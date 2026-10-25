#!/bin/bash
# fleet-remote-view.sh — the 看台's far end: what the thin client (fleet-thin.py)
# and its home machine run on a machine that holds sessions (issue #1424, EPIC
# #1419 C5; the 看台 since issue #2763, EPIC #2999). The old proxy window — a
# window here whose pane was an ssh client attached to another machine's session
# (`open` / `run` / a plain `attach` / `serve` / `watch` / `back` / `reconcile`) —
# was deleted with T606 (EPIC T605 C1): a 看台 reaches another machine through
# its peer window (fleet-peerlink.py), and those modes now say so and exit 2.
#
#   attach --thin --view <id> [--want <worker_id>|--resume] --device <b64>
#          --route <name> --token <nonce> [--lang <locale>]   (ON <node>, the thin client's home —
#                           issue #2763, EPIC #2999 C1) — the client's 看台: a view
#                           session that wears the top line itself and outlives its
#                           client for FLEET_VIEW_KEEP_SECS; see rv_attach_thin.
#   attach --thin --browser --home <window id> --view wt-<conn> …   (issue #4373)
#                           a browser's personal terminal (fleet-webterm.py attach):
#                           no `.last`, no ⌘N road — the session
#                           named, else the owned home pane's window.
#   attach --thin --view <id>-via-<home> …   (ON another machine, from a home
#                           machine's peer window — EPIC #2999 C4) — the same 看台,
#                           bare: no top line, no key table (the home draws both).
#   select <worker_id> [<view>]  (ON <node>) — select the worker's window in the
#                           看台 <view> (the fleet session when none is named or
#                           live); a home's peer window rides it on its standing
#                           link (the fast path below). Exit 3 when the worker is
#                           not live here; 5 when <view> is a home's far 看台
#                           (`*-via-*`, C4) not here yet.
#   deliver <worker_id>     (ON <node>, T992) — a new session's stub's words
#                           (JSON on stdin) handed to its agent here, see below.
#   cur / notify-jump       (the server's [78] / [79] hooks, in a @view_thin
#                           session) — see each below.
#   shell-here <worker id>  (ON <node>) — the session's own shell (⌃\), below.
#   live                    (ON <node>, issue #2219) — exit 0 when this login has a
#                           live fleet session here (what a 看台 lands on), 1 not.
#   health / prune          (ON <node>, issue #1907) — `shared=<n> orphans=<m>`:
#                           remote clients on the fleet session instead of a view
#                           session of their own, attaches whose tmux client is
#                           gone (fleet-doctor's `rview`); `prune` reaps what every
#                           attach reaps first.
#
# ONE VIEW SESSION PER CLIENT (issue #1489, EPIC #1479 R4): a tmux session has one
# current window, so two people on the fleet session kept switching each other
# away. A 看台 is a GROUPED session of its own — `new-session -t <fleet>`, named
# `<fleet>@view-<id>` — the fleet's windows, its own current window. A second
# session holding the same windows lists each twice in `list-windows -a`, so the
# fleet's scans go through fleet_lw (fleet-lib.sh), which drops the view sessions'
# rows, and every window→session read uses FLEET_SESSION_FMT, which names the
# fleet from a view session too. `select` targets the 看台's own session, so one
# 看台's switch moves nobody else's screen.
#
# Nesting — NO rule (issue #1713, EPIC #1710 C3; #1485's rule retired): the node
# never makes way for a viewer, because it has nothing of its own to hide. The one
# thing a window carries for everyone is its top header (pane-border-status, a
# WINDOW option): a window a 看台 looks at loses it ONE WAY (issue #1549 — the
# 看台's top line is the one title line) and never gets it back, so no client
# change ever resizes a pane. Never `resize-pane -Z`.
#
# The registry $FLEET_CONF_DIR/remote-views/<id>: one line per client,
# `<tty> <session> <kind> <since epoch> <pid>` (tab-separated — the first two
# columns are what fleet-open.sh reads) and, for a 看台 (kind `thin`), key=value
# columns after. A row whose attach shell is gone (SIGKILLed before its cleanup)
# does not count and is pruned at the next attach, so a tty the next login reuses
# is never mistaken for a client.
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
  # Issue #4000: and the person's LAST session, kept past this 看台 (`.last`, one
  # line, this login's — every device that comes home here reads it): a plain
  # `fleet` lands there next time. Only a session (a worker id), never a bare
  # window id — tmux deals those out again after a restart; never a far 看台's.
  case "$_v:$_c" in *-via-*:*|*:@*) ;; *)
    [ "$(cat "${2:-}/.last" 2>/dev/null)" = "$_c" ] \
      || { printf '%s\n' "$_c" > "${2:-}/.last.$$" && mv -f "${2:-}/.last.$$" "${2:-}/.last"; } 2>/dev/null ;;
  esac
  # Issue #3489: and the thin loop on the person's computer is told, in the 7502
  # it already reads (`ESC ] 7502 ; cur ; token=… ; m= ; l= ; w= BEL`, on the tty
  # of the client attached to THIS 看台 — never a row's old tty, which another
  # program may hold by now): a file dropped there goes to the session in view
  # (fleet-thin.py send → `fleet-client-upload.py recv <m> <l> <w>` here). m=- l=-
  # is this machine (recv's own inbox, whatever alias the machine goes by); another
  # machine's window says its @peer. Until a home said it, every drop failed.
  # A far 看台 (`-via-`) has no thin loop of its own — its home's says it.
  case "$_v" in *-via-*) exit 0 ;; esac
  _t=$(rv_row_get "$_f" token)
  case "$_t" in ''|*[!A-Za-z0-9._:-]*) exit 0 ;; esac
  _y=$(tmux -S "$3" list-clients -t "=$4" -F '#{client_tty}' 2>/dev/null | head -n 1)
  case "$_y" in /dev/*) ;; *) exit 0 ;; esac
  _m=- _l=-
  if [ -n "${_pc:-}" ]; then
    _p=$(tmux -S "$3" display-message -p -t "=$4:" '#{@peer}' 2>/dev/null)
    case "$_p" in ?*@?*) _m=${_p%@*} _l=${_p##*@} ;; esac
  fi
  _ok() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._:@/-'; }
  # #4379: bind an upload to this selection and the active pane/agent launch.
  # Old clients ignore g; new clients fail attachments visibly on an old home.
  _g="$$-$(date +%s)"
  _snap=$(tmux -S "$3" display-message -p -t "=$4:" '#{window_id}|#{@fleet_id}|#{@peer_cur}|#{pane_id}|#{pane_pid}|#{@cc_launcher_pid}|#{@cc_session_id}|#{@codex_session_id}|#{pane_current_command}|#{pane_dead}' 2>/dev/null)
  rv_row_set "$_f" upload_target "$_snap" || exit 0
  rv_row_set "$_f" upload_gen "$_g" || exit 0
  # Invalidate a cached upload line before this selection's first redraw.
  tmux -S "$3" set-option -t "=$4:" @view_upload_id '' \; \
    set-option -t "=$4:" @view_upload_gen "$_g" 2>/dev/null
  printf '\033]7502;cur;token=%s;m=%s;l=%s;w=%s;g=%s\007' "$_t" "$(_ok "$_m")" "$(_ok "$_l")" "$(_ok "$_c")" "$_g" 2>/dev/null > "$_y"
  exit 0
fi

# `select <worker_id> <view>` for a home machine's peer window (issue #2751, EPIC
# #2999 C4): the far 看台 `<id>-via-<home>` a thin client's home keeps here shows
# that worker. It rides ONE channel of the home's standing link on every switch to
# another session of this machine, so it runs before the lib: the 看台's row names
# its fleet session (the socket label) and fleet UUID, and three tmux calls do the
# rest — the 看台's own client switches (its window takes this viewer's size,
# #1933). Exit 3 not live here, 5 no such far 看台 here yet; anything else it
# cannot judge (no such row, another fleet's UUID) falls through to rv_select below.
if [ "${1:-}" = select ] && [ -n "${3:-}" ]; then
  _v=$3; _f="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/remote-views/$_v"; _row=''
  case "$_v" in *[!A-Za-z0-9-]*) ;; *) [ -f "$_f" ] && IFS= read -r _row < "$_f" ;; esac
  _s=''; _u=''; _k=''
  case "$_row" in *"	thin	"*)
    _s=${_row#*	}; _s=${_s%%	*}
    case "$_row" in *"	fuid="*) _u=${_row#*	fuid=}; _u=${_u%%	*} ;; esac ;;
  esac
  # No thin row for a far 看台 yet: 5 HERE (issue #3036). Falling through, the
  # attach could write its row while the lib loads, and the slow path below —
  # seeing it thin — would answer rv_select's 3 (gone) for a 看台 one beat old.
  case "$_v" in *-via-*) [ -n "$_s" ] || exit 5 ;; esac
  _t=${2#wid:}
  if [ -n "$_s" ] && [ -n "$_u" ] && [ "${_t%%/*}" = "$_u" ]; then
    command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    _g="$_s@view-$_v"; _w=''; _c=''; _id=${_t#*/}
    # a worker the hub names by its KEY (`<fleet UUID>/<key>`, fleet_worker_id_key —
    # issue #3007; every scratch session of a repo): the identity the one resolver
    # answered for it last time (rv_select's .wid-fid, T691), used only while a live
    # window still wears it — the slow road below cost 130-400 ms on a busy machine,
    # on most of a home's switches to another machine
    case "$_id" in *:*|issue-[0-9]*|scratch-[0-9]*) _id=$(awk -F '\t' -v k="$_t" '$1 == k { v = $2 } END { print v }' "${_f%/*}/.wid-fid" 2>/dev/null) ;; esac
    # one tmux call for both: the fleet's windows, then the 看台's client
    while IFS=' ' read -r _k _a _b; do
      case "$_k" in
        W) [ -z "$_w" ] && [ -n "$_id" ] && [ "$_b" = "$_id" ] && _w=$_a ;;
        C) [ -z "$_c" ] && _c=$_a ;;
      esac
    done <<EOF
