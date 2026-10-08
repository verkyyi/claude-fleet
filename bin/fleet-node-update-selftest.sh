#!/bin/bash
# fleet-node-update-selftest.sh — the machine's one updater, sandboxed (issue #2334):
# bin/fleet-node-update.py (every part to the release or none, the doctor's
# rollback gate, a tick killed half way, the EPIC hold) and the restart request
# bin/fleet-node-supervisor.py honours. Cases in bin/fleet-node-update-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py"
