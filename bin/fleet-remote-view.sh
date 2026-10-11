#!/bin/bash
# fleet-remote-view.sh — step into a session on ANOTHER machine from this one's
# sidebar (issue #1424, EPIC #1419 C5).
#
# The sidebar already SHOWS your sessions on the other machines (#1423: rows keyed
# `wid:<worker_id>`, each ending in its machine's `@m4` mark, #1780). Enter on
# one opens a PROXY WINDOW here — titled `<name> · @m4` (issue #1780: the mark
# the row ends in, never a machine prefix on the name), so the window list and the
# pane header both say the keys go elsewhere — a window marked `@remote=<node>:<worker_id>` whose
# pane is an ssh client attached to that session's tmux window on <node>. Typing
# and scrolling are the remote window's own; closing the proxy window only drops
# the connection — the remote session never notices. A dropped connection
# reconnects by itself.
#
# It is a TASK WINDOW of this machine (issue #1475): the local sidebar treats a
# window with `@remote` like an issue worker's, so the list stays on the left and
# the other machine's pane is on the right — never the whole window gone remote,
# never two lists. `prefix h` / `prefix q` (conf/tmux-shell.conf: last-window)
# return to the machine you were on; ↑↓ in the list do too. `back` is kept for a
# direct attach; the node binds no key to it since issue #1714.
#
#   open <worker_id>        (dash Enter, in a fleet pane) — open the proxy window
#                           for the row's machine, or retarget + select the one
#                           already open: ONE proxy window per machine (in the
#                           shell, on its STAGE server, FLEET_SHELL_STAGE —
#                           issue #1759), because
#                           it is a client of that machine's one fleet session
#                           (one fleet per login). `--node <m> [--name <n>]`
#                           (issue #2236): the machine + name of a session just
#                           opened, which the sidebar's cache does not carry yet.
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
#   attach --thin --view <id> [--want <worker_id>|--resume] --device <b64>
#          --route <name> --token <nonce>   (ON <node>, the thin client's home —
#                           issue #2763, EPIC #2999 C1) — the client's 看台: a view
#                           session that wears the top line itself and outlives its
#                           client for FLEET_VIEW_KEEP_SECS; see rv_attach_thin.
#   select <worker_id> [<view>]  (runs ON <node>, over the proxy's own ssh
#                           connection, issue #1484) — select the worker's window
#                           in the proxy's view session (its <view> id; the fleet
#                           session when none is named or live), which that proxy
#                           then shows: how `open` moves an open proxy window to
#                           another row of the SAME machine, with no reconnect.
#                           Exit 3 when the worker is not live here.
#   watch <view>            (runs ON <node>, over the same ssh connection) — the
#                           fleet-open back channel, below.
#   live                    (ON <node>, issue #2219) — exit 0 when this login has a
#                           live fleet session here (what `attach -` lands on), 1 not.
#   health / prune          (ON <node>, issue #1907) — `shared=<n> orphans=<m>`:
#                           remote clients on the fleet session instead of a view
#                           session of their own, attaches whose tmux client is
#                           gone (fleet-doctor's `rview`); `prune` reaps what every
#                           attach reaps first.
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
# viewer's `<name> · @m4` header is the one title line) and never gets it back, so no
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
#   FLEET_ROUTE_FAIL_HINT    5 — on a PINNED route (`fleet route`, claude-fleet#2886),
#                            failures in a row before the page suggests going back
#                            to auto (it never switches by itself). The window
#                            carries `@remote_pin` <route> + `@remote_tries` <N>
#                            while pinned, and `@remote_via` `<auto|manual> <route>`
#                            once connected — the top bar's connection part
#   FLEET_ROUTE_GET_CMD      (selftests) the pin lookup, given the node + host
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

# --- a registry row's key=value columns (issue #2763) ------------------------------
# A row is `<tty> <session> <kind> <since> <pid>` and, for a thin 看台, key=value
# columns after the fifth (cur= route= device= token= fuid= node= left=).
# rv_row_get <file> <key> — the value, or nothing.
rv_row_get() {
  awk -F '\t' -v k="$2" 'NR == 1 { for (i = 6; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }' "$1" 2>/dev/null
}
# rv_row_set <file> <key> <value> — set it (added when absent), atomically: a
# dot-name temp file, which no `$VIEWS/*` scan reads as a row.
rv_row_set() {
  local f="$1" t
  [ -f "$f" ] || return 1
  t="${f%/*}/.${f##*/}.$$"
  awk -F '\t' -v OFS='\t' -v k="$2" -v v="$(printf '%s' "$3" | tr -d '\t\n')" '
    NR == 1 { n = 0; for (i = 6; i <= NF; i++) if (index($i, k "=") == 1) { $i = k "=" v; n = 1 }
              if (!n) $(NF + 1) = k "=" v; print }' "$f" > "$t" 2>/dev/null && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}

# `cur <views dir> <socket> <session>` (issue #2763) — run by the server's
# session-window-changed[78] hook, only in a session marked `@view_thin` (a thin
# 看台): the 看台's registry row gets `cur=` — the session in view, as a worker id
# (`<fleet UUID>/<@fleet_id>`), or the far session's for another machine's window
# (its `@peer_cur`, EPIC #2999 C4), else `@<window id>`. Before the lib: it runs on
# every window change of a 看台, so it costs one tmux call and one awk.
if [ "${1:-}" = cur ]; then
  command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  _v=${4#*@view-}; _f="${2:-}/$_v"
  case "$_v" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
  [ "$(cut -f3 "$_f" 2>/dev/null)" = thin ] || exit 0
  IFS='|' read -r _w _fid _pc <<EOF
$(tmux -S "$3" display-message -p -t "=$4:" '#{window_id}|#{@fleet_id}|#{@peer_cur}' 2>/dev/null)
EOF
  [ -n "$_w" ] || exit 0
  _fu=$(rv_row_get "$_f" fuid); _c="@${_w#@}"
  if [ -n "${_pc:-}" ]; then _c=${_pc#wid:}
  elif [ -n "${_fid:-}" ] && [ -n "$_fu" ]; then _c="$_fu/$_fid"; fi
  [ "$(rv_row_get "$_f" cur)" = "$_c" ] || rv_row_set "$_f" cur "$_c"
  exit 0
fi

[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-ui-lang.sh"   # the proxy title's 本机 (issue #1780)

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
# rv_route_login <route file> — the login a master was opened as (fleet-connect.py
# writes it into FLEET_CONNECT_ROUTE_FILE, issue #2430); nothing when it did not say.
rv_route_login() {
  [ -s "${1:-}" ] || return 0
  python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("login") or "")
except Exception: pass' "$1" 2>/dev/null
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

# A static forward in the person's ~/.ssh/config (`RemoteForward 2226 …`, the
# open-url.sh opener) is asked for again by EVERY session on a shared master, and
# the second ask of one remote port is refused — fatally for a mux client
# (`muxclient: master forward request failed`): no attach, a reconnect, a storm
# (issue #1775). So a session on a master never carries the config's forwards
# (MUXO; the master that holds them already has them), and a master that cannot
# get one goes on without it (MASTERO) — a lost opener, never a lost attach.
MUXO=(-o ClearAllForwardings=yes -o ControlMaster=no)
MASTERO=(-o ExitOnForwardFailure=no)
# ↑ ControlMaster=no on every session over a master (issue #2987): a mux client
#   whose ControlMaster is anything else (a person's `Host * / ControlMaster auto`)
#   takes a refused connect — macOS refuses a LIVE socket whose accept queue is
#   full for a moment — for a stale socket and UNLINKS it (OpenSSH mux.c
#   "Stale control socket, unlinking"): the master runs on, nobody can reach it,
#   and every switch after it fell to a full reconnect.

# rv_warm_sock <node> [<login>] — the shell's warm master for that machine as that
# login (issue #2987: `fleet-shell.sh warm` keeps `<node>@<login>.sock` per login
# its sessions are in); a login with none of its own (an older warm loop, or no
# login known) gets `<node>.sock`, which the caller rides only when its route file
# says the same login.
rv_warm_sock() {
  local d="${TMPDIR:-/tmp}/warm"
  if [ -n "${2:-}" ] && { [ -S "$d/$1@$2.sock" ] || [ -e "$d/$1@$2.sock.pending" ]; }; then
    printf '%s' "$d/$1@$2.sock"
  else
    printf '%s' "$d/$1.sock"
  fi
}
# rv_warm_ok <sock> <login> — that warm master may carry a session of <login>
rv_warm_ok() {
  [ -z "${2:-}" ] && return 0
  case "${1##*/}" in *@"$2".sock) return 0 ;; esac
  [ "$(rv_route_login "$1.route")" = "$2" ]
}
# rv_switch_log <event> <node> <how> <ms> [<why>] — one line per switch in the
# client's connect log (issue #2987): how it went (chan · select · readopt ·
# respawn · new) and how long `open` took, so a slow switch is visible.
rv_switch_log() {
  [ "${FLEET_SHELL:-0}" = 1 ] && [ -f "$BIN/fleet_clientlog.py" ] || return 0
  python3 "$BIN/fleet_clientlog.py" write connect "$1" "$2" "$3" "$4" ok "${5:-}" >/dev/null 2>&1 || :
}
rv_ms() { python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s000' "$(date +%s)"; }

# rv_ssh_why <stderr file> — ssh's last word on a dropped line, in words a person
# reads (issue #1775 §3): a raw `mux_client_forward: …` reads as "the network is
# broken". An unknown line is shown as it is.
rv_ssh_why() {
  local f="$1" l
  [ -s "$f" ] || return 0
  l=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | grep -v '^Warning: remote port forwarding failed' | tail -n 1)
  [ -n "$l" ] || return 0
  case "$l" in
    *'forward request failed'*|*'port forwarding failed'*)
      printf '端口转发被拒（另一条连接已占用同一个端口）' ;;
    *'Connection refused'*)                  printf '对方的 ssh 拒绝连接' ;;
    *'kex_exchange_identification'*|*'Connection reset'*|*'Connection closed by'*)
      printf '对方的 ssh 在握手时断开（可能同时连接太多）' ;;
    *'timed out'*|*'Timeout, server'*)       printf '连接超时（网络不通或对方不在线）' ;;
    *'Permission denied'*)                   printf '认证被拒（证书可能过期，试试 fleet login）' ;;
    *'Could not resolve hostname'*)          printf '找不到这台机器的地址' ;;
    *'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION'*)
      printf '对方的主机指纹不符' ;;
    *'Broken pipe'*|*'Network is unreachable'*|*'No route to host'*)
      printf '网络断了' ;;
    *'Control socket'*|*'mux_client'*|*'muxclient'*)
      printf '共享的连接已关闭' ;;
    *) printf '%s' "$l" ;;
  esac
}

