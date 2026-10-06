#!/bin/bash
# fleet-human-menu.sh <action> <target> — the actions of a node's read-only
# right-click menu (conf/tmux-node-human.conf, issue #1840). Run by tmux
# (run-shell -b), so $TMUX names the right server and bare tmux reaches it.
#
#   copy  <pane-id>    this screen of the pane → the tmux buffer + the person's
#                      clipboard (load-buffer -w: OSC 52 through their terminal)
#   send  <window-id>  the text the prompt left in the window's @fleet_human_msg →
#                      that session, over fleet-peer-send.sh (a real delivery, never
#                      typed into the pane)
#   issue <window-id>  the window's bound issue, opened on the person's own computer
#                      (fleet-open.sh)
#   sweep              (run once at conf load) unbind every root / prefix key whose
#                      command deletes, respawns or renames the session — whatever
#                      this tmux version ships, whatever a personal conf bound
#
# Nothing here closes, restarts or renames anything. Every outcome is one
# display-message line; exit 0 unless the arguments are wrong.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
act="${1:-}"; t="${2:-}"
say() { tmux display-message -d 4000 "$1" 2>/dev/null; return 0; }
if [ "$act" = sweep ]; then
  for tbl in root prefix; do
    tmux list-keys -T "$tbl" 2>/dev/null \
      | grep -E 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session' \
      | awk '{ print $4 }' | while IFS= read -r k; do
          # list-keys escapes a special key (\$, \#); a bare `;` on tmux's own
          # command line is a separator, so that one keeps its backslash.
          case "$k" in '\;') ;; *) k=${k#\\} ;; esac
          tmux unbind-key -T "$tbl" -- "$k" 2>/dev/null
        done
  done
  exit 0
fi
[ -n "$t" ] || { echo "usage: fleet-human-menu.sh copy <pane> | send <window> | issue <window>" >&2; exit 2; }
case "$act" in
  copy)
    if tmux capture-pane -p -J -t "$t" 2>/dev/null | tmux load-buffer -w - 2>/dev/null; then say "已复制这一屏"
    else say "复制失败：读不到这个窗格"; fi ;;
  send)
    msg=$(tmux show-options -wqv -t "$t" @fleet_human_msg 2>/dev/null)
    tmux set-option -wu -t "$t" @fleet_human_msg 2>/dev/null
    [ -n "$msg" ] || { say "没有发：消息是空的"; exit 0; }
    if out=$(bash "$BIN/fleet-peer-send.sh" "$t" "$msg" 2>&1); then say "已发给 $(tmux display-message -p -t "$t" '#{window_name}' 2>/dev/null)"
    else say "没发出去：$(printf '%s' "$out" | tail -n 1)"; fi ;;
  issue)
    # shellcheck source=/dev/null
    . "$BIN/fleet-lib.sh"
    iss=$(tmux display-message -p -t "$t" '#{@issue}' 2>/dev/null)
    case "$iss" in ''|*[!0-9]*) say "这个会话没有绑定单子"; exit 0 ;; esac
    sess=$(tmux display-message -p -t "$t" "$FLEET_SESSION_FMT" 2>/dev/null)
    repo=$(fleet_window_repo "$sess" "$t" 2>/dev/null)
    if [ -z "$repo" ]; then fleet_load_conf "$sess" 2>/dev/null; repo="${FLEET_REPO:-}"; fi
    [ -n "$repo" ] || { say "#$iss：认不出它属于哪个仓库"; exit 0; }
    url="https://github.com/$repo/issues/$iss"
    if bash "$BIN/fleet-open.sh" "$url" >/dev/null 2>&1; then say "已在你的电脑上打开 #$iss"
    else say "#$iss：$url"; fi ;;
  *) echo "fleet-human-menu.sh: unknown action $act" >&2; exit 2 ;;
esac
exit 0
