#!/bin/bash
# selftest-deps: fleet-handoff-pickup-claude-selftest.py fleet-native-claude-tui-selftest.py fleet-handoff-cycle.sh accept.ts inbox.ts lifecycle.ts
# The real Claude Code engine behind a handoff's pickup (#4865): mod/fleet (a
# copy, plus a markdown command standing in for /fleet-handoff) in a pty, a
# loopback model fixture and an isolated HOME; `/clear` and then the pickup are
# posted to the mod inbox exactly as fleet-handoff-cycle.sh's fleet_session_command
# posts them, and the pickup must reach the fresh session's model — never
# «fleet idle-accept: no live request». No credential, no network, no fleet pane.
# No claude >= 2.1.295 on PATH (CI) => SKIP.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
claude_bin=$(command -v claude 2>/dev/null || true)
if [ -z "$claude_bin" ]; then
  echo "SKIP fleet-handoff-pickup-claude: no claude on PATH"; exit 0
fi
for managed in "/Library/Application Support/ClaudeCode" /etc/claude-code; do
  if [ -e "$managed" ]; then echo "SKIP fleet-handoff-pickup-claude: machine-managed Claude configuration"; exit 0; fi
done
ver=$("$claude_bin" --version 2>/dev/null | awk '{print $1}')
IFS=. read -r ma mi pa <<<"${ver:-0.0.0}"
if [ "${ma:-0}" -ne 2 ] || [ "${mi:-0}" -ne 1 ] || [ "${pa%%[!0-9]*}" -lt 295 ] 2>/dev/null; then
  echo "SKIP fleet-handoff-pickup-claude: claude $ver outside 2.1.295..2.1.x"; exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 -I "$BIN/fleet-handoff-pickup-claude-selftest.py" "$BIN" "$claude_bin"