# --- the registry (issue #1485) ---------------------------------------------------
# Live rows of the registry: `<tty> <session> <kind> <since> <pid>`. A row whose
# attach shell is gone does not count; a row without a pid (written by an older
# attach) is trusted as before.
rv_registry() {
  local f tty sess kind since pid _rest
  for f in "$VIEWS"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r tty sess kind since pid _rest < "$f" || :
    [ -n "$tty" ] || continue
    case "${pid:-}" in '') ;; *[!0-9]*) continue ;; *) kill -0 "$pid" 2>/dev/null || continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$sess" "${kind:-view}" "${since:-}" "${pid:-}"
  done
}
# Drop the rows (and spools) whose attach shell is gone: a SIGKILL skipped its
# cleanup, and the next login may get that very tty.
rv_prune() {
  local f tty sess kind since pid g v _rest
  for f in "$VIEWS"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r tty sess kind since pid _rest < "$f" || :
    case "${pid:-}" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    # a thin 看台 outlives its client for FLEET_VIEW_KEEP_SECS (issue #2763)
    [ "$kind" = thin ] && rv_thin_kept "$f" && continue
    rm -rf "$f" "$f.d"
  done
  # A view session with no client (issue #1489): destroy-unattached takes it when
  # its client goes; this is the belt for one left detached by an attach that
  # died first. Never one a live attach has registered and is about to join.
  for g in $(T list-sessions -F '#{?#{session_attached},,#{session_name}}' 2>/dev/null); do
    fleet_is_view_session "$g" || continue
    v=${g#*@view-}
    [ -f "$VIEWS/$v" ] && kill -0 "$(cut -f5 "$VIEWS/$v" 2>/dev/null)" 2>/dev/null && continue
    [ "$(cut -f3 "$VIEWS/$v" 2>/dev/null)" = thin ] && rv_thin_kept "$VIEWS/$v" && continue
    # a uniquely-suffixed one (`<id>-x<pid>`, #1907) belongs to <id>'s row
    case "$v" in *-x*) [ -f "$VIEWS/${v%-x*}" ] && kill -0 "$(cut -f5 "$VIEWS/${v%-x*}" 2>/dev/null)" 2>/dev/null && continue ;; esac
    T kill-session -t "=$g" 2>/dev/null
  done
  rv_reap_orphans
}
# --- orphaned attaches (issue #1907) ---------------------------------------------
# An attach whose line died without sshd noticing keeps its tmux client process —
# stuck writing to a tty nobody reads — long after the server dropped that client
# (m4, 2026-10-06: six of them, one to two days old, none in `list-clients`). Its
# registry row and spool live on with it. An attach is an ORPHAN when it is older
# than FLEET_REMOTE_ORPHAN_SECS (60) and no client of any live fleet server is its
# child (or grandchild: a tmux shim on PATH may not exec).
#
# rv_attach_procs — `<pid>\t<age secs>\t<view id or ->\t<shell|view|plain>` for
# every `fleet-remote-view.sh attach` shell of this login.
rv_attach_procs() {
  ps -axo uid=,pid=,etime=,command= 2>/dev/null | awk -v me="$(id -u)" '
    $1 != me { next }
    $5 !~ /fleet-remote-view\.sh$/ || $6 != "attach" { next }
    { e = $3; d = 0; if (index(e, "-")) { split(e, dp, "-"); d = dp[1]; e = dp[2] }
      n = split(e, t, ":"); secs = 0; for (i = 1; i <= n; i++) secs = secs * 60 + t[i]
      secs += d * 86400
      i = 7; kind = "plain"
      if ($i == "--thin") { v = "-"; for (j = i + 1; j < NF; j++) if ($j == "--view") { v = $(j + 1); break }
        printf "%s\t%s\t%s\t%s\n", $2, secs, v, "thin"; next }
      if ($i == "--shell") { kind = "shell"; i++ }
      if ($i == "--") i++
      v = $(i + 1); if (v == "") v = "-"; else if (kind == "plain") kind = "view"
      printf "%s\t%s\t%s\t%s\n", $2, secs, v, kind }'
}
# rv_client_rows — `<client pid> <session>` of every client of every live fleet
# server here; rc 1 when no fleet server answers (nothing can be judged then).
rv_client_rows() {
  local f any=''
  for f in $(fleet_sockets); do
    any=1; tmux -L "$(fleet_socket "$f")" list-clients -F '#{client_pid} #{client_session}' 2>/dev/null
  done
  [ -n "$any" ]
}
# rv_scan — `<kind>\t<pid>\t<view>` per attach: `orphan` (no client is its
# own), `shared` (a --shell / view attach whose client sits on a fleet session,
# not a view session — what #1907 saw), `ok`.
#
# Only a REGISTERED attach is ever an orphan — one this machine's registry names
# (its row's pid, or for a row an older version wrote without one, its view id): a
# plain attach a person runs on the node is never touched, and neither is any
# attach another FLEET_CONF_DIR (a selftest's sandbox, another install)
# registered. `shared` needs no row (#1907's own lost it): a --shell / view attach
# whose client one of THIS machine's fleet servers lists on a fleet session.
rv_scan() {
  local clients rows f
  clients=$(rv_client_rows) || return 0
  rows=$(for f in "$VIEWS"/*; do [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(cut -f5 "$f" 2>/dev/null)"; done)
  # multi-line values through the environment: BSD awk refuses a newline in -v
  rv_attach_procs | RV_CLIENTS="$clients" RV_ROWS="$rows" RV_TREE="$(ps -axo pid=,ppid= 2>/dev/null)" \
    awk -F '\t' -v grace="${FLEET_REMOTE_ORPHAN_SECS:-60}" '
    BEGIN { clients = ENVIRON["RV_CLIENTS"]; rows = ENVIRON["RV_ROWS"]; tree = ENVIRON["RV_TREE"]
            n = split(tree, tl, "\n"); for (i = 1; i <= n; i++) { split(tl[i], f, " "); par[f[1]] = f[2] }
            n = split(clients, cl, "\n"); for (i = 1; i <= n; i++) { split(cl[i], f, " "); if (f[1] != "") sess[f[1]] = f[2] }
            n = split(rows, rl, "\n"); for (i = 1; i <= n; i++) { split(rl[i], f, " "); if (f[1] == "") continue
              if (f[2] != "") regpid[f[2]] = 1; else regview[f[1]] = 1 } }
    { pid = $1; mine = ""; reg = (pid in regpid) || ($3 in regview)
      for (c in sess) if (par[c] == pid || par[par[c]] == pid) { mine = sess[c]; break }
      if (mine == "") { if (reg && $2 + 0 >= grace + 0) print "orphan\t" pid "\t" $3; next }
      if ($4 != "plain" && mine !~ /@view-/) print "shared\t" pid "\t" $3; else print "ok\t" pid "\t" $3 }'
}
# rv_kill_attach <pid> — an attach shell and what it runs: TERM, then KILL what is
# left (a client stuck in a tty write may not take a TERM).
rv_kill_attach() {
  local p="$1" kids _
  kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
  kill -TERM "$p" $kids 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$p" 2>/dev/null || { [ -z "$kids" ] || ! kill -0 $kids 2>/dev/null; } && break
    sleep 0.1
  done
  kill -KILL "$p" $kids 2>/dev/null
  return 0
}
# rv_reap_orphans — kill every orphaned attach and drop the row it wrote (rows a
# version before the pid column wrote are matched by the view id on its argv).
rv_reap_orphans() {
  local k p v rp
  [ "${FLEET_REMOTE_ORPHAN_REAP:-1}" = 1 ] || return 0
  while IFS="$(printf '\t')" read -r k p v; do
    [ "$k" = orphan ] || continue
    [ "$p" = "$$" ] && continue
    rv_kill_attach "$p"
    case "$v" in ''|-|*[!A-Za-z0-9-]*) continue ;; esac
    [ -f "$VIEWS/$v" ] || continue
    rp=$(cut -f5 "$VIEWS/$v" 2>/dev/null)
    # a thin 看台's row stays for its keep window, counted from now (issue #2763)
    if [ "$(cut -f3 "$VIEWS/$v" 2>/dev/null)" = thin ]; then
      [ "$rp" = "$p" ] && rv_row_set "$VIEWS/$v" left "$(date +%s)"
      continue
    fi
    [ -z "$rp" ] || [ "$rp" = "$p" ] && rm -rf "${VIEWS:?}/$v" "${VIEWS:?}/$v.d"
  done <<EOF
$(rv_scan)
EOF
  return 0
}
# rv_unregister <view> — drop the row (and spool) only while it is this attach's.
rv_unregister() {
  [ "$(cut -f5 "$VIEWS/$1" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "${VIEWS:?}/$1" "${VIEWS:?}/$1.d" 2>/dev/null
}
# rv_takeover <view> <view session> — a reconnect reuses its view id (`run` keeps
# one per pane); an attach of the last connection may still hold the id's row and
# session (issue #1907). Same id = same proxy pane, so the old one is over: kill
# its attach (only a live `fleet-remote-view.sh attach` naming this id), then its
# session. Never touches another id.
rv_takeover() {
  local v="$1" g="$2" p
  p=$(cut -f5 "$VIEWS/$v" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) p='' ;; esac
  if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null \
     && ps -o command= -p "$p" 2>/dev/null | grep -q "fleet-remote-view\.sh attach .*$v"; then
    rv_kill_attach "$p"
  fi
  if T has-session -t "=$g" 2>/dev/null; then
    T detach-client -s "=$g" 2>/dev/null
    T kill-session -t "=$g" 2>/dev/null
  fi
  return 0
}
# rv_machine_word <label> — the proxy title's machine (issue #1780): `本机` when
# the label names this computer (its short hostname, or that name's
# FLEET_NODE_ALIASES alias, any case — the sidebar's `@本机` rule), else the label.
# FLEET_SIDEBAR_HOST stands in for the hostname (tests), as in the sidebar.
rv_machine_word() {
  local n h lh a la
  n=$1; h=${FLEET_SIDEBAR_HOST:-$(hostname -s 2>/dev/null)}; h=${h%%.*}
  lh=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  for a in $lh ${FLEET_NODE_ALIASES:-}; do
    case "$a" in
      *=*) la=$(printf '%s' "${a%%=*}" | tr '[:upper:]' '[:lower:]'); [ "$la" = "$lh" ] || continue; a=${a#*=} ;;
    esac
    [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')" ] \
      && { fleet_ui_t sidebar_here; return 0; }
  done
  printf '%s' "$n"
}
# A window a shell/view looks at loses its own top header, ONE WAY (issues #1549,
# #1713): the viewer's `<name> · @m4` header is the one title line, and since it never
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
  local wid="${1#wid:}" view="${2:-}" hit loc fid tgt g c w='' s=''
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
  # the view's session — or the uniquely-suffixed one an attach made when the
  # name was still taken (#1907)
  case "$view" in ''|*[!A-Za-z0-9-]*) ;; *)
    if T has-session -t "=$s@view-$view" 2>/dev/null; then tgt="$s@view-$view"
    else
      g=$(T list-sessions -F '#{session_name}' 2>/dev/null | awk -v p="$s@view-$view-x" 'index($0, p) == 1 { print; exit }')
      [ -n "$g" ] && tgt="$g"
    fi ;;
  esac
  # A view's own client switches (issue #1933): `switch-client -c` makes it the
  # window's latest client, so the window takes THIS viewer's size (the node runs
  # `window-size latest`); a bare select-window comes from no client and leaves
  # the window at whoever typed into it last. No client attached → select-window.
  c=''; [ "$tgt" = "$s" ] || c=$(T list-clients -t "=$tgt" -F '#{client_tty}' 2>/dev/null | head -1)
  { [ -n "$c" ] && T switch-client -c "$c" -t "=$tgt:$w" 2>/dev/null; } \
    || T select-window -t "=$tgt:$w" 2>/dev/null || { note "cannot select $w"; return 3; }
  rv_hide_border "$w"   # a window spawned since the attach (#1549, #1682)
  return 0
}
# rv_chan_select <chan> <worker_id> — `select` over a proxy's `serve` channel
# (issue #1682). 0 = selected there; 2 = no answer in 2 s (a dead line, issue
# #1876: the caller reconnects rather than try the same line again); anything
# else (no channel, not live there) = the caller's one-shot path.
rv_chan_select() {
  local c="$1" nonce n r rc=none
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
  case "$rc" in 0) return 0 ;; none) return 2 ;; *) return 1 ;; esac
}
# rv_within <secs> <cmd…> — the command's status, or 124 once it has run <secs>
# (killed then): an ssh on a half-dead master never returns (issue #1876).
rv_within() {
  local n=$(( $1 * 10 )) p; shift
  "$@" & p=$!
  while kill -0 "$p" 2>/dev/null; do
    [ "$n" -le 0 ] && { pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; }
    sleep 0.1; n=$((n - 1))
  done
  wait "$p"
}

# --- the thin client's 看台 (issue #2763, EPIC #2999 C1, 共同约定 6) ---------------
# `attach --thin --view <id> [--want <worker_id>|--resume] --device <b64 json>
#  --route <name> --token <nonce>` — what the thin client (C6) runs on its home
# machine. Like a view client it gets a grouped session of its own,
# `<fleet>@view-<id>`, but the 看台 is the client's whole screen now — it has no
# tmux of its own — so the session wears the top line itself: `status on`, at the
# top, every 2 s, its one status line `fleet-topbar.py render --node` (the
# session's name · machine · 剩余 · model · effort · route, drawn HERE off this
# machine's books — EPIC #2999 共同约定 2), and `key-table fleet-view` once C2's
# conf/tmux-view.conf has defined that table. All of it session options of the
# 看台: the fleet session, its windows and every global option are untouched.
#
# The registry row (kind `thin`) carries `cur= route= device= token= fuid= node=`
# after the five columns; `cur=` follows the session in view — a server hook,
# session-window-changed[78], gated on the session's `@view_thin`, runs `cur`
# above on every change. The 看台 OUTLIVES its client: no destroy-unattached; on
# the attach's exit the row gets `left=<epoch>` and rv_prune (every attach, the
# collector's `views` phase) takes row + session FLEET_VIEW_KEEP_SECS (600) later.
# `--resume` comes back to it — the same session when it is still kept, else a
# new one on `cur=` — and lands, with no `cur=` to go back to, on the
# orchestrator's window, else the fleet's current one.
rv_thin_kept() {   # <row file> — still inside its keep window (left=, else its mtime)
  local t keep="${FLEET_VIEW_KEEP_SECS:-600}"
  case "$keep" in ''|*[!0-9]*) keep=600 ;; esac
  t=$(rv_row_get "$1" left)
  case "$t" in ''|*[!0-9]*) t=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) ;; esac
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - t )) -lt "$keep" ]
}
# rv_thin_window <session> <cur> — the window of <session> a `cur=` / `--want`
# names: a window id, a worker id (its @fleet_id), or another machine's session a
# C4 window shows (@peer_cur). Nothing when none.
rv_thin_window() {
  local c="${2#wid:}"
  [ -n "$c" ] || return 1
  T list-windows -t "=$1" -F '#{window_id}|#{@fleet_id}|#{@peer_cur}' 2>/dev/null \
    | awk -F '|' -v c="$c" -v f="${c##*/}" '
        $1 == c || (index(c, "/") && (($2 != "" && $2 == f) || $3 == c || $3 == "wid:" c)) { print $1; exit }'
}
# rv_thin_home <session> — where a 看台 with nowhere to go back to lands: the
# orchestrator's window (「新任务」), else the session's current window.
rv_thin_home() {
  local w
  w=$(T list-windows -t "=$1" -F '#{window_id} #{@fleet_role}' 2>/dev/null | awk '$2 == "orchestrator" { print $1; exit }')
  [ -n "$w" ] || w=$(T display-message -p -t "=$1:" '#{window_id}' 2>/dev/null)
  printf '%s' "$w"
}
# rv_thin_cur <session> <window> <fleet uuid> — that window as `cur=` says it
# (the `cur` hook's rule, for the attach's own first write).
rv_thin_cur() {
  local fid pc
  IFS='|' read -r fid pc <<EOF
$(T display-message -p -t "$2" '#{@fleet_id}|#{@peer_cur}' 2>/dev/null)
EOF
  if [ -n "${pc:-}" ]; then printf '%s' "${pc#wid:}"
  elif [ -n "${fid:-}" ] && [ -n "$3" ]; then printf '%s/%s' "$3" "$fid"
  else printf '@%s' "${2#@}"; fi
}
# rv_node_label — this machine's name as the hub's rows say it: its
# FLEET_NODE_ALIASES name (`macmini=m5`), else the short hostname.
rv_node_label() {
  local h lh a
  h=${FLEET_SIDEBAR_HOST:-$(hostname -s 2>/dev/null)}; h=${h%%.*}
  lh=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  for a in ${FLEET_NODE_ALIASES:-}; do
    case "$a" in *=*) [ "$(printf '%s' "${a%%=*}" | tr '[:upper:]' '[:lower:]')" = "$lh" ] && { printf '%s' "${a#*=}"; return 0; } ;; esac
  done
  printf '%s' "$h"
}
# rv_thin_dress <session id> <view id> <fleet session> — the 看台's own options.
rv_thin_dress() {
  local gid="$1" v="$2" s="$3" bar
  bar="#(python3 '$BIN/fleet-topbar.py' render --node view=$v s=$s reg='$VIEWS' g='$FLEET_C/global'"
  bar="$bar sock=#{q:socket_path} cw=#{client_width} w=#{window_id} pc=#{q:@peer_cur} pd=#{pane_dead})"
  T set-option -t "$gid" status on \; set-option -t "$gid" status-position top \; \
    set-option -t "$gid" status-interval 2 \; set-option -t "$gid" status-style "bg=#1a1b26,fg=#565f89" \; \
    set-option -t "$gid" status-format[0] "$bar" \; set-option -t "$gid" destroy-unattached off \; \
    set-option -t "$gid" @view_thin "$v" 2>/dev/null
  # C2's key table, once it exists — a table tmux does not have would take every key
  T list-keys -T fleet-view >/dev/null 2>&1 && T set-option -t "$gid" key-table fleet-view 2>/dev/null \
    && { python3 "$BIN/fleet-quickopen.py" view-keys --if-stale --socket "$sock" </dev/null >/dev/null 2>&1 & }
  # ↑ and rebuilt, off the attach's path, when root moved since it was copied (a
  # personal conf re-sourced after the fleet's): the 看台's mouse is root's (#3000)
  # the `cur=` hook: global, but it acts only in a session marked @view_thin
  T set-hook -g 'session-window-changed[78]' \
    "if -F '#{@view_thin}' { run-shell -b \"bash '$BIN/fleet-remote-view.sh' cur '$VIEWS' '#{socket_path}' '#{hook_session_name}' >/dev/null 2>&1 || :\" }" 2>/dev/null
  return 0
}
rv_attach_thin() {
  local view='' want='' resume='' device='' route='' token='' s w='' g gid='' tty f p fu cur rc kept
  while [ $# -gt 0 ]; do
    case "$1" in
      --view) view="${2:-}"; shift 2 ;;
      --want) want="${2:-}"; shift 2 ;;
      --resume) resume=1; shift ;;
      --device) device="${2:-}"; shift 2 ;;
      --route) route="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      *) note "attach --thin: unknown option $1"; return 2 ;;
    esac
  done
  case "$view" in ''|*[!A-Za-z0-9-]*) note "attach --thin: bad or missing --view"; return 2 ;; esac
  case "$route$token" in *[!A-Za-z0-9._:-]*) note "attach --thin: bad --route / --token"; return 2 ;; esac
  case "$device" in *[!A-Za-z0-9+/=_-]*) note "attach --thin: --device is not base64"; return 2 ;; esac
  s=$(fleet_sockets | head -n 1)
  [ -n "$s" ] || { note "no fleet session is live on $(hostname -s)"; return 3; }
  sock=$(fleet_socket "$s")
  rv_prune
  rv_legacy_undo "$s"
  f="$VIEWS/$view"; g="$s@view-$view"
  cur=''; [ -n "$resume" ] && cur=$(rv_row_get "$f" cur)
  # The last connection of this id: its attach goes, its 看台 stays to be resumed.
  p=$(cut -f5 "$f" 2>/dev/null)
  case "$p" in ''|*[!0-9]*) ;; *)
    [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null \
      && ps -o command= -p "$p" 2>/dev/null | grep -q "fleet-remote-view\.sh attach .*$view" && rv_kill_attach "$p" ;;
  esac
  if T has-session -t "=$g" 2>/dev/null; then
    T detach-client -s "=$g" 2>/dev/null
    [ -n "$resume" ] || [ -n "$want" ] || [ -f "$f" ] || T kill-session -t "=$g" 2>/dev/null
  fi
  if [ -n "$want" ]; then
    w=$(rv_thin_window "$s" "$want")
    [ -n "$w" ] || note "attach --thin: ${want#*/} is not live on $(hostname -s) — landing elsewhere"
  fi
  kept=''
  T has-session -t "=$g" 2>/dev/null && gid=$(T display-message -p -t "=$g:" '#{session_id}' 2>/dev/null) && kept=1
  if [ -z "$gid" ]; then
    gid=$(T new-session -d -P -F '#{session_id}' -t "=$s" -s "$g" 2>/dev/null) \
      || { note "attach --thin: no 看台 session for $view"; return 1; }
    [ -n "$w" ] || w=$(rv_thin_window "$s" "$cur")
  fi
  # Nowhere named: a resumed 看台 still kept stays where it was; anything else lands home.
  [ -n "$w" ] || { [ -n "$resume" ] && [ -n "$kept" ]; } || w=$(rv_thin_home "$s")
  [ -z "$w" ] || T select-window -t "$gid:$w" 2>/dev/null
  rv_thin_dress "$gid" "$view" "$s"
  rv_hide_borders "$s"
  tty=$(tty 2>/dev/null) || tty=-
  fu=$(fleet_uuid "$s" 2>/dev/null) || fu=''
  mkdir -p "$VIEWS" 2>/dev/null
  w=$(T display-message -p -t "$gid:" '#{window_id}' 2>/dev/null)
  ( umask 077
    printf '%s\t%s\tthin\t%s\t%s\tcur=%s\troute=%s\tdevice=%s\ttoken=%s\tfuid=%s\tnode=%s\n' \
      "$tty" "$s" "$(date +%s)" "$$" "$(rv_thin_cur "$s" "$w" "$fu")" "$route" "$device" "$token" "$fu" "$(rv_node_label)" \
      > "$VIEWS/.$view.$$" && mv -f "$VIEWS/.$view.$$" "$f" ) \
    || { note "attach --thin: cannot register $view"; return 1; }
  trap 'rc=129' HUP
  T attach-session -t "$gid"; rc=$?
  # The 看台 stays: its row says since when nobody looks (only while it is ours).
  [ "$(cut -f5 "$f" 2>/dev/null)" = "$$" ] && rv_row_set "$f" left "$(date +%s)"
  return "$rc"
}

