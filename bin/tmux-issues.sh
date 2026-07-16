#!/bin/bash
# tmux-issues.sh [roadmap|unplanned|all] — GitHub backlog panel (open issues
# grouped by milestone), read from THIS fleet's cache via fleet_cache (the
# collector writes $C/issues_<slug> per fleet; no flat mirror — issue #180).
# Enter on an issue spawns a Claude session to work on it (worktree + claude
# seeded with the issue). Auto-reloads. Toggled as a two-pane window by
# prefix+b: roadmap (milestoned) | unplanned (no milestone).
set -uo pipefail
REFRESH="${REFRESH:-8}"
MODE="${1:-all}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
REPO="${FLEET_REPO:-}"
# multi-fleet: this panel shows the CURRENT fleet's (tmux session's) backlog.
# Resolve the session → repo from the collector's sessmap; export FLEET_SESSION
# so the rows producer (and its reload-binds) read the right issues cache.
FLEET_SESSION=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
[ -z "$FLEET_SESSION" ] && FLEET_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
export FLEET_SESSION
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
ROWS="$BIN/tmux-issues-rows.sh"
command -v fzf >/dev/null 2>&1 || { echo "fzf required"; sleep 5; exit 1; }
case "$MODE" in roadmap) LABEL=' roadmap · milestoned ';; unplanned) LABEL=' unplanned · no milestone ';; *) LABEL=' backlog · GitHub issues ';; esac

# The ⌃n new · ⌃x close · ? keys sub-actions each open a small
# `tmux display-popup` (input dialog / cheatsheet). That works from a windowed
# panel, but NOT when the backlog itself already runs in a display-popup
# (prefix+b): tmux won't nest a popup inside a popup, so the dialog never opens
# and the input is silently lost (issues #123/#122).
#
# So the binds are POPUP-conditional:
#   • windowed (no POPUP): keep the original in-place binds — nesting a popup is
#     fine here, and fzf's +reload/+refresh-preview preserve the filter/cursor.
#   • POPUP: each sub-action drops an intent sentinel + ABORTs fzf; the loop
#     below runs it in the gap — directly in THIS shell, which owns the terminal,
#     no nested popup — then relaunches fzf. Same non-nesting pattern the config
#     modal's ⌃s uses (bin/tmux-config.sh). Each helper's phase-2 (`confirm`)
#     path reads right here in the terminal, so we call it straight.
# Also: in POPUP mode enter spawns AND closes (+abort); windowed loops forever.
# enter passes --async (issue #303): dash-issue-session.sh runs its synchronous
# gate (cap / dedup / claim — refusals still surface instantly) then backgrounds the
# slow `git worktree add` + window spawn via `run-shell -b`, so fzf's execute-silent
# returns at once and the popup closes without freezing on a big-monorepo checkout.
# The header is deliberately terse — the essential action (enter=work), the
# common one (⌃n new), and a pointer to the full keymap (? keys), matching the
# dashboard's `↵ jump · ⌃n new · … · ? keys` grammar (one `?` convention
# everywhere, issue #289). Every other bind lives in the `?` cheatsheet
# (bin/fleet-keys.sh) rather than crowding this line.
# Lead the header with a live "slots N/8" chip (issue #331) so the GLOBAL session
# cap's fullness is visible BEFORE an Enter that the cap would silently refuse.
# Reuses the cross-fleet count in fleet-lib.sh (pure tmux+awk, no network on
# render); recomputed each time the panel (re)opens, so it is current at the
# moment you go to spawn. fzf colorizes it via --ansi.
SLOTS=$(fleet_slots_chip)
HDR="$SLOTS · ↵ work · ⌃n new · ? keys"
ACT="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/global/issues_act_${FLEET_SESSION:-_}.$$"
if [ -n "${POPUP:-}" ]; then
  ENTER_TAIL='+abort'
  # POPUP only: a tappable ✕ close for iPad/Termius, where Escape is a reach
  # (issue #346). The click-header bind in run_fzf aborts when the ✕/close header
  # word is tapped; abort closes the popup (windowed panes just reopen, so the ✕
  # token is popup-only and the bind is inert there — no matching header word).
  HDR="$HDR · esc · ✕ close"
  mkdir -p "$(dirname "$ACT")" 2>/dev/null || true
  N_BIND="ctrl-n:execute-silent(printf 'new' > '$ACT')+abort"
  X_BIND="ctrl-x:execute-silent(printf 'close %s' {1} > '$ACT')+abort"
  K_BIND="?:execute-silent(printf 'keys' > '$ACT')+abort"
