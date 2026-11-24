#!/bin/bash
# Tests for the idle watchdog: it stops a quiet stack, leaves a busy one up,
# runs once per state folder and exits when the stack goes down another way.
# Checks run every second and the quiet limit is a few seconds, through env.
# Run: bash skills/dev-stack/tests/idle.test.sh
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fixture.sh"
unset DEVSTACK_IDLE_MINUTES
export DEVSTACK_IDLE_TICK=1 DEVSTACK_IDLE_SECONDS=3
IDLE="$DEVSTACK_STATE_DIR/idle"

wd_pid() { cat "$IDLE/watchdog/pid" 2>/dev/null; }
alive() { [ -f "$PCS/alive" ]; }
_ds_wd_up() { [ -n "$(wd_pid)" ] && kill -0 "$(wd_pid)" 2>/dev/null; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
# wait_for <seconds> <command...>: poll until the command succeeds.
wait_for() {
  local n=$(( $1 * 5 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done
  return 1
}
# keep_busy <seconds> <line>: append <line> to bsa's log every half second.
keep_busy() {
  local n=$(( $1 * 2 ))
  while [ "$n" -gt 0 ]; do echo "$2" >> "$DEVSTACK_STATE_DIR/logs/bsa.log"; sleep 0.5; n=$((n - 1)); done
}
trap 'p=$(wd_pid); [ -n "$p" ] && kill "$p" 2>/dev/null; rm -rf "$TMP"' EXIT

# --- idle → down ---
out=$(ds up bsa 2>&1); code=$?
check "up exits 0 (got $code: $out)" [ "$code" -eq 0 ]
check "up prints nothing about the watchdog (got: $out)" [ "$(wc -l <<<"$out" | tr -d ' ')" = 1 ]
check "up starts a watchdog" wait_for 5 _ds_wd_up
pid=$(wd_pid)
check "status shows the countdown (got: $(ds status | tail -1))" grep -qE "^idle shutdown in [0-9]+ s unless" <<<"$(ds status)"
check "a quiet stack is stopped" wait_for 15 bash -c '! [ -f "$1" ]' _ "$PCS/alive"
wait_for 5 [ -f "$IDLE/stopped" ]
check "the reason is recorded" grep -q "stopped by the idle watchdog: no connections or log output for 3 s" "$IDLE/stopped"
check "the watchdog exits after stopping the stack" wait_for 5 pid_gone "$pid"
out=$(ds status)
check "status says why nothing is running (got: $out)" grep -q "^last stop: .*idle watchdog" <<<"$out"
check "containers are left alone without idle.stop_infra" bash -c '! grep -q "^docker stop" "$1"' _ "$TMP/calls.log"

# --- an open connection keeps it up ---
echo 3010 > "$PCS/established"
ds up bsa >/dev/null 2>&1
check "a new up clears the last stop" [ ! -f "$IDLE/stopped" ]
sleep 6
check "a service with an open connection stays up" alive
: > "$PCS/established"

# --- new log lines keep it up; health-check lines don't ---
keep_busy 6 "GET /api/things 200"
check "a service writing to its log stays up" alive
keep_busy 10 "GET /health 200" &
busy=$!
check "health-check lines alone don't count as activity" wait_for 10 bash -c '! [ -f "$1" ]' _ "$PCS/alive"
kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null

# --- only one watchdog per state folder ---
ds up bsa >/dev/null 2>&1
check "the watchdog is back" wait_for 5 _ds_wd_up
pid=$(wd_pid)
ds up ti-api >/dev/null 2>&1
check "a second up keeps the same watchdog" [ "$(wd_pid)" = "$pid" ]
start=$(date +%s)
(cd "$TMP/ws" && bash "$DEVSTACK" idle-watch >/dev/null 2>&1)
check "a second watchdog exits at once" [ $(( $(date +%s) - start )) -le 2 ]
check "...and leaves the first one's claim" [ "$(wd_pid)" = "$pid" ]

# --- a stale claim from a dead watchdog is taken over ---
kill "$pid"; wait_for 5 pid_gone "$pid"
LP=$(sh -c 'echo $$')   # the pid of a process that has already exited
mkdir -p "$IDLE/watchdog" && echo "$LP" > "$IDLE/watchdog/pid"
ds up bsa >/dev/null 2>&1
check "up replaces a dead watchdog" wait_for 5 bash -c 'p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && [ "$p" != "$2" ] && kill -0 "$p"' _ "$IDLE/watchdog/pid" "$LP"

# --- it exits after a manual down ---
pid=$(wd_pid)
ds down >/dev/null 2>&1
check "down ends the watchdog" wait_for 3 pid_gone "$pid"
check "...and releases its claim" [ ! -d "$IDLE/watchdog" ]
check "a manual down records no idle stop" [ ! -f "$IDLE/stopped" ]

# --- it exits when the server dies some other way ---
ds up bsa >/dev/null 2>&1
wait_for 5 _ds_wd_up; pid=$(wd_pid)
rm -f "$PCS/alive" "$PCS"/procs/*.json
check "a server that went away ends the watchdog" wait_for 5 pid_gone "$pid"
check "...without recording an idle stop" [ ! -f "$IDLE/stopped" ]
ds down >/dev/null 2>&1

# --- a devstack command that's running counts as activity ---
ds up bsa >/dev/null 2>&1
wait_for 5 _ds_wd_up; pid=$(wd_pid)
sleep 60 & LOCKPID=$!
mkdir -p "$DEVSTACK_STATE_DIR/lock" && echo $LOCKPID > "$DEVSTACK_STATE_DIR/lock/pid"
sleep 6
check "the stack stays up while another command holds the lock" alive
kill $LOCKPID 2>/dev/null; wait $LOCKPID 2>/dev/null; rm -rf "$DEVSTACK_STATE_DIR/lock"
check "...and is stopped once it's free" wait_for 10 bash -c '! [ -f "$1" ]' _ "$PCS/alive"
ds down >/dev/null 2>&1

# --- DEVSTACK_IDLE_MINUTES=0 turns it off; a bad value is refused ---
out=$(env -u DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_MINUTES=0 bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" 2>&1)
sleep 1
check "minutes=0 starts no watchdog" bash -c '! [ -d "$1/watchdog" ]' _ "$IDLE"
check "status says it's off" grep -q "^idle shutdown: off" <<<"$(ds status)"
ds down >/dev/null 2>&1
out=$(env -u DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_MINUTES=soon bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" 2>&1); code=$?
check "a bad DEVSTACK_IDLE_MINUTES exits 2 (got $code: $out)" [ "$code" -eq 2 ]
check "...before starting anything" bash -c '! [ -f "$1" ]' _ "$PCS/alive"

# --- the registry sets the default; a bad value is a registry problem ---
yq -i '.idle = {"minutes": "15"}' "$TMP/ws/stack.yaml"
out=$(ds status 2>&1); code=$?
check "a non-number idle.minutes exits 2 (got $code)" [ "$code" -eq 2 ]
check "...and says what's wrong" grep -q "idle.minutes: must be a whole number" <<<"$out"
yq -i '.idle = {"minutes": 0}' "$TMP/ws/stack.yaml"
env -u DEVSTACK_IDLE_SECONDS bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" >/dev/null 2>&1
check "idle.minutes: 0 in the registry turns it off" grep -q "^idle shutdown: off" <<<"$(ds status)"
ds down >/dev/null 2>&1

# --- idle.stop_infra stops the containers devstack started, and only those ---
yq -i '.idle = {"stop_infra": true}' "$TMP/ws/stack.yaml"
rm -f "$PCS"/docker-started.*; : > "$TMP/calls.log"
STUB_CONTAINERS="redis:false mongodb:true" ds up bsa ti-api >/dev/null 2>&1
check "the watchdog stops the quiet stack" wait_for 15 bash -c '! [ -f "$1" ]' _ "$PCS/alive"
wait_for 5 [ -f "$IDLE/stopped" ]   # the containers go after the services
check "...then the container it started" grep -q "^docker stop redis" "$TMP/calls.log"
check "...but not one that was already running" bash -c '! grep -q "^docker stop mongodb" "$1"' _ "$TMP/calls.log"
check "the reason names the stopped container" grep -q "stopped the containers devstack had started: redis" "$IDLE/stopped"
yq -i 'del(.idle)' "$TMP/ws/stack.yaml"

# --- an uncapped MongoDB container gets one hint per state folder ---
check "a capped MongoDB gets no hint" [ ! -f "$DEVSTACK_STATE_DIR/infra-hinted" ]
out=$(STUB_IMAGES="mongodb=mongo:7|mongod,--bind_ip_all" DEVSTACK_IDLE_SECONDS=0 ds up ti-api 2>&1)
check "uncapped MongoDB is pointed out (got: $out)" grep -q "container mongodb runs MongoDB without a cache cap.*--wiredTigerCacheSizeGB 1" <<<"$out"
out=$(STUB_IMAGES="mongodb=mongo:7|mongod,--bind_ip_all" DEVSTACK_IDLE_SECONDS=0 ds up ti-api 2>&1)
check "...only once" bash -c '! grep -q "cache cap" <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

finish
