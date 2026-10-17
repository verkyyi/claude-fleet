#!/bin/bash
# selftest-deps: fleet-loop.py fleet_runtime.py fleet-codex-rpc.py fleet-loop-idle-native-selftest.py
# The loop's due wakeup through fleet_runtime.accept_if_idle against a REAL Codex
# app-server (#4431): Stop->looping + native idle => accepted exactly once; a turn
# that starts after the idle check => rejected natively, still due, then once.
# Fixtures: the loopback model, the C3 launch authority and the pane gates; the
# native accept / journal / receipt are the real ones. No fleet pane, no network.
# No codex >= 0.162 on PATH (CI) => SKIP; the unit contract is
# fleet-loop-selftest.py IdleDispatchTests.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
codex_bin=$(command -v codex 2>/dev/null || true)
if [ -z "$codex_bin" ]; then
  echo "SKIP fleet-loop-idle-native: no codex on PATH"; exit 0
fi
ver=$("$codex_bin" --version 2>/dev/null | awk '{print $NF}')
case "$ver" in
  0.16[2-9].*|0.1[7-9][0-9].*|0.[2-9][0-9][0-9].*|[1-9]*) ;;
  *) echo "SKIP fleet-loop-idle-native: codex $ver < 0.162"; exit 0 ;;
esac
PYTHONDONTWRITEBYTECODE=1 python3 -I "$BIN/fleet-loop-idle-native-selftest.py" "$BIN" "$codex_bin"
