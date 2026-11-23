#!/bin/bash
# Tests for the port table.
# Run: bash skills/dev-stack/tests/ports.test.sh
. "$(dirname "$0")/helpers.sh"
export DEVSTACK_STATE_DIR="$TMP/st"
mkdir -p "$TMP/ws"
cat > "$TMP/ws/stack.yaml" <<'YAML'
services:
  connect-api: {repo: afrotech-connect/afrotech-app-backend, node: nvmrc, doppler: none, command: x, port: 3200, health: tcp, label: Connect backend}
  bsa: {repo: blavity-service-api, node: nvmrc, doppler: none, command: x, port: 3010, health: tcp, notes: Core API}
targets: {}
YAML
ds() { (cd "$TMP/ws" && bash "$DEVSTACK" "$@"); }

out=$(ds ports)
check "ports sorted by port (got '$out')" [ "$(head -1 <<<"$out" | awk '{print $1}')" = 3010 ]
check "ports shows service and repo" grep -qE "^3200 +connect-api +afrotech-connect/afrotech-app-backend" <<<"$out"

md=$(ds ports --markdown)
check "markdown header" grep -qx '| Port | Service | Repo | Notes |' <<<"$md"
check "markdown uses label" grep -qF '| `3200` | Connect backend | `afrotech-connect/afrotech-app-backend` |  |' <<<"$md"
check "markdown falls back to the name, keeps notes" grep -qF '| `3010` | bsa | `blavity-service-api` | Core API |' <<<"$md"

printf 'intro\n<!-- devstack:ports:start -->\nold table\n<!-- devstack:ports:end -->\noutro\n' > "$TMP/P.md"
ds ports --write "$TMP/P.md"
check "write keeps text outside the markers" [ "$(head -1 "$TMP/P.md")" = intro ] && [ "$(tail -1 "$TMP/P.md")" = outro ]
check "write replaces the old table" bash -c '! grep -q "old table" "$1"' _ "$TMP/P.md"
check "write puts the new table in" grep -qF '| `3010` | bsa |' "$TMP/P.md"
check "markers stay" grep -q 'devstack:ports:end' "$TMP/P.md"

printf 'keep\n<!-- devstack:ports:end -->\nmiddle\n<!-- devstack:ports:start -->\ntail\n' > "$TMP/R.md"; cp "$TMP/R.md" "$TMP/R.orig"
ds ports --write "$TMP/R.md" 2>/dev/null; code=$?
check "markers in the wrong order exit 2 (got $code)" [ "$code" -eq 2 ]
check "markers in the wrong order leave the file untouched" cmp -s "$TMP/R.md" "$TMP/R.orig"

printf 'no markers\n' > "$TMP/N.md"
ds ports --write "$TMP/N.md" 2>/dev/null; code=$?
check "write without markers exits 2 (got $code)" [ "$code" -eq 2 ]

finish
