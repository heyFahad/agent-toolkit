#!/bin/bash
# Tests for the verify script and its lib. No dependencies beyond bash, git
# and jq: package managers are stubs on PATH, Node versions are fake nvm
# folders. Runs under macOS's bash 3.2.
# Run: bash skills/verify/scripts/tests/verify.test.sh
set -uo pipefail
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands below that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
# Keep the user's own git config (signing, hooks, default branch) out of it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# Comments and echoed text in a workflow aren't CI running a script.
R=$(mkrepo wfnoise '{"lint":"l","test":"t","build":"b"}' "" "$(printf 'npm run lint\necho "run npm test locally"\nnpm run build && echo built')")
printf '      # npm test is flaky, skipped for now\n' >>"$R/.github/workflows/ci.yml"
git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m noise
run_verify "$R" --list
check "list: comments and echoed text don't count, a command next to an echo does" '["lint","build"]' "$(q '[.[].name]')"

R=$(mkrepo nowf '{"lint":"l","test":"t"}' pnpm-lock.yaml "")
run_verify "$R" --list
check "list: no workflow runs any script" '[]' "$OUT"

# `npm ci` is npm's install command, not the "ci" script; only `npm run ci`
# runs that.
R=$(mkrepo builtin '{"ci":"npm run lint","lint":"l"}' "" "$(printf 'npm ci\nnpm run lint')")
run_verify "$R" --list
check "list: npm ci isn't the ci script" '["lint"]' "$(q '[.[].name]')"

# CI's own arguments come along; a step CI ignores (|| true) isn't a check.
R=$(mkrepo args '{"lint":"l","test":"t","audit:deps":"a"}' "" \
  "$(printf 'npm run lint -- --max-warnings=0\nnpm run test -- --run\nnpm run audit:deps || true')")
run_verify "$R" --list
check "list: CI's arguments are kept" '["CI=true npm run lint -- --max-warnings=0","CI=true npm run test -- --run"]' "$(q '[.[].run]')"

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
  '["CI=true npm run lint","CI=true npx --no-install jest --maxWorkers=50% --findRelatedTests --passWithNoTests a.ts b.ts"]' "$(q '[.[].run]')"

R=$(mkrepo vitest '{"lint":"l","test":"t","build":"b"}' pnpm-lock.yaml "$(printf 'pnpm lint\npnpm test\npnpm build')" '{"vitest":"^2"}')
run_verify "$R" --list --related src/a.ts
check "list: related with vitest" \
  '["CI=true pnpm run lint","CI=true pnpm exec vitest related --run --passWithNoTests --maxWorkers=50% src/a.ts"]' "$(q '[.[].run]')"
run_verify "$R" --list --related
check "list: related, no changed files" '["CI=true pnpm run lint"]' "$(q '[.[].run]')"

# The related level runs the type scripts too, not only format and lint.
R=$(mkrepo relty '{"lint":"l","typecheck":"tc","test":"t","build":"b"}' "" \
  "$(printf 'npm run lint\nnpm run typecheck\nnpm test\nnpm run build')" '{"jest":"^29"}')
run_verify "$R" --list --related a.ts
check "list: related runs lint, typecheck and related tests" '["lint","typecheck","related-tests"]' "$(q '[.[].name]')"

# ------------------------------------------------------------- worker caps
# A script that is one jest or vitest call gets the cap at the full level;
# npm needs `--` to pass it on, the others don't; after CI's own `--` it
# comes last.
R=$(mkrepo capnpm '{"test":"jest","test:e2e":"cross-env X=1 jest -c e2e.js"}' "" \
  "$(printf 'npm test\nnpm run test:e2e -- --ci')" '{"jest":"^29"}')
run_verify "$R" --list
check "caps: jest under npm, with and without CI's arguments" \
  '["CI=true npm run test -- --maxWorkers=50%","CI=true npm run test:e2e -- --ci --maxWorkers=50%"]' "$(q '[.[].run]')"
