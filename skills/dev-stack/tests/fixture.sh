#!/bin/bash
# Stubbed process-compose, docker and lsof plus a fixture workspace, shared by
# the tests that run devstack commands (no real servers start). Source it
# after helpers.sh.
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
    [ -f "$PCS/list-fails" ] && { echo "[]"; exit 1; }
    [ -f "$PCS/list-object" ] && { echo "{}"; exit 0; }
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
# --- stub docker: STUB_DOCKER_DOWN=1, STUB_CONTAINERS="redis:true mongodb:false",
# STUB_IMAGES="mongodb=mongo:7|--bind_ip_all" (image|command per container) ---
stub_bin docker '
case "$1" in
  info) [ -z "${STUB_DOCKER_DOWN:-}" ] ;;
  inspect)
    n=${!#}
    if [[ " $* " == *Image* ]]; then
      for e in ${STUB_IMAGES:-}; do [ "${e%%=*}" = "$n" ] && { echo "${e#*=}" | tr , " "; exit 0; }; done
      echo "$n:latest|"; exit 0
    fi
    for c in ${STUB_CONTAINERS:-}; do
      [ "${c%%:*}" = "$n" ] || continue
      if [ -f "$PCS/docker-started.$n" ]; then echo true; else echo "${c#*:}"; fi; exit 0
    done; exit 1 ;;
  start) touch "$PCS/docker-started.$2"; echo "$2" ;;
  *) exit 1 ;;
esac'
# --- stub lsof: STUB_LSOF="3010:node:4242" holds a port; a port listed in
# $PCS/established has a browser connected; one in $PCS/probe has
# process-compose'"'"'s readiness probe connected ---
stub_bin lsof '
if [[ " $* " == *ESTABLISHED* ]]; then
  [ -f "$PCS/slow-lsof" ] && sleep 4
  for p in $(cat "$PCS/established" 2>/dev/null); do
    printf "p1\ncbrowser\nf20\nn127.0.0.1:5%s->127.0.0.1:%s\n" "$p" "$p"
  done
  for p in $(cat "$PCS/probe" 2>/dev/null); do
    printf "p2\ncprocess-compose\nf9\nn127.0.0.1:6%s->127.0.0.1:%s\n" "$p" "$p"
    printf "p3\ncnode\nf11\nn[::ffff:127.0.0.1]:%s->[::ffff:127.0.0.1]:6%s\n" "$p" "$p"
  done
  exit 0
fi
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
export STUB_IMAGES="mongodb=mongo:7|mongod,--wiredTigerCacheSizeGB,1"
ds() { (cd "$TMP/ws" && bash "$DEVSTACK" "$@"); }
starts() { grep -c "process start" "$TMP/calls.log"; }
line_of() { grep -n "process start $1" "$TMP/calls.log" | head -1 | cut -d: -f1; }
