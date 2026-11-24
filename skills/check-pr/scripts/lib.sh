# shellcheck shell=bash disable=SC2034 # variables here are used by the scripts that source it
# Shared helpers for the check-pr scripts. Sourced, never run on its own.
# Keep everything here bash 3.2 compatible: it runs under macOS's /bin/bash.

set -euo pipefail

# Login of GitHub's Copilot code reviewer. GraphQL reports the bare login,
# REST appends "[bot]", and a review request made with `--add-reviewer
# @copilot` can show up as "Copilot".
COPILOT_LOGIN_RE='^(copilot-pull-request-reviewer(\[bot\])?|Copilot)$'

die() {
  echo "$(basename "$0"): $*" >&2
  exit 2
}

# gh prefers an exported GITHUB_TOKEN over the keyring login, and such a
# token (one kept for a package registry, say) may lack the scopes these
# scripts need: private repos then answer 404, which looks like a permissions
# problem. Resolve the keyring token once here so every gh call below (and
# any child script) uses it. `env -u` makes `gh auth token` read the keyring
# login rather than echo back the exported token.
ensure_gh_token() {
  if [ -z "${GH_TOKEN:-}" ]; then
    local t
    t=$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null || true)
    if [ -n "$t" ]; then
      GH_TOKEN=$t
      export GH_TOKEN
    fi
  fi
}

# Parses a leading `-R OWNER/REPO` / `--repo OWNER/REPO` and sets REPO, OWNER,
# NAME and ARGS (the remaining positional arguments). Without the flag, the
# repo is whatever `gh` resolves for the current directory.
REPO="" OWNER="" NAME=""
ARGS=()
parse_repo_args() {
  ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -R | --repo)
        [ "$#" -ge 2 ] || die "$1 needs OWNER/REPO"
        REPO=$2
        shift 2
        ;;
      --repo=*)
        REPO=${1#--repo=}
        shift
        ;;
      *)
        ARGS+=("$1")
        shift
        ;;
    esac
  done
  if [ -z "$REPO" ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$REPO" ] || die "could not tell which repo this is; pass -R OWNER/REPO"
  fi
  case "$REPO" in
    */*) ;;
    *) die "repo must be OWNER/REPO, got '$REPO'" ;;
  esac
  OWNER=${REPO%%/*}
  NAME=${REPO#*/}
}

require_pr_number() {
  case "${1:-}" in
    '' | *[!0-9]*) die "expected a PR number, got '${1:-}'" ;;
  esac
}

# find_preprod_resolver [SCRIPTS_DIR]: prints the path of git-workflow's
# resolve-preprod-branch.sh, or nothing. That script lives in another plugin,
# so look where it can be:
#   1. $AGENT_TOOLKIT_PREPROD_RESOLVER, when set (and only there)
#   2. next to this skill, in a source checkout of the toolkit, where skills
#      are siblings (SCRIPTS_DIR is this skill's scripts/ folder)
#   3. the installed git-workflow plugin, from Claude Code's
#      installed_plugins.json
find_preprod_resolver() {
  local dir=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
  local rel=skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh
  if [ -n "${AGENT_TOOLKIT_PREPROD_RESOLVER+set}" ]; then
    [ ! -f "$AGENT_TOOLKIT_PREPROD_RESOLVER" ] || printf '%s' "$AGENT_TOOLKIT_PREPROD_RESOLVER"
    return 0
  fi
  if [ -f "$dir/../../branching-pr-workflow/scripts/resolve-preprod-branch.sh" ]; then
    printf '%s' "$dir/../../branching-pr-workflow/scripts/resolve-preprod-branch.sh"
    return 0
  fi
  local installed="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" p
  [ -f "$installed" ] || return 0
  p=$(jq -r '[.plugins // {} | to_entries[] | select(.key | startswith("git-workflow@")) | .value[]?.installPath] | first // empty' "$installed" 2>/dev/null)
  [ -z "$p" ] || [ ! -f "$p/$rel" ] || printf '%s' "$p/$rel"
}

# checkout_repo_key: the current checkout's origin as a lowercase owner/name,
# or nothing.
checkout_repo_key() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || return 0
  printf '%s' "$url" | sed -E 's#\.git/?$##; s#/$##; s#^[^:]+:(//[^/]+/)?##' |
    awk -F/ '{ if (NF >= 2) print $(NF-1) "/" $NF; else print $NF }' | tr '[:upper:]' '[:lower:]'
}
