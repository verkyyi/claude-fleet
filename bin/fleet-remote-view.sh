#!/bin/bash
# fleet-remote-view.sh — step into a session on ANOTHER machine from this one's
# sidebar (issue #1424, EPIC #1419 C5).
#
# The sidebar already SHOWS your sessions on the other machines (#1423: rows keyed
# `wid:<worker_id>`, drawn like the local ones — the machine is the row menu's
# title and the status line on top, #1475). Enter on one opens a PROXY WINDOW
# here — named `⇄m4 <name>` (#1475), so the window list and the pane header both
# say the keys go elsewhere — a window marked `@remote=<node>:<worker_id>` whose
# pane is an ssh client attached to that session's tmux window on <node>. Typing
# and scrolling are the remote window's own; closing the proxy window only drops
# the connection — the remote session never notices. A dropped connection
# reconnects by itself.
#
# It is a TASK WINDOW of this machine (issue #1475): the local sidebar treats a
# window with `@remote` like an issue worker's, so the list stays on the left and
# the other machine's pane is on the right — never the whole window gone remote,
# never two lists. `prefix h` (conf/tmux-attention.conf → `back`) returns to the
# last local window; ↑↓ in the list do too.
#
#   open <worker_id>        (dash Enter, in a fleet pane) — open the proxy window
#                           for the row's machine, or retarget + select the one
#                           already open: ONE proxy window per machine, because
#                           it is a client of that machine's one fleet session
#                           (one fleet per login), and two clients of one session
#                           share its current window.
#   run <node> <worker_id>  the proxy pane's program: connect, reconnect, report.
#   attach <worker_id> [<view>]   (runs ON <node>, over ssh) — select the worker's
#                           window and attach to its fleet session.
#   watch <view>            (runs ON <node>, over the same ssh connection) — the
#                           fleet-open back channel, below.
#   restore <sess> [--unless-view <tty>]   (ON <node>; also its client-attached
#                           hook) — hand the session its status line, prefix and
#                           sidebar back once the proxy leaves, or someone AT that
#                           machine attaches.
#   back [<session>]        (the local `prefix h`) — from a proxy window, select
#                           the last LOCAL window; anywhere else, nothing.
#
# WHY a client of the fleet session, not a grouped/linked session of its own:
# every fleet script scans `list-windows -a`, and a second session holding the
# same window lists it twice — fleet-peer-send would call the worker AMBIGUOUS
# for as long as the proxy is open. A plain client adds no winlink at all.
#
# Nesting: while the proxy is the remote session's ONLY client, it turns that
# session's status line and prefix off (saved, and restored when it leaves or
# when anyone else attaches) and marks the session `@remote_view_solo`, which
# that machine's sidebar reads as "draw no list" (fleet-sidebar.py sync, #1475)
# — so the remote looks like a local window, this machine's prefix reaches this
# machine, and the one list on screen is this machine's. With someone attached
# at the remote end, it changes nothing: that person keeps their status line,
# prefix and sidebar, and the proxy shows their sidebar beside the local one —
# two lists, the price of sharing a screen.
#
# fleet-open in the remote session (the operator's iTerm2 only trusts THIS
# machine's secret, and the escape would have to cross two tmux servers): the
# remote `attach` registers its client tty under a view id in
# $FLEET_CONF_DIR/remote-views/; fleet-open there sees its newest client is a
# view and drops the request in that view's spool instead of writing an escape.
# `watch` — a second session on the SAME ssh connection (ControlMaster) — prints
# each request as one JSON line, and this side re-issues it through the local
# fleet-open: a url as is; a page on <node>'s loopback through an `ssh -O forward`
# on the proxy's own connection (gone when the proxy closes), then `:<lport>/path`.
#
# Rails: off unless CCQUOTA_FLEET=1 (EPIC #1419 rule 1); proxy windows are skipped
# by every reaper, the sleeper and the migrator (rule 5) — see `fleet_is_remote_window`.
#
# Knobs (env, fleet.conf or the fleet's conf):
#   FLEET_REMOTE_SSH         `m4=m4-lan m5=macmini` — ssh host per machine label
#                            (default: the label itself, as ~/.ssh/config names it)
#   FLEET_REMOTE_BIN         the fleet's bin/ on the other machine, relative to its
#                            $HOME or absolute (default .claude/fleet/bin)
#   FLEET_REMOTE_VIA_HUB     1 (default) = after a failed direct attempt, try the
#                            hub relay (`fleet connect --proxy`, #1413) when one is
#                            configured; 0 = direct only
#   FLEET_REMOTE_SSH_CMD     (selftests) the ssh program
#   FLEET_REMOTE_OPENER      (selftests) what re-issues a request (fleet-open.sh)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# A non-interactive ssh session has a bare PATH: find tmux where Homebrew puts it.
command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VIEWS="$FLEET_CONF_DIR/remote-views"
mode="${1:-}"; [ $# -gt 0 ] && shift

note() { printf 'fleet-remote-view: %s\n' "$*" >&2; }

# ssh host for a machine label: FLEET_REMOTE_SSH, else the label itself.
ssh_host() {
  local n="$1" h
  h=$(printf '%s\n' ${FLEET_REMOTE_SSH:-} | awk -F= -v n="$n" '$1 == n { print $2; exit }')
  printf '%s' "${h:-$n}"
}
# The hub's name for a machine label: FLEET_NODE_ALIASES backwards (`macmini=m5`).
hub_node() {
  printf '%s\n' ${FLEET_NODE_ALIASES:-} | awk -F= -v n="$1" '$2 == n { print $1; f = 1; exit } END { if (!f) print n }'
}
hub_relay_ok() {
  [ "${FLEET_REMOTE_VIA_HUB:-1}" = 1 ] && [ -x "$BIN/fleet" ] || return 1
  [ -n "${FLEET_HUB_URL:-}" ] || [ -s "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" ]
}
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "$mode" in
# ---------------------------------------------------------------------------------
open)
  wid="${1#wid:}"
  sess="${FLEET_SESSION:-$(fleet_current_session)}"
  [ -n "$sess" ] || { note 'not inside a fleet'; exit 2; }
  fleet_load_conf "$sess" 2>/dev/null
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || exit 0
  _fleet_wid_split "$wid" >/dev/null || { note "not a worker_id: $wid"; exit 2; }
  # The row's machine + name, from the sidebar's own cache (never the network).
  row=$(LC_ALL=C awk -F $'\037' -v w="wid:$wid" '$1 == w { print $2 "\037" $8; exit }' \
        "$FLEET_C/global/remote_$sess" 2>/dev/null)
  node="${row%%$'\037'*}"; name="${row#*$'\037'}"
  [ -n "$node" ] || { tmux display-message "fleet: $wid 不在侧边栏的远程清单里" 2>/dev/null; exit 1; }
  case "$node" in *[!A-Za-z0-9._-]*) note "bad machine label: $node"; exit 2 ;; esac
  # `⇄m4 <name>` (issue #1475): the window name is also the pane header
  # (conf/tmux-attention.conf's pane-border-format), so the top of the pane says
  # at a glance that the keys go to another machine.
  title="⇄$node ${name:-${wid#*/}}"
  cmd="exec bash $(sq "$BIN/fleet-remote-view.sh") run $(sq "$node") $(sq "$wid")"
  w=$(tmux list-windows -t "=$sess" -F '#{window_id} #{@remote}' 2>/dev/null \
      | awk -v n="$node:" 'index($2, n) == 1 { print $1; exit }')
  if [ -n "$w" ]; then
    cur=$(tmux show-options -wqv -t "$w" @remote 2>/dev/null)
    if [ "$cur" != "$node:$wid" ]; then
      tmux set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
      tmux rename-window -t "$w" -- "$title" 2>/dev/null
      tmux respawn-pane -k -t "$w" -c "$HOME" "$cmd" 2>/dev/null
    fi
  else
    w=$(tmux new-window -d -P -F '#{window_id}' -t "=$sess:" -n "$title" -c "$HOME" "$cmd" 2>/dev/null) || exit 1
    tmux set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
    tmux set-window-option -t "$w" automatic-rename off 2>/dev/null
  fi
  tmux select-window -t "$w" 2>/dev/null
  printf '%s\n' "$w"
  ;;

