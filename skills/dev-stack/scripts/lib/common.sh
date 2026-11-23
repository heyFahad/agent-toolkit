#!/bin/bash
# Helpers every dev-stack library uses.

# ds_die <code> <message...>: print to stderr and exit with <code>.
# Codes: 1 a service failed, 2 usage or registry error, 3 missing prerequisite.
ds_die() { local code=$1; shift; echo "devstack: $*" >&2; exit "$code"; }

ds_state_dir() { echo "${DEVSTACK_STATE_DIR:-$HOME/.local/state/devstack}"; }
