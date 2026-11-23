#!/bin/bash
# Tests for which checkout each service runs from, and copying local files.
# Run: bash skills/dev-stack/tests/state.test.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../scripts/lib/state.sh
. "$LIB/state.sh"
mkdir -p "$DEVSTACK_STATE_DIR"

# --- owners: set and get ---
ds_owner_set bsa /a
check "owner recorded" [ "$(ds_owner_get bsa)" = /a ]
check "owners.json is a flat object" [ "$(jq -r .bsa "$DEVSTACK_STATE_DIR/owners.json")" = /a ]

# --- copies_missing_local_file / never_overwrites ---
mkdir -p "$TMP/ws/svc" "$TMP/wt" "$TMP/wt2"
echo MAIN=1 > "$TMP/ws/svc/.env"
cat > "$TMP/reg.json" <<JSON
{"_root": "$TMP/ws", "services": {"svc": {"repo": "svc", "local_files": [".env", "missing.txt"]}}, "targets": {}}
JSON
out=$(ds_copy_local_files "$TMP/reg.json" svc "$TMP/wt")
check "missing .env copied" grep -q MAIN=1 "$TMP/wt/.env"
check "copy reported" grep -q ".env" <<<"$out"
echo WT=1 > "$TMP/wt2/.env"
out=$(ds_copy_local_files "$TMP/reg.json" svc "$TMP/wt2")
check "existing .env left alone" grep -q WT=1 "$TMP/wt2/.env"
check "nothing reported when nothing copied" [ -z "$out" ]
check "copying into the main checkout itself is a no-op" ds_copy_local_files "$TMP/reg.json" svc "$TMP/ws/svc"

# --- a directory is linked, not copied (keeps credentials in one place) ---
mkdir -p "$TMP/ws/svc/config" "$TMP/wt3" && echo KEY=1 > "$TMP/ws/svc/config/key.pem"
cat > "$TMP/reg2.json" <<JSON
{"_root": "$TMP/ws", "services": {"svc": {"repo": "svc", "local_files": ["config"]}}, "targets": {}}
JSON
ds_copy_local_files "$TMP/reg2.json" svc "$TMP/wt3" >/dev/null
check "directory is a symlink" [ -L "$TMP/wt3/config" ]
check "symlink points at the main checkout" [ "$(readlink "$TMP/wt3/config")" = "$TMP/ws/svc/config" ]

finish
