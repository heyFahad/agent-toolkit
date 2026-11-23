#!/bin/bash
# Tests for target expansion and dependency ordering.
# Run: bash skills/dev-stack/tests/resolve.test.sh
. "$(dirname "$0")/helpers.sh"
# shellcheck source=../scripts/lib/resolve.sh
. "$LIB/resolve.sh"

cat > "$TMP/reg.json" <<'JSON'
{"services": {
  "connect-api": {"depends_on": ["bsa", "ti-api"], "optional_deps": ["naia"]},
  "bsa": {}, "ti-api": {}, "naia": {"depends_on": ["bsa"]}, "connect-metro": {}
 },
 "targets": {"connect": ["connect-metro", "connect-api"]}}
JSON
cat > "$TMP/cycle.json" <<'JSON'
{"services": {"a": {"depends_on": ["b"]}, "b": {"depends_on": ["a"]}}, "targets": {}}
JSON

before() { # <list> <first> <second>: first appears before second
  local a b
  a=$(grep -nx "$2" <<<"$1" | cut -d: -f1); b=$(grep -nx "$3" <<<"$1" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# --- target_expands_with_deps ---
got=$(ds_resolve "$TMP/reg.json" "" connect)
check "bsa before connect-api" before "$got" bsa connect-api
check "ti-api before connect-api" before "$got" ti-api connect-api
check "connect-metro included" grep -qx connect-metro <<<"$got"
check "naia not included without --with" bash -c '! grep -qx naia <<<"$1"' _ "$got"

# --- with_adds_optional ---
got=$(ds_resolve "$TMP/reg.json" "naia" connect)
check "naia before connect-api with --with" before "$got" naia connect-api
check "naia's own dep comes first" before "$got" bsa naia

# --- no_duplicates ---
got=$(ds_resolve "$TMP/reg.json" "" connect connect-api bsa)
check "each service once (got: $(echo $got))" [ "$(sort <<<"$got" | uniq -d)" = "" ]
check "four services" [ "$(wc -l <<<"$got" | tr -d ' ')" = 4 ]

# --- unknown_exit_2 ---
out=$(ds_resolve "$TMP/reg.json" "" nope 2>&1); code=$?
check "unknown exits 2 (got $code)" [ "$code" -eq 2 ]
check "unknown names it" grep -q "unknown service or target: nope" <<<"$out"

# --- cycle_exit_2 ---
out=$(ds_resolve "$TMP/cycle.json" "" a 2>&1); code=$?
check "cycle exits 2 (got $code)" [ "$code" -eq 2 ]
check "cycle shows the path (got '$out')" grep -q "dependency cycle: a -> b -> a" <<<"$out"

finish
