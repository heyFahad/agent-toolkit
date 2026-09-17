#!/bin/bash
# PostToolUse hook: after every Edit/Write to a JS/TS file, run eslint --fix
# using this plugin's shareable config so style rules are actually enforced
# on the file rather than relying on the model remembering prose. Silently
# auto-fixes what's fixable; prints anything left over so it's visible in
# the same turn. Requires ESLint to be resolvable from the edited file's
# location (the target repo's own install) - if it isn't, this no-ops
# rather than blocking or failing the edit.
set -uo pipefail

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

case "$FILE_PATH" in
  *.js|*.jsx|*.ts|*.tsx) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/../eslint.config.js"
FILE_DIR="$(dirname "$FILE_PATH")"

if ! ( cd "$FILE_DIR" && npx --no-install eslint --version ) >/dev/null 2>&1; then
  # No ESLint resolvable from this file's location - nothing to enforce with.
  exit 0
fi

OUTPUT=$(cd "$FILE_DIR" && ESLINT_USE_FLAT_CONFIG=true npx --no-install eslint --fix -c "$CONFIG_PATH" "$FILE_PATH" 2>&1)
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
  printf 'coding-style eslint-autofix-gate: %s has remaining lint issues after auto-fix:\n\n%s\n' "$FILE_PATH" "$OUTPUT"
fi

exit 0
