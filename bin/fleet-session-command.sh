#!/bin/bash
# fleet-session-command.sh [--socket <label>] [--from <who>] <target> '/cmd args'
# The CLI face of fleet_session_command (bin/fleet-lib.sh, issue #1337): run a
# slash command in <target>'s Claude session through the fleet mod's inbox
# instead of typing it. For the sh callers (bin/fleet-compact-send.sh) that do not
# source the lib. Exit codes are the function's: 0 executed · 3 no mod · 4 timed
# out (cancelled, never runs) · 5 refused · 6 running (taken, not yet done) ·
# 2 usage. Fall back to send-keys on 3/4/5 only.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || exit 3
fleet_session_command "$@"
