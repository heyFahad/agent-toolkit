#!/bin/bash
# The commands: up, status, logs, restart, down, urls, attach.
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=registry.sh
. "$DS_LIB/registry.sh"
# shellcheck source=resolve.sh
. "$DS_LIB/resolve.sh"
# shellcheck source=build.sh
. "$DS_LIB/build.sh"
# shellcheck source=state.sh
. "$DS_LIB/state.sh"
# shellcheck source=infra.sh
. "$DS_LIB/infra.sh"

# --- process-compose plumbing ---------------------------------------------

_ds_sock() {
  local s
  s="$(ds_state_dir)/pc.sock"
  # macOS caps unix socket paths at 104 bytes.
  [ ${#s} -le 100 ] || ds_die 2 "socket path too long (${#s} > 100): set DEVSTACK_STATE_DIR to a shorter path"
  echo "$s"
}
_ds_pc() { process-compose "$@" -U -u "$DS_SOCK" 2>/dev/null; }
_ds_alive() {
  local out
  out=$(process-compose project state -U -u "$DS_SOCK" 2>&1) && return 0
  # A sandbox (Codex's, say) that blocks the socket isn't "nothing running".
  if grep -q "operation not permitted" <<<"$out"; then
    ds_die 1 "can't reach the devstack server at $DS_SOCK: this sandbox blocks the connection. Allow network access and writes to $(ds_state_dir) (in Codex: sandbox_workspace_write.network_access = true and writable_roots)"
  fi
  return 1
}
# _ds_reach: run in the main shell (not inside $(...)) so a blocked socket
# ends the command with exit 1 instead of reading as "nothing running".
_ds_reach() { _ds_alive >/dev/null || true; }
_ds_ps() { if _ds_alive; then _ds_pc process list -o json; else echo '[]'; fi; }

# _ds_server_ensure: apply the generated config to the running server, or start one.
_ds_server_ensure() {
  local state cfg
  state=$(ds_state_dir); cfg="$state/process-compose.yaml"
  if _ds_alive; then
    _ds_pc project update -f "$cfg" >/dev/null || ds_die 1 "process-compose rejected the new config ($cfg)"
    return
  fi
  rm -f "$DS_SOCK"
  # Services inherit the server's environment: drop what would silently change
  # them (a stray PORT, NODE_OPTIONS=--inspect, NODE_ENV) from the caller's shell.
  env -u PORT -u NODE_OPTIONS -u NODE_ENV \
    process-compose up -D -U -u "$DS_SOCK" -f "$cfg" --keep-project -L "$state/process-compose.log" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do _ds_alive && return 0; sleep 0.5; done
  ds_die 1 "process-compose didn't start; see $state/process-compose.log"
}

# --- one command at a time ------------------------------------------------------
# bash 3.2 and macOS have no flock, so the lock is a directory with a pid file.

_ds_lock() {
  local lock waited=0 holder max=${DEVSTACK_LOCK_WAIT:-300}
  lock="$(ds_state_dir)/lock"; mkdir -p "$(ds_state_dir)"
  until mkdir "$lock" 2>/dev/null; do
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock"; continue   # its owner died: stale
    fi
    [ "$waited" -eq 0 ] && echo "devstack: waiting for another devstack command (pid ${holder:-?})" >&2
    [ "$waited" -ge "$max" ] && ds_die 1 "another devstack command is still running (pid ${holder:-?}); try again later"
    sleep 1; waited=$((waited + 1))
  done
  echo $$ > "$lock/pid"
  trap '_ds_unlock' EXIT
}
_ds_unlock() { local lock; lock="$(ds_state_dir)/lock"; [ "$(cat "$lock/pid" 2>/dev/null)" = $$ ] && rm -rf "$lock"; }

# _ds_check_name <svc>: a plain service name (it becomes a file name).
_ds_check_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]*$ ]] || ds_die 2 "not a service name: $1"; }

