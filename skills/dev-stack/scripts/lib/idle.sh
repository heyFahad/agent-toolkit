#!/bin/bash
# The idle watchdog: one background process per state folder that runs
# `devstack down` once no managed service has had a connection or written a
# log line for a while. `up` starts it, `down` stops it, `status` shows its
# countdown. It uses runtime.sh's process-compose helpers, which source it.
#
# Files in $STATE/idle:
#   limit         seconds of quiet before the shutdown (0: off), set by each up
#   last_active   epoch seconds of the last activity (or up / restart)
#   services.tsv  service, port and health-check path, from the registry
#   stop_infra    true when the registry asks to stop containers devstack started
#   watchdog/pid  the running watchdog (a directory, so only one can claim it)
#   size.<svc>    each service log's size at the last check
#   stopped       why the watchdog last stopped the stack
#   watch.log     the watchdog's own output
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

_ds_idle_dir() { echo "$(ds_state_dir)/idle"; }

# _ds_idle_limit <registry_json_file>: seconds of quiet before the shutdown,
# 0 when it's off. DEVSTACK_IDLE_MINUTES overrides the registry's idle.minutes
# (default 15); DEVSTACK_IDLE_SECONDS overrides both, for tests.
_ds_idle_limit() {
  local m s
  m=${DEVSTACK_IDLE_MINUTES:-$(jq -r '.idle.minutes // 15' "$1")}
  [[ $m =~ ^[0-9]+$ ]] || ds_die 2 "DEVSTACK_IDLE_MINUTES must be a whole number of minutes (0 turns the idle shutdown off), got $m"
  s=${DEVSTACK_IDLE_SECONDS:-$((m * 60))}
  [[ $s =~ ^[0-9]+$ ]] || ds_die 2 "DEVSTACK_IDLE_SECONDS must be a whole number, got $s"
  echo "$s"
}

# _ds_dur <seconds>: "15 min", "1 min" or "40 s".
_ds_dur() { if [ "$1" -ge 60 ]; then echo "$(( ($1 + 30) / 60 )) min"; else echo "$1 s"; fi; }

