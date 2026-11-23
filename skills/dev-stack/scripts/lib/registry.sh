#!/bin/bash
# Prerequisite checks, registry lookup and registry validation.
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

# ds_require_tools: exit 3 with an install line for each missing tool.
ds_require_tools() {
  local missing=() t
  for t in jq yq process-compose; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  for t in "${missing[@]}"; do
    case $t in
      process-compose) echo "devstack: process-compose is missing: brew install f1bonacc1/tap/process-compose" >&2 ;;
      *) echo "devstack: $t is missing: brew install $t" >&2 ;;
    esac
  done
  exit 3
}

# ds_find_registry: $DEVSTACK_REGISTRY, else the nearest stack.yaml above $PWD.
ds_find_registry() {
  if [ -n "${DEVSTACK_REGISTRY:-}" ]; then
    [ -f "$DEVSTACK_REGISTRY" ] || ds_die 2 "DEVSTACK_REGISTRY points at a missing file: $DEVSTACK_REGISTRY"
    echo "$DEVSTACK_REGISTRY"
    return
  fi
  local d
  d=$(pwd -P)
  while :; do
    [ -f "$d/stack.yaml" ] && { echo "$d/stack.yaml"; return; }
    [ "$d" = / ] && break
    d=$(dirname "$d")
  done
  ds_die 2 "no stack.yaml found (set DEVSTACK_REGISTRY)"
}

ds_registry_root() { (cd "$(dirname "$1")" && pwd -P); }

# Prints one "<service>: <field>: <problem>" line per problem.
# shellcheck disable=SC2016 # a jq program, not shell
_DS_VALIDATE='
def problems($n; $s):
  (if ($s.repo | type) != "string" then "\($n): repo: required string" else empty end),
  (if ($s.node | type) != "string" or (($s.node != "nvmrc") and ($s.node | test("^v?[0-9]+(\\.[0-9]+){0,2}$") | not))
     then "\($n): node: must be nvmrc or a version" else empty end),
  (if $s.doppler == "none" then empty
   elif ($s.doppler | type) == "object" and ($s.doppler.project | type) == "string" and ($s.doppler.config | type) == "string" then empty
   else "\($n): doppler: must be none or {project, config}" end),
  (if ($s.command | type) != "string" then "\($n): command: required string" else empty end),
  (if ($s.port | type) != "number" or $s.port < 1 or $s.port > 65535 or ($s.port | floor) != $s.port
     then "\($n): port: must be a number from 1 to 65535" else empty end),
  (if $s.health == "tcp" or (($s.health | type) == "string" and ($s.health | startswith("http://"))) then empty
   else "\($n): health: must be tcp or an http:// URL" end),
  ($s | to_entries[] | select(.key as $k | ["depends_on","optional_deps","infra","local_files","conflicts_with"] | index($k))
     | select((.value | type) != "array") | "\($n): \(.key): must be a list"),
  (if ($s.env // {} | type) != "object" then "\($n): env: must be a map" else empty end),
  (if ($s.timeout // 120 | type) != "number" then "\($n): timeout: must be seconds" else empty end);
if (.services | type) != "object" then "registry: services: required map"
else (.services | to_entries[] | problems(.key; .value)),
     (.services | keys[] | select(test("^[a-z0-9][a-z0-9-]*$") | not)
       | "\(.): name: use lowercase letters, digits and dashes") end,
(if (.targets // {} | type) != "object" then "registry: targets: must be a map" else empty end)
'

# ds_registry_json <path>: the validated registry as JSON.
ds_registry_json() {
  local json problems
  json=$(yq -o=json '.' "$1" 2>&1) || ds_die 2 "can't parse $1: $json"
  problems=$(jq -r "$_DS_VALIDATE" <<<"$json") || ds_die 2 "can't validate $1"
  [ -z "$problems" ] || { echo "$problems" | sed 's/^/devstack: /' >&2; exit 2; }
  echo "$json"
}