case "$mode" in
# ---------------------------------------------------------------------------------
# stage-health [<client session>] [<client tmp>] — the client's proxy windows, as `fleet
# doctor`'s `stage` row reads them (issue #2987). One line, `PASS|WARN<TAB><words>`,
# exit 1 on WARN. It flags what made every switch a full reconnect on the
# operator's MacBook: a window whose `@remote_ctl` socket is gone while its line is
# up, a warm master logged in as another login than the sessions it should carry,
# and a `run` loop no proxy pane runs (a stray: more than one per window).
stage-health)
  hs="${1:-${FLEET_SHELL_SESSION:-fleet-shell}}"
  htmp="${2:-${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}/tmp}"
  hwd="$htmp/warm"
  hbad='' hn=0 hpanes=' ' US='|'   # not a tab (`read` collapses empty tab fields), not a control byte (tmux escapes one in a format)
  hsay() { case "$hbad" in *"$1"*) ;; *) hbad="$hbad${hbad:+ · }$1" ;; esac; }
  hrows=$( { tmux -L "$hs-stage" list-windows -t "=$hs-stage" -F "#{window_id}$US#{@remote}$US#{@remote_login}$US#{@remote_ctl}$US#{@remote_down}$US#{pane_pid}" 2>/dev/null
             tmux -L "$hs" list-windows -t "=$hs" -F "#{window_id}$US#{@remote}$US#{@remote_login}$US#{@remote_ctl}$US#{@remote_down}$US#{pane_pid}" 2>/dev/null; } )
  while IFS="$US" read -r _ hrem hlg hctl hdown hpid; do
    case "$hrem" in -:*|'') continue ;; *:?*) ;; *) continue ;; esac
    hnode=${hrem%%:*}
    hn=$((hn + 1)); hpanes="$hpanes$hpid "
    if [ -n "$hctl" ] && [ -z "$hdown" ] && [ ! -S "$hctl" ]; then
      hsay "${hnode} 的控制连接 ${hctl##*/} 不在了（每次切换都重连）"
    fi
    if [ -n "$hlg" ] && [ ! -S "$hwd/$hnode@$hlg.sock" ] && [ -S "$hwd/$hnode.sock" ]; then
      hwl=$(rv_route_login "$hwd/$hnode.sock.route")
      [ -n "$hwl" ] && [ "$hwl" != "$hlg" ] && hsay "${hnode} 的预热连接登的是 ${hwl}，看的会话在 ${hlg}"
    fi
  done <<EOF_HROWS
