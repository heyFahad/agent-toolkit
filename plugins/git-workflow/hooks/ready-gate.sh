#!/bin/bash
# PreToolUse hook (Bash): blocks `gh pr ready` (not --undo) unless the PR may
# leave draft. Marking a pre-prod PR ready puts it in front of other
# developers, which happens only after the user tested the running app and
# said so; the manually-verified label (which label-gate.sh makes the user
# confirm) records that.
#
#   PR base                    pre-prod resolver   decision
#   the pre-prod branch        prints it           allow only with manually-verified
#   the default branch         exit 3 (none)       allow: a single-PR repo
#   the default branch         prints a branch     block: the main PR stays a
#                                                  draft until release
#   anything else              prints or exit 3    allow: a stacked PR into the
#                                                  branch below it
#   anything                   fails (exit 1, 2)   block: settle the pre-prod
#                                                  branch first
#
# The PR comes from one `gh pr view` lookup, run where the command would run
# (`.cwd`, plus any earlier `cd`). The resolver can only answer for that
# checkout, so a -R, GH_REPO or URL naming another repo is blocked, and so is
# a PR the lookup resolves in another repo (gh repo set-default). A failed
# lookup blocks too. So does gh pr ready after a gh pr edit of the base or
# labels in the same Bash call: the lookup runs before that edit.
#
# A speed bump, not a proof: a GraphQL markPullRequestReadyForReview call
# through `gh api` isn't caught. The check-pr skill forbids it.
# Exit 2 blocks the call, with the reason on stderr.
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

LABEL=manually-verified
HERE=$(cd "$(dirname "$0")" && pwd)
RESOLVER="${AGENT_TOOLKIT_PREPROD_RESOLVER:-$HERE/../skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh}"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Fast path: almost no command mentions ready. Anything subtler (an operator
# right after it, a continued line) is left to the parser below.
printf '%s' "$COMMAND" | grep -q ready || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/commands.sh
. "$HERE/lib/commands.sh"
# shellcheck source-path=SCRIPTDIR source=../skills/verify/scripts/lib.sh
. "$HERE/../skills/verify/scripts/lib.sh"

REASONS=""
block() { REASONS="$REASONS""ready-gate: $1"$'\n'; }

# A -R value or a PR URL as a lowercase owner/name.
repo_of() {
  printf '%s' "$1" | sed -E 's#^https?://##; s#^[^/]+/([^/]+/[^/]+)/pull/.*#\1#; s#^[^/]+/([^/]+/[^/]+)$#\1#' |
    tr '[:upper:]' '[:lower:]'
}

# check_ready DIR ENV_REPO FLAG_REPO ARGS...: ENV_REPO is what GH_REPO says
# for this command, FLAG_REPO a -R given before the verb.
check_ready() {
  local dir=$1 env_repo=$2 repo=$3
  shift 3
  local arg="" w
  while [ "$#" -gt 0 ]; do
    w=$1
    case "$w" in
      --undo) return 0 ;;
      -R | --repo)
        repo=${2:-}
        shift
        ;;
      --repo=*) repo=${w#--repo=} ;;
      -R?*) repo=${w#-R} ;;
      -*) ;;
      # A redirection (2>&1, > /dev/null) is no PR argument.
      *[\<\>]) shift ;;
      *[\<\>]*) ;;
      *) [ -n "$arg" ] || arg=$w ;;
    esac
    [ "$#" -eq 0 ] || shift
  done
  # gh takes -R over GH_REPO.
  [ -n "$repo" ] || repo=$env_repo

  local here
  here=$(vf_repo_key "$dir")
  if [ -z "$here" ]; then
    block "can't tell which repo $dir is (not a git checkout with an origin), so the PR's base can't be checked. Run gh pr ready from the PR's checkout."
    return
  fi
  local named url_repo=""
  case "$arg" in https://*/pull/*) url_repo=$(repo_of "$arg") ;; esac
  for named in "$(repo_of "$repo")" "$url_repo"; do
    if [ -n "$named" ] && [ "$named" != "$here" ]; then
      block "gh pr ready names $named (through -R, GH_REPO or a URL), but this checkout is $here, and the pre-prod branch can only be checked for the checkout. Run it from a checkout of $named."
      return
    fi
  done

  local view err
  err=$(mktemp "${TMPDIR:-/tmp}/ready-gate.XXXXXX")
  local args=(pr view)
  [ -z "$arg" ] || args+=("$arg")
  args+=(--json 'baseRefName,labels,url')
  [ -z "$repo" ] || args+=(-R "$repo")
  if ! view=$(cd "$dir" && gh "${args[@]}" 2>"$err"); then
    block "couldn't look up the PR (gh ${args[*]}): $(tr '\n' ' ' <"$err")"
    rm -f "$err"
    return
  fi
  rm -f "$err"
  local base url labeled
  base=$(printf '%s' "$view" | jq -r '.baseRefName // ""')
  url=$(printf '%s' "$view" | jq -r '.url // "the PR"')
  # The PR gh resolved, which `gh repo set-default` can point at a remote
  # other than origin.
  local resolved
  resolved=$(repo_of "$url")
  case "$url" in https://*/pull/*) ;; *) resolved="" ;; esac
  if [ -z "$resolved" ] || [ "$resolved" != "$here" ]; then
    block "gh resolved $url, which isn't in this checkout's repo ($here), so its pre-prod branch can't be checked here. Run gh pr ready from a checkout of that repo."
    return
  fi
  labeled=$(printf '%s' "$view" | jq -r --arg l "$LABEL" '[.labels[]?.name | ascii_downcase] | index($l) != null')

  local preprod rc=0 default
  preprod=$(cd "$dir" && bash "$RESOLVER" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3) preprod="" ;;
    *)
      block "couldn't tell this repo's pre-prod branch (resolve-preprod-branch.sh exit $rc), so $url can't be checked. Ask the user which branch QA PRs target, save it with resolve-preprod-branch.sh --set <branch>, and try again."
      return
      ;;
  esac
  default=$(cd "$dir" && bash "$RESOLVER" --default 2>/dev/null) || default=""

  if [ -n "$preprod" ] && [ "$base" = "$preprod" ]; then
    [ "$labeled" = true ] && return 0
    block "$url is a pre-prod PR without $LABEL. Don't mark it ready yet: ask the user to test the running app and approve; check-pr adds the label once they do."
    return
  fi
  if [ -z "$default" ]; then
    block "couldn't tell this repo's default branch, so $url (into $base) can't be checked."
    return
  fi
  if [ "$base" = "$default" ] && [ -n "$preprod" ]; then
    block "$url is the PR into $default. It stays a draft until the change is released; only the pre-prod PR (into $preprod) gets marked ready."
  fi
}

