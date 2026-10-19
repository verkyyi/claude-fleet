#!/bin/bash
# fleet-admin-old-jobs-selftest.sh — the admin login's old jobs, cleared by the
# machine daemon's sweep (issue #4363, EPIC #4354 C10): bin/fleet-node-supervisor.py
# admin_old_retire; the credential store is never asked (a fake records it).
# Cases in bin/fleet-admin-old-jobs-selftest.py.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning "$BIN/fleet-admin-old-jobs-selftest.py"
