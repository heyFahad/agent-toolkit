#!/bin/bash
# Tests for ready-gate.sh. A temp repo with an origin on github.com, a stub
# gh that answers `pr view` from a fixture, and a stub pre-prod resolver.
# Run: bash plugins/git-workflow/hooks/tests/ready-gate.test.sh
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../ready-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export FX="$TMP/fx" GHLOG="$TMP/ghlog"
mkdir -p "$FX"

cat >"$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "$(pwd -P)|$*" >>"$GHLOG"
if [ -n "${GH_FAIL:-}" ]; then echo "$GH_FAIL" >&2; exit 1; fi
case "$1 $2" in
  "pr view") cat "$FX/view.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
cat >"$TMP/resolver" <<'EOF'
#!/bin/bash
if [ "${1:-}" = --default ]; then echo main; exit 0; fi
case "$RESOLVE" in
  2) echo "ambiguous: dev staging" >&2; exit 2 ;;
  3) exit 3 ;;
  *) echo "$RESOLVE" ;;
esac
EOF
chmod +x "$TMP/bin/gh" "$TMP/resolver"
export PATH="$TMP/bin:$PATH" AGENT_TOOLKIT_PREPROD_RESOLVER="$TMP/resolver" RESOLVE=staging

R="$TMP/repo"
git init -q "$R"
git -C "$R" remote add origin https://github.com/O/r.git
mkdir -p "$R/sub"

pass=0 fail=0
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

# view BASE [LABEL...]: what `gh pr view` answers.
view() {
  local base=$1
  shift
  jq -n --arg b "$base" --arg u "${VIEW_URL:-https://github.com/o/r/pull/5}" '{baseRefName: $b, url: $u,
    labels: ($ARGS.positional | map({name: .}))}' --args "$@" >"$FX/view.json"
}

# gate CMD [CWD]: "allow" or "block" (exit 2), or "exit N".
gate() {
  : >"$GHLOG"
  jq -n --arg cwd "${2:-$R}" --arg c "$1" '{cwd: $cwd, tool_input: {command: $c}}' |
    bash "$HOOK" >/dev/null 2>"$TMP/stderr"
  local code=$?
  case $code in
    0) echo allow ;;
    2) echo block ;;
    *) echo "exit $code" ;;
  esac
}
said() { grep -qi -- "$1" "$TMP/stderr" && echo true || echo false; }

view staging bug
check "pre-prod PR without the label" block "$(gate 'gh pr ready 5')"
check "  says to ask the user" true "$(said 'ask the user to test the running app')"
check "  names the PR" true "$(said 'https://github.com/o/r/pull/5')"

view staging bug Manually-Verified
check "pre-prod PR with the label, any case" allow "$(gate 'gh pr ready 5')"

view main
check "main PR in a repo with a pre-prod branch" block "$(gate 'gh pr ready 5')"
check "  says it stays a draft" true "$(said 'draft')"
check "main PR in a repo without one" allow "$(RESOLVE=3 gate 'gh pr ready 5')"

view feat/PROJ-1-a
check "stacked PR into the branch below" allow "$(gate 'gh pr ready 5')"
check "stacked PR, repo without pre-prod" allow "$(RESOLVE=3 gate 'gh pr ready 5')"

view staging manually-verified
check "ambiguous resolver" block "$(RESOLVE=2 gate 'gh pr ready 5')"
check "  says to settle it" true "$(said 'resolve-preprod-branch.sh --set')"
check "gh lookup fails" block "$(GH_FAIL='HTTP 401: Bad credentials' gate 'gh pr ready 5')"
check "  passes gh's error on" true "$(said 'Bad credentials')"
check "-R another repo" block "$(gate 'gh pr ready 5 -R other/repo')"
check "  makes no gh call" 0 "$(wc -l <"$GHLOG" | tr -d ' ')"
check "--repo= another repo" block "$(gate 'gh pr ready 5 --repo=other/repo')"
check "URL of another repo" block "$(gate 'gh pr ready https://github.com/other/repo/pull/5')"
check "-R this repo, other case" allow "$(gate 'gh pr ready 5 -R o/R')"
check "  passes -R on" true "$(grep -q -- '-R o/R' "$GHLOG" && echo true || echo false)"
check "outside a repo" block "$(gate 'gh pr ready 5' "$TMP")"

