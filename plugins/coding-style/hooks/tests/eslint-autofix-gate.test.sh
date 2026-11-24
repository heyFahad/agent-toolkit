#!/bin/bash
set -euo pipefail

hook="$(cd "$(dirname "$0")/.." && pwd)/eslint-autofix-gate.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

mkdir bin src
touch 'src/added file.ts' src/modified.jsx src/deleted.js src/ignored.md
export LINT_LOG="$scratch/linted"
export PATH="$scratch/bin:$PATH"
cat > bin/npx <<'MOCK'
#!/bin/bash
[ "$3" != --version ] || exit 0
printf '%s\n' "${@: -1}" >> "$LINT_LOG"
echo 'Example lint issue'
exit 1
MOCK
chmod +x bin/npx

response=$'Exit code: 0\nOutput:\nSuccess. Updated the following files:\nA src/added file.ts\nM src/modified.jsx\nD src/deleted.js\nM src/ignored.md\n'
output=$(jq -n --arg response "$response" '{tool_name: "apply_patch", tool_response: $response}' | bash "$hook")
jq -e '.hookSpecificOutput.additionalContext | contains("Example lint issue")' <<<"$output" >/dev/null
expected=$(printf '%s\n' "$PWD/src/added file.ts" "$PWD/src/modified.jsx")
[ "$(cat "$LINT_LOG")" = "$expected" ]

: > "$LINT_LOG"
output=$(jq -n '{tool_name: "apply_patch", tool_response: "Exit code: 1\nM src/modified.jsx"}' | bash "$hook")
[ -z "$output" ] && [ ! -s "$LINT_LOG" ]

output=$(jq -n --arg path "$PWD/src/modified.jsx" '{tool_name: "Edit", tool_input: {file_path: $path}}' | bash "$hook")
[[ "$output" = *"Example lint issue"* ]]
[ "$(cat "$LINT_LOG")" = "$PWD/src/modified.jsx" ]

echo 'ESLint hook passed for Claude Code edits and Codex patches'

# ESLint runs from the edited project even when its config is in a plugin cache.
mkdir -p node_modules/eslint-plugin-import
printf 'module.exports = { rules: {} };\n' > node_modules/eslint-plugin-import/index.js
config="$(cd "$(dirname "$hook")/.." && pwd)/eslint.config.js"
node - "$config" <<'JS'
const assert = require('node:assert/strict');
const config = require(process.argv[2]);
assert(config.some(entry => entry.rules?.['import/order']), 'project-local import plugin was not loaded');
JS
echo 'ESLint config resolved dependencies from the edited project'
