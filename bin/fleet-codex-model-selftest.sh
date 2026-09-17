#!/bin/bash
# Native model settings and model-specific quota evidence, with no model calls.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-codex-model-selftest.py"
