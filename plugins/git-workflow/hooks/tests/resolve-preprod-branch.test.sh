#!/bin/bash
# Tests for skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh,
# the pre-prod branch resolver the hook and skills share. Uses a temp repo
# with a bare origin; `gh` is a stub on PATH.
# Run: bash plugins/git-workflow/hooks/tests/resolve-preprod-branch.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RESOLVER="$HERE/../../../../skills/branching-pr-workflow/scripts/resolve-preprod-branch.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AGENT_TOOLKIT_STATE_DIR="$TMP/state"
export AGENT_TOOLKIT_CONFIG_DIR="$TMP/config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir -p "$TMP/bin"
# The resolver asks for merged PRs with --jq '.[].baseRefName', so the stub
# prints one base branch per line. An empty STUB_PR_BASES means gh failed.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "repo view"*) echo "$STUB_DEFAULT" ;;
  "pr list"*) [ -s "$STUB_PR_BASES" ] || exit 1; cat "$STUB_PR_BASES" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_DEFAULT=main STUB_PR_BASES="$TMP/pr-bases"

git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git commit -q --allow-empty -m initial
git push -q origin HEAD:main

pass=0 fail=0

expect() { # name, expected stdout, expected exit code, [args]
  local out code
  out=$(bash "$RESOLVER" ${4:-} 2>/dev/null)
  code=$?
  if [ "$out" = "$2" ] && [ "$code" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (wanted \"$2\" exit $3, got \"$out\" exit $code)"
  fi
}
reset_state() { rm -rf "$AGENT_TOOLKIT_STATE_DIR" "$AGENT_TOOLKIT_CONFIG_DIR"; }
branches() { for b in "$@"; do git push -q origin HEAD:"$b"; done; }
counts() { : > "$STUB_PR_BASES"; while [ $# -gt 0 ]; do i=0; while [ $i -lt "$2" ]; do echo "$1" >> "$STUB_PR_BASES"; i=$((i + 1)); done; shift 2; done; }

# --- no pre-prod branch, and short-lived names never count
branches release/2026.09.30 feature/x fix/y conflicts/T-1-z chore/w
counts main 5
expect "none"                   "" 3
reset_state

# --- one candidate needs no PR history
branches dev
: > "$STUB_PR_BASES"
expect "only dev"               "dev" 0
reset_state

# --- dev and staging both exist, every merged PR went to dev
branches staging
counts dev 156 main 27 release/2026.09.30 6
expect "most merged PRs"        "dev" 0
# cached: a change in PR history doesn't flip it until --refresh
counts staging 9 dev 1
expect "cached"                 "dev" 0
expect "refresh"                "staging" 0 --refresh
reset_state

# --- ties, no merges into any candidate, or no gh: ask the user
counts dev 4 staging 4
expect "tie"                    "" 2
counts main 10
expect "no merges"              "" 2
: > "$STUB_PR_BASES"
expect "gh unavailable"         "" 2
err=$(bash "$RESOLVER" 2>&1 >/dev/null)
case "$err" in *"--set <branch>"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL: ambiguous message doesn't say how to save the answer: $err" ;; esac
reset_state

# --- the default branch is never its own pre-prod branch
STUB_DEFAULT=dev expect "default excluded" "staging" 0
reset_state

# --- overrides win over inference, and survive --refresh
counts dev 156
expect "set"                    "staging" 0 "--set staging"
expect "override"               "staging" 0
expect "override, refresh"      "staging" 0 --refresh
expect "set none"               "" 0 "--set none"
expect "override none"          "" 3
reset_state

# --- the override key is owner/repo, lowercased, from any remote URL form
for url in git@github.com:Example-Org/Example-App.git https://github.com/example-org/example-app ssh://git@github.com/example-org/example-app.git; do
  git remote set-url origin "$url"
  bash "$RESOLVER" --set dev >/dev/null 2>&1
  key=$(jq -r '.repos | keys[]' "$AGENT_TOOLKIT_CONFIG_DIR/preprod-branches.local.json")
  if [ "$key" = "example-org/example-app" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: key for $url is $key"; fi
  reset_state
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
