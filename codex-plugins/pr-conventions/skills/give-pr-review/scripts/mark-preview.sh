#!/bin/bash
# Usage: bash mark-preview.sh OWNER/REPO PR_NUMBER REVIEW_ID
#
# Prints the inline comments of a PENDING review exactly as GitHub stored
# them, and records a hash of them as the "preview shown" marker that the
# pr-conventions review-guard hook requires before it lets the review be
# submitted. Run it, paste the output into the chat preview, then wait for
# the user. Editing the pending review afterwards invalidates the marker.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: mark-preview.sh OWNER/REPO PR_NUMBER REVIEW_ID" >&2
  exit 2
fi
REPO=$1 PR=$2 REVIEW_ID=$3

# Keep in sync with plugins/pr-conventions/hooks/review-guard.sh.
STATE_DIR="${AGENT_TOOLKIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-toolkit}/review-previews"

hash_stdin() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

COMMENTS=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews/$REVIEW_ID/comments")
LINES=$(printf '%s' "$COMMENTS" | jq -c '.[] | {path, line, side, commit_id, body}')

if [ -z "$LINES" ]; then
  echo "warning: review $REVIEW_ID has no inline comments (is it pending, and is the id right?)" >&2
fi

printf '%s' "$COMMENTS" | jq -r '.[] | "\(.path):\(.line) [\(.side)] @ \(.commit_id[0:7])\n\(.body)\n"'

mkdir -p "$STATE_DIR"
printf '%s' "$COMMENTS" | jq -c '.[] | {path, line, side, commit_id, body}' | hash_stdin > "$STATE_DIR/$REVIEW_ID"
echo "preview marker recorded for review $REVIEW_ID ($(printf '%s' "$LINES" | grep -c . || true) comments)" >&2
