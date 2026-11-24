#!/bin/bash
# The idle watchdog: one background process per state folder that stops each
# service nobody has used for a while: no connection on its port and no new
# log line. A quiet service that something still running depends on stays up
# until its dependants stop too. When the last service stops, the stack goes
# down. `up` starts the watchdog, `down` ends it, `status` shows its countdown.
# It uses runtime.sh's process-compose helpers, which source it.
#
# Files in $STATE/idle:
#   limit          seconds of quiet before a service stops (0: off), set by each up
#   services.json  each service's port, health-check path, dependencies and containers
#   active.<svc>   epoch seconds of the service's last activity (or up / restart)
#   size.<svc>     the service log's size at the last check
#   stopped.<svc>  when the watchdog stopped the service
#   empty_since    when the server was first seen running no service at all
#   stop_infra     true when the registry asks to stop containers devstack started
#   watchdog/pid   the running watchdog (a directory, so only one can claim it)
#   watch.log      the watchdog's own output
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

_ds_idle_dir() { echo "$(ds_state_dir)/idle"; }

# _ds_idle_limit <registry_json_file>: seconds of quiet before a service stops,
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

# _ds_idle_touch <svc...>: count now as activity for each (up and restart call it).
_ds_idle_touch() {
  local dir now s
  dir=$(_ds_idle_dir); mkdir -p "$dir"; now=$(date +%s)
  for s in "$@"; do echo "$now" > "$dir/active.$s"; rm -f "$dir/stopped.$s"; done
}

# _ds_idle_forget: clear the per-service records (a manual down of everything).
_ds_idle_forget() {
  local dir; dir=$(_ds_idle_dir)
  rm -f "$dir"/active.* "$dir"/stopped.* "$dir"/size.* "$dir/empty_since"
}

