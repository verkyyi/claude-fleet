#!/bin/bash
# fleet-webterm-selftest.sh — the phone-first web terminal prototype (issue #3837,
# EPIC #3836): extras/web-term/server.py for real on 127.0.0.1 — token + Origin
# gates, CJK text into the PTY whole, resize, no orphan when the browser goes —
# and extras/web-term/ui/keys.js's bytes under node. The checks live in
# fleet-webterm-selftest.py.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-webterm-selftest.py"
