#!/bin/bash
# PreToolUse hook: before a PR is opened against the repo's pre-prod branch,
# check two things against that branch's latest tip, rather than letting the
# PR get opened and found broken later. See the clean-preprod-pr
# skill for what to do when this denies.
#
#   1. Merge conflicts (git merge-tree).
#   2. A noisy diff. The default branch is squash-merged, and back-merges
#      from it into pre-prod don't always happen. A feature branch cut from
#      the default branch then carries the squash commits that pre-prod has
#      only in their original form, so a PR from it lists those files too,
#      even though pre-prod already has that content. A PR from a
#      conflicts/... branch cut from pre-prod shows only the feature's files.
#
#      A back-merge PR whose head is the default branch itself hits the same
#      thing, worse: it lists every squash commit since the last back-merge,
#      though pre-prod has nearly all of that content already. For that head
#      the check compares the files the PR would list with the files the
#      merge would actually change, and denies when the first has more. The
#      back-merge then goes out from conflicts/backmerge-<release>.
#
# Branch names are not canonical across repos, so nothing is hardcoded: the
# default branch comes from gh/git, and the pre-prod branch from the
# resolver script shipped with the branching-pr-workflow skill.
#
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RESOLVER="${AGENT_TOOLKIT_PREPROD_RESOLVER:-$HERE/../skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh}"
LONG_LIVED_NAMES="dev develop development staging stage preprod pre-prod qa uat"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "."')
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

# hooks.json's "if" is a fast-path only. This script is the authority: it
# must not run gh/git network calls for an unrelated Bash call.
if ! printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
  exit 0
fi

# Value of a flag given as "--long value", "--long=value" or "-S value",
# with surrounding quotes removed.
flag_value() { # long, short
  printf '%s' "$COMMAND" \
    | grep -oE -- "(--$1[= ]+|(^|[[:space:]])-$2[[:space:]]+)[^[:space:]]+" \
    | head -n1 \
    | sed -E "s/^[[:space:]]*(--$1[= ]+|-$2[[:space:]]+)//; s/^[\"']//; s/[\"']$//" \
    || true
}

BASE_BRANCH=$(flag_value base B)
if [ -z "$BASE_BRANCH" ]; then
  # No explicit base: gh targets the default branch, the production line.
  exit 0
fi

cd "$CWD"

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed -E 's@^refs/remotes/origin/@@' || true)
fi

if [ -n "$DEFAULT_BRANCH" ] && [ "$BASE_BRANCH" = "$DEFAULT_BRANCH" ]; then
  exit 0
fi

# Only the pre-prod branch gets checked. A PR into anything else (a stacked
# subtask into its trunk, say) is none of this hook's business. When the
# resolver can't decide, fall back to treating any long-lived-looking name
# as pre-prod rather than skipping the check.
PREPROD_BRANCH=""
if [ -x "$RESOLVER" ] || [ -f "$RESOLVER" ]; then
  PREPROD_BRANCH=$(bash "$RESOLVER" 2>/dev/null || true)
fi
if [ -n "$PREPROD_BRANCH" ]; then
  [ "$BASE_BRANCH" = "$PREPROD_BRANCH" ] || exit 0
else
  case " $LONG_LIVED_NAMES " in
    *" $BASE_BRANCH "*) ;;
    *) exit 0 ;;
  esac
fi

HEAD_BRANCH=$(flag_value head H)
HEAD_BRANCH="${HEAD_BRANCH##*:}" # "owner:branch" form
if [ -z "$HEAD_BRANCH" ]; then
  HEAD_BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

git fetch origin "$BASE_BRANCH" --quiet >/dev/null 2>&1 || true
[ -n "$DEFAULT_BRANCH" ] && { git fetch origin "$DEFAULT_BRANCH" --quiet >/dev/null 2>&1 || true; }
git fetch origin "$HEAD_BRANCH" --quiet >/dev/null 2>&1 || true

