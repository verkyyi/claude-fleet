#!/bin/bash
# selftest-deps: fleet_launch.py dash-raw-session.sh fleet-native-create-selftest.py
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$BIN/fleet-native-create-selftest.py"