# ---------------------------------------------------------------------------------
run)
  node="${1:-}"; wid="${2:-}"
  [ -n "$node" ] && [ -n "$wid" ] || { note 'usage: run <node> <worker_id>'; exit 2; }
  _s=$(fleet_current_session); [ -n "$_s" ] && fleet_load_conf "$_s" 2>/dev/null
  host=$(ssh_host "$node")
  rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
  SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"
  view="$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9-' '-')$$-$RANDOM"
  ctl="${TMPDIR:-/tmp}/frv.$$.$RANDOM"
  side=''
  cleanup() {
    [ -n "$side" ] && kill "$side" 2>/dev/null
    $SSH -S "$ctl" -O exit "$host" >/dev/null 2>&1
    rm -f "$ctl"
  }
  trap 'cleanup; exit 0' INT TERM HUP
  trap cleanup EXIT
  # The back channel: once the master connection is up, a second session on it
  # streams fleet-open requests made in the remote session; each is re-issued here.
  sidecar() {
    local _ up=''
    for _ in $(seq 1 50); do
      $SSH -S "$ctl" -O check "$host" >/dev/null 2>&1 && { up=1; break; }
      sleep 0.2
    done
    # No master: never let `-S` fall through to a second, independent login.
    [ -n "$up" ] || return 0
    $SSH -S "$ctl" "$host" "bash $rbin/fleet-remote-view.sh watch $(sq "$view")" 2>/dev/null \
      | python3 -c '
import json, socket, subprocess, sys
ssh, ctl, host, opener = sys.argv[1:5]
for line in sys.stdin:
    try:
        req = json.loads(line)
    except ValueError:
        continue
    if req.get("kind") == "url" and str(req.get("url", "")).startswith(("http://", "https://")):
        subprocess.call(["bash", opener, req["url"]], stdout=subprocess.DEVNULL)
    elif req.get("kind") == "forward" and str(req.get("rport", "")).isdigit():
        s = socket.socket(); s.bind(("127.0.0.1", 0)); lport = s.getsockname()[1]; s.close()
        if subprocess.call([ssh, "-S", ctl, "-O", "forward", "-L",
                            "127.0.0.1:%d:127.0.0.1:%s" % (lport, req["rport"]), host],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
            path = str(req.get("path") or "/")
            if not path.startswith("/"):
                path = "/" + path
            subprocess.call(["bash", opener, ":%d%s" % (lport, path)], stdout=subprocess.DEVNULL)
' "$SSH" "$ctl" "$host" "${FLEET_REMOTE_OPENER:-$BIN/fleet-open.sh}"
  }
  route=direct; delay=1
  while :; do
    printf '\033[2J\033[H→ %s (%s%s) …\n' "$node" "$host" "$( [ "$route" = hub ] && printf ' · 经入口中转')"
    opts=(-tt -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o ConnectTimeout=8
          -o ControlMaster=yes -o "ControlPath=$ctl" -o ControlPersist=no)
    [ "$route" = hub ] && opts+=(-o "ProxyCommand=$(sq "$BIN/fleet") connect --proxy $(sq "$(hub_node "$node")")")
    rm -f "$ctl"
    sidecar & side=$!
    started=$(date +%s)
    $SSH ${opts[@]+"${opts[@]}"} "$host" "bash $rbin/fleet-remote-view.sh attach $(sq "$wid") $(sq "$view")"
    rc=$?
    kill "$side" 2>/dev/null; side=''
    case "$rc" in
      0) exit 0 ;;                                   # the remote client ended on purpose
      3) printf '\n%s 已不在 %s 上（结束或搬走了）。按任意键关闭。\n' "${wid#*/}" "$node"
         read -r -n 1 -s _; exit 0 ;;
    esac
    # A drop after a good session reconnects at once; a failing route backs off and,
    # when the hub relay is configured, alternates with it.
    if [ $(( $(date +%s) - started )) -gt 30 ]; then delay=1
    else
      hub_relay_ok && { [ "$route" = direct ] && route=hub || route=direct; }
      [ "$delay" -lt 10 ] && delay=$(( delay * 2 ))
    fi
    printf '\n与 %s 的连接断了（exit %s），%ss 后重连 · Ctrl-C 关闭窗口\n' "$node" "$rc" "$delay"
    sleep "$delay"
  done
  ;;

