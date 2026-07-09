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
set -uo pipefail
REFRESH="${REFRESH:-0.25}"   # 4Hz repaint: the rows producer is exec-fork-free (~45ms), spinner steps a frame per repaint
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
C="${TMPDIR:-/tmp}/.claude-dash"

# Scope rows to THIS fleet's tmux session (strict per-fleet). The rows producer and
# its reload-binds inherit FLEET_SESSION; unset ⇒ show-all (single-fleet back-compat).
# Same convention tmux-issues.sh uses for the backlog panel.
. "$BIN/fleet-lib.sh" 2>/dev/null || true
FLEET_SESSION=$(fleet_current_session 2>/dev/null); export FLEET_SESSION

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf not found — install it (brew install fzf) for the interactive dash."; sleep 5; exit 1
fi

# Summary is an inline column (one line per row) — no preview panel.
PREVIEW=( --preview-window=hidden )

# POPUP=1 → run as a one-shot FULL-SCREEN modal (prefix+G peek): esc/q closes it
# and drops you back where you were, and a jump (enter) closes it too. Otherwise
# it's the always-on 'dash' window that relaunches on esc. Same convention the
# backlog panel (tmux-issues.sh) uses.
POPUP="${POPUP:-}"
ENTER_TAIL=""; [ -n "$POPUP" ] && ENTER_TAIL="+abort"
HDR='enter=jump · ⌃g=new session (pick issue) · ⌃e=rename · ⌃x=reap ⌥x=force · esc=back'
[ -n "$POPUP" ] && HDR='enter=jump (closes) · ⌃g=new session · ⌃e=rename · ⌃x=reap ⌥x=force · esc=close'

run_dash() {
  rm -f "$C/rename_target" "$C/bind_target"   # clear any half-finished mode from a prior run
  bash "$ROWS" | fzf --ansi --delimiter=$'\x1f' --with-nth=3 \
    --header-lines=1 \
    --disabled --no-input --no-sort \
    --layout=reverse-list --info=hidden --border=none \
    --prompt='▸ ' \
    --header="$HDR" \
    "${PREVIEW[@]}" \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS)" \
    --bind "ctrl-r:reload(bash $ROWS)" \
    --bind "ctrl-g:execute(tmux display-popup -E -w 82% -h 72% \"bash $BIN/dash-issue-spawn.sh\")+reload(bash $ROWS)" \
    --bind "ctrl-e:show-input+execute-silent(echo {1} > $C/rename_target)+transform-query(tmux display-message -t {1} -p '#W')+change-prompt(rename ▸ )" \
    --bind "ctrl-x:execute-silent(bash $BIN/dash-reap.sh {1})+reload(bash $ROWS)" \
    --bind "alt-x:execute(bash $BIN/dash-reap.sh {1} --force)+reload(bash $ROWS)" \
    --bind "enter:transform(bash $BIN/dash-enter.sh {1} {q})$ENTER_TAIL" \
    --bind "esc:transform(bash $BIN/dash-esc.sh)" \
    >/dev/null 2>&1
}

# Modal peek: run once, then exit so the popup closes and returns you.
if [ -n "$POPUP" ]; then run_dash; exit 0; fi

# Loop so Esc/q just relaunches — the window stays a live dashboard.
while :; do
  run_dash
  sleep 0.2
done
