#!/bin/bash
# fleet-remote-view.sh — step into a session on ANOTHER machine from this one's
# sidebar (issue #1424, EPIC #1419 C5).
#
# The sidebar already SHOWS your sessions on the other machines (#1423: rows keyed
# `wid:<worker_id>`, drawn like the local ones — the machine is the row menu's
# title and the status line on top, #1475). Enter on one opens a PROXY WINDOW
# here — named `m4 <name>` (#1475; no ⇄ since #1621), so the window list and the
# pane header both say the keys go elsewhere — a window marked `@remote=<node>:<worker_id>` whose
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
#                           (one fleet per login).
#   run [--shell] <node> <worker_id>  the proxy pane's program: connect, reconnect,
#                           report (`--shell` is passed through to `attach`). A
#                           <worker_id> of `-` is the machine itself: its fleet
#                           session as it stands, no window selected (the shell's
#                           first window, issue #1484). The pane's window carries
#                           `@remote_ctl` — the ssh ControlPath of its connection —
#                           so `open` can retarget it without reconnecting.
#   attach [--shell] <worker_id> [<view>]   (runs ON <node>, over ssh — or on the
#                           node itself, nested in the shell's own tmux) — select
#                           the worker's window and attach to its fleet session
#                           (`-`: attach the login's fleet session, select nothing).
#                           `--shell` registers this client as a SHELL client
#                           (C5's `fleet` shell, issue #1485); a <view> id
#                           registers it as a proxy VIEW with a fleet-open spool.
#                           A registered client attaches to a VIEW SESSION of its
#                           own (issue #1489, below), a plain one to the fleet's.
#   select <worker_id> [<view>]  (runs ON <node>, over the proxy's own ssh
#                           connection, issue #1484) — select the worker's window
#                           in the proxy's view session (its <view> id; the fleet
#                           session when none is named or live), which that proxy
#                           then shows: how `open` moves an open proxy window to
#                           another row of the SAME machine, with no reconnect.
#                           Exit 3 when the worker is not live here.
#   watch <view>            (runs ON <node>, over the same ssh connection) — the
#                           fleet-open back channel, below.
#   sessions                (runs ON <node>, over the same ssh connection; issue
#                           #1488) — this machine's sessions in the hub's own
#                           fleet_sessions shape, one JSON object on stdout, so a
#                           shell whose hub is silent can take this machine's rows
#                           over the connection it already holds. The rows are the
#                           control adapter's inventory keyed by the hub's own rule
#                           (fleet_hub_common.worker_key) — never a second generator.
#   reconcile <sess>        (ON <node>) — retired with the rule (issue #1713):
#   restore <sess>          both undo what an OLDER version left on <sess> — its
#                           hidden status line / prefix, the solo marker, the
#                           server's [77] hooks — and nothing else.
#   back [<session>]        (the local `prefix h`) — from a proxy window, select
#                           the last LOCAL window; anywhere else, nothing.
#
# ONE VIEW SESSION PER REGISTERED CLIENT (issue #1489, EPIC #1479 R4): a tmux
# session has one current window, so two shells on the fleet session kept
# switching each other away. `attach` with `--shell` or a <view> id makes the
# client a GROUPED session of its own — `new-session -t <fleet>`, named
# `<fleet>@view-<id>` — the fleet's windows, its own current window, status line
# and prefix off for good (the person's own tmux has both), destroyed with its
# client (`destroy-unattached`, armed in the attach command itself, plus the
# attach's own kill-session). A plain `attach` — a person on the node — stays a
# client of the fleet session, as before. #1424 settled for a plain client
# because a second session holding the same windows lists each twice in
# `list-windows -a` and fleet-peer-send called the worker AMBIGUOUS; the fleet's
# scans now go through fleet_lw (fleet-lib.sh), which drops the view sessions'
# rows, and every window→session read uses FLEET_SESSION_FMT, which names the
# fleet from a view session too. `select` targets the proxy's own view session,
# so one proxy's retarget moves nobody else's screen.
#
# Nesting — NO rule (issue #1713, EPIC #1710 C3; #1485's rule retired): the
# node never makes way for a viewer, because it has nothing of its own to hide.
# The list is drawn only on the CLIENT's server (fleet-sidebar.sh, FLEET_SHELL=1);
# a node fleet session draws none, so a viewer arriving or leaving changes no
# pane on the node. A shell/view client attaches to its own VIEW SESSION (below)
# with that session's status line and prefix off for good. The one thing a
# window carries for everyone is its top header (pane-border-status, a WINDOW
# option): a window a shell/view looks at loses it ONE WAY (issue #1549 — the
# viewer's `m4 …` header is the one title line) and never gets it back, so no
# client change ever resizes a pane. Never `resize-pane -Z`.
#
# The registry $FLEET_CONF_DIR/remote-views/<id>: one line per client,
# `<tty> <session> <kind=shell|view> <since epoch> <pid>` (tab-separated — the
# first two columns are what fleet-open.sh reads). A row whose attach shell is
# gone (SIGKILLed before its cleanup) does not count and is pruned at the next
# attach, so a tty the next login reuses is never mistaken for a shell.
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
# THE SHELL (issue #1484, EPIC #1479 C5): bin/fleet-shell.sh runs this very
# machinery on a person's own computer — its tmux server holds one proxy window
# per machine and nothing else. It sets FLEET_SHELL=1 in that server's environment,
# and that is the only difference `open` sees: the pane it starts runs `run --shell`,
# so the far end registers a SHELL client (#1485) on a view session of its own.
#
# Knobs (env, fleet.conf or the fleet's conf):
#   FLEET_REMOTE_SSH         `m4=m4-lan m5=macmini` — ssh host per machine label
#                            (default: the label itself, as ~/.ssh/config names it)
#   FLEET_REMOTE_BIN         the fleet's bin/ on the other machine, relative to its
#                            $HOME or absolute (default .claude/fleet/bin)
#   FLEET_REMOTE_VIA_HUB     1 (default) = after a failed direct attempt, try the
#                            hub relay (`fleet connect --proxy`, #1413) when one is
#                            configured; 0 = direct only
#   FLEET_CONNECT_UPGRADE_SECS  15 — on the hub relay in the shell, how often one
#                            direct handshake is tried (`fleet connect
#                            --probe-direct`); one answers → the pane switches to
#                            it once no key has been pressed for
#                            FLEET_REMOTE_IDLE_SECS (2). The window carries
#                            `@remote_route relay` while on the relay (the bar's
#                            「· 中转」, issue #1628)
#   FLEET_REMOTE_SSH_CMD     (selftests) the ssh program
#   FLEET_CONNECT_PROBE_CMD  (selftests) the direct probe, given the host
#   FLEET_REMOTE_OPENER      (selftests) what re-issues a request (fleet-open.sh)
#
# Machine to machine (issue #1626): with plain ssh on a hub node, every connect
# first asks the hub for a five-minute certificate to that machine
# (fleet-peer-cert.sh) — no standing key in the far end's authorized_keys is
# needed or used; a hub that says no or is down pauses the view and says why.
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
T() { tmux -L "$sock" "$@"; }   # the REMOTE fleet's server; each mode sets $sock first

