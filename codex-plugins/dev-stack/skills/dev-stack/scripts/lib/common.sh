#!/bin/bash
# Helpers every dev-stack library uses.

# ds_die <code> <message...>: print to stderr and exit with <code>.
# Codes: 1 a service failed, 2 usage or registry error, 3 missing prerequisite.
ds_die() { local code=$1; shift; echo "devstack: $*" >&2; exit "$code"; }

# _ds_sha256 <file>: hex digest (macOS ships shasum, minimal Linux sha256sum).
_ds_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi; }

ds_state_dir() { echo "${DEVSTACK_STATE_DIR:-$HOME/.local/state/devstack}"; }
