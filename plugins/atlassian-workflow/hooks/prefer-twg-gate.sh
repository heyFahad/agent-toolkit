#!/bin/bash
# PreToolUse hook: blocks Atlassian MCP tools (Jira, Confluence, Teamwork
# Graph) when the twg CLI is installed, so `twg` is the one route to Atlassian
# data in Claude Code. See the prefer-twg-cli skill for why. The MCP server
# usually stays connected because it's a claude.ai connector that's meant for
# claude.ai sessions, so a skill asking nicely isn't enough: an agent that
# hasn't loaded the skill sees getJiraIssue in its tool list and calls it.
#
# Decision:
#   - not an Atlassian MCP tool                       -> allow (no output)
#   - AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP=1             -> allow (opt-out)
#   - twg not installed                               -> allow (MCP is the fallback)
#   - twg installed and `twg whoami` succeeds         -> deny, name the twg command
#   - twg installed but `twg whoami` fails            -> deny, ask for a re-login
#
# The last case is deliberate: a silent fallback to the MCP when twg's login
# lapses is exactly how the MCP keeps getting used. A successful whoami is
# cached for a few minutes so a burst of calls doesn't pay ~1s each.
#
# Atlassian tools are recognised by name rather than by server, because the
# server name of a claude.ai connector is an opaque per-account id. A tool is
# Atlassian if its name mentions Jira, Confluence, Atlassian, Loom or the
# Teamwork Graph, if its server name mentions atlassian, or if its input
# carries a `cloudId` (an Atlassian-only concept, which catches the generic
# discover/executeRead/executeWrite names). A generic `search`/`fetch` tool on
# an opaque server with no cloudId isn't caught; that's an accepted gap.
set -euo pipefail

STATE_DIR="${AGENT_TOOLKIT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-toolkit}"
AUTH_CACHE="$STATE_DIR/twg-auth-ok"
AUTH_CACHE_MINUTES=10

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')

case "$TOOL_NAME" in mcp__*) ;; *) exit 0 ;; esac
REST=${TOOL_NAME#mcp__}
TOOL=${REST##*__}
SERVER=${REST%__*}

is_atlassian() {
  local lc_tool lc_server
  lc_tool=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
  lc_server=$(printf '%s' "$SERVER" | tr '[:upper:]' '[:lower:]')
  case "$lc_tool" in
    *jira* | *confluence* | *atlassian* | *loom* | *graphcontext* | getgraphobject | getworkactivity | getworkportfolio) return 0 ;;
  esac
  case "$lc_server" in *atlassian*) return 0 ;; esac
  [ "$(printf '%s' "$INPUT" | jq -r '.tool_input | type == "object" and has("cloudId")')" = "true" ]
}

is_atlassian || exit 0
[ "${AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP:-}" = "1" ] && exit 0

TWG=$(command -v twg 2>/dev/null || true)
if [ -z "$TWG" ] && [ -x "$HOME/.local/bin/twg" ]; then
  TWG="$HOME/.local/bin/twg"
fi
[ -n "$TWG" ] || exit 0

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

# The closest twg command for the blocked tool, where there's an obvious one.
suggestion() {
  case "$TOOL" in
    getJiraIssue | listJiraIssueComments | getJiraIssueRemoteIssueLinks)
      echo '`twg jira workitem get <KEY> --full -o json`, then read the file named under output_files.stdout (and `twg jira workitem changelog query --issue-id <KEY>` for history)' ;;
    searchJiraIssuesUsingJql) echo '`twg jira workitem query --jql "<JQL>" -o json`' ;;
    transitionJiraIssue | getTransitionsForJiraIssue)
      echo '`twg jira workitem transition --id <KEY> -o json` with no --transition-id to discover transitions, then again with --transition-id' ;;
    addCommentToJiraIssue | addOrEditJiraIssueComment) echo '`twg jira workitem comment` (see `twg help jira workitem comment`)' ;;
    editJiraIssue) echo '`twg jira workitem update --id <KEY> ...`' ;;
    createJiraIssue) echo '`twg jira workitem create ...` (see `twg help jira workitem create`)' ;;
    *Confluence*) echo '`twg confluence ...` (see `twg help describe confluence`)' ;;
    *) echo "the matching twg command (find it with \`twg help discover-skills \"<what you need>\"\`)" ;;
  esac
}

auth_cached() {
  [ -f "$AUTH_CACHE" ] && [ -n "$(find "$AUTH_CACHE" -mmin -"$AUTH_CACHE_MINUTES" 2>/dev/null)" ]
}

if auth_cached || "$TWG" whoami >/dev/null 2>&1; then
  mkdir -p "$STATE_DIR" && touch "$AUTH_CACHE" 2>/dev/null || true
  deny "prefer-twg gate: $TOOL_NAME is an Atlassian MCP tool, and the twg CLI is installed and signed in, so use twg instead: $(suggestion). Load the root \`twg\` skill and the narrowest companion (twg-jira, twg-confluence, ...) for command details. See the prefer-twg-cli skill."
fi

rm -f "$AUTH_CACHE" 2>/dev/null || true
deny "prefer-twg gate: $TOOL_NAME is an Atlassian MCP tool. The twg CLI is installed but \`twg whoami\` fails, so its login has probably lapsed. Don't fall back to the MCP silently: tell the user and ask them to run \`twg login\` (and \`twg doctor\` if that doesn't fix it), then retry with twg. If they want the MCP used anyway, they can set AGENT_TOOLKIT_ALLOW_ATLASSIAN_MCP=1 in their Claude Code settings' env."