# --- the registry (issue #1485) ---------------------------------------------------
# Live rows of the registry: `<tty> <session> <kind> <since> <pid>`. A row whose
# attach shell is gone does not count; a row without a pid (written by an older
# attach) is trusted as before.
rv_registry() {
  local f tty sess kind since pid
  for f in "$VIEWS"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r tty sess kind since pid < "$f" || :
    [ -n "$tty" ] || continue
    case "${pid:-}" in '') ;; *[!0-9]*) continue ;; *) kill -0 "$pid" 2>/dev/null || continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$sess" "${kind:-view}" "${since:-}" "${pid:-}"
  done
}
# Drop the rows (and spools) whose attach shell is gone: a SIGKILL skipped its
# cleanup, and the next login may get that very tty.
rv_prune() {
  local f tty sess kind since pid g v
  for f in "$VIEWS"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r tty sess kind since pid < "$f" || :
    case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -rf "$f" "$f.d"
  done
  # A view session with no client (issue #1489): destroy-unattached takes it when
  # its client goes; this is the belt for one left detached by an attach that
  # died first. Never one a live attach has registered and is about to join.
  for g in $(T list-sessions -F '#{?#{session_attached},,#{session_name}}' 2>/dev/null); do
    fleet_is_view_session "$g" || continue
    v=${g#*@view-}
    [ -f "$VIEWS/$v" ] && kill -0 "$(cut -f5 "$VIEWS/$v" 2>/dev/null)" 2>/dev/null && continue
    T kill-session -t "=$g" 2>/dev/null
  done
}
# A window a shell/view looks at loses its own top header, ONE WAY (issues #1549,
# #1713): the viewer's `m4 …` header is the one title line, and since it never
# comes back no client arriving or leaving resizes a pane on this machine.
rv_hide_border() {   # <window-id>
  [ "$(T show-options -wqv -t "$1" pane-border-status 2>/dev/null)" = off ] ||
    T set-option -w -t "$1" pane-border-status off 2>/dev/null
}
rv_hide_borders() {
  local w
  for w in $(T list-windows -t "=$1" -F '#{window_id}' 2>/dev/null); do rv_hide_border "$w"; done
}
# What an OLDER version's rule (#1475/#1485, retired in #1713) left on a session:
# its status line + prefix hidden (the originals saved in `@remote_view_saved`,
# `-` = inherited), `@remote_view_solo`, a window's saved header, the server's
# GLOBAL `client-attached[77]` / `client-detached[77]` hooks, and a session-level
# hook array #1475 set (even an emptied one shadows the fleet's own [71]–[73]).
# Undone once, on the next attach (or `restore`); with none of it, a no-op. A
# window's header stays off: that is the one-way rule above, not a leftover.
rv_legacy_undo() {
  local s="$1" saved o v p w h
  for h in client-attached client-detached; do
    T show-hooks -g 2>/dev/null | grep -q "^$h\[77\]" && T set-hook -gu "${h}[77]" 2>/dev/null
    T show-hooks -t "=$s:" 2>/dev/null | grep -q "^$h" || continue
    T show-hooks -t "=$s:" 2>/dev/null | grep "^$h\[" | grep -qv "^$h\[77\]" && continue   # someone else's: leave it
    T set-hook -u -t "=$s:" "$h" 2>/dev/null
  done
  for w in $(T list-windows -t "=$s" -F '#{window_id}' 2>/dev/null); do
    [ -z "$(T show-options -wqv -t "$w" @remote_view_saved 2>/dev/null)" ] ||
      T set-option -wu -t "$w" @remote_view_saved 2>/dev/null
  done
  saved=$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)
  [ -n "$saved$(T show-options -qv -t "=$s:" @remote_view_solo 2>/dev/null)" ] || return 0
  IFS=' ' read -r -a kv <<< "$saved"
  for p in ${kv[@]+"${kv[@]}"}; do
    o=${p%%=*}; v=${p#*=}
    case "$o" in status|prefix|prefix2) ;; *) continue ;; esac
    if [ "$v" = - ]; then T set-option -u -t "=$s:" "$o" 2>/dev/null
    else T set-option -t "=$s:" "$o" "$v" 2>/dev/null; fi
  done
  T set-option -u -t "=$s:" @remote_view_saved \; set-option -u -t "=$s:" @remote_view_solo 2>/dev/null
}
# rv_select <worker_id> [<view>] — the worker's window becomes the current one of
# the view session (the fleet session when none is named or live). 3 = not live
# here. A window found once is remembered for the life of this process (`serve`
# answers every row of one connection) as `<wid> <window> <sess> <@fleet_id>`
# and re-checked by its identity — a window that no longer carries that
# @fleet_id (closed, recycled) is located afresh, the 61 ms fleet_worker_locate
# paid once per row, not per click (issue #1682).
RV_SEEN=''
rv_select() {
  local wid="${1#wid:}" view="${2:-}" hit loc fid tgt w='' s=''
  hit=$(printf '%s\n' "$RV_SEEN" | awk -v k="$wid" '$1 == k { print $2, $3, $4; exit }')
  if [ -n "$hit" ]; then
    set -- $hit; sock=$(fleet_socket "$2")
    [ "$(T display-message -p -t "=$2:$1" '#{@fleet_id}' 2>/dev/null)" = "$3" ] && { w=$1; s=$2; }
  fi
  if [ -z "$w" ]; then
    loc=$(fleet_worker_locate "wid:$wid" 2>/dev/null)
    case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; return 3 ;; esac
    set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
    fid=$(T display-message -p -t "=$s:$w" '#{@fleet_id}' 2>/dev/null)
    RV_SEEN=$(printf '%s\n' "$RV_SEEN" | awk -v k="$wid" '$1 != k && NF')
    [ -n "$fid" ] && RV_SEEN="$RV_SEEN
$wid $w $s $fid"
  fi
  tgt="$s"
  case "$view" in ''|*[!A-Za-z0-9-]*) ;; *) T has-session -t "=$s@view-$view" 2>/dev/null && tgt="$s@view-$view" ;; esac
  T select-window -t "=$tgt:$w" 2>/dev/null || { note "cannot select $w"; return 3; }
  rv_hide_border "$w"   # a window spawned since the attach (#1549, #1682)
  return 0
}
# rv_chan_select <chan> <worker_id> — `select` over a proxy's `serve` channel
# (issue #1682). 0 = selected there; anything else (no channel, not live there,
# no answer in 2 s) = the caller's one-shot path, which also says why.
rv_chan_select() {
  local c="$1" nonce n r rc=1
  [ -p "$c.cmd" ] && [ -p "$c.ack" ] || return 1
  nonce="o$$-$RANDOM"
  exec 7<>"$c.ack" 8<>"$c.cmd" || return 1
  printf '%s select %s\n' "$nonce" "$2" >&8
  # Answers to an earlier, abandoned request may come first: skip to ours.
  for _ in 1 2 3 4 5 6 7 8; do
    read -r -t 2 -u 7 n r || break
    [ "$n" = "$nonce" ] && { rc=$r; break; }
  done
  exec 7<&- 8>&-
  [ "$rc" = 0 ]
}

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
  # `m4 <name>` (issue #1475): the window name is also the pane header
  # (conf/tmux-attention.conf's pane-border-format), so the top of the pane says
  # at a glance that the keys go to another machine. The machine's name alone
  # carries it — no ⇄ (issue #1621): a proxy window is known by `@remote`, never
  # by its name.
  title="$node ${name:-${wid#*/}}"
  shellopt=''; [ "${FLEET_SHELL:-0}" = 1 ] && shellopt=' --shell'   # the shell's panes (#1484)
  cmd="exec bash $(sq "$BIN/fleet-remote-view.sh") run$shellopt $(sq "$node") $(sq "$wid")"
  w=$(tmux list-windows -t "=$sess" -F '#{window_id} #{@remote}' 2>/dev/null \
      | awk -v n="$node:" 'index($2, n) == 1 { print $1; exit }')
  if [ -n "$w" ]; then
    cur=$(tmux show-options -wqv -t "$w" @remote 2>/dev/null)
    if [ "$cur" != "$node:$wid" ]; then
      # Another row of the SAME machine (issue #1484): over the proxy's own ssh
      # connection (`@remote_ctl`, the ControlMaster `run` holds), select that
      # worker's window there — the proxy, a client of that session, follows at
      # once. No master up, or the worker not live there: reconnect, as before.
      # Fastest first (issue #1682): the `serve` channel `run` keeps open on that
      # connection (`@remote_chan`) — one round trip, nothing started at either end.
      ctl=$(tmux show-options -wqv -t "$w" @remote_ctl 2>/dev/null)
      rview=$(tmux show-options -wqv -t "$w" @remote_view 2>/dev/null)   # its view session (#1489)
      chn=$(tmux show-options -wqv -t "$w" @remote_chan 2>/dev/null)
      SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"; host=$(ssh_host "$node"); rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
      if [ -n "$chn" ] && rv_chan_select "$chn" "$wid"; then
        tmux set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
        tmux rename-window -t "$w" -- "$title" 2>/dev/null
      elif [ -n "$ctl" ] && [ -S "$ctl" ] && $SSH -S "$ctl" -O check "$host" >/dev/null 2>&1 \
         && $SSH -S "$ctl" "$host" "bash $rbin/fleet-remote-view.sh select $(sq "$wid")${rview:+ $(sq "$rview")}" >/dev/null 2>&1; then
        tmux set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
        tmux rename-window -t "$w" -- "$title" 2>/dev/null
      else
        tmux set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
        tmux rename-window -t "$w" -- "$title" 2>/dev/null
        tmux respawn-pane -k -t "$w" -c "$HOME" "$cmd" 2>/dev/null
      fi
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
  shellopt=''; [ "${1:-}" = --shell ] && { shellopt=' --shell'; shift; }
  node="${1:-}"; wid="${2:-}"
  [ -n "$node" ] && [ -n "$wid" ] || { note 'usage: run [--shell] <node> <worker_id>'; exit 2; }
  _s=$(fleet_current_session); [ -n "$_s" ] && fleet_load_conf "$_s" 2>/dev/null
  host=$(ssh_host "$node")
  rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
  SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"
  view="$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9-' '-')$$-$RANDOM"
  ctl="${TMPDIR:-/tmp}/frv.$$.$RANDOM"
  # The window knows its connection (issue #1484) and its view id (issue #1489):
  # `open` retargets through the one, in the far end's view session named by the other.
  [ -n "${TMUX:-}" ] && tmux set-window-option -t "${TMUX_PANE:-}" @remote_ctl "$ctl" \; \
                             set-window-option -t "${TMUX_PANE:-}" @remote_view "$view" 2>/dev/null
  side='' upg='' chn=''
  stop_bg() {   # the sidecar, the upgrader, the channel, and whatever they are waiting in
    local p
    for p in $side $upg $chn; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    side='' upg='' chn=''
    [ -n "${TMUX:-}" ] && tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_chan 2>/dev/null
    rm -f "$ctl.cmd" "$ctl.ack"
  }
  cleanup() {
    stop_bg
    $SSH -S "$ctl" -O exit "$host" >/dev/null 2>&1   # our own master only — never the warm one (#1631)
    rm -f "$ctl" "$ctl.route" "$ctl.upgrade"
    [ "$use" = "$ctl" ] || rm -f "$use.upgrade"
  }
  use="$ctl"   # the master this round rides: ours, or the shell's warm one (#1631)
  trap 'cleanup; exit 0' INT TERM HUP
  trap cleanup EXIT
  # The back channel: once the master connection is up, a second session on it
  # streams fleet-open requests made in the remote session; each is re-issued here.
  sidecar() {
    local _ up=''
    for _ in $(seq 1 50); do
      $SSH -S "$use" -O check "$host" >/dev/null 2>&1 && { up=1; break; }
      sleep 0.2
    done
    # No master: never let `-S` fall through to a second, independent login.
    [ -n "$up" ] || return 0
    $SSH -S "$use" "$host" "bash $rbin/fleet-remote-view.sh watch $(sq "$view")" 2>/dev/null \
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
' "$SSH" "$use" "$host" "${FLEET_REMOTE_OPENER:-$BIN/fleet-open.sh}"
  }
  # The forward channel (issue #1682): a third session on the same master runs the
  # far end's `serve` for as long as the connection lives, its stdin/stdout two
  # FIFOs beside the control socket (`$ctl.cmd` / `$ctl.ack`, both opened
  # read-write so neither side ever blocks on an open or sees an EOF). Once a
  # `ping` comes back the window carries `@remote_chan` = "$ctl" and `open`
  # retargets through it: one ssh round trip, no new session, no remote bash.
  # An older far end with no `serve` never answers the ping — no `@remote_chan`,
  # and `open` keeps the one-shot `select`.
  chan() {
    local _ up='' n r sp
    [ -n "${TMUX:-}" ] || return 0
    for _ in $(seq 1 50); do
      $SSH -S "$use" -O check "$host" >/dev/null 2>&1 && { up=1; break; }
      sleep 0.2
    done
    [ -n "$up" ] || return 0
    rm -f "$ctl.cmd" "$ctl.ack"
    mkfifo "$ctl.cmd" "$ctl.ack" 2>/dev/null || return 0
    $SSH -S "$use" "$host" "bash $rbin/fleet-remote-view.sh serve $(sq "$view")" \
      0<>"$ctl.cmd" 1<>"$ctl.ack" 2>/dev/null &
    sp=$!
    exec 7<>"$ctl.ack" 8<>"$ctl.cmd"
    printf 'hello ping -\n' >&8
    if read -r -t 10 -u 7 n r && [ "$n" = hello ] && [ "$r" = 0 ]; then
      tmux set-window-option -t "${TMUX_PANE:-}" @remote_chan "$ctl" 2>/dev/null
    fi
    exec 7<&- 8>&-
    wait "$sp"
    tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_chan 2>/dev/null
  }
  # The line this connection took (issue #1628): `fleet connect`'s own word in the
  # shell (FLEET_CONNECT_ROUTE_FILE — it chose), else this loop's (`hub` = relay).
  route_kind() {
    local k=''
    [ -s "$use.route" ] && k=$(sed -n 's/.*"kind": *"\([a-z]*\)".*/\1/p' "$use.route" | head -n 1)
    [ -n "$k" ] || { [ "$route" = hub ] && k=relay || k=direct; }
    printf '%s' "$k"
  }
  # @remote_route on the window: `relay` → the bar's machine chip says 「· 中转」
  mark_route() {
    [ -n "${TMUX:-}" ] || return 0
    if [ "${1:-}" = relay ]; then tmux set-window-option -t "${TMUX_PANE:-}" @remote_route relay 2>/dev/null
    else tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_route 2>/dev/null; fi
    return 0
  }
  # keys_idle <secs> — no key on any client of this tmux for that long
  keys_idle() {
    local last
    [ -n "${TMUX:-}" ] || return 0
    last=$(tmux list-clients -F '#{client_activity}' 2>/dev/null | sort -n | tail -n 1)
    case "$last" in ''|*[!0-9]*) return 0 ;; esac
    [ $(( $(date +%s) - last )) -ge "$1" ]
  }
  probe_direct() {
    if [ -n "${FLEET_CONNECT_PROBE_CMD:-}" ]; then $FLEET_CONNECT_PROBE_CMD "$host"
    else python3 "$BIN/fleet-connect.py" --probe-direct "$host"; fi
  }
  # The upgrader (issue #1628): once the master is up, mark its line; on the hub
  # relay (the shell, where `fleet connect` picks the line), one direct handshake
  # every FLEET_CONNECT_UPGRADE_SECS (15) — when one answers, wait for the keys to
  # rest FLEET_REMOTE_IDLE_SECS (2), flag the switch and close the master: the loop
  # reconnects at once and re-measures, so the pane is back on the direct line in
  # about a second. A failed probe costs ~0.1–0.2 s and nothing else.
  upgrader() {
    local every="${FLEET_CONNECT_UPGRADE_SECS:-15}" idle="${FLEET_REMOTE_IDLE_SECS:-2}" _ up='' kind
    for _ in $(seq 1 50); do
      $SSH -S "$use" -O check "$host" >/dev/null 2>&1 && { up=1; break; }
      sleep 0.2
    done
    [ -n "$up" ] || return 0
    kind=$(route_kind); mark_route "$kind"
    [ "$kind" = relay ] && [ -n "$shellopt" ] || return 0
    while sleep "$every"; do
      $SSH -S "$use" -O check "$host" >/dev/null 2>&1 || return 0
      probe_direct >/dev/null 2>&1 || continue
      until keys_idle "$idle"; do
        sleep 0.5
        $SSH -S "$use" -O check "$host" >/dev/null 2>&1 || return 0
      done
      : > "$use.upgrade"
      $SSH -S "$use" -O exit "$host" >/dev/null 2>&1
      return 0
    done
  }
  # In the shell (`--shell`) `fleet connect` picks the line on every connect, and
  # every RECONNECT re-measures them all (FLEET_CONNECT_RETEST, issue #1628) —
  # never the remembered one. A fleet's own proxy alternates direct / hub below.
  route=direct; delay=1; retest=''
  while :; do
    # Machine to machine (issue #1626): a plain-ssh view from a hub node asks the
    # hub for a five-minute certificate to THIS machine first. rc 3 = no hub here
    # (or it predates #1626): plain ssh, as before; rc 1 = the hub said no or is
    # down — pause and say so, never fall back to a standing key. A view driven by
    # the shell (FLEET_REMOTE_SSH_CMD) rides the person's own certificate instead.
    peer=(); peerwhy=''
    if [ -z "${FLEET_REMOTE_SSH_CMD:-}" ] && [ -f "$BIN/fleet-peer-cert.sh" ]; then
      peerout=$(bash "$BIN/fleet-peer-cert.sh" "$(hub_node "$node")" view 2>"${ctl}.err"); prc=$?
      peerwhy=$(tail -n 1 "${ctl}.err" 2>/dev/null); rm -f "${ctl}.err"
      case "$prc" in
        0) while IFS= read -r o; do [ -n "$o" ] && peer+=("$o"); done <<EOF_PEER
