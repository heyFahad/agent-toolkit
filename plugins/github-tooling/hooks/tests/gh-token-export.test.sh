#!/bin/bash
# Tests for gh-token-export.sh. No dependencies beyond bash and jq: the
# scripts a command runs are fixtures in a temp dir that serves as the
# hook's cwd. Fixtures are written with printf so this file itself never
# calls gh at command position (it is checked below like any other script).
# Run: bash plugins/github-tooling/hooks/tests/gh-token-export.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK="$HERE/../gh-token-export.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

G=gh
fixture() { # path, line...
  local f="$TMP/$1"
  shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$@" >"$f"
  chmod +x "$f"
}

fixture calls-gh.sh '#!/bin/bash' 'set -e' "$G api user --jq .login"
fixture subst-gh.sh '#!/bin/bash' "login=\$($G api user --jq .login)" 'echo "$login"'
fixture if-gh.sh '#!/bin/bash' "if $G auth status >/dev/null 2>&1; then echo ok; fi"
fixture dq-subst-gh.sh '#!/bin/bash' "echo \"login: \$($G api user --jq .login)\""
fixture escaped.sh '#!/bin/bash' "echo \"prefix with GH_TOKEN=\\\$($G auth token) first\""
fixture stack.sh '#!/bin/bash' "$G-stack submit"
fixture mentions-gh.sh '#!/bin/bash' "# Needs $G installed; see '$G pr view' docs." "echo 'run: $G pr view 12'"
fixture tool.py 'import subprocess' "subprocess.run([\"$G\", \"api\", \"user\"], check=True)"
fixture clean.py 'print("hello")'
fixture sub/calls-gh.sh '#!/bin/bash' "$G pr list"
fixture sub/clean.sh '#!/bin/bash' 'echo clean'
fixture plugins/x/hooks/foo.sh '#!/bin/bash' 'cat >/dev/null' 'exit 0'
fixture plugins/x/hooks/tests/foo.test.sh '#!/bin/bash' 'echo "{}" | bash "$(dirname "$0")/../foo.sh"' 'echo "1 passed, 0 failed"'
fixture skills/jira-ticket-lifecycle/SKILL.md '# Jira ticket lifecycle'

pass=0 fail=0

run_hook() { jq -n --arg c "$1" --arg d "$TMP" '{tool_input:{command:$c}, cwd:$d}' | bash "$HOOK"; }

