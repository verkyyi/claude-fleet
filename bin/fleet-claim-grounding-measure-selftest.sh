#!/bin/bash
# Synthetic checked-in transcripts only; no live sessions or network.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-claim-grounding-measure-selftest.py" "$BIN"
