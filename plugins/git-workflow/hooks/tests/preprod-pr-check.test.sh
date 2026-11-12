#!/bin/bash
# Tests for preprod-pr-check.sh. Builds a temp repo with a bare
# origin that reproduces the squash-merge case: a ticket reached dev through
# a merge commit, then main got the same change as one squash commit, and
# nobody back-merged main into dev. `gh` is a stub on PATH.
# Needs bash, git >= 2.38 (merge-tree --write-tree) and jq.
# Run: bash plugins/git-workflow/hooks/tests/preprod-pr-check.test.sh
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
  "pr list"*) cat "$STUB_PR_BASES" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_PR_BASES="$TMP/pr-bases"
printf 'dev\ndev\nmain\n' > "$STUB_PR_BASES"

REPO="$TMP/work"
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$REPO" 2>/dev/null
cd "$REPO"
git switch -q -c main 2>/dev/null || true
commit() { # file, content, message
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
  git add "$1"
  git commit -q -m "$3"
}

commit app.txt "line one" "initial"
git push -q -u origin main
git switch -q -c dev
git push -q -u origin dev
git switch -q main

# Ticket A ships to dev as two ordinary commits plus a merge commit...
git switch -q -c feature/a
commit a1.txt "a1" "feat: a1"
commit a2.txt "a2" "feat: a2"
git push -q -u origin feature/a
git switch -q dev
git merge -q --no-ff -m "Merge feature/a into dev" feature/a
git push -q origin dev
# ...and to main as one squash commit. No back-merge into dev.
git switch -q main
git merge -q --squash feature/a >/dev/null
git commit -q -m "feat: ticket A (#1)"
git push -q origin main

# Ticket B is cut from main after that, so it carries the squash commit.
git switch -q -c feature/b
commit b.txt "b" "feat: b"
git push -q -u origin feature/b

pass=0 fail=0

run_hook() { jq -n --arg c "$1" --arg d "$REPO" '{tool_input:{command:$c}, cwd:$d}' | bash "$HOOK"; }