# --- registry -----------------------------------------------------------------

# ds_load_registry: validate the registry into $STATE/registry.json (with _root).
ds_load_registry() {
  local reg state json
  reg=$(ds_find_registry) || exit $?
  state=$(ds_state_dir); mkdir -p "$state/logs"
  json=$(ds_registry_json "$reg") || exit $?
  # Written atomically: another session's `up` may be reading it right now.
  local tmp
  tmp=$(mktemp "$state/registry.json.XXXXXX")
  jq --arg r "$(ds_registry_root "$reg")" '. + {_root: $r}' <<<"$json" > "$tmp" && mv "$tmp" "$state/registry.json"
  DS_REG="$state/registry.json"
  DS_SOCK=$(_ds_sock) || exit $?
}

_ds_field() { jq -r --arg s "$1" ".services[\$s]$2 // empty" "$DS_REG"; }
_ds_main_dir() { jq -r --arg s "$1" '._root + "/" + .services[$s].repo' "$DS_REG"; }
_ds_abs() { (cd "$1" 2>/dev/null && pwd -P) || ds_die 2 "no such directory: $1"; }

# _ds_proc <ps_json> <svc> <field>
_ds_proc() { jq -r --arg s "$2" "map(select(.name == \$s))[0].$3 // empty" <<<"$1"; }

_ds_port_holder() { # <port>: "<command> (pid <pid>)" of the listener, if any
  local out pid cmd
  out=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null) || return 1
  pid=$(sed -n 's/^p//p' <<<"$out" | head -1); cmd=$(sed -n 's/^c//p' <<<"$out" | head -1)
  [ -n "$pid" ] || return 1
  echo "$cmd (pid $pid)"
}

_ds_error_lines() { # <svc>: up to 20 error-looking lines of its log
  local log
  log="$(ds_state_dir)/logs/$1.log"
  [ -f "$log" ] || { echo "  (no log yet: $log)"; return; }
  { grep -iE 'error|exception|fatal|ERR!' "$log" || cat "$log"; } | _ds_plain | tail -20 | sed 's/^/  /'
}

# _ds_crashed <svc>: nodemon reported a crash and is waiting for file changes.
# Only the latest nodemon state counts: a crash that nodemon has since restarted
# from ("restarting due to changes", "starting") is history, not a crash.
_ds_crashed() {
  grep -E '\[nodemon\] (app crashed|restarting|starting)' "$(ds_state_dir)/logs/$1.log" 2>/dev/null \
    | tail -1 | grep -q 'app crashed'
}

