#!/bin/bash
# Helpers every dev-stack library uses.

# ds_die <code> <message...>: print to stderr and exit with <code>.
# Codes: 1 a service failed, 2 usage or registry error, 3 missing prerequisite.
ds_die() { local code=$1; shift; echo "devstack: $*" >&2; exit "$code"; }

# _ds_sha256 <file>: hex digest (macOS ships shasum, minimal Linux sha256sum).
_ds_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi; }

# _ds_timeout <seconds> <cmd...>: run it, killing it after <seconds> (exit
# 124), with SIGKILL 2 seconds later if it ignores SIGTERM. macOS has no
# timeout(1). Its output goes through a file, not the
# caller's pipe: a child the killed command leaves behind (a wrapper script's
# own child) would otherwise keep a capturing $(...) waiting.
_ds_timeout() {
  local t=$1 p w rc out
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/devstack-out.XXXXXX") || return 1
  "$@" > "$out" & p=$!
  # The marker is written before the first signal, so a command that exits
  # cleanly on SIGTERM still reads as timed out.
  ( sleep "$t"; : > "$out.expired"; kill "$p" 2>/dev/null; sleep 2; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null && wait "$w" 2>/dev/null
  [ -e "$out.expired" ] && rc=124
  cat "$out"; rm -f "$out" "$out.expired"
  return $rc
}

ds_state_dir() { echo "${DEVSTACK_STATE_DIR:-$HOME/.local/state/devstack}"; }
