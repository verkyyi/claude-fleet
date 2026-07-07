#!/bin/bash
# steward-zoom.sh — prefix+g, progressive steward focus:
#   from another window : jump to the plan window and focus the steward pane
#                         (split view — dash above, steward below)
#   already in that window: toggle the steward pane fullscreen (zoom) — press
#                         again to restore the split
# The steward pane = pane option @steward=1 (steward-session.sh marks its
# spawn; mark any pane by hand: tmux set-option -p @steward 1). No marked
# pane anywhere → fall back to spawning the standalone steward window.
target=$(tmux list-panes -a -F '#{pane_id} #{@steward}' | awk '$2=="1"{print $1; exit}')
if [ -z "$target" ]; then
  exec bash "$HOME/.claude/steward-session.sh"
fi

tw=$(tmux display-message -p -t "$target" '#{window_id}')
curw=$(tmux display-message -p '#{window_id}')

if [ "$curw" != "$tw" ]; then
  tmux select-window -t "$target"       # jump — always arrive at the SPLIT view
  tmux select-pane -t "$target"
  if [ "$(tmux display-message -p -t "$target" '#{window_zoomed_flag}')" = "1" ]; then
    tmux resize-pane -Z -t "$target"
  fi
else
  tmux select-pane -t "$target"         # inside already — toggle fullscreen
  tmux resize-pane -Z -t "$target"
fi
# run-shell shows a blocking error view on ANY nonzero exit (e.g. the zoom-flag
# test above evaluating false) — always leave cleanly.
exit 0