R=$(mkrepo cappnpm '{"test":"vitest run"}' pnpm-lock.yaml 'pnpm test' '{"vitest":"^3.1.0"}')
run_verify "$R" --list
check "caps: vitest under pnpm, no --" '["CI=true pnpm run test --maxWorkers=50%"]' "$(q '[.[].run]')"
R=$(mkrepo capnone '{"test":"jest && node after.js","test:serial":"jest --runInBand","test:w":"jest","test:node":"node t.js"}' "" \
  "$(printf 'npm test\nnpm run test:serial\nnpm run test:w -- -w 2\nnpm run test:node')" '{"jest":"^29"}')
run_verify "$R" --list
check "caps: none for chained scripts, a worker count of their own, or no jest" \
  '["CI=true npm run test","CI=true npm run test:node","CI=true npm run test:serial","CI=true npm run test:w -- -w 2"]' "$(q '[.[].run]')"
R=$(mkrepo capold '{"lint":"l","test":"vitest run"}' "" "$(printf 'npm run lint\nnpm test')" '{"vitest":"^0.34.6"}')
run_verify "$R" --list
check "caps: vitest 0.x has no --maxWorkers" '["CI=true npm run lint","CI=true npm run test"]' "$(q '[.[].run]')"
run_verify "$R" --list --related a.ts
check "caps: nor for related tests" '"CI=true npx --no-install vitest related --run --passWithNoTests a.ts"' "$(q '.[1].run')"

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

# An object-form related maps changed paths to the suites that cover them.
jq -n '{repos: {"owner/repo": {checks: [{name: "all", run: "make all"}], related: {
  run: "shellcheck {files}",
  paths: {
    "skills/check-pr/**": "bash skills/check-pr/tests/t.sh",
    "skills/*/SKILL.md": "lint-skill {files}",
    "**/*.json": "jq . {files}",
    "plugins/x/**": "bash skills/check-pr/tests/t.sh"}}}}}' >"$CFG"
run_verify "$R" --list --related skills/check-pr/scripts/a.sh skills/verify/SKILL.md skills/verify/deep/SKILL.md README.md
check "paths: each matching glob's command, {files} as the files it matched" \
  "$(jq -nc '[{name: "related", run: "shellcheck skills/check-pr/scripts/a.sh skills/verify/SKILL.md skills/verify/deep/SKILL.md README.md"},
    {name: "related skills/check-pr/**", run: "bash skills/check-pr/tests/t.sh"},
    {name: "related skills/*/SKILL.md", run: "lint-skill skills/verify/SKILL.md"}]')" "$OUT"
run_verify "$R" --list --related a.json sub/dir/b.json
check "paths: **/ matches no directory or many" '["shellcheck a.json sub/dir/b.json","jq . a.json sub/dir/b.json"]' "$(q '[.[].run]')"
run_verify "$R" --list --related skills/check-pr/x plugins/x/y
check "paths: two globs with the same command run it once" '["shellcheck skills/check-pr/x plugins/x/y","bash skills/check-pr/tests/t.sh"]' "$(q '[.[].run]')"
jq '.repos["owner/repo"].related |= del(.run)' "$CFG" >"$CFG.tmp" && mv "$CFG.tmp" "$CFG"
run_verify "$R" --list --related docs/x.md 'a b.json'
check "paths: no run, only the matching globs, files quoted" \
  "$(jq -nc --arg r "jq . $(printf '%q' 'a b.json')" '[$r]')" "$(q '[.[].run]')"
run_verify "$R" --list --related docs/x.md
check "paths: nothing matched, nothing to run" '[]' "$OUT"
run_verify "$R" --list
check "paths: the full level is still the checks" '["make all"]' "$(q '[.[].run]')"
# A list of commands per glob, and {file} for one run per file: a suite both
# its source and its test file pick runs once.
jq -n '{repos: {"owner/repo": {checks: [{name: "all", run: "make all"}], related: {paths: {
  "**/*.test.sh": "bash {file}",
  "src/a.sh": ["bash tests/a.test.sh", "bash tests/b.test.sh"]}}}}}' >"$CFG"
