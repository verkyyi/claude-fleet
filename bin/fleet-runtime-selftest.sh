#!/bin/bash
# selftest-deps: fleet_runtime.py fleet_launch.py fleet-codex-rpc.py fleet-codex-session.py mod/fleet/hooks/state.ts
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$BIN/fleet-runtime-selftest.py" "$@"
