#!/bin/bash
# Tests for skills/back-merge/scripts/backmerge-drift-audit.sh. Builds a temp
# repo where a past back-merge resolved a released fix away, then checks the
# audit reports it, reports the pre-prod-only file no ticket explains, and
# stays quiet about unreleased work.
# Run: bash plugins/git-workflow/hooks/tests/backmerge-drift-audit.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AUDIT="$HERE/../../../../skills/back-merge/scripts/backmerge-drift-audit.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q -b main "$TMP/repo"
cd "$TMP/repo" || exit 1

printf 'line one\nline two\nline three\n' > app.txt
git add app.txt && git commit -q -m "chore: initial"
git branch dev

# A fix ships on main.
printf 'line one\nline two, with the released fix applied\nline three\n' > app.txt
git commit -q -am "fix(TT-1): apply the released fix"

# dev changes the same line, then a back-merge takes dev's side wholesale.
git switch -q dev
printf 'line one\nline two, reworded on dev\nline three\n' > app.txt
git commit -q -am "feat(TT-2): reword line two"
git merge -q main >/dev/null 2>&1
git checkout -q --ours app.txt && git add app.txt
git -c core.editor=true merge --continue >/dev/null 2>&1

# Unreleased work, and a dev-only file with no ticket at all.
echo "new feature" > feature.txt
git add feature.txt && git commit -q -m "feat(TT-3): unreleased feature"
echo "notes" > notes.md
git add notes.md && git commit -q -m "docs: dev-only notes"

pass=0 fail=0 out="" code=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $1"; printf '%s\n' "$out" | sed 's/^/    | /'; }
has() { if printf '%s\n' "$out" | grep -qE -- "$2"; then ok; else no "$1"; fi; }
lacks() { if printf '%s\n' "$out" | grep -qE -- "$2"; then no "$1"; else ok; fi; }
exits() { if [ "$code" -eq "$2" ]; then ok; else no "$1 (got exit $code)"; fi; }
audit() { out=$(bash "$AUDIT" "$@" 2>&1); code=$?; }

audit --merged dev --default main --since "10 years ago"
exits "exits 2 with findings" 2
has "reports the released fix the merge dropped" 'fix\(TT-1\): apply the released fix'
has "names the file and the missing line count" '1/1 lines missing  app.txt'
has "reports the dev-only file no ticket explains" '^  \+[0-9]+/-[0-9]+  notes\.md$'
lacks "stays quiet about unreleased work" 'feature\.txt'
lacks "does not call app.txt unexplained: an unreleased ticket touched it" '^  \+[0-9]+/-[0-9]+  app\.txt$'

# Restoring the fix and dropping the stray file leaves nothing to review.
git switch -q -c reconciled dev
git checkout -q main -- app.txt
git rm -q notes.md
git commit -q -m "fix(TT-1): restore the released fix"
audit --merged reconciled --default main --since "10 years ago"
exits "exits 0 once reconciled" 0

audit --merged no-such-ref --default main
exits "exits 1 on a bad ref" 1

echo "backmerge-drift-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
