#!/bin/bash
# PreToolUse hook: guards the way a review on someone else's PR gets posted.
# See the give-pr-review skill for the workflow this enforces. A review
# posted as one long itemised body, or submitted without the user having
# seen it, is hard to act on and blocks the author's PR, and that exact
# mistake has actually happened.
#
# What it enforces (everything else, including every read-only call, passes):
#   1. `gh pr review` with a long or itemised body. That command cannot
#      attach inline comments, so it is only for a short verdict.
#   2. `POST .../pulls/N/reviews` (creating a review) that either submits
#      immediately (has an `event`) or carries a long/itemised body, a
#      missing commit_id, or inline comments without path/line/side/body
#      (or with the diff-position field instead of line).
#   3. `POST .../reviews/ID/events` (submitting) with a long/itemised body,
#      or without a preview marker whose content hash still matches the
#      pending review's comments. The marker is written by the skill's
#      scripts/mark-preview.sh. A hook cannot read the chat, so this proves
#      the preview step was run against *this* content, not that the user
#      read it. It is a speed bump, not a proof.
#
# The body limits are approximate on purpose: when the body cannot be parsed
# out of the command (shell-quoted `-f body=...`), the whole command text is
# measured instead, which over-counts by the flags and errs towards blocking.
set -euo pipefail

# Keep in sync with skills/give-pr-review/scripts/mark-preview.sh.
STATE_DIR="${AGENT_TOOLKIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-toolkit}/review-previews"

# The skill asks for two or three lines; ~500 chars is that with slack.
MAX_BODY_CHARS=500
# Measured on the raw command text, which carries ~100 chars of flags.
MAX_COMMAND_CHARS=600
# An itemised list is the real signature of the failure, so it is blocked
# even when short. Three bullets can still be a legitimate summary.
MAX_LIST_ITEMS=3

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only a gh call at command position counts, so `git commit -m "... gh pr
# review ..."` or an `echo` of the text never trips this.
CMD_POS='(^|[;&|(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
PR_REVIEW_RE="${CMD_POS}gh[[:space:]]+pr[[:space:]]+review([[:space:]]|\$)"
API_RE="${CMD_POS}gh[[:space:]]+api[[:space:]]"
CREATE_RE='pulls/[0-9]+/reviews(["'"'"'?[:space:]]|$)'
EVENTS_RE='(repos/[^/[:space:]"'"'"']+/[^/[:space:]"'"'"']+/pulls/[0-9]+/reviews/([0-9]+))/events(["'"'"'?[:space:]]|$)'

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

POINTER='See the give-pr-review skill: every finding is an inline comment in a pending review, the review body is a short summary only, and the user sees the exact comments before anything is submitted.'

list_items() {
  # Break after an opening --body quote so the first bullet starts a line.
  printf '%s' "$1" | sed -E "s/(--body|-b)[= ]+[\"']/\\1 \\n/" | grep -cE '^[[:space:]"'"'"']*([-*•]|[0-9]+[.)])[[:space:]]+' || true
}

