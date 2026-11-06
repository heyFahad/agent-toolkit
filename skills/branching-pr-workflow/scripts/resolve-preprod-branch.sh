#!/bin/bash
# Prints the current repo's pre-prod branch (the long-lived branch that QA
# deploys go to: dev, develop, staging, ...). Every git-workflow skill and
# hook asks this script instead of assuming a name.
#
# Usage, from inside the repo:
#   resolve-preprod-branch.sh             print the branch
#   resolve-preprod-branch.sh --refresh   ignore the cache and infer again
#   resolve-preprod-branch.sh --set dev   save a per-repo override
#   resolve-preprod-branch.sh --set none  record that this repo has none
#
# Order: per-repo override, then a cached inference, then a fresh
# inference (the candidate that received the most merged PRs recently).
#
# Exit codes:
#   0  branch printed on stdout
#   1  not a git repo, or no origin remote
#   2  ambiguous: candidates are on stderr. Ask the user which one QA PRs
#      target, then save the answer with --set.
#   3  this repo has no pre-prod branch
#
# The override file lives outside any plugin folder so it survives plugin
# updates, like jira-ticket-lifecycle's status-map.local.json:
#   ${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/preprod-branches.local.json
#   {"repos": {"owner/repo": {"branch": "dev", "setOn": "2026-11-06"}}}
# An empty "branch" means the repo has none.
#
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

# Exact names only, so release/*, feature/*, fix/*, conflicts/*, chore/* and
# other short-lived branches can never be picked.
CANDIDATE_NAMES="dev develop development staging stage preprod pre-prod qa uat"
CACHE_DAYS=7

CONFIG_DIR="${AGENT_TOOLKIT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit}"
CONFIG_FILE="$CONFIG_DIR/preprod-branches.local.json"
STATE_DIR="${AGENT_TOOLKIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-toolkit}/preprod-branch"

MODE=get
SET_VALUE=""
case "${1:-}" in
  --refresh) MODE=refresh ;;
  --set)
    MODE=set
    SET_VALUE="${2:-}"
    if [ -z "$SET_VALUE" ]; then
      echo "usage: $0 --set <branch>|none" >&2
      exit 1
    fi
    ;;
  "") ;;
  *) echo "usage: $0 [--refresh | --set <branch>|none]" >&2; exit 1 ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "resolve-preprod-branch: not inside a git repository" >&2
  exit 1
fi

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
if [ -z "$ORIGIN_URL" ]; then
  echo "resolve-preprod-branch: no origin remote" >&2
  exit 1
fi

# owner/repo from any of git@host:o/r.git, https://host/o/r, ssh://git@host/o/r.git
REPO_KEY=$(printf '%s' "$ORIGIN_URL" | sed -E 's#\.git/?$##; s#/$##; s#^[^:]+:(//[^/]+/)?##' | awk -F/ '{ if (NF >= 2) print $(NF-1) "/" $NF; else print $NF }' | tr '[:upper:]' '[:lower:]')
CACHE_FILE="$STATE_DIR/$(printf '%s' "$REPO_KEY" | tr '/' '_')"

if [ "$MODE" = set ]; then
  [ "$SET_VALUE" = none ] && SET_VALUE=""
  mkdir -p "$CONFIG_DIR"
  [ -s "$CONFIG_FILE" ] || echo '{"repos":{}}' > "$CONFIG_FILE"
  TMP_FILE=$(mktemp "$CONFIG_DIR/.preprod-branches.XXXXXX")
  if jq --arg k "$REPO_KEY" --arg b "$SET_VALUE" --arg d "$(date +%Y-%m-%d)" \
      '.repos[$k] = {branch: $b, setOn: $d}' "$CONFIG_FILE" > "$TMP_FILE"; then
    mv "$TMP_FILE" "$CONFIG_FILE"
  else
    rm -f "$TMP_FILE"
    echo "resolve-preprod-branch: could not update $CONFIG_FILE" >&2
    exit 1
  fi
  rm -f "$CACHE_FILE"
  echo "Saved pre-prod branch for $REPO_KEY: ${SET_VALUE:-none} ($CONFIG_FILE)" >&2
  [ -n "$SET_VALUE" ] && echo "$SET_VALUE"
  exit 0
