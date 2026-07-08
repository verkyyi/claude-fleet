#!/bin/bash
# dash-issue-pick.sh <target sess:idx> — popup issue picker. Lists all cached
# GitHub issues (searchable), and on selection binds the target window to it
# (@issue). Run inside `tmux display-popup -E`. Esc cancels (no binding).
set -uo pipefail
target="${1:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
C="${TMPDIR:-/tmp}/.claude-dash"
[ -s "$C/issues" ] || { echo "no issues cached yet — wait for the collector"; sleep 1.5; exit 0; }
cur=$(tmux display-message -t "$target" -p '#{@issue}' 2>/dev/null)

# filtering ENABLED here (type to search); field1=issue number, field2=display
num=$(bash "$BIN/tmux-issues-rows.sh" all 2>/dev/null \
  | fzf --ansi --delimiter=$'\x1f' --with-nth=2 --no-sort --layout=reverse \
        --prompt="bind $(tmux display-message -t "$target" -p '#W') → " \
        --header="pick an issue (type to search · enter binds · esc cancels)${cur:+   [currently #$cur]}" \
  | cut -d$'\x1f' -f1)
[ -n "$num" ] && tmux set-window-option -t "$target" @issue "$num" 2>/dev/null
