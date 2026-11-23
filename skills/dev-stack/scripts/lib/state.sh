#!/bin/bash
# Which checkout each service runs from (owners.json), and local files that
# a fresh worktree lacks.
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

_ds_owners() { echo "$(ds_state_dir)/owners.json"; }

# ds_owner_get <svc>: the directory <svc> runs from, or nothing.
ds_owner_get() { jq -r --arg s "$1" '.[$s] // empty' "$(_ds_owners)" 2>/dev/null; }

# ds_owner_set <svc> <dir>: record it (atomic write).
ds_owner_set() {
  local f tmp
  f=$(_ds_owners); mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || echo '{}' > "$f"
  tmp=$(mktemp "$f.XXXXXX")
  jq --arg s "$1" --arg d "$2" '. + {($s): $d}' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ds_copy_local_files <registry_json_file> <svc> <dir>: bring each listed local
# file missing from <dir> over from the main checkout: files are copied,
# directories symlinked. Never overwrites.
ds_copy_local_files() {
  local file=$1 svc=$2 dir=$3 main f
  main=$(jq -r --arg s "$svc" '._root + "/" + .services[$s].repo' "$file")
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$main" && pwd -P)" ] && return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$dir/$f" ] && continue
    [ -e "$main/$f" ] || continue
    mkdir -p "$(dirname "$dir/$f")"
    if [ -d "$main/$f" ]; then
      # A directory (say, a gitignored config/ with keys) is linked, so
      # credentials aren't duplicated into every worktree.
      ln -s "$main/$f" "$dir/$f" && echo "linked $f to $main/$f"
    else
      cp -p "$main/$f" "$dir/$f" && echo "copied $f from $main"
    fi
  done < <(jq -r --arg s "$svc" '.services[$s].local_files // [] | .[]' "$file")
}