# Strip colour codes and cap each line at 300 characters: one minified line
# mustn't flood an agent. `logs --tail N` reads more when it's needed.
_ds_plain() { sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' | cut -c1-300; }

# _ds_health_hint <svc>: one line on what the health check sees right now.
_ds_health_hint() {
  local h code port
  h=$(_ds_field "$1" .health); port=$(_ds_field "$1" .port)
  if [ "$h" = tcp ]; then
    nc -z localhost "$port" 2>/dev/null && echo "  port $port accepts connections" || echo "  port $port isn't accepting connections"
    return
  fi
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$h" 2>/dev/null)
  if [ -z "$code" ] || [ "$code" = 000 ]; then echo "  health check $h didn't answer"
  else echo "  health check $h answered $code"; fi
}

_ds_line() { # <svc> <state> <dir|""> : one output line
  local port
  port=$(_ds_field "$1" .port)
  printf '%-16s %-5s %-10s %s%s\n' "$1" "$port" "$2" "http://localhost:$port" "${3:+  $3}"
}

# _ds_wait <svc...>: wait for each to be Ready; print a line each; 1 if any failed.
_ds_wait() {
  local svc ps ready status running deadline failed=0 now t
  for svc in "$@"; do
    t=$(_ds_field "$svc" .timeout); deadline=$(( $(date +%s) + ${t:-120} ))
    while :; do
      ps=$(_ds_ps)
      ready=$(_ds_proc "$ps" "$svc" is_ready); status=$(_ds_proc "$ps" "$svc" status)
      running=$(_ds_proc "$ps" "$svc" is_running)
      [ "$ready" = Ready ] && { _ds_line "$svc" Ready ""; break; }
      now=$(date +%s)
      if [ "$running" != true ] && [ "$status" != Pending ] && [ "$status" != Launching ] && [ "$status" != Restarting ]; then
        _ds_line "$svc" "${status:-Stopped}" ""; _ds_error_lines "$svc"; _ds_health_hint "$svc"; failed=1; break
      fi
      # nodemon keeps a crashed app's process alive ("waiting for file changes"),
      # so the process never exits: read the log to fail now, not at the timeout.
      if _ds_crashed "$svc"; then
        _ds_line "$svc" Crashed ""; _ds_error_lines "$svc"; failed=1; break
      fi
      if [ "$now" -ge "$deadline" ]; then
        _ds_line "$svc" "NotReady" ""; _ds_error_lines "$svc"; _ds_health_hint "$svc"; failed=1; break
      fi
      sleep 1
    done
  done
  return $failed
}

# --- commands -----------------------------------------------------------------

cmd_up() {
  local names=() froms=() with="" takeover=0 a
  while [ $# -gt 0 ]; do
    case $1 in
      --from) [ $# -ge 2 ] || ds_die 2 "--from needs <svc>=<path>"; froms+=("$2"); shift 2 ;;
      --from=*) froms+=("${1#--from=}"); shift ;;
      --with) [ $# -ge 2 ] || ds_die 2 "--with needs a service"; with="$with,$2"; shift 2 ;;
      --takeover) takeover=1; shift ;;
      -*) ds_die 2 "up: unknown option $1" ;;
      *) names+=("$1"); shift ;;
    esac
  done
  [ ${#names[@]} -gt 0 ] || ds_die 2 "up: name a target or service"
  ds_load_registry
  _ds_lock
  _ds_up "$takeover" "$with" "${froms[@]+"${froms[@]}"}" -- "${names[@]}"
}

# _ds_up <takeover> <with_csv> <from...> -- <name...>
_ds_up() {
  local takeover=$1 with=$2 froms=() names=() svcs svc dir from ps running owner f infra=() holder a
  shift 2
  while [ "$1" != -- ]; do froms+=("$1"); shift; done; shift
  names=("$@")
  svcs=$(ds_resolve "$DS_REG" "$with" "${names[@]}") || exit $?

  # Each --from must name a service this run starts.
  for f in "${froms[@]+"${froms[@]}"}"; do
    [[ $f == *=* ]] || ds_die 2 "--from needs <svc>=<path>, got $f"
    grep -qFx "${f%%=*}" <<<"$svcs" || ds_die 2 "--from names ${f%%=*}, which this run doesn't start"
  done
  _from_of() { local f; for f in "${froms[@]+"${froms[@]}"}"; do [ "${f%%=*}" = "$1" ] && { _ds_abs "${f#*=}"; return; }; done; return 0; }

  _ds_reach
  ps=$(_ds_ps)
  # Pass 1: decide each service's directory; refuse before changing anything.
  local plan=""
  while IFS= read -r svc; do
    from=$(_from_of "$svc") || exit $?
    owner=$(ds_owner_get "$svc"); running=$(_ds_proc "$ps" "$svc" is_running)
    # An owner only counts while its service runs; a stopped one goes back to main.
    [ "$running" = true ] || owner=""
    dir=${from:-${owner:-$(_ds_main_dir "$svc")}}
    if [ -n "$owner" ] && [ "$owner" != "$dir" ] && [ "$takeover" != 1 ]; then
      ds_die 2 "$svc is running from $owner; rerun with --takeover to switch it to $dir"
    fi
    ds_command "$DS_REG" "$svc" "$dir" >/dev/null || exit $?
    # Some services can't share a folder (Next.js allows one dev server per project).
    local c cdir
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      cdir=$(sed -n "s|^$c=||p" <<<"$plan")
      if [ -z "$cdir" ] && [ "$(_ds_proc "$ps" "$c" is_running)" = true ]; then
        cdir=$(ds_owner_get "$c"); cdir=${cdir:-$(_ds_main_dir "$c")}
      fi
      if [ -n "$cdir" ] && [ "$cdir" = "$dir" ]; then
        ds_die 2 "$svc can't run while $c runs from the same folder ($dir): stop it with devstack down $c, or run $svc from another worktree with --from $svc=<path>"
      fi
    done < <({ _ds_field "$svc" '.conflicts_with[]?'
               jq -r --arg s "$svc" '.services | to_entries[] | select((.value.conflicts_with // []) | index($s)) | .key' "$DS_REG"; } | sort -u)
    plan+="$svc=$dir"$'\n'
  done <<<"$svcs"

  # Pass 2: checks that can still fail (ports, Docker). Nothing is recorded yet.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    svc=${line%%=*}
    while IFS= read -r a; do [ -n "$a" ] && infra+=("$a"); done < <(_ds_field "$svc" '.infra[]?')
    running=$(_ds_proc "$ps" "$svc" is_running)
    if [ "$running" != true ] && holder=$(_ds_port_holder "$(_ds_field "$svc" .port)"); then
      ds_die 1 "port $(_ds_field "$svc" .port) for $svc is held by $holder"
    fi
  done <<<"$plan"
  if [ ${#infra[@]} -gt 0 ]; then
    # shellcheck disable=SC2046 # one word per container name
    ds_infra_ensure $(printf '%s\n' "${infra[@]}" | sort -u) || exit $?
  fi

  # Pass 3: record owners (dropping those of services that aren't running) and
  # bring local files over.
  local f_own keep
  f_own="$(ds_state_dir)/owners.json"
  keep=$(jq -c '[.[] | select(.is_running == true) | .name]' <<<"$ps")
  if [ -f "$f_own" ]; then
    jq --argjson keep "$keep" 'with_entries(select(.key as $k | $keep | index($k)))' "$f_own" > "$f_own.tmp" && mv "$f_own.tmp" "$f_own"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    svc=${line%%=*}; dir=${line#*=}
    ds_owner_set "$svc" "$dir"
    ds_copy_local_files "$DS_REG" "$svc" "$dir" >&2
  done <<<"$plan"
  # Everything running before the update, so a service outside this run that
  # the update stops (its definition changed) is brought back as well.
  local before
  before=$(jq -r '.[] | select(.is_running == true) | .name' <<<"$ps")
  ds_pc_config "$DS_REG" "$(ds_state_dir)"
  _ds_server_ensure
  ps=$(_ds_ps)
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    if [ "$(_ds_proc "$ps" "$svc" is_running)" = true ]; then
      # nodemon keeps a crashed app's process alive: restart it, so a fix (a
      # Doppler key, say) is picked up by just running up again.
      [ "$(_ds_proc "$ps" "$svc" is_ready)" = Ready ] && continue
      _ds_crashed "$svc" || continue
      : > "$(ds_state_dir)/logs/$svc.log"
      _ds_pc process restart "$svc" >/dev/null || ds_die 1 "process-compose couldn't restart $svc"
      continue
    fi
    : > "$(ds_state_dir)/logs/$svc.log"   # a fresh log per start: old crashes mustn't count
    _ds_pc process start "$svc" >/dev/null || ds_die 1 "process-compose couldn't start $svc"
    grep -qFx "$svc" <<<"$svcs" || echo "restarted $svc (its registry entry changed)" >&2
  done < <(printf '%s\n%s\n' "$svcs" "$before" | awk 'NF && !seen[$0]++')
  # shellcheck disable=SC2086 # one word per service
  _ds_wait $svcs || exit 1
}

cmd_status() {
  local json=0
  [ "${1:-}" = --json ] && json=1
  ds_load_registry
  local ps n crashed='[]'
  _ds_reach
  ps=$(_ds_ps)
  while IFS= read -r n; do
    [ -n "$n" ] && _ds_crashed "$n" && crashed=$(jq -c --arg n "$n" '. + [$n]' <<<"$crashed")
  done < <(jq -r '.[] | select(.is_ready != "Ready" and .is_running == true) | .name' <<<"$ps")
  jq -c --slurpfile reg "$DS_REG" --argjson crashed "$crashed" --slurpfile own <(cat "$(ds_state_dir)/owners.json" 2>/dev/null || echo '{}') '
    map(select(.status != "Disabled"))
    | map({name, status: (if (.name as $n | $crashed | index($n)) then "Crashed"
                          elif (.is_running != true and .status == "Completed") then "Stopped" else .status end),
           ready: .is_ready, port: $reg[0].services[.name].port,
           dir: ($own[0][.name] // ($reg[0]._root + "/" + $reg[0].services[.name].repo))})' <<<"$ps" > "$(ds_state_dir)/status.json"
  if [ $json = 1 ]; then cat "$(ds_state_dir)/status.json"; return; fi
  if [ "$(jq length "$(ds_state_dir)/status.json")" = 0 ]; then echo "nothing running"; return; fi
  jq -r '.[] | [.name, (.port|tostring), (if .ready == "Ready" then "Ready" else .status end), .dir] | @tsv' "$(ds_state_dir)/status.json" \
    | while IFS=$'\t' read -r n p s d; do printf '%-16s %-5s %-10s %s\n' "$n" "$p" "$s" "$d"; done
}

cmd_logs() {
  local svc="" errors=0 tail=30
  while [ $# -gt 0 ]; do
    case $1 in
      --errors) errors=1; shift ;;
      --tail) tail=${2:?--tail needs a number}; shift 2 ;;
      -*) ds_die 2 "logs: unknown option $1" ;;
      *) svc=$1; shift ;;
    esac
  done
  [ -n "$svc" ] || ds_die 2 "logs: name a service"
  _ds_check_name "$svc"
  local log
  log="$(ds_state_dir)/logs/$svc.log"
  [ -f "$log" ] || ds_die 2 "no log for $svc yet ($log)"
  if [ $errors = 1 ]; then grep -iE 'error|exception|fatal|ERR!' "$log" | _ds_plain | tail -n "$tail"
  else tail -n "$tail" "$log" | _ds_plain; fi
}

cmd_restart() {
  local svc="" from="" takeover=0
  while [ $# -gt 0 ]; do
    case $1 in
      --from) from=${2:?--from needs a path}; shift 2 ;;
      --takeover) takeover=1; shift ;;
      -*) ds_die 2 "restart: unknown option $1" ;;
      *) svc=$1; shift ;;
    esac
  done
  [ -n "$svc" ] || ds_die 2 "restart: name a service"
  _ds_check_name "$svc"
  ds_load_registry
  [ -n "$(_ds_field "$svc" .port)" ] || ds_die 2 "unknown service: $svc"
  _ds_lock
  local ps abs
  ps=$(_ds_ps)
  if [ -n "$from" ]; then
    abs=$(_ds_abs "$from") || exit $?
    # Switching folders (or starting a stopped service) goes through up; the
    # same folder falls through to a plain restart below.
    if [ "$(_ds_proc "$ps" "$svc" is_running)" != true ] || [ "$(ds_owner_get "$svc")" != "$abs" ]; then
      _ds_up "$takeover" "" "$svc=$abs" -- "$svc"
      return
    fi
  fi
  [ "$(_ds_proc "$ps" "$svc" is_running)" = true ] || ds_die 1 "$svc isn't running; use devstack up $svc"
  : > "$(ds_state_dir)/logs/$svc.log"
  _ds_pc process restart "$svc" >/dev/null || ds_die 1 "process-compose couldn't restart $svc"
  _ds_wait "$svc" || exit 1
}

cmd_down() {
  DS_SOCK=$(_ds_sock) || exit $?
  local f svc ps
  for svc in "$@"; do _ds_check_name "$svc"; done
  _ds_lock
  _ds_reach
  f="$(ds_state_dir)/owners.json"
  if [ $# -eq 0 ]; then
    if _ds_alive; then
      _ds_pc down >/dev/null || ds_die 1 "process-compose down failed; the stack may still be running (check devstack status)"
    fi
    rm -f "$DS_SOCK"; echo '{}' > "$f"
    echo "stopped everything (Docker containers left running)"
    return
  fi
  ps=$(_ds_ps)
  for svc in "$@"; do
    jq -e --arg s "$svc" 'map(.name) | index($s)' <<<"$ps" >/dev/null || ds_die 2 "unknown service: $svc (not in the running stack)"
  done
  for svc in "$@"; do
    _ds_pc process stop "$svc" >/dev/null || ds_die 1 "process-compose couldn't stop $svc"
    [ -f "$f" ] && jq --arg s "$svc" 'del(.[$s])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "stopped $svc"
  done
}

cmd_urls() {
  ds_load_registry
  local ps
  _ds_reach
  ps=$(_ds_ps)
  jq -r --slurpfile reg "$DS_REG" '
    map(select(.is_running == true)) | map($reg[0].services[.name].port as $p | {name, p: ($p|tostring)})
    | sort_by(.p) | .[]
    | if (.p|startswith("5")) then "web     \(.name): http://localhost:\(.p)"
      elif (.p|startswith("8")) then "mobile  \(.name): Metro on \(.p) (open the app in the Simulator)"
      elif (.p|startswith("6")) then "docs    \(.name): http://localhost:\(.p)"
      else "API     \(.name): http://localhost:\(.p)" end' <<<"$ps"
}

cmd_attach() {
  DS_SOCK=$(_ds_sock) || exit $?
  _ds_alive || ds_die 1 "nothing is running; start something with devstack up"
  exec process-compose attach -U -u "$DS_SOCK"
}

# ports [--markdown | --write <file>]: the registry's port table.
cmd_ports() {
  ds_load_registry
  case ${1:-} in
    "") jq -r '.services | to_entries | sort_by(.value.port)[] | "\(.value.port)\t\(.key)\t\(.value.repo)"' "$DS_REG" \
          | while IFS=$'\t' read -r p n r; do printf '%-5s %-16s %s\n' "$p" "$n" "$r"; done ;;
    --markdown) _ds_ports_md ;;
    --write)
      local f=${2:?--write needs a file} table tmp
      grep -q '<!-- devstack:ports:start -->' "$f" && grep -q '<!-- devstack:ports:end -->' "$f" \
        || ds_die 2 "$f has no <!-- devstack:ports:start --> / <!-- devstack:ports:end --> markers"
      table=$(_ds_ports_md); tmp=$(mktemp)
      DS_TABLE="$table" awk '
        /<!-- devstack:ports:start -->/ { print; print ""; print ENVIRON["DS_TABLE"]; print ""; skip = 1; next }
        /<!-- devstack:ports:end -->/ { skip = 0 }
        !skip { print }' "$f" > "$tmp" && mv "$tmp" "$f"
      echo "updated the port table in $f" ;;
    *) ds_die 2 "ports: unknown option $1" ;;
  esac
}

_ds_ports_md() {
  echo '| Port | Service | Repo | Notes |'
  echo '|---|---|---|---|'
  jq -r '.services | to_entries | sort_by(.value.port)[]
    | "| `\(.value.port)` | \(.value.label // .key) | `\(.value.repo)` | \(.value.notes // "") |"' "$DS_REG"
}