expect() { # name, allow|deny, command
  local out decision
  out=$(run_hook "$3" 2>&1)
  if [ -z "$out" ]; then decision=allow
  else decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "garbage"' 2>/dev/null || echo garbage); fi
  if [ "$decision" = "$2" ] && { [ "$2" = deny ] || [ -z "$out" ]; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (wanted $2, got $decision)"
    [ -n "$out" ] && echo "      $out" | head -c 400 && echo
  fi
}

# --- false positives seen in real sessions: nothing here runs a gh script
expect "find + grep .sh"       allow "find plugins/atlassian-workflow -type f | grep -rl jira --include=*.sh"
expect "cat a skill"           allow "cat skills/jira-ticket-lifecycle/SKILL.md"
expect "switch + ls + find"    allow "git switch -c feat/x && ls plugins/*/ && find plugins -path '*hooks*'"
expect "chmod, bash -n, test"  allow "chmod +x plugins/x/hooks/foo.sh && bash -n plugins/x/hooks/foo.sh && bash plugins/x/hooks/tests/foo.test.sh"

# --- other things that only mention or inspect a gh script
expect "cat a gh script"       allow "cat calls-gh.sh"
expect "grep a gh script"      allow "grep -n api calls-gh.sh"
expect "sed a gh script"       allow "sed -n 1,5p calls-gh.sh"
expect "bash -n a gh script"   allow "bash -n calls-gh.sh"
expect "git add a gh script"   allow "git add calls-gh.sh sub/calls-gh.sh"
expect "commit message"        allow 'git commit -m "fix: make ./calls-gh.sh quieter"'
expect "gh only in comments"   allow "bash mentions-gh.sh"
expect "clean python"          allow "python3 clean.py"
expect "inline bash -c"        allow "bash -c 'echo hi'"

# --- direct gh calls and inline GH_TOKEN
expect "direct gh pr view"     allow "gh pr view 12 --repo o/r --json title"
expect "env-prefixed gh"       allow "GH_REPO=o/r gh pr view 12"
expect "gh after cd"           allow "cd sub && gh pr list"
expect "inline GH_TOKEN"       allow "GH_TOKEN=x bash calls-gh.sh"
expect "GH_TOKEN for gh-stack" allow "GH_TOKEN=x gh-stack submit"

# --- running a script that calls gh
expect "bash script calls gh"  deny  "bash calls-gh.sh"
expect "./script calls gh"     deny  "./calls-gh.sh"
expect "sh, quoted path"       deny  "sh \"calls-gh.sh\""
expect "gh inside \$(...)"     deny  "bash subst-gh.sh"
expect "\$(gh) in a string"    deny  "bash dq-subst-gh.sh"
expect "escaped \\\$(gh) text"   allow "bash escaped.sh"
expect "gh after if"         deny  "./if-gh.sh"
expect "script runs gh-stack"  deny  "bash stack.sh"
expect "python subprocess gh"  deny  "python3 tool.py"
expect "after direct gh"       deny  "gh pr view 12 && bash calls-gh.sh"
expect "after cd"              deny  "cd sub && ./calls-gh.sh"
expect "abs path"              deny  "$TMP/calls-gh.sh --flag"
expect "bash -c ./script"      deny  "bash -c './calls-gh.sh'"
expect "piped into"            deny  "echo x | bash calls-gh.sh"
expect "cd'd clean script"     allow "cd sub && ./clean.sh"

# --- separators inside quotes, comments and quoted heredocs separate nothing
expect "sed with ; in quotes"  allow "sed -i '' -e 's/a/b/; s/c/d/' sub/clean.sh"
expect "grep with \\| pattern" allow "grep -n -E 'a|b/c' README.md"
expect "dq with ; and /"       allow 'echo "x; ./calls-gh.sh" > /dev/null'
expect "jq pipes in quotes"    allow "jq -r '.[] | .a/.b' f.json"
expect "awk with ; in quotes"  allow "awk '{ a = 1; print \$1 }' sub/clean.sh"
expect "comment with ;"        allow "ls # then; ./calls-gh.sh"
expect "quoted heredoc body"   allow "cat > /dev/null <<'EOF'
Wrap it in \`/loop\` for repeated passes; see ./calls-gh.sh (old).
EOF"
expect "quoted heredoc, -EOF"  allow "cat <<-\"EOF\"
	run \`./calls-gh.sh\` | tee x
	EOF"
expect "after a quoted heredoc" deny "cat <<'EOF'
text; more
EOF
bash calls-gh.sh"
expect "unquoted heredoc runs"  deny "cat <<EOF
\$(./calls-gh.sh)
EOF"
expect "after a quoted ;"      deny  "echo 'a;b'; bash calls-gh.sh"
expect "\$(script) in a string" deny 'echo "login: $(./calls-gh.sh)"'
expect "bash -c '...; script'" deny  "bash -c 'echo hi; ./calls-gh.sh'"
expect "sh -lc \"...; script\"" deny "sh -lc \"cd sub && ./calls-gh.sh\""
expect "eval '...; script'"    deny  "eval 'true; ./calls-gh.sh'"
expect "quote spans lines"     deny  "echo 'a;
b'; bash calls-gh.sh"

# --- known wrappers and unreadable scripts
expect "gh-stack submit"       deny  "gh-stack submit"
expect "missing script"        deny  "bash nope.sh"
expect "variable path"         deny  'bash "$SCRIPT_DIR/run.sh"'

# --- this repo's own test files mention gh but never call it at command position
expect "this test file"        allow "bash $HERE/gh-token-export.test.sh"
expect "review-guard tests"    allow "bash $HERE/../../../pr-conventions/hooks/tests/review-guard.test.sh"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
