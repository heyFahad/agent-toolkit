#!/bin/bash
# Usage: request-copilot.sh [-R OWNER/REPO] PR_NUMBER...
#
# Requests a Copilot review on each PR, then checks that each request was
# accepted. When Copilot's monthly credits have run out, GitHub still accepts
# `gh pr edit --add-reviewer @copilot`, but no request event for Copilot
# reaches the PR's timeline and no review ever comes. So a request counts as
# accepted only once a Copilot ReviewRequestedEvent dated at or after the
# request shows up. The timeline is read up to CHECK_PR_REQUEST_READS times
# (default 6), CHECK_PR_REQUEST_DELAY seconds apart (default 5), in case the
# event lags. Every request is made first, so all PRs share one window.
#
# requestedAt is the time of the request minus 60 seconds, to absorb clock
# skew between this machine and GitHub.
#
# Prints JSON: [{pr, accepted, requestedAt}]
# Exit codes: 0 once every request was made, accepted or not; 2 bad usage, a
# failed request or a failed timeline lookup.
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
[ "${#ARGS[@]}" -gt 0 ] || die "usage: request-copilot.sh [-R OWNER/REPO] PR_NUMBER..."
for pr in "${ARGS[@]}"; do require_pr_number "$pr"; done

READS=${CHECK_PR_REQUEST_READS:-6}
DELAY=${CHECK_PR_REQUEST_DELAY:-5}

# An epoch time as ISO 8601 UTC, on BSD (macOS) or GNU date.
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE=$(iso $(($(date -u +%s) - 60)))

for pr in "${ARGS[@]}"; do
  gh pr edit -R "$REPO" "$pr" --add-reviewer @copilot >/dev/null || die "requesting Copilot on #$pr failed"
done

# shellcheck disable=SC2016 # GraphQL variables, not shell ones
QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      timelineItems(last: 20, itemTypes: [REVIEW_REQUESTED_EVENT]) {
        nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on Bot { login } ... on User { login } } } }
      }
    }
  }
}'

# accepted PR: true when the timeline has a Copilot request event since SINCE.
# A failed lookup stops the script: reporting it as a decline would send the
# agent to a fallback review while Copilot may still be coming.
accepted() {
  local json
  json=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$1") ||
    die "reading PR #$1's timeline failed"
  printf '%s' "$json" | jq -e --arg copilot "$COPILOT_LOGIN_RE" --arg since "$SINCE" '
      any(.data.repository.pullRequest.timelineItems.nodes[];
        ((.requestedReviewer.login // "") | test($copilot)) and (.createdAt // "") >= $since)' >/dev/null
}

PENDING=" ${ARGS[*]} "
ACCEPTED=" "
i=1
while [ "$i" -le "$READS" ] && [ -n "${PENDING// /}" ]; do
  [ "$i" -gt 1 ] && sleep "$DELAY"
  for pr in $PENDING; do
    if accepted "$pr"; then
      ACCEPTED="$ACCEPTED$pr "
      PENDING=${PENDING/ $pr / }
    fi
  done
  i=$((i + 1))
done

for pr in "${ARGS[@]}"; do
  case "$ACCEPTED" in *" $pr "*) a=true ;; *) a=false ;; esac
  jq -n --argjson pr "$pr" --argjson a "$a" --arg at "$SINCE" '{pr: $pr, accepted: $a, requestedAt: $at}'
done | jq -s .
