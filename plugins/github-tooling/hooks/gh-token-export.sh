#!/bin/bash
# PreToolUse hook: macOS's Keychain-backed `gh` credential can fail to
# propagate through an extra process boundary when a script/skill/plugin
# shells out to `gh` from inside its own subprocess. That makes `gh`
# behave as effectively unauthenticated and GitHub returns 404 (not 401)
# for private-repo calls - a real auth-propagation bug that reads like a
# permissions or path bug. This heuristically catches commands that look
# like they invoke a nested wrapper script rather than calling `gh`
# directly, and requires GH_TOKEN to already be exported inline.
#
# This is a heuristic, not exhaustive - it cannot know every possible
# wrapper script's internals. A direct `gh ...` call is always allowed
# through untouched.
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Direct `gh` invocation (optionally prefixed with env var assignments) - fine as-is.
if printf '%s' "$COMMAND" | grep -qE '^\s*([A-Za-z_][A-Za-z0-9_]*=\S+\s+)*gh\s'; then
  exit 0
fi

# GH_TOKEN already exported inline for this command - fine as-is.
if printf '%s' "$COMMAND" | grep -q 'GH_TOKEN='; then
  exit 0
fi

# Heuristic: looks like a nested script/wrapper invocation that plausibly
# shells out to `gh` on its own (a .sh script, an explicit shell
# invocation, a path under a skills/plugins directory, or a known
# third-party wrapper like gh-stack). Not exhaustive - any other wrapper
# script name it doesn't recognize will simply pass through unchecked.
if printf '%s' "$COMMAND" | grep -qE '(\.sh\b|^\s*(bash|sh|zsh)\s|/skills/|/plugins/|gh-stack)'; then
  REASON='GH_TOKEN export check: this command looks like it invokes a script that may shell out to `gh` from its own subprocess. macOS Keychain-backed `gh` auth can silently fail to propagate through that extra process boundary, producing a `404` that reads like a permissions bug. Prefix this command with `GH_TOKEN=$(gh auth token)` in the same shell invocation before retrying.'

  jq -n --arg reason "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
else
  exit 0
fi
