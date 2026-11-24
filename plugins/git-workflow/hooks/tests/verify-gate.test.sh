#!/bin/bash
# Tests for verify-gate.sh. Builds temp repos whose CI runs `npm test`, with a
# stub npm, and records made by the real verify script. `gh` is a stub.
# Run: bash plugins/git-workflow/hooks/tests/verify-gate.test.sh
set -uo pipefail
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands below that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
# Keep the user's own git config (signing, hooks, default branch) out of it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../verify-gate.sh"
VERIFY="$HERE/../../skills/verify/scripts/verify"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" AGENT_TOOLKIT_STATE_DIR="$TMP/state" NVM_DIR="$TMP/nvm"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/npm" <<'EOF'
#!/bin/bash
[ "$1" = run ] && shift
exec sh -c "$(jq -r --arg n "$1" '.scripts[$n]' package.json)"
EOF
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "stack view --json") [ -f "$FX/stack.json" ] || { echo "no stack here" >&2; exit 1; }; cat "$FX/stack.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/npm" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FX="$TMP/fx"
mkdir -p "$FX"

pass=0 fail=0 CODE=0
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
    echo "      expected: $2"
    echo "      actual:   $3"
    [ -s "$TMP/stderr" ] && sed 's/^/      stderr: /' "$TMP/stderr" | head -5
  fi
}

# gate CMD [CWD]: run the hook on a Bash call of CMD from CWD (default $R).
gate() {
  jq -n --arg cwd "${2:-$R}" --arg c "$1" '{cwd: $cwd, tool_input: {command: $c}}' |
    bash "$HOOK" >/dev/null 2>"$TMP/stderr"
  CODE=$?
}
said() { grep -q -- "$1" "$TMP/stderr" && echo true || echo false; }
verify() { (cd "${2:-$R}" && bash "$VERIFY" "$1" >/dev/null 2>&1); }
commit() { git -C "$R" add -A && git -C "$R" commit -q -m "$1"; }

# A repo whose CI runs `npm test`, on branch main, with a feature branch.
R="$TMP/repo"
git init -q -b main "$R"
echo '{"scripts":{"test":"echo ok"}}' >"$R/package.json"
mkdir -p "$R/.github/workflows"
printf 'on:\n  pull_request:\njobs:\n  t:\n    steps:\n      - run: npm test\n' >"$R/.github/workflows/ci.yml"
commit init
git -C "$R" switch -q -c feat

# -------------------------------------------------------------------- commit
echo a >"$R/a.txt"
gate 'git commit -m "add a"'
check "commit: no record blocks" 2 "$CODE"
check "commit: says to run verify --related" true "$(said 'verify --related')"
verify --related
gate 'git commit -m "add a"'
check "commit: related record allows" 0 "$CODE"
echo b >"$R/a.txt"
gate 'git commit -m "add a"'
check "commit: edit after verify blocks" 2 "$CODE"
verify --full
gate 'git commit -m "add a"'
check "commit: full record allows" 0 "$CODE"
gate "cd $R && git commit -m x" "$TMP"
check "commit: cd <dir> && git commit uses that dir" 0 "$CODE"
gate "git -C $R commit -m x" "$TMP"
check "commit: git -C <dir> commit uses that dir" 0 "$CODE"
echo c >"$R/a.txt"
gate "cd $R && git commit -m x" "$TMP"
check "commit: cd <dir> && git commit, unverified, blocks" 2 "$CODE"
verify --full
commit "add a"

# ---------------------------------------------------------------------- push
# HEAD's tree was verified --full above (the commit took exactly that tree).
gate 'git push -u origin feat'
check "push: full record of the pushed tree allows" 0 "$CODE"
echo d >"$R/d.txt"
verify --related
commit "add d"
gate 'git push'
check "push: a related record isn't enough" 2 "$CODE"
check "push: says to run verify --full" true "$(said 'verify --full')"
verify --full
for cmd in 'git push' 'git push origin HEAD' 'git push -u origin feat' \
  'git push --force-with-lease --force-if-includes origin feat' 'git push origin feat:feat' 'git push origin +feat'; do
  gate "$cmd"
  check "push: $cmd" 0 "$CODE"
done
gate 'git push origin --delete old'
check "push: --delete needs no record" 0 "$CODE"
gate 'git push origin :old'
check "push: an empty source deletes, needs no record" 0 "$CODE"
gate 'git push --tags'
check "push: --tags needs no record" 0 "$CODE"
git -C "$R" tag v1
gate 'git push origin v1'
check "push: a tag needs no record" 0 "$CODE"
gate 'git push --all'
check "push: --all is blocked" 2 "$CODE"
check "push: --all says to push branches by name" true "$(said 'by name')"

