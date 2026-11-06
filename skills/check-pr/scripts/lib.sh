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

# macOS's Keychain-backed gh credential can fail to reach a nested gh call,
# which then gets a 404 that looks like a permissions problem. Resolve the
# token once here so every gh call below (and any child script) inherits it.
ensure_gh_token() {
  if [ -z "${GH_TOKEN:-}" ]; then
    local t
    t=$(gh auth token 2>/dev/null || true)
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