# $1 = text, $2 = char limit, $3 = what is being measured
check_body() {
  local text="$1" limit="$2" what="$3" len items
  len=${#text}
  items=$(list_items "$text")
  if [ "$len" -gt "$limit" ]; then
    deny "Review guard: $what is $len characters (limit about $limit). A review body is a two-to-three line summary; findings go in inline comments on the lines they are about. $POINTER"
  fi
  if [ "$items" -gt "$MAX_LIST_ITEMS" ]; then
    deny "Review guard: $what contains an itemised list ($items items). Move each finding into its own inline comment on the exact file and line. $POINTER"
  fi
}

# Resolve --input FILE (not "-") relative to the hook's cwd.
input_file() {
  local f
  f=$(printf '%s' "$COMMAND" | grep -oE -- '--input[= ]+[^[:space:]]+' | head -n1 | sed -E 's/--input[= ]+//; s/^["'"'"']//; s/["'"'"']$//' || true)
  if [ -n "$f" ] && [ "$f" != "-" ]; then
    case "$f" in /*) ;; *) f="$CWD/$f" ;; esac
    printf '%s' "$f"
  fi
}

# Print the JSON request body: from --input FILE, or the object embedded in
# the command (heredoc / echo pipe). Prints nothing if there is none.
payload_json() {
  local f json m
  f=$(input_file)
  if [ -n "$f" ] && [ -f "$f" ]; then
    jq -c 'select(type == "object")' "$f" 2>/dev/null && return 0
  fi
  local re='\{[[:space:]]*"'
  if [[ $COMMAND =~ $re ]]; then
    m=${BASH_REMATCH[0]}
    json="$m${COMMAND#*"$m"}"
    json="${json%\}*}}"
    printf '%s' "$json" | jq -c 'select(type == "object")' 2>/dev/null && return 0
  fi
  return 0
}

# ---------------------------------------------------------------- 1. gh pr review
if printf '%s' "$COMMAND" | grep -qE "$PR_REVIEW_RE"; then
  TEXT="$COMMAND"
  BODY_FILE=$(printf '%s' "$COMMAND" | grep -oE -- '(--body-file|-F)[= ]+[^[:space:]]+' | head -n1 | sed -E 's/^(--body-file|-F)[= ]+//; s/^["'"'"']//; s/["'"'"']$//' || true)
  if [ -n "$BODY_FILE" ] && [ "$BODY_FILE" != "-" ]; then
    case "$BODY_FILE" in /*) ;; *) BODY_FILE="$CWD/$BODY_FILE" ;; esac
    [ -f "$BODY_FILE" ] && TEXT="$TEXT
$(cat "$BODY_FILE")"
  fi
  check_body "$TEXT" "$MAX_COMMAND_CHARS" "this gh pr review command (body included)"
  exit 0
fi

# ---------------------------------------------------------------- gh api reviews
if ! printf '%s' "$COMMAND" | grep -qE "$API_RE"; then
  exit 0
fi

IS_CREATE=0
IS_EVENTS=0
printf '%s' "$COMMAND" | grep -qE "$EVENTS_RE" && IS_EVENTS=1
if [ "$IS_EVENTS" -eq 0 ] && printf '%s' "$COMMAND" | grep -qE "$CREATE_RE"; then
  IS_CREATE=1
fi
[ "$IS_CREATE" -eq 1 ] || [ "$IS_EVENTS" -eq 1 ] || exit 0

# Only writes matter. gh defaults to POST once any body flag is present.
METHOD=$(printf '%s' "$COMMAND" | grep -oiE -- '(-X|--method)[= ]+[A-Za-z]+' | head -n1 | sed -E 's/^(-X|--method)[= ]+//' | tr '[:lower:]' '[:upper:]' || true)
if [ -z "$METHOD" ]; then
  if printf '%s' "$COMMAND" | grep -qE -- '[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
    METHOD=POST
  else
    METHOD=GET
  fi
fi
[ "$METHOD" = "POST" ] || exit 0

JSON=$(payload_json || true)
if [ -n "$JSON" ]; then
  EVENT=$(printf '%s' "$JSON" | jq -r '.event // ""')
  BODY=$(printf '%s' "$JSON" | jq -r '.body // ""')
  COMMIT=$(printf '%s' "$JSON" | jq -r '.commit_id // ""')
  N_BAD=$(printf '%s' "$JSON" | jq '[(.comments // [])[] | select(
      (.path // "") == "" or (.line == null) or ((.side // "") | IN("LEFT", "RIGHT") | not)
      or ((.body // "") == "") or (.position != null))] | length')
  BODY_LIMIT=$MAX_BODY_CHARS
else
  # Flat -f/-F fields: cannot carry an inline comments array, and the body
  # is shell-quoted, so measure the whole command instead.
  EVENT=""
  printf '%s' "$COMMAND" | grep -qE -- '(-f|-F|--field|--raw-field)[ =]+["'"'"']?event=' && EVENT="(set)"
  BODY="$COMMAND"
  COMMIT=""
  printf '%s' "$COMMAND" | grep -qE -- '(-f|-F|--field|--raw-field)[ =]+["'"'"']?commit_id=' && COMMIT="(set)"
  N_BAD=0
  BODY_LIMIT=$MAX_COMMAND_CHARS
fi

# ---------------------------------------------------------------- 2. create
if [ "$IS_CREATE" -eq 1 ]; then
  if [ -n "$EVENT" ]; then
    deny "Review guard: this call creates the review with an event ($EVENT), which submits it immediately and skips the preview. Create it pending (no event field) with the inline comments, show the user the exact comments, then submit with POST .../reviews/ID/events. A review with no inline comments and a long body is exactly the mistake this prevents. $POINTER"
  fi
  check_body "$BODY" "$BODY_LIMIT" "the review body"
  if [ -z "$COMMIT" ]; then
    deny "Review guard: no commit_id. Anchor the review to the PR head commit (gh pr view N --json headRefOid) so the inline comments land on the lines you verified. $POINTER"
  fi
  if [ "$N_BAD" -gt 0 ]; then
    deny "Review guard: $N_BAD inline comment(s) are missing path, line, side (LEFT or RIGHT) or body, or use the diff-relative position field. Use repo line numbers in the PR head commit with side RIGHT for added/context lines and LEFT for removed lines. $POINTER"
  fi
  exit 0
fi

# ---------------------------------------------------------------- 3. submit
check_body "$BODY" "$BODY_LIMIT" "the review summary body"

PREFIX=$(printf '%s' "$COMMAND" | grep -oE "$EVENTS_RE" | head -n1 | sed -E 's@/events.*$@@')
REVIEW_ID=${PREFIX##*/}
MARKER="$STATE_DIR/$REVIEW_ID"

hash_stdin() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

if [ ! -f "$MARKER" ]; then
  deny "Review guard: review $REVIEW_ID has no preview marker, so the exact comments have not been shown to the user yet. Show the verdict, summary and every inline comment (file, line, severity) in chat, run 'bash scripts/mark-preview.sh OWNER/REPO PR $REVIEW_ID' from the give-pr-review skill, wait for the user's go-ahead, then submit."
fi

cd "$CWD"
# Keep in sync with scripts/mark-preview.sh.
CURRENT=$(gh api --paginate "${PREFIX#/}/comments" 2>/dev/null | jq -c '.[] | {path, line, side, commit_id, body}' | hash_stdin) || CURRENT=""
if [ -z "$CURRENT" ]; then
  deny "Review guard: could not read the pending comments of review $REVIEW_ID to compare them with the previewed ones. Check gh auth and that the review is still pending, then retry."
fi
if [ "$CURRENT" != "$(cat "$MARKER")" ]; then
  deny "Review guard: the pending review $REVIEW_ID changed after its preview was shown. Re-run 'bash scripts/mark-preview.sh OWNER/REPO PR $REVIEW_ID', show the user the updated comments, and wait for their go-ahead."
fi
exit 0
