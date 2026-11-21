#!/bin/bash
# Tests for preprod-pr-check.sh in a repo that never squashes: every PR,
# into dev and into main, is merged with a merge commit. Two tickets reach
# both branches, nobody back-merges main into dev, and a third ticket cut
# from main then has two merge bases with dev. GitHub diffs against one of
# them, so the PR lists the other ticket's file even though dev already
# has it. `gh` is a stub on PATH.
# Needs bash, git >= 2.38 (merge-tree --write-tree) and jq.
# Run: bash plugins/git-workflow/hooks/tests/preprod-pr-check-merge-commits.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../preprod-pr-check.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AGENT_TOOLKIT_STATE_DIR="$TMP/state"
export AGENT_TOOLKIT_CONFIG_DIR="$TMP/config"
# Keep the user's own git config (signing, hooks, default branch) out of it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "repo view"*) echo main ;;
  "pr list"*) printf 'dev\ndev\nmain\n' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

REPO="$TMP/work"
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$REPO" 2>/dev/null
cd "$REPO" || exit 1
git switch -q -c main 2>/dev/null || true
commit() { # file, content, message
  printf '%s\n' "$2" > "$1"
  git add "$1"
  git commit -q -m "$3"
}

commit app.txt "line one" "initial"
git push -q -u origin main
git push -q origin main:dev

# Tickets A and B are both cut from main, and each is merged into dev and
# into main with a merge commit. No back-merge into dev.
for t in a b; do
  git switch -q -c "feature/$t" main
  commit "$t.txt" "$t" "feat: $t"
  git push -q -u origin "feature/$t"
done
git switch -q -c dev origin/dev
git merge -q --no-ff -m "Merge feature/a into dev" feature/a
git merge -q --no-ff -m "Merge feature/b into dev" feature/b
git push -q origin dev
git switch -q main
git merge -q --no-ff -m "Merge pull request #1 from feature/a" feature/a
git merge -q --no-ff -m "Merge pull request #2 from feature/b" feature/b
git push -q origin main

# Ticket C is cut from main after both.
git switch -q -c feature/c main
commit c.txt "c" "feat: c"
git push -q -u origin feature/c

pass=0 fail=0
check() { # name, condition result (0 = pass)
  if [ "$2" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi
}

run_hook() { jq -n --arg c "$1" --arg d "$REPO" '{tool_input:{command:$c}, cwd:$d}' | bash "$HOOK"; }
# hook <command>: runs the hook, keeping its raw JSON in $out and its exit
# status in $rc (pipefail is on, so a crash in the hook shows up there).
hook() { out=$(run_hook "$1" 2>"$TMP/stderr"); rc=$?; }
field() { printf '%s' "$out" | jq -r ".hookSpecificOutput.$1 // \"\"" 2>/dev/null; }
allowed() { [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$TMP/stderr" ]; }

bases=$(git merge-base --all origin/dev feature/c | wc -l | tr -d ' ')
check "the setup really has two merge bases (got $bases)" "$([ "$bases" -eq 2 ]; echo $?)"

hook 'gh pr create --base dev --title x --body y'
reason=$(field permissionDecisionReason)
noise=$(printf '%s\n' "$reason" | sed -n '/--- files only/,$p' | sed 1d)
check "a ticket-C PR into dev is denied (rc $rc, decision $(field permissionDecision))" \
  "$([ "$rc" -eq 0 ] && [ "$(field permissionDecision)" = deny ]; echo $?)"
check "the noise is the other ticket's file, not C's own (got: $noise)" \
  "$({ [ "$noise" = a.txt ] || [ "$noise" = b.txt ]; }; echo $?)"
check "the deny doesn't blame squash merges" "$(printf '%s' "$reason" | grep -qi 'squash merges that' && echo 1 || echo 0)"

# From a conflicts branch cut from dev, the PR shows only C's file.
git switch -q -c conflicts/TAL-3-c origin/dev
git merge -q --no-edit feature/c
git push -q -u origin conflicts/TAL-3-c
hook 'gh pr create --base dev --title x --body y'
check "the conflicts branch is allowed (rc $rc)" "$(allowed; echo $?)"
check "the conflicts branch PR lists only c.txt" "$([ "$(git diff --name-only origin/dev...conflicts/TAL-3-c)" = c.txt ]; echo $?)"

# Once main is back-merged into dev, the feature branch itself is clean.
git switch -q dev
git merge -q --no-edit origin/main
git push -q origin dev
git switch -q feature/c
hook 'gh pr create --base dev --title x --body y'
check "after a back-merge the feature branch is allowed (rc $rc)" "$(allowed; echo $?)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
