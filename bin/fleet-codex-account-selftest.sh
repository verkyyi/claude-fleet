#!/bin/bash
# Hermetic homes, quota fixtures and fake native app-server. No model/network calls.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-codex-account-selftest.py"