$peerout
EOF_PEER
           ;;
        3) peerwhy='' ;;
        *) printf '\033[2J\033[H→ %s 暂停：%s\n' "$node" "${peerwhy#fleet-peer-cert: }"
           [ "$delay" -lt 30 ] && delay=$(( delay * 2 ))
           printf '%ss 后再向入口申请 · Ctrl-C 关闭窗口\n' "$delay"
           sleep "$delay"; continue ;;
      esac
    fi
    # The shell's warm master (issue #1631): `fleet-shell.sh warm` keeps one
    # connection per machine you have sessions on; when it answers, this round is
    # a SESSION on it — no handshake, no `fleet connect`, no certificate — and the
    # window's `@remote_ctl` names it, so `open` retargets over it too. Its line,
    # keepalive and life are the warm loop's; a drop here just comes back round.
    use="$ctl"
    if [ -n "$shellopt" ] && [ "${FLEET_SHELL_WARM:-1}" != 0 ]; then
      wsock="${TMPDIR:-/tmp}/warm/$node.sock"
      [ -S "$wsock" ] && $SSH -S "$wsock" -O check "$host" >/dev/null 2>&1 && use="$wsock"
    fi
    [ -n "${TMUX:-}" ] && tmux set-window-option -t "${TMUX_PANE:-}" @remote_ctl "$use" 2>/dev/null
    if [ "$use" != "$ctl" ]; then
      printf '\033[2J\033[H→ %s (%s · 已连) …\n' "$node" "$host"
      opts=(-tt -o ControlMaster=no -S "$use")
    else
      printf '\033[2J\033[H→ %s (%s%s%s) …\n' "$node" "$host" "$( [ "$route" = hub ] && printf ' · 经入口中转')" \
        "$( [ ${#peer[@]} -gt 0 ] && printf ' · 入口证书 5 分钟')"
      # keepalive 2 s × 3: a dead line is seen in ≤ 6 s (issue #1631, was 5 × 3);
      # no compression (a LAN / tailnet only pays its latency), low-delay QoS
      opts=(-tt -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o ConnectTimeout=8
            -o "IPQoS=lowdelay throughput" -o Compression=no
            -o ControlMaster=yes -o "ControlPath=$ctl" -o ControlPersist=no ${peer[@]+"${peer[@]}"})
      [ "$route" = hub ] && opts+=(-o "ProxyCommand=$(sq "$BIN/fleet") connect --proxy $(sq "$(hub_node "$node")")")
      rm -f "$ctl" "$ctl.route" "$ctl.upgrade"
    fi
    rm -f "$use.upgrade"
    sidecar & side=$!
    upgrader & upg=$!
    chan & chn=$!
    started=$(date +%s)
    FLEET_CONNECT_ROUTE_FILE="$ctl.route" FLEET_CONNECT_RETEST="$retest" \
      $SSH ${opts[@]+"${opts[@]}"} "$host" "bash $rbin/fleet-remote-view.sh attach$shellopt $(sq "$wid") $(sq "$view")"
    rc=$?
    stop_bg
    mark_route ''
    retest=1
    if [ -f "$use.upgrade" ]; then
      rm -f "$use.upgrade"
      # the upgrader closed the relay: a direct line answered — over to it now
      printf '\n%s 的直连通了，切回直连 …\n' "$node"
      delay=1; continue
    fi
    case "$rc" in
      0) exit 0 ;;                                   # the remote client ended on purpose
      3) if [ "$wid" = - ]; then printf '\n%s 上没有活着的 fleet 会话。按任意键关闭。\n' "$node"
         else printf '\n%s 已不在 %s 上（结束或搬走了）。按任意键关闭。\n' "${wid#*/}" "$node"; fi
         read -r -n 1 -s _; exit 0 ;;
    esac
    # A drop after a good session reconnects at once; a failing route backs off and,
    # when the hub relay is configured, alternates with it.
    if [ $(( $(date +%s) - started )) -gt 30 ]; then delay=1
    else
      [ -z "$shellopt" ] && hub_relay_ok && { [ "$route" = direct ] && route=hub || route=direct; }
      [ "$delay" -lt 10 ] && delay=$(( delay * 2 ))
    fi
    printf '\n与 %s 的连接断了（exit %s），%ss 后重连 · Ctrl-C 关闭窗口\n' "$node" "$rc" "$delay"
    sleep "$delay"
  done
  ;;

