#!/bin/bash
# PreToolUse hook: before a PR is opened against the repo's pre-prod branch,
# pre-check for merge conflicts against its latest tip rather than letting
# the PR get opened and discovered as blocked later. See the
# staging-conflict-resolution skill for what to do when this denies.
#
# Branch names are NOT canonical across repos (main/master, staging/stage/
# develop/dev/preprod/prod all show up in the wild), so this never
# hardcodes a name. It reads whatever --base value the command actually
# passed, compares it against the repo's real default branch, and only
# runs the conflict check when --base is something other than that
# default - i.e. treats "not the production branch" as "this is a
# pre-prod/staging deploy" regardless of what it's actually called.
set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

BASE_BRANCH=$(printf '%s' "$COMMAND" | grep -oE -- '--base[= ]+[^ ]+' | sed -E 's/--base[= ]+//' | head -n1 || true)
if [ -z "$BASE_BRANCH" ]; then
  # No explicit --base - gh will target the repo's default branch, which is
  # the production line, not a pre-prod deploy. Nothing to pre-check.
  exit 0
fi

cd "$CWD"

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed -E 's@^refs/remotes/origin/@@' || true)
fi

if [ -n "$DEFAULT_BRANCH" ] && [ "$BASE_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # This PR targets the production branch directly, not a pre-prod branch.
  exit 0
fi

HEAD_BRANCH=$(printf '%s' "$COMMAND" | grep -oE -- '--head[= ]+[^ ]+' | sed -E 's/--head[= ]+//' | head -n1 || true)
if [ -z "$HEAD_BRANCH" ]; then
  HEAD_BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

git fetch origin "$BASE_BRANCH" --quiet >/dev/null 2>&1 || true

MERGE_OUTPUT=$(git merge-tree --write-tree "origin/$BASE_BRANCH" "$HEAD_BRANCH" 2>&1 || true)

if printf '%s' "$MERGE_OUTPUT" | grep -q "CONFLICT"; then
  REASON=$(printf 'Pre-staging-conflict-check: origin/%s has diverged and conflicts with "%s". Do not open this PR from this branch.\n\nFollow the staging-conflict-resolution skill instead: branch conflicts/<ticket>-<slug> off origin/%s, merge %s into it, resolve the conflicts there, and open the PR against %s from that branch.\n\n--- git merge-tree output ---\n%s' "$BASE_BRANCH" "$HEAD_BRANCH" "$BASE_BRANCH" "$HEAD_BRANCH" "$BASE_BRANCH" "$MERGE_OUTPUT")

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
