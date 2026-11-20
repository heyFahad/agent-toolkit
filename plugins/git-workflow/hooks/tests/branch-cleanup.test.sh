#!/bin/bash
# Tests for skills/branch-cleanup/scripts/branch-cleanup.sh. Builds a repo
# with a bare origin and one worktree or branch per case, then checks that
# only what holds nothing local-only is removed.
# Run: bash plugins/git-workflow/hooks/tests/branch-cleanup.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLEANUP="$HERE/../../../../skills/branch-cleanup/scripts/branch-cleanup.sh"

TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# Stubs, so no test reaches GitHub or sees this machine's processes:
#   gh repo view   -> main
#   gh pr list     -> the merged PR heads in $STUB_MERGED_HEADS
#   lsof           -> one cwd per path in $STUB_LSOF_CWDS
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "repo view") echo main ;;
  "pr list") printf '%s\n' ${STUB_MERGED_HEADS:-} ;;
  *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/bin/bash
for p in ${STUB_LSOF_CWDS:-}; do printf 'p1\nfcwd\nn%s\n' "$p"; done
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/lsof"
export PATH="$TMP/bin:$PATH" STUB_MERGED_HEADS="" STUB_LSOF_CWDS=""

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
cd "$TMP/repo" || exit 1
printf '.env\nnode_modules/\n.claude/\n' > .gitignore
echo one > app.txt
git add . && git commit -q -m "chore: initial" && git push -q origin main
OLD_MAIN=$(git rev-parse HEAD)
echo two >> app.txt && git commit -q -am "feat: two" && git push -q origin main

W="$TMP/repo/.claude/worktrees"
mkdir -p "$W"
pushed_wt() { # name
  git worktree add -q -b "feat/$1" "$W/$1" origin/main
  git -C "$W/$1" commit -q --allow-empty -m "feat: $1"
  git -C "$W/$1" push -q -u origin "feat/$1" 2>/dev/null
}

pushed_wt clean
pushed_wt dirty;      echo changed >> "$W/dirty/app.txt"
pushed_wt untracked;  echo new > "$W/untracked/new.txt"
pushed_wt env;        echo SECRET=1 > "$W/env/.env"
pushed_wt rebuild
mkdir -p "$W/rebuild/node_modules/x" "$W/rebuild/.claude"
echo '{}' > "$W/rebuild/node_modules/x/index.js"
echo '{}' > "$W/rebuild/.claude/settings.local.json"
pushed_wt inuse
pushed_wt locked;     git worktree lock "$W/locked"
pushed_wt here
# A clean, pushed worktree with a dirty one nested in its ignored .claude/.
pushed_wt outer
git worktree add -q -b feat/inner "$W/outer/.claude/worktrees/inner" origin/main
echo changed >> "$W/outer/.claude/worktrees/inner/app.txt"
git worktree add -q -b feat/unpushed "$W/unpushed" origin/main
git -C "$W/unpushed" commit -q --allow-empty -m "feat: only here"
git worktree add -q --detach "$W/detached" origin/main
# A detached HEAD with a commit made only here.
git worktree add -q --detach "$W/detached-unpushed" origin/main
git -C "$W/detached-unpushed" commit -q --allow-empty -m "wip: detached"
git worktree add -q -b feat/gone "$W/gone" origin/main
rm -rf "$W/gone"

git branch claude/stale "$OLD_MAIN"
git branch --no-track local-only origin/main && git commit -q --allow-empty -m x && git branch -f local-only HEAD && git reset -q --hard origin/main
# A conflicts/ branch pushed without -u, so it has no upstream.
git branch --no-track conflicts/T-1-x origin/main
git push -q origin conflicts/T-1-x 2>/dev/null
# A merged PR's branch whose remote copy was deleted and pruned.
git switch -q -c merged-gone origin/main && git commit -q --allow-empty -m "feat: merged"
git push -q origin merged-gone 2>/dev/null
MERGED_TIP=$(git rev-parse HEAD)
git switch -q main
git push -q origin --delete merged-gone 2>/dev/null
git fetch -q --prune origin

# main moves on origin; the local main is behind.
git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
(cd "$TMP/other" && echo three >> app.txt && git commit -q -am "feat: three" && git push -q origin main)

pass=0 fail=0 out="" code=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $1"; printf '%s\n' "$out" | sed 's/^/    | /'; }
wt_is() { # desc name action [reason-regex]
  local got
  got=$(jq -r --arg p "$W/$2" '.worktrees[] | select(.path == $p) | "\(.action)|\(.reason)"' <<<"$out")
  if [[ "$got" == "$3|"* ]] && { [ -z "${4:-}" ] || [[ "$got" =~ $4 ]]; }; then ok; else no "$1 (got '$got')"; fi
}
br_is() { # desc branch action
  local got
  got=$(jq -r --arg n "$2" '.branches[] | select(.name == $n) | .action' <<<"$out")
  if [ "$got" = "$3" ]; then ok; else no "$1 (got '$got')"; fi
}
exists() { if [ -e "$2" ]; then ok; else no "$1"; fi; }
gone() { if [ -e "$2" ]; then no "$1"; else ok; fi; }
run() { out=$(bash "$CLEANUP" "$@" 2>"$TMP/stderr"); code=$?; }