$hrows
EOF_HROWS
  # stray loops: a client's `run --shell` whose parent is not a run (its own
  # subshells keep its command line) and that no proxy pane runs
  hstray=$(ps -ax -o pid= -o ppid= -o command= 2>/dev/null | awk -v panes="$hpanes" '
    $0 ~ /fleet-remote-view\.sh run --shell / { run[$1] = 1; pp[$1] = $2 }
    END { n = 0; for (p in run) if (!(pp[p] in run) && index(panes, " " p " ") == 0) n++; print n }')
  [ "${hstray:-0}" -gt 0 ] && hsay "${hstray} 个 run 循环不属于任何代理窗口（多余的会自己退）"
  if [ -n "$hbad" ]; then printf 'WARN\t%s\n' "$hbad"; exit 1; fi
  [ "$hn" -gt 0 ] || exit 0   # no client, or nothing open: no row
  printf 'PASS\t%s 个代理窗口 · 控制连接都在 · 预热连接登录对得上 · 每窗一个 run\n' "$hn"
  exit 0
  ;;
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
  # --node <m> [--name <n>] (issue #2236): a session the hub just opened there,
  # stepped into as the place answers — before the cache carries its row.
  shift
  while [ $# -ge 2 ]; do
    case "$1" in
      --node) [ -n "$node" ] || node=$2 ;;
      --name) [ -n "$row" ] || name=$2 ;;
    esac
    shift 2
  done
  [ -n "$node" ] || { tmux display-message "fleet: $wid 不在侧边栏的远程清单里" 2>/dev/null; exit 1; }
  case "$node" in *[!A-Za-z0-9._-]*) note "bad machine label: $node"; exit 2 ;; esac
  # `<name> · @m4` (issue #1780): the window name is also the pane header
  # (conf/tmux-attention.conf's pane-border-format; the stage's title line,
  # conf/tmux-shell-stage.conf), so the top of the pane says at a glance where
  # the keys go — in the sidebar row's own words: `@m4`, `@本机` when that machine
  # is this computer. No machine PREFIX on the name (#1475's `m4 <name>`), no ⇄
  # (#1621): a proxy window is known by `@remote`, never by its name.
  title="${name:-${wid#*/}} · @$(rv_machine_word "$node")"
  shellopt=''; [ "${FLEET_SHELL:-0}" = 1 ] && shellopt=' --shell'   # the shell's panes (#1484)
  cmd="exec bash $(sq "$BIN/fleet-remote-view.sh") run$shellopt $(sq "$node") $(sq "$wid")"
  # The shell's STAGE (issue #1759): there the proxy windows live on a server of
  # their own (FLEET_SHELL_STAGE, conf/tmux-shell-stage.conf) that the shell's one
  # window shows in its right pane — every window op below happens THERE, so a
  # switch repaints the right pane and nothing else. No stage (a fleet, or a
  # shell started before it): this server, as before.
  OT() { tmux "$@"; }; osess=$sess
  if [ "${FLEET_SHELL:-0}" = 1 ] && [ -n "${FLEET_SHELL_STAGE:-}" ] \
     && tmux -L "$FLEET_SHELL_STAGE" has-session -t "=$FLEET_SHELL_STAGE" 2>/dev/null; then
    OT() { tmux -L "$FLEET_SHELL_STAGE" "$@"; }; osess=$FLEET_SHELL_STAGE
  fi
  # one proxy window per (machine, LOGIN) — issue #2430: a row of the person's
  # other login on that machine is another connection, never a retarget over
  # this one (whose far end cannot see that login's fleet). `run` stamps the
  # window's login every round; an unstamped one (not up yet) is taken as is.
  olog=$(fleet_fleet_login "$wid" 2>/dev/null) || olog=''
  w=$(OT list-windows -t "=$osess" -F '#{window_id} #{@remote} #{@remote_login}' 2>/dev/null \
      | awk -v n="$node:" -v l="$olog" 'index($2, n) == 1 && ($3 == l || $3 == "") { print $1; exit }')
  if [ -n "$w" ]; then
    cur=$(OT show-options -wqv -t "$w" @remote 2>/dev/null)
    if [ "$cur" != "$node:$wid" ]; then
      # Another row of the SAME machine (issue #1484): over the proxy's own ssh
      # connection (`@remote_ctl`, the ControlMaster `run` holds), select that
      # worker's window there — the proxy, a client of that session, follows at
      # once. No master up, or the worker not live there: reconnect, as before.
      # Fastest first (issue #1682): the `serve` channel `run` keeps open on that
      # connection (`@remote_chan`) — one round trip, nothing started at either end.
      ctl=$(OT show-options -wqv -t "$w" @remote_ctl 2>/dev/null)
      rview=$(OT show-options -wqv -t "$w" @remote_view 2>/dev/null)   # its view session (#1489)
      chn=$(OT show-options -wqv -t "$w" @remote_chan 2>/dev/null)
      # A pane between two connections (issue #1876) — its line dropped, the
      # loop waiting out the back-off or reconnecting — has nothing to select
      # in: a one-shot `select` there "succeeds" against a far end with no view
      # session and the pane comes back on the worker it had. It is respawned on
      # the new row at once. A channel that does not answer in time is a dead
      # line too; a one-shot select gets the same bound.
      down=$(OT show-options -wqv -t "$w" @remote_down 2>/dev/null)
      SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"; host=$(ssh_host "$node"); rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
      # rv_sel <sock> — the one-shot `select` over that master, both steps bounded
      rv_sel() {
        rv_within "${FLEET_REMOTE_SELECT_SECS:-2}" $SSH -S "$1" -O check "$host" >/dev/null 2>&1 \
          && rv_within "${FLEET_REMOTE_SELECT_SECS:-2}" $SSH "${MUXO[@]}" -S "$1" "$host" "bash $rbin/fleet-remote-view.sh select $(sq "$wid")${rview:+ $(sq "$rview")}" >/dev/null 2>&1
      }
      t0=$(rv_ms); how=''; why=''
      crc=1; [ -z "$down" ] && [ -n "$chn" ] && { rv_chan_select "$chn" "$wid"; crc=$?; }
      if [ "$crc" = 0 ]; then
        how=chan
      elif [ -z "$down" ] && [ "$crc" != 2 ] && [ -n "$ctl" ] && [ -S "$ctl" ] && rv_sel "$ctl"; then
        how=select
      elif [ -z "$down" ] && [ "$crc" != 2 ] && [ -n "$ctl" ] && [ ! -S "$ctl" ] \
         && wsk=$(rv_warm_sock "$node" "$olog") && [ "$wsk" != "$ctl" ] && [ -S "$wsk" ] \
         && rv_warm_ok "$wsk" "$olog" && rv_sel "$wsk"; then
        # Its control socket is gone while the line lives (issue #2987): the far
        # end's view session is the same whichever master carries the `select`, so
        # the warm one does it — and the window adopts it for the next switch,
        # instead of a full reconnect on every switch from now on.
        how=readopt; why="$ctl gone → $wsk"
        OT set-window-option -t "$w" @remote_ctl "$wsk" 2>/dev/null
      else
        how=respawn
        if [ -n "$down" ]; then why=down
        elif [ "$crc" = 2 ]; then why='chan no answer'
        elif [ -z "$ctl" ]; then why='no ctl'
        elif [ ! -S "$ctl" ]; then why="ctl gone: $ctl"
        else why='select failed'; fi
      fi
      OT set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
      OT rename-window -t "$w" -- "$title" 2>/dev/null
      [ "$how" = respawn ] && OT respawn-pane -k -t "$w" -c "$HOME" "$cmd" 2>/dev/null
      rv_switch_log switch "$node" "$how" "$(( $(rv_ms) - t0 ))" "$why"
    fi
  else
    t0=$(rv_ms)
    w=$(OT new-window -d -P -F '#{window_id}' -t "=$osess:" -n "$title" -c "$HOME" "$cmd" 2>/dev/null) || exit 1
    rv_switch_log switch "$node" new "$(( $(rv_ms) - t0 ))"
    OT set-window-option -t "$w" @remote "$node:$wid" 2>/dev/null
    [ -n "$olog" ] && OT set-window-option -t "$w" @remote_login "$olog" 2>/dev/null
    OT set-window-option -t "$w" automatic-rename off 2>/dev/null
  fi
  OT select-window -t "$w" 2>/dev/null
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
  # ONE loop per window (issue #2987): `@remote_run` names the loop that owns this
  # pane. A loop that finds another's pid there is a stray — a respawn keeps the
  # pane id, so `pane_gone` never fires for it — and it ends at its next round
  # without touching the window (before this, a stray rewrote `@remote_ctl` to a
  # master it then closed, unset the live loop's `@remote_chan` and stamped
  # `@remote_down`: every switch after it was a full reconnect). A new loop ends
  # the one the window named, if it still runs.
  stray=''
  if [ -n "${TMUX:-}" ]; then
    # a pane that is not ours (see `mine` below): touch nothing, end
    pp=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_pid}' 2>/dev/null)
    case "$pp" in ''|*[!0-9]*|"$$"|"$PPID") ;; *) exit 0 ;; esac
    oldrun=$(tmux show-options -wqv -t "${TMUX_PANE:-}" @remote_run 2>/dev/null)
    case "$oldrun" in ''|*[!0-9]*|"$$") ;; *)
      case "$(ps -o command= -p "$oldrun" 2>/dev/null)" in
        *fleet-remote-view.sh*\ run\ *) kill "$oldrun" 2>/dev/null
          rv_switch_log stray-end "$node" run 0 "pid $oldrun" ;;
      esac ;;
    esac
    tmux set-window-option -t "${TMUX_PANE:-}" @remote_run "$$" \; \
         set-window-option -t "${TMUX_PANE:-}" @remote_ctl "$ctl" \; \
         set-window-option -t "${TMUX_PANE:-}" @remote_view "$view" 2>/dev/null
  fi
  # mine — this loop still owns its pane: the pane's process is this loop (`open`
  # execs `run` as the pane's command), and its window's `@remote_run` is not
  # another loop's. No tmux, or a server that does not answer = yes. Seen on the
  # operator's MacBook (issue #2987): a loop whose stage server was replaced kept
  # running as an orphan — the new server has the same socket path and REUSES the
  # pane ids, so `pane_gone` saw `%1` alive — and wrote its m5 line's
  # `@remote_ctl` / `@remote_down` onto the m4 window that now had `%1`.
  mine() {
    [ -n "$stray" ] && return 1
    [ -n "${TMUX:-}" ] || return 0
    local pp r
    pp=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_pid}' 2>/dev/null) || return 0
    # (or its parent: a pane whose command is `run …; more` runs it as a child)
    case "$pp" in ''|*[!0-9]*) ;; *) [ "$pp" = "$$" ] || [ "$pp" = "$PPID" ] || { stray=1; return 1; } ;; esac
    r=$(tmux show-options -wqv -t "${TMUX_PANE:-}" @remote_run 2>/dev/null) || return 0
    [ -z "$r" ] || [ "$r" = "$$" ] && return 0
    stray=1; return 1
  }
  side='' upg='' chn='' att=''
  stop_bg() {   # the sidecar, the upgrader, the channel, and whatever they are waiting in
    local p
    for p in $side $upg $chn; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    side='' upg='' chn=''
    [ -n "${TMUX:-}" ] && [ -z "$stray" ] && tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_chan 2>/dev/null
    rm -f "$ctl.cmd" "$ctl.ack"
  }
  cleanup() {
    stop_bg
    # the attach itself (issue #1704): it runs in the background now, so a TERM
    # reaches this trap at once — and must not leave it holding the far end's
    # view session (a session on the warm master outlives our own `-O exit`)
    [ -n "$att" ] && { pkill -P "$att" 2>/dev/null; kill "$att" 2>/dev/null; att=''; }
    $SSH -S "$ctl" -O exit "$host" >/dev/null 2>&1   # our own master only — never the warm one (#1631)
    rm -f "$ctl" "$ctl.route" "$ctl.upgrade" "$ctl.ssherr" "$ctl.nopaste"
    [ "$use" = "$ctl" ] || rm -f "$use.upgrade"
  }
  # pane_gone — before a reconnect: this loop's pane (or its whole tmux server)
  # is no more (issue #1704). A closed pane or a kill-server HUPs the loop, and
  # with the attach in the background that HUP reaches the trap at once; this
  # is the belt for a loop that slept through it. Only tmux's own "no such pane"
  # (or its socket gone) counts — a busy server that does not answer is not gone.
  pane_gone() {
    local err
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 1
    [ -S "${TMUX%%,*}" ] || return 0
    err=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_id}' 2>&1 >/dev/null)
    case "$err" in *"can't find pane"*|*"no server running"*) return 0 ;; esac
    return 1
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
    $SSH "${MUXO[@]}" -S "$use" "$host" "bash $rbin/fleet-remote-view.sh watch $(sq "$view")" 2>/dev/null \
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
    $SSH "${MUXO[@]}" -S "$use" "$host" "bash $rbin/fleet-remote-view.sh serve $(sq "$view")" \
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
  # route_via — `<auto|manual> <the route in words>` off `fleet connect`'s route
  # file (claude-fleet#2886; its route_label: 中转 · Tailscale · 直连 …); nothing
  # when it did not say (this loop's own line)
  route_via() {
    [ -s "$use.route" ] && [ -f "$BIN/fleet-connect.py" ] || return 0
    python3 -c 'import importlib.util,json,sys
try:
    spec = importlib.util.spec_from_file_location("fc", sys.argv[2]); fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
    d = json.load(open(sys.argv[1]))
    print("%s %s" % ("manual" if d.get("source") == "manual" else "auto", fc.route_label(d.get("kind"), d.get("name"))))
except Exception: pass' "$use.route" "$BIN/fleet-connect.py" 2>/dev/null
  }
  # @remote_route on the window: `relay` → the bar's machine chip says 「· 中转」;
  # @remote_via (claude-fleet#2886) the line and who chose it, for the top bar
  mark_route() {
    [ -n "${TMUX:-}" ] && [ -z "$stray" ] || return 0
    if [ "${1:-}" = relay ]; then tmux set-window-option -t "${TMUX_PANE:-}" @remote_route relay 2>/dev/null
    else tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_route 2>/dev/null; fi
    if [ -n "${2:-}" ]; then tmux set-window-option -t "${TMUX_PANE:-}" @remote_via "$2" 2>/dev/null
    else tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_via 2>/dev/null; fi
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
    local every="${FLEET_CONNECT_UPGRADE_SECS:-15}" idle="${FLEET_REMOTE_IDLE_SECS:-2}" _ up='' kind via
    for _ in $(seq 1 50); do
      $SSH -S "$use" -O check "$host" >/dev/null 2>&1 && { up=1; break; }
      sleep 0.2
    done
    [ -n "$up" ] || return 0
    kind=$(route_kind); via=$(route_via); mark_route "$kind" "$via"
    # a pinned line (claude-fleet#2886) is never left for a faster one
    case "$via" in manual\ *) return 0 ;; esac
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
  # In the shell (`--shell`) `fleet connect` picks the line on every connect; a
  # RECONNECT tries the remembered one first (FLEET_CONNECT_RETEST=last,
  # claude-fleet#2886) and re-measures them all only when it does not answer, or
  # after the upgrader found a direct line (=1, issue #1628). A PINNED machine
  # (`fleet route`, #2886) takes its one route every time: the page and the bar
  # say 「钉住：<route>（手动）· 第 N 次重连」, and after FLEET_ROUTE_FAIL_HINT (5)
  # failures in a row the page suggests auto — it never switches by itself.
  # A fleet's own proxy alternates direct / hub below.
  # Stuck past FLEET_DEBUG_STALL_SECS (60) with no session lasting (issue #2894):
  # the reconnect page says 「按 d 让远端看一眼」 and d sends fleet-debug report
  # from here — only on this page, never a key of the node's or the client's.
  route=direct; delay=1; retest=''; gone_since=''; tries=0; fails=0; stuck_since=''
  while :; do
    mine || { rv_switch_log stray-end "$node" run 0 "pid $$"; exit 0; }
    pin=''
    if [ -n "$shellopt" ]; then
      if [ -n "${FLEET_ROUTE_GET_CMD:-}" ]; then pin=$($FLEET_ROUTE_GET_CMD "$node" "$host" 2>/dev/null)
      elif [ -f "$BIN/fleet-route.py" ] && [ -s "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/routes" ]; then
        # no routes file = nothing pinned: no python started (fleet-connect.py's config_dir)
        pin=$(python3 "$BIN/fleet-route.py" --get "$node" "$host" 2>/dev/null)
      fi
    fi
    if [ -n "${TMUX:-}" ]; then
      if [ -n "$pin" ]; then
        tmux set-window-option -t "${TMUX_PANE:-}" @remote_pin "$pin" \; set-window-option -t "${TMUX_PANE:-}" @remote_tries "$tries" 2>/dev/null
      else
        tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_pin \; set-window-option -u -t "${TMUX_PANE:-}" @remote_tries 2>/dev/null
      fi
    fi
    pinsay=''
    if [ -n "$pin" ]; then
      case "$pin" in relay) pinsay='中转' ;; tailscale|tailnet) pinsay='Tailscale' ;; direct) pinsay='直连' ;; *) pinsay=$pin ;; esac
      pinsay=" · 钉住：${pinsay}（手动）"
      [ "$tries" -gt 0 ] && pinsay="${pinsay}· 第 ${tries} 次重连"
    fi
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
    pane_gone && exit 0   # the cleanup trap runs on the way out (issue #1704)
    # The row picked last (issue #1876): `open` writes it on this window, so a
    # reconnect lands where the person is now, not where this loop began.
    if [ -n "${TMUX:-}" ]; then
      cur=$(tmux show-options -wqv -t "${TMUX_PANE:-}" @remote 2>/dev/null)
      case "$cur" in "$node":?*) wid=${cur#"$node":} ;; esac
    fi
    # The login that holds this worker's fleet (issue #2430): one person may have
    # two logins on the machine, and the far end finds a worker only in its own
    # login's fleets. Named → every connection this round is made as it (`-l`,
    # and FLEET_CONNECT_LOGIN for `fleet connect`), and a warm master logged in
    # as anyone else is not ridden. Unnamed → the default login, as before.
    login=$(fleet_fleet_login "$wid" 2>/dev/null) || login=''
    lopt=(); [ -n "$login" ] && lopt=(-l "$login")
    export FLEET_CONNECT_LOGIN="$login"
    [ -n "${TMUX:-}" ] && tmux set-window-option -t "${TMUX_PANE:-}" @remote_login "$login" 2>/dev/null
    wsock=$(rv_warm_sock "$node" "$login")
    if [ -n "$shellopt" ] && [ "${FLEET_SHELL_WARM:-1}" != 0 ] && rv_warm_ok "$wsock" "$login"; then
      # A warm master still coming up (its `<sock>.pending` pid alive — the shell
      # and the first click start in the same second) is waited for, up to
      # FLEET_REMOTE_WARM_WAIT (5) s, instead of opening a private master beside
      # it (issue #1704); a round that does go private says so in warm.log.
      wdeadline=$(( $(date +%s) + ${FLEET_REMOTE_WARM_WAIT:-5} ))
      while :; do
        [ -S "$wsock" ] && $SSH -S "$wsock" -O check "$host" >/dev/null 2>&1 && { use="$wsock"; break; }
        wp=''; { read -r wp < "$wsock.pending"; } 2>/dev/null
        case "$wp" in ''|*[!0-9]*) break ;; esac
        kill -0 "$wp" 2>/dev/null && [ "$(date +%s)" -lt "$wdeadline" ] || break
        sleep 0.2
      done
      [ "$use" = "$ctl" ] && [ -d "${wsock%/*}" ] \
        && printf '%s private %s (run %s: warm not up)\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$node${login:+@$login}" $$ \
             >> "${wsock%/*}/warm.log" 2>/dev/null
    fi
    [ -n "${TMUX:-}" ] && tmux set-window-option -t "${TMUX_PANE:-}" @remote_ctl "$use" 2>/dev/null
    if [ "$use" != "$ctl" ]; then
      printf '\033[2J\033[H→ 正在连接 %s (%s · 已连%s) …\n' "$node" "$host" "$pinsay"
      opts=(-tt "${MUXO[@]}" -S "$use" ${lopt[@]+"${lopt[@]}"})
    else
      printf '\033[2J\033[H→ 正在连接 %s (%s%s%s%s) …\n' "$node" "$host" "$( [ "$route" = hub ] && printf ' · 经入口中转')" \
        "$( [ ${#peer[@]} -gt 0 ] && printf ' · 入口证书 5 分钟')" "$pinsay"
      # keepalive 2 s × 3: a dead line is seen in ≤ 6 s (issue #1631, was 5 × 3);
      # no compression (a LAN / tailnet only pays its latency), low-delay QoS
      opts=(-tt -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o ConnectTimeout=8
            -o "IPQoS=lowdelay throughput" -o Compression=no
            -o ControlMaster=yes -o "ControlPath=$ctl" "${MASTERO[@]}" -o ControlPersist=no ${peer[@]+"${peer[@]}"} ${lopt[@]+"${lopt[@]}"})
      [ "$route" = hub ] && opts+=(-o "ProxyCommand=$(sq "$BIN/fleet") connect --proxy $(sq "$(hub_node "$node")")")
      rm -f "$ctl" "$ctl.route" "$ctl.upgrade"
    fi
    rm -f "$use.upgrade"
    sidecar & side=$!
    upgrader & upg=$!
    chan & chn=$!
    started=$(date +%s)
    [ -n "$stuck_since" ] || stuck_since=$started
    # In the BACKGROUND, then `wait` (issue #1704): bash runs a trap only once the
    # foreground command returns, and an attach never returns — a TERM waited
    # forever. `wait` returns on a trapped signal; `0<&0` keeps the pane's tty as
    # its stdin (a background job's default is /dev/null). ssh's own words go to
    # a file, read back below in a person's words (issue #1775 §3).
    : > "$ctl.ssherr"
    # Between two connections nothing the person types is echoed (issue #1876):
    # ssh -tt takes the tty raw for the session and gives back this state.
    [ -t 0 ] && stty -echo 2>/dev/null
    [ -n "${TMUX:-}" ] && tmux set-window-option -u -t "${TMUX_PANE:-}" @remote_down 2>/dev/null
    # A file dropped in the shell (issue #2757): the ssh runs behind
    # fleet-client-upload.py's filter, which sends a bracketed paste of this
    # computer's file paths to the session's machine first and hands on the paths
    # there; every other byte passes untouched. A filter that broke once
    # (`$ctl.nopaste`) leaves this connection's later rounds on the bare ssh;
    # FLEET_CLIENT_PASTE=0 never starts it.
    pastewrap=()
    if [ -n "$shellopt" ] && [ "${FLEET_CLIENT_PASTE:-1}" != 0 ] && [ ! -e "$ctl.nopaste" ] \
       && [ -f "$BIN/fleet-client-upload.py" ]; then
      pastewrap=(python3 "$BIN/fleet-client-upload.py" filter --node "$node" --wid "$wid" --ctl "$use" --mark "$ctl.nopaste" --)
    fi
    FLEET_CONNECT_ROUTE_FILE="$ctl.route" FLEET_CONNECT_RETEST="$retest" \
      ${pastewrap[@]+"${pastewrap[@]}"} $SSH ${opts[@]+"${opts[@]}"} "$host" "bash $rbin/fleet-remote-view.sh attach$shellopt $(sq "$wid") $(sq "$view")" \
      0<&0 2>"$ctl.ssherr" &
    att=$!
    wait "$att"; rc=$?
    att=''
    # The line is gone (issue #1876): `open` now reconnects instead of selecting
    # over it, and the far end's tmux never got to turn its mouse reporting (and
    # bracketed paste) off in this pane — the outer tmux would keep handing it
    # SGR reports nobody reads. Off here, as the far end's exit would have.
    # when it dropped (issue #1904): the top line says `⟳ <secs>` off it
    mine && [ -n "${TMUX:-}" ] && tmux set-window-option -t "${TMUX_PANE:-}" @remote_down "$(date +%s)" 2>/dev/null
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l\033[?2004l'
    [ -t 0 ] && stty -echo 2>/dev/null
    stop_bg
    why=$(rv_ssh_why "$ctl.ssherr" | cut -c1-120)
    # the reason on a line of its own, above the drop line (issue #1775 §3): a
    # long one wrapping into it would split the line a person reads
    mark_route ''
    retest=last
    if [ -f "$use.upgrade" ]; then
      rm -f "$use.upgrade"
      retest=1
      # the upgrader closed the relay: a direct line answered — over to it now
      printf '\n%s 的直连通了，切回直连 …\n' "$node"
      delay=1; continue
    fi
    case "$rc" in
      0) exit 0 ;;                                   # the remote client ended on purpose
      3) # Not live there right now (issue #2484): a machine whose tmux restarted or
         # whose node program is updating brings its sessions back — same @fleet_id,
         # so the same address — within a tick or two. Ask again every
         # FLEET_REMOTE_GONE_STEP (5s) for FLEET_REMOTE_GONE_SECS (120s) before
         # saying it is gone.
         now=$(date +%s); [ -n "$gone_since" ] || gone_since=$now
         gstep=${FLEET_REMOTE_GONE_STEP:-5}; gmax=${FLEET_REMOTE_GONE_SECS:-120}
         if [ $(( now - gone_since )) -lt "$gmax" ]; then
           printf '\n%s 机器在重启，稍等 · 每 %ss 再连一次，最多 %ss\n' "$node" "$gstep" "$gmax"
           sleep "$gstep"; continue
         fi
         if [ "$wid" = - ]; then printf '\n%s 上没有活着的 fleet 会话。按任意键关闭。\n' "$node"
         else printf '\n%s 已不在 %s 上（结束或搬走了）。按任意键关闭。\n' "${wid#*/}" "$node"; fi
         read -r -n 1 -s _; exit 0 ;;
    esac
    gone_since=''
    # A drop after a good session reconnects at once; a failing route backs off and,
    # when the hub relay is configured, alternates with it.
    tries=$(( tries + 1 ))
    if [ $(( $(date +%s) - started )) -gt 30 ]; then delay=1; tries=1; fails=0; stuck_since=''
    else
      fails=$(( fails + 1 ))
      [ -z "$shellopt" ] && hub_relay_ok && { [ "$route" = direct ] && route=hub || route=direct; }
      [ "$delay" -lt 10 ] && delay=$(( delay * 2 ))
    fi
    [ -n "$why" ] && printf '\n原因：%s' "$why"
    if [ -n "$pin" ] && [ "$fails" -ge "${FLEET_ROUTE_FAIL_HINT:-5}" ]; then
      printf '\n钉住的线路已连续 %s 次连不上 · 要不要改回自动？fleet route %s auto（或 ⌘P 连接路线…）' "$fails" "$node"
    fi
    if [ -n "$shellopt" ]; then
      # The client's right pane (issue #1785): a dropped line is never the end of
      # it — Enter reconnects now, and ⌃c, which closed the window (and with the
      # stage's last one, the right pane), does nothing while it waits.
      printf '\n与 %s 的连接断了（exit %s）· %ss 后重连 · 回车立即重连\n' "$node" "$rc" "$delay"
      stall=''
      if [ -n "$stuck_since" ] && [ -t 0 ] && [ -f "$BIN/fleet-debug-prompt.sh" ] \
         && sh "$BIN/fleet-debug-prompt.sh" can; then
        stall=$(( $(date +%s) - stuck_since ))
        [ "$stall" -ge "${FLEET_DEBUG_STALL_SECS:-60}" ] || stall=''
      fi
      [ -z "$stall" ] || printf '%s\n' "$(sh "$BIN/fleet-ui-lang.sh" t debug_stall_key_fmt "$stall")"
      trap '' INT
      if [ -t 0 ] && [ -n "$stall" ]; then
        k=''; read -r -s -n 1 -t "$delay" k 2>/dev/null || :
        case "$k" in
          d|D)
            stty echo 2>/dev/null
            sh "$BIN/fleet-debug-prompt.sh" stall "正在连接 $node 卡住 ${stall}s · exit $rc${why:+ · $why}"
            printf '\n%s\n' "$(sh "$BIN/fleet-ui-lang.sh" t debug_stall_done)"
            read -r -s -n 1 _ 2>/dev/null || :
            stty -echo 2>/dev/null ;;
        esac
      elif [ -t 0 ]; then read -r -s -t "$delay" _ 2>/dev/null || :; else sleep "$delay"; fi
      trap 'cleanup; exit 0' INT
    else
      printf '\n与 %s 的连接断了（exit %s），%ss 后重连 · Ctrl-C 关闭窗口\n' "$node" "$rc" "$delay"
      sleep "$delay"
    fi
  done
  ;;

