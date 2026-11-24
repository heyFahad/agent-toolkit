#!/bin/bash
# PreToolUse hook (Bash): makes the user confirm anything that adds the
# manually-verified label. That label says the user tested the change by hand
# on the running app, and the ready gate lets a pre-prod PR out of draft only
# with it, so it must never go on because an agent misread the user.
#
# Gated, matching the label in any case:
#   gh pr edit / gh issue edit      --add-label X (or --add-label=X), X a
#                                   comma list holding the label
#   gh pr create / gh pr new /      --label X, -l X (or --label=X)
#   gh issue create
#   gh label create <label>
#   gh api ...                      any call whose arguments mention both
#                                   `labels` and the label
#
# The decision is "ask": Claude Code shows the user its permission prompt,
# also in auto mode. bypassPermissions and dontAsk would never show it, so
# there the hook denies and hands the user the command to run themselves.
#
# A speed bump, not a proof: a GraphQL addLabelsToLabelable call passes label
# IDs, not names, and isn't caught. The check-pr skill forbids it.
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

LABEL=manually-verified
HERE=$(cd "$(dirname "$0")" && pwd)

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
MODE=$(printf '%s' "$INPUT" | jq -r '.permission_mode // ""')

# Fast path: almost no command mentions the label.
printf '%s' "$COMMAND" | grep -qi "$LABEL" || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/commands.sh
. "$HERE/lib/commands.sh"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# has_label LIST: LIST, comma-separated, holds the label.
has_label() {
  local IFS=,
  local l
  for l in $1; do
    [ "$(lower "$l")" = "$LABEL" ] && return 0
  done
  return 1
}

# unquote VALUE: VALUE without quote characters. A token like
# --add-label="manually-verified" keeps the quotes after the = sign.
unquote() { printf '%s' "$1" | tr -d "\"'"; }

# flag_adds FLAG... : the command's arguments carry one of the flags with the
# label, as `--flag X`, `--flag=X` or, for a short flag, `-fX`.
flag_adds() {
  local j=$gh_args w f
  while [ "$j" -lt "${#words[@]}" ]; do
    w=${words[$j]}
    for f in "$@"; do
      case "$w" in
        "$f")
          has_label "$(unquote "${words[$((j + 1))]:-}")" && return 0
          ;;
        "$f"=*)
          has_label "$(unquote "${w#"$f"=}")" && return 0
          ;;
        "$f"?*)
          case "$f" in --*) ;; *) has_label "$(unquote "${w#"$f"}")" && return 0 ;; esac
          ;;
      esac
    done
    j=$((j + 1))
  done
  return 1
}

gated() { # segment
  hc_words "$1"
  [ "$i" -lt "${#words[@]}" ] || return 1
  [ "${words[$i]##*/}" = gh ] || return 1
  hc_gh_command
  case "$gh_sub" in
    "pr edit" | "issue edit") flag_adds --add-label ;;
    "pr create" | "pr new" | "issue create") flag_adds --label -l ;;
    "label create") [ "$(lower "$(unquote "${words[$gh_args]:-}")")" = "$LABEL" ] ;;
    api*)
      # The request body may be in a heredoc, which the segments leave out,
      # so look for the label in the whole command.
      printf '%s' "$1" | grep -q labels && printf '%s' "$COMMAND" | grep -qi "$LABEL"
      ;;
    *) return 1 ;;
  esac
}

HIT=false
while IFS= read -r seg; do
  if gated "$seg"; then
    HIT=true
    break
  fi
done < <(hc_segments "$COMMAND")
[ "$HIT" = true ] || exit 0

case "$MODE" in
  bypassPermissions | dontAsk)
    jq -n --arg c "$COMMAND" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: ("manually-verified needs the user'"'"'s approval, and this permission mode can'"'"'t ask. Give the user this command to run themselves:\n" + $c)}}'
    ;;
  *)
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask",
      permissionDecisionReason: "Adding manually-verified says the user tested this change by hand. Approve only if they said so in chat."}}'
    ;;
esac
exit 0
