#!/bin/bash
# Helpers every dev-stack library uses.

# ds_die <code> <message...>: print to stderr and exit with <code>.
# Codes: 1 a service failed, 2 usage or registry error, 3 missing prerequisite.
ds_die() { local code=$1; shift; echo "devstack: $*" >&2; exit "$code"; }

# _ds_sha256 <file>: hex digest (macOS ships shasum, minimal Linux sha256sum).
_ds_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi; }

# _ds_timeout <seconds> <cmd...>: run it, killing it after <seconds> (exit
# 124). macOS has no timeout(1). Its output goes through a file, not the
# caller's pipe: a child the killed command leaves behind (a wrapper script's
# own child) would otherwise keep a capturing $(...) waiting.
_ds_timeout() {
  local t=$1 p w rc out
  shift
  out=$(mktemp "${TMPDIR:-/tmp}/devstack-out.XXXXXX") || return 1
  "$@" > "$out" & p=$!
  ( sleep "$t"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$p"; rc=$?
  if kill "$w" 2>/dev/null; then wait "$w" 2>/dev/null; else rc=124; fi
  cat "$out"; rm -f "$out"
  return $rc
}

ds_state_dir() { echo "${DEVSTACK_STATE_DIR:-$HOME/.local/state/devstack}"; }
