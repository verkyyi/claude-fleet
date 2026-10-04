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
#   reconcile <sess>        (ON <node>; its client-attached/-detached hooks) — apply
#                           the one rule: hidden ⇔ every client is a shell/view.
#   restore <sess>          (ON <node>) — hand the session its status line, prefix
#                           and sidebar back now (an escape hatch; the rule wins at
#                           the next client change).
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
# Nesting — ONE rule (issue #1485, EPIC #1479 rule 7): the remote session's own
# status line, prefix and sidebar are HIDDEN exactly while it has at least one
# client and every client is a registered shell/view; any other client — someone
# who ssh'd onto that machine and attached — brings them back at once, and so
# does the last shell leaving. Hidden = #1475's hide: status off, prefix None
# (saved in `@remote_view_saved`), `@remote_view_solo 1`, which that machine's
# sidebar reads as "draw no list" (fleet-sidebar.py sync) — so the remote looks
# like a local window, this machine's prefix reaches this machine, and the one
# list on screen is the viewer's. Two shells on one session: still one list each.
# Never `resize-pane -Z`. `reconcile` applies the rule; the server's GLOBAL hooks
# `client-attached[77]` / `client-detached[77]` run it on every client change
# while any shell is registered (global, not on the session: a session-level hook
# array — even an emptied one — shadows the fleet's own [71]–[73] hooks).
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
# so the far end registers a SHELL client (#1485) and hides its own list and bar.
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
T() { tmux -L "$sock" "$@"; }   # the REMOTE fleet's server; each mode sets $sock first

# --- the registry + the one rule (issue #1485) -----------------------------------
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
# The clients of the fleet session AND of its view sessions (issue #1489): a
# shell or proxy sits on `<s>@view-<id>`, a person on `<s>` itself; the rule
# counts both — FLEET_SESSION_FMT names the fleet from either.
rv_clients() {
  T list-clients -F "#{client_tty}	$FLEET_SESSION_FMT" 2>/dev/null \
    | awk -F '\t' -v s="$1" '$2 == s { print $1 }'
}
# Every client of the session is a registered shell/view (none at all → yes).
rv_shells_only() {
  local s="$1" reg tty
  reg=$(rv_registry | awk -F '\t' -v s="$s" '$2 == s { print $1 }')
  while IFS= read -r tty; do
    [ -n "$tty" ] || continue
    printf '%s\n' "$reg" | grep -qxF -- "$tty" || return 1
  done <<< "$(rv_clients "$s")"
  return 0
}
rv_sync() {   # the sidebar follows the solo marker (issue #1475); the script wants $TMUX
  TMUX="$(T display-message -p '#{socket_path}' 2>/dev/null),0,0" \
    bash "$BIN/fleet-sidebar.sh" sync "=$1:" >/dev/null 2>&1 || :
}
# #1475's hide: status line + prefix off, what the SESSION itself set saved
# (`-` = inherited), the solo marker on, its sidebar gone. Idempotent.
rv_hide() {
  local s="$1" saved='' o v
  [ -z "$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)" ] || return 0
  # Space-separated: an argument ENDING in `;` is a command separator to tmux.
  for o in status prefix prefix2; do
    v=$(T show-options -q -t "=$s:" "$o" 2>/dev/null | sed "s/^$o //")
    saved="$saved$o=${v:--} "
  done
  T set-option -t "=$s:" @remote_view_saved "$saved" \; \
    set-option -t "=$s:" status off \; set-option -t "=$s:" prefix None \; set-option -t "=$s:" prefix2 None \; \
    set-option -t "=$s:" @remote_view_solo 1 2>/dev/null
  rv_sync "$s"
}
# #1475 set its hook ON THE SESSION, and a session-level hook array — even one
# emptied by `set-hook -u <hook>[77]` — shadows the server's global hooks of that
# name for good (the fleet's [71]–[73]: sidebar sync, sleep wake, hub visits).
# Lift what an older attach left; the hooks live on the server now.
rv_unshadow() {
  local s="$1" h
  for h in client-attached client-detached; do
    T show-hooks -t "=$s:" 2>/dev/null | grep -q "^$h" || continue
    T show-hooks -t "=$s:" 2>/dev/null | grep "^$h\[" | grep -qv "^$h\[77\]" && continue   # someone else's: leave it
    T set-hook -u -t "=$s:" "$h" 2>/dev/null
  done
}
rv_restore() {
  local s="$1" saved o v p
  saved=$(T show-options -qv -t "=$s:" @remote_view_saved 2>/dev/null)
  rv_unshadow "$s"
  [ -n "$saved" ] || return 0
  IFS=' ' read -r -a kv <<< "$saved"
  for p in ${kv[@]+"${kv[@]}"}; do
    o=${p%%=*}; v=${p#*=}
    case "$o" in status|prefix|prefix2) ;; *) continue ;; esac
    if [ "$v" = - ]; then T set-option -u -t "=$s:" "$o" 2>/dev/null
    else T set-option -t "=$s:" "$o" "$v" 2>/dev/null; fi
  done
  T set-option -u -t "=$s:" @remote_view_saved \; set-option -u -t "=$s:" @remote_view_solo 2>/dev/null
  rv_sync "$s"
}
# One application of the rule at a time per session: a client leaving fires the
# detached hook AND its own attach's cleanup, and two hides racing re-save the
# hidden values (`prefix=None`) as the originals. A holder that died keeps nobody
# waiting; a lock older than ~5 s is taken anyway.
rv_lock() {
  local d="$VIEWS/.lock-$1" pid
  mkdir -p "$VIEWS" 2>/dev/null
  for _ in $(seq 1 100); do
    if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid"; return 0; fi
    pid=$(cat "$d/pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null || rm -rf "$d" ;; esac
    sleep 0.05
  done
  rm -rf "$d"; mkdir "$d" 2>/dev/null && printf '%s\n' "$$" > "$d/pid"
  return 0
}
rv_unlock() { rm -rf "${VIEWS:?}/.lock-$1"; }
# The rule: hidden ⇔ at least one client, and every one of them a shell/view.
rv_reconcile() {
  local s="$1" n
  rv_lock "$s"
  n=$(rv_clients "$s" | grep -c .)
  if [ "$n" -gt 0 ] && rv_shells_only "$s"; then rv_hide "$s"; else rv_restore "$s"; fi
  rv_unlock "$s"
}
# The server's hooks run the rule on every client change while a shell is registered.
rv_hooks_on() {
  local s="$1" cmd
  cmd="run-shell -b 'bash $(sq "$BIN/fleet-remote-view.sh") reconcile $(sq "$s") >/dev/null 2>&1'"
  T set-hook -g 'client-attached[77]' "$cmd" \; set-hook -g 'client-detached[77]' "$cmd" 2>/dev/null
  rv_unshadow "$s"
}
rv_hooks_off() { T set-hook -gu 'client-attached[77]' \; set-hook -gu 'client-detached[77]' 2>/dev/null; }

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
      ctl=$(tmux show-options -wqv -t "$w" @remote_ctl 2>/dev/null)
      rview=$(tmux show-options -wqv -t "$w" @remote_view 2>/dev/null)   # its view session (#1489)
      SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"; host=$(ssh_host "$node"); rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
      if [ -n "$ctl" ] && [ -S "$ctl" ] && $SSH -S "$ctl" -O check "$host" >/dev/null 2>&1 \
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
    $SSH ${opts[@]+"${opts[@]}"} "$host" "bash $rbin/fleet-remote-view.sh attach$shellopt $(sq "$wid") $(sq "$view")"
    rc=$?
    kill "$side" 2>/dev/null; side=''
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
      hub_relay_ok && { [ "$route" = direct ] && route=hub || route=direct; }
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
    case "$1" in --shell) shell=1; shift ;; --) shift; break ;; -*) note "attach: unknown option $1"; exit 2 ;; *) break ;; esac
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
  # A marker a SIGKILLed proxy left behind, or a state the hooks missed: the rule
  # first, on the clients that are here now.
  rv_prune
  rv_reconcile "$s"
  # Register this client (issue #1485): `--shell` = a shell client; a <view> id =
  # a proxy view, with the spool its `watch` drains (no id → no spool: a request
  # nobody drains would read as sent). Either way it counts toward the rule.
  reg=''; g=''
  if { [ -n "$shell" ] || [ -n "$view" ]; } && tty=$(tty 2>/dev/null); then
    kind=view; [ -n "$shell" ] && kind=shell
    spool="$view"
    [ -n "$view" ] || view="$kind-$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9-' '-')$$-$RANDOM"
    case "$view" in *[!A-Za-z0-9-]*) note "attach: bad view id $view — not registered" ;; *)
      # Under the lock, like the unregister below: a shell leaving must not read the
      # registry without this row and take the hooks down right after they went up.
      rv_lock "$s"
      if mkdir -p "$VIEWS" 2>/dev/null \
         && printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$s" "$kind" "$(date +%s)" "$$" > "$VIEWS/$view"; then
        reg="$view"
        [ -n "$spool" ] && mkdir -p "$VIEWS/$spool.d" 2>/dev/null
        rv_hooks_on "$s"
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
        # Before the first frame: every client already here is a shell (none at
        # all counts), so this one makes the session shells-only.
        rv_shells_only "$s" && rv_hide "$s"
      fi
      rv_unlock "$s" ;;
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
  # The last registered client of this session takes the hooks with it; the rule
  # decides what the remaining clients get (none → everything back).
  rv_lock "$s"
  [ -n "$reg" ] && rm -rf "${VIEWS:?}/$reg" "${VIEWS:?}/$reg.d" 2>/dev/null
  rv_registry | awk -F '\t' -v s="$s" '$2 == s { f = 1 } END { exit !f }' || rv_hooks_off "$s"
  rv_unlock "$s"
  rv_reconcile "$s"
  exit "$rc"
  ;;

