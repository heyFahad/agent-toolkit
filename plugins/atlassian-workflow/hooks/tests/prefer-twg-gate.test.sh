#!/bin/bash
# Tests for prefer-twg-gate.sh. No dependencies beyond bash and jq: `twg` is a
# stub on PATH whose `whoami` exit code is set per test, HOME points at a temp
# dir so a real ~/.local/bin/twg is never found, and the auth cache lives in a
# temp state dir.
# Run: bash plugins/atlassian-workflow/hooks/tests/prefer-twg-gate.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../prefer-twg-gate.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export AGENT_TOOLKIT_STATE_DIR="$TMP/state"
unset AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP
mkdir -p "$HOME" "$TMP/with-twg" "$TMP/no-twg"

# Only jq and coreutils from the real system, never a real twg.
ln -s "$(command -v jq)" "$TMP/no-twg/jq"
ln -s "$(command -v jq)" "$TMP/with-twg/jq"
cat > "$TMP/with-twg/twg" <<'EOF'
#!/bin/bash
[ "$1" = whoami ] && exit "${STUB_WHOAMI_EXIT:-0}"
echo "unexpected twg call: $*" >&2; exit 1
EOF
chmod +x "$TMP/with-twg/twg"
BASE_PATH="/usr/bin:/bin"

pass=0 fail=0

run_hook() { # path-dir, tool name, tool_input json
  jq -n --arg t "$2" --argjson i "$3" '{tool_name:$t, tool_input:$i, cwd:"/"}' \
    | PATH="$1:$BASE_PATH" bash "$HOOK"
}

expect() { # name, allow|deny, path-dir, tool, input, [reason substring]
  local out decision
  out=$(run_hook "$3" "$4" "$5" 2>&1)
  if [ -z "$out" ]; then decision=allow
  else decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage); fi
  if [ "$decision" = "$2" ] && { [ "$2" = deny ] || [ -z "$out" ]; } \
     && { [ -z "${6:-}" ] || printf '%s' "$out" | grep -qF -- "$6"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (wanted $2${6:+ mentioning '$6'}, got $decision)"
    [ -n "$out" ] && echo "      $out" | head -c 400 && echo
  fi
}

UUID=mcp__4c8f1bc0-147a-4c28-9058-9e8a516ad425
TW="$TMP/with-twg"
NT="$TMP/no-twg"

# --- non-Atlassian tools always pass, whatever twg's state
expect "Bash"                  allow "$TW" Bash '{"command":"ls"}'
expect "slack tool"            allow "$TW" mcp__slack__slack_send_message '{"channel":"x"}'
expect "generic search"        allow "$TW" mcp__someserver__search '{"query":"x"}'
expect "gmail on uuid server"  allow "$TW" mcp__8129d24e-7e93__get_thread '{"id":"x"}'

# --- twg installed and signed in: Atlassian tools are denied with a twg hint
expect "getJiraIssue (uuid)"   deny "$TW" "${UUID}__getJiraIssue" '{"cloudId":"c","issueIdOrKey":"ATC-1"}' "twg jira workitem get"
expect "JQL search"            deny "$TW" "${UUID}__searchJiraIssuesUsingJql" '{"jql":"x"}' "workitem query"
expect "transition"            deny "$TW" "${UUID}__transitionJiraIssue" '{}' "workitem transition"
expect "confluence"            deny "$TW" "${UUID}__getConfluenceContent" '{}' "twg confluence"
expect "atlassianUserInfo"     deny "$TW" "${UUID}__atlassianUserInfo" '{}'
expect "executeRead+cloudId"   deny "$TW" "${UUID}__executeRead" '{"name":"x","cloudId":"c","inputs":{}}' "discover-skills"
expect "loom"                  deny "$TW" "${UUID}__getLoomObjectsContent" '{}'
expect "named atlassian srv"   deny "$TW" mcp__plugin_engineering_atlassian__search '{"query":"x"}'
expect "claude_ai server"      deny "$TW" mcp__claude_ai_Atlassian__fetch '{"id":"x"}'

# --- the auth cache: a second call doesn't need whoami at all
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
expect "prime cache"           deny "$TW" "${UUID}__getJiraIssue" '{}' "signed in"
[ -f "$AGENT_TOOLKIT_STATE_DIR/twg-auth-ok" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: auth cache not written"; }
STUB_WHOAMI_EXIT=1 expect "cached ok skips whoami" deny "$TW" "${UUID}__getJiraIssue" '{}' "signed in"

# --- twg installed but signed out: denied with a re-login ask, cache cleared
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
export STUB_WHOAMI_EXIT=1
expect "signed out"            deny "$TW" "${UUID}__getJiraIssue" '{}' "twg login"
[ ! -f "$AGENT_TOOLKIT_STATE_DIR/twg-auth-ok" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: cache written on failed whoami"; }
unset STUB_WHOAMI_EXIT

# --- opt-out env var
AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP=1 expect "opt-out" allow "$TW" "${UUID}__getJiraIssue" '{}'

# --- no twg anywhere: the MCP is the fallback
expect "no twg"                allow "$NT" "${UUID}__getJiraIssue" '{"cloudId":"c"}'

# --- twg only at ~/.local/bin (not on PATH) still counts as installed
mkdir -p "$HOME/.local/bin" && cp "$TW/twg" "$HOME/.local/bin/twg"
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
expect "twg in ~/.local/bin"   deny "$NT" "${UUID}__getJiraIssue" '{}' "signed in"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