run_verify "$R" --list --related src/a.sh tests/a.test.sh 'tests/c d.test.sh'
check "paths: {file} runs per file, a list runs each, the same command once" \
  "$(jq -nc --arg c "bash $(printf '%q' 'tests/c d.test.sh')" '["bash tests/a.test.sh", $c, "bash tests/b.test.sh"]')" "$(q '[.[].run]')"
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

# A tree nothing has verified yet (the ones above already have records).
echo r >"$R/r.txt"
run_verify "$R" --related
TREE=$(lib vf_tree "$R")
check "run: related record does not satisfy full" 1 "$(lib vf_record_ok "$TREE" full; echo $?)"
check "run: related record satisfies related" 0 "$(lib vf_record_ok "$TREE" related; echo $?)"
run_verify "$R" --full
check "run: full record satisfies related" 0 "$(lib vf_record_ok "$TREE" related; echo $?)"
rm "$R/r.txt"

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

# CI runs only a test script and there's no jest or vitest: nothing is quick
# enough for --related, but the repo's gate is on, so the run still counts.
R=$(mkrepo runrelnone '{"test":"echo t"}' "" 'npm test')
echo x >"$R/x.ts"
run_verify "$R" --related
check "run: related with nothing to run still records a pass" 0 "$(lib vf_record_ok "$(lib vf_tree "$R")" related; echo $?)"
check "run: and doesn't call the gate off" false "$(printf '%s' "$OUT" | grep -q 'gate off' && echo true || echo false)"

# A passing --related run on the same tree keeps an earlier --full pass.
R=$(mkrepo keepfull '{"lint":"echo l","test":"echo t"}' "" "$(printf 'npm run lint\nnpm test')")
run_verify "$R" --full
run_verify "$R" --related
check "run: a later --related pass keeps the --full record" 0 "$(lib vf_record_ok "$(lib vf_tree "$R")" full; echo $?)"

# Untracked files the run saw are listed, and kept in the record.
echo n >"$R/new.ts"
run_verify "$R" --full
check "run: untracked files are listed" true "$(printf '%s' "$OUT" | grep -q 'new.ts' && echo true || echo false)"
run_verify "$R" --status
check "run: and kept in the record" '["new.ts"]' "$(q .untracked)"
rm "$R/new.ts"

# Naming files checks only those: useful while working, but no record.
echo x >>"$R/package.json"
run_verify "$R" --related package.json
check "run: --related with named files runs" 0 "$CODE"
check "run: but records nothing" 1 "$(lib vf_record_ok "$(lib vf_tree "$R")" related; echo $?)"
check "run: and says so" true "$(printf '%s' "$OUT" | grep -q 'no record' && echo true || echo false)"
git -C "$R" checkout -q package.json

# --list wins over --full whichever comes first.
run_verify "$R" --list --full
check "run: --list --full only lists" '["lint","test"]' "$(q '[.[].name]')"

# Old logs and records are pruned.
mkdir -p "$AGENT_TOOLKIT_STATE_DIR/verify/logs"
touch -t 202001010000 "$AGENT_TOOLKIT_STATE_DIR/verify/old.json" "$AGENT_TOOLKIT_STATE_DIR/verify/logs/old.log"
run_verify "$R" --full
check "run: records and logs older than 14 days are pruned" false \
  "$([ -e "$AGENT_TOOLKIT_STATE_DIR/verify/old.json" ] || [ -e "$AGENT_TOOLKIT_STATE_DIR/verify/logs/old.log" ] && echo true || echo false)"

