#!/bin/bash
# fleet-admin-handover-selftest.sh — the admin login's old node agent handed over to
# the seat (issue #3725, EPIC #3500 C15·b-4): bin/fleet-node-supervisor.py
# admin-handover / its sweep, bin/fleet_admin_seat.py seat_connected,
# bin/fleet-node-update.py's follow skipping a handed-over login and
# bin/fleet-credsep.py's agent_reload. Cases in bin/fleet-admin-handover-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-admin-handover-selftest.py"
