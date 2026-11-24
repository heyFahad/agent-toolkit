#!/bin/bash
# PreToolUse hook: before running a package-manager install/add/update
# command, check which lockfile is actually committed on the current branch
# and deny if it doesn't match the manager being invoked. A migration to a
# different package manager may exist only on a separate, unmerged branch,
# so a stated tooling convention (AGENTS.md, README) isn't enough on its own.
set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# Only fire on install-family subcommands of npm/pnpm/yarn.
MANAGER=""
if printf '%s' "$COMMAND" | grep -qE '\bnpm\b.*\b(install|i|ci|add|update|up)\b'; then
  MANAGER="npm"
  EXPECTED_LOCKFILE="package-lock.json"
elif printf '%s' "$COMMAND" | grep -qE '\bpnpm\b.*\b(install|add|update|up)\b'; then
  MANAGER="pnpm"
  EXPECTED_LOCKFILE="pnpm-lock.yaml"
elif printf '%s' "$COMMAND" | grep -qE '\byarn\b.*\b(install|add|up|upgrade)\b'; then
  MANAGER="yarn"
  EXPECTED_LOCKFILE="yarn.lock"
fi

if [ -z "$MANAGER" ]; then
  exit 0
fi

cd "$CWD"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

COMMITTED_LOCKFILES=$(git ls-tree -r HEAD --name-only 2>/dev/null | grep -iE '(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock)$' || true)

if [ -z "$COMMITTED_LOCKFILES" ]; then
  # No lockfile committed yet (new repo) - nothing to verify against.
  exit 0
fi

if printf '%s' "$COMMITTED_LOCKFILES" | grep -q "$EXPECTED_LOCKFILE"; then
  exit 0
fi

REASON=$(printf 'Lockfile verification gate: this branch has %s committed, not %s. Running a %s command here can convert node_modules/package.json to the wrong layout and break the test runner (seen before: a jest/jest-mock version mismatch after an out-of-place "pnpm add"). Confirm which manager this branch actually uses before proceeding: a migration to a different manager may exist only on a separate, unmerged branch.\n\n--- committed lockfiles (git ls-tree -r HEAD) ---\n%s' "$COMMITTED_LOCKFILES" "$EXPECTED_LOCKFILE" "$MANAGER" "$COMMITTED_LOCKFILES")

jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
