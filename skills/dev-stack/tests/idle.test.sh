#!/bin/bash
# Tests for the idle watchdog: it stops each quiet service (keeping one that a
# running service depends on), takes the stack down with the last one, runs
# once per state folder and exits when the stack goes down another way.
# Checks run every second and the quiet limit is a few seconds, through env.
# Run: bash skills/dev-stack/tests/idle.test.sh
. "$(dirname "$0")/helpers.sh"
. "$(dirname "$0")/fixture.sh"
unset DEVSTACK_IDLE_MINUTES
export DEVSTACK_IDLE_TICK=1 DEVSTACK_IDLE_SECONDS=3
IDLE="$DEVSTACK_STATE_DIR/idle"

wd_pid() { cat "$IDLE/watchdog/pid" 2>/dev/null; }
wd_up() { [ -n "$(wd_pid)" ] && kill -0 "$(wd_pid)" 2>/dev/null; }
alive() { [ -f "$PCS/alive" ]; }
down_now() { [ ! -f "$PCS/alive" ]; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
running() { [ "$(jq -r .is_running "$PCS/procs/$1.json" 2>/dev/null)" = true ]; }
stopped() { [ -f "$PCS/procs/$1.json" ] && ! running "$1"; }
stop_line() { grep -n "process stop $1" "$TMP/calls.log" | head -1 | cut -d: -f1; }
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

# --- one quiet service: it stops, and the stack with it ---
echo 3010 > "$PCS/established"   # held while status is read, so it can't stop first
out=$(ds up bsa 2>&1); code=$?
check "up exits 0 (got $code: $out)" [ "$code" -eq 0 ]
check "up prints nothing about the watchdog (got: $out)" [ "$(wc -l <<<"$out" | tr -d ' ')" = 1 ]
check "up starts a watchdog" wait_for 5 wd_up
pid=$(wd_pid)
out=$(ds status)
check "status shows the countdown (got: $(tail -1 <<<"$out"))" grep -qE "^idle stop in: bsa [0-9]+ s$" <<<"$out"
: > "$PCS/established"
check "the last quiet service takes the stack down" wait_for 15 down_now
check "the stop is recorded" wait_for 5 [ -f "$IDLE/stopped.bsa" ]
check "the watchdog exits after stopping the stack" wait_for 5 pid_gone "$pid"
out=$(ds status)
check "status says what stopped (got: $out)" grep -qE "^stopped while idle: bsa \([0-9]{2}:[0-9]{2}\)$" <<<"$out"
check "the watchdog never touches containers" bash -c '! grep -q "^docker stop" "$1"' _ "$TMP/calls.log"

# --- quiet services stop one by one; a busy one and its dependencies stay ---
: > "$TMP/calls.log"
echo 3200 > "$PCS/established"   # someone is using connect-api
ds up connect wl-atc >/dev/null 2>&1
check "a new up clears the stops it restarts" [ ! -f "$IDLE/stopped.bsa" ]
check "the quiet services stop" wait_for 15 bash -c 'for s in connect-metro wl-atc; do [ -f "$1/procs/$s.json" ] && [ "$(jq -r .is_running "$1/procs/$s.json")" = false ] || exit 1; done' _ "$PCS"
sleep 2
check "the busy service stays up" running connect-api
check "...and so do the quiet services it depends on" bash -c 'running() { [ "$(jq -r .is_running "$1/procs/$2.json")" = true ]; }; running "$1" bsa && running "$1" ti-api' _ "$PCS"
check "the stack stays up" alive
check "...with no down" bash -c '! grep -q "process-compose down" "$1"' _ "$TMP/calls.log"
out=$(ds status)
check "status names what stopped (got: $out)" grep -qE "^stopped while idle: connect-metro \(.*\), wl-atc \(" <<<"$out"
check "status counts the dependencies down with their dependant (got: $out)" grep -qE "^idle stop in: bsa ([0-9]+) s, connect-api \1 s, ti-api \1 s$" <<<"$out"
check "status still lists the stopped ones as Stopped" grep -qE "^wl-atc +5200 +Stopped" <<<"$out"

# --- a dependant stops before what it depends on; a busy dependency stays ---
: > "$TMP/calls.log"
echo 3010 > "$PCS/established"   # now only bsa is in use
check "the quiet dependant stops" wait_for 15 stopped connect-api
check "...then its now-unneeded dependency" wait_for 5 stopped ti-api
check "...in that order" [ "$(stop_line connect-api)" -lt "$(stop_line ti-api)" ]
check "the busy dependency stays" running bsa
: > "$PCS/established"
check "once the last one is quiet the stack goes down" wait_for 15 down_now

# --- when everything is quiet, dependants still stop first, then the server ---
: > "$TMP/calls.log"
ds up connect-api >/dev/null 2>&1
check "a whole quiet stack goes down" wait_for 15 down_now
check "...its dependant stopped before its dependencies" bash -c 'a=$(grep -n "process stop connect-api" "$1" | cut -d: -f1); b=$(grep -n "process stop bsa" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$TMP/calls.log"
check "...and the server went last" bash -c 'b=$(grep -n "process stop ti-api" "$1" | cut -d: -f1); d=$(grep -n "process-compose down" "$1" | cut -d: -f1); [ -n "$b" ] && [ -n "$d" ] && [ "$b" -lt "$d" ]' _ "$TMP/calls.log"

# --- process-compose's own readiness-probe connection isn't activity ---
echo 3010 > "$PCS/probe"
ds up bsa >/dev/null 2>&1
check "a service with only the probe connected still stops" wait_for 15 down_now
: > "$PCS/probe"

# --- a round slower than the limit doesn't read a service it just saw used as quiet ---
echo 3010 > "$PCS/established"; touch "$PCS/slow-lsof"
ds up bsa >/dev/null 2>&1
sleep 12
check "a busy service survives rounds that take longer than the limit" alive
rm -f "$PCS/slow-lsof"; : > "$PCS/established"
ds down >/dev/null 2>&1

# --- a large burst of log lines counts (no SIGPIPE under pipefail) ---
ds up bsa >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8; do seq 1 200000 | sed 's/^/GET \/api\/row /' >> "$DEVSTACK_STATE_DIR/logs/bsa.log"; sleep 1; done
check "a service writing large bursts stays up" alive
ds down >/dev/null 2>&1

# --- new log lines keep a service up; health-check lines don't ---
ds up bsa >/dev/null 2>&1
keep_busy 6 "GET /api/things 200"
check "a service writing to its log stays up" alive
keep_busy 10 "GET /health 200" &
busy=$!
check "health-check lines alone don't count as activity" wait_for 10 down_now
kill "$busy" 2>/dev/null; wait "$busy" 2>/dev/null

# --- a server left with nothing running goes down too ---
ds up bsa >/dev/null 2>&1
wait_for 5 wd_up; pid=$(wd_pid)
ds down bsa >/dev/null 2>&1
check "an empty server goes down after the quiet time" wait_for 15 down_now
check "...and its watchdog exits" wait_for 5 pid_gone "$pid"

# --- only one watchdog per state folder ---
ds up bsa >/dev/null 2>&1
check "the watchdog is back" wait_for 5 wd_up
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

# --- a live process that reused a dead watchdog's pid is neither trusted nor killed ---
pid=$(wd_pid); kill "$pid"; wait_for 5 pid_gone "$pid"
sleep 60 & OTHER=$!
mkdir -p "$IDLE/watchdog" && echo "$OTHER" > "$IDLE/watchdog/pid"
ds up bsa >/dev/null 2>&1
check "up starts a watchdog despite a reused pid" wait_for 5 bash -c 'p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && [ "$p" != "$2" ] && kill -0 "$p"' _ "$IDLE/watchdog/pid" "$OTHER"
ds down >/dev/null 2>&1
mkdir -p "$IDLE/watchdog" && echo "$OTHER" > "$IDLE/watchdog/pid"
ds down >/dev/null 2>&1
check "down doesn't signal an unrelated process" kill -0 "$OTHER"
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
ds up bsa >/dev/null 2>&1; wait_for 5 wd_up

# --- where a live pid's command can't be read (ps blocked), its claim is kept
# and it's never signalled. Linux reads /proc instead, so this is macOS-only. ---
if [ ! -r /proc/self/cmdline ]; then
  pid=$(wd_pid); kill "$pid"; wait_for 5 pid_gone "$pid"
  sleep 60 & OTHER=$!
  mkdir -p "$IDLE/watchdog" && echo "$OTHER" > "$IDLE/watchdog/pid"
  stub_bin ps 'exit 1'
  ds up bsa >/dev/null 2>&1
  sleep 2
  check "an unreadable live claim is kept" [ "$(wd_pid)" = "$OTHER" ]
  ds down >/dev/null 2>&1
  check "...and not signalled" kill -0 "$OTHER"
  rm -f "$TMP/bin/ps"; kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
  rm -rf "$IDLE/watchdog"
  ds up bsa >/dev/null 2>&1; wait_for 5 wd_up
fi

# --- it exits after a manual down ---
pid=$(wd_pid)
ds down >/dev/null 2>&1
check "down ends the watchdog" wait_for 3 pid_gone "$pid"
check "...and releases its claim" [ ! -d "$IDLE/watchdog" ]
check "a manual down clears the idle records" [ -z "$(ls "$IDLE"/stopped.* "$IDLE"/active.* 2>/dev/null)" ]

# --- it exits when the server dies some other way ---
ds up bsa >/dev/null 2>&1
wait_for 5 wd_up; pid=$(wd_pid)
rm -f "$PCS/alive" "$PCS"/procs/*.json
check "a server that went away ends the watchdog" wait_for 5 pid_gone "$pid"
check "...without recording an idle stop" [ ! -f "$IDLE/stopped.bsa" ]
ds down >/dev/null 2>&1

# --- a devstack command that's running counts as activity ---
ds up bsa >/dev/null 2>&1
wait_for 5 wd_up
sleep 60 & LOCKPID=$!
mkdir -p "$DEVSTACK_STATE_DIR/lock" && echo $LOCKPID > "$DEVSTACK_STATE_DIR/lock/pid"
sleep 6
check "the stack stays up while another command holds the lock" alive
kill $LOCKPID 2>/dev/null; wait $LOCKPID 2>/dev/null; rm -rf "$DEVSTACK_STATE_DIR/lock"
check "...and is stopped once it's free" wait_for 10 down_now
ds down >/dev/null 2>&1

# --- DEVSTACK_IDLE_MINUTES=0 turns it off; a bad value is refused ---
env -u DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_MINUTES=0 bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" >/dev/null 2>&1
sleep 1
check "minutes=0 starts no watchdog" bash -c '! [ -d "$1/watchdog" ]' _ "$IDLE"
check "status says it's off" grep -q "^idle shutdown: off" <<<"$(ds status)"
ds down >/dev/null 2>&1
out=$(env -u DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_MINUTES=soon bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" 2>&1); code=$?
check "a bad DEVSTACK_IDLE_MINUTES exits 2 (got $code: $out)" [ "$code" -eq 2 ]
check "...before starting anything" down_now

env -u DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_MINUTES=08 bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" >/dev/null 2>&1
check "DEVSTACK_IDLE_MINUTES=08 is eight minutes, not an octal error (got $(cat "$IDLE/limit"))" [ "$(cat "$IDLE/limit")" = 480 ]
ds down >/dev/null 2>&1

# --- the registry sets the default; a bad value is a registry problem ---
yq -i '.idle = {"minutes": "15"}' "$TMP/ws/stack.yaml"
out=$(ds status 2>&1); code=$?
check "a non-number idle.minutes exits 2 (got $code)" [ "$code" -eq 2 ]
check "...and says what's wrong" grep -q "idle.minutes: must be a whole number" <<<"$out"
yq -i '.idle = {"minutes": 0}' "$TMP/ws/stack.yaml"
env -u DEVSTACK_IDLE_SECONDS bash -c 'cd "$1" && bash "$2" up bsa' _ "$TMP/ws" "$DEVSTACK" >/dev/null 2>&1
check "idle.minutes: 0 in the registry turns it off" grep -q "^idle shutdown: off" <<<"$(ds status)"
ds down >/dev/null 2>&1

# --- a running service the registry snapshot doesn't list still stops ---
ds up wl-atc >/dev/null 2>&1
jq 'del(."wl-atc")' "$IDLE/services.json" > "$IDLE/s.tmp" && mv "$IDLE/s.tmp" "$IDLE/services.json"
rm -f "$IDLE/active.wl-atc"
check "a service missing from the snapshot isn't kept up forever" wait_for 15 down_now

# --- a failing process list stops nothing ---
: > "$TMP/calls.log"
echo 3100 > "$PCS/established"
ds up bsa ti-api >/dev/null 2>&1
touch "$PCS/list-fails"
sleep 6
check "nothing stops while the process list fails" bash -c '! grep -qE "process stop|process-compose down" "$1"' _ "$TMP/calls.log"
rm -f "$PCS/list-fails"; touch "$PCS/list-object"
sleep 6
check "...or answers with something other than a list" bash -c '! grep -qE "process stop|process-compose down" "$1"' _ "$TMP/calls.log"
rm -f "$PCS/list-object"
check "...and the quiet one stops once it answers" wait_for 15 stopped bsa
: > "$PCS/established"; ds down >/dev/null 2>&1

# --- a loop of optional dependencies doesn't hang status ---
yq -i '.services."wl-atc".optional_deps = ["connect-metro"] | .services."connect-metro".optional_deps = ["wl-atc"]' "$TMP/ws/stack.yaml"
ds up wl-atc >/dev/null 2>&1; ds up connect-metro >/dev/null 2>&1
ds status > "$TMP/status.out" 2>&1 & sp=$!
check "status returns with a dependency loop" wait_for 10 pid_gone "$sp"
kill "$sp" 2>/dev/null
check "...and shows both countdowns (got: $(tail -1 "$TMP/status.out"))" grep -qE "^idle stop in: .*connect-metro.*wl-atc|^idle stop in: .*wl-atc.*connect-metro" "$TMP/status.out"
ds down >/dev/null 2>&1
yq -i 'del(.services."wl-atc".optional_deps) | del(.services."connect-metro".optional_deps)' "$TMP/ws/stack.yaml"

# --- an uncapped MongoDB container gets one hint per state folder ---
rm -f "$PCS"/docker-started.*
check "a capped MongoDB gets no hint" [ ! -f "$DEVSTACK_STATE_DIR/infra-hinted" ]
out=$(STUB_IMAGES="mongodb=mongo:7|mongod,--bind_ip_all" DEVSTACK_IDLE_SECONDS=0 ds up ti-api 2>&1)
check "uncapped MongoDB is pointed out (got: $out)" grep -q "container mongodb runs MongoDB without a cache cap.*--wiredTigerCacheSizeGB 1" <<<"$out"
out=$(STUB_IMAGES="mongodb=mongo:7|mongod,--bind_ip_all" DEVSTACK_IDLE_SECONDS=0 ds up ti-api 2>&1)
check "...only once" bash -c '! grep -q "cache cap" <<<"$1"' _ "$out"
ds down >/dev/null 2>&1

finish