# -------------------------------------------------------------------- branch
# --branch runs the quick checks on every file the branch changes since it
# left the default branch: committed, uncommitted and untracked, but not
# what the default branch changed since.
R=$(mkrepo br '{"lint":"echo l","test":"echo t"}' "" "$(printf 'npm run lint\nnpm test')" '{"jest":"^29"}')
git -C "$R" branch -q -M main
echo m >"$R/main-later.ts"
git -C "$R" switch -q -c feat
git -C "$R" switch -q main
git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m later
git -C "$R" update-ref refs/remotes/origin/main main
git -C "$R" switch -q feat
echo c >"$R/committed.ts"
echo e >"$R/edited.ts"
git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m c
echo u >>"$R/edited.ts"
echo n >"$R/new.ts"
run_verify "$R" --list --branch
check "branch: related checks over every file the branch changes" \
  '["CI=true npm run lint","CI=true npx --no-install jest --maxWorkers=50% --findRelatedTests --passWithNoTests committed.ts edited.ts new.ts"]' "$(q '[.[].run]')"
git -C "$R" checkout -q edited.ts
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/npx"
chmod +x "$TMP/bin/npx"
run_verify "$R" --branch
check "branch: runs and says how many files" '[0,true]' "[$CODE,$(printf '%s' "$OUT" | grep -q 'checks the 3 files this branch changes' && echo true || echo false)]"
TREE=$(lib vf_tree "$R")
check "branch: records the branch level" branch "$(jq -r .level "$AGENT_TOOLKIT_STATE_DIR/verify/$TREE.json")"
check "branch: satisfies related and branch, not full" '0 0 1' \
  "$(lib vf_record_ok "$TREE" related; echo -n "$? "; lib vf_record_ok "$TREE" branch; echo -n "$? "; lib vf_record_ok "$TREE" full; echo $?)"
run_verify "$R" --related
check "branch: a later --related pass keeps the --branch record" 0 "$(lib vf_record_ok "$TREE" branch; echo $?)"
run_verify "$R" --full
run_verify "$R" --branch
check "branch: a later --branch pass keeps the --full record" 0 "$(lib vf_record_ok "$TREE" full; echo $?)"
# origin/HEAD, when set, names the default branch.
git -C "$R" update-ref refs/remotes/origin/trunk "$(git -C "$R" rev-parse feat)"
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
check "branch: origin/HEAD is the base when set" "$(git -C "$R" rev-parse feat)" "$(lib vf_branch_base "$R")"
git -C "$R" symbolic-ref --delete refs/remotes/origin/HEAD
# Nothing to diff against: --branch runs every check instead.
git -C "$R" update-ref -d refs/remotes/origin/main
git -C "$R" update-ref -d refs/remotes/origin/trunk
echo x >"$R/x.ts"
run_verify "$R" --branch
check "branch: no default branch falls back to --full, and says so" '[0,true,"full"]' \
  "[$CODE,$(printf '%s' "$OUT" | grep -q 'runs every check' && echo true || echo false),\"$(jq -r .level "$AGENT_TOOLKIT_STATE_DIR/verify/$(lib vf_tree "$R").json")\"]"

rm "$TMP/bin/npx"

# firstPush in the config: per repo, or for every repo at the top.
check "branch: the first push needs --branch by default" branch "$(lib vf_first_push_level "$R")"
echo '{"firstPush": "full"}' >"$CFG"
check "branch: firstPush full at the top applies to every repo" full "$(lib vf_first_push_level "$R")"
echo '{"firstPush": "full", "repos": {"owner/br": {"firstPush": "branch"}}}' >"$CFG"
check "branch: a repo's own firstPush wins" branch "$(lib vf_first_push_level "$R")"
rm "$CFG"

