#!/bin/bash
# Target expansion and dependency ordering.
DS_LIB=${DS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=common.sh
. "$DS_LIB/common.sh"

# shellcheck disable=SC2016 # a jq program, not shell
_DS_RESOLVE='
def deps($s):
  (.reg.services[$s].depends_on // [])
  + ((.reg.services[$s].optional_deps // []) | map(select(. as $d | $with | index($d))));
def visit($s; $path):
  if (.reg.services | has($s) | not) then
    error("unknown service: \($s) (a dependency of \($path[-1]))")
  elif (.order | index($s)) then .
  elif ($path | index($s)) then
    error("dependency cycle: " + (($path + [$s]) | join(" -> ")))
  else reduce deps($s)[] as $d (.; visit($d; $path + [$s])) | .order += [$s]
  end;
. as $reg
| try (
    [ $names[] as $n
      | if ($reg.targets // {} | has($n)) then $reg.targets[$n][]
        elif ($reg.services | has($n)) then $n
        else error("unknown service or target: \($n)") end ] as $start
    | reduce $start[] as $s ({reg: $reg, order: []}; visit($s; [])) | .order[])
  catch ("ERROR: " + .)
'

# ds_resolve <registry_json_file> <with_csv> <name...>: services in start
# order (dependencies first), one per line.
ds_resolve() {
  local file=$1 with=$2 out
  shift 2
  [ $# -gt 0 ] || ds_die 2 "name at least one service or target"
  out=$(jq -r --argjson names "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
    --argjson with "$(tr ',' '\n' <<<"$with" | grep . | jq -R . | jq -s .)" \
    "$_DS_RESOLVE" "$file" 2>&1) || ds_die 2 "${out#jq: error (at *): }"
  if grep -q '^ERROR: ' <<<"$out"; then ds_die 2 "$(sed -n 's/^ERROR: //p' <<<"$out" | head -1)"; fi
  echo "$out"
}
