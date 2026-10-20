#!/bin/bash
# Keep fleet_transfer_source.py (fleet-transfer-source-selftest.py) paired with missing/untrusted auth refusals.
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-transfer-auth-selftest.py" "$@"