# ---------------------------------------------------------------------------------
attach)
  shell=''
  # `--thin` (issue #2763): the thin client's 看台, its own options — rv_attach_thin
  [ "${1:-}" = --thin ] && { shift; rv_attach_thin "$@"; exit $?; }
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
  reg=''; g=''; gid=''
  if { [ -n "$shell" ] || [ -n "$view" ]; } && tty=$(tty 2>/dev/null); then
    kind=view; [ -n "$shell" ] && kind=shell
    spool="$view"
    [ -n "$view" ] || view="$kind-$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9-' '-')$$-$RANDOM"
    case "$view" in *[!A-Za-z0-9-]*) note "attach: bad view id $view — not registered" ;; *)
      # The last connection of this very view id may still hold it (#1907).
      rv_takeover "$view" "$s@view-$view"
      if mkdir -p "$VIEWS" 2>/dev/null \
         && printf '%s\t%s\t%s\t%s\t%s\n' "$tty" "$s" "$kind" "$(date +%s)" "$$" > "$VIEWS/$view"; then
        reg="$view"
        [ -n "$spool" ] && mkdir -p "$VIEWS/$spool.d" 2>/dev/null
        # This client's own VIEW SESSION (issue #1489): grouped onto the fleet's —
        # the same windows, a current window of its own — with the status line and
        # prefix off for good (the person's own tmux has both). It starts on the
        # worker's window, or for `-` on the fleet session's current one. Never
        # the fleet session itself (#1907): a name still taken gets a unique
        # suffix (`select` finds it by prefix), and no session at all = exit 1,
        # which `run` reconnects.
        g="$s@view-$view"
        gid=$(T new-session -d -P -F '#{session_id}' -t "=$s" -s "$g" 2>/dev/null) \
          || { g="$s@view-$view-x$$"; gid=$(T new-session -d -P -F '#{session_id}' -t "=$s" -s "$g" 2>/dev/null); } \
          || gid=''
        if [ -n "$gid" ]; then
          T set-option -t "$gid:" status off \; set-option -t "$gid:" prefix None \; \
            set-option -t "$gid:" prefix2 None 2>/dev/null
          [ -n "$w" ] || w=$(T display-message -p -t "=$s:" '#{window_id}' 2>/dev/null)
          [ -z "$w" ] || T select-window -t "$gid:$w" 2>/dev/null
        else
          note "attach: no view session for $view — not attaching to the fleet session"
          rv_unregister "$view"
          exit 1
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
    # destroyed it before this client arrived. By session ID: a session id is
    # never reused, so a later connection's session of the same name (#1907) is
    # never this one's to kill.
    T attach-session -t "$gid" \; set-option -t "$gid:" destroy-unattached on; rc=$?
    T kill-session -t "$gid" 2>/dev/null
  else
    T attach-session -t "=$s"; rc=$?
  fi
  # Leaving changes nothing on this machine but the registry (issue #1713) — and
  # only this attach's own row: a reconnect may have written its own since.
  [ -n "$reg" ] && rv_unregister "$reg"
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
live)
  # ON <node> (issue #2219): exit 0 when this login has a live fleet session here
  # — what `attach -` would land on — else 1. The client asks it before it opens
  # its first window on THIS computer: no fleet here, no connection to fail.
  [ -n "$(fleet_sockets | head -n 1)" ]
  ;;
