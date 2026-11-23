#!/bin/bash
# Tests for prerequisite checks and registry lookup/validation.
# Run: bash skills/dev-stack/tests/registry.test.sh
. "$(dirname "$0")/helpers.sh"

valid_service='    repo: svc
    node: nvmrc
    doppler: none
    command: npm start
    port: 3010
    health: tcp'

# --- missing_tools_exit_3: no yq on PATH ---
mkdir -p "$TMP/noyq"
for t in jq process-compose; do
  p=$(command -v "$t") && ln -s "$p" "$TMP/noyq/$t"
done
out=$(PATH="$TMP/noyq:/usr/bin:/bin" bash "$DEVSTACK" status 2>&1); code=$?
check "missing yq exits 3 (got $code)" [ "$code" -eq 3 ]
check "missing yq prints the install line" grep -q "brew install yq" <<<"$out"

# --- finds_registry_walking_up ---
mkdir -p "$TMP/ws/a/b"
printf 'services:\n  s:\n%s\ntargets: {}\n' "$valid_service" > "$TMP/ws/stack.yaml"
got=$(cd "$TMP/ws/a/b" && . "$LIB/registry.sh" && ds_find_registry)
check "finds stack.yaml walking up (got '$got')" [ "$got" = "$TMP/ws/stack.yaml" ]

# --- env_override_wins ---
cp "$TMP/ws/stack.yaml" "$TMP/other.yaml"
got=$(cd "$TMP/ws/a/b" && . "$LIB/registry.sh" && DEVSTACK_REGISTRY="$TMP/other.yaml" ds_find_registry)
check "DEVSTACK_REGISTRY wins (got '$got')" [ "$got" = "$TMP/other.yaml" ]

# --- no_registry_exit_2 ---
mkdir -p "$TMP/empty"
out=$(cd "$TMP/empty" && . "$LIB/registry.sh" && ds_find_registry 2>&1); code=$?
check "no registry exits 2 (got $code)" [ "$code" -eq 2 ]
check "no registry says so" grep -q "no stack.yaml found" <<<"$out"

# --- invalid_port_exit_2 ---
printf 'services:\n  bad-port:\n%s\ntargets: {}\n' "${valid_service/port: 3010/port: abc}" > "$TMP/badport.yaml"
out=$(. "$LIB/registry.sh" && ds_registry_json "$TMP/badport.yaml" 2>&1); code=$?
check "bad port exits 2 (got $code)" [ "$code" -eq 2 ]
check "bad port names service and field" grep -q "bad-port: port" <<<"$out"

# --- unknown_field_value_exit_2 ---
printf 'services:\n  bad-health:\n%s\ntargets: {}\n' "${valid_service/health: tcp/health: ftp://x}" > "$TMP/badhealth.yaml"
out=$(. "$LIB/registry.sh" && ds_registry_json "$TMP/badhealth.yaml" 2>&1); code=$?
check "bad health exits 2 (got $code)" [ "$code" -eq 2 ]
check "bad health names the field" grep -q "bad-health: health" <<<"$out"

# --- F6: service keys are plain names ---
printf 'services:\n  "../x":\n%s\ntargets: {}\n' "$valid_service" > "$TMP/badname.yaml"
out=$(. "$LIB/registry.sh" && ds_registry_json "$TMP/badname.yaml" 2>&1); code=$?
check "path-like service key exits 2 (got $code)" [ "$code" -eq 2 ]

# --- conflicts_with must be a list ---
printf 'services:\n  s:\n%s\n    conflicts_with: other\ntargets: {}\n' "$valid_service" > "$TMP/badconf.yaml"
out=$(. "$LIB/registry.sh" && ds_registry_json "$TMP/badconf.yaml" 2>&1); code=$?
check "conflicts_with must be a list (got $code)" [ "$code" -eq 2 ]

# --- a valid registry loads as JSON ---
got=$(. "$LIB/registry.sh" && ds_registry_json "$TMP/ws/stack.yaml" | jq -r '.services.s.port')
check "valid registry loads (got '$got')" [ "$got" = 3010 ]

finish