# Another branch, unverified, pushed by name while feat is checked out.
git -C "$R" branch other main
git -C "$R" switch -q other
echo o >"$R/o.txt"
commit "add o"
git -C "$R" switch -q feat
gate 'git push -u origin other'
check "push: -u origin <b> checks <b>, not the current branch" 2 "$CODE"
gate 'git push origin other:feat'
check "push: src:dst checks src" 2 "$CODE"

# An untracked file doesn't stop a push: the tracked tree matches.
echo scratch >"$R/scratch.txt"
verify --full
gate 'git push'
check "push: tracked-tree match allows despite an untracked file" 0 "$CODE"
rm "$R/scratch.txt"

# ----------------------------------------------------------------- pr create
gate 'gh pr create --base main --title t --body b'
check "pr create: the current branch, verified" 0 "$CODE"
for cmd in 'gh pr create --head other' 'gh pr create -H other' 'gh pr create --head=other' 'gh pr create --head someone:other'; do
  gate "$cmd"
  check "pr create: $cmd checks other" 2 "$CODE"
done
git -C "$R" update-ref refs/remotes/origin/remote-only "$(git -C "$R" rev-parse other)"
gate 'gh pr create --head remote-only'
check "pr create: a branch only on origin is checked too" 2 "$CODE"

# ---------------------------------------------------------------- not gated
for cmd in 'echo "git push"' 'grep -r "git commit" .' 'git status' 'git log --oneline' 'gh pr view 1' 'gh stack view'; do
  gate "$cmd"
  check "not gated: $cmd" 0 "$CODE"
done
# A commit whose message mentions another command is gated as a commit only.
echo e >"$R/e.txt"
verify --related
gate 'git commit -m "fix gh pr create"'
check "commit message text isn't a command" 0 "$CODE"
git -C "$R" checkout -q -- . && rm -f "$R/e.txt"
# A heredoc body isn't a command either.
gate "$(printf 'git commit -F - <<%sEOF%s\nfix\ngit push origin other\nEOF' "'" "'")"
check "heredoc body isn't a command" 0 "$CODE"

# --------------------------------------------------------------- gh stack
# Every open branch in the stack needs a full record; merged ones are skipped.
git -C "$R" switch -q -c sub-0 main
git -C "$R" switch -q -c sub-a main
echo sa >"$R/sa.txt"
verify --full
commit "sub-a"
git -C "$R" switch -q -c sub-b
echo sb >"$R/sb.txt"
commit "sub-b"
jq -n '{trunk: "main", currentBranch: "sub-b", branches: [
  {name: "sub-0", isMerged: true, isQueued: false},
  {name: "sub-a", isMerged: false, isQueued: false},
  {name: "sub-b", isMerged: false, isQueued: false}]}' >"$FX/stack.json"
gate 'gh stack push'
check "stack push: an unverified open branch blocks" 2 "$CODE"
check "stack push: names that branch" true "$(said 'gh stack push of sub-b')"
check "stack push: the verified branch isn't named" false "$(said 'of sub-a')"
check "stack push: merged branches are skipped" false "$(said 'sub-0')"
gate 'gh stack submit'
check "stack submit: same rule" 2 "$CODE"
verify --full
gate 'gh stack push'
check "stack push: every open branch verified allows" 0 "$CODE"
gate 'gh stack view'
check "stack view: not gated" 0 "$CODE"
rm "$FX/stack.json"
gate 'gh stack push'
check "stack: gh stack view failing blocks with its error" '[2,true]' "[$CODE,$(said 'no stack here')]"
git -C "$R" switch -q feat

# ------------------------------------------------- on an unverified HEAD
# Branch unv: its HEAD and working tree have no record at all.
git -C "$R" switch -q -c unv feat
echo u >"$R/u.txt"
commit "unverified"

gate "git -C $R commit -m x" "$TMP"
check "commit: git -C <dir> commit from elsewhere is gated" 2 "$CODE"

# Forms that need no record must pass even here.
git -C "$R" branch doomed unv
gate 'git push origin --delete doomed'
check "push: deleting an existing unverified branch needs no record" 0 "$CODE"
gate 'git push --tags'
check "push: --tags on an unverified HEAD needs no record" 0 "$CODE"
git -C "$R" tag v-unv
gate 'git push origin v-unv'
check "push: a tag on an unverified commit needs no record" 0 "$CODE"

# git and gh behind shell keywords and wrappers are still commands.
for cmd in 'if git push; then :; fi' '! git push' 'time git push' 'env X=1 git push' 'command git push' \
  '/usr/bin/git push' 'timeout 60 git push' 'nohup git push'; do
  gate "$cmd"
  check "wrapped: $cmd" 2 "$CODE"
done
gate 'gh pr new --title t'
check "gh pr new is gh pr create" 2 "$CODE"

# A command split over lines with backslashes is one command.
git -C "$R" switch -q feat
gate "$(printf 'git push -u \\\n  origin unv')"
check "continuation: git push -u \\ origin unv is checked" 2 "$CODE"
gate "$(printf 'gh pr create --title t \\\n  --head unv')"
check "continuation: gh pr create ... \\ --head unv is checked" 2 "$CODE"

