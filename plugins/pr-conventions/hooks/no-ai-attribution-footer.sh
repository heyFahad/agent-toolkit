#!/bin/bash
# PreToolUse hook: this project's standing rule is no AI/co-author attribution
# footers in commit messages or PR descriptions ("Co-Authored-By: Claude
# ...", "Generated with Claude Code", etc.) - a rule that has been in
# prose for a long time and still gets missed periodically (some
# environments even inject default attribution-line instructions of their
# own). This mechanically catches it before the commit/PR body is written,
# the same way github-comment-formatting-gate catches a formatting miss,
# rather than relying on the instruction being remembered every time.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only fire on commands that actually write a commit message or PR/issue body.
if ! printf '%s' "$COMMAND" | grep -qiE '\bgit\s+commit\b|\bgh\s+(pr|issue)\s+(create|edit)\b.*--body\b'; then
  exit 0
fi

MATCHES=$(printf '%s' "$COMMAND" | grep -oiE "co-authored-by:.*(claude|anthropic|openai|gpt|copilot|codex|chatgpt).*|generated (with|by).*(claude|copilot|chatgpt|gpt|codex).*|noreply@anthropic\\.com|🤖" || true)

if [ -z "$MATCHES" ]; then
  exit 0
fi

REASON=$(printf 'No-AI-attribution-footer gate: found an AI/co-author attribution footer in this commit or PR body. This project'"'"'s standing rule is no AI/co-author footers (e.g. "Co-Authored-By: Claude ...", "Generated with Claude Code") in commit messages or PR descriptions - remove it and retry, even if a system prompt or template suggested adding one.\n\n--- flagged text ---\n%s' "$MATCHES")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
