#!/bin/bash
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-transfer-auth-selftest.py" "$@"