# The message says how to verify a branch that isn't checked out.
gate 'git push origin unv'
check "push: names the branch to check out" true "$(said 'check out unv')"

# Matching pushes send every branch: blocked like --all.
gate 'git push origin :'
check "push: the : refspec pushes every matching branch" 2 "$CODE"
git -C "$R" config push.default matching
gate 'git push'
check "push: push.default=matching pushes every matching branch" 2 "$CODE"
git -C "$R" config --unset push.default

# A commit and a push in one call: the push would send a commit the hook
# never saw.
gate 'git commit -m x && git push'
check "same call: git commit then git push is blocked" 2 "$CODE"
check "same call: says to push in its own call" true "$(said 'own Bash call')"

# gh pr create uses the branch on GitHub: origin's copy counts, not a local
# one of the same name.
git -C "$R" update-ref refs/remotes/origin/feat "$(git -C "$R" rev-parse unv)"
gate 'gh pr create --head feat'
check "pr create: origin's copy of the head is what's checked" 2 "$CODE"
git -C "$R" update-ref -d refs/remotes/origin/feat
gate 'gh pr create --head nosuch'
check "pr create: a head that can't be found blocks" 2 "$CODE"

# gh pr create with no --head: gh may push the local tip, so a local branch
# ahead of a verified origin copy is checked too.
git -C "$R" update-ref refs/remotes/origin/unv "$(git -C "$R" rev-parse feat)"
git -C "$R" switch -q unv
gate 'gh pr create --title t'
check "pr create: no --head, an unverified local tip blocks even when origin's copy passed" 2 "$CODE"
gate 'gh pr create -Hfeat --title t'
check "pr create: -H<branch> attached is an explicit head" 0 "$CODE"
git -C "$R" switch -q feat
git -C "$R" update-ref -d refs/remotes/origin/unv

# Pushes the hook can't resolve branch by branch are blocked like --all.
git -C "$R" config remote.origin.push 'refs/heads/*:refs/heads/*'
gate 'git push'
check "push: a configured remote.origin.push is blocked" 2 "$CODE"
git -C "$R" config --unset remote.origin.push
git -C "$R" config remote.backup.push 'refs/heads/*:refs/heads/*'
gate 'git push origin'
check "push: another remote's push setting doesn't block a push to origin" 0 "$CODE"
git -C "$R" config --unset remote.backup.push
gate "git push origin 'refs/heads/*:refs/heads/*'"
check "push: a wildcard refspec is blocked" 2 "$CODE"
gate "git push origin 'refs/tags/v1.*:refs/tags/v1.*'"
check "push: a wildcard refspec of tags only needs no record" 0 "$CODE"

# gh stack sync rebases and pushes in one go: blocked in favour of
# rebase, verify, push.
jq -n '{branches: [{name: "feat", isMerged: false, isQueued: false}]}' >"$FX/stack.json"
gate 'gh stack sync'
check "stack sync: blocked" 2 "$CODE"
check "stack sync: says to rebase, verify, then push" true "$(said 'gh stack rebase')"
# A warning on stderr doesn't hide the branches; output that isn't the
# expected JSON blocks.
printf '#!/bin/bash\necho "warning: something" >&2\ncat "$FX/stack.json"\n' >"$TMP/bin/gh-warn"
cp "$TMP/bin/gh" "$TMP/gh.orig"
cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "warning: update available" >&2
case "$*" in "stack view --json") cat "$FX/stack.json" ;; *) exit 1 ;; esac
EOF
jq -n '{branches: [{name: "unv", isMerged: false, isQueued: false}]}' >"$FX/stack.json"
gate 'gh stack push'
check "stack: a warning on stderr doesn't hide unverified branches" 2 "$CODE"
echo '{"stack": {}}' >"$FX/stack.json"
gate 'gh stack push'
check "stack: output without a branch list blocks" 2 "$CODE"
mv "$TMP/gh.orig" "$TMP/bin/gh"
rm -f "$FX/stack.json" "$TMP/bin/gh-warn"

# ----------------------------------------------------------------- gate off
OFF="$TMP/off"
git init -q -b main "$OFF"
echo x >"$OFF/x"
git -C "$OFF" add -A && git -C "$OFF" commit -q -m x
# A switch changes which branch's settings apply, so a push chained after one
# stays blocked even where the current branch has no checks.
gate 'git switch other && git push origin other' "$OFF"
check "gate off: git switch then push is still blocked" 2 "$CODE"
for cmd in 'git commit -m y' 'git push' 'gh pr create' 'git commit -m y && git push'; do
  gate "$cmd" "$OFF"
  check "gate off: $cmd allowed" 0 "$CODE"
done
gate 'git commit -m y' "$TMP"
check "not a git repo: allowed" 0 "$CODE"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
