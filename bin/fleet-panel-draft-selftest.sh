#!/bin/bash
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 exec python3 "$BIN/fleet-panel-draft-selftest.py"