$(tmux -L "$_s" list-windows -t "=$_s" -F 'W #{window_id} #{@fleet_id}' \; list-clients -t "=$_g" -F 'C #{client_tty}' 2>/dev/null)
EOF
    # no window carries that @fleet_id (or the key's remembered one): rv_select
    # below resolves it the one way (fleet_worker_locate) and answers 3 itself
    if [ -n "$_w" ]; then
      # a PARKED window's pane stuck in copy-mode is let out first (BREAK-IT
      # park-page-copy-mode, the same words as fleet_view.park_unmode); a live one never
      tmux -L "$_s" if-shell -F -t "$_w" '#{?#{@parked},#{pane_in_mode},0}' "send-keys -t $_w -X cancel" 2>/dev/null
      case "$_v" in wt-*) python3 "$BIN/fleet-webterm.py" switch --conn "${_v#wt-}" --window "$_w"; exit $? ;; esac
      { [ -n "$_c" ] && tmux -L "$_s" switch-client -c "$_c" -t "=$_g:$_w" 2>/dev/null; } \
        || tmux -L "$_s" select-window -t "=$_g:$_w" 2>/dev/null || exit 5
      exit 0
    fi
  fi
fi

# `notify-jump <socket> <session>` (issue #3005, EPIC #2999 C8) — run by the
# server's client-focus-in[79] hook, only in a session marked `@view_thin`: a
# notification fleet_thin_lease.py sent to this 看台's terminal armed
# `@notify_jump "<epoch> wid:<worker id>"` on it while the terminal was not in
# front; the click brings the terminal back, the focus-in lands here and the
# 看台 goes to that session — through C2's `fleet-view-go.sh`, else (it said
# no) straight to this machine's window that holds it. Older than
# FLEET_NOTIFY_JUMP_SECS (60 s): dropped. Before the lib: it runs on every focus-in.
if [ "${1:-}" = notify-jump ]; then
  command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  _s="${3:-}"; case "$_s" in *@view-*) ;; *) exit 0 ;; esac
  _val=$(tmux -S "$2" show-options -qv -t "=$_s:" @notify_jump 2>/dev/null)
  [ -n "$_val" ] || exit 0
  tmux -S "$2" set-option -u -t "=$_s:" @notify_jump 2>/dev/null
  _at=${_val%% *}; _key=${_val#* }; _wid=${_key#wid:}
  case "$_at" in ''|*[!0-9]*) exit 0 ;; esac
  [ $(( $(date +%s) - _at )) -le "${FLEET_NOTIFY_JUMP_SECS:-60}" ] || exit 0
  [ -n "$_wid" ] && [ "$_wid" != "$_val" ] || exit 0
  # C2's one way a 看台 changes session; it says no (another machine not yet
  # connected, gone) ⇒ this machine's own window, if it has one
  [ -f "$BIN/fleet-view-go.sh" ] && bash "$BIN/fleet-view-go.sh" "$_s" "$_wid" --how notify >/dev/null 2>&1 && exit 0
  case "$_s" in *@view-wt-*) exit 0 ;; esac # a refused browser lease must stay refused
  _w=$(tmux -S "$2" list-windows -t "=$_s" -F '#{window_id}|#{@fleet_id}|#{@peer_cur}' 2>/dev/null \
    | awk -F '|' -v c="$_wid" -v f="${_wid##*/}" '$2 != "" && $2 == f || $3 == c || $3 == "wid:" c { print $1; exit }')
  [ -n "$_w" ] && tmux -S "$2" select-window -t "=$_s:$_w" 2>/dev/null
  exit 0