# ---------------------------------------------------------------------------------
attach)
  shell=''
  while [ $# -gt 0 ]; do
    # a bare `-` is the machine itself (the shell's first window), not an option (#1712)
    case "$1" in --shell) shell=1; shift ;; --) shift; break ;; -) break ;; -*) note "attach: unknown option $1"; exit 2 ;; *) break ;; esac
  done
  wid="${1:-}"; view="${2:-}"; w=''
  if [ -z "$wid" ] || [ "$wid" = - ]; then
    # The machine itself (issue #1484): this login's one fleet session (one fleet
    # per login, #980), as it stands — the shell's first window lands here.
    s=$(fleet_sockets | head -n 1)
    [ -n "$s" ] || { note "no fleet session is live on $(hostname -s)"; exit 3; }
    sock=$(fleet_socket "$s")
  else
    loc=$(fleet_worker_locate "wid:${wid#wid:}" 2>/dev/null)
    case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; exit 3 ;; esac
    set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
    T display-message -p -t "=$s:$w" '' >/dev/null 2>&1 || { note "cannot select $w"; exit 3; }
  fi
  # A row a SIGKILLed proxy left behind; what an older version's rule left (#1713).
  rv_prune
  rv_legacy_undo "$s"
  # Register this client (issue #1485): `--shell` = a shell client; a <view> id =
  # a proxy view, with the spool its `watch` drains (no id → no spool: a request
  # nobody drains would read as sent).
  reg=''; g=''
  if { [ -n "$shell" ] || [ -n "$view" ]; } && tty=$(tty 2>/dev/null); then
    kind=view; [ -n "$shell" ] && kind=shell
    spool="$view"
    [ -n "$view" ] || view="$kind-$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9-' '-')$$-$RANDOM"
    case "$view" in *[!A-Za-z0-9-]*) note "attach: bad view id $view — not registered" ;; *)
      if mkdir -p "$VIEWS" 2>/dev/null \
         && printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$s" "$kind" "$(date +%s)" "$$" > "$VIEWS/$view"; then
        reg="$view"
        [ -n "$spool" ] && mkdir -p "$VIEWS/$spool.d" 2>/dev/null
        # This client's own VIEW SESSION (issue #1489): grouped onto the fleet's —
        # the same windows, a current window of its own — with the status line and
        # prefix off for good (the person's own tmux has both). It starts on the
        # worker's window, or for `-` on the fleet session's current one.
        g="$s@view-$view"
        if T new-session -d -t "=$s" -s "$g" 2>/dev/null; then
          T set-option -t "=$g:" status off \; set-option -t "=$g:" prefix None \; \
            set-option -t "=$g:" prefix2 None 2>/dev/null
          [ -n "$w" ] || w=$(T display-message -p -t "=$s:" '#{window_id}' 2>/dev/null)
          [ -z "$w" ] || T select-window -t "=$g:$w" 2>/dev/null
        else
          note "attach: no view session for $view — sharing the fleet session's current window"
          g=''
        fi
        # Before the first frame: the windows' own headers go, one way (#1549).
        rv_hide_borders "$s"
      fi ;;
    esac
  fi
  # A plain client sees the worker in the FLEET session — by name: a bare `-t @w`
  # lands in whichever session holding the window was active last (#1489). A
  # registered one already selected it in its own view session, so the fleet's
  # current window — what a person on the node sees — is never moved by a shell.
  [ -n "$w" ] && [ -z "$g" ] && T select-window -t "=$s:$w" 2>/dev/null
  # A dropped connection HUPs this shell too: outlive the client, then clean up.
  trap 'rc=129' HUP
  if [ -n "$g" ]; then
    # destroy-unattached is armed IN the attach command: armed on the detached
    # session a moment earlier, any other client's leaving in between would have
    # destroyed it before this client arrived.
    T attach-session -t "=$g" \; set-option -t "=$g:" destroy-unattached on; rc=$?
    T kill-session -t "=$g" 2>/dev/null
  else
    T attach-session -t "=$s"; rc=$?
  fi
  # Leaving changes nothing on this machine but the registry (issue #1713).
  [ -n "$reg" ] && rm -rf "${VIEWS:?}/$reg" "${VIEWS:?}/$reg.d" 2>/dev/null
  exit "$rc"
  ;;