health)
  # ON <node> (issue #1907): `shared=<n> orphans=<m>` — registered remote clients
  # sitting on a fleet session instead of a view session of their own, and
  # attaches whose tmux client the server no longer has. fleet-doctor's `rview`.
  rv_scan | awk -F '\t' '{ c[$1]++ } END { printf "shared=%d orphans=%d\n", c["shared"], c["orphan"] }'
  ;;
prune)
  # ON <node>: what every attach does first, on demand — dead rows, unattached
  # view sessions, orphaned attaches (#1907).
  s=$(fleet_sockets | head -n 1)
  if [ -n "$s" ]; then sock=$(fleet_socket "$s"); rv_prune; else rv_reap_orphans; fi
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
# ⌃\ — THIS SESSION's shell (issue #2744; #2566 had it this computer's): a login
# shell of the machine the session runs on, as its login, in its working
# directory — the worker's `@worktree`, else its pane's directory (an
# orchestrator's $HOME, a no-repo session's own), so its branch, its tests and
# its logs are one key away; the next ⌃\ is back on the session.
#
#   shell-open <client session>   (a key on the client's server: the one-session
#                           view, or the client's solo layout) — the session is
#                           the current window's `@remote`, else the stage's
#                           current window's. Its shell window (`@solo_shell` =
#                           `<node>:<worker id>`, titled 「shell · <name> @<node>」)
#                           is selected when one is open — one a session, never
#                           two — else opened. No session there (a machine row,
#                           nothing open): this computer's shell in $HOME, as
#                           `prefix !` always is (`shell-open --local`, one too).
#   shell <node> <worker id>  that window's program: the warm master when it
#                           answers, else a master of its own through the same ssh
#                           program the proxy uses (in the client, `fleet-shell.sh
#                           ssh`: `fleet connect`, or right here when the machine
#                           is this computer) — then `shell-here` on the far end.
#                           A failed connection says why and waits for a key.
#   shell-here <worker id>  (ON <node>) — cd to the session's directory and exec
#                           the login's shell (`-l`) with the fleet's bin/ on its
#                           PATH and no worker credential in its environment; a
#                           watcher HUPs it when the session's window goes (a
#                           reaped session takes its shell along). Exit 3 when the
#                           session is not live here.
shell-open)
  if [ "${1:-}" = --local ]; then
    w=$(tmux list-windows -F '#{window_id} #{@solo_shell}' 2>/dev/null | awk '$2 == "local" { print $1; exit }')
    [ -n "$w" ] && { tmux select-window -t "$w"; exit 0; }
    # its PATH set by its own command: a new window's environment takes the
    # client's PATH over an `-e PATH=`
    lsh=$(tmux show-options -gv default-shell 2>/dev/null); [ -x "$lsh" ] || lsh=${SHELL:-/bin/sh}
    tmux new-window -n 本机shell -c "$HOME" \
      "exec env PATH=$(sq "$HOME/.local/bin:$BIN:$PATH") $(sq "$lsh") -l" \; \
      set-window-option @solo_shell local 2>/dev/null
    exit 0
  fi
  csess="${1:-}"
  r=$(tmux display-message -p '#{@remote}' 2>/dev/null)
  sname=''
  if [ -z "$r" ] && [ -n "$csess" ]; then
    r=$(tmux -L "$csess-stage" display-message -p -t "=$csess-stage:" '#{@remote}' 2>/dev/null)
    sname=$(tmux -L "$csess-stage" display-message -p -t "=$csess-stage:" '#{window_name}' 2>/dev/null)
  fi
  snode=${r%%:*}; swid=${r#*:}
  case "$snode" in ''|*[!A-Za-z0-9._-]*) exec bash "$BIN/fleet-remote-view.sh" shell-open --local ;; esac
  case "$swid" in ''|-|*[!A-Za-z0-9._/@:-]*) exec bash "$BIN/fleet-remote-view.sh" shell-open --local ;; esac
  # its own shell already open: there
  w=$(tmux list-windows -F '#{window_id} #{@solo_shell}' 2>/dev/null \
        | awk -v r="$r" '$2 == r { print $1; exit }')
  [ -n "$w" ] && { tmux select-window -t "$w"; exit 0; }
  # its name: the list's row (field 8), else the stage window's, else the id's tail
  rf="${TMPDIR:-/tmp}/.claude-dash/global/remote_$csess"
  n=$(LC_ALL=C awk -F $'\037' -v k="wid:$swid" '$1 == k { print $8; exit }' "$rf" 2>/dev/null)
  [ -n "$n" ] || n=${sname% · @*}
  [ -n "$n" ] && [ "$n" != "$snode" ] || n=${swid##*/}
  n=$(printf '%s' "$n" | tr -d '\000-\037#"' | cut -c1-40)
  tmux new-window -n "shell · $n @$snode" -c "$HOME" -e "PATH=$HOME/.local/bin:$BIN:$PATH" \
    "exec bash $(sq "$BIN/fleet-remote-view.sh") shell $(sq "$snode") $(sq "$swid")" \; \
    set-window-option @solo_shell "$r" \; set-window-option automatic-rename off \; \
    set-window-option allow-rename off 2>/dev/null
  exit 0
  ;;
shell)
  node="${1:-}"; wid="${2:-}"
  [ -n "$node" ] && [ -n "$wid" ] || { note 'usage: shell <node> <worker_id>'; exit 2; }
  host=$(ssh_host "$node")
  rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
  SSH="${FLEET_REMOTE_SSH_CMD:-ssh}"
  ctl="${TMPDIR:-/tmp}/frs.$$.$RANDOM"
  login=$(fleet_fleet_login "$wid" 2>/dev/null) || login=''
  lopt=(); [ -n "$login" ] && lopt=(-l "$login")
  export FLEET_CONNECT_LOGIN="$login"
  wsock=$(rv_warm_sock "$node" "$login")
  if [ "${FLEET_SHELL_WARM:-1}" != 0 ] && [ -S "$wsock" ] && rv_warm_ok "$wsock" "$login" \
     && $SSH -S "$wsock" -O check "$host" >/dev/null 2>&1; then
    opts=(-tt "${MUXO[@]}" -S "$wsock" ${lopt[@]+"${lopt[@]}"})
  else
    # as `run`: a plain-ssh view from a hub node rides a five-minute certificate
    # (issue #1626); rc 3 = no hub here, plain ssh; anything else = say why
    peer=()
    if [ -z "${FLEET_REMOTE_SSH_CMD:-}" ] && [ -f "$BIN/fleet-peer-cert.sh" ]; then
      peerout=$(bash "$BIN/fleet-peer-cert.sh" "$(hub_node "$node")" view 2>"$ctl.err"); prc=$?
      peerwhy=$(tail -n 1 "$ctl.err" 2>/dev/null); rm -f "$ctl.err"
      case "$prc" in
        0) while IFS= read -r o; do [ -n "$o" ] && peer+=("$o"); done <<EOF_PEER
