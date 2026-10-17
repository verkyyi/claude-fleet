#!/bin/bash
# selftest-deps: fleet_runtime.py fleet-codex-rpc.py fleet-idle-accept-native-selftest.py
# The real Codex app-server's start-if-idle + clientUserMessageId receipt
# (#4617), behind fleet_runtime's own settle/receipt functions. A loopback model
# fixture and an isolated HOME; no fleet pane, no credential, no network.
# No codex >= 0.162 on PATH (CI) => SKIP; the unit contract is
# fleet-runtime-selftest.py CodexIdleAccept.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
codex_bin=$(command -v codex 2>/dev/null || true)
if [ -z "$codex_bin" ]; then
  echo "SKIP fleet-idle-accept-native: no codex on PATH"; exit 0
fi
ver=$("$codex_bin" --version 2>/dev/null | awk '{print $NF}')
case "$ver" in
  0.16[2-9].*|0.1[7-9][0-9].*|0.[2-9][0-9][0-9].*|[1-9]*) ;;
  *) echo "SKIP fleet-idle-accept-native: codex $ver < 0.162"; exit 0 ;;
esac
PYTHONDONTWRITEBYTECODE=1 python3 -I "$BIN/fleet-idle-accept-native-selftest.py" "$BIN" "$codex_bin"