else
  ENTER_TAIL=''
  N_BIND="ctrl-n:execute(bash $BIN/dash-issue-new.sh)+reload(sleep 2; bash $ROWS $MODE)"
  X_BIND="ctrl-x:execute-silent(bash $BIN/dash-issue-close.sh {1})+reload(sleep 2; bash $ROWS $MODE)"
  K_BIND="?:execute(tmux display-popup -E -w 72% -h 80% \"bash $BIN/fleet-keys.sh --context backlog\")"
fi

# Prepend a dim column-title line (issue #371) so field-2's fixed columns read as
# a table. fzf --header accepts multiple lines; this becomes the FIRST header line
# (in --layout=reverse-list it sits directly under the rows), with the hint line
# below it. fleet_backlog_col_header aligns the # / pri / owner / title labels to
# the SAME FLEET_BL_W_* widths the rows use (bin/tmux-issues-rows.sh) — the header
# is NOT subject to --with-nth=2, so alignment is to the visible columns by hand
# there; backlog-header-cols-selftest.sh pins the two in step.
HDR="$(fleet_backlog_col_header)"$'\n'"$HDR"

# Priority cycle (⌃y): raises the highlighted issue's priority:pN label one step
# and wraps (none→p2→p1→p0→none). It takes NO text input, so — unlike ⌃n/⌃x —
# it needs no popup and uses ONE bind in both windowed + popup modes (execute-silent
# blocks fzf until the label edit + optimistic cache write finish, so the reload
# repaints with the fresh tag). {1} is the row's issue number.
P_BIND="ctrl-y:execute-silent(bash $BIN/dash-issue-priority.sh {1} cycle)+reload(bash $ROWS $MODE)"

# The panel is list-only by default (search off, issue #156). `--no-input` also
# DROPS the query/prompt input row entirely (issue #361) — one less line of
# chrome on small/iPad screens, and it never gets typed into by mistake. `/`
# reveals it on demand: show-input un-hides the row, enable-search turns the
# (still --disabled) filter on, change-prompt relabels it. esc closes the panel;
# reopening (windowed loop / prefix+b) starts fresh with the row hidden again.
run_fzf() {
  rm -f "$ACT"
  bash "$ROWS" "$MODE" | fzf --ansi --delimiter=$'\x1f' --with-nth=2 --nth=2 \
    --no-sort --disabled --no-input \
    --layout=reverse-list --info=hidden --border=rounded \
    --border-label="$LABEL" --border-label-pos=3 \
    --prompt='backlog ▸ ' \
    --header="$HDR" \
    --preview "bash $BIN/tmux-issue-preview.sh {1}" \
    --preview-window='right,46%,wrap,border-left,hidden' \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS $MODE)" \
    --bind "ctrl-r:reload(bash $ROWS $MODE)" \
    --bind "$K_BIND" \
    --bind "space:toggle-preview" \
    --bind "/:show-input+enable-search+change-prompt(filter ▸ )" \
    --bind "tab:execute-silent(bash $BIN/dash-toggle-collapse.sh {3})+reload(bash $ROWS $MODE)" \
    --bind "ctrl-o:execute-silent(bash $BIN/open-url.sh https://github.com/$REPO/issues/{1})" \
    --bind "$N_BIND" \
    --bind "$X_BIND" \
    --bind "$P_BIND" \
    --bind "enter:execute-silent(bash $BIN/dash-issue-session.sh {1} --async)${ENTER_TAIL}" \
    --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in ✕|close) echo abort ;; esac' \
    >/dev/null 2>&1
}

# POPUP only: run the pending sub-action (if any) in the gap between fzf runs.
# Returns 0 if it ran one (caller relaunches fzf), 1 if there was none — esc, or
# the enter spawn, both of which leave no sentinel and should close the popup.
run_action() {
  [ -s "$ACT" ] || return 1
  local act arg; read -r act arg < "$ACT"; rm -f "$ACT"
  case "$act" in
    new)     bash "$BIN/dash-issue-new.sh" confirm ;;
    keys)    bash "$BIN/fleet-keys.sh" --context backlog ;;
    close)   bash "$BIN/dash-issue-close.sh" "$arg" confirm ;;
    *)       return 1 ;;
  esac
  return 0
}

if [ -n "${POPUP:-}" ]; then
  while :; do run_fzf; run_action || break; done
  rm -f "$ACT"; exit 0
fi
# Windowed panes: the sub-actions run in-place via their own binds, so there is
# no sentinel to dispatch — just re-run fzf forever (esc reopens it).
while :; do run_fzf; sleep 0.2; done
