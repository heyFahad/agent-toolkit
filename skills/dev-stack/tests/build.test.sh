#!/bin/bash
# Tests for Node version lookup, service commands and the process-compose config.
# Run: bash skills/dev-stack/tests/build.test.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../scripts/lib/build.sh
. "$LIB/build.sh"

export NVM_DIR="$TMP/nvm"
mkdir -p "$NVM_DIR/versions/node/v22.16.0/bin" "$NVM_DIR/versions/node/v16.20.2/bin"
mkdir -p "$TMP/ws/bsa" "$TMP/ws/ti" "$TMP/ws/env"
echo 22.16.0 > "$TMP/ws/bsa/.nvmrc"
echo v16.20.2 > "$TMP/ws/ti/.nvmrc"
echo 22.16.0 > "$TMP/ws/env/.nvmrc"

cat > "$TMP/reg.json" <<JSON
{"_root": "$TMP/ws",
 "services": {
  "bsa": {"repo": "bsa", "node": "nvmrc", "doppler": {"project": "blavity-service-api", "config": "dev"},
          "command": "pnpm start:dev", "port": 3010, "health": "http://localhost:3010/health"},
  "ti-api": {"repo": "ti", "node": "16.20.2", "doppler": "none", "command": "npm run start:dev",
             "port": 3100, "health": "tcp", "timeout": 60},
  "connect-api": {"repo": "bsa", "node": "nvmrc", "doppler": "none", "command": "true",
                  "port": 3200, "health": "tcp", "depends_on": ["bsa", "ti-api"]},
  "envy": {"repo": "env", "node": "nvmrc", "doppler": "none", "command": "printenv X",
           "port": 3300, "health": "tcp", "env": {"X": "a b \$c 'q'"}}
 }, "targets": {}}
JSON

# --- nvmrc_resolves / pinned_version_resolves ---
got=$(ds_node_bin "$TMP/ws/bsa" nvmrc)
check "nvmrc resolves (got '$got')" [ "$got" = "$NVM_DIR/versions/node/v22.16.0/bin" ]
got=$(ds_node_bin "$TMP/ws/ti" nvmrc)
check "nvmrc with a leading v resolves" [ "$got" = "$NVM_DIR/versions/node/v16.20.2/bin" ]
got=$(ds_node_bin "$TMP/ws/bsa" 16.20.2)
check "pinned version resolves" [ "$got" = "$NVM_DIR/versions/node/v16.20.2/bin" ]

# --- missing_version_exit_3 (Review Focus) ---
mkdir -p "$TMP/ws/new" && echo 24.99.0 > "$TMP/ws/new/.nvmrc"
out=$(ds_node_bin "$TMP/ws/new" nvmrc 2>&1); code=$?
check "missing Node exits 3 (got $code)" [ "$code" -eq 3 ]
check "missing Node says nvm install" grep -q "nvm install 24.99.0" <<<"$out"
out=$(ds_node_bin "$TMP/ws/none" nvmrc 2>&1); code=$?
check "missing .nvmrc exits 2 (got $code)" [ "$code" -eq 2 ]

# --- doppler_wrapped / doppler_none_not_wrapped ---
cmd=$(ds_command "$TMP/reg.json" bsa "$TMP/ws/bsa")
check "doppler run wraps it" grep -q -- "doppler run --project blavity-service-api --config dev --" <<<"$cmd"
check "DOPPLER_PROJECT exported" grep -q "DOPPLER_PROJECT=blavity-service-api" <<<"$cmd"
check "Node bin first on PATH" grep -q "$NVM_DIR/versions/node/v22.16.0/bin" <<<"$cmd"
cmd=$(ds_command "$TMP/reg.json" ti-api "$TMP/ws/ti")
check "doppler none isn't wrapped" bash -c '! grep -q doppler <<<"$1"' _ "$cmd"

# --- env_applied: quoting survives a shell ---
cmd=$(ds_command "$TMP/reg.json" envy "$TMP/ws/env")
got=$(bash -c "$cmd")
check "env value survives quoting (got '$got')" [ "$got" = "a b \$c 'q'" ]

# --- pc_config_shape ---
mkdir -p "$TMP/state"
ds_pc_config "$TMP/reg.json" "$TMP/state"
cfg=$(yq -o=json '.' "$TMP/state/process-compose.yaml")
check "processes are disabled" [ "$(jq -r '.processes.bsa.disabled' <<<"$cfg")" = true ]
check "depends_on waits for healthy" [ "$(jq -r '.processes."connect-api".depends_on.bsa.condition' <<<"$cfg")" = process_healthy ]
check "http probe path" [ "$(jq -r '.processes.bsa.readiness_probe.http_get.path' <<<"$cfg")" = /health ]
check "http probe port" [ "$(jq -r '.processes.bsa.readiness_probe.http_get.port' <<<"$cfg")" = 3010 ]
check "tcp probe uses nc" grep -q "nc -z localhost 3100" <<<"$(jq -r '.processes."ti-api".readiness_probe.exec.command' <<<"$cfg")"
check "working_dir defaults to the repo" [ "$(jq -r '.processes.bsa.working_dir' <<<"$cfg")" = "$TMP/ws/bsa" ]
check "log per service" [ "$(jq -r '.processes.bsa.log_location' <<<"$cfg")" = "$TMP/state/logs/bsa.log" ]
check "timeout sets failure_threshold" [ "$(jq -r '.processes."ti-api".readiness_probe.failure_threshold' <<<"$cfg")" = 30 ]

# --- an owner overrides working_dir ---
echo "{\"bsa\": \"$TMP/wt\"}" > "$TMP/state/owners.json"
mkdir -p "$TMP/wt" && echo 22.16.0 > "$TMP/wt/.nvmrc"
ds_pc_config "$TMP/reg.json" "$TMP/state"
check "owner dir wins" [ "$(yq -r '.processes.bsa.working_dir' "$TMP/state/process-compose.yaml")" = "$TMP/wt" ]

finish