fi

# 1. Per-repo override.
if [ -s "$CONFIG_FILE" ]; then
  OVERRIDE=$(jq -r --arg k "$REPO_KEY" '.repos[$k] // empty | if type == "object" then .branch else . end' "$CONFIG_FILE" 2>/dev/null || true)
  if jq -e --arg k "$REPO_KEY" '.repos | has($k)' "$CONFIG_FILE" >/dev/null 2>&1; then
    if [ -z "$OVERRIDE" ]; then
      echo "resolve-preprod-branch: $REPO_KEY is recorded as having no pre-prod branch ($CONFIG_FILE)" >&2
      exit 3
    fi
    echo "$OVERRIDE"
    exit 0
  fi
fi

# 2. Cached inference.
if [ "$MODE" = get ] && [ -s "$CACHE_FILE" ] && [ -n "$(find "$CACHE_FILE" -mtime -"$CACHE_DAYS" 2>/dev/null)" ]; then
  CACHED=$(cat "$CACHE_FILE")
  if [ "$CACHED" = "-" ]; then
    exit 3
  fi
  echo "$CACHED"
  exit 0
fi

# 3. Inference.
# Ask GitHub first: a local origin/HEAD is set at clone time and goes stale
# when the default branch is changed later.
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed -E 's@^refs/remotes/origin/@@' || true)
fi

# The remote's live branch list; fall back to the last-fetched refs offline.
REMOTE_BRANCHES=$(git ls-remote --heads origin 2>/dev/null | sed -E 's@^[^[:space:]]+[[:space:]]+refs/heads/@@')
if [ -z "$REMOTE_BRANCHES" ]; then
  REMOTE_BRANCHES=$(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin 2>/dev/null)
fi

CANDIDATES=""
for name in $CANDIDATE_NAMES; do
  [ "$name" = "$DEFAULT_BRANCH" ] && continue
  if printf '%s\n' "$REMOTE_BRANCHES" | grep -qxF "$name"; then
    CANDIDATES="$CANDIDATES $name"
  fi
done
CANDIDATES="${CANDIDATES# }"

save_cache() {
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$1" > "$CACHE_FILE" 2>/dev/null || true
}

if [ -z "$CANDIDATES" ]; then
  save_cache "-"
  echo "resolve-preprod-branch: origin has no long-lived pre-prod branch (looked for: $CANDIDATE_NAMES)" >&2
  exit 3
fi

case "$CANDIDATES" in
  *" "*) ;;
  *)
    save_cache "$CANDIDATES"
    echo "$CANDIDATES"
    exit 0
    ;;
esac

# Several candidates: the one most PRs actually merge into wins.
BASES=$(gh pr list --state merged --limit 200 --json baseRefName --jq '.[].baseRefName' 2>/dev/null || true)

BEST="" BEST_COUNT=0 SECOND_COUNT=0 SUMMARY=""
for name in $CANDIDATES; do
  count=$(printf '%s\n' "$BASES" | grep -cxF "$name" || true)
  SUMMARY="$SUMMARY $name ($count merged PRs)"
  if [ "$count" -gt "$BEST_COUNT" ]; then
    SECOND_COUNT=$BEST_COUNT
    BEST_COUNT=$count
    BEST=$name
  elif [ "$count" -gt "$SECOND_COUNT" ]; then
    SECOND_COUNT=$count
  fi
done

if [ -z "$BASES" ] || [ "$BEST_COUNT" -eq 0 ] || [ "$BEST_COUNT" -eq "$SECOND_COUNT" ]; then
  {
    echo "resolve-preprod-branch: can't tell which branch is pre-prod for $REPO_KEY."
    echo "Candidates:$SUMMARY"
    [ -z "$BASES" ] && echo "(gh pr list returned nothing, so there were no merge counts to compare.)"
    echo "Ask the user which branch QA PRs go to, then save it: $0 --set <branch>"
  } >&2
  exit 2
fi

save_cache "$BEST"
echo "$BEST"
