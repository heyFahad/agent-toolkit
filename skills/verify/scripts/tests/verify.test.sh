#!/bin/bash
# Tests for the verify script and its lib. No dependencies beyond bash, git
# and jq: package managers are stubs on PATH, Node versions are fake nvm
# folders. Runs under macOS's bash 3.2.
# Run: bash skills/verify/scripts/tests/verify.test.sh
set -uo pipefail
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands below that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" AGENT_TOOLKIT_STATE_DIR="$TMP/state" NVM_DIR="$TMP/nvm"
mkdir -p "$TMP/bin" "$XDG_CONFIG_HOME/agent-toolkit" "$NVM_DIR/versions/node"
export PATH="$TMP/bin:$PATH"

pass=0 fail=0
OUT="" CODE=0

# check NAME EXPECTED ACTUAL
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
q() { printf '%s' "$OUT" | jq -c "$1" 2>/dev/null || echo "not-json"; }

# run_verify DIR ARGS...: run verify from DIR; stdout to $OUT, exit to $CODE.
run_verify() {
  local dir=$1
  shift
  OUT=$(cd "$dir" && bash "$S/verify" "$@" 2>"$TMP/stderr")
  CODE=$?
}

# mkrepo NAME SCRIPTS_JSON LOCKFILE CI_LINES [DEV_DEPS_JSON]: a repo with
# origin git@github.com:Owner/NAME.git, a package.json with those scripts, the
# lockfile committed (or none for ""), and a pull_request workflow whose run
# lines are CI_LINES (one per line, "" for no workflow).
mkrepo() {
  local d="$TMP/$1"
  rm -rf "$d"
  git init -q "$d"
  git -C "$d" remote add origin "git@github.com:Owner/$1.git"
  local dd=${5:-}
  [ -n "$dd" ] || dd='{}'
  jq -n --argjson s "$2" --argjson dd "$dd" '{name: "x", scripts: $s, devDependencies: $dd}' >"$d/package.json"
  [ -n "$3" ] && : >"$d/$3"
  if [ -n "$4" ]; then
    mkdir -p "$d/.github/workflows"
    {
      printf 'name: CI\non:\n  pull_request:\njobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n'
      printf '%s\n' "$4" | sed 's/^/      - run: /'
    } >"$d/.github/workflows/ci.yml"
  fi
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m init
  echo "$d"
}

# ----------------------------------------------------------------- inference
R=$(mkrepo app '{"build":"b","test":"t","lint":"l","typecheck":"tc","deploy":"d"}' pnpm-lock.yaml \
  "$(printf 'pnpm run lint\npnpm test\npnpm build')")
mkdir -p "$R/.github/workflows"
printf 'on:\n  push:\n    branches: [main]\njobs:\n  d:\n    steps:\n      - run: pnpm run deploy\n' >"$R/.github/workflows/deploy.yml"
git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m deploy
run_verify "$R" --list
check "list: only scripts a pull_request workflow runs" '["lint","test","build"]' "$(q '[.[].name]')"
check "list: runs with CI=true and the lockfile's manager" \
  '["CI=true pnpm run lint","CI=true pnpm run test","CI=true pnpm run build"]' "$(q '[.[].run]')"

R=$(mkrepo order '{"build":"b","test:coverage":"t","docs:check":"d","type-check":"tc","lint":"l","format:check":"f"}' pnpm-lock.yaml \
  "$(printf 'pnpm run build\npnpm run test:coverage\npnpm run docs:check\npnpm run type-check\npnpm run lint\npnpm run format:check')")
run_verify "$R" --list
check "list: order format, lint, type, other, test, build" \
  '["format:check","lint","type-check","docs:check","test:coverage","build"]' "$(q '[.[].name]')"

R=$(mkrepo prefix '{"lint":"l","lint:ci":"lc"}' pnpm-lock.yaml 'pnpm run lint:ci')
run_verify "$R" --list
check "list: a script name that is a prefix of another" '["lint:ci"]' "$(q '[.[].name]')"

R=$(mkrepo prep '{"prepare":"p","lint":"l"}' pnpm-lock.yaml "$(printf 'pnpm prepare\npnpm lint')")
run_verify "$R" --list
check "list: install-time scripts skipped" '["lint"]' "$(q '[.[].name]')"

R=$(mkrepo nowf '{"lint":"l","test":"t"}' pnpm-lock.yaml "")
run_verify "$R" --list
check "list: no workflow runs any script" '[]' "$OUT"

