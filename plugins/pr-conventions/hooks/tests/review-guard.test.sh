#!/bin/bash
# Tests for review-guard.sh. No dependencies beyond bash and jq: `gh` is
# replaced by a stub on PATH, and the preview marker lives in a temp dir.
# Run: bash plugins/pr-conventions/hooks/tests/review-guard.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../review-guard.sh"
MARK="$HERE/../../../../skills/give-pr-review/scripts/mark-preview.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AGENT_TOOLKIT_STATE_DIR="$TMP/state"
mkdir -p "$TMP/bin"

# Stub gh: only `gh api --paginate .../reviews/<id>/comments` is ever called.
# The fixture file decides what the "pending review" contains.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"/comments"*) cat "$STUB_COMMENTS" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_COMMENTS="$TMP/comments.json"
echo '[{"path":"a.js","line":10,"side":"RIGHT","commit_id":"abc1234def","body":"**High** x"}]' > "$STUB_COMMENTS"

pass=0 fail=0

run_hook() { jq -n --arg c "$1" --arg d "$TMP" '{tool_input:{command:$c}, cwd:$d}' | bash "$HOOK"; }

expect() { # name, allow|deny, command
  local out decision
  out=$(run_hook "$3" 2>&1)
  if [ -z "$out" ]; then decision=allow
  else decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage); fi
  if [ "$decision" = "$2" ] && { [ "$2" = deny ] || [ -z "$out" ]; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (wanted $2, got $decision)"
    [ -n "$out" ] && echo "      $out" | head -c 400 && echo
  fi
}

LONG=$(printf 'word %.0s' $(seq 1 200))
LIST=$'- one\n- two\n- three\n- four'
GOOD='{"commit_id":"abc1234","comments":[{"path":"a.js","line":10,"side":"RIGHT","body":"**High** x"}]}'

# --- read-only and unrelated commands pass
expect "gh pr view"            allow 'gh pr view 12 --repo o/r --json headRefOid'
expect "gh pr diff"            allow 'gh pr diff 12 --repo o/r'
expect "gh api GET reviews"    allow 'gh api repos/o/r/pulls/12/reviews'
expect "gh api GET files"      allow 'gh api repos/o/r/pulls/12/files --paginate'
expect "gh api DELETE review"  allow 'gh api -X DELETE repos/o/r/pulls/12/reviews/99'
expect "git commit mention"    allow 'git commit -m "docs: explain gh pr review --approve flow"'
expect "echo mention"          allow "echo 'gh api repos/o/r/pulls/1/reviews -f event=APPROVE'"
expect "unrelated api POST"    allow 'gh api repos/o/r/issues/1/comments -f body=hi'

# --- gh pr review
expect "short approve"         allow 'gh pr review 12 --repo o/r --approve --body "LGTM, nothing blocking."'
expect "short request-changes" allow 'gh pr review 12 -r -b "Blocked on the auth change, see inline."'
expect "env-prefixed short"    allow 'GH_TOKEN=x gh pr review 12 --approve -b "ok"'
expect "long body"             deny  "gh pr review 12 --request-changes --body \"$LONG\""
expect "itemised body"         deny  "gh pr review 12 --comment --body \"$LIST\""
expect "long after &&"         deny  "cd x && gh pr review 12 -c -b \"$LONG\""
echo "$LONG" > "$TMP/body.md"
expect "long body-file"        deny  "gh pr review 12 -r --body-file $TMP/body.md"
echo "Looks good." > "$TMP/short.md"
expect "short body-file"       allow "gh pr review 12 -a --body-file $TMP/short.md"

# --- creating a review
expect "pending, good"         allow "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
$GOOD
EOF"
expect "pending, echo pipe"    allow "echo '$GOOD' | gh api repos/o/r/pulls/12/reviews --input -"
expect "placeholders path"     allow "gh api repos/{owner}/{repo}/pulls/12/reviews --input - <<'EOF'
$GOOD
EOF"
expect "event on create"       deny  "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
{\"commit_id\":\"abc\",\"event\":\"APPROVE\",\"comments\":[{\"path\":\"a\",\"line\":1,\"side\":\"RIGHT\",\"body\":\"x\"}]}
EOF"
expect "event, no comments"    deny  'gh api repos/o/r/pulls/12/reviews -f event=REQUEST_CHANGES -f body=short'
expect "event via -F"          deny  'gh api -X POST repos/o/r/pulls/12/reviews -F event=COMMENT'
expect "long body on create"   deny  "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
{\"commit_id\":\"abc\",\"body\":\"$LONG\",\"comments\":[]}
EOF"
expect "no commit_id"          deny  "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
{\"comments\":[{\"path\":\"a\",\"line\":1,\"side\":\"RIGHT\",\"body\":\"x\"}]}
EOF"
expect "position not line"     deny  "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
{\"commit_id\":\"abc\",\"comments\":[{\"path\":\"a\",\"position\":4,\"body\":\"x\"}]}
EOF"
expect "missing side"          deny  "gh api repos/o/r/pulls/12/reviews --input - <<'EOF'
{\"commit_id\":\"abc\",\"comments\":[{\"path\":\"a\",\"line\":4,\"body\":\"x\"}]}
EOF"
printf '%s' "$GOOD" > "$TMP/ok.json"
printf '%s' '{"commit_id":"abc","event":"APPROVE","comments":[]}' > "$TMP/bad.json"
expect "--input file good"     allow "gh api repos/o/r/pulls/12/reviews --input $TMP/ok.json"
expect "--input file w/ event" deny  "gh api repos/o/r/pulls/12/reviews --input $TMP/bad.json"

# --- submitting
SUBMIT='gh api repos/o/r/pulls/12/reviews/777/events -f event=REQUEST_CHANGES -f body="One blocker, see inline."'
expect "submit, no marker"     deny  "$SUBMIT"
bash "$MARK" o/r 12 777 >/dev/null 2>&1
expect "submit, marked"        allow "$SUBMIT"
expect "submit, long body"     deny  "gh api repos/o/r/pulls/12/reviews/777/events -f event=COMMENT -f body=\"$LONG\""
expect "submit, other review"  deny  "${SUBMIT/777/778}"
echo '[{"path":"a.js","line":11,"side":"RIGHT","commit_id":"abc1234def","body":"edited"}]' > "$STUB_COMMENTS"
expect "submit, edited after"  deny  "$SUBMIT"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
