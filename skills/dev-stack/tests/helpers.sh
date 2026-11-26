#!/bin/bash
# Shared setup for the dev-stack tests: a temp dir, a stub-binary folder
# first on PATH, and pass/fail counters. Source it from a *.test.sh file.
set -uo pipefail

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS="$TESTS/../scripts"
# shellcheck disable=SC2034 # used by the test files that source this one
DEVSTACK="$SCRIPTS/devstack"
# shellcheck disable=SC2034
LIB="$SCRIPTS/lib"

TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# `git rebase --exec` and git hooks export GIT_DIR. Left set, the git
# commands in these tests that build a throwaway repo would write to the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
mkdir -p "$TMP/bin"
: > "$TMP/calls.log"
export PATH="$TMP/bin:$PATH"
export DEVSTACK_STATE_DIR="$TMP/state"
unset DEVSTACK_REGISTRY
# No idle watchdog unless a test asks for one.
export DEVSTACK_IDLE_MINUTES=0
unset DEVSTACK_IDLE_SECONDS DEVSTACK_IDLE_TICK

pass=0
fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $1"; }

# check <description> <command...>: passes when the command succeeds.
check() { local d=$1; shift; if "$@"; then ok; else no "$d"; fi; }

# stub_bin <name> <script-body>: an executable on PATH that logs each call
# to $TMP/calls.log, then runs the body.
stub_bin() {
  {
    echo '#!/bin/bash'
    echo "echo \"$1 \$*\" >> \"$TMP/calls.log\""
    echo "$2"
  } > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}

# sedi <sed args...> <file>: in-place edit that works with BSD (macOS) and GNU sed.
sedi() { local f=${*: -1}; sed -i.bak "$@" && rm -f "$f.bak"; }

finish() {
  echo "$(basename "$0" .test.sh): $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
