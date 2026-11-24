#!/bin/bash
# Run ESLint against JS/TS files edited by Claude Code or Codex. Use the
# target project's ESLint and skip the hook if it isn't installed there.
set -uo pipefail

INPUT=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/../eslint.config.js"

lint_file() {
  local file_path=$1 file_dir output
  case "$file_path" in
    *.js|*.jsx|*.ts|*.tsx) ;;
    *) return ;;
  esac
  [[ "$file_path" = /* ]] || file_path="$PWD/$file_path"
  [ -f "$file_path" ] || return
  file_dir="$(dirname "$file_path")"

  if ! ( cd "$file_dir" && npx --no-install eslint --version ) >/dev/null 2>&1; then
    return
  fi

  if ! output=$(cd "$file_dir" && ESLINT_USE_FLAT_CONFIG=true npx --no-install eslint --fix -c "$CONFIG_PATH" "$file_path" 2>&1); then
    printf 'coding-style eslint-autofix-gate: %s has remaining lint issues after auto-fix:\n\n%s\n' "$file_path" "$output"
  fi
}

if [ "$(jq -r '.tool_name' <<<"$INPUT")" = apply_patch ]; then
  # Codex reports the files the patch actually changed, including move targets.
  issues=$(
    while IFS= read -r path; do
      lint_file "$path"
    done < <(jq -r '.tool_response | strings | split("\n") |
      index("Success. Updated the following files:") as $start |
      select($start != null) | .[$start + 1:][] |
      select(startswith("A ") or startswith("M ")) | .[2:]' <<<"$INPUT")
  )
  if [ -n "$issues" ]; then
    jq -n --arg issues "$issues" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $issues}}'
  fi
else
  lint_file "$(jq -r '.tool_input.file_path // ""' <<<"$INPUT")"
fi

exit 0
