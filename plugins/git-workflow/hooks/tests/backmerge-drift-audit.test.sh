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
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands below that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# `gh` is a stub: it reports $STUB_GH_DEFAULT as the default branch, or fails
# when that's empty, so no test reaches the real GitHub.
mkdir -p "$TMP/bin"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/bin/bash\n[ -n "${STUB_GH_DEFAULT:-}" ] || exit 1\necho "$STUB_GH_DEFAULT"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" STUB_GH_DEFAULT=""

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

# A ticket merged into dev whose key is only in the merge commit's subject
# (its branch name), not in any of its own commits.
git switch -q -c widget-branch
echo "widget" > widget.txt
git add widget.txt && git commit -q -m "feat: add the widget"
git switch -q dev
git merge -q --no-ff -m "Merge pull request #7 from example/TT-4-widget" widget-branch

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
lacks "reads ticket keys from merge subjects too" 'widget\.txt'
has "skips report 3 when the tip isn't a back-merge" "Conflicted files: skipped"

# With no --default, it asks gh for the default branch, even when a stale
# origin/HEAD still points at the old one...
git update-ref refs/remotes/origin/main main
git update-ref refs/remotes/origin/old-main main~1
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/old-main
STUB_GH_DEFAULT=main audit --merged dev --since "10 years ago"
exits "detects the default branch from gh" 2
has "prefers gh over a stale origin/HEAD" 'between origin/main and dev'

# ...falls back to origin/HEAD when gh can't tell...
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
audit --merged dev --since "10 years ago"
exits "falls back to origin/HEAD: exits 2" 2
has "falls back to origin/HEAD for the default branch" 'between origin/main and dev'

# The resolver's --default has its own copy of this lookup. Both must pick
# the same branch, whether gh answers or only origin/HEAD does.
RESOLVER="$HERE/../../../../skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh"
same_default() { # name, gh's answer
  local res
  res=$(STUB_GH_DEFAULT=$2 bash "$RESOLVER" --default 2>/dev/null)
  STUB_GH_DEFAULT=$2 audit --merged dev --since "10 years ago"
  if [ -n "$res" ] && printf '%s\n' "$out" | grep -qF "between origin/$res and dev"; then ok; else no "$1 (resolver said '$res')"; fi
}
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/old-main
same_default "resolver and audit agree when gh answers" main
same_default "resolver and audit agree on origin/HEAD alone" ""

# ...and fails clearly when neither can tell.
git symbolic-ref --delete refs/remotes/origin/HEAD
audit --merged dev --since "10 years ago"
exits "exits 1 when the default branch can't be found" 1
has "says to pass --default" "can't tell the default branch"

# Restoring the fix and dropping the stray file leaves nothing to review.
git switch -q -c reconciled dev
git checkout -q main -- app.txt
git rm -q notes.md
git commit -q -m "fix(TT-1): restore the released fix"
audit --merged reconciled --default main --since "10 years ago"
exits "exits 0 once reconciled" 0

audit --merged no-such-ref --default main
exits "exits 1 on a bad ref" 1

# --- a repo whose ticket keys don't match the default pattern
git init -q -b main "$TMP/lower"
cd "$TMP/lower" || exit 1
echo "base" > base.txt
git add base.txt && git commit -q -m "chore: initial"
git branch dev
echo "fix" >> base.txt
git commit -q -am "fix(web-1): released fix"
git switch -q dev
git merge -q --no-edit main
echo "feature" > feature.txt
git add feature.txt && git commit -q -m "feat(web-2): unreleased feature"

audit --merged dev --default main --since "10 years ago"
exits "no ticket keys: exits 2" 2
has "no ticket keys: says it can't tell" "Can't tell unreleased work from drift"
has "no ticket keys: lists every differing file" '^  \+1/-0  feature\.txt$'
lacks "no ticket keys: doesn't call them unexplained" 'that no unreleased ticket explains'

audit --merged dev --default main --since "10 years ago" --ticket '[a-z]+-[0-9]+'
exits "--ticket: exits 0 once the keys match" 0
lacks "--ticket: unreleased work is explained" 'feature\.txt'

