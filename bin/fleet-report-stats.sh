#!/bin/bash
# The five child-report quality metrics of EPIC #935 (read-only); see fleet-report-stats.py.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-report-stats.py" "$@"
