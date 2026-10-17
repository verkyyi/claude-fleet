#!/bin/bash
# fleet-admin-old-jobs-selftest.sh — the admin login's old jobs and a managed
# login's own credential proxy, cleared by the machine daemon's sweep (issue #4363,
# EPIC #4354 C10): bin/fleet-node-supervisor.py admin_old_retire / credsep_join_own,
# driving bin/fleet-credsep.py machine managed / machine join through a fake.
# Cases in bin/fleet-admin-old-jobs-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-admin-old-jobs-selftest.py"
