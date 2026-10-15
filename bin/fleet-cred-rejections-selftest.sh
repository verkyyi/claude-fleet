#!/usr/bin/env bash
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 -W ignore::ResourceWarning -I "$BIN/fleet-cred-rejections-selftest.py"
