#!/bin/bash
# Tests for pr-chain-reminders.sh, the PostToolUse hook that tells the agent
# what comes next after it opens PRs or marks one ready.
# Run: bash plugins/git-workflow/hooks/tests/pr-chain-reminders.test.sh
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../pr-chain-reminders.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Two PATHs: one with a devstack, one without. Both keep jq and the basics.
mkdir -p "$TMP/with" "$TMP/without"
for t in jq awk grep sed tr cat; do
  p=$(command -v "$t") && ln -s "$p" "$TMP/with/$t" && ln -s "$p" "$TMP/without/$t"
done
printf '#!/bin/sh\n' >"$TMP/with/devstack"
chmod +x "$TMP/with/devstack"

pass=0 fail=0
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "      expected: $2"
    echo "      actual:   $3"
  fi
}

# remind CMD [with|without]: the additionalContext, or "none".
remind() {
  local out
  out=$(jq -n --arg c "$1" '{hook_event_name: "PostToolUse", cwd: "/", tool_input: {command: $c}}' |
    PATH="$TMP/${2:-without}" /bin/bash "$HOOK")
  if [ -z "$out" ]; then
    echo none
  else
    printf '%s' "$out" | jq -r 'if .hookSpecificOutput.hookEventName == "PostToolUse" then .hookSpecificOutput.additionalContext else "bad event" end'
  fi
}

CHECK_PR="Once every PR for this change is open (the main PR and its pre-prod PR, or the stack's PRs), run the check-pr skill on them. Don't stop to ask the user first."
DEVSTACK="Next: run devstack down, then the branch-cleanup skill."
CLEANUP="Next: run the branch-cleanup skill."

check "gh pr create" "$CHECK_PR" "$(remind 'gh pr create --draft --base main --fill')"
check "gh pr new after cd" "$CHECK_PR" "$(remind 'cd repo && gh pr new --draft')"
check "gh stack submit" "$CHECK_PR" "$(remind 'gh stack submit')"
check "gh pr ready with devstack" "$DEVSTACK" "$(remind 'gh pr ready 7' with)"
check "gh pr ready without devstack" "$CLEANUP" "$(remind 'gh pr ready 7')"
check "both in one call" "$CHECK_PR"$'\n'"$CLEANUP" "$(remind 'gh pr create --draft --fill && gh pr ready 8')"
check "gh pr -R before ready" "$CLEANUP" "$(remind 'gh pr -R o/r ready 7')"
check "gh pr ready; echo" "$CLEANUP" "$(remind 'gh pr ready;echo done')"
check "gh pr ready --undo" none "$(remind 'gh pr ready 7 --undo')"
check "git status" none "$(remind 'git status')"
check "echo gh pr create" none "$(remind 'echo gh pr create')"
check "gh pr view" none "$(remind 'gh pr view 7')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
