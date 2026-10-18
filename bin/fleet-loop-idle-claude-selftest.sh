#!/bin/bash
# selftest-deps: fleet-loop.py fleet_runtime.py fleet-loop-idle-claude-selftest.py fleet-idle-accept-claude-selftest.py fleet-native-claude-tui-selftest.py accept.ts inbox.ts lifecycle.ts state.ts
# The loop's due wakeup through fleet_runtime.accept_if_idle against a REAL
# Claude Code engine and the real fleet mod (#4658, the Claude half of #4431):
# idle ⇒ accepted once with a queryable receipt; a person's turn behind an idle
# read ⇒ dropped at the entry boundary, still due, then once as a new delivery;
# the answer lost after the mod took it ⇒ unknown, settled by its receipt on the
# next tick, never resent. Loopback model fixture, isolated HOME, no fleet pane.
# No claude >= 2.1.295 on PATH (CI) => SKIP; the unit contract is
# fleet-loop-selftest.py IdleDispatchTests.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
claude_bin=$(command -v claude 2>/dev/null || true)
if [ -z "$claude_bin" ]; then
  echo "SKIP fleet-loop-idle-claude: no claude on PATH"; exit 0
fi
for managed in "/Library/Application Support/ClaudeCode" /etc/claude-code; do
  if [ -e "$managed" ]; then echo "SKIP fleet-loop-idle-claude: machine-managed Claude configuration"; exit 0; fi
done
ver=$("$claude_bin" --version 2>/dev/null | awk '{print $1}')
IFS=. read -r ma mi pa <<<"${ver:-0.0.0}"
if [ "${ma:-0}" -ne 2 ] || [ "${mi:-0}" -ne 1 ] || [ "${pa%%[!0-9]*}" -lt 295 ] 2>/dev/null; then
  echo "SKIP fleet-loop-idle-claude: claude $ver outside 2.1.295..2.1.x"; exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 -I "$BIN/fleet-loop-idle-claude-selftest.py" "$BIN" "$claude_bin"