_ds_idle_pid() { cat "$(_ds_idle_dir)/watchdog/pid" 2>/dev/null; }
_ds_idle_running() { local p; p=$(_ds_idle_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# _ds_idle_touch: count now as activity (up and restart call it).
_ds_idle_touch() { mkdir -p "$(_ds_idle_dir)" && date +%s > "$(_ds_idle_dir)/last_active"; }

# _ds_idle_arm <limit>: record the settings for this stack and start the
# watchdog unless one is already running. Called by up with $DS_REG loaded.
_ds_idle_arm() {
  local dir limit=$1
  dir=$(_ds_idle_dir); mkdir -p "$dir"
  echo "$limit" > "$dir/limit"
  jq -r '.idle.stop_infra // false' "$DS_REG" > "$dir/stop_infra"
  jq -r '.services | to_entries[] | [.key, (.value.port | tostring),
      (if .value.health == "tcp" then "" else (.value.health | capture("^http://[^/?#]+(?<p>[/?][^#]*)?$").p // "") end)]
    | @tsv' "$DS_REG" > "$dir/services.tsv"
  _ds_idle_touch
  rm -f "$dir/stopped"
  [ "$limit" -gt 0 ] || return 0
  _ds_idle_running && return 0
  # Detached from this command's session and output, so an agent's shell
  # that ends (or captures up's output) neither waits for nor kills it.
  ( trap '' HUP; _ds_detach bash "$DS_LIB/../devstack" idle-watch ) </dev/null >>"$dir/watch.log" 2>&1 &
}

# _ds_detach <cmd...>: run it in a session of its own where the OS allows.
_ds_detach() {
  if command -v setsid >/dev/null 2>&1; then exec setsid "$@"
  elif command -v perl >/dev/null 2>&1; then exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' "$@"
  else exec "$@"; fi
}

# _ds_idle_claim: become the one watchdog for this state folder, or return 1.
# The same directory lock as _ds_lock: a dead claimant's lock is reclaimed
# under a guard, and only if it still names that same dead pid.
_ds_idle_claim() {
  local dir holder
  dir=$(_ds_idle_dir)
  for _ in 1 2 3; do
    if mkdir "$dir/watchdog" 2>/dev/null; then echo $$ > "$dir/watchdog/pid"; return 0; fi
    holder=$(cat "$dir/watchdog/pid" 2>/dev/null)
    # No pid yet: another watchdog is mid-claim.
    { [ -z "$holder" ] || kill -0 "$holder" 2>/dev/null; } && return 1
    mkdir "$dir/watchdog.reclaim" 2>/dev/null || return 1
    [ "$(cat "$dir/watchdog/pid" 2>/dev/null)" = "$holder" ] && rm -rf "$dir/watchdog"
    rmdir "$dir/watchdog.reclaim"
  done
  return 1
}
_ds_idle_release() {
  local dir; dir=$(_ds_idle_dir)
  [ "$(cat "$dir/watchdog/pid" 2>/dev/null)" = $$ ] && rm -rf "$dir/watchdog"
  return 0
}

# _ds_idle_stop: end the watchdog (from down), unless this process is it.
_ds_idle_stop() {
  local p
  p=$(_ds_idle_pid)
  [ -n "$p" ] && [ "$p" != $$ ] || return 0
  kill "$p" 2>/dev/null || return 0
  # Wait for it to let go, so an up right after this starts a new one.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 0.1
  done
}

# _ds_connections: every established TCP connection as "<addr>:<port>-><addr>:<port>",
# from one lsof (or ss) call: on a machine where security agents inspect
# every process launch, one call per check is cheaper than one per port.
_ds_connections() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:ESTABLISHED -Fn 2>/dev/null | sed -n 's/^n//p'
  elif command -v ss >/dev/null 2>&1; then
    ss -Htn state established 2>/dev/null | awk '{ print $3 "->" $4 }'
  fi
}

# _ds_idle_active: 0 when any running service has a connection on its port or
# new log lines since the last check. Lines naming the service's health-check
# path are process-compose's own probes, not someone using the service.
_ds_idle_active() {
  local dir svc port hp log size prev conns active=1
  dir=$(_ds_idle_dir)
  conns=$(_ds_connections)
  while IFS=$'\t' read -r svc port hp; do
    [ -n "$svc" ] || continue
    # Either end: a browser connected to the service, or the service's own
    # client side of a connection on that port.
    if [ -n "$port" ] && grep -qE ":$port(->|\$)" <<<"$conns"; then active=0; fi
    log="$(ds_state_dir)/logs/$svc.log"
    size=$(wc -c < "$log" 2>/dev/null | tr -d ' '); size=${size:-0}
    prev=$(cat "$dir/size.$svc" 2>/dev/null)
    echo "$size" > "$dir/size.$svc"
    [ -n "$prev" ] || continue
    if [ "$size" -lt "$prev" ]; then
      active=0   # the log was cleared: the service was restarted
    elif [ "$size" -gt "$prev" ]; then
      if [ -n "$hp" ] && [ "$hp" != / ]; then
        tail -c +$((prev + 1)) "$log" | grep -vF -- "$hp" | grep -q '[^[:space:]]' && active=0
      else
        tail -c +$((prev + 1)) "$log" | grep -q '[^[:space:]]' && active=0
      fi
    fi
  done < <(jq -r '.[] | select(.is_running == true) | .name' <<<"$(_ds_ps)" \
             | awk -F'\t' 'NR == FNR { want[$0] = 1; next } want[$1]' - "$dir/services.tsv")
  return $active
}

# _ds_idle_shutdown <limit>: stop the stack if it's still idle. Returns 1 when
# it didn't: a devstack command holds the lock, or one ran since the check.
_ds_idle_shutdown() {
  local dir now last reason stopped
  dir=$(_ds_idle_dir)
  _ds_try_lock || return 1
  now=$(date +%s); last=$(cat "$dir/last_active" 2>/dev/null || echo "$now")
  if [ $((now - last)) -lt "$1" ]; then _ds_unlock; return 1; fi
  _ds_down_all
  reason="$(date '+%Y-%m-%d %H:%M') stopped by the idle watchdog: no connections or log output for $(_ds_dur "$1")"
  if [ "$(cat "$dir/stop_infra" 2>/dev/null)" = true ]; then
    stopped=$(ds_infra_stop_started)
    [ -n "$stopped" ] && reason="$reason; stopped the containers devstack had started: $stopped"
  fi
  echo "$reason" > "$dir/stopped"
  echo "$reason"
  _ds_unlock
}

# cmd_idle_watch: the watchdog loop (devstack idle-watch; up starts it).
# DEVSTACK_IDLE_TICK sets the seconds between checks (default 60).
cmd_idle_watch() {
  local dir tick limit now last
  DS_SOCK=$(_ds_sock) || exit $?
  dir=$(_ds_idle_dir); mkdir -p "$dir"
  _ds_idle_claim || exit 0
  DS_IDLE_OWNED=1
  trap _ds_exit EXIT
  trap 'exit 0' TERM INT
  tick=${DEVSTACK_IDLE_TICK:-60}
  rm -f "$dir"/size.*
  echo "$(date '+%F %T') watching (pid $$)"
  while :; do
    sleep "$tick" & DS_SLEEP=$!
    wait "$DS_SLEEP"; DS_SLEEP=""
    limit=$(cat "$dir/limit" 2>/dev/null)
    [ "${limit:-0}" -gt 0 ] 2>/dev/null || { echo "$(date '+%F %T') idle shutdown turned off"; exit 0; }
    _ds_alive || { echo "$(date '+%F %T') the stack is down"; exit 0; }
    if _ds_idle_active; then date +%s > "$dir/last_active"; fi
    now=$(date +%s); last=$(cat "$dir/last_active" 2>/dev/null || echo "$now")
    [ $((now - last)) -ge "$limit" ] || continue
    _ds_idle_shutdown "$limit" && exit 0
  done
}

# _ds_idle_status <running: 0|1>: status's last line.
_ds_idle_status() {
  local dir limit now last left
  dir=$(_ds_idle_dir)
  if [ "$1" = 0 ]; then
    [ -f "$dir/stopped" ] && echo "last stop: $(cat "$dir/stopped")"
    return 0
  fi
  limit=$(cat "$dir/limit" 2>/dev/null)
  if [ "${limit:-0}" -le 0 ] 2>/dev/null; then echo "idle shutdown: off"; return 0; fi
  if ! _ds_idle_running; then echo "idle shutdown: the watchdog isn't running (the next devstack up starts it)"; return 0; fi
  now=$(date +%s); last=$(cat "$dir/last_active" 2>/dev/null || echo "$now")
  left=$((limit - (now - last))); [ "$left" -ge 0 ] || left=0
  echo "idle shutdown in $(_ds_dur "$left") unless a service gets a connection or writes to its log (quiet for $(_ds_dur $((now - last))))"
}
