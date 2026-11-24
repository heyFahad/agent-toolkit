#!/bin/bash
# Docker containers a service relies on. devstack only ever starts a stopped
# container; it never creates, recreates or removes one. The one exception to
# "never stops one": with the registry's idle.stop_infra, the idle watchdog
# stops the containers devstack itself started once no running service uses them.
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

# ds_infra_ensure <container...>
ds_infra_ensure() {
  [ $# -gt 0 ] || return 0
  command -v docker >/dev/null 2>&1 || ds_die 3 "docker is missing (needed for: $*): install Docker Desktop"
  docker info >/dev/null 2>&1 || ds_die 1 "Docker isn't running (needed for: $*)"
  local c state
  for c in "$@"; do
    state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) \
      || ds_die 1 "container $c doesn't exist (devstack never creates containers)"
    if [ "$state" != true ]; then
      docker start "$c" >/dev/null 2>&1 || ds_die 1 "couldn't start container $c"
      state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)
      [ "$state" = true ] || ds_die 1 "container $c didn't stay running"
      echo "started container $c" >&2
      echo "$c" >> "$(ds_state_dir)/infra-started"
    fi
    _ds_infra_hint "$c"
  done
}

# _ds_infra_hint <container>: once per state folder, say when a MongoDB
# container has no WiredTiger cache cap. MongoDB then sizes its cache to about
# half of the Docker VM's memory (3.6 GB of a 7.8 GB VM has been seen).
_ds_infra_hint() {
  local mark info
  mark="$(ds_state_dir)/infra-hinted"
  grep -qxF "$1" "$mark" 2>/dev/null && return 0
  info=$(docker inspect -f '{{.Config.Image}}|{{join .Config.Cmd " "}} {{join .Config.Entrypoint " "}}' "$1" 2>/dev/null) || return 0
  case ${info%%|*} in *mongo*) ;; *) return 0 ;; esac
  case $info in *wiredTigerCacheSizeGB*) return 0 ;; esac
  echo "devstack: container $1 runs MongoDB without a cache cap, so it can take about half of Docker's memory; recreate it with --wiredTigerCacheSizeGB 1 (devstack never recreates containers)" >&2
  echo "$1" >> "$mark"
}

# ds_infra_stop_unused <used>: stop each container devstack started that isn't
# in <used> (one name per line), and print their names. Only the idle watchdog
# calls it, and only with idle.stop_infra.
ds_infra_stop_unused() {
  local f c out="" keep=""
  f="$(ds_state_dir)/infra-started"
  [ -f "$f" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  for c in $(sort -u "$f"); do
    if grep -qxF "$c" <<<"$1"; then keep+="$c"$'\n'
    elif docker stop "$c" >/dev/null 2>&1; then out="$out $c"
    else keep+="$c"$'\n'; fi
  done
  printf '%s' "$keep" > "$f"
  echo "${out# }"
}
