#!/bin/bash
# tmux-dashboard.sh — INTERACTIVE, footer-themed session dashboard (fzf).
# Rows come from tmux-dashboard-rows.sh (footer glyphs+palette; issue · model ·
# context% · one-line LLM summary). Reads like the tmux status bar with columns,
# but you can drive it:
#   ↑/↓ move · Enter jump to that window · type a task + Enter = create a GitHub
#   issue and spawn a worktree session bound to it · Ctrl-G bind window↔issue ·
#   Ctrl-E rename window · Ctrl-R refresh now · Esc/q relaunch (it's always-on)
# Auto-reloads every REFRESH sec (default 3). Run in a dedicated 'dash' window
# (prefix+j creates one). Env: REFRESH.
REFRESH="${REFRESH:-0.25}"   # 4Hz repaint: the rows producer is exec-fork-free (~45ms), spinner steps a frame per repaint
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
C="${TMPDIR:-/tmp}/.claude-dash"

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf not found — install it (brew install fzf) for the interactive dash."; sleep 5; exit 1
fi

# Summary is an inline column (one line per row) — no preview panel.
PREVIEW=( --preview-window=hidden )

# Loop so Esc/q just relaunches — the window stays a live dashboard.
while :; do
  rm -f "$C/rename_target" "$C/bind_target"   # clear any half-finished mode from a prior run
  SP=$(tmux display-message -p '#{session_path}' 2>/dev/null); SP="${SP/#$HOME/~}"   # cwd new windows open in
  bash "$ROWS" | fzf --ansi --delimiter=$'\x1f' --with-nth=3 \
    --disabled --no-sort \
    --layout=reverse-list --info=hidden --border=rounded \
    --border-label=" $SP " --border-label-pos=3 \
    --prompt='＋ new ▸ ' \
    --header='enter=jump · type→enter=new · ⌃g=bind (pick issue) · ⌃e=rename · esc=back' \
    "${PREVIEW[@]}" \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS)" \
    --bind "ctrl-r:reload(bash $ROWS)" \
    --bind "ctrl-g:execute(tmux display-popup -E -w 82% -h 72% \"bash $BIN/dash-issue-pick.sh {1}\")+reload(bash $ROWS)" \
    --bind "ctrl-e:execute-silent(echo {1} > $C/rename_target)+transform-query(tmux display-message -t {1} -p '#W')+change-prompt(rename ▸ )" \
    --bind "enter:transform(bash $BIN/dash-enter.sh {1} {q})" \
    --bind "esc:transform(bash $BIN/dash-esc.sh)" \
    >/dev/null 2>&1
  sleep 0.2
done
