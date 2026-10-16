#!/bin/bash
# Keep fleet-failover-selftest.py fixtures paired with missing/untrusted auth refusals.
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-transfer-auth-selftest.py" "$@"
