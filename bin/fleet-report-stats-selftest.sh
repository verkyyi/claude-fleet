#!/bin/bash
# fleet-report-stats selftest (issue #941) — synthetic transcripts + ledger built in a
# temp dir; no live sessions, no network.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-report-stats-selftest.py" "$BIN"
