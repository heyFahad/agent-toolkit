#!/bin/bash
# PreToolUse hook: on GitHub-native surfaces (PR/issue comments, review
# replies, PR/issue descriptions, Discussions), GitHub auto-shortens a bare
# github.com URL/SHA/#-reference into a real clickable link - but only if
# it's pasted bare. Wrapping it in backticks defeats the autolinker
# (confirmed by PATCHing a live PR review comment and reading back its
# body_html). This exists because that exact mistake has actually happened.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only fire on gh subcommands that write a comment/review/PR-or-issue body.
if ! printf '%s' "$COMMAND" | grep -qE '\bgh\s+(pr|issue)\s+(comment|review|create|edit)\b|\bgh\s+api\b.*/(comments|reviews)\b'; then
  exit 0
fi

MATCHES=$(printf '%s' "$COMMAND" | grep -oE '`https?://github\.com/[^`]+`|`[0-9a-f]{7,40}`|`#[0-9]+( \(comment\))?`' || true)

if [ -z "$MATCHES" ]; then
  exit 0
fi

REASON=$(printf 'GitHub comment formatting gate: found a backtick-wrapped GitHub reference in this command. On GitHub-native surfaces (PR/issue comments, review replies, PR/issue descriptions, Discussions), paste the bare github.com URL/SHA/#-reference instead - GitHub auto-shortens it into a real clickable link, but only if it is not wrapped in backticks (its autolinker skips code spans). See the github-native-writing skill.\n\n--- flagged references ---\n%s' "$MATCHES")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
