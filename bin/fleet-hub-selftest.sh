#!/bin/bash
# Hub/bridge regression tests run entirely inside temporary fixtures.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-hub-selftest.py"
