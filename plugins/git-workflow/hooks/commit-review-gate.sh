#!/bin/bash
# PreToolUse hook: never let `git commit` run without showing the staged
# diff and forcing an explicit confirmation, no exceptions (see AGENTS.md).
set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')

cd "$CWD"

STATUS=$(git status --short 2>&1 || true)
DIFF=$(git diff --staged 2>&1 || true)

if [ -z "$STATUS" ] && [ -z "$DIFF" ]; then
  STATUS="(nothing staged or changed)"
fi

# Soft atomicity nudge: atomicity itself is a judgment call this hook can't
# make, but a diff that spans many unrelated top-level directories is worth
# flagging for a second look before committing everything as one change.
ATOMICITY_NOTE=""
TOP_LEVEL_DIRS=$(git diff --staged --name-only 2>/dev/null | awk -F/ 'NF>1{print $1} NF==1{print "(root)"}' | sort -u | wc -l | tr -d ' ')
if [ -n "$TOP_LEVEL_DIRS" ] && [ "$TOP_LEVEL_DIRS" -gt 4 ]; then
  ATOMICITY_NOTE=$(printf '\n\nNote: staged changes span %s different top-level paths. Worth double-checking this is one logical change and not several that should be split into separate commits (see the commit-message-conventions skill).' "$TOP_LEVEL_DIRS")
fi

REASON=$(printf 'Commit review gate: never run "git commit" without showing staged files and getting explicit go-ahead first, no exceptions, even in auto-mode or a /loop.\n\n--- git status --short ---\n%s\n\n--- git diff --staged ---\n%s%s' "$STATUS" "$DIFF" "$ATOMICITY_NOTE")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $reason
  }
}'
