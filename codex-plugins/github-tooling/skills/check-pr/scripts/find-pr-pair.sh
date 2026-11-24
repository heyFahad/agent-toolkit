#!/bin/bash
# Usage: find-pr-pair.sh [-R OWNER/REPO] [FEATURE_BRANCH]
#
# Finds a ticket's open PRs from its feature branch (default: the branch
# checked out) without assuming any branch names:
#   main     the open PR from the feature branch into the repo's default branch
#   preprod  every open PR into any other branch whose head is the feature
#            branch, or a conflicts/... branch that belongs to it
#
# A conflicts/... branch belongs to the feature branch when its name is the
# feature branch's name (with or without the type prefix: conflicts/x for
# feat/x), when the two share a ticket key (ABC-123), or, failing both, when
# it already contains the feature branch's tip commit.
#
# Prints JSON:
#   {repo, branch, defaultBranch,
#    main: {number, url, title, isDraft, headRefName, baseRefName, headRefOid} | null,
#    preprod: [{...same fields..., matchedBy}]}
# matchedBy is one of: head, conflicts-name, conflicts-ticket, conflicts-ancestry.
# More than one preprod entry means the pair is ambiguous; ask, don't guess.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
BRANCH=${ARGS[0]:-}
if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] || die "not on a branch; pass the feature branch name"
fi
case "$BRANCH" in
  conflicts/*) die "'$BRANCH' is a conflicts branch; pass the feature branch it was made for" ;;
esac

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name }
    pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { number url title isDraft headRefName baseRefName headRefOid }
    }
  }
}'

DATA=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME")

RESULT=$(printf '%s' "$DATA" | jq --arg repo "$REPO" --arg branch "$BRANCH" '
  def tickets: [scan("[A-Z][A-Z0-9]+-[0-9]+")];
  def fields: {number, url, title, isDraft, headRefName, baseRefName, headRefOid};
  .data.repository as $r
  | $r.defaultBranchRef.name as $default
  | ($branch | sub("^[^/]+/"; "")) as $tail
  | ($branch | tickets) as $keys
  | [$r.pullRequests.nodes[] | select(.baseRefName != $default)] as $others
  | {
      repo: $repo,
      branch: $branch,
      defaultBranch: $default,
      main: ([$r.pullRequests.nodes[] | select(.headRefName == $branch and .baseRefName == $default) | fields] | first),
      preprod: [
        $others[]
        | (.headRefName | sub("^conflicts/"; "")) as $c
        | if .headRefName == $branch then fields + {matchedBy: "head"}
          elif (.headRefName | startswith("conflicts/")) | not then empty
          elif $c == $branch or $c == $tail then fields + {matchedBy: "conflicts-name"}
          elif any($c | tickets[]; IN($keys[])) then fields + {matchedBy: "conflicts-ticket"}
          else fields + {matchedBy: null}
          end
      ]
    }')

# conflicts/... PRs that matched neither by name nor by ticket: keep only the
# ones that already contain the feature branch's tip.
UNMATCHED=$(printf '%s' "$RESULT" | jq -r '.preprod[] | select(.matchedBy == null) | .headRefName')
ANCESTRY=()
if [ -n "$UNMATCHED" ]; then
  while IFS= read -r head; do
    status=$(gh api "repos/$REPO/compare/$(printf '%s' "$BRANCH" | jq -sRr @uri)...$(printf '%s' "$head" | jq -sRr @uri)" --jq .status 2>/dev/null || true)
    case "$status" in
      ahead | identical) ANCESTRY+=("$head") ;;
    esac
  done <<<"$UNMATCHED"
fi

printf '%s' "$RESULT" | jq --args '
  ($ARGS.positional) as $anc
  | .preprod |= [ .[]
      | if .matchedBy != null then .
        elif (.headRefName | IN($anc[])) then .matchedBy = "conflicts-ancestry"
        else empty end ]' ${ANCESTRY[@]+"${ANCESTRY[@]}"}
