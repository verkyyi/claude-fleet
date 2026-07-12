#!/bin/bash
# tmux-dashboard.sh — INTERACTIVE, footer-themed session dashboard (fzf).
# Rows come from tmux-dashboard-rows.sh (footer glyphs+palette; issue · model ·
# context% · one-line LLM summary). Reads like the tmux status bar with columns,
# but you can drive it:
#   ↑/↓ move · Enter jump to that window · type a task + Enter = create a GitHub
#   issue and spawn a worktree session bound to it · Ctrl-G bind window↔issue ·
#   Ctrl-E rename window · Ctrl-L land the row's green PR (dash-land.sh → the
#   no-LLM fleet-land.sh; #232 — overrides fzf's low-value clear-screen default) ·
#   Ctrl-R refresh now · Esc/q relaunch (it's always-on)
# Auto-reloads every REFRESH sec (default 3). Runs as the embedded dash pane in
# the 'plan' hub (fleet-up/steward-session builds it; prefix+G focuses it). Env: REFRESH.
set -uo pipefail
REFRESH="${REFRESH:-1}"   # 1Hz repaint: 4Hz burned ~10% CPU per dash in steady state; the spinner steps a frame per repaint
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
C="${TMPDIR:-/tmp}/.claude-dash"

# Scope rows to THIS fleet's tmux session (strict per-fleet). The rows producer and
# its reload-binds inherit FLEET_SESSION; unset ⇒ show-all (single-fleet back-compat).
# Same convention tmux-issues.sh uses for the backlog panel.
. "$BIN/fleet-lib.sh" 2>/dev/null || true
FLEET_SESSION=$(fleet_current_session 2>/dev/null); export FLEET_SESSION

# Mark this pane as a dash (mirrors how steward-session.sh marks @steward=1) so
# /fleet-sync-install can find EVERY dash pane to respawn on a launcher change —
# the standalone 'dash' window AND an embedded dash pane in the plan/steward
# split. Set early (before fzf) so even a freshly-launched dash is discoverable;
# the pane just runs `bash`, so a marker is far more robust than name/command
# heuristics. Mark THIS pane explicitly ($TMUX_PANE) — a bare `set-option -p`
# marks the *active* pane, so an embedded dash relaunching while the steward pane
# is focused would wrongly tag the steward (issue #135). fleet_mark_role also
# clears @steward here, keeping the two markers mutually exclusive.
fleet_mark_role dash "${TMUX_PANE:-}" 2>/dev/null || \
  tmux set-option -p -t "${TMUX_PANE:-}" @dash 1 2>/dev/null || true

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
# Minimal header (issue #249): core actions inline, the rest deferred to the `?`
# cheatsheet (fleet-keys.sh lists every demoted bind: ⌃g ⌃s ⌃e ⌃x ⌥x ⌃t ⌃o).
# Terse `key verb` form, not `key=phrase`, so it fits one line at normal widths.
HDR='↵ jump · ⌃n new · ⌃l land · ? keys'
# POPUP variant: same minimal set + a trailing `esc close` (closing a modal is
# less obvious than esc-back on the always-on dash) — that token is the only diff.
[ -n "$POPUP" ] && HDR='↵ jump · ⌃n new · ⌃l land · ? keys · esc close'

run_dash() {
  # clear any half-finished mode from a prior run; reset the live⇄landed view so
  # the landed peek doesn't stick across esc-relaunch (and never hides the live
  # session list on reopen). Per-fleet keyed, matching dash-view-toggle.sh (#130).
  rm -f "$C/rename_target" "$C/bind_target" "$C/global/dash_view_${FLEET_SESSION:-default}"
  bash "$ROWS" | fzf --ansi --delimiter=$'\x1f' --with-nth=3 \
    --header-lines=1 \
    --disabled --no-input --no-sort \
    --layout=reverse-list --info=hidden --border=none \
    --prompt='▸ ' \
    --header="$HDR" \
    "${PREVIEW[@]}" \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS)" \
    --bind "ctrl-r:reload(bash $ROWS)" \
    --bind "?:execute(tmux display-popup -E -w 72% -h 80% \"bash $BIN/fleet-keys.sh --context dash\")" \
    --bind "ctrl-g:execute(tmux display-popup -E -w 82% -h 72% \"bash $BIN/dash-issue-spawn.sh\")+reload(bash $ROWS)" \
    --bind "ctrl-n:execute(tmux display-popup -w 72 -h 12 -E \"bash $BIN/dash-issue-new.sh confirm --spawn\")+reload(bash $ROWS)" \
    --bind "ctrl-s:execute(tmux display-popup -w 72 -h 10 -E \"bash $BIN/dash-raw-session.sh --prompt-read\")+reload(bash $ROWS)" \
    --bind "ctrl-e:show-input+execute-silent(echo {1} > $C/rename_target)+transform-query(tmux display-message -t {1} -p '#W')+change-prompt(rename ▸ )" \
    --bind "ctrl-t:execute-silent(sh $BIN/dash-view-toggle.sh)+reload(bash $ROWS)" \
    --bind "ctrl-o:execute-silent(bash $BIN/dash-restore-session.sh {1})+reload(bash $ROWS)" \
    --bind "ctrl-p:execute-silent(bash $BIN/dash-open-pr.sh {1})" \
    --bind "ctrl-x:execute-silent(bash $BIN/dash-reap.sh {1})+reload(bash $ROWS)" \
    --bind "alt-x:execute(bash $BIN/dash-reap.sh {1} --force)+reload(bash $ROWS)" \
    --bind "ctrl-l:execute(tmux display-popup -E -w 72% -h 60% \"bash $BIN/dash-land.sh {1}\")+reload(bash $ROWS)" \
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