$peerout
EOF_PEER
           ;;
        3) ;;
        *) printf '→ %s 的 shell 开不了：%s\n按任意键关闭。\n' "$node" "${peerwhy#fleet-peer-cert: }"
           read -r -n 1 -s _; exit 0 ;;
      esac
    fi
    opts=(-tt -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o ConnectTimeout=8
          -o ControlMaster=yes -o "ControlPath=$ctl" "${MASTERO[@]}" -o ControlPersist=no
          ${peer[@]+"${peer[@]}"} ${lopt[@]+"${lopt[@]}"})
    trap '$SSH -S "$ctl" -O exit "$host" >/dev/null 2>&1; rm -f "$ctl" "$ctl.ssherr"' EXIT
  fi
  printf '→ 正在打开 %s 上的 shell …\n' "$node"
  : > "$ctl.ssherr"
  # a far end older than shell-here (or with no fleet there) still answers: its
  # login shell in $HOME — either way one exec, so leaving it leaves the window
  $SSH ${opts[@]+"${opts[@]}"} "$host" \
    "if grep -qs '^shell-here)' $rbin/fleet-remote-view.sh; then exec bash $rbin/fleet-remote-view.sh shell-here $(sq "$wid"); fi; exec \"\${SHELL:-/bin/sh}\" -l" \
    2>"$ctl.ssherr"
  rc=$?
  case "$rc" in
    3)   printf '\n%s 已不在 %s 上（结束或搬走了）。按任意键关闭。\n' "${wid#*/}" "$node"; read -r -n 1 -s _ ;;
    255) why=$(rv_ssh_why "$ctl.ssherr" | cut -c1-120)
         printf '\n连不上 %s%s。按任意键关闭。\n' "$node" "${why:+：$why}"; read -r -n 1 -s _ ;;
  esac
  rm -f "$ctl.ssherr"
  exit 0
  ;;
