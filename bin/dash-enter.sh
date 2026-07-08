#!/bin/bash
# dash-enter.sh <target sess:idx> <query> — Enter handler for the dash.
# Emits fzf actions on stdout (called from an fzf `transform` binding) and does
# the tmux side-effect. Modes:
#   bind mode    (bind flag, set by ctrl-g): bind/unbind <target> to issue query
#   rename mode  (rename flag, set by ctrl-e): rename <stored target> to query
#   jump         (default): select the target window (typed query is ignored)
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"; bindflag="$C/bind_target"
target="${1:-}"; q="${2:-}"
PROMPT='▸ '
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"

if [ -f "$bindflag" ]; then                       # bind-issue mode (empty q unbinds)
  t=$(cat "$bindflag"); rm -f "$bindflag"
  tmux set-window-option -t "$t" @issue "$q" 2>/dev/null
  echo "hide-input+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
elif [ -f "$flag" ]; then                         # rename mode
  t=$(cat "$flag"); rm -f "$flag"
  if [ -n "$q" ]; then tmux rename-window -t "$t" "$q" 2>/dev/null
    echo "hide-input+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
  else echo "hide-input+change-prompt($PROMPT)+clear-query"; fi
else                                              # jump (typed query is ignored)
  tmux select-window -t "$target" 2>/dev/null
  echo "clear-query"
fi
