#!/bin/bash
# dash-enter.sh <target sess:idx> <query> — Enter handler for the dash.
# Emits fzf actions on stdout (called from an fzf `transform` binding) and does
# the tmux side-effect. Three modes:
#   rename mode  (flag file present, set by ctrl-e): rename <stored target> to query
#   new-session  (query non-empty): spawn a worktree session seeded with query
#   jump         (query empty): select the target window
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"; bindflag="$C/bind_target"
target="$1"; q="$2"
NEWPROMPT='＋ new ▸ '
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"

if [ -f "$bindflag" ]; then                       # bind-issue mode (empty q unbinds)
  t=$(cat "$bindflag"); rm -f "$bindflag"
  tmux set-window-option -t "$t" @issue "$q" 2>/dev/null
  echo "change-prompt($NEWPROMPT)+clear-query+reload(bash $ROWS)"
elif [ -f "$flag" ]; then                         # rename mode
  t=$(cat "$flag"); rm -f "$flag"
  if [ -n "$q" ]; then tmux rename-window -t "$t" "$q" 2>/dev/null
    echo "change-prompt($NEWPROMPT)+clear-query+reload(bash $ROWS)"
  else echo "change-prompt($NEWPROMPT)+clear-query"; fi
elif [ -n "$q" ]; then
  bash "$BIN/dash-new-session.sh" "$q"
  echo "clear-query"
else
  tmux select-window -t "$target" 2>/dev/null
fi