# ---------------------------------------------------------------------------------
select)
  # On <node>, over the proxy's own connection (issue #1484): the worker's window
  # becomes the current one of the proxy's VIEW SESSION (issue #1489) — named by
  # the <view> id `run` gave `attach`; the fleet session itself when none is
  # named (an older `open`) or live. Not live here → 3, and `open` reconnects.
  # The one-shot form: `open` uses it when the proxy's `serve` channel (below) is
  # not up. A window spawned since the attach loses its header too (#1549).
  rv_select "${1:-}" "${2:-}"; exit $?
  ;;

# ---------------------------------------------------------------------------------
serve)
  # ON <node>, over the proxy's own connection, for as long as it lives (issue
  # #1682): `select` without a fresh ssh session, bash and fleet-lib per click.
  # `run` holds its stdin/stdout; one request per line, `<nonce> select <wid>`
  # (or `<nonce> ping -`), one answer per line, `<nonce> <rc>`. The view id is
  # this connection's, fixed at start. EOF (the proxy went) ends it.
  view="${1:-}"
  while IFS=' ' read -r nonce op arg; do
    case "$nonce" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    case "$op" in
      ping) rc=0 ;;
      select) rv_select "$arg" "$view" 2>/dev/null; rc=$? ;;
      *) rc=2 ;;
    esac
    printf '%s %s\n' "$nonce" "$rc" || exit 0
  done
  exit 0
  ;;