# ---------------------------------------------------------------------------------
attach)
  wid="${1:-}"; view="${2:-}"
  loc=$(fleet_worker_locate "wid:${wid#wid:}" 2>/dev/null)
  case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; exit 3 ;; esac
  set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
  T() { tmux -L "$sock" "$@"; }
  # A proxy that died without restoring (a SIGKILL) left the marker: restore first.
  if [ -n "$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)" ] \
     && [ "$(T display-message -p -t "=$s:" '#{session_attached}' 2>/dev/null)" = 0 ]; then
    bash "$BIN/fleet-remote-view.sh" restore "$s"
  fi
  T select-window -t "$w" 2>/dev/null || { note "cannot select $w"; exit 3; }
  if [ "$(T display-message -p -t "=$s:" '#{session_attached}' 2>/dev/null)" = 0 ] \
     && [ -z "$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)" ]; then
    # Save what the SESSION itself sets (`-` = inherited) before turning them off.
    # Space-separated: an argument ENDING in `;` is a command separator to tmux.
    saved=''
    for o in status prefix prefix2; do
      v=$(T show-options -q -t "=$s:" "$o" 2>/dev/null | sed "s/^$o //")
      saved="$saved$o=${v:--} "
    done
    T set-option -t "=$s:" @remote_view_saved "$saved" \; \
      set-option -t "=$s:" status off \; set-option -t "=$s:" prefix None \; set-option -t "=$s:" prefix2 None \; \
      set-option -t "=$s:" @remote_view_solo 1 \; \
      set-hook -t "=$s:" 'client-attached[77]' "run-shell -b 'bash $(sq "$BIN/fleet-remote-view.sh") restore $(sq "$s") --unless-view #{client_tty} >/dev/null 2>&1'" 2>/dev/null
    # This session's sidebar goes (issue #1475): the proxy draws inside the
    # viewer's own sidebar, and a second list on the right would be noise. Not
    # FLEET_SIDEBAR — nothing is written to the conf; the marker above is what
    # fleet-sidebar.py reads, and `restore` drops it. The script wants $TMUX.
    TMUX="$(T display-message -p '#{socket_path}' 2>/dev/null),0,0" \
      bash "$BIN/fleet-sidebar.sh" sync "=$s:" >/dev/null 2>&1 || :
  fi
  if [ -n "$view" ] && tty=$(tty 2>/dev/null); then
    case "$view" in *[!A-Za-z0-9-]*) ;; *)
      mkdir -p "$VIEWS/$view.d" 2>/dev/null && printf '%s\t%s\n' "$tty" "$s" > "$VIEWS/$view" ;;
    esac
  fi
  # A dropped connection HUPs this shell too: outlive the client, then clean up.
  trap 'rc=129' HUP
  T attach-session -t "=$s"; rc=$?
  [ -n "$view" ] && rm -rf "${VIEWS:?}/$view" "${VIEWS:?}/$view.d" 2>/dev/null
  [ "$(T display-message -p -t "=$s:" '#{session_attached}' 2>/dev/null)" = 0 ] && bash "$BIN/fleet-remote-view.sh" restore "$s"
  exit "$rc"
  ;;