fi

[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# A non-interactive ssh session has a bare PATH: find tmux where Homebrew puts it.
command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

VIEWS="$FLEET_CONF_DIR/remote-views"
mode="${1:-}"; [ $# -gt 0 ] && shift

note() { printf 'fleet-remote-view: %s\n' "$*" >&2; }

T() { tmux -L "$sock" "$@"; }   # the REMOTE fleet's server; each mode sets $sock first

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
  rv_peer_sweep
  rv_reap_orphans
}
# rv_peer_sweep — a 看台's peer windows (C4, `@peer_view <id>`) go with it: a window
# whose 看台 session is gone is closed, and its pane's ssh with it (#1298 reaps any
# straggler). A window of a 看台 still here — kept or attached — stays.
rv_peer_sweep() {
  local w v live
  live=$(T list-sessions -F '#{session_name}' 2>/dev/null)
  fleet_lw '#{window_id} #{@peer_view}' T | while read -r w v; do
    case "$v" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    printf '%s\n' "$live" | grep -q "@view-$v\$" && continue
    T kill-window -t "$w" 2>/dev/null
  done
}
# --- orphaned attaches (issue #1907) ---------------------------------------------
# An attach whose line died without sshd noticing keeps its tmux client process —
# stuck writing to a tty nobody reads — long after the server dropped that client
# (mac-a, 2026-10-06: six of them, one to two days old, none in `list-clients`). Its
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
# A window a shell/view looks at loses its own top header, ONE WAY (issues #1549,
# #1713): the viewer's `<name> · @mac-a` header is the one title line, and since it never
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
# rv_wid_fid <uuid/key> <window> — remember the identity fleet_worker_locate found
# for a worker the hub names by its key (T691): the select fast path at the top
# reads $VIEWS/.wid-fid (a dot name: no row scan sees it), last 200 workers. A
# worker already named by its identity writes nothing.
rv_wid_fid() {
  local f="$VIEWS/.wid-fid" fid
  case "${1#*/}" in *:*|issue-[0-9]*|scratch-[0-9]*) ;; *) return 0 ;; esac
  fid=$(T display-message -p -t "$2" '#{@fleet_id}' 2>/dev/null)
  case "$fid" in ''|*[!A-Za-z0-9-]*) return 0 ;; esac
  [ "$(awk -F '\t' -v k="$1" '$1 == k { v = $2 } END { print v }' "$f" 2>/dev/null)" = "$fid" ] && return 0
  mkdir -p "$VIEWS" 2>/dev/null
  { awk -F '\t' -v k="$1" '$1 != k' "$f" 2>/dev/null; printf '%s\t%s\n' "$1" "$fid"; } \
    | tail -n 200 > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
  return 0
}
# rv_select <worker_id> [<view>] — the worker's window becomes the current one of
# the view session (the fleet session when none is named or live). 3 = not live
# here.
rv_select() {
  local wid="${1#wid:}" view="${2:-}" loc tgt g c w s
  loc=$(fleet_worker_locate "wid:$wid" 2>/dev/null)
  case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; return 3 ;; esac
  set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
  rv_wid_fid "$wid" "$w"
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
  # A home machine's far 看台 (C4) not attached yet: never the fleet session's own
  # window — 5, and the home's peer window lands there when it attaches
  case "$view" in *-via-*) [ "$tgt" = "$s" ] && return 5 ;; esac
  # A view's own client switches (issue #1933): `switch-client -c` makes it the
  # window's latest client, so the window takes THIS viewer's size (the node runs
  # `window-size latest`); a bare select-window comes from no client and leaves
  # the window at whoever typed into it last. No client attached → select-window.
  c=''; [ "$tgt" = "$s" ] || c=$(T list-clients -t "=$tgt" -F '#{client_tty}' 2>/dev/null | head -1)
  # a PARKED window's pane stuck in copy-mode is let out first (BREAK-IT
  # park-page-copy-mode, the fast path's words above); a live one never
  T if-shell -F -t "$w" '#{?#{@parked},#{pane_in_mode},0}' "send-keys -t $w -X cancel" 2>/dev/null
  case "$view" in wt-*) python3 "$BIN/fleet-webterm.py" switch --conn "${view#wt-}" --window "$w"; return $? ;; esac
  { [ -n "$c" ] && T switch-client -c "$c" -t "=$tgt:$w" 2>/dev/null; } \
    || T select-window -t "=$tgt:$w" 2>/dev/null || { note "cannot select $w"; return 3; }
  rv_hide_border "$w"   # a window spawned since the attach (#1549, #1682)
  return 0
}