# ---------------------------------------------------------------------- lock
# One run at a time on the machine: a second run waits for the first, and
# says whose run it's queued behind.
LOCK="$AGENT_TOOLKIT_STATE_DIR/verify/run.lock"
export VF_LOCK_POLL=0.1
A=$(mkrepo locka '{"lint":"sleep 1; touch '"$TMP"'/a-done"}' "" 'npm run lint')
B=$(mkrepo lockb '{"lint":"test -f '"$TMP"'/a-done"}' "" 'npm run lint')
rm -f "$TMP/a-done"
(cd "$A" && bash "$S/verify" --full >"$TMP/a-out" 2>&1) &
apid=$!
for _ in $(seq 50); do [ -f "$LOCK/owner" ] && break; sleep 0.1; done
check "lock: a run holds the lock, naming its repo" owner/locka "$(sed -n 's/^repo=//p' "$LOCK/owner" 2>/dev/null)"
run_verify "$B" --full
wait "$apid"
check "lock: a second run waits for the first to finish" 0 "$CODE"
check "lock: and says whose run it's queued behind" true "$(printf '%s' "$OUT" | grep -q 'queued behind the verify run for owner/locka' && echo true || echo false)"
check "lock: released after the run" false "$([ -e "$LOCK" ] && echo true || echo false)"

# A lock whose holder died is stale: the next run takes it over.
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir -p "$LOCK"
printf 'pid=%s\nrepo=owner/gone\nat=then\n' "$dead" >"$LOCK/owner"
run_verify "$B" --full
check "lock: a dead holder's lock is taken over" 0 "$CODE"
check "lock: and says so" true "$(printf '%s' "$OUT" | grep -q 'stale lock left by pid' && echo true || echo false)"
check "lock: released after the run" false "$([ -e "$LOCK" ] && echo true || echo false)"

# A live PID that started at another time isn't the holder: its PID was
# reused. Only where ps can say when a process started.
if [ -n "$(lib _vf_proc_start $$)" ]; then
  mkdir -p "$LOCK"
  printf 'pid=%s\nstart=Thu Jan  1 00:00:00 1970\nrepo=owner/old\nat=then\n' "$$" >"$LOCK/owner"
  run_verify "$B" --full
  check "lock: a reused PID's lock is stale" '[0,true]' "[$CODE,$(printf '%s' "$OUT" | grep -q 'stale lock' && echo true || echo false)]"
fi

# A lock with no owner a minute after it was made is stale too.
mkdir -p "$LOCK"
touch -t 202001010000 "$LOCK"
run_verify "$B" --full
check "lock: an ownerless lock from long ago is taken over" '[0,true]' "[$CODE,$(printf '%s' "$OUT" | grep -q 'stale lock' && echo true || echo false)]"

# A run a check starts (a test suite that runs verify) shares the lock its
# parent holds rather than waiting on it.
sleep 30 &
holder=$!
mkdir -p "$LOCK"
printf 'pid=%s\nstart=%s\nrepo=owner/parent\nat=now\n' "$holder" "$(lib _vf_proc_start "$holder")" >"$LOCK/owner"
OUT=$(cd "$B" && VF_LOCK_HELD="$LOCK" bash "$S/verify" --full 2>"$TMP/stderr")
CODE=$?
check "lock: a nested run doesn't wait on its parent's lock" '[0,false]' "[$CODE,$(printf '%s' "$OUT" | grep -q queued && echo true || echo false)]"
check "lock: and leaves it in place" owner/parent "$(sed -n 's/^repo=//p' "$LOCK/owner" 2>/dev/null)"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rm -rf "$LOCK"
unset VF_LOCK_POLL

# CI with PR workflows that verify can't read isn't the same as no CI.
R=$(mkrepo shellci '{}' "" 'bash run-tests.sh')
rm "$R/package.json"
run_verify "$R" --full
check "run: CI it can't read says to set an override" true "$(printf '%s' "$OUT" | grep -q 'verify.local.json' && echo true || echo false)"

R=$(mkrepo runoff '{"lint":"l"}' "" "")
rm -rf "$AGENT_TOOLKIT_STATE_DIR"
run_verify "$R" --full
check "run: gate off exits 0" 0 "$CODE"
check "run: gate off says so" true "$(printf '%s' "$OUT" | grep -q 'gate off' && echo true || echo false)"
check "run: gate off writes nothing" 0 "$(find "$AGENT_TOOLKIT_STATE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
