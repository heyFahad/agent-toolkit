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
[ -n "${STUB_SANDBOX:-}" ] && { echo "dial unix $PCS/x.sock: connect: operation not permitted" >&2; exit 1; }
case "$args" in
  *" up "*) touch "$PCS/alive"; yq -o=json . "$(sed -E "s/.* -f ([^ ]+).*/\1/" <<<"$args")" > "$PCS/cfg.json" ;;
  *" project state "*) [ -f "$PCS/alive" ] ;;
  *" project update "*)
    [ -f "$PCS/alive" ] || exit 1
    [ -n "${STUB_UPDATE_FAILS:-}" ] && exit 1
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
    n=$(sed -E "s/.* process stop ([^ ]+).*/\1/" <<<"$args"); set_proc "$n" Completed - false ;;
  *" down "*) [ -n "${STUB_DOWN_FAILS:-}" ] && exit 1; rm -f "$PCS/alive" "$PCS"/procs/*.json ;;
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
check "status calls a crashed app Crashed, not Running" grep -qE "^ti-api +3100 +Crashed" <<<"$(ds status)"
ds down >/dev/null 2>&1

# --- an old crash in the log doesn't fail a fresh start ---
printf '[nodemon] app crashed - waiting for file changes\n' > "$DEVSTACK_STATE_DIR/logs/connect-api.log"
out=$(STUB_NEVER_READY=connect-api ds up connect-api 2>&1)
check "old crash line isn't read as a new crash (got: $out)" bash -c '! grep -q Crashed <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

# --- update_restarts_changed: a config change that stops a running service ---
ds up connect >/dev/null 2>&1
sedi 's/  bsa: {repo: bsa, node: nvmrc, doppler: none, command: "true"/  bsa: {timeout: 60, repo: bsa, node: nvmrc, doppler: none, command: "true"/' "$TMP/ws/stack.yaml"
: > "$TMP/calls.log"
out=$(ds up connect 2>&1); code=$?
check "changed service comes back (got $code: $out)" [ "$code" -eq 0 ]
check "changed service is started again" grep -q "process start bsa" "$TMP/calls.log"
check "unchanged services aren't restarted" bash -c '! grep -q "process start ti-api" "$1"' _ "$TMP/calls.log"

# --- a running service outside this run that the update stopped comes back too ---
sedi 's/  wl-atc: {repo: metro/  wl-atc: {timeout: 30, repo: metro/' "$TMP/ws/stack.yaml"
ds up wl-atc >/dev/null 2>&1
sedi 's/  wl-atc: {timeout: 30, repo: metro/  wl-atc: {timeout: 40, repo: metro/' "$TMP/ws/stack.yaml"
: > "$TMP/calls.log"
ds up bsa >/dev/null 2>&1
check "an untouched running service is restarted after the update stops it" grep -q "process start wl-atc" "$TMP/calls.log"
check "status still lists it" grep -q "^wl-atc" <<<"$(ds status)"

# --- logs are readable: no colour codes ---
printf '\033[31mERROR red\033[0m\n' > "$DEVSTACK_STATE_DIR/logs/bsa.log"
check "logs strip colour codes" [ "$(ds logs bsa)" = "ERROR red" ]

# --- down_without_registry ---
mkdir -p "$TMP/elsewhere"; : > "$TMP/calls.log"
out=$(cd "$TMP/elsewhere" && bash "$DEVSTACK" down 2>&1); code=$?
check "down works without a stack.yaml (got $code: $out)" [ "$code" -eq 0 ]
check "down without a registry still stops the server" grep -q "process-compose down" "$TMP/calls.log"

# --- F1: a bad --from path fails instead of silently using main ---
ds down >/dev/null 2>&1
out=$(ds up bsa --from bsa=/nonexistent/wt 2>&1); code=$?
check "bad --from exits 2 (got $code: $out)" [ "$code" -eq 2 ]
check "bad --from starts nothing" bash -c '! grep -q "Ready" <<<"$1"' _ "$out"

# --- F2: a stale owner doesn't choose the directory of a stopped service ---
ds down >/dev/null 2>&1
echo "{\"bsa\": \"$TMP/gone-wt\"}" > "$DEVSTACK_STATE_DIR/owners.json"
out=$(ds up bsa 2>&1); code=$?
check "stale owner ignored (got $code: $out)" [ "$code" -eq 0 ]
check "runs from the main checkout" [ "$(yq -r '.processes.bsa.working_dir' "$DEVSTACK_STATE_DIR/process-compose.yaml")" = "$TMP/ws/bsa" ]
ds down >/dev/null 2>&1
out=$(STUB_LSOF="3010:node:4242" ds up bsa --from "bsa=$TMP/wt" 2>&1)
check "a failed up records no new owner" bash -c '! grep -q "$1" "$2" 2>/dev/null' _ "$TMP/wt" "$DEVSTACK_STATE_DIR/owners.json"

# --- F3: a registry env change reaches the running service ---
ds up bsa >/dev/null 2>&1
sedi 's/  bsa: {timeout: 60, repo: bsa/  bsa: {env: {FOO: bar}, timeout: 60, repo: bsa/' "$TMP/ws/stack.yaml"
: > "$TMP/calls.log"
ds up bsa >/dev/null 2>&1
check "env change restarts the service" grep -q "process start bsa" "$TMP/calls.log"

# --- F5: a live lock makes a second command wait, then give up ---
sleep 30 & LOCKPID=$!
mkdir -p "$DEVSTACK_STATE_DIR/lock" && echo $LOCKPID > "$DEVSTACK_STATE_DIR/lock/pid"
out=$(DEVSTACK_LOCK_WAIT=1 ds down 2>&1); code=$?
check "held lock: exits 1 (got $code)" [ "$code" -eq 1 ]
check "held lock: names the holder" grep -q "pid $LOCKPID" <<<"$out"
kill $LOCKPID 2>/dev/null; wait $LOCKPID 2>/dev/null
out=$(DEVSTACK_LOCK_WAIT=1 ds down 2>&1); code=$?
check "stale lock is cleared (got $code: $out)" [ "$code" -eq 0 ]
check "lock released after the command" [ ! -d "$DEVSTACK_STATE_DIR/lock" ]

# --- F6: service names are checked ---
out=$(ds restart ../../x 2>&1); code=$?
check "restart rejects a path-like name (got $code)" [ "$code" -eq 2 ]
out=$(ds down nosuch 2>&1); code=$?
check "down rejects an unknown name (got $code)" [ "$code" -eq 2 ]
out=$(ds logs ../x 2>&1); code=$?
check "logs rejects a path-like name (got $code)" [ "$code" -eq 2 ]

# --- B1: up restarts a service nodemon reports as crashed but still running ---
ds down >/dev/null 2>&1
STUB_START_LOG='[nodemon] app crashed - waiting for file changes\n' STUB_NEVER_READY=ti-api ds up ti-api >/dev/null 2>&1
: > "$TMP/calls.log"
out=$(ds up ti-api 2>&1); code=$?
check "crashed-but-running service is restarted (got $code: $out)" grep -qE "process (start|restart) ti-api" "$TMP/calls.log"
check "and comes back Ready" grep -qE "^ti-api +3100 +Ready" <<<"$out"
ds down >/dev/null 2>&1

# --- B2: a failed http health check says what the URL answered ---
stub_bin curl 'echo 404'
out=$(STUB_NEVER_READY=bsa ds up bsa 2>&1)
check "health failure reports the HTTP status (got: $out)" grep -q "health check http://localhost:3010/health answered 404" <<<"$out"
rm -f "$TMP/bin/curl"
ds down >/dev/null 2>&1

# --- M2: docker not installed is a missing prerequisite (exit 3) ---
mv "$TMP/bin/docker" "$TMP/bin/docker.off"
bare="$TMP/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v yq)"):/usr/bin:/bin"
if PATH="$bare" command -v docker >/dev/null 2>&1; then
  echo "skipped the no-docker case: a real docker is on this machine's base PATH"
else
  out=$(PATH="$bare" ds up bsa 2>&1); code=$?
  check "no docker exits 3 (got $code: $out)" [ "$code" -eq 3 ]
fi
mv "$TMP/bin/docker.off" "$TMP/bin/docker"

# --- M3: long log lines are cut ---
printf 'ERROR %0400d\n' 0 > "$DEVSTACK_STATE_DIR/logs/bsa.log"
check "logs cap each line at 300 characters" [ "$(ds logs bsa | awk '{ print length }')" -le 300 ]

# --- M4: the server doesn't inherit the caller's PORT / NODE_OPTIONS ---
ds down >/dev/null 2>&1
sedi 's|^case "\$args" in|[[ "$args" == *" up "* ]] \&\& env > "$PCS/up.env"\ncase "$args" in|' "$TMP/bin/process-compose"
PORT=9999 NODE_OPTIONS=--inspect ds up bsa >/dev/null 2>&1
check "server env has no PORT" bash -c '! grep -q "^PORT=" "$1"' _ "$PCS/up.env"
check "server env has no NODE_OPTIONS" bash -c '! grep -q "^NODE_OPTIONS=" "$1"' _ "$PCS/up.env"
ds down >/dev/null 2>&1

# --- M6: down on a fresh machine ---
out=$(DEVSTACK_STATE_DIR="$TMP/fresh" ds down 2>&1); code=$?
check "down on a fresh state dir exits 0 cleanly (got $code: $out)" bash -c '[ "$1" -eq 0 ] && ! grep -qi "no such file" <<<"$2"' _ "$code" "$out"

# --- conflicts_with: two services that can't share one checkout ---
ds down >/dev/null 2>&1
cat >> "$TMP/ws/stack.yaml" <<'YAML'
YAML
yq -i '.services."tn-web" = {"repo": "metro", "node": "nvmrc", "doppler": "none", "command": "true", "port": 5300, "health": "tcp", "conflicts_with": ["wl-atc"]} | .services."wl-atc".conflicts_with = ["tn-web"]' "$TMP/ws/stack.yaml"
ds up wl-atc >/dev/null 2>&1
: > "$TMP/calls.log"
out=$(ds up tn-web 2>&1); code=$?
check "conflicting service is refused with 2 (got $code)" [ "$code" -eq 2 ]
check "refusal names the other service and the fix (got: $out)" grep -q "tn-web can't run while wl-atc runs from the same folder" <<<"$out"
check "refusal starts nothing" bash -c '! grep -q "process start" "$1"' _ "$TMP/calls.log"
mkdir -p "$TMP/wt-tn" && echo 22.16.0 > "$TMP/wt-tn/.nvmrc"
out=$(ds up tn-web --from "tn-web=$TMP/wt-tn" 2>&1); code=$?
check "from another folder it's allowed (got $code: $out)" [ "$code" -eq 0 ]
ds down >/dev/null 2>&1

# --- S1: a sandbox that blocks the socket isn't reported as "nothing running" ---
ds up bsa >/dev/null 2>&1
out=$(STUB_SANDBOX=1 ds status 2>&1); code=$?
check "blocked socket exits 1 (got $code: $out)" [ "$code" -eq 1 ]
check "blocked socket says why" grep -q "can't reach the devstack server" <<<"$out"
check "blocked socket isn't 'nothing running'" bash -c '! grep -q "nothing running" <<<"$1"' _ "$out"

# --- S2: a service stopped with down shows Stopped, not Crashed ---
ds down >/dev/null 2>&1
STUB_START_LOG='[nodemon] app crashed - waiting\n' STUB_NEVER_READY=ti-api ds up ti-api >/dev/null 2>&1
ds down ti-api >/dev/null 2>&1
out=$(ds status 2>&1)
check "stopped service isn't Crashed (got: $out)" bash -c '! grep -qE "^ti-api .*Crashed" <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

# --- R1: a recovered service (old crash line, now Ready) isn't restarted ---
ds down >/dev/null 2>&1
ds up ti-api >/dev/null 2>&1
printf '[nodemon] app crashed - waiting for file changes\n[nodemon] restarting due to changes...\n[nodemon] starting `node x`\n' >> "$DEVSTACK_STATE_DIR/logs/ti-api.log"
: > "$TMP/calls.log"
ds up ti-api >/dev/null 2>&1
check "recovered service isn't restarted" bash -c '! grep -qE "process (start|restart) ti-api" "$1"' _ "$TMP/calls.log"

# --- R2: restart --from the folder it already runs from still restarts ---
: > "$TMP/calls.log"
ds restart ti-api --from "$TMP/ws/ti" >/dev/null 2>&1
check "restart --from the same folder restarts" grep -qE "process (start|restart) ti-api" "$TMP/calls.log"

# --- R3: restart of a stopped service is refused ---
ds down ti-api >/dev/null 2>&1
: > "$TMP/calls.log"
out=$(ds restart ti-api 2>&1); code=$?
check "restart of a stopped service exits 1 (got $code)" [ "$code" -eq 1 ]
check "restart of a stopped service starts nothing" bash -c '! grep -qE "process (start|restart) ti-api" "$1"' _ "$TMP/calls.log"
ds down >/dev/null 2>&1

# --- R4: a failed down is reported, and the socket is kept ---
ds up bsa >/dev/null 2>&1
out=$(STUB_DOWN_FAILS=1 ds down 2>&1); code=$?
check "failed down exits 1 (got $code: $out)" [ "$code" -eq 1 ]
check "failed down doesn't claim success" bash -c '! grep -q "stopped everything" <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

# --- R5: conflicts_with works when only the other side declares it ---
yq -i 'del(.services."wl-atc".conflicts_with)' "$TMP/ws/stack.yaml"
ds up tn-web >/dev/null 2>&1
out=$(ds up wl-atc 2>&1); code=$?
check "one-sided conflicts_with still refuses (got $code)" [ "$code" -eq 2 ]
ds down >/dev/null 2>&1

# --- C2: each command reads its own registry snapshot and leaves none behind ---
ds status >/dev/null 2>&1
check "no registry snapshots left behind" [ -z "$(ls "$DEVSTACK_STATE_DIR"/registry* 2>/dev/null)" ]

# --- C3: a selected optional dependency is healthy before its dependant starts ---
yq -i '.services.naia = {"repo": "bsa", "node": "nvmrc", "doppler": "none", "command": "true", "port": 4010, "health": "tcp", "timeout": 2} | .services."connect-api".optional_deps = ["naia"]' "$TMP/ws/stack.yaml"
ds down >/dev/null 2>&1; : > "$TMP/calls.log"
out=$(STUB_NEVER_READY=naia ds up connect-api --with naia 2>&1); code=$?
check "unhealthy optional dep fails the run (got $code)" [ "$code" -eq 1 ]
check "its dependant isn't started (calls: $(grep -c 'process start' "$TMP/calls.log"))" bash -c '! grep -q "process start connect-api" "$1"' _ "$TMP/calls.log"
ds down >/dev/null 2>&1

# --- X1: a running stack from another registry isn't changed from this one ---
ds down >/dev/null 2>&1; ds up bsa >/dev/null 2>&1
mkdir -p "$TMP/ws2/bsa" && echo 22.16.0 > "$TMP/ws2/bsa/.nvmrc"
printf 'services:\n  bsa: {repo: bsa, node: nvmrc, doppler: none, command: "true", port: 3010, health: tcp}\ntargets: {}\n' > "$TMP/ws2/stack.yaml"
: > "$TMP/calls.log"
out=$(cd "$TMP/ws2" && bash "$DEVSTACK" up bsa 2>&1); code=$?
check "another registry's stack is refused (got $code: $out)" [ "$code" -eq 2 ]
check "...and isn't updated" bash -c '! grep -q "project update" "$1"' _ "$TMP/calls.log"
ds down >/dev/null 2>&1

# --- X1b: a live stack with no owner marker is claimed by the first registry ---
ds up bsa >/dev/null 2>&1; rm -f "$DEVSTACK_STATE_DIR/server.registry"
ds up bsa >/dev/null 2>&1
out=$(cd "$TMP/ws2" && bash "$DEVSTACK" up bsa 2>&1); code=$?
check "unmarked stack is claimed, then another registry is refused (got $code)" [ "$code" -eq 2 ]
ds down >/dev/null 2>&1

# --- X2: a failed config update keeps the previous owner ---
ds up ti-api >/dev/null 2>&1
before=$(jq -c . "$DEVSTACK_STATE_DIR/owners.json")
out=$(STUB_UPDATE_FAILS=1 ds up ti-api --from "ti-api=$TMP/wt" --takeover 2>&1); code=$?
check "failed update exits 1 (got $code)" [ "$code" -eq 1 ]
check "failed update leaves owners as they were" [ "$(jq -c . "$DEVSTACK_STATE_DIR/owners.json")" = "$before" ]
yq -i '.services."ti-api".command = "echo rejected"' "$TMP/ws/stack.yaml"
STUB_UPDATE_FAILS=1 ds up ti-api >/dev/null 2>&1
check "a rejected update leaves the old launcher" bash -c '! grep -q rejected "$1"' _ "$DEVSTACK_STATE_DIR/run/ti-api.sh"
yq -i '.services."ti-api".command = "true"' "$TMP/ws/stack.yaml"
ds down >/dev/null 2>&1

# --- X3: naming an optional dependency starts it before its dependant ---
: > "$TMP/calls.log"
out=$(ds up connect-api naia 2>&1); code=$?
check "naming an optional dep works (got $code: $(echo $out | cut -c1-80))" [ "$code" -eq 0 ]
check "it starts before its dependant" [ "$(line_of naia)" -lt "$(line_of connect-api)" ]
ds down >/dev/null 2>&1

# --- X5: an unwritable state folder fails at once, not as lock contention ---
mkdir -p "$TMP/ro" && chmod 555 "$TMP/ro"
start=$(date +%s)
out=$(DEVSTACK_STATE_DIR="$TMP/ro/st" ds down 2>&1); code=$?
check "unwritable state exits 1 fast (got $code in $(( $(date +%s) - start ))s)" bash -c '[ "$1" -eq 1 ] && [ "$2" -le 2 ]' _ "$code" "$(( $(date +%s) - start ))"
check "unwritable state names the folder" grep -q "$TMP/ro/st" <<<"$out"
chmod 755 "$TMP/ro"

# --- X6: a leftover reclaim guard doesn't spin forever ---
LP=$(sh -c 'echo $$')   # the pid of a process that has already exited
mkdir -p "$DEVSTACK_STATE_DIR/lock" "$DEVSTACK_STATE_DIR/lock.reclaim" && echo $LP > "$DEVSTACK_STATE_DIR/lock/pid"
start=$(date +%s)
out=$(DEVSTACK_LOCK_WAIT=3 ds down 2>&1); code=$?
check "a leftover reclaim guard times out instead of spinning (got $code in $(( $(date +%s) - start ))s)" bash -c '[ "$1" -eq 1 ] && [ "$2" -le 6 ]' _ "$code" "$(( $(date +%s) - start ))"
check "...and names what to remove" grep -q "lock.reclaim" <<<"$out"
rm -rf "$DEVSTACK_STATE_DIR/lock" "$DEVSTACK_STATE_DIR/lock.reclaim"

# --- socket path too long ---
out=$(DEVSTACK_STATE_DIR="$TMP/$(printf 'x%.0s' {1..110})" ds status 2>&1); code=$?
check "too-long socket path exits 2 (got $code)" [ "$code" -eq 2 ]

finish