# --- report 3: a back-merge whose four files all conflict
# a.txt: shipped ticket TT-10 put a constant in a different place on each
#        side, and main hotfixed the line next to it.
# c.txt: TT-10 also reworded a comment differently on each side.
# d.txt: unreleased TT-20 added a line on dev only.
# e.txt: unreleased TT-30 moved a constant on dev. Its commit also names epic
#        TT-1, which main's history mentions too.
git init -q -b main "$TMP/conf"
cd "$TMP/conf" || exit 1
put() { printf '%b' "$2" > "$1"; } # file, content with \n escapes
put a.txt 'header\nbody\nfooter\n'
put c.txt 'header\n// fetch the user\nload();\nfooter\n'
put d.txt 'header\nbody\nfooter\n'
put e.txt 'header\nconst LIMIT_VALUE = 10;\nbody\nfooter\n'
git add . && git commit -q -m "chore: initial"
git branch dev
put a.txt 'header\nbody\nfooter\nconst NO_OPTIONS = [];\n'
put c.txt 'header\n// load the user\nload();\nfooter\n'
git commit -q -am "feat(TT-10): add options and reword (#3)"
put a.txt 'header\nbody fixed\nfooter\nconst NO_OPTIONS = [];\n'
put c.txt 'header\n// load the user\nload(true);\nfooter\n'
put d.txt 'header\nbody fixed\nfooter\n'
put e.txt 'header\nconst LIMIT_VALUE = 10;\nbody fixed\nfooter\n'
git commit -q -am "fix(TT-1): hotfix the bodies"
git switch -q dev
put a.txt 'header\nconst NO_OPTIONS = [];\nbody\nfooter\n'
put c.txt 'header\n// fetch the current user\nload();\nfooter\n'
git commit -q -am "feat(TT-10): add options and reword"
put d.txt 'header\nfeature line\nbody\nfooter\n'
git commit -q -am "feat(TT-20): unreleased feature"
put e.txt 'header\nbody\nfooter\nconst LIMIT_VALUE = 10;\n'
git commit -q -am "refactor(TT-30): move the limit, part of epic TT-1"

backmerge() { # branch, a.txt, c.txt, d.txt: merge main into dev, resolved so
  git switch -q -c "$1" dev
  git merge -q main >/dev/null 2>&1
  put a.txt "$2"; put c.txt "$3"; put d.txt "$4"
  put e.txt 'header\nbody fixed\nfooter\nconst LIMIT_VALUE = 10;\n'
  git add . && git -c core.editor=true merge --continue >/dev/null 2>&1
}

# Resolved toward dev's layout for a.txt and c.txt.
backmerge bm-dev 'header\nconst NO_OPTIONS = [];\nbody fixed\nfooter\n' \
  'header\n// fetch the current user\nload(true);\nfooter\n' 'header\nfeature line\nbody fixed\nfooter\n'
audit --default main --since "10 years ago"
exits "toward dev: exits 2" 2
has "toward dev: before and after counts" '^  a\.txt: 4 line\(s\) differ .* before the merge, 2 after$'
has "toward dev: a moved constant is drift" 'L2 moved  DRIFT: resolve toward main .*const NO_OPTIONS'
has "toward dev: a reworded comment is drift" 'L2 cosmetic  DRIFT: resolve toward main .*// fetch the current user'
lacks "toward dev: an unreleased addition isn't flagged" 'feature line'
has "an unreleased move is attributed" 'L4 moved  unreleased work \(TT-30, '
lacks "an epic key on both sides doesn't make it shipped" 'L4 moved  DRIFT'

# A reconciliation commit after the merge clears the drift.
put a.txt 'header\nbody fixed\nfooter\nconst NO_OPTIONS = [];\n'
put c.txt 'header\n// load the user\nload(true);\nfooter\n'
git commit -q -am "chore: take main's layout for merge leftovers"
audit --default main --since "10 years ago"
exits "reconciled after the merge: exits 0" 0
has "finds the back-merge past the reconciliation commit" '^== Conflicted files in '

