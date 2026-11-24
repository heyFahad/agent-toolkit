#!/bin/bash
# Tests for label-gate.sh. No git or gh needed: the hook reads only the
# command and the permission mode.
# Run: bash plugins/git-workflow/hooks/tests/label-gate.test.sh
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../label-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# decision CMD [MODE]: the hook's permissionDecision, "none" when it printed
# nothing, or "exit N" when it exited non-zero.
decision() {
  local out code
  out=$(jq -n --arg c "$1" --arg m "${2:-default}" '{cwd: "/", permission_mode: $m, tool_input: {command: $c}}' |
    bash "$HOOK" 2>"$TMP/stderr")
  code=$?
  printf '%s' "$out" >"$TMP/out"
  if [ "$code" -ne 0 ]; then
    echo "exit $code"
  elif [ -z "$out" ]; then
    echo none
  else
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'
  fi
}

ADD='gh pr edit 12 --add-label manually-verified'

check "add-label asks" ask "$(decision "$ADD")"
check "comma list, other case, asks" ask "$(decision 'gh pr edit 12 --add-label bug,Manually-Verified')"
check "--add-label= asks" ask "$(decision 'gh pr edit 12 --add-label=manually-verified')"
check "second --add-label asks" ask "$(decision 'gh pr edit 12 --add-label bug --add-label manually-verified')"
check "quoted label asks" ask "$(decision 'gh pr edit 12 --add-label "manually-verified"')"
check "issue edit asks" ask "$(decision 'gh issue edit 12 --add-label manually-verified')"
check "create then add, one decision" ask "$(decision 'gh label create manually-verified --color 0e8a16 2>/dev/null; gh pr edit 12 --add-label manually-verified')"
check "label create alone asks" ask "$(decision 'gh label create Manually-Verified')"
check "pr create with --label asks" ask "$(decision 'cd repo && gh pr create --draft --label manually-verified')"
check "pr create with -l asks" ask "$(decision 'gh pr create -l bug,manually-verified --fill')"
check "pr new with --label= asks" ask "$(decision 'gh pr new --label=manually-verified')"
check "gh api labels endpoint asks" ask "$(decision "gh api repos/o/r/issues/12/labels -f 'labels[]=manually-verified'")"
check "env wrapper asks" ask "$(decision "env GH_HOST=github.com $ADD")"
check "full path to gh asks" ask "$(decision "/opt/homebrew/bin/$ADD")"
check "line continuation asks" ask "$(decision $'gh pr edit 12 \\\n  --add-label manually-verified')"

check "quoted --add-label= value asks" ask "$(decision 'gh pr edit 5 --add-label="manually-verified"')"
check "single-quoted --add-label= value asks" ask "$(decision "gh pr edit 5 --add-label='manually-verified'")"
check "attached -l value asks" ask "$(decision 'gh pr create -lmanually-verified')"
check "-R before the verb asks" ask "$(decision 'gh pr -R o/r edit 5 --add-label manually-verified')"
check "--repo= before the verb asks" ask "$(decision 'gh issue --repo=o/r edit 5 --add-label manually-verified')"
check "gh api body in a heredoc asks" ask "$(decision $'gh api repos/o/r/issues/5/labels --input - <<EOF\n{"labels":["manually-verified"]}\nEOF')"

check "quoted list with a space asks" ask "$(decision 'gh pr edit 5 --add-label "help wanted,manually-verified"')"
check "single-quoted list, space after comma, asks" ask "$(decision "gh pr edit 5 --add-label 'help wanted, Manually-Verified'")"
check "--label= quoted list asks" ask "$(decision 'gh pr create --label="needs review,manually-verified"')"
check "-l quoted list asks" ask "$(decision 'gh pr create -l "a b,manually-verified" --fill')"
check "quoted other label, then remove passes" none "$(decision 'gh pr edit 5 --add-label "help wanted" --remove-label manually-verified')"

check "remove-label passes" none "$(decision 'gh pr edit 12 --remove-label manually-verified')"
check "another label passes" none "$(decision 'gh pr edit 12 --add-label bug')"
check "echo passes" none "$(decision "echo \"$ADD\"")"
check "heredoc body passes" none "$(decision $'git commit -F - <<\'EOF\'\nRun gh pr edit 12 --add-label manually-verified later\nEOF')"
check "reading labels passes" none "$(decision 'gh pr view 12 --json labels | grep manually-verified')"
check "unrelated command passes" none "$(decision 'git status')"
check "gh api without labels passes" none "$(decision 'gh api repos/o/r/pulls/12 --jq .title # manually-verified')"

check "reason says what approving means" true \
  "$(decision "$ADD" >/dev/null; jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out" | grep -q 'tested this change by hand' && echo true || echo false)"

for mode in bypassPermissions dontAsk; do
  check "$mode denies" deny "$(decision "$ADD" "$mode")"
  check "$mode reason holds the command" true \
    "$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$TMP/out" | grep -qF "$ADD" && echo true || echo false)"
done
check "acceptEdits still asks" ask "$(decision "$ADD" acceptEdits)"
check "auto mode still asks" ask "$(decision "$ADD" auto)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
