#!/bin/bash
# After a back-merge, lists what still separates the pre-prod branch from
# "the default branch plus unreleased work". Run it on the back-merge branch
# once `git merge --no-ff origin/<default>` is committed; see the back-merge
# skill for what to do with each finding.
#
# Usage, from inside the repo:
#   backmerge-drift-audit.sh [--merged <ref>] [--default <ref>]
#                            [--since <date>] [--ticket <regex>]
#
#   --merged   the merged pre-prod state to audit (default: HEAD)
#   --default  the default branch as released (default: origin/main)
#   --since    how far back to look for released commits (default: 90 days ago)
#   --ticket   extended regex for ticket keys in commit messages
#              (default: [A-Z][A-Z0-9]+-[0-9]+)
#
# Two reports:
#   1. Released changes missing from the merged state: non-merge commits on
#      the default branch whose change is still there but is not in the merged
#      state, with the lines that are missing. Usually a past conflict
#      resolution that took the pre-prod side. Git counts those commits as
#      merged, so no later back-merge brings them back on its own.
#   2. Differences no unreleased ticket explains: files that differ between
#      the two, where no commit touching the file on the pre-prod side names a
#      ticket the default branch has not shipped.
#
# Both are leads, not verdicts: a fix can have moved to another file, or been
# superseded by unreleased work. Check each one before acting on it.
#
# Exit codes: 0 nothing to review, 2 findings printed, 1 usage or git error.
#
# Keep this bash 3.2 compatible: it runs under macOS's /bin/bash.
set -uo pipefail

MERGED=HEAD
DEFAULT=origin/main
SINCE="90 days ago"
TICKET='[A-Z][A-Z0-9]+-[0-9]+'

while [ $# -gt 0 ]; do
  case "$1" in
    --merged) MERGED=${2:?}; shift 2 ;;
    --default) DEFAULT=${2:?}; shift 2 ;;
    --since) SINCE=${2:?}; shift 2 ;;
    --ticket) TICKET=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

git rev-parse --verify -q "$MERGED^{commit}" >/dev/null || { echo "not a commit: $MERGED" >&2; exit 1; }
git rev-parse --verify -q "$DEFAULT^{commit}" >/dev/null || { echo "not a commit: $DEFAULT" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Index files holding each tree, so `git apply --cached --check` can test a
# patch against either one without touching the working tree.
GIT_INDEX_FILE="$TMP/idx-default" git read-tree "$DEFAULT" || exit 1
GIT_INDEX_FILE="$TMP/idx-merged" git read-tree "$MERGED" || exit 1

trimmed() { # ref, path -> the file's lines, trimmed, on stdout (empty if absent)
  git show "$1:$2" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

findings=0

# --- 1. Released changes missing from the merged state
echo "== Released changes missing from $MERGED"
for c in $(git rev-list --no-merges --since="$SINCE" "$DEFAULT"); do
  git diff "$c^" "$c" > "$TMP/patch" 2>/dev/null || continue
  [ -s "$TMP/patch" ] || continue
  # Still on the default branch, and not in the merged state.
  GIT_INDEX_FILE="$TMP/idx-default" git apply --cached --check -R "$TMP/patch" 2>/dev/null || continue
  GIT_INDEX_FILE="$TMP/idx-merged" git apply --cached --check -R "$TMP/patch" 2>/dev/null && continue

  # A patch also fails when only its context moved. Count the commit's added
  # lines that are still on the default branch but absent from the merged
  # file, and report the commit only if there are any.
  report=""
  for f in $(git diff --name-only "$c^" "$c"); do
    trimmed "$DEFAULT" "$f" > "$TMP/default-lines"
    trimmed "$MERGED" "$f" > "$TMP/merged-lines"
    git diff -U0 "$c^" "$c" -- "$f" | sed -n 's/^+\([^+]\)/\1/p' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'length($0) > 3' > "$TMP/added"
    live=0 missing=0 sample=""
    while IFS= read -r line; do
      grep -Fxq -- "$line" "$TMP/default-lines" || continue
      live=$((live + 1))
      if ! grep -Fxq -- "$line" "$TMP/merged-lines"; then
        missing=$((missing + 1))
        [ -z "$sample" ] && sample=$line
      fi
    done < "$TMP/added"
    if [ "$missing" -gt 0 ]; then
      absent=""
      git cat-file -e "$MERGED:$f" 2>/dev/null || absent=" (file absent)"
      report="$report    $missing/$live lines missing  $f$absent
      e.g. $(printf '%s' "$sample" | cut -c1-100)
"
    fi
  done
  if [ -n "$report" ]; then
    findings=$((findings + 1))
    git show -s --format='  %h %ad %s' --date=short "$c"
    printf '%s' "$report"
  fi
done

# --- 2. Differences no unreleased ticket explains
echo
echo "== Differences between $DEFAULT and $MERGED that no unreleased ticket explains"
git log "$DEFAULT" --format='%s%n%b' | grep -oE "$TICKET" | sort -u > "$TMP/shipped"
git diff --name-only "$DEFAULT" "$MERGED" > "$TMP/files"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  unreleased=$(git log "$DEFAULT..$MERGED" --no-merges --format='%s%n%b' -- "$f" \
    | grep -oE "$TICKET" | sort -u | comm -23 - "$TMP/shipped")
  if [ -z "$unreleased" ]; then
    findings=$((findings + 1))
    stat=$(git diff --numstat "$DEFAULT" "$MERGED" -- "$f" | awk '{print "+" $1 "/-" $2}')
    echo "  $stat  $f"
  fi
done < "$TMP/files"

echo
if [ "$findings" -eq 0 ]; then
  echo "Nothing to review: every difference belongs to an unreleased ticket."
  exit 0
fi
echo "$findings finding(s) to review. See the back-merge skill for how to classify each one."
exit 2