# Resolved toward main's layout from the start.
backmerge bm-main 'header\nbody fixed\nfooter\nconst NO_OPTIONS = [];\n' \
  'header\n// load the user\nload(true);\nfooter\n' 'header\nfeature line\nbody fixed\nfooter\n'
audit --default main --since "10 years ago"
exits "toward main: exits 0" 0
has "toward main: no drift left in a.txt" '^  a\.txt: 4 line\(s\) differ .* before the merge, 0 after$'

# A resolution that adds lines neither side has.
backmerge bm-extra 'header\nbody fixed\nfooter\nconst NO_OPTIONS = [];\n' \
  'header\n// load the user\nload(true);\nfooter\n' 'header\nfeature line\nbody fixed\none\ntwo\nthree\nfour\nfooter\n'
audit --default main --since "10 years ago"
has "more drift after than before is flagged" '^  d\.txt: 3 .* 5 after  MORE DRIFT AFTER THE MERGE'

# A merge-tree failure is an error, not "no conflicts".
REAL_GIT=$(command -v git)
mkdir -p "$TMP/badgit"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/bin/bash\ncase " $* " in *" merge-tree "*) echo "fatal: simulated" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" > "$TMP/badgit/git"
chmod +x "$TMP/badgit/git"
PATH="$TMP/badgit:$PATH" audit --default main --since "10 years ago"
exits "merge-tree failure: exits 1" 1
has "merge-tree failure: says so" 'git merge-tree failed'

# Once the back-merge PR has merged into dev, report 3 finds the back-merge
# through the PR's merge commit.
git switch -q dev
git merge -q --no-ff -m "Merge pull request #9 from example/conflicts/backmerge-r2" bm-dev
audit --merged dev --default main --since "10 years ago"
exits "after the PR merged: exits 0" 0
has "after the PR merged: finds the back-merge" "^== Conflicted files in $(git rev-parse --short bm-dev^),"

# --- report 1: fixes lost when a later commit changed part of the patch,
# and fixes that only delete a line or a file
git init -q -b main "$TMP/rel"
cd "$TMP/rel" || exit 1
put x.txt 'x one\nx two\n'
put y.txt 'y one original\n'
put z.txt 'keep this line\nremove this buggy line\n'
put w.txt 'whole file to delete\n'
put 'two  spaces.txt' 'spaced one original\n'
put '[ab].txt' 'bracket one original\n'
put a.txt 'decoy a original\n'
git add . && git commit -q -m "chore: initial"
git branch dev
put x.txt 'x one\nx two fixed in release\n'
put y.txt 'y one fixed in release\n'
put 'two  spaces.txt' 'spaced one fixed in release\n'
put '[ab].txt' 'bracket one fixed in release\n'
git commit -q -am "fix(TT-50): fix x and y"
put x.txt 'x one\nx two reworked later\n'
git commit -q -am "fix(TT-51): rework x"
put z.txt 'keep this line\n'
git rm -q w.txt
git commit -q -am "fix(TT-52): drop the buggy line and the old file"
git switch -q dev
git merge -q -s ours --no-edit main
audit --merged dev --default main --since "10 years ago"
exits "lost fixes: exits 2" 2
has "a partly reworked commit still reports its other file" '1/1 lines missing  y\.txt'
has "a removed line that came back is reported" '1/1 removed lines still present  z\.txt$'
has "a deleted file that came back is reported" 'removed lines still present  w\.txt \(file deleted on main\)'
has "a file name with two spaces stays whole" '1/1 lines missing  two  spaces\.txt$'
has "a file name with glob characters stays whole" '1/1 lines missing  \[ab\]\.txt$'
lacks "glob characters don't match other files" '  a\.txt$'

# The same audit from a subdirectory of the repo.
mkdir -p sub && cd sub || exit 1
audit --merged dev --default main --since "10 years ago"
has "from a subdirectory: still reports the lost fix" '1/1 lines missing  y\.txt'
cd .. || exit 1

echo "backmerge-drift-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