for pair in "yarn.lock:yarn" ":npm" "bun.lock:bun" "package-lock.json:npm"; do
  lock=${pair%%:*} pm=${pair#*:}
  R=$(mkrepo "pm-$pm-${lock:-none}" '{"lint":"l"}' "$lock" 'npm run lint')
  run_verify "$R" --list
  check "list: package manager from ${lock:-no lockfile}" "\"CI=true $pm run lint\"" "$(q '.[0].run')"
done
# A lockfile that isn't committed doesn't count.
R=$(mkrepo uncommitted '{"lint":"l"}' package-lock.json 'npm run lint')
: >"$R/pnpm-lock.yaml"
run_verify "$R" --list
check "list: an uncommitted lockfile doesn't count" '"CI=true npm run lint"' "$(q '.[0].run')"

R=$(mkrepo jest '{"lint":"l","test":"t"}' "" "$(printf 'npm run lint\nnpm test')" '{"jest":"^29"}')
run_verify "$R" --list --related a.ts b.ts
check "list: related with jest" \
  '["CI=true npm run lint","CI=true npx --no-install jest --findRelatedTests --passWithNoTests a.ts b.ts"]' "$(q '[.[].run]')"

R=$(mkrepo vitest '{"lint":"l","test":"t","build":"b"}' pnpm-lock.yaml "$(printf 'pnpm lint\npnpm test\npnpm build')" '{"vitest":"^2"}')
run_verify "$R" --list --related src/a.ts
check "list: related with vitest" \
  '["CI=true pnpm run lint","CI=true pnpm exec vitest related --run --passWithNoTests src/a.ts"]' "$(q '[.[].run]')"
run_verify "$R" --list --related
check "list: related, no changed files" '["CI=true pnpm run lint"]' "$(q '[.[].run]')"

R=$(mkrepo notestci '{"lint":"l","test":"t"}' "" 'npm run lint' '{"jest":"^29"}')
run_verify "$R" --list --related a.ts
check "list: related tests only when CI runs tests" '["CI=true npm run lint"]' "$(q '[.[].run]')"

# ------------------------------------------------------------------ override
CFG="$XDG_CONFIG_HOME/agent-toolkit/verify.local.json"
R=$(mkrepo Repo '{"lint":"l"}' "" 'npm run lint')
echo '{"codexModel":"m","repos":{"owner/repo":{"checks":[{"name":"t","run":"make t"}],"related":"shellcheck {files}"}}}' >"$CFG"
run_verify "$R" --list
check "list: override replaces inference" '[{"name":"t","run":"make t"}]' "$OUT"
run_verify "$R" --list --related a 'b c.sh'
check "list: override related with {files}" \
  "$(jq -nc --arg r "shellcheck $(printf '%q ' a 'b c.sh' | sed 's/ $//')" '[$r]')" "$(q '[.[].run]')"
echo '{"repos":{"owner/repo":{"checks":[{"name":"t","run":"make t"}]}}}' >"$CFG"
run_verify "$R" --list --related a
check "list: override with no related runs the full list" '["make t"]' "$(q '[.[].run]')"
echo '{"repos":{"owner/repo":{"checks":[]}}}' >"$CFG"
run_verify "$R" --list
check "list: empty checks turns the gate off" '[]' "$OUT"
rm "$CFG"

R=$(mkrepo nopkg '{}' "" "")
rm "$R/package.json"
run_verify "$R" --list
check "list: no package.json, no override" '[]' "$OUT"

run_verify "$TMP" --list
check "list: not a git repo exits 2" 2 "$CODE"

# ---------------------------------------------------------------------- node
mkdir -p "$NVM_DIR/versions/node/v22.16.0/bin" "$NVM_DIR/versions/node/v22.9.1/bin"
R=$(mkrepo nodever '{"lint":"l"}' "" 'npm run lint')
echo 22 >"$R/.nvmrc"
OUT=$(bash -c '. "$1/lib.sh"; vf_node_path "$2"' _ "$S" "$R" 2>"$TMP/stderr")
check "node: .nvmrc version found" "$NVM_DIR/versions/node/v22.16.0/bin" "$OUT"
echo 20 >"$R/.nvmrc"
OUT=$(bash -c '. "$1/lib.sh"; vf_node_path "$2"' _ "$S" "$R" 2>"$TMP/stderr")
CODE=$?
check "node: missing version exits 3" 3 "$CODE"
check "node: missing version says how to install it" true "$(grep -q 'nvm install 20' "$TMP/stderr" && echo true || echo false)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
