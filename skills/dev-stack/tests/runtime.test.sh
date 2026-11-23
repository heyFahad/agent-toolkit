#!/bin/bash
# Tests for up, status, logs, restart, down and urls, against stubbed
# process-compose, docker and lsof (no real servers start).
# Run: bash skills/dev-stack/tests/runtime.test.sh
. "$(dirname "$0")/helpers.sh"
export DEVSTACK_STATE_DIR="$TMP/st"   # keep the socket path short
PCS="$TMP/pc"; mkdir -p "$PCS/procs"; export PCS

# --- stub process-compose: a tiny state machine in $PCS ---
stub_bin process-compose '
args=" $* "
proc() { printf "%s" "$1" | tr -c "a-zA-Z0-9_-" _; }
set_proc() { # name status ready running
  printf "{\"name\":\"%s\",\"status\":\"%s\",\"is_ready\":\"%s\",\"is_running\":%s,\"pid\":%s}" \
    "$1" "$2" "$3" "$4" "$( [ "$4" = true ] && echo 100 || echo 0)" > "$PCS/procs/$(proc "$1").json"
}
case "$args" in
  *" up "*) touch "$PCS/alive"; yq -o=json . "$(sed -E "s/.* -f ([^ ]+).*/\1/" <<<"$args")" > "$PCS/cfg.json" ;;
  *" project state "*) [ -f "$PCS/alive" ] ;;
  *" project update "*)
    [ -f "$PCS/alive" ] || exit 1
    cfg=$(sed -E "s/.* -f ([^ ]+).*/\1/" <<<"$args")
    for f in "$PCS"/procs/*.json; do
      [ -f "$f" ] || continue
      n=$(jq -r .name "$f")
      if [ -f "$PCS/cfg.json" ] && [ "$(yq -o=json ".processes.\"$n\"" "$cfg")" != "$(jq ".processes.\"$n\"" "$PCS/cfg.json")" ]; then
        set_proc "$n" Disabled - false
      fi
    done
    yq -o=json . "$cfg" > "$PCS/cfg.json" ;;
  *" process list "*)
    [ -f "$PCS/alive" ] || exit 1
    cat "$PCS"/procs/*.json 2>/dev/null | jq -s . ;;
  *" process start "*|*" process restart "*)
    n=$(sed -E "s/.* process (start|restart) ([^ ]+).*/\2/" <<<"$args")
    [ -n "${STUB_START_LOG:-}" ] && printf "%b" "$STUB_START_LOG" >> "$DEVSTACK_STATE_DIR/logs/$n.log"
    if [[ " ${STUB_NEVER_READY:-} " == *" $n "* ]]; then set_proc "$n" Running "Not Ready" true
    else set_proc "$n" Running Ready true; fi ;;
  *" process stop "*)
    n=$(sed -E "s/.* process stop ([^ ]+).*/\1/" <<<"$args"); set_proc "$n" Disabled - false ;;
  *" down "*) rm -f "$PCS/alive" "$PCS"/procs/*.json ;;
  *" attach "*) echo attached ;;
  *) exit 1 ;;
esac'
# --- stub docker: STUB_DOCKER_DOWN=1, STUB_CONTAINERS="redis:true mongodb:false" ---
stub_bin docker '
case "$1" in
  info) [ -z "${STUB_DOCKER_DOWN:-}" ] ;;
  inspect) n=${!#}; for c in ${STUB_CONTAINERS:-}; do [ "${c%%:*}" = "$n" ] && { echo "${c#*:}"; exit 0; }; done; exit 1 ;;
  start) STUB_CONTAINERS=$(echo "${STUB_CONTAINERS:-}" | sed "s/$2:false/$2:true/"); echo "$2" ;;
  *) exit 1 ;;
esac'
# --- stub lsof: STUB_LSOF="3010:node:4242" ---
stub_bin lsof '
for e in ${STUB_LSOF:-}; do
  port=${e%%:*}; rest=${e#*:}
  [[ " $* " == *"-iTCP:$port "* ]] && { printf "p%s\nc%s\n" "${rest#*:}" "${rest%%:*}"; exit 0; }
done; exit 1'

# --- fixture workspace ---
export NVM_DIR="$TMP/nvm"; mkdir -p "$NVM_DIR/versions/node/v22.16.0/bin"
for r in bsa ti connect metro; do mkdir -p "$TMP/ws/$r"; echo 22.16.0 > "$TMP/ws/$r/.nvmrc"; done
echo SECRET=main > "$TMP/ws/connect/.env"
cat > "$TMP/ws/stack.yaml" <<'YAML'
services:
  bsa: {repo: bsa, node: nvmrc, doppler: none, command: "true", port: 3010, health: "http://localhost:3010/health", infra: [redis]}
  ti-api: {repo: ti, node: nvmrc, doppler: none, command: "true", port: 3100, health: tcp, infra: [mongodb]}
  connect-api: {repo: connect, node: nvmrc, doppler: none, command: "true", port: 3200, health: tcp, depends_on: [bsa, ti-api], timeout: 2, local_files: [.env]}
  connect-metro: {repo: metro, node: nvmrc, doppler: none, command: "true", port: 8200, health: tcp}
  wl-atc: {repo: metro, node: nvmrc, doppler: none, command: "true", port: 5200, health: tcp}
targets:
  connect: [connect-metro, connect-api]
YAML
export STUB_CONTAINERS="redis:true mongodb:true"
ds() { (cd "$TMP/ws" && bash "$DEVSTACK" "$@"); }
starts() { grep -c "process start" "$TMP/calls.log"; }
line_of() { grep -n "process start $1" "$TMP/calls.log" | head -1 | cut -d: -f1; }

# --- up_starts_in_order ---
out=$(ds up connect 2>&1); code=$?
check "up exits 0 (got $code: $out)" [ "$code" -eq 0 ]
check "bsa starts before connect-api" [ "$(line_of bsa)" -lt "$(line_of connect-api)" ]
check "ti-api starts before connect-api" [ "$(line_of ti-api)" -lt "$(line_of connect-api)" ]
check "one line per service (got $(wc -l <<<"$out"))" [ "$(wc -l <<<"$out" | tr -d ' ')" = 4 ]
check "line shows port, state and URL" grep -qE "^bsa +3010 +Ready +http://localhost:3010" <<<"$out"

# --- up_idempotent (Review Focus) ---
n=$(starts)
ds up connect >/dev/null 2>&1
check "second up starts nothing new" [ "$(starts)" = "$n" ]

# --- status / status_json_parses ---
out=$(ds status)
check "status lists bsa" grep -qE "^bsa +3010 +Ready" <<<"$out"
check "status fits in a few lines" [ "$(wc -l <<<"$out" | tr -d ' ')" -le 10 ]
check "status --json parses" bash -c 'jq -e "map(select(.name == \"bsa\"))[0] | .port == 3010 and .dir != null" >/dev/null' <<<"$(ds status --json)"

# --- from_refused_without_takeover / takeover / local files ---
mkdir -p "$TMP/wt" && echo 22.16.0 > "$TMP/wt/.nvmrc"
n=$(starts)
out=$(ds up connect-api --from "connect-api=$TMP/wt" 2>&1); code=$?
check "--from on a running service exits 2 (got $code)" [ "$code" -eq 2 ]
check "refusal mentions --takeover" grep -q -- "--takeover" <<<"$out"
check "refusal restarts nothing" [ "$(starts)" = "$n" ]
out=$(ds up connect-api --from "connect-api=$TMP/wt" --takeover 2>&1); code=$?
check "--takeover exits 0 (got $code: $out)" [ "$code" -eq 0 ]
check "takeover copied the missing .env" grep -q SECRET=main "$TMP/wt/.env"
check "status shows the worktree dir" grep -q "$TMP/wt" <<<"$(ds status)"
check "config now runs connect-api from the worktree" [ "$(yq -r '.processes."connect-api".working_dir' "$DEVSTACK_STATE_DIR/process-compose.yaml")" = "$TMP/wt" ]

# --- logs_tail_default ---
seq 1 100 > "$DEVSTACK_STATE_DIR/logs/bsa.log"
check "logs default to 30 lines" [ "$(ds logs bsa | wc -l | tr -d ' ')" = 30 ]
printf 'ok\nERROR boom\nfine\n' > "$DEVSTACK_STATE_DIR/logs/bsa.log"
check "logs --errors filters" [ "$(ds logs bsa --errors)" = "ERROR boom" ]

# --- urls ---
out=$(ds urls)
check "urls lists the API" grep -q "http://localhost:3010" <<<"$out"
check "urls lists Metro" grep -q "Metro on 8200" <<<"$out"

# --- down_never_touches_docker ---
: > "$TMP/calls.log"
ds down >/dev/null 2>&1
check "down calls process-compose down" grep -q "process-compose down" "$TMP/calls.log"
check "down never touches docker" bash -c '! grep -q "^docker" "$1"' _ "$TMP/calls.log"
check "down clears owners" [ "$(jq -r 'length' "$DEVSTACK_STATE_DIR/owners.json" 2>/dev/null || echo 0)" = 0 ]

# --- stale_socket_restarts_server (Review Focus) ---
: > "$TMP/calls.log"; mkdir -p "$DEVSTACK_STATE_DIR"; touch "$DEVSTACK_STATE_DIR/pc.sock"
out=$(ds up bsa 2>&1); code=$?
check "stale socket: up still succeeds (got $code: $out)" [ "$code" -eq 0 ]
check "stale socket: a fresh server is started" grep -q "process-compose up -D" "$TMP/calls.log"
ds down >/dev/null 2>&1

# --- port_taken_fails_fast (Review Focus) ---
start=$(date +%s)
out=$(STUB_LSOF="3010:node:4242" ds up bsa 2>&1); code=$?
check "taken port exits 1 (got $code)" [ "$code" -eq 1 ]
check "taken port names the holder (got '$out')" grep -q "port 3010 for bsa is held by node (pid 4242)" <<<"$out"
check "taken port fails fast" [ $(( $(date +%s) - start )) -le 2 ]

# --- docker_down_fails (Review Focus) ---
: > "$TMP/calls.log"
out=$(STUB_DOCKER_DOWN=1 ds up bsa 2>&1); code=$?
check "Docker down exits 1 (got $code)" [ "$code" -eq 1 ]
check "Docker down says so" grep -q "Docker isn't running" <<<"$out"
check "never docker run or create" bash -c '! grep -qE "^docker (run|create)" "$1"' _ "$TMP/calls.log"
out=$(STUB_CONTAINERS="mongodb:true" ds up bsa 2>&1); code=$?
check "missing container exits 1 (got $code)" [ "$code" -eq 1 ]
check "missing container says devstack never creates" grep -q "container redis doesn't exist" <<<"$out"

# --- stopped_container_started_once ---
: > "$TMP/calls.log"
STUB_CONTAINERS="redis:false mongodb:true" ds up bsa >/dev/null 2>&1
check "stopped redis started exactly once" [ "$(grep -c '^docker start redis' "$TMP/calls.log")" = 1 ]
ds down >/dev/null 2>&1

# --- unhealthy_prints_errors ---
mkdir -p "$DEVSTACK_STATE_DIR/logs"
out=$(STUB_NEVER_READY=connect-api STUB_START_LOG="$(seq 1 40 | sed 's/^/ERROR line /' | tr '\n' '|' | sed 's/|/\\n/g')" ds up connect-api 2>&1); code=$?
check "unhealthy exits 1 (got $code)" [ "$code" -eq 1 ]
check "unhealthy shows at most 20 log lines" [ "$(grep -c 'ERROR line' <<<"$out")" -le 20 ]
check "unhealthy shows some log lines" grep -q "ERROR line 40" <<<"$out"

# --- crash_line_fails_fast: nodemon keeps a crashed app "running" ---
ds down >/dev/null 2>&1
start=$(date +%s)
out=$(STUB_NEVER_READY=ti-api STUB_START_LOG='starting\nInvalid environment variables: ITERABLE_API_KEY\n[nodemon] app crashed - waiting for file changes before starting...\n' ds up ti-api 2>&1); code=$?
check "crashed app exits 1 (got $code)" [ "$code" -eq 1 ]
check "crashed app fails fast" [ $(( $(date +%s) - start )) -le 5 ]
check "crashed app shows the cause" grep -q "ITERABLE_API_KEY" <<<"$out"
ds down >/dev/null 2>&1

# --- an old crash in the log doesn't fail a fresh start ---
printf '[nodemon] app crashed - waiting for file changes\n' > "$DEVSTACK_STATE_DIR/logs/connect-api.log"
out=$(STUB_NEVER_READY=connect-api ds up connect-api 2>&1)
check "old crash line isn't read as a new crash (got: $out)" bash -c '! grep -q Crashed <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

# --- update_restarts_changed: a config change that stops a running service ---
ds up connect >/dev/null 2>&1
sed -i '' 's/  bsa: {repo: bsa, node: nvmrc, doppler: none, command: "true"/  bsa: {timeout: 60, repo: bsa, node: nvmrc, doppler: none, command: "true"/' "$TMP/ws/stack.yaml"
: > "$TMP/calls.log"
out=$(ds up connect 2>&1); code=$?
check "changed service comes back (got $code: $out)" [ "$code" -eq 0 ]
check "changed service is started again" grep -q "process start bsa" "$TMP/calls.log"
check "unchanged services aren't restarted" bash -c '! grep -q "process start ti-api" "$1"' _ "$TMP/calls.log"

# --- logs are readable: no colour codes ---
printf '\033[31mERROR red\033[0m\n' > "$DEVSTACK_STATE_DIR/logs/bsa.log"
check "logs strip colour codes" [ "$(ds logs bsa)" = "ERROR red" ]

# --- down_without_registry ---
mkdir -p "$TMP/elsewhere"; : > "$TMP/calls.log"
out=$(cd "$TMP/elsewhere" && bash "$DEVSTACK" down 2>&1); code=$?
check "down works without a stack.yaml (got $code: $out)" [ "$code" -eq 0 ]
check "down without a registry still stops the server" grep -q "process-compose down" "$TMP/calls.log"

# --- socket path too long ---
out=$(DEVSTACK_STATE_DIR="$TMP/$(printf 'x%.0s' {1..110})" ds status 2>&1); code=$?
check "too-long socket path exits 2 (got $code)" [ "$code" -eq 2 ]

finish