expect() { # name, allow|deny, command, [text the deny reason must contain]
  local out decision reason
  out=$(run_hook "$3" 2>&1)
  if [ -z "$out" ]; then decision=allow
  else decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage); fi
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)
  if [ "$decision" = "$2" ] && { [ "$2" = deny ] || [ -z "$out" ]; } \
    && { [ -z "${4:-}" ] || printf '%s' "$reason" | grep -qF -- "$4"; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (wanted $2${4:+ mentioning \"$4\"}, got $decision)"
    [ -n "$out" ] && echo "      $out" | head -c 600 && echo
  fi
}

# --- commands this hook leaves alone
expect "unrelated command"      allow 'git status'
expect "pr view"                allow 'gh pr view 12'
expect "no --base"              allow 'gh pr create --draft --title "x" --body "y"'
expect "base is default"        allow 'gh pr create --base main --title "x" --body "y"'
expect "base not pre-prod"      allow 'gh pr create --base feature/a --title "x" --body "y"'

# --- the noisy diff
expect "noisy, --base"          deny  'gh pr create --base dev --draft --title "x" --body "y"' "a1.txt"
expect "noisy, --base="         deny  'gh pr create --base=dev --title "x" --body "y"' "conflicts/<ticket>-<slug>"
expect "noisy, -B"              deny  'gh pr create -B dev -t "x" -b "y"' "a2.txt"
expect "noisy, quoted base"     deny  "gh pr create --base 'dev' --title x --body y" "a1.txt"
expect "noisy, env prefix"      deny  'GH_TOKEN=$(gh auth token) gh pr create --base dev --title x --body y' "a1.txt"
expect "noisy, after cd"        deny  "cd $REPO && gh pr create --base dev --title x --body y" "a1.txt"
expect "noisy, --head"          deny  'gh pr create --base dev --head feature/b --title x --body y' "a1.txt"
expect "noisy, owner:head"      deny  'gh pr create --base dev --head someone:feature/b --title x --body y' "a1.txt"
expect "suggests back-merge"    deny  'gh pr create --base dev --title x --body y' "gh pr list --base dev --state open"
expect "back-merge via branch"  deny  'gh pr create --base dev --title x --body y' "conflicts/backmerge-<release>"
expect "says no squash"         deny  'gh pr create --base dev --title x --body y' "never squashed"
expect "says no cherry-pick"    deny  'gh pr create --base dev --title x --body y' "do not cherry-pick"
out=$(run_hook 'gh pr create --base dev --title x --body y')
if printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | sed -n '/--- files only/,$p' | grep -qx 'b.txt'; then
  fail=$((fail + 1)); echo "FAIL: the branch's own file is listed as noise"
else
  pass=$((pass + 1))
fi

# --- the deliberate conflicts branch is clean
git switch -q -c conflicts/TAL-1-b origin/dev
git merge -q --no-edit feature/b
git push -q -u origin conflicts/TAL-1-b
expect "conflicts branch"       allow 'gh pr create --base dev --title x --body y'
files=$(git diff --name-only origin/dev...conflicts/TAL-1-b)
if [ "$files" = "b.txt" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: conflicts branch PR would show: $files"; fi
git switch -q feature/b

# --- a back-merge straight from main lists ticket A, which dev already has
expect "back-merge from main"   deny  'gh pr create --base dev --head main --title x --body y' "a1.txt"
expect "back-merge recipe"      deny  'gh pr create --base dev --head main --title x --body y' "git merge --no-ff origin/main"
expect "back-merge no squash"   deny  'gh pr create --base dev --head main --title x --body y' "never squashed"
out=$(run_hook 'gh pr create --base dev --head main --title x --body y')
if printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qF 'would list 2 file(s) that the merge would not change (it really changes 0 file(s)'; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: back-merge deny miscounts files: $out" | head -c 600; echo
fi

# ...and from a conflicts/backmerge-... branch its files tab is empty
git switch -q -c conflicts/backmerge-r1 origin/dev
git merge -q --no-ff --no-edit origin/main
git push -q -u origin conflicts/backmerge-r1
expect "back-merge branch"      allow 'gh pr create --base dev --title x --body y'
files=$(git diff --name-only origin/dev...conflicts/backmerge-r1)
if [ -z "$files" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: back-merge branch PR would show: $files"; fi

# --- a noise list far bigger than a pipe buffer still gets a deny, not a
# crash: sampling it must not SIGPIPE the writer under pipefail
# (cut from the root commit, so merging it into dev doesn't bring main's
# squash commits along and quietly clean up the later cases' noise)
git switch -q -c feature/big "$(git rev-list --max-parents=0 main)"
mkdir -p noise
i=0
while [ "$i" -lt 4000 ]; do
  printf '%s\n' "$i" > "noise/file-$i-with-a-long-enough-name-to-fill-a-pipe-buffer.txt"
  i=$((i + 1))
done
git add noise
git commit -q -m "feat: big ticket"
git push -q -u origin feature/big
git switch -q dev
git merge -q --no-ff -m "Merge feature/big into dev" feature/big
git push -q origin dev
git switch -q main
git merge -q --squash feature/big >/dev/null
git commit -q -m "feat: big ticket (#3)"
git push -q origin main
expect "huge back-merge noise"  deny  'gh pr create --base dev --head main --title x --body y' "noise/file-"
git switch -q -c feature/after-big main
commit after-big.txt "after big" "feat: after big"
git push -q -u origin feature/after-big
expect "huge feature noise"     deny  'gh pr create --base dev --title x --body y' "noise/file-"
git switch -q feature/b

# --- once main is back-merged into dev with a merge commit, no noise
git switch -q dev
git merge -q --no-edit origin/main
git push -q origin dev
git switch -q feature/b
expect "after back-merge"       allow 'gh pr create --base dev --title x --body y'

# --- a back-merge that only brings what dev lacks is fine straight from main
git switch -q main
commit hotfix.txt "hotfix" "fix: hotfix straight to main (#2)"
git push -q origin main
expect "clean back-merge"       allow 'gh pr create --base dev --head main --title x --body y'
git switch -q feature/b

# --- a real conflict is still caught first
git switch -q dev
commit app.txt "dev's line one" "feat: dev edit"
git push -q origin dev
git switch -q -c feature/c main
commit app.txt "c's line one" "feat: c edit"
git push -q -u origin feature/c
expect "conflict"               deny  'gh pr create --base dev --title x --body y' "CONFLICT"

# --- when the resolver can't decide, a long-lived name is still checked
git push -q origin main:staging
printf 'dev\nstaging\n' > "$STUB_PR_BASES"
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
git switch -q feature/b
git switch -q dev && git reset -q --hard HEAD~2 && git push -q -f origin dev && git switch -q feature/b
expect "ambiguous, dev"         deny  'gh pr create --base dev --title x --body y' "a1.txt"

# --- with an override, only that branch is pre-prod
mkdir -p "$AGENT_TOOLKIT_CONFIG_DIR"
key=$(printf '%s' "$TMP/origin" | awk -F/ '{print $(NF-1) "/" $NF}' | tr '[:upper:]' '[:lower:]')
jq -n --arg k "$key" '{repos: {($k): {branch: "staging", setOn: "2026-11-06"}}}' > "$AGENT_TOOLKIT_CONFIG_DIR/preprod-branches.local.json"
expect "override: dev skipped"  allow 'gh pr create --base dev --title x --body y'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
