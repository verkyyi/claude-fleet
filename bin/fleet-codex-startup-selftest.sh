#!/bin/bash
# Native startup policy and unused-TUI readiness, without MCP/model requests.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-codex-startup-selftest.py"