# What the PR's head actually is: gh pushes nothing itself, so the remote
# copy is what GitHub will diff. Prefer it, fall back to the local branch.
HEAD_REF="$HEAD_BRANCH"
if git rev-parse --verify -q "refs/remotes/origin/$HEAD_BRANCH" >/dev/null; then
  HEAD_REF="origin/$HEAD_BRANCH"
fi
if ! git rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null || ! git rev-parse --verify -q "origin/$BASE_BRANCH^{commit}" >/dev/null; then
  exit 0
fi

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

BACK_MERGE=false
if [ -n "$DEFAULT_BRANCH" ] && [ "$HEAD_BRANCH" = "$DEFAULT_BRANCH" ]; then
  BACK_MERGE=true
fi

MERGE_OUTPUT=$(git merge-tree --write-tree "origin/$BASE_BRANCH" "$HEAD_REF" 2>&1 || true)
if printf '%s' "$MERGE_OUTPUT" | grep -q "CONFLICT"; then
  if [ "$BACK_MERGE" = true ]; then
    SUGGESTED_BRANCH="conflicts/backmerge-<release>"
    MERGE_SOURCE="origin/$DEFAULT_BRANCH"
  else
    SUGGESTED_BRANCH="conflicts/<ticket>-<slug>"
    MERGE_SOURCE="$HEAD_BRANCH"
  fi
  deny "$(printf 'Preprod-pr-check: origin/%s has diverged and conflicts with "%s". Do not open this PR from this branch.\n\nFollow the clean-preprod-pr skill instead: branch %s off origin/%s, merge %s into it, resolve the conflicts there, and open the PR against %s from that branch.\n\n--- git merge-tree output ---\n%s' "$BASE_BRANCH" "$HEAD_BRANCH" "$SUGGESTED_BRANCH" "$BASE_BRANCH" "$MERGE_SOURCE" "$BASE_BRANCH" "$MERGE_OUTPUT")"
fi

