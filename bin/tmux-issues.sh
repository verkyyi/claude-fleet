#!/bin/bash
# tmux-issues.sh [roadmap|unplanned|all] — GitHub backlog panel (open issues
# grouped by milestone), read from cache (the collector writes $C/issues).
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

# POPUP=1 → single shot for a tmux display-popup modal: esc closes; enter
# spawns the issue session AND closes. Without it, loop forever (window panes).
if [ -n "${POPUP:-}" ]; then ENTER_TAIL='+abort'; else ENTER_TAIL=''; fi

# Sub-actions that read input / show a viewer (⌃n new, ⌃t comment, ⌃x close,
# ⌃k keys) used to nest a `tmux display-popup` from inside this panel. When the
# panel itself already runs in a display-popup (prefix+b), that nested popup
# never opens, so the input is silently lost (issues #123/#122). Instead each of
# those binds ABORTS fzf and drops an intent sentinel; the loop below runs the
# action in the gap — directly in THIS shell (which owns the terminal), no
# nested popup — then relaunches fzf. Same non-nesting pattern the config modal's
# ⌃s uses (bin/tmux-config.sh). The phase-2 (`confirm`) path of each helper reads
# right here in the terminal, so we call it straight instead of via a popup.
ACT="${FLEET_C:-${TMPDIR:-/tmp}/.claude-dash}/issues_act_${FLEET_SESSION:-_}.$$"
mkdir -p "$(dirname "$ACT")" 2>/dev/null || true

run_fzf() {
  rm -f "$ACT"
  bash "$ROWS" "$MODE" | fzf --ansi --delimiter=$'\x1f' --with-nth=2 --nth=2 \
    --no-sort \
    --layout=reverse-list --info=hidden --border=rounded \
    --border-label="$LABEL" --border-label-pos=3 \
    --prompt='filter ▸ ' \
    --header='type=filter · enter=work · ⌃n=new · ⌃t=comment · ⌃x=close · ⌃p=preview · tab=collapse · ⌃o=web · ⌃r · ⌃k=keys · esc' \
    --preview "bash $BIN/tmux-issue-preview.sh {1}" \
    --preview-window='right,46%,wrap,border-left' \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS $MODE)" \
    --bind "ctrl-r:reload(bash $ROWS $MODE)" \
    --bind "ctrl-k:execute-silent(printf 'keys' > '$ACT')+abort" \
    --bind "ctrl-p:toggle-preview" \
    --bind "tab:execute-silent(bash $BIN/dash-toggle-collapse.sh {3})+reload(bash $ROWS $MODE)" \
    --bind "ctrl-o:execute-silent(bash $BIN/open-url.sh https://github.com/$REPO/issues/{1})" \
    --bind "ctrl-n:execute-silent(printf 'new' > '$ACT')+abort" \
    --bind "ctrl-t:execute-silent(printf 'comment %s' {1} > '$ACT')+abort" \
    --bind "ctrl-x:execute-silent(printf 'close %s' {1} > '$ACT')+abort" \
    --bind "enter:execute-silent(bash $BIN/dash-issue-session.sh {1})${ENTER_TAIL}" \
    >/dev/null 2>&1
}

# Run the pending sub-action (if any) in the gap between fzf runs. Returns 0 if
# it ran one (caller relaunches fzf), 1 if there was none — esc, or the enter
# spawn in POPUP mode, both of which leave no sentinel and should close.
run_action() {
  [ -s "$ACT" ] || return 1
  local act arg; read -r act arg < "$ACT"; rm -f "$ACT"
  case "$act" in
    new)     bash "$BIN/dash-issue-new.sh" confirm ;;
    keys)    bash "$BIN/fleet-keys.sh" ;;
    comment) bash "$BIN/dash-issue-comment.sh" "$arg" confirm ;;
    close)   bash "$BIN/dash-issue-close.sh" "$arg" confirm ;;
    *)       return 1 ;;
  esac
  return 0
}

if [ -n "${POPUP:-}" ]; then
  while :; do run_fzf; run_action || break; done
  rm -f "$ACT"; exit 0
fi
while :; do run_fzf; run_action || true; sleep 0.2; done