export STUB_LSOF_CWDS="$W/inuse/sub"

# --- Dry run first: reports, removes nothing. ---
run --dry-run
if [ "$code" -eq 0 ]; then ok; else no "dry run exits 0 (got $code)"; fi
wt_is "dry run: clean worktree would go" clean would-remove
exists "dry run leaves the clean worktree" "$W/clean"
br_is "dry run: a stale claude/ branch would go" claude/stale would-remove
br_is "dry run: a removable worktree's branch would go too" feat/clean would-remove
if git rev-parse -q --verify refs/heads/claude/stale >/dev/null; then ok; else no "dry run leaves branches"; fi

# --- From inside a worktree: that one is kept. ---
out=$(cd "$W/here" && bash "$CLEANUP" --dry-run 2>&1)
wt_is "the worktree it runs in is kept" here kept "runs in"

# --- A missing --default value never swallows the next option. ---
run --default --dry-run
if [ "$code" -eq 1 ]; then ok; else no "--default followed by an option exits 1 (got $code)"; fi
exists "--default --dry-run removes nothing" "$W/clean"
run --default
if [ "$code" -eq 1 ]; then ok; else no "a lone --default exits 1 (got $code)"; fi

# --- The real run. ---
run
if [ "$code" -eq 0 ]; then ok; else no "exits 0 (got $code)"; fi
wt_is "clean and pushed: removed" clean removed
gone "the clean worktree's folder is gone" "$W/clean"
wt_is "modified file: kept" dirty kept "uncommitted"
wt_is "untracked file: kept" untracked kept "uncommitted"
wt_is "ignored .env: kept" env kept "can't be rebuilt"
if jq -e --arg p "$W/env" '.worktrees[] | select(.path == $p) | .files | index(".env")' <<<"$out" >/dev/null; then ok; else no "names the .env it would lose"; fi
wt_is "only rebuildable ignored files: removed" rebuild removed
gone "git worktree remove deletes ignored files without --force" "$W/rebuild"
wt_is "a process works inside it: kept" inuse kept "in use"
wt_is "locked: kept" locked kept "locked"
wt_is "unpushed commit: kept" unpushed kept "aren't on any remote"
wt_is "detached HEAD on a pushed commit: removed" detached removed
wt_is "detached HEAD with a local-only commit: kept" detached-unpushed kept "detached HEAD"
wt_is "folder already gone: pruned" gone removed "prunable"
wt_is "a worktree with another inside it: kept" outer kept "inside it"
exists "the nested dirty worktree survives" "$W/outer/.claude/worktrees/inner/app.txt"
if git worktree list | grep -q "/gone "; then no "prunes the missing worktree"; else ok; fi

br_is "a removed worktree's branch is deleted" feat/clean removed
br_is "a kept worktree's branch is kept" feat/dirty kept
br_is "a stale claude/ branch at an old main commit is deleted" claude/stale removed
br_is "a branch with a local-only commit is kept" local-only kept
br_is "a conflicts/ branch pushed without an upstream is deleted" conflicts/T-1-x removed
br_is "a merged branch whose remote is gone is kept without a matching PR" merged-gone kept
if jq -e '.branches[] | select(.name == "main")' <<<"$out" >/dev/null; then no "never lists the default branch"; else ok; fi

if [ "$(jq -r .defaultBranch.action <<<"$out")" = updated ]; then ok; else no "fast-forwards the default branch"; fi
if [ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ]; then ok; else no "main matches origin/main"; fi

# --- With gh showing the merged PR's head, that branch goes too. ---
export STUB_MERGED_HEADS="$MERGED_TIP"
run
br_is "a merged PR's head matching the tip counts as pushed" merged-gone removed
export STUB_MERGED_HEADS="0000000000000000000000000000000000000000"
git branch merged-other "$MERGED_TIP" 2>/dev/null || true
run
br_is "a merged PR whose head differs doesn't count" merged-other kept

# --- Without lsof, a recently changed index counts as in use. ---
BRANCH_CLEANUP_LSOF="" run
wt_is "no lsof: recently used worktree kept" inuse kept "index changed"

# An lsof that lists nothing failed: fall back to the index check, never
# treat every worktree as unused.
printf '#!/bin/bash\nexit 1\n' > "$TMP/bin/lsof-broken" && chmod +x "$TMP/bin/lsof-broken"
BRANCH_CLEANUP_LSOF="$TMP/bin/lsof-broken" run
wt_is "lsof that lists nothing: falls back, worktree kept" inuse kept "index changed"

# --- The fast-forward never overwrites an ignored local file. ---
(cd "$TMP/other" && git pull -q && echo TRACKED=1 > .env && git add -f .env && git commit -q -m "chore: track .env" && git push -q origin main)
echo LOCAL=1 > "$TMP/repo/.env"
STUB_LSOF_CWDS="$W/inuse/sub" run
if [ "$(jq -r .defaultBranch.action <<<"$out")" = kept ]; then ok; else no "won't fast-forward over an ignored local file"; fi
if grep -q LOCAL=1 "$TMP/repo/.env"; then ok; else no "the ignored local .env is untouched"; fi

echo "branch-cleanup: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