# A branch already cut from pre-prod (conflicts/...) is the remedy itself.
case "$HEAD_BRANCH" in
  conflicts/*) exit 0 ;;
esac
if [ -z "$DEFAULT_BRANCH" ] || ! git rev-parse --verify -q "origin/$DEFAULT_BRANCH^{commit}" >/dev/null; then
  exit 0
fi

PREPROD_BASE=$(git merge-base "origin/$BASE_BRANCH" "$HEAD_REF" 2>/dev/null || true)
[ -n "$PREPROD_BASE" ] || exit 0
# What GitHub's files tab will list: the head against its merge base.
PREPROD_FILES=$(git diff --name-only "$PREPROD_BASE" "$HEAD_REF" | sort -u)

if [ "$BACK_MERGE" = true ]; then
  # A back-merge has no "own change" to compare against. Compare with what
  # the merge would really change in pre-prod instead: the files GitHub would
  # list beyond that are content pre-prod already has.
  MERGED_TREE=$(printf '%s\n' "$MERGE_OUTPUT" | head -n1)
  git rev-parse --verify -q "$MERGED_TREE^{tree}" >/dev/null || exit 0
  REAL_FILES=$(git diff --name-only "origin/$BASE_BRANCH" "$MERGED_TREE" | sort -u)
  EXTRA_FILES=$(comm -23 <(printf '%s\n' "$PREPROD_FILES" | sed '/^$/d') <(printf '%s\n' "$REAL_FILES" | sed '/^$/d'))
  [ -n "$EXTRA_FILES" ] || exit 0

  EXTRA_COUNT=$(printf '%s\n' "$EXTRA_FILES" | wc -l | tr -d ' ')
  REAL_COUNT=$(printf '%s\n' "$REAL_FILES" | sed '/^$/d' | wc -l | tr -d ' ')
  EXTRA_SAMPLE=$(printf '%s\n' "$EXTRA_FILES" | head -n 20)
  deny "$(printf 'Preprod-pr-check: a back-merge PR straight from "%s" into %s would list %s file(s) that the merge would not change (it really changes %s file(s) in %s). %s already has their content from the original ticket commits; %s has it as squash commits that are not in %s'"'"'s history, so GitHub diffs %s against an old merge base and lists them anyway.\n\nDo not open this PR from %s. Follow the clean-preprod-pr skill: open the back-merge from a conflicts branch, whose files tab shows only what the merge really changes:\n\n  git switch -c conflicts/backmerge-<release> origin/%s\n  git merge --no-ff origin/%s\n  git push -u origin conflicts/backmerge-<release>\n\nthen open the PR against %s from that branch. Merge it with a merge commit (gh pr merge --merge), never squashed: the merge commit is what puts %s'"'"'s commits into %s'"'"'s history. Close any back-merge PR already open straight from %s.\n\n--- files the PR from %s would list but the merge would not change ---\n%s' \
    "$HEAD_BRANCH" "$BASE_BRANCH" "$EXTRA_COUNT" "$REAL_COUNT" "$BASE_BRANCH" "$BASE_BRANCH" "$HEAD_BRANCH" "$BASE_BRANCH" "$HEAD_BRANCH" \
    "$HEAD_BRANCH" \
    "$BASE_BRANCH" "$DEFAULT_BRANCH" \
    "$BASE_BRANCH" "$DEFAULT_BRANCH" "$BASE_BRANCH" "$HEAD_BRANCH" \
    "$HEAD_BRANCH" "$EXTRA_SAMPLE")"
fi

OWN_FILES=$(git diff --name-only "origin/$DEFAULT_BRANCH...$HEAD_REF" | sort -u)
EXTRA_FILES=$(comm -23 <(printf '%s\n' "$PREPROD_FILES" | sed '/^$/d') <(printf '%s\n' "$OWN_FILES" | sed '/^$/d'))

if [ -n "$EXTRA_FILES" ]; then
  EXTRA_COUNT=$(printf '%s\n' "$EXTRA_FILES" | wc -l | tr -d ' ')
  OWN_COUNT=$(printf '%s\n' "$OWN_FILES" | sed '/^$/d' | wc -l | tr -d ' ')
  EXTRA_SAMPLE=$(printf '%s\n' "$EXTRA_FILES" | head -n 20)
  deny "$(printf 'Preprod-pr-check: a PR from "%s" into %s would list %s file(s) that are not part of this branch'"'"'s own change (it changes %s file(s) against origin/%s). They come from %s commits that origin/%s does not have yet, usually squash merges that were never back-merged, so the PR would show them even where %s already has the same content.\n\nDo not open this PR from this branch, and do not cherry-pick. Follow the clean-preprod-pr skill: branch conflicts/<ticket>-<slug> off origin/%s, merge %s into it (git merge, not a rebase or cherry-pick), push it, and open the PR against %s from that branch. Its files tab then shows only this branch'"'"'s changes.\n\nAlso check for an open back-merge PR into %s (head %s or conflicts/backmerge-*): gh pr list --base %s --state open --json number,headRefName. If there is none, offer the user to open one from conflicts/backmerge-<release> as the clean-preprod-pr skill describes, not straight from %s. It must be merged with a merge commit (gh pr merge --merge), never squashed, or the noise stays.\n\n--- files only the %s PR would show ---\n%s' \
    "$HEAD_BRANCH" "$BASE_BRANCH" "$EXTRA_COUNT" "$OWN_COUNT" "$DEFAULT_BRANCH" "$DEFAULT_BRANCH" "$BASE_BRANCH" "$BASE_BRANCH" \
    "$BASE_BRANCH" "$HEAD_BRANCH" "$BASE_BRANCH" \
    "$BASE_BRANCH" "$DEFAULT_BRANCH" "$BASE_BRANCH" "$DEFAULT_BRANCH" \
    "$BASE_BRANCH" "$EXTRA_SAMPLE")"
fi

exit 0
