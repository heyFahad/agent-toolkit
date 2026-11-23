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

# ----------------------------------------------------------------------- run
# A stub npm runs the package.json script body with sh and notes the CI it saw.
cat >"$TMP/bin/npm" <<'EOF'
#!/bin/bash
[ "$1" = run ] && shift
echo "CI=${CI:-unset}" >>"$CI_SEEN"
exec sh -c "$(jq -r --arg n "$1" '.scripts[$n]' package.json)"
EOF
chmod +x "$TMP/bin/npm"
export CI_SEEN="$TMP/ci-seen"
lib() { bash -c '. "$1/lib.sh"; shift; "$@"' _ "$S" "$@"; }

R=$(mkrepo runok '{"lint":"echo linted","test":"echo tested"}' "" "$(printf 'npm run lint\nnpm test')")
: >"$CI_SEEN"
run_verify "$R" --full
check "run: full passes" 0 "$CODE"
check "run: one line per check" "$(printf 'PASS lint\nPASS test')" "$(printf '%s' "$OUT" | grep -E '^(PASS|FAIL)')"
run_verify "$R" --status
check "run: record says full, passed, with exit codes" '["full",true,[["lint",0],["test",0]]]' \
  "$(q '[.level, .passed, [.commands[] | [.name, .exit]]]')"
check "run: CI=true reaches the scripts" "$(printf 'CI=true\nCI=true')" "$(cat "$CI_SEEN")"

echo edit >>"$R/package.json"
run_verify "$R" --status
check "run: an edit after verifying means no record" 1 "$CODE"
git -C "$R" checkout -q package.json

# Untracked files are part of the tree; the tracked tree leaves them out.
T1=$(lib vf_tree "$R") K1=$(lib vf_tracked_tree "$R")
echo new >"$R/new.txt"
T2=$(lib vf_tree "$R") K2=$(lib vf_tracked_tree "$R")
check "run: tree covers untracked files" true "$([ "$T1" != "$T2" ] && [ "$K1" = "$K2" ] && echo true || echo false)"
run_verify "$R" --full
check "run: records under both hashes" true \
  "$([ -f "$AGENT_TOOLKIT_STATE_DIR/verify/$T2.json" ] && [ -f "$AGENT_TOOLKIT_STATE_DIR/verify/$K2.json" ] && echo true || echo false)"
rm "$R/new.txt"

# A staged checkpoint stays exactly as the user left it.
echo staged >>"$R/package.json"
git -C "$R" add package.json
echo unstaged >"$R/other.txt"
before_idx=$(shasum "$R/.git/index") before_cached=$(git -C "$R" diff --cached)
run_verify "$R" --full
check "run: the real index is untouched" true \
  "$([ "$before_idx" = "$(shasum "$R/.git/index")" ] && [ "$before_cached" = "$(git -C "$R" diff --cached)" ] && echo true || echo false)"
git -C "$R" reset -q --hard && rm -f "$R/other.txt"

run_verify "$R" --related
TREE=$(lib vf_tree "$R")
check "run: related record does not satisfy full" 1 "$(lib vf_record_ok "$TREE" full; echo $?)"
check "run: related record satisfies related" 0 "$(lib vf_record_ok "$TREE" related; echo $?)"
run_verify "$R" --full
check "run: full record satisfies related" 0 "$(lib vf_record_ok "$TREE" related; echo $?)"

R=$(mkrepo runfail '{"lint":"echo bad lint; exit 1","test":"touch ran-test"}' "" "$(printf 'npm run lint\nnpm test')")
run_verify "$R" --full
check "run: stops at the first failure" '[1,false]' "[$CODE,$([ -f "$R/ran-test" ] && echo true || echo false)]"
check "run: failure shows the check and its output" true \
  "$(printf '%s' "$OUT" | grep -q '^FAIL lint (exit 1)' && printf '%s' "$OUT" | grep -q 'bad lint' && echo true || echo false)"
run_verify "$R" --status
check "run: failed record says so" false "$(q .passed)"

R=$(mkrepo runfmt '{"format":"echo x >> a.txt"}' "" 'npm run format')
echo a >"$R/a.txt"
git -C "$R" add a.txt && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m a
run_verify "$R" --full
check "run: a check that changes tracked files fails" 1 "$CODE"
check "run: and names the file" true "$(printf '%s' "$OUT" | grep -q 'a.txt' && echo true || echo false)"

R=$(mkrepo runbuild '{"build":"mkdir -p out && echo x > out/b.js"}' "" 'npm run build')
run_verify "$R" --full
check "run: untracked build output doesn't fail the run" 0 "$CODE"
check "run: and the record matches the tree after the run" 0 "$(lib vf_record_ok "$(lib vf_tree "$R")" full; echo $?)"

R=$(mkrepo runoff '{"lint":"l"}' "" "")
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
run_verify "$R" --full
check "run: gate off exits 0" 0 "$CODE"
check "run: gate off says so" true "$(printf '%s' "$OUT" | grep -q 'gate off' && echo true || echo false)"
check "run: gate off writes nothing" 0 "$(find "$AGENT_TOOLKIT_STATE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
