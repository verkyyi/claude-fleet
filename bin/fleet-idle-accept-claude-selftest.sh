#!/bin/bash
# selftest-deps: fleet_runtime.py fleet-idle-accept-claude-selftest.py fleet-native-claude-tui-selftest.py accept.ts inbox.ts lifecycle.ts state.ts
# The real Claude Code engine's entry boundary behind the fleet mod's
# conditional idle acceptance (#4618): mod/fleet (a copy) in a pty, a loopback
# model fixture and an isolated HOME; fleet_runtime's own claude_post_accept /
# claude_receipt. No credential, no network, no fleet pane.
# No claude >= 2.1.295 on PATH (CI) => SKIP; the unit contracts are
# fleet-runtime-selftest.py ClaudeIdleAccept and mod/fleet/tests/accept.test.tsx.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
claude_bin=$(command -v claude 2>/dev/null || true)
if [ -z "$claude_bin" ]; then
  echo "SKIP fleet-idle-accept-claude: no claude on PATH"; exit 0
fi
for managed in "/Library/Application Support/ClaudeCode" /etc/claude-code; do
  if [ -e "$managed" ]; then echo "SKIP fleet-idle-accept-claude: machine-managed Claude configuration"; exit 0; fi
done
ver=$("$claude_bin" --version 2>/dev/null | awk '{print $1}')
IFS=. read -r ma mi pa <<<"${ver:-0.0.0}"
if [ "${ma:-0}" -ne 2 ] || [ "${mi:-0}" -ne 1 ] || [ "${pa%%[!0-9]*}" -lt 295 ] 2>/dev/null; then
  echo "SKIP fleet-idle-accept-claude: claude $ver outside 2.1.295..2.1.x"; exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 -I "$BIN/fleet-idle-accept-claude-selftest.py" "$BIN" "$claude_bin"