# gh_repo_assign WORD: the value when WORD is a GH_REPO= assignment.
gh_repo_assign() {
  case "$1" in GH_REPO=*) printf '%s' "${1#GH_REPO=}" | tr -d "\"'" ;; *) return 1 ;; esac
}

# GH_REPO points gh at another repo: from the hook's own environment (which
# the command inherits), an `export GH_REPO=...` earlier in the call, or a
# GH_REPO= prefix on the command itself.
DIR=$CWD ENV_REPO=${GH_REPO:-} EDITED=""
while IFS= read -r seg; do
  hc_words "$seg"
  [ "$i" -lt "${#words[@]}" ] || continue
  seg_repo=$ENV_REPO
  k=0
  while [ "$k" -lt "$i" ]; do
    v=$(gh_repo_assign "${words[$k]}") && seg_repo=$v
    k=$((k + 1))
  done
  case "${words[$i]##*/}" in
    cd) [ $((i + 1)) -lt "${#words[@]}" ] && DIR=$(hc_resolve "${words[$((i + 1))]}" "$DIR") ;;
    export)
      for w in "${words[@]:$((i + 1))}"; do
        v=$(gh_repo_assign "$w") && ENV_REPO=$v
      done
      ;;
    unset)
      for w in "${words[@]:$((i + 1))}"; do [ "$w" != GH_REPO ] || ENV_REPO=""; done
      ;;
    gh)
      hc_gh_command
      # An edit of the PR's base or labels earlier in the same call hasn't
      # happened yet when this hook looks the PR up.
      if [ "$gh_sub" = "pr edit" ]; then
        for w in "${words[@]:$gh_args}"; do
          case "$w" in --base | --base=* | -B | -B?* | --add-label | --add-label=* | --remove-label | --remove-label=*) EDITED="gh pr edit $w" ;; esac
        done
      fi
      if [ "$gh_sub" = "pr ready" ] && [ -n "$EDITED" ]; then
        block "gh pr ready runs in the same Bash call as $EDITED, which changes what this hook checks, so it can't see the PR as it will be. Run gh pr ready in its own Bash call."
        continue
      fi
      if [ "$gh_sub" = "pr ready" ]; then
        rest=()
        [ "$gh_args" -ge "${#words[@]}" ] || rest=("${words[@]:$gh_args}")
        check_ready "$DIR" "$seg_repo" "$gh_repo" ${rest[@]+"${rest[@]}"}
      fi
      ;;
  esac
done < <(hc_segments "$COMMAND")

if [ -n "$REASONS" ]; then
  printf '%s' "$REASONS" >&2
  exit 2
fi
exit 0