shell-here)
  wid="${1:-}"; dir=''
  if [ -n "$wid" ] && [ "$wid" != - ]; then
    loc=$(fleet_worker_locate "wid:${wid#wid:}" 2>/dev/null)
    case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; exit 3 ;; esac
    set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
    dir=$(T display-message -p -t "=$s:$w" '#{@worktree}' 2>/dev/null)
    [ -n "$dir" ] && [ -d "$dir" ] || dir=$(T display-message -p -t "=$s:$w" '#{pane_current_path}' 2>/dev/null)
    # the session's window gone (reaped, moved): its shell goes with it
    shpid=$$
    ( trap '' HUP
      while sleep "${FLEET_SESSION_SHELL_WATCH:-5}"; do
        kill -0 "$shpid" 2>/dev/null || exit 0
        # (a display-message on a gone window still answers 0: list them)
        T list-windows -t "=$s" -F '#{window_id}' 2>/dev/null | grep -qxF "$w" \
          || { kill -HUP "$shpid" 2>/dev/null; exit 0; }
      done ) </dev/null >/dev/null 2>&1 &
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || dir=$HOME
  cd "$dir" 2>/dev/null || cd "$HOME" 2>/dev/null || :
  unset TMUX TMUX_PANE FLEET_WORKER_CRED FLEET_WORKER_ASSERT
  export PATH="$BIN:$HOME/.local/bin:$PATH"
  sh_=${FLEET_SESSION_SHELL_CMD:-${SHELL:-/bin/bash}}; [ -x "$sh_" ] || sh_=/bin/bash   # _CMD: the selftests
  exec "$sh_" -l
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
    if not issue and scratch != "1" and not ident:
        continue                                     # keyless: listed by identity (#1749)
    number = int(issue) if issue.isdigit() and int(issue) > 0 else None
    key = worker_key(number, scratch == "1", worktree, repo)
    wid = worker_identity(uuid, key or ident)
    if not wid:
        continue
    sessions.append({"worker_id": wid, "fleet_id": uuid, "fleet_name": sess, "machine_name": host,
                     "os_user": user, "availability": "online", "observed_at": now,
                     "worker": {"key": key, "issue": number,
                                "repo": repo if repo and repo != "?" else (None if repo else frepo or None),
                                "state": state or "unknown", "lifecycle": lifecycle or "awake",
                                "agent": agent or None, "name": name, "origin_wid": owid or None,
                                "needs": needs or None, "identity": ident,
                                "busy": extra.get("busy"), "born": extra.get("born"),
                                "cfg": extra.get("cfg"), "title": extra.get("title"),
                                "reap": extra.get("reap"), "epic": extra.get("epic"),
                                "epic_stale": extra.get("epic_stale"),
                                "backfill": extra.get("backfill"),
                                # issue #2431: the measurement bus, as the hub forwards it
                                "ctx_left": extra.get("ctx_left"), "ctx_band": extra.get("ctx_band"),
                                "ctx_ts": extra.get("ctx_ts"), "model": extra.get("model"),
                                "effort": extra.get("effort")}})
print(json.dumps({"sessions": sessions,
                  "nodes": [{"machine_name": host, "availability": "online",
                             "sessions": len(sessions), "observed_at": now}]}, ensure_ascii=False))
PY
  rc=$?; rm -f "$inv"; exit "$rc"
  ;;

*)
  sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2 ;;
esac
