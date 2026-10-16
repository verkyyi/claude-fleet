#!/bin/bash
# selftest-part-of: tmux-spinner.sh tmux-spinner.py fleet-render-watch.py set-claude-state.sh
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/spinner-wait-selftest.py" "$@"