check "--undo passes" allow "$(gate 'gh pr ready 5 --undo')"
check "  makes no gh call" 0 "$(wc -l <"$GHLOG" | tr -d ' ')"
check "echo passes" allow "$(gate 'echo gh pr ready 5')"
check "other gh calls pass" allow "$(gate 'gh pr view 5')"

view staging
check "no argument, after cd" block "$(gate 'cd sub && gh pr ready')"
check "  looks up the current branch's PR from sub" "$(cd "$R/sub" && pwd -P)|pr view --json baseRefName,labels,url" "$(head -1 "$GHLOG")"
check "URL of this repo" block "$(gate 'gh pr ready https://github.com/o/r/pull/5')"
check "  looks up that URL" true "$(grep -qF 'pr view https://github.com/o/r/pull/5 --json' "$GHLOG" && echo true || echo false)"
check "branch name" block "$(gate 'gh pr ready feat/PROJ-1-a')"
check "  looks up that branch" true "$(grep -qF 'pr view feat/PROJ-1-a --json' "$GHLOG" && echo true || echo false)"
check "second of two commands" block "$(gate 'git status; gh pr ready 5')"


# Operators right after `ready`, and a continued line, still reach the gate.
view staging
for c in 'gh pr ready;echo ok' 'gh pr ready&&devstack down' '(gh pr ready)' 'gh pr ready|cat' $'gh pr \\\n  ready 5'; do
  check "operator form: $c" block "$(gate "$c")"
done
check "-R before ready" block "$(gate 'gh pr -R o/r ready 5')"
check "  looks the PR up" true "$(grep -qF 'pr view 5 --json' "$GHLOG" && echo true || echo false)"
# From here the PR has the label, so only the repo check can block.
view staging manually-verified
check "-R another repo before ready" block "$(gate 'gh pr -R other/repo ready 5')"
check "  makes no gh call" 0 "$(wc -l <"$GHLOG" | tr -d ' ')"
check "GH_REPO prefix naming another repo" block "$(gate 'GH_REPO=other/repo gh pr ready 5')"
check "  makes no gh call" 0 "$(wc -l <"$GHLOG" | tr -d ' ')"
check "exported GH_REPO naming another repo" block "$(gate 'export GH_REPO=other/repo; gh pr ready 5')"
check "GH_REPO from the environment" block "$(GH_REPO=other/repo gate 'gh pr ready 5')"
check "URL of another repo despite -R" block "$(gate 'gh pr ready https://github.com/other/x/pull/5 -R o/r')"
check "GH_REPO naming this repo" allow "$(gate 'GH_REPO=o/r gh pr ready 5')"
check "redirection isn't the PR argument" allow "$(gate 'gh pr ready 5 2>&1')"
check "  looks up PR 5" true "$(grep -qF 'pr view 5 --json' "$GHLOG" && echo true || echo false)"
check "spaced redirection isn't the PR argument" allow "$(gate 'gh pr ready > /dev/null')"
check "  looks up the current branch" true "$(grep -qF '|pr view --json' "$GHLOG" && echo true || echo false)"

# The PR gh actually resolves (gh repo set-default can point at another remote).
VIEW_URL=https://github.com/other/repo/pull/5 view staging manually-verified
check "the PR gh resolves is in another repo" block "$(gate 'gh pr ready 5')"
check "  says which" true "$(said 'other/repo')"
view staging manually-verified

# Readying after a base or label change in the same call: the lookup would see
# the PR as it was before the edit.
check "base change, then ready" block "$(gate 'gh pr edit 5 --base staging && gh pr ready 5')"
check "  says to run it on its own" true "$(said 'its own Bash call')"
check "-B change, then ready" block "$(gate 'gh pr edit 5 -B staging; gh pr ready 5')"
check "label change, then ready" block "$(gate 'gh pr edit 5 --remove-label manually-verified && gh pr ready 5')"
check "label removal, then ready --undo" allow "$(gate 'gh pr edit 5 --remove-label manually-verified && gh pr ready 5 --undo')"
check "title change, then ready" allow "$(gate 'gh pr edit 5 --title t && gh pr ready 5')"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
