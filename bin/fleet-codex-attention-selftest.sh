#!/bin/bash
# Native request fixtures, exact identity checks and private tmux state races.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-codex-attention-selftest.py"