# ---------------------------------------------------------------------------------
reconcile|restore)
  # Both retired with the rule (issue #1713). Kept for ONE version: the [77]
  # hooks an older attach set still call `reconcile`, and `restore` was the
  # escape hatch — each now undoes that older version's leftovers and no more.
  s="${1:-}"; [ -n "$s" ] || exit 2
  sock=$(fleet_socket "$s")
  rv_legacy_undo "$s"
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

# ---------------------------------------------------------------------------------
sessions)
  # ON <node> (issue #1488, EPIC #1479 R3): this machine's sessions, hub-shaped —
  # {"sessions": […], "nodes": […]} as /v1/fleet/fleet_sessions would answer for
  # it alone — so the shell's loop feeds it through the ONE mapping it has for the
  # hub's answer (fleet-hub-sessions.sh), rows and header lines alike. Each live
  # fleet session here: its UUID (fleet_uuid — the first half of every worker_id
  # the hub knows), its conf's repo (what fills a one-repo window's repo, as
  # fleet_control.py does) and the control adapter's inventory — the very
  # `workers` the node agent reports — keyed by the hub's own rule, worker_key. A
  # fleet with no UUID (no control database) has no addressable rows and is
  # skipped, as the hub would skip it. Exit 1 only when python3 is missing.
  inv=$(mktemp "${TMPDIR:-/tmp}/frv-sess.XXXXXX") || exit 1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    u=$(fleet_uuid "$s" 2>/dev/null) || u=''
    [ -n "$u" ] || continue
    r=$( unset TMUX TMUX_PANE; fleet_load_conf "$s" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    bash "$BIN/fleet-control-read.sh" workers "$s" 2>/dev/null \
      | while IFS= read -r line; do [ -n "$line" ] && printf '%s\t%s\t%s\t%s\n' "$s" "$u" "$r" "$line"; done >> "$inv"
  done <<EOF
$(fleet_sockets)
EOF
  python3 - "$inv" "$(hostname -s 2>/dev/null)" "$(id -un 2>/dev/null)" "$BIN" <<'PY'
import json, sys
from datetime import datetime, timezone
ipath, host, user, bindir = sys.argv[1:5]
sys.path.insert(0, bindir)
from fleet_hub_common import inventory_row, worker_key, worker_identity
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
host = (host or "").split(".", 1)[0]
sessions = []
for line in open(ipath, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    # sess, uuid, the fleet's repo, then the adapter's columns, read by the SAME
    # reader fleet_control.py's inventory uses (issue #1698): a hand copy of it
    # here missed #1607's trailing `busy=` column and so glued @origin_wid onto
    # the name and lost the parent chain — every row of a silent hub flat
    if len(p) < 4:
        continue
    sess, uuid, frepo = p[0], p[1], p[2]
    row = inventory_row(p[3:])
    if row is None:
        continue
    (window, issue, scratch, worktree, state, agent, handle, lifecycle, repo), extra = row
    name, owid, needs, ident = extra.get("name") or "", extra.get("origin_wid"), extra.get("needs"), extra.get("identity")
    if not issue and scratch != "1":
        continue
    number = int(issue) if issue.isdigit() and int(issue) > 0 else None
    key = worker_key(number, scratch == "1", worktree, repo)
    wid = worker_identity(uuid, key)
    if not wid:
        continue
    sessions.append({"worker_id": wid, "fleet_id": uuid, "fleet_name": sess, "machine_name": host,
                     "os_user": user, "availability": "online", "observed_at": now,
                     "worker": {"key": key, "issue": number,
                                "repo": repo if repo and repo != "?" else (None if repo else frepo or None),
                                "state": state or "unknown", "lifecycle": lifecycle or "awake",
                                "agent": agent or None, "name": name, "origin_wid": owid or None,
                                "needs": needs or None, "identity": ident,
                                "busy": extra.get("busy")}})
print(json.dumps({"sessions": sessions,
                  "nodes": [{"machine_name": host, "availability": "online",
                             "sessions": len(sessions), "observed_at": now}]}, ensure_ascii=False))
PY
  rc=$?; rm -f "$inv"; exit "$rc"
  ;;

*)
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2 ;;
esac