# ---------------------------------------------------------------------------------
restore)
  s="${1:-}"; [ -n "$s" ] || exit 2
  sock=$(fleet_socket "$s")
  T() { tmux -L "$sock" "$@"; }
  # The hook form: a proxy attaching is not a reason to restore; anyone else is.
  if [ "${2:-}" = --unless-view ]; then
    awk -F '\t' -v t="${3:-}" '$1 == t { f = 1 } END { exit !f }' "$VIEWS"/* 2>/dev/null && exit 0
  fi
  saved=$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)
  [ -n "$saved" ] || exit 0
  IFS=' ' read -r -a kv <<< "$saved"
  for p in ${kv[@]+"${kv[@]}"}; do
    o=${p%%=*}; v=${p#*=}
    case "$o" in status|prefix|prefix2) ;; *) continue ;; esac
    if [ "$v" = - ]; then T set-option -u -t "=$s:" "$o" 2>/dev/null
    else T set-option -t "=$s:" "$o" "$v" 2>/dev/null; fi
  done
  T set-option -u -t "=$s:" @remote_view_saved \; set-option -u -t "=$s:" @remote_view_solo \; \
    set-hook -u -t "=$s:" 'client-attached[77]' 2>/dev/null
  # The sidebar comes back with the rest (issue #1475): a sync now that the
  # solo marker is gone — a no-op while nobody is attached.
  TMUX="$(T display-message -p '#{socket_path}' 2>/dev/null),0,0" \
    bash "$BIN/fleet-sidebar.sh" sync "=$s:" >/dev/null 2>&1 || :
  exit 0
  ;;

# ---------------------------------------------------------------------------------
back)
  # From a proxy window, back to the last LOCAL window (issue #1475): the one the
  # row was clicked from, as a rule — never another proxy; failing that, the
  # first local window. Anywhere else: nothing (the key is a no-op there).
  t="${1:-}"; [ -n "$t" ] || t=$(tmux display-message -p '#{session_id}' 2>/dev/null)
  [ -n "$t" ] || exit 0
  cur=$(tmux display-message -p -t "$t:" '#{window_id}' 2>/dev/null)
  [ -n "$cur" ] && [ -n "$(tmux show-options -wqv -t "$cur" @remote 2>/dev/null)" ] || exit 0
  w=$(tmux list-windows -t "$t" -F '#{window_last_flag} #{window_id} #{@remote}' 2>/dev/null \
      | awk '$1 == 1 && $3 == "" { print $2; exit }')
  [ -n "$w" ] || w=$(tmux list-windows -t "$t" -F '#{window_id} #{@remote}' 2>/dev/null \
                     | awk '$2 == "" { print $1; exit }')
  [ -n "$w" ] && tmux select-window -t "$w" 2>/dev/null
  exit 0
  ;;

# ---------------------------------------------------------------------------------
watch)
  view="${1:-}"
  case "$view" in ''|*[!A-Za-z0-9-]*) exit 2 ;; esac
  d="$VIEWS/$view.d"
  # Wait for attach to register, then stream: one JSON line per request, oldest
  # first, deleted once printed. A broken pipe (the proxy went away) ends it.
  for _ in $(seq 1 50); do [ -d "$d" ] && break; sleep 0.2; done
  while [ -d "$d" ]; do
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      tr -d '\n' < "$f" && printf '\n' || exit 0
      rm -f "$f"
    done
    sleep 0.5
  done
  ;;

*)
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2 ;;
esac
