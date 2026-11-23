#!/bin/bash
# Usage: fallback-review.sh [-R OWNER/REPO] PR_NUMBER
#
# Reviews a PR when Copilot declined to (request-copilot.sh said
# accepted: false). Run it from a checkout at the PR's head commit.
#
# The reviewer: Codex when `codex` is on PATH and `codex login status`
# succeeds, otherwise diff-review. A Codex run that fails (quota, expired
# auth, a rejected model) also falls to diff-review. diff-review is a skill,
# so this script only names it: the agent then runs it on base..head.
#
# The range starts at, in order: the head the last fallback review covered
# (its marker comment names it), the commit Copilot last reviewed, or the
# merge base with the PR's own base branch. A candidate that isn't an
# ancestor of the head (missing here, or orphaned by a rebase and force-push)
# is skipped. When a fallback review already covered the head, there is
# nothing to do: reviewer is null.
#
# Codex's model comes from .codexModel in
# ${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/verify.local.json, passed as
# -c model="..."; without it Codex uses its own default.
#
# Two things about the codex CLI (0.171) this works around:
#   - In a git worktree, `codex review --base` says the directory "is not a
#     git repository". Agents work in worktrees, so GIT_DIR and GIT_WORK_TREE
#     are set for it explicitly.
#   - After an error it prints "ERROR: ..." and then hangs instead of
#     exiting. Its output is watched: an ERROR line, or running past
#     CHECK_PR_CODEX_TIMEOUT seconds (default 1200), stops it, and the
#     review falls to diff-review. CHECK_PR_CODEX_POLL (default 2) is how
#     often it's checked.
#
# Prints JSON: {pr, head, base, reviewer: "codex"|"diff-review"|null, reason,
#               output: path to Codex's review text | null}
# Exit codes: 0 a reviewer was chosen (and Codex, if it was, finished);
# 2 bad usage, a failed lookup, or a checkout that isn't exactly the PR's
# head (another commit, or uncommitted changes to tracked files).
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

ensure_gh_token
parse_repo_args "$@"
PR=${ARGS[0]:-}
require_pr_number "$PR"
HERE=$(cd "$(dirname "$0")" && pwd)

COPILOT=$(bash "$HERE/copilot-review.sh" -R "$REPO" "$PR") || die "copilot-review.sh failed"
HEAD_OID=$(printf '%s' "$COPILOT" | jq -r .headOid)
LOCAL=$(git rev-parse HEAD 2>/dev/null) || die "not in a git checkout"
[ "$LOCAL" = "$HEAD_OID" ] || die "this checkout is at $LOCAL, but PR #$PR's head is $HEAD_OID: check out the PR's head first"
# Codex's --base review diffs the working tree, not HEAD, so local edits
# would be reviewed in place of the PR.
[ -z "$(git status --porcelain --untracked-files=no)" ] ||
  die "this checkout has uncommitted changes; commit or set them aside first, so the review covers exactly $HEAD_OID"

result() { # base reviewer reason output
  jq -n --argjson pr "$PR" --arg head "$HEAD_OID" --arg base "$1" --arg reviewer "$2" --arg reason "$3" --arg output "$4" \
    '{pr: $pr, head: $head, base: (if $base == "" then null else $base end),
      reviewer: (if $reviewer == "" then null else $reviewer end), reason: $reason,
      output: (if $output == "" then null else $output end)}'
}

if [ "$(printf '%s' "$COPILOT" | jq -r .fallbackReviewedHead)" = true ]; then
  result "" "" "a $(printf '%s' "$COPILOT" | jq -r .fallbackReviewer) fallback review already covers $HEAD_OID" ""
  exit 0
fi

BASE=""
for c in $(printf '%s' "$COPILOT" | jq -r '.fallbackLastHead // empty, .review.commit // empty'); do
  if git merge-base --is-ancestor "$c" HEAD 2>/dev/null; then
    BASE=$c
    break
  fi
done
if [ -z "$BASE" ]; then
  BASE_REF=$(gh pr view "$PR" -R "$REPO" --json baseRefName --jq .baseRefName) || die "could not read PR #$PR's base branch"
  BASE=$(git merge-base "origin/$BASE_REF" HEAD) || die "no merge base with origin/$BASE_REF; fetch it first"
fi

if ! command -v codex >/dev/null 2>&1; then
  result "$BASE" diff-review "codex is not on PATH" ""
  exit 0
fi
if ! codex login status >/dev/null 2>&1; then
  result "$BASE" diff-review "codex login status failed: Codex isn't logged in" ""
  exit 0
fi

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/agent-toolkit/verify.local.json"
MODEL=$(jq -r '.codexModel // empty' "$CONFIG" 2>/dev/null || true)
OUT=$(mktemp "${TMPDIR:-/tmp}/check-pr-fallback-$PR-XXXXXX")
set -- review --base "$BASE"
[ -z "$MODEL" ] || set -- "$@" -c "model=\"$MODEL\""
LIMIT=${CHECK_PR_CODEX_TIMEOUT:-1200}
POLL=${CHECK_PR_CODEX_POLL:-2}
GIT_DIR=$(git rev-parse --absolute-git-dir) GIT_WORK_TREE=$(git rev-parse --show-toplevel) \
  codex "$@" </dev/null >"$OUT" 2>&1 &
CODEX_PID=$!
SECONDS=0
FAILED=""
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if grep -q '^ERROR:' "$OUT"; then
    FAILED="codex review failed: $(grep -m1 '^ERROR:' "$OUT" | sed 's/^ERROR: *//')"
  elif [ "$SECONDS" -ge "$LIMIT" ]; then
    FAILED="codex review ran past its time limit (${LIMIT}s)"
  fi
  if [ -n "$FAILED" ]; then
    kill "$CODEX_PID" 2>/dev/null || true
    break
  fi
  sleep "$POLL"
done
rc=0
wait "$CODEX_PID" 2>/dev/null || rc=$?
if [ -z "$FAILED" ] && [ "$rc" -ne 0 ]; then
  FAILED="codex review exited $rc"
fi
if [ -n "$FAILED" ]; then
  result "$BASE" diff-review "$FAILED; its output is in $OUT" ""
  exit 0
fi
result "$BASE" codex "Copilot declined and Codex is logged in" "$OUT"