# ---------------------------------------------------------------------------------
select)
  # On <node>, over the proxy's own connection (issue #1484): the worker's window
  # becomes the current one of the proxy's VIEW SESSION (issue #1489) — named by
  # the <view> id `run` gave `attach`; the fleet session itself when none is
  # named (an older `open`) or live. Not live here → 3, and `open` reconnects.
  wid="${1:-}"; view="${2:-}"
  loc=$(fleet_worker_locate "wid:${wid#wid:}" 2>/dev/null)
  case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; exit 3 ;; esac
  set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
  tgt="$s"
  case "$view" in ''|*[!A-Za-z0-9-]*) ;; *) T has-session -t "=$s@view-$view" 2>/dev/null && tgt="$s@view-$view" ;; esac
  T select-window -t "=$tgt:$w" 2>/dev/null || { note "cannot select $w"; exit 3; }
  exit 0
  ;;

# ---------------------------------------------------------------------------------
reconcile)
  s="${1:-}"; [ -n "$s" ] || exit 2
  sock=$(fleet_socket "$s")
  rv_reconcile "$s"
  exit 0
  ;;

# ---------------------------------------------------------------------------------
restore)
  s="${1:-}"; [ -n "$s" ] || exit 2
  sock=$(fleet_socket "$s")
  # The hook an older attach set (`--unless-view <tty>`): the rule decides now.
  [ "${2:-}" = --unless-view ] && { rv_reconcile "$s"; exit 0; }
  rv_lock "$s"; rv_restore "$s"; rv_unlock "$s"
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
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2 ;;
esac
