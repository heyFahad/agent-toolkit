#!/bin/bash
# PostToolUse hook (Bash): tells the agent what comes next in the PR chain,
# so it carries on instead of stopping for the user.
#
#   after gh pr create, gh pr new,   run check-pr once every PR for the
#   gh stack submit                  change is open
#   after gh pr ready (not --undo)   devstack down (when installed), then
#                                    branch-cleanup
#
# PostToolUse runs only when the command succeeded (a failed one fires
# PostToolUseFailure instead), so a failed gh pr create brings no reminder.
# It reads only the command.
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

HERE=${BASH_SOURCE[0]%/*}
COMMAND=$(jq -r '.tool_input.command // ""')

# Fast path: almost no command opens or readies a PR.
printf '%s' "$COMMAND" | grep -qE '(create|new|submit|ready)' || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/commands.sh
. "$HERE/lib/commands.sh"

OPENED=false READIED=false
while IFS= read -r seg; do
  hc_words "$seg"
  [ "$i" -lt "${#words[@]}" ] || continue
  [ "${words[$i]##*/}" = gh ] || continue
  hc_gh_command
  case "$gh_sub" in
    "pr create" | "pr new" | "stack submit") OPENED=true ;;
    "pr ready")
      undo=false
      for w in "${words[@]:$gh_args}"; do [ "$w" != --undo ] || undo=true; done
      [ "$undo" = true ] || READIED=true
      ;;
  esac
done < <(hc_segments "$COMMAND")

TEXT=""
add() { TEXT="${TEXT:+$TEXT$'\n'}$1"; }
[ "$OPENED" = false ] || add "Once every PR for this change is open (the main PR and its pre-prod PR, or the stack's PRs), run the check-pr skill on them. Don't stop to ask the user first."
if [ "$READIED" = true ]; then
  if command -v devstack >/dev/null 2>&1; then
    add "Next: run devstack down, then the branch-cleanup skill."
  else
    add "Next: run the branch-cleanup skill."
  fi
fi
[ -n "$TEXT" ] || exit 0
jq -n --arg t "$TEXT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $t}}'