# --- the thin client's 看台 (issue #2763, EPIC #2999 C1, 共同约定 6) ---------------
# `attach --thin --view <id> [--want <worker_id>|--resume] --device <b64 json>
#  --route <name> --token <nonce> [--lang <locale>]` — what the thin client (C6) runs on its home
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
# (+ `caps=` when the loop says what it takes, issue #3541; + `cv=` its client
# version, issue #4916) after the five columns; `cur=` follows the session in view — a server hook,
# session-window-changed[78], gated on the session's `@view_thin`, runs `cur`
# above on every change. The 看台 OUTLIVES its client: no destroy-unattached; on
# the attach's exit the row gets `left=<epoch>` and rv_prune (every attach, the
# collector's `views` phase) takes row + session FLEET_VIEW_KEEP_SECS (600) later.
# `--resume` comes back to it — the same session when it is still kept, else a
# new one on `cur=`. A plain `fleet` (no --want, no --resume — a new run, any
# device) lands on the person's LAST session (`.last`, the `cur` hook's, issue
# #4000): here, or on another machine through the 看台's switch road. Gone, or
# never seen one, the first screen is `do land` (task Q1A8): ⌘P's panel on the
# person's most recently active session anywhere (FLEET_VIEW_LAND=last: straight
# onto it) — a new session (⌘N's road) only when they have none at all; no
# session is anyone's home (issue #4341).
# rv_restoring — a restore of this login holds its lock right now (a live pid in
# fleet-restore's $FLEET_CONF_DIR/restore/.auto.lock, which the snapshot restore
# takes too): sessions are being reopened.
rv_restoring() {
  local pid
  pid=$(cat "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/restore/.auto.lock/pid" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}
rv_thin_kept() {   # <row file> — still inside its keep window (left=, else its mtime)
  local t keep="${FLEET_VIEW_KEEP_SECS:-600}"
  case "$keep" in ''|*[!0-9]*) keep=600 ;; esac
  t=$(rv_row_get "$1" left)
  # GNU first: GNU stat takes `-f` for its filesystem mode, prints that and exits 1,
  # so `stat -f %m || stat -c %Y` read two texts there; BSD stat refuses `-c` (#3513)
  case "$t" in ''|*[!0-9]*) t=$(stat -c %Y "$1" 2>/dev/null) || t=$(stat -f %m "$1" 2>/dev/null) ;; esac
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(date +%s) - t )) -lt "$keep" ]
}
# rv_thin_window <session> <cur> — the window of <session> a `cur=` / `--want`
# names: a window id, a worker id (its @fleet_id), or another machine's session a
# C4 window shows (@peer_cur). Nothing when none.
rv_thin_window() {
  local c="${2#wid:}" w loc
  [ -n "$c" ] || return 1
  w=$(T list-windows -t "=$1" -F '#{window_id}|#{@fleet_id}|#{@peer_cur}' 2>/dev/null \
    | awk -F '|' -v c="$c" -v f="${c##*/}" '
        $1 == c || (index(c, "/") && (($2 != "" && $2 == f) || $3 == c || $3 == "wid:" c)) { print $1; exit }')
  # A worker id by its key (`<uuid>/<slug>:issue-<N>` — what the list hands for an
  # issue-bound session, issue #3463): the one resolver knows it. Before this a
  # peer window's reconnect (`--want` its @peer_cur) found no such window and
  # landed on whatever the fleet session showed — a bare shell, on the phone.
  if [ -z "$w" ] && case "$c" in */*) true ;; *) false ;; esac; then
    loc=$(fleet_worker_locate "wid:$c" "$1" 2>/dev/null)
    case "$loc" in "local "*" $1") w=${loc#local }; w=${w%% *} ;; esac
  fi
  [ -n "$w" ] || return 1
  printf '%s\n' "$w"
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
# FLEET_NODE_ALIASES name (`mac-c=mac-b`), else the short hostname.
rv_node_label() {
  local h lh a
  h=${FLEET_SIDEBAR_HOST:-$(hostname -s 2>/dev/null)}; h=${h%%.*}
  lh=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  for a in ${FLEET_NODE_ALIASES:-}; do
    case "$a" in *=*) [ "$(printf '%s' "${a%%=*}" | tr '[:upper:]' '[:lower:]')" = "$lh" ] && { printf '%s' "${a#*=}"; return 0; } ;; esac
  done
  printf '%s' "$h"
}
# rv_thin_bar <view id> <fleet session> — the 看台's top line, as status-format[0].
rv_thin_bar() {
  local v="$1" s="$2" bar
  bar="#(python3 '$BIN/fleet-topbar.py' render --node view=$v s=$s reg='$VIEWS' g='$FLEET_C/global'"
  bar="$bar sock=#{q:socket_path} cw=#{client_width} w=#{window_id} pc=#{q:@peer_cur} pd=#{pane_dead}"
  # this connection's language (issue #3329): what attach set; the message row
  # (T701): the line opens it (status 2) while a message not seen yet is live and
  # folds it after (ib=1 · st=#{status} · vs=#{session_id})
  bar="$bar vl=#{q:@view_lang_set}:#{q:@view_lang} ib=1 st=#{status} vs='#{session_id}'"
  printf '%s' "$bar up=#{q:@view_upload})"
}
# rv_thin_inbox — the 看台's message row (T701), as status-format[1]: drawn only
# while `status` is 2 (bin/fleet_notice.py's book, every machine's)
rv_thin_inbox() {
  printf '%s' "#(python3 '$BIN/fleet-topbar.py' inbox --node g='$FLEET_C/global' cw=#{client_width} vl=#{q:@view_lang_set}:#{q:@view_lang})"
}

# rv_thin_dress <session id> <view id> <fleet session> — the 看台's own options.
rv_thin_dress() {
  local gid="$1" v="$2" s="$3" bar
  # A home machine's far 看台 (`<id>-via-<home>`, C4): its client is a pane of that
  # home's 看台, which draws the top line and holds the keys — bare here (status
  # off, no key table), only the `cur=` hook and the keep rule.
  # A 看台 rings only for the window it shows (issue #3090): the node's global
  # `bell-action any` passed every worker's BEL — a turn's end, a question — to the
  # person's terminal, and a far 看台's through its peer window. Another session
  # wanting you reaches them as fleet_notify's OSC 9 (fleet_thin_lease.py notify).
  # A session option: the fleet session and an old client's view keep `any`.
  T set-option -t "$gid" bell-action current 2>/dev/null
  case "$v" in *-via-*)
    T set-option -t "$gid" status off \; set-option -t "$gid" destroy-unattached off \; \
      set-option -t "$gid" @view_thin "$v" 2>/dev/null
    T set-hook -g 'session-window-changed[78]' \
      "if -F '#{@view_thin}' { run-shell -b \"bash '$BIN/fleet-remote-view.sh' cur '$VIEWS' '#{socket_path}' '#{hook_session_name}' >/dev/null 2>&1 || :\" }" 2>/dev/null
    return 0 ;;
  esac
  bar=$(rv_thin_bar "$v" "$s")
  # The bar sits at the BOTTOM (task NFVN): with status lines on top, tmux 3.7c
  # checks the ⌘P popup against the window's rows instead of the terminal's when
  # it repaints a pane (screen_redraw_draw_pane: tty_check_overlay_range gets wy,
  # not py), so every whole repaint — any set-option on the server — drew the pane
  # over the popup's top two rows and the frame's top edge flickered. Bottom ⇒
  # the two coincide. Back on top once the pinned tmux carries the fix.
  T set-option -t "$gid" status on \; set-option -t "$gid" status-position bottom \; \
    set-option -t "$gid" status-interval 2 \; set-option -t "$gid" status-style "bg=#1a1b26,fg=#565f89" \; \
    set-option -t "$gid" status-format[0] "$bar" \; set-option -t "$gid" status-format[1] "$(rv_thin_inbox)" \; \
    set-option -t "$gid" @view_inbox 1 \; set-option -t "$gid" destroy-unattached off \; \
    set-option -t "$gid" @view_thin "$v" 2>/dev/null
  # C2's key table, once it exists — a table tmux does not have would take every key
  T list-keys -T fleet-view >/dev/null 2>&1 && T set-option -t "$gid" key-table fleet-view 2>/dev/null \
    && { python3 "$BIN/fleet-quickopen.py" view-keys --if-stale --socket "$sock" </dev/null >/dev/null 2>&1 & }
  # ↑ and rebuilt, off the attach's path, when root moved since it was copied (a
  # personal conf re-sourced after the fleet's): the 看台's mouse is root's (#3000)
  # the `cur=` hook: global, but it acts only in a session marked @view_thin
  T set-hook -g 'session-window-changed[78]' \
    "if -F '#{@view_thin}' { run-shell -b \"bash '$BIN/fleet-remote-view.sh' cur '$VIEWS' '#{socket_path}' '#{hook_session_name}' >/dev/null 2>&1 || :\" }" 2>/dev/null
  # a notification's click (issue #3005): the terminal back in front takes the
  # jump armed on this 看台 — global too, acting only in a @view_thin session
  T set-hook -g 'client-focus-in[79]' \
    "if -F '#{@view_thin}' { run-shell -b \"bash '$BIN/fleet-remote-view.sh' notify-jump '#{socket_path}' '#{client_session}' >/dev/null 2>&1 || :\" }" 2>/dev/null
  return 0
}
# Values are arguments captured by the EXIT trap: rv_attach_thin's locals are
# already out of scope when the dispatcher exits after a normal detach.
rv_browser_cleanup() {
  local bsock="$1" bgid="$2" bf="$3" bpid="$4" bv="$5" bs="$6" bw bp br
  [ "$(cut -f5 "$bf" 2>/dev/null)" != "$bpid" ] || rm -rf "$bf" "$bf.d"
  [ "$(tmux -L "$bsock" show-options -qv -t "$bgid" @view_thin 2>/dev/null)" != "$bv" ] \
    || tmux -L "$bsock" kill-session -t "$bgid" 2>/dev/null
  # Only peer panels made by this connection, never another view or a worker.
  tmux -L "$bsock" list-windows -t "=$bs" -F '#{window_id}|#{@peer_view}|#{@fleet_role}' 2>/dev/null \
    | while IFS='|' read -r bw bp br; do
        [ "$bp:$br" != "$bv:panel" ] || tmux -L "$bsock" kill-window -t "$bw" 2>/dev/null
      done
  return 0
}

rv_attach_thin() {
  local view='' want='' resume='' device='' route='' token='' lang='' setlang='' hint='' s w='' g gid='' tty f p fu cur rc kept wfar newfar sp last lastgone caps rh
  local browser='' bhome=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --view) view="${2:-}"; shift 2 ;;
      # a browser's personal terminal (issue #4373, fleet-webterm.py attach): never
      # the last-session / ⌘N fallback — nothing named or not live lands on the
      # owned home pane's window, and no session is ever started for it
      --browser) browser=1; shift ;;
      --home) bhome="${2:-}"; shift 2 ;;
      --want) want="${2:-}"; shift 2 ;;
      --resume) resume=1; shift ;;
      --device) device="${2:-}"; shift 2 ;;
      --route) route="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      --lang) lang="${2:-}"; setlang=1; shift 2 ;;
      *) note "attach --thin: unknown option $1"; return 2 ;;
    esac
  done
  # the entry door hands it in its environment (fleet-entry.sh, issue #3326)
  [ -n "$setlang" ] || [ -z "${FLEET_CLIENT_LANG+x}" ] || { lang=$FLEET_CLIENT_LANG; setlang=1; }
  case "$view" in ''|*[!A-Za-z0-9-]*) note "attach --thin: bad or missing --view"; return 2 ;; esac
  case "$route$token" in *[!A-Za-z0-9._:-]*) note "attach --thin: bad --route / --token"; return 2 ;; esac
  case "$device" in *[!A-Za-z0-9+/=_-]*) note "attach --thin: --device is not base64"; return 2 ;; esac
  case "$lang" in *[!A-Za-z0-9._@-]*) note "attach --thin: --lang is not a locale name — recorded as none"; lang='' ;; esac
  case "$bhome" in ''|@[0-9]*) ;; *) note "attach --thin: --home is not a window id"; return 2 ;; esac
  [ -z "$bhome" ] || [ -n "$browser" ] || { note "attach --thin: --home is for --browser"; return 2; }
  s=$(fleet_sockets | head -n 1)
  [ -n "$s" ] || { note "no fleet session is live on $(hostname -s)"; return 3; }
  sock=$(fleet_socket "$s")
  rv_prune
  rv_legacy_undo "$s"
  fleet_guide_arrive "$s" attach >/dev/null 2>&1   # a person is here: a pending guide opens (#4852)
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
  wfar=''; lastgone=''
  if [ -n "$want" ]; then
    w=$(rv_thin_window "$s" "$want")
    if [ -z "$w" ]; then
      [ -z "$browser" ] || { note "browser: requested session ended"; return 4; }
      case "$want" in */*) wfar=${want#wid:} ;; esac
      note "attach --thin: ${want#*/} is not live on $(hostname -s) — landing elsewhere${wfar:+, then there}"
    fi
  elif [ -z "$resume" ] && [ -z "$browser" ] && last=$(head -n 1 "$VIEWS/.last" 2>/dev/null) && [ -n "$last" ]; then
    # a plain `fleet` (issue #4000): the session this person looked at last
    w=$(rv_thin_window "$s" "$last")
    if [ -z "$w" ]; then
      case "$last" in */*)
        case "$(fleet_worker_locate "wid:$last" "$s" 2>/dev/null)" in remote\ *) wfar=$last ;; esac ;;
      esac
      [ -n "$wfar" ] || lastgone=1
    fi
  fi
  # A resumed 看台 whose session is not here YET, while a restore holds the lock
  # (fleet-sessions-snapshot.sh restore / fleet-restore.sh --auto — the home's tmux
  # was restarted, issue #3511): the fleet is back, its windows are still coming.
  # Landing now would put the person on the home window and ask for a NEW session;
  # say no fleet yet (3) and the thin loop waits for the same session instead.
  if [ -n "$resume" ] && [ -n "$cur" ] && [ -z "$w" ] && ! T has-session -t "=$g" 2>/dev/null \
     && [ -z "$(rv_thin_window "$s" "$cur")" ] && rv_restoring; then
    note "attach --thin: $(hostname -s) is restarting — its sessions are coming back"
    return 3
  fi
  kept=''
  T has-session -t "=$g" 2>/dev/null && gid=$(T display-message -p -t "=$g:" '#{session_id}' 2>/dev/null) && kept=1
  if [ -z "$gid" ]; then
    gid=$(T new-session -d -P -F '#{session_id}' -t "=$s" -s "$g" 2>/dev/null) \
      || { note "attach --thin: no 看台 session for $view"; return 1; }
    [ -n "$w" ] || w=$(rv_thin_window "$s" "$cur")
  fi
  if [ -n "$browser" ]; then
    # Arm cleanup before dressing the view: interruption during setup must not
    # strand an unattached grouped session either.
    T set-option -t "$gid" @view_thin "$view" 2>/dev/null
    # shellcheck disable=SC2064 # capture locals now; the EXIT runs after this function returns
    trap "rv_browser_cleanup $(printf '%q ' "$sock" "$gid" "$f" "$$" "$view" "$s")" EXIT
    trap 'exit 129' HUP
    trap 'exit 143' TERM
  fi
  # Nowhere named: a resumed 看台 still kept stays where it was; anything else gets a
  # new session through ⌘N's own road below (issue #3007: a bare `home` shell is no
  # landing; issue #4341: no session is anyone's home)
  newfar=''
  if [ -n "$browser" ]; then
    # the browser lands where it asked, else on its own home pane — never a new
    # session (issue #4373)
    [ -n "$w" ] || { [ -n "$bhome" ] && T list-windows -t "=$s" -F '#{window_id}' 2>/dev/null | grep -qxF "$bhome" && w=$bhome; }
    [ -n "$w" ] || w=$(T display-message -p -t "=$s:" '#{window_id}' 2>/dev/null)
  elif [ -n "$lastgone" ] || { [ -z "$w" ] && ! { [ -n "$resume" ] && [ -n "$kept" ]; }; }; then
    # the last one is gone, or there never was one: `do land` below (a new session
    # only when the person has none anywhere — task Q1A8)
    w=$(T display-message -p -t "=$s:" '#{window_id}' 2>/dev/null); newfar=1
  fi
  [ -z "$w" ] || T select-window -t "$gid:$w" 2>/dev/null
  rv_thin_dress "$gid" "$view" "$s"
  if [ -n "$browser" ]; then
    # The personal shell is persistent; browser navigation never creates a
    # per-view shell. Load native keys even on a minimally initialized fleet.
    T set-option -t "$gid" @view_web_home "$bhome" 2>/dev/null
    sp=$(T display-message -p -t "$gid:" '#{socket_path}')
    TMUX="$sp,0,0" python3 "$BIN/fleet-quickopen.py" view-keys --browser
    T set-option -t "$gid" key-table fleet-webterm
    T set-option -t "$gid" prefix None
    T set-option -t "$gid" prefix2 None
    # A browser attachment is disposable. The captured session id and row pid
    # belong to THIS attach; neither cleanup can hit a replacement connection.
  fi
  # the language this connection's client brought (issue #3326): per 看台, never the
  # server's environment (started before, `update-environment` has no LANG) —
  # empty = it said none. Issue #3329: the 看台 draws in it — FLEET_VIEW_LANG in its
  # session's environment (every run-shell and popup of the 看台 inherits it;
  # fleet-ui-lang.sh: the person's choice first, then this), `@view_lang_set` for
  # the top line's format — and the first time this device comes in on English
  # detected for it, the top line says so for 8 s (an info notice, T675; D8 / L4).
  if [ -n "$setlang" ]; then
    T set-option -t "$gid" @view_lang "$lang" \; set-option -t "$gid" @view_lang_set 1 \; \
      set-environment -t "$gid" FLEET_VIEW_LANG "$lang" 2>/dev/null
    hint=$(FLEET_VIEW_LANG="$lang" sh "$BIN/fleet-ui-lang.sh" first-hint "$view" 2>/dev/null)
    [ -z "$hint" ] || python3 "$BIN/fleet_notice.py" notify info "$hint" --secs 8 --view "$gid" \
      --sock "$sock" --source attach </dev/null >/dev/null 2>&1
  fi
  # the client's own version (issue #3826): fleet-thin.py brings it as
  # FLEET_CLIENT_VER; when the hub hands out a newer one the top line says
  # 「客户端不是最新 … 运行 fleet update」 for 20 s — off the attach's path. An older
  # client brings none: nothing is said.
  case "${FLEET_CLIENT_VER:-}" in ''|*[!0-9A-Za-z._-]*) ;; *)
    ( ( behind=$( { [ -z "$setlang" ] || export FLEET_VIEW_LANG="$lang"; }
                  python3 "$BIN/fleet-client-behind.py" "$FLEET_CLIENT_VER" </dev/null 2>/dev/null )
        [ -z "$behind" ] || [ -n "${FLEET_CLIENT_REHOMED:-}" ] || python3 "$BIN/fleet_notice.py" notify warn "$behind" \
          --secs 20 --view "$gid" --sock "$sock" --source client-behind ) </dev/null >/dev/null 2>&1 & ) ;;
  esac
  # 换家 (T690): the thin loop gave up on its home and landed here — it brings the
  # home it left as FLEET_CLIENT_REHOMED; the top line says so for 60 s (the
  # client-behind word above stays quiet on this attach, never written over it).
  # An older loop brings none: nothing is said.
  case "${FLEET_CLIENT_REHOMED:-}" in ''|*[!0-9A-Za-z._-]*) ;; *)
    rh=$( { [ -z "$setlang" ] || export FLEET_VIEW_LANG="$lang"; }
          sh "$BIN/fleet-ui-lang.sh" t view_rehomed_fmt "$FLEET_CLIENT_REHOMED" "$(rv_node_label)" 2>/dev/null )
    [ -z "$rh" ] || python3 "$BIN/fleet_notice.py" notify info "$rh" --secs 60 --view "$gid" --sock "$sock" \
      --source rehomed </dev/null >/dev/null 2>&1 ;;
  esac
  # C4: a window per other (machine, login) your sessions are on, made now — off
  # the attach's path — so the first visit to another machine is already warm
  case "$browser:$view" in 1:*|*:*-via-*) ;; *)
    ( python3 "$BIN/fleet-quickopen.py" view-peers --view "$s@view-$view" --socket "$sock" </dev/null >/dev/null 2>&1 & ) ;;
  esac
  # ⌘P's resident panel (T890): started now, off the attach's path, so the first
  # ⌘P already finds the list in hand (fleet-panel-server.py; off ⇒ nothing)
  case "$browser:$view" in 1:*|*:*-via-*) ;; *)
    ( python3 "$BIN/fleet-panel-server.py" ensure --view "$s@view-$view" --socket "$sock" </dev/null >/dev/null 2>&1 & ) ;;
  esac
  # the one message issue #3328 added: 快捷键只剩 ⌘P, once per login, on this
  # 看台's client once it is attached
  case "$view" in *-via-*) ;; *)
    ( { sleep 1.5; TMUX='' python3 "$BIN/fleet-quickopen.py" view-notice --view "$s@view-$view" --socket "$sock"; } </dev/null >/dev/null 2>&1 & ) ;;
  esac
  # --want naming another machine's session (`fleet claude` placed there, #3004):
  # the 看台's one switch road takes it there once attached — its C4 window
  case "$wfar:$view" in ?*:*-via-*|:*) ;; *)
    ( sleep 0.3; TMUX='' python3 "$BIN/fleet-quickopen.py" go "$s@view-$view" "$wfar" --how want </dev/null >/dev/null 2>&1 & ) ;;
  esac
  case "$newfar:$wfar:$view" in 1::*-via-*) ;; 1::*)
    if [ -n "${FLEET_VIEW_FIRST_CMD:-}" ]; then   # the selftest's seam: what ran, nothing switched
      ( sleep 0.3; TMUX='' sh -c "$FLEET_VIEW_FIRST_CMD"' "$@"' _ "do" land --view "$s@view-$view" </dev/null >/dev/null 2>&1 & )
    else
      ( sleep 0.3; TMUX='' python3 "$BIN/fleet-quickopen.py" "do" land --view "$s@view-$view" </dev/null >/dev/null 2>&1 & )
    fi ;;
  esac
  rv_hide_borders "$s"
  # what the loop takes beyond `open` (issue #3541: `show` — fleet-show.sh reads it);
  # an older loop brings none and the row is byte for byte as before
  caps=''
  case "${FLEET_CLIENT_CAPS:-}" in ''|*[!a-z0-9,_-]*) ;; *) caps="	caps=${FLEET_CLIENT_CAPS}" ;; esac
  # which client it is (issue #4916): `fleet doctor --installs` lists each
  # connected 看台's version against stable; an older loop brings none
  case "${FLEET_CLIENT_VER:-}" in ''|*[!0-9A-Za-z._-]*) ;; *) caps="$caps	cv=${FLEET_CLIENT_VER}" ;; esac
  tty=$(tty 2>/dev/null) || tty=-
  fu=$(fleet_uuid "$s" 2>/dev/null) || fu=''
  mkdir -p "$VIEWS" 2>/dev/null
  w=$(T display-message -p -t "$gid:" '#{window_id}' 2>/dev/null)
  ( umask 077
    printf '%s\t%s\tthin\t%s\t%s\tcur=%s\troute=%s\tdevice=%s\ttoken=%s\tfuid=%s\tnode=%s%s\n' \
      "$tty" "$s" "$(date +%s)" "$$" "$(rv_thin_cur "$s" "$w" "$fu")" "$route" "$device" "$token" "$fu" "$(rv_node_label)" "$caps" \
      > "$VIEWS/.$view.$$" && mv -f "$VIEWS/.$view.$$" "$f" ) \
    || { note "attach --thin: cannot register $view"; return 1; }
  # the session in view, said to the thin loop once its client is on (issue #3489):
  # an attach fires no session-window-changed, so the `cur` hook's first word is
  # this one — off the attach's path, a few tries while the client comes up
  case "$view" in *-via-*) ;; *)
    sp=$(T display-message -p -t "$gid:" '#{socket_path}' 2>/dev/null)
    [ -z "$sp" ] || ( for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        T list-clients -t "=$g" -F x 2>/dev/null | grep -q x || continue
        bash "$BIN/fleet-remote-view.sh" cur "$VIEWS" "$sp" "$g"; break
      done </dev/null >/dev/null 2>&1 & ) ;;
  esac
  trap 'rc=129' HUP
  [ -z "$browser" ] || trap 'exit 143' TERM
  if [ -n "$browser" ]; then
    T attach-session -t "$gid" \; set-option -t "$gid" destroy-unattached on; rc=$?
  else
    T attach-session -t "$gid"; rc=$?
  fi
  # The 看台 stays: its row says since when nobody looks (only while it is ours).
  [ "$(cut -f5 "$f" 2>/dev/null)" = "$$" ] && rv_row_set "$f" left "$(date +%s)"
  return "$rc"
}

case "$mode" in
# ---------------------------------------------------------------------------------
attach)
  # only the 看台 (issue #2763): a plain / view attach was the proxy window's far
  # end, deleted with it (T606)
  [ "${1:-}" = --thin ] && { shift; rv_attach_thin "$@"; exit $?; }
  note '已删除：看台走 fleet / attach --thin'
  exit 2
  ;;
open|run|serve|watch|back|reconcile|restore)
  # the proxy window and what served it (issues #1424, #1484, #1682, #1713) —
  # deleted with T606 (EPIC T605 C1): a 看台 reaches another machine through its
  # peer window
  note '已删除：看台走 fleet / attach --thin'
  exit 2
  ;;

# ---------------------------------------------------------------------------------
deliver)
  # ON <node> (T992): a new session's stub's words for <worker_id> — the home
  # machine's ⌘P opened the stub there, the hub placed the session here. JSON on
  # stdin ({"queued": [...], "unsent": "..."}), handed to the agent here once it
  # keeps a paste (bin/fleet_stub.py deliver: the queued lines submitted, the
  # unsent one left in its input). Exit 3 not live here, 4 never ready (the home
  # keeps the words as a notice).
  loc=$(fleet_worker_locate "wid:${1#wid:}" 2>/dev/null)
  case "$loc" in local\ *) ;; *) note "${1#*/} is not live on $(hostname -s)"; exit 3 ;; esac
  set -- $loc; sock=$(fleet_socket "$3")
  pane=$(T display-message -p -t "$2" '#{pane_id}' 2>/dev/null)
  case "$pane" in %*) ;; *) exit 3 ;; esac
  exec python3 "$BIN/fleet_stub.py" deliver --socket "$sock" --pane "$pane"
  ;;

