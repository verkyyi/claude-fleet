#!/bin/bash
# tmux-issues.sh [roadmap|unplanned|all] — GitHub backlog panel (open issues
# grouped by milestone), read from cache (the collector writes $C/issues).
# Enter on an issue spawns a Claude session to work on it (worktree + claude
# seeded with the issue). Auto-reloads. Toggled as a two-pane window by
# prefix+b: roadmap (milestoned) | unplanned (no milestone).
REFRESH="${REFRESH:-8}"
MODE="${1:-all}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
REPO="${FLEET_REPO:-}"
ROWS="$BIN/tmux-issues-rows.sh"
command -v fzf >/dev/null 2>&1 || { echo "fzf required"; sleep 5; exit 1; }
case "$MODE" in roadmap) LABEL=' roadmap · milestoned ';; unplanned) LABEL=' unplanned · no milestone ';; *) LABEL=' backlog · GitHub issues ';; esac
while :; do
  bash "$ROWS" "$MODE" | fzf --ansi --delimiter=$'\x1f' --with-nth=2 --nth=2 \
    --no-sort \
    --layout=reverse-list --info=hidden --border=rounded \
    --border-label="$LABEL" --border-label-pos=3 \
    --prompt='filter ▸ ' \
    --header='type=filter · enter=work issue · tab=collapse group · ⌃o=web · ⌃r · esc' \
    --preview-window=hidden \
    --bind "load:reload-sync(sleep $REFRESH; bash $ROWS $MODE)" \
    --bind "ctrl-r:reload(bash $ROWS $MODE)" \
    --bind "tab:execute-silent(bash $BIN/dash-toggle-collapse.sh {3})+reload(bash $ROWS $MODE)" \
    --bind "ctrl-o:execute-silent(gh issue view {1} --repo $REPO --web)" \
    --bind "enter:execute-silent(bash $BIN/dash-issue-session.sh {1})" \
    >/dev/null 2>&1
  sleep 0.2
done
