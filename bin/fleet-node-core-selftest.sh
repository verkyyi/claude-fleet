#!/bin/bash
# fleet-node-core-selftest.sh — the machine's root core, sandboxed (issue #3555,
# EPIC #3500 C13): bin/fleet-node-core.py (the fixed table, the peer check, run-as /
# exec-as / kill / memguard / power, the signed switch + rollback, the alert),
# bin/fleet_node_core.py (the client) and bin/fleet_ed25519.py. Cases in
# bin/fleet-node-core-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-node-core-selftest.py"
