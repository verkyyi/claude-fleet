#!/bin/bash
# fleet-node-supervisor-selftest.sh — the machine's one daemon, sandboxed (issue #2331):
# bin/fleet-node-supervisor.py (children + backoff, one copy per task, the attic
# sweep, state across a restart, status --check) and fleet-diskguard.sh's
# FLEET_ORPHAN_ALL_USERS. Cases in bin/fleet-node-supervisor-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-node-supervisor-selftest.py"
