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
_ds_alive() { _ds_pc project state >/dev/null; }
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
  process-compose up -D -U -u "$DS_SOCK" -f "$cfg" --keep-project -L "$state/process-compose.log" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do _ds_alive && return 0; sleep 0.5; done
  ds_die 1 "process-compose didn't start; see $state/process-compose.log"
}

# --- registry -----------------------------------------------------------------

# ds_load_registry: validate the registry into $STATE/registry.json (with _root).
ds_load_registry() {
  local reg state json
  reg=$(ds_find_registry) || exit $?
  state=$(ds_state_dir); mkdir -p "$state/logs"
  json=$(ds_registry_json "$reg") || exit $?
  jq --arg r "$(ds_registry_root "$reg")" '. + {_root: $r}' <<<"$json" > "$state/registry.json"
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
  { grep -iE 'error|exception|fatal|ERR!' "$log" || cat "$log"; } | tail -20 | sed 's/^/  /'
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
        _ds_line "$svc" "${status:-Stopped}" ""; _ds_error_lines "$svc"; failed=1; break
      fi
      if [ "$now" -ge "$deadline" ]; then
        _ds_line "$svc" "NotReady" ""; _ds_error_lines "$svc"; failed=1; break
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
  _ds_up "$takeover" "$with" "${froms[@]+"${froms[@]}"}" -- "${names[@]}"
}

# _ds_up <takeover> <with_csv> <from...> -- <name...>
_ds_up() {
  local takeover=$1 with=$2 froms=() names=() svcs svc dir from ps running ready owner f infra=() todo=() holder
  shift 2
  while [ "$1" != -- ]; do froms+=("$1"); shift; done; shift
  names=("$@")
  svcs=$(ds_resolve "$DS_REG" "$with" "${names[@]}") || exit $?

  # Each --from must name a service this run starts.
  for f in "${froms[@]+"${froms[@]}"}"; do
    [[ $f == *=* ]] || ds_die 2 "--from needs <svc>=<path>, got $f"
    grep -qx "${f%%=*}" <<<"$svcs" || ds_die 2 "--from names ${f%%=*}, which this run doesn't start"
  done
  _from_of() { local f; for f in "${froms[@]+"${froms[@]}"}"; do [ "${f%%=*}" = "$1" ] && { _ds_abs "${f#*=}"; return; }; done; }

  ps=$(_ds_ps)
  # Pass 1: decide each service's directory; refuse before changing anything.
  local plan=""
  while IFS= read -r svc; do
    from=$(_from_of "$svc"); owner=$(ds_owner_get "$svc"); running=$(_ds_proc "$ps" "$svc" is_running)
    dir=${from:-${owner:-$(_ds_main_dir "$svc")}}
    [ "$running" = true ] || owner=""
    if [ -n "$owner" ] && [ "$owner" != "$dir" ] && [ "$takeover" != 1 ]; then
      ds_die 2 "$svc is running from $owner; rerun with --takeover to switch it to $dir"
    fi
    ds_command "$DS_REG" "$svc" "$dir" >/dev/null || exit $?
    plan+="$svc=$dir"$'\n'
  done <<<"$svcs"

  # Pass 2: record owners, copy local files, collect infra and what to start.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    svc=${line%%=*}; dir=${line#*=}
    owner=$(ds_owner_get "$svc"); running=$(_ds_proc "$ps" "$svc" is_running); ready=$(_ds_proc "$ps" "$svc" is_ready)
    ds_owner_set "$svc" "$dir"
    ds_copy_local_files "$DS_REG" "$svc" "$dir" >&2
    while IFS= read -r a; do [ -n "$a" ] && infra+=("$a"); done < <(_ds_field "$svc" '.infra[]?')
    if [ "$running" = true ] && [ "$owner" = "$dir" ]; then continue; fi
    if [ "$running" != true ] && holder=$(_ds_port_holder "$(_ds_field "$svc" .port)"); then
      ds_die 1 "port $(_ds_field "$svc" .port) for $svc is held by $holder"
    fi
    todo+=("$svc")
  done <<<"$plan"

  if [ ${#infra[@]} -gt 0 ]; then
    # shellcheck disable=SC2046 # one word per container name
    ds_infra_ensure $(printf '%s\n' "${infra[@]}" | sort -u) || exit $?
  fi
  ds_pc_config "$DS_REG" "$(ds_state_dir)"
  _ds_server_ensure
  for svc in "${todo[@]+"${todo[@]}"}"; do
    _ds_pc process start "$svc" >/dev/null || ds_die 1 "process-compose couldn't start $svc"
  done
  # shellcheck disable=SC2086 # one word per service
  _ds_wait $svcs || exit 1
}

cmd_status() {
  local json=0
  [ "${1:-}" = --json ] && json=1
  ds_load_registry
  local ps
  ps=$(_ds_ps)
  jq -c --slurpfile reg "$DS_REG" --slurpfile own <(cat "$(ds_state_dir)/owners.json" 2>/dev/null || echo '{}') '
    map(select(.status != "Disabled"))
    | map({name, status, ready: .is_ready, port: $reg[0].services[.name].port,
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
  local log
  log="$(ds_state_dir)/logs/$svc.log"
  [ -f "$log" ] || ds_die 2 "no log for $svc yet ($log)"
  if [ $errors = 1 ]; then grep -iE 'error|exception|fatal|ERR!' "$log" | tail -n "$tail"
  else tail -n "$tail" "$log"; fi
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
  ds_load_registry
  if [ -n "$from" ]; then
    _ds_up "$takeover" "" "$svc=$from" -- "$svc"
    return
  fi
  _ds_alive || ds_die 1 "$svc isn't running; use devstack up $svc"
  _ds_pc process restart "$svc" >/dev/null || ds_die 1 "process-compose couldn't restart $svc"
  _ds_wait "$svc" || exit 1
}

cmd_down() {
  ds_load_registry
  local f svc
  f="$(ds_state_dir)/owners.json"
  if [ $# -eq 0 ]; then
    _ds_alive && _ds_pc down >/dev/null
    rm -f "$DS_SOCK"; echo '{}' > "$f"
    echo "stopped everything (Docker containers left running)"
    return
  fi
  for svc in "$@"; do
    _ds_alive && _ds_pc process stop "$svc" >/dev/null
    [ -f "$f" ] && jq --arg s "$svc" 'del(.[$s])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "stopped $svc"
  done
}

cmd_urls() {
  ds_load_registry
  local ps
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