# ---------------------------------------------------------------------------------
select)
  # On <node> (issue #1484): the worker's window becomes the current one of the
  # 看台 <view> (issue #1489); the fleet session itself when none is named or
  # live. Not live here → 3. The slow road of the fast path at the top — a key
  # the hub named by, another fleet's UUID. A window spawned since the attach
  # loses its header too (#1549).
  # a home's far 看台 (C4) not attached here yet: 5 — its window lands there when it is
  case "${2:-}" in *-via-*) [ "$(cut -f3 "$VIEWS/$2" 2>/dev/null)" = thin ] || exit 5 ;; esac
  rv_select "${1:-}" "${2:-}"; exit $?
  ;;

# ---------------------------------------------------------------------------------
thin-bar)
  # the 看台's top line format for <view> <fleet> (rv_thin_bar) — a selftest and a
  # BREAK-IT drill dress a test 看台 with the very format attach sets
  rv_thin_bar "${1:-}" "${2:-}"; echo
  ;;
thin-inbox)
  # the 看台's message row format (rv_thin_inbox, T701) — for the same tests
  rv_thin_inbox; echo
  ;;
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
# THIS SESSION's shell (issue #2744): a login shell of the machine the session
# runs on, as its login, in its working directory — the worker's `@worktree`,
# else its pane's directory. The 看台's ⌃\ (fleet_view.py) opens it; the old
# client's own `shell-open` / `shell` went with that client (#3008).
#
#   shell-here <worker id>  (ON <node>) — cd to where its agent is (the agent
#                           pane's directory, else @worktree, else $HOME) and exec
#                           the login's shell (`-l`) with the fleet's bin/ on its
#                           PATH and no worker credential in its environment; a
#                           watcher HUPs it when the session's window goes (a
#                           reaped session takes its shell along). Exit 3 when the
#                           session is not live here.
shell-here)
  wid="${1:-}"; dir=''; w=''; sock=''
  if [ -n "$wid" ] && [ "$wid" != - ]; then
    loc=$(fleet_worker_locate "wid:${wid#wid:}" 2>/dev/null)
    case "$loc" in local\ *) ;; *) note "${wid#*/} is not live on $(hostname -s)"; exit 3 ;; esac
    set -- $loc; w=$2; s=$3; sock=$(fleet_socket "$s")
    # where its agent is right now (issue #3183): the cwd its last Bash call left
    # (@agent_cwd), then the agent pane's directory (the pane the wrapper started,
    # else the window's first), then @worktree, then $HOME — fleet_view.agent_dir's
    dir=$(T display-message -p -t "=$s:$w" '#{@agent_cwd}' 2>/dev/null)
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      panes=$(T list-panes -t "=$s:$w" -F "#{pane_current_path}$(printf '\t')#{pane_start_command}" 2>/dev/null)
      dir=$(printf '%s\n' "$panes" | awk -F '\t' 'index($2, "fleet-session-wrap") { print $1; exit }')
      [ -n "$dir" ] || dir=$(printf '%s\n' "$panes" | head -n 1 | cut -f 1)
    fi
    [ -n "$dir" ] && [ -d "$dir" ] || dir=$(T display-message -p -t "=$s:$w" '#{@worktree}' 2>/dev/null)
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
  # `codex` / `claude` here (issue #3463): the session's own agent is said back to
  # it (bin/fleet-session-shell-agent.sh) — a bare one in this shell has no fleet
  # login — anything else passes through.
  if [ -n "${w:-}" ]; then
    export FLEET_SESSION_SHELL_WIN="$w" FLEET_SESSION_SHELL_SOCK="$sock"
    export PATH="$BIN/session-shell:$BIN:$HOME/.local/bin:$PATH"
  else
    export PATH="$BIN:$HOME/.local/bin:$PATH"
  fi
  sh_=${FLEET_SESSION_SHELL_CMD:-${SHELL:-/bin/bash}}; [ -x "$sh_" ] || sh_=/bin/bash   # _CMD: the selftests
  exec "$sh_" -l
  ;;

*)
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2 ;;
esac
