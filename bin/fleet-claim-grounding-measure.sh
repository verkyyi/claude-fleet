#!/bin/bash
# Read-only Claude claim/grounding transcript measurements; see docs/dev/CLAIM-MEASUREMENT.md.
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-claim-grounding-measure.py" "$@"
