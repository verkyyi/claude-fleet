#!/bin/bash
# Own result history, PR evidence and pending protection; no Parent delivery.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-report-durable-selftest.py"