# _ds_idle_arm <limit> <svc...>: record the settings, count the services this
# up starts as active, and start the watchdog unless one is already running.
# Called by up with $DS_REG loaded.
_ds_idle_arm() {
  local dir limit=$1
  shift
  dir=$(_ds_idle_dir); mkdir -p "$dir"
  echo "$limit" > "$dir/limit"
  jq -r '.idle.stop_infra // false' "$DS_REG" > "$dir/stop_infra"
  jq '.services | map_values({port,
      hp: (if .health == "tcp" then "" else (.health | capture("^http://[^/?#]+(?<p>[/?][^#]*)?$").p // "") end),
      needs: ((.depends_on // []) + (.optional_deps // [])), infra: (.infra // [])})' "$DS_REG" > "$dir/services.json"
  _ds_idle_touch "$@"
  rm -f "$dir/empty_since"
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

# _ds_idle_running_json: the running services, as a JSON array of names.
_ds_idle_running_json() { jq -c '[.[] | select(.is_running == true) | .name]' <<<"$(_ds_ps)"; }

# _ds_idle_active <running_json>: print each running service that had a
# connection on its port or new log lines since the last check, or that has
# no activity on record yet. Lines naming the service's health-check path are
# process-compose's own probes, not someone using the service.
_ds_idle_active() {
  local dir svc port hp log size prev conns
  dir=$(_ds_idle_dir)
  conns=$(_ds_connections)
  while IFS=$'\t' read -r svc port hp; do
    [ -n "$svc" ] || continue
    [ -f "$dir/active.$svc" ] || { echo "$svc"; continue; }
    # Either end of a connection on the port: a browser using the service, or
    # another service calling it.
    if [ -n "$port" ] && grep -qE ":$port(->|\$)" <<<"$conns"; then echo "$svc"; continue; fi
    log="$(ds_state_dir)/logs/$svc.log"
    size=$(wc -c < "$log" 2>/dev/null | tr -d ' '); size=${size:-0}
    prev=$(cat "$dir/size.$svc" 2>/dev/null)
    echo "$size" > "$dir/size.$svc"
    [ -n "$prev" ] || continue
    if [ "$size" -lt "$prev" ]; then
      echo "$svc"   # the log was cleared: the service was restarted
    elif [ "$size" -gt "$prev" ]; then
      if [ -n "$hp" ] && [ "$hp" != / ]; then
        tail -c +$((prev + 1)) "$log" | grep -vF -- "$hp" | grep -q '[^[:space:]]' && echo "$svc"
      else
        tail -c +$((prev + 1)) "$log" | grep -q '[^[:space:]]' && echo "$svc"
      fi
    fi
  done < <(jq -r --argjson r "$1" '. as $all | $r[] | select($all[.]) | [., ($all[.].port | tostring), $all[.].hp] | @tsv' "$dir/services.json")
  return 0
}

# _ds_idle_times: {svc: last activity} from the active.* files.
_ds_idle_times() {
  local f
  for f in "$(_ds_idle_dir)"/active.*; do
    [ -f "$f" ] && printf '%s\t%s\n' "${f##*/active.}" "$(cat "$f" 2>/dev/null)"
  done | jq -R -s '[split("\n")[] | select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber?)}] | add // {}'
}

# The dependency rules, shared by the stop plan and the countdown.
# shellcheck disable=SC2016 # a jq program, not shell
_DS_IDLE_JQ='
def needs($s): $svcs[$s].needs // [];
def dependants($s): [$running[] | select(. as $d | any(needs($d)[]; . == $s))];
def quiet($s): $now - ($active[$s] // $now);
# Keep only the quiet services whose running dependants are all stopping too.
def shrink($q): [$q[] | . as $s | select(all(dependants($s)[]; . as $d | any($q[]; . == $d)))] as $n
  | if ($n | length) == ($q | length) then $n else shrink($n) end;
# Dependants before what they depend on.
def order($q): if ($q | length) == 0 then []
  else [$q[] | . as $s | select(any($q[]; . as $d | any(needs($d)[]; . == $s)) | not)] as $l
    | if ($l | length) == 0 then $q else $l + order($q - $l) end end;
# Seconds until a service stops: its own quiet time, or its longest-lived dependant.
def left($s): ([$limit - quiet($s)] + [dependants($s)[] | left(.)]) | max;
'

# _ds_idle_jq <limit> <running_json> <program>: run <program> with the rules above.
_ds_idle_jq() {
  local svcs
  svcs=$(cat "$(_ds_idle_dir)/services.json" 2>/dev/null) || return 0
  jq -nr --argjson limit "$1" --argjson running "$2" --argjson now "$(date +%s)" \
    --argjson active "$(_ds_idle_times)" --argjson svcs "$svcs" "$_DS_IDLE_JQ $3"
}

# _ds_idle_plan <limit> <running_json>: the services to stop now, in order.
_ds_idle_plan() { _ds_idle_jq "$1" "$2" 'order(shrink([$running[] | select(quiet(.) >= $limit)])) | .[]'; }

# _ds_idle_infra <running_json>: with idle.stop_infra, stop the containers
# devstack started that no running service lists any more.
_ds_idle_infra() {
  local dir
  dir=$(_ds_idle_dir)
  [ "$(cat "$dir/stop_infra" 2>/dev/null)" = true ] || return 0
  ds_infra_stop_unused "$(jq -r --argjson r "$1" '. as $all | [$r[] | $all[.].infra // [] | .[]] | unique | .[]' "$dir/services.json")"
}

# _ds_idle_sweep <limit>: stop what's been quiet long enough. Returns 0 once
# the whole stack is down, 1 while anything is still running. Skips the round
# while another devstack command holds the lock: that's someone using it.
_ds_idle_sweep() {
  local dir running plan now stamp s stopped="" left containers
  dir=$(_ds_idle_dir); now=$(date +%s)
  running=$(_ds_idle_running_json)
  if [ "$running" = "[]" ]; then
    # The server is up with nothing running in it (each service was stopped
    # by name, or failed). It goes too, after the same quiet time.
    [ -f "$dir/empty_since" ] || echo "$now" > "$dir/empty_since"
    [ $((now - $(cat "$dir/empty_since"))) -ge "$1" ] || return 1
    _ds_try_lock || return 1
    [ "$(_ds_idle_running_json)" = "[]" ] || { rm -f "$dir/empty_since"; _ds_unlock; return 1; }
    _ds_down_all
    containers=$(_ds_idle_infra '[]')
    echo "$(date '+%F %T') stopped the empty server${containers:+ and containers $containers}"
    rm -f "$dir/empty_since"
    _ds_unlock
    return 0
  fi
  rm -f "$dir/empty_since"
  [ -n "$(_ds_idle_plan "$1" "$running")" ] || return 1
  _ds_try_lock || return 1
  # Plan again under the lock: an up or restart may have run since.
  running=$(_ds_idle_running_json)
  plan=$(_ds_idle_plan "$1" "$running")
  [ -n "$plan" ] || { _ds_unlock; return 1; }
  stamp=$(date '+%Y-%m-%d %H:%M')
  if [ "$(jq length <<<"$running")" = "$(grep -c . <<<"$plan")" ]; then
    _ds_down_all
    stopped=$plan; left='[]'
  else
    while IFS= read -r s; do
      _ds_pc process stop "$s" >/dev/null || continue
      _ds_owner_del "$s"
      stopped+="$s"$'\n'
    done <<<"$plan"
    left=$(_ds_idle_running_json)
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    echo "$stamp" > "$dir/stopped.$s"; rm -f "$dir/active.$s" "$dir/size.$s"
  done <<<"$stopped"
  containers=$(_ds_idle_infra "$left")
  echo "$stamp stopped $(tr '\n' ' ' <<<"$stopped")${containers:+then containers $containers}"
  _ds_unlock
  [ "$left" = "[]" ]
}

# cmd_idle_watch: the watchdog loop (devstack idle-watch; up starts it).
# DEVSTACK_IDLE_TICK sets the seconds between checks (default 60).
cmd_idle_watch() {
  local dir tick limit now s
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
    now=$(date +%s)
    for s in $(_ds_idle_active "$(_ds_idle_running_json)"); do echo "$now" > "$dir/active.$s"; done
    _ds_idle_sweep "$limit" && exit 0
  done
}

# _ds_idle_status <running: 0|1>: status's last lines.
_ds_idle_status() {
  local dir limit f stopped="" running
  dir=$(_ds_idle_dir)
  for f in "$dir"/stopped.*; do
    [ -f "$f" ] && stopped+="${stopped:+, }${f##*/stopped.} ($(cut -d' ' -f2 "$f"))"
  done
  [ -n "$stopped" ] && echo "stopped while idle: $stopped"
  [ "$1" = 1 ] || return 0
  limit=$(cat "$dir/limit" 2>/dev/null)
  if [ "${limit:-0}" -le 0 ] 2>/dev/null; then echo "idle shutdown: off"; return 0; fi
  if ! _ds_idle_running; then echo "idle shutdown: the watchdog isn't running (the next devstack up starts it)"; return 0; fi
  running=$(_ds_idle_running_json)
  [ "$running" != "[]" ] || return 0
  echo "idle stop in: $(_ds_idle_jq "$limit" "$running" '[$running[] | {s: ., l: ([left(.), 0] | max)}] | sort_by(.l, .s) | .[] | "\(.s)\t\(.l)"' \
    | while IFS=$'\t' read -r s l; do printf '%s %s, ' "$s" "$(_ds_dur "$l")"; done | sed 's/, $//')"
}
