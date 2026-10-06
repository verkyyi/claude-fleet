#!/bin/bash
# fleet-remote-view-selftest.sh — the proxy window onto another machine's session
# (issue #1424, EPIC #1419 C5): bin/fleet-remote-view.sh, the sidebar/dash Enter
# on a `wid:` row (dash-enter.sh, fleet-sidebar.py), fleet-open.sh's proxy relay,
# and the local rails that must skip a proxy window.
#
# Two ISOLATED tmux servers stand in for the two machines: LOCAL (`-L rvL<pid>`,
# the fleet the operator sits at) and REMOTE (`-L <its session>`, the other
# machine's fleet — fleet_socket is the session name). `ssh` is a shim
# (FLEET_REMOTE_SSH_CMD) that drops the options and runs the remote command here,
# with $TMUX unset as a real ssh login has it.
#   A. degenerate  — CCQUOTA_FLEET off: `open` creates nothing
#   B. open        — a proxy window `@remote=m4:<wid>`, named `m4 …` (#1475; no ⇄, #1621), selected;
#                    a second row of the same machine RETARGETS it (still one)
#   H. local view  — (#1475) the local sidebar's `jump` on a remote row lands in
#                    the proxy window WITH the view: the list on the left, the other
#                    machine's pane on the right; `sync` keeps it there (a proxy
#                    window is a task window); `jump` on a local row takes it back;
#                    `prefix h` (`back`) returns to the last local window
#   C. attach      — the proxy is a client of a VIEW SESSION of its own, grouped
#                    onto the remote fleet session (`<fleet>@view-<id>`, #1489) and
#                    on the worker's window; the fleet session's current window
#                    never moves; status line + prefix off there for good — and
#                    NOTHING on the fleet session itself (#1713: the node makes no
#                    way); what an older version's rule left there (status/prefix
#                    hidden, `@remote_view_solo`, the [77] hooks, a session-level
#                    hook array) is undone; typing reaches it; registered as a
#                    `view` row; the fleet's own global client-attached hook fires
#   D. fleet-open  — from the remote session, the request reaches the proxy side
#                    (sent:proxy), not an escape on the remote's terminal
#   N. no list     — (#1713) a node fleet session draws no list: fleet-sidebar.sh
#                    sync there, a client on it, adds no sidebar pane and reaps the
#                    one an older version drew; the drawer's selftest seam
#                    (FLEET_SIDEBAR_NODE=1) does draw one — the positive control
#   G. shared      — a client attaching AT the remote end changes nothing: no pane
#                    on the node is added, removed or moved
#   I. shells      — (#1485/#1713) shells, a plain hand-run attach, a shell beside
#                    it, each leaving: the registry follows every one (a shell row,
#                    no spool without a view id) and the node's panes never change
#   K. one title   — (#1549) a window a shell/view looks at loses its own header
#                    ONE WAY — off at the attach, still off after every client
#                    has gone — so the proxy pane shows no second header and no
#                    client change resizes a pane
#   J. own window  — (#1489) two shells on one machine: each view session keeps
#                    its own current window; `select <wid> <view>` moves that view
#                    alone, `select <wid>` (an older open) the fleet session alone;
#                    fleet_lw lists each window once and fleet-peer-send resolves
#                    the worker (no AMBIGUOUS); FLEET_SESSION_FMT names the fleet
#                    from a pane of the shared window
#   E. close       — killing the proxy window leaves the remote worker running,
#                    the registry gone, no hook and no marker anywhere, the node's
#                    panes as they were
#   F. skipped     — a proxy window is no dash row, no session in either cap
#                    tally, no fleet-restore row, no sleep candidate
#   L. no ⇄ (lint) — (#1621) a proxy window is known by `@remote`, never by its
#                    name: no code line in bin/ (fleet-remote-view.sh,
#                    fleet-shell.sh, fleet-sidebar.py, tmux-status.sh,
#                    tmux-dashboard-rows.sh, …) or conf/ draws or matches a ⇄ —
#                    only fleet-ui-lang.sh's toggle words (`claude ⇄ codex`) keep one
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-remote-view selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-remote-view selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/frv-st.XXXXXX")" || exit 2
LL="rvL$$"; RS="rvR$$"; LS=$LL   # a fleet's socket label IS its session name
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/control" "$FLEET_CONF_DIR/fleets/$RS"
export FLEET_REMOTE_BIN="$BIN" FLEET_REMOTE_VIA_HUB=0
export FLEET_OPEN_SECRET_FILE="$WORK/open/open.secret"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
tl() { "$REAL_TMUX" -L "$LL" "$@"; }
tr_() { "$REAL_TMUX" -L "$RS" "$@"; }
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cleanup() {
  "$REAL_TMUX" -L "$LL" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$RS" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- shims: bare `tmux` = the LOCAL server; `ssh` runs the remote command here ---
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<EOF
#!/bin/bash
[ -n "\${TMUX:-}" ] && exec "$REAL_TMUX" "\$@"
for a in "\$@"; do case "\$a" in -L|-S) exec "$REAL_TMUX" "\$@" ;; esac; done
exec "$REAL_TMUX" -L "$LL" "\$@"
EOF
cat > "$SHIM/ssh" <<'EOF'
#!/bin/bash
# options → dropped, but the ControlPath remembered; `-O check` answers like a
# master would (is the control socket there?), `-O exit` takes it down, `-O
# forward` says yes; then host, cmd. The master (the `attach`) binds the control
# socket first, so `open`'s retarget goes over it to `select` (issue #1484) — the
# way a real proxy does — instead of reconnecting.
op=''; ctl=''
while [ $# -gt 0 ]; do
  case "$1" in
    -O) op=$2; shift 2 ;;
    -o) case "$2" in ControlPath=*) ctl=${2#ControlPath=} ;; esac; shift 2 ;;
    -S) ctl=$2; shift 2 ;;
    -L) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "$op" ]; then
  case "$op" in check) [ -S "$ctl" ]; exit $? ;; exit) rm -f "$ctl"; exit 0 ;; *) exit 0 ;; esac
fi
shift                                    # the host
[ -n "${FRV_SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$FRV_SSH_LOG"
unset TMUX TMUX_PANE
case "$*" in *" attach"*) [ -n "$ctl" ] && python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$ctl" 2>/dev/null ;; esac
cd "$HOME" && exec bash -c "$*"
EOF
chmod +x "$SHIM/tmux" "$SHIM/ssh"
export PATH="$SHIM:$PATH"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh" FRV_SSH_LOG="$WORK/ssh.log"
export FLEET_REMOTE_OPENER="$WORK/opener.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\n' "$WORK/opened" > "$FLEET_REMOTE_OPENER"; chmod +x "$FLEET_REMOTE_OPENER"

# --- the REMOTE machine's fleet: a conf + a machine id ⇒ a fleet UUID ---------------
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$RS/conf"
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
c.execute("INSERT INTO metadata VALUES ('machine_id', '0b8e2f3a-7c1d-4e5f-9a6b-1c2d3e4f5a6b')"); c.commit()
PY
U=$(. "$BIN/fleet-lib.sh"; fleet_uuid "$RS")
[ -n "$U" ] || { printf 'FAIL: rig: no fleet UUID for %s\n' "$RS" >&2; exit 1; }
WID="$U/issue-7"; WID2="$U/issue-8"

tr_ -f /dev/null new-session -d -s "$RS" -n plan -x 200 -y 50 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'fleet-remote-view selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }
# The fleet conf's own hook (tmux-attention.conf, client-attached[71]): a hook ON
# THE SESSION — #1475's form — would shadow it.
tr_ set-hook -g 'client-attached[71]' "run-shell -b 'echo att >> $WORK/hook71'"
RW=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n worker7 "cat > '$WORK/typed'")
tr_ set-window-option -t "$RW" @issue 7
RW8=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n worker8 'while :; do sleep 300; done')
tr_ set-window-option -t "$RW8" @issue 8
# Each window's own top header (tmux-attention.conf: global `top`, a marker format
# to find it in a capture); worker 8 sets its OWN value (#1549).
tr_ set-option -g pane-border-status top \; set-option -g pane-border-format 'RBORDER #{window_name}'
tr_ set-window-option -t "$RW8" pane-border-status bottom
# What an OLDER version left on a node (#1475/#1485, retired in #1713): its own
# sidebar view in the worker's window, the session hidden (status + prefix off,
# the originals saved), the solo marker, a window's saved header, the server's
# [77] hooks and a session-level hook array. The first attach undoes the rule's
# leftovers; the node's next sync reaps the view (N).
RVP=$(tr_ split-window -d -h -b -f -l 30 -P -F '#{pane_id}' -t "$RW" 'while :; do sleep 300; done')
tr_ set-option -p -t "$RVP" @sidebar 1
tr_ set-option -t "=$RS:" prefix C-a
tr_ set-option -t "=$RS:" @remote_view_saved 'status=- prefix=C-a prefix2=- ' \; \
  set-option -t "=$RS:" status off \; set-option -t "=$RS:" prefix None \; set-option -t "=$RS:" prefix2 None \; \
  set-option -t "=$RS:" @remote_view_solo 1
tr_ set-window-option -t "$RW8" @remote_view_saved 'pane-border-status=bottom'
tr_ set-hook -g 'client-attached[77]' "run-shell -b 'echo legacy >> $WORK/hook77'" \; \
  set-hook -g 'client-detached[77]' "run-shell -b 'echo legacy >> $WORK/hook77'"
tr_ set-hook -t "=$RS:" 'client-attached[77]' "run-shell -b 'echo legacy >> $WORK/hook77'"
tr_ set-hook -u -t "=$RS:" 'client-attached[77]'   # #1475's emptied array: it still shadows

# --- the LOCAL fleet + the sidebar's remote cache (#1423's row shape) ---------------
tl -f /dev/null new-session -d -s "$LS" -n plan -x 160 -y 40 'while :; do sleep 300; done'
LW=$(tl new-window -d -P -F '#{window_id}' -t "$LS:" -n local-work 'while :; do sleep 300; done')
tl set-window-option -t "$LW" @issue 9
tl select-window -t "$LW"
G="$TMPDIR/.claude-dash/global"; mkdir -p "$G"
US=$'\037'
{ printf '#ts%s%s\n' "$US" "$(date +%s)"
  printf 'wid:%s%sm4%sonline%s7%sacme/app%sworking%sclaude%s侧边栏%s\n' "$WID" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
  printf 'wid:%s%sm4%sonline%s8%sacme/app%sdone%sclaude%s另一个%s\n' "$WID2" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US"
} > "$G/remote_$LS"

proxies() { tl list-windows -t "=$LS" -F '#{window_id} #{@remote}' | awk '$2 != ""'; }
# The clients of the remote fleet: its own and its view sessions' (#1489) — a
# registered client sits on `<fleet>@view-<id>`, a person on the fleet session.
gatt() { tr_ display-message -p -t "=$RS:" '#{session_group_attached}' 2>/dev/null; }
vsess() { tr_ list-sessions -F '#{session_name}' 2>/dev/null | grep "^$RS@view-"; }
vcur() { tr_ display-message -p -t "=$1:" '#{window_id}' 2>/dev/null; }
rscur() { tr_ display-message -p -t "=$RS:" '#{window_name}' 2>/dev/null; }

# ============================================================================
# A. degenerate
# ============================================================================
FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" open "$WID" >/dev/null 2>&1
eq "A: hub off — open makes no window" "" "$(proxies)"

# ============================================================================
# B. open + retarget
# ============================================================================
export CCQUOTA_FLEET=1
PW=$(FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" open "wid:$WID" 2>/dev/null)
eq "B: a proxy window, marked with machine:worker_id" "$PW m4:$WID" "$(proxies)"
eq "B: named for the row and its machine — m4, the pane header's word too (#1475), no ⇄ (#1621)" "m4 侧边栏" "$(tl display-message -p -t "$PW" '#{window_name}')"
eq "B: and selected" "$PW" "$(tl display-message -p -t "=$LS:" '#{window_id}')"

# ============================================================================
# H. the local view rides along (#1475): a proxy window is a task window
# ============================================================================
# fleet-sidebar.py as the view's own entry points, on the LOCAL server (the shim).
sb() { FLEET_SESSION=$LS python3 - "$BIN/fleet-sidebar.py" "$@" <<'PYR'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
fn = sys.argv[2]
if fn == "jump":
    sb.jump(sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
elif fn == "sync":
    sb.sync(sys.argv[3], "1", 30, sys.argv[4])
elif fn == "version":
    print(sb.VIEW_VERSION)
PYR
}
VV=$(sb version)
tl select-window -t "$LW"
LWP=$(tl display-message -p -t "$LW" '#{pane_id}')
# A view pane in the local task window, as sync would have made it.
VP=$(tl split-window -d -h -b -f -l 30 -P -F '#{pane_id}' -t "$LWP" 'while :; do sleep 300; done')
tl set-option -p -t "$VP" @sidebar 1 \; set-option -p -t "$VP" @sidebar_version "$VV" \; set-option -w -t "$LW" @sidebar_worker "$LWP"
views_in() { tl list-panes -t "$1" -F '#{pane_id} #{@sidebar}' | awk '$2 == 1 { print $1 }' | tr '\n' ' '; }
# `sync` draws a view only for an ATTACHED session (the operator's screen): a
# client on the local session, from a pane of the other server.
AW=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n viewer "env -u TMUX $REAL_TMUX -L $LL attach -t '=$LS'")
lattached() { [ "$(tl display-message -p -t "=$LS:" '#{session_attached}' 2>/dev/null)" = 1 ]; }
waitfor 10 lattached || fail "H: no client attached to the local session"
sb jump "$LS" "wid:$WID" "$VP" "$WORK/sb.lock"
eq "H: jump on a remote row lands in the proxy window" "$PW" "$(tl display-message -p -t "=$LS:" '#{window_id}')"
eq "H: …with the view: the list is in the proxy window" "$VP " "$(views_in "$PW")"
eq "H: …and nowhere else" "" "$(views_in "$LW")"
eq "H: …on the left" "0" "$(tl display-message -p -t "$VP" '#{pane_left}')"
PP=$(tl list-panes -t "$PW" -F '#{pane_id} #{pane_active} #{@sidebar}' | awk '$2 == 1 && $3 != 1 { print $1 }')
[ -n "$PP" ] || fail "H: the proxy pane is not the active pane of its window" "$(tl list-panes -t "$PW" -F '#{pane_id} #{pane_active} #{@sidebar}')"
sb sync "$LS" "$WORK/sb.lock"
eq "H: sync with the proxy window current keeps the view there (a task window)" "$VP " "$(views_in "$PW")"
eq "H: …one view in the whole session" "1" "$(tl list-panes -s -t "$LS" -F '#{@sidebar}' | grep -c '^1$')"
sb jump "$LS" "$LW" "$VP" "$WORK/sb.lock"
eq "H: jump on a local row goes back, view and all" "$LW $VP " "$(tl display-message -p -t "=$LS:" '#{window_id}') $(views_in "$LW")"
eq "H: …the proxy window keeps no view" "" "$(views_in "$PW")"
tl select-window -t "$PW"
FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" back "$LS" >/dev/null 2>&1
eq "H: prefix h (back) from the proxy window selects the last local window" "$LW" "$(tl display-message -p -t "=$LS:" '#{window_id}')"
FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" back "$LS" >/dev/null 2>&1
eq "H: …and is a no-op anywhere else" "$LW" "$(tl display-message -p -t "=$LS:" '#{window_id}')"
tl select-window -t "$PW"
tr_ kill-window -t "$AW"

# ============================================================================
# C. attach
# ============================================================================
attached() { [ "$(gatt)" = 1 ]; }
waitfor 10 attached || fail "C: the proxy never attached to the remote session"
VS=$(vsess)
eq "C: the proxy is a client of a VIEW SESSION of its own, grouped onto the fleet's (#1489)" "1 $RS" "$(printf '%s\n' "$VS" | grep -c .) $(tr_ display-message -p -t "=$VS:" '#{session_group}')"
eq "C: …which shows the worker's window" "$RW" "$(vcur "$VS")"
eq "C: …while the fleet session's own current window never moved" "plan" "$(rscur)"
eq "C: …its status line and prefix off for good, and it goes with its client" "off None None on" "$(tr_ show-options -qv -t "=$VS:" status) $(tr_ show-options -qv -t "=$VS:" prefix) $(tr_ show-options -qv -t "=$VS:" prefix2) $(tr_ show-options -qv -t "=$VS:" destroy-unattached)"
eq "C: …the fleet session has no client of its own" "0" "$(tr_ display-message -p -t "=$RS:" '#{session_attached}')"
# #1713: the node makes no way — the fleet session's own status line and prefix
# are its own (the older rule's hiding undone: status inherited, prefix C-a).
eq "C: the fleet session's status line and prefix are its own — an older hide undone (#1713)" "|C-a|" "$(tr_ show-options -qv -t "=$RS:" status)|$(tr_ show-options -qv -t "=$RS:" prefix)|$(tr_ show-options -qv -t "=$RS:" prefix2)"
eq "C: …no marker of the retired rule left (#1713)" "|" "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)|$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)"
rviews() { tr_ list-panes -s -t "$RS" -F '#{pane_id} #{@sidebar}' | awk '$2 == 1 { print $1 }' | tr '\n' ' '; }
# K (#1549): the far side's own header goes, one way — one title line.
pbs() { printf '%s|%s' "$(tr_ show-options -wqv -t "$RW" pane-border-status)" "$(tr_ show-options -wqv -t "$RW8" pane-border-status)"; }
pbsaved() { printf '%s|%s' "$(tr_ show-options -wqv -t "$RW" @remote_view_saved)" "$(tr_ show-options -wqv -t "$RW8" @remote_view_saved)"; }
eq "K: every remote window's pane-border-status is off once a view is attached" "off|off" "$(pbs)"
eq "K: …nothing is saved to give back (one way), an older marker lifted" "|" "$(pbsaved)"
noheader() { ! tl capture-pane -p -t "$PW" | grep -q RBORDER; }
waitfor 5 noheader || fail "K: the proxy pane still shows the remote window's own header" "$(tl capture-pane -p -t "$PW" | head -3)"
tl send-keys -t "$PW" 'hello-from-m5' Enter
typed() { grep -q 'hello-from-m5' "$WORK/typed" 2>/dev/null; }
waitfor 5 typed || fail "C: typing in the proxy window never reached the remote pane" "$(cat "$WORK/typed" 2>/dev/null)"
regrows() { local f; for f in "$FLEET_CONF_DIR"/remote-views/*; do [ -f "$f" ] && cat "$f"; done; }
eq "C: one view registered (the fleet-open back channel)" "1" "$(regrows | wc -l | tr -d ' ')"
eq "C: …a row <tty> <session> view <since> <pid> (#1485)" "$RS view" "$(regrows | awk -F '\t' '{ print $2, $3 }')"
has "C: …its tty is the proxy client's" "$(tr_ list-clients -F '#{client_tty}' | tr '\n' ' ')" "$(regrows | cut -f1)"
kill -0 "$(regrows | cut -f5)" 2>/dev/null; eq "C: …its pid is the attach shell, alive" "0" "$?"
hook71() { [ -s "$WORK/hook71" ]; }
waitfor 5 hook71 || fail "C: the fleet's own global client-attached hook did not fire for the proxy (shadowed by a session-level hook?)"
eq "C: no [77] hook anywhere — an older attach's lifted, none set (#1713)" "0 " "$(tr_ show-hooks -g | grep -c '\[77\]') $(tr_ show-hooks -t "=$RS:" 2>/dev/null)"

# M (#1682): the proxy holds a `serve` channel on its own connection, and a
# retarget rides it — no one-shot `select` (a fresh remote bash) per click.
chanup() { [ -n "$(tl show-options -wqv -t "$PW" @remote_chan)" ]; }
waitfor 10 chanup || fail "M: the proxy window never got its serve channel (@remote_chan)"
has "M: …a serve session on the proxy's connection, for its view id" "$(cat "$WORK/ssh.log")" "fleet-remote-view.sh serve '$(tl show-options -wqv -t "$PW" @remote_view)'"
: > "$WORK/ssh.log"
# B (cont.): another row of the same machine retargets the SAME window
PW2=$(FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" open "$WID2" 2>/dev/null)
eq "M: the retarget opened no ssh session of its own (the channel carried it)" "" "$(cat "$WORK/ssh.log")"
eq "B: a second row of m4 reuses the proxy window" "$PW" "$PW2"
eq "B: still exactly one proxy, now on the new worker" "$PW m4:$WID2" "$(proxies)"
on8() { [ "$(vcur "$VS")" = "$RW8" ] && attached; }
waitfor 10 on8 || fail "B: the retargeted proxy never showed worker 8" "$(vcur "$VS")"
eq "B: …over the proxy's own connection — no reconnect: the same view session, the fleet session untouched (#1489)" "plan $VS" "$(rscur) $(vsess | tr '\n' ' ' | sed 's/ $//')"
eq "B: the proxy window knows its view id, the one select targets (#1489)" "${VS#"$RS@view-"}" "$(tl show-options -wqv -t "$PW" @remote_view)"

# ============================================================================
# D. fleet-open from the remote session goes back through the proxy
# ============================================================================
waitfor 5 attached
RP=$(tr_ display-message -p -t "$RW8" '#{pane_id}')
RSOCK=$(tr_ display-message -p '#{socket_path}')
out=$(TMUX="$RSOCK,1,0" TMUX_PANE="$RP" PATH="$PATH" bash "$BIN/fleet-open.sh" https://github.com 2>"$WORK/open.err")
eq "D: fleet-open in the remote session hands it to the proxy" "sent:proxy" "$out"
has "D: and says so on stderr" "$(cat "$WORK/open.err")" "proxy view"
gotit() { grep -q '^https://github.com$' "$WORK/opened" 2>/dev/null; }
waitfor 5 gotit || fail "D: the proxy side never re-issued the url" "$(cat "$WORK/opened" 2>/dev/null)"

# ============================================================================
# F. a proxy window is skipped by the local rails
# ============================================================================
rows=$(FLEET_SESSION=$LS PATH="$PATH" bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null)
hasnt "F: no local dash row for the proxy window" "$rows" "$PW"
has "F: the m4 row itself is still there" "$rows" "wid:$WID"
cnt=$(. "$BIN/fleet-lib.sh"; FLEET_CONF_DIR="$WORK/none" fleet_session_count_for "$LS")
eq "F: the per-fleet cap counts the local window only" "1" "$cnt"
cntg=$(. "$BIN/fleet-lib.sh"; fleet_sockets() { printf '%s\n' "$LL"; }; _fleet_session_tally)
eq "F: the machine-wide tally counts the local window only" "1 0" "$cntg"
snap=$(tl list-windows -t "=$LS" -F '#{?@remote,,#{window_name}}|x')
hasnt "F: fleet-restore's snapshot format names no proxy" "$snap" "m4 侧边栏"
sl=$(FLEET_SLEEP=observe python3 "$BIN/fleet-sleep.py" scan --session "$LL" --dry-run 2>/dev/null)
hasnt "F: the sleeper reports nothing about the proxy" "$sl" "\"$PW\""

# ============================================================================
# N. a node fleet session draws no list (#1713) — G's plain client on it
# ============================================================================
# The panes of every remote window — which window, where it starts, a list or not:
# no client change may add, remove or move one. (Not sizes: tmux sizes a window
# to its newest client, which is tmux's and not the fleet's — and `window-size
# manual`, which would pin them, takes this tmux server down.)
layout() { tr_ list-panes -s -t "=$RS" -F '#{pane_id} #{window_id} #{pane_left},#{pane_top} sb=#{@sidebar}' 2>/dev/null | sort | tr '\n' ' '; }
HW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n helper "env -u TMUX $REAL_TMUX -L $RS attach -t '=$RS'")   # quoted: zsh expands a bare =word
two() { [ "$(gatt)" = 2 ]; }
waitfor 10 two || fail "G: the second client never attached"
tr_ select-window -t "=$RS:$RW"   # a task window, on the plain client's screen
nsync() { TMUX="$RSOCK,0,0" bash "$BIN/fleet-sidebar.sh" sync "=$RS:" >/dev/null 2>&1; }
nsync
eq "N: sync on the node, a client on it — no sidebar pane; the one an older version drew is reaped" "" "$(rviews)"
FLEET_SIDEBAR_NODE=1 nsync
drawn() { [ -n "$(rviews)" ]; }
waitfor 5 drawn || fail "N: the selftest seam did not draw the list (the positive control: the gate is what keeps it off)" "$(tr_ list-panes -t "$RW" -F '#{pane_id} #{pane_width} #{@sidebar}')"
nsync
eq "N: …and the node's next sync takes it away again" "" "$(rviews)"
NW=$(tr_ new-window -P -F '#{window_id}' -t "$RS:" -n worker10 'while :; do sleep 300; done')
tr_ set-window-option -t "$NW" @issue 10
nsync
eq "N: a window the node opens has no sidebar pane" "1 " "$(tr_ list-panes -t "$NW" -F '#{pane_id}' | grep -c .) $(rviews)"
tr_ kill-window -t "$NW"; tr_ select-window -t "=$RS:plan"
L0=$(layout)

# ============================================================================
# G. someone attaches AT the remote end → nothing on the node changes
# ============================================================================
settle() { sleep 0.7; }   # give a NEGATIVE check time to be wrong
eq "G: a plain client at the remote end — the status line stays the fleet's own, no marker" "|" "$(tr_ show-options -qv -t "=$RS:" status)|$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)"
eq "K: a plain client gets no header back — the one-way rule (#1549, #1713)" "off|off" "$(pbs)"
tl kill-window -t "$HW"
one() { [ "$(gatt)" = 1 ]; }
waitfor 5 one || fail "G: the helper client did not leave"
settle
eq "G: the plain client came and went — the node's panes unchanged" "$L0" "$(layout)"

# ============================================================================
# I. shells (#1485): hidden ⇔ at least one client, and every one a shell/view
# ============================================================================
natt() { [ "$(gatt)" = "$1" ]; }
# The node never changes for a client (#1713): the fleet session's own status
# line, no marker, every pane where it was.
still() { [ -z "$(tr_ show-options -qv -t "=$RS:" status)$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)" ] && [ "$(layout)" = "$L0" ]; }
# I1. a second SHELL client, on the node itself: a pane of ANOTHER tmux server (the
# shell's own), no ssh, $TMUX left set — C5's `fleet` shell run on the machine.
SW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n shell2 "bash '$BIN/fleet-remote-view.sh' attach --shell '$WID2'; sleep 300")
waitfor 10 natt 2 || fail "I: the nested --shell client never attached" "$(tl capture-pane -p -t "$SW" | head -3)"
settle
still || fail "I: a second shell changed the node" "$(layout) vs $L0"
eq "I: …no list" "" "$(rviews)"
eq "I: the registry holds the view and the shell" "shell view " "$(regrows | cut -f3 | sort | tr '\n' ' ')"
srow=$(regrows | awk -F '\t' '$3 == "shell"')
eq "I: the shell row names the remote session" "$RS" "$(printf '%s' "$srow" | cut -f2)"
has "I: …the shell client's tty" "$(tr_ list-clients -F '#{client_tty}' | tr '\n' ' ')" "$(printf '%s' "$srow" | cut -f1)"
kill -0 "$(printf '%s' "$srow" | cut -f5)" 2>/dev/null; eq "I: …a live pid" "0" "$?"
eq "I: …and no spool: nothing drains one for a shell without a view id" "" "$(ls -d "$FLEET_CONF_DIR"/remote-views/shell-*.d 2>/dev/null)"

# ============================================================================
# J. two shells, each its own current window (#1489)
# ============================================================================
S2ID=''; for f in "$FLEET_CONF_DIR"/remote-views/shell-*; do [ -f "$f" ] && { S2ID=${f##*/}; break; }; done; S2V="$RS@view-$S2ID"
eq "J: the nested shell has a view session of its own, named by its registry id" "1" "$(tr_ has-session -t "=$S2V" 2>/dev/null && echo 1)"
eq "J: …two view sessions now, both grouped onto the fleet session" "$RS $RS" "$(tr_ display-message -p -t "=$VS:" '#{session_group}') $(tr_ display-message -p -t "=$S2V:" '#{session_group}')"
eq "J: …each on the window it asked for (both worker 8 so far)" "$RW8 $RW8" "$(vcur "$VS") $(vcur "$S2V")"
# `select <wid> <view>` — what `open` sends for a retarget — moves THAT view alone.
bash "$BIN/fleet-remote-view.sh" select "$WID" "$S2ID" 2>/dev/null; eq "J: select with a view id answers 0" "0" "$?"
eq "J: the nested shell shows worker 7, the proxy still worker 8, the fleet session is where the person left it" "$RW $RW8 plan" "$(vcur "$S2V") $(vcur "$VS") $(rscur)"
# `select <wid>` with no view id (an older open): the fleet session alone.
bash "$BIN/fleet-remote-view.sh" select "$WID2" >/dev/null 2>&1
eq "J: select with no view id moves the fleet session and nobody's view" "$RW8 $RW $RW8" "$(tr_ display-message -p -t "=$RS:" '#{window_id}') $(vcur "$S2V") $(vcur "$VS")"
tr_ select-window -t "=$RS:plan"
# `serve` (#1682) — what the channel runs: one answer per request, a window found
# once is remembered but re-checked by its identity, never trusted blind.
out=$(printf 'a select %s\nb select %s\nc ping -\nd bogus x\n' "$WID" "$WID" | bash "$BIN/fleet-remote-view.sh" serve "$S2ID" 2>/dev/null | tr '\n' ' ')
eq "M: serve answers each request by its nonce" "a 0 b 0 c 0 d 2 " "$out"
eq "M: …and moved that view alone" "$RW $RW8 plan" "$(vcur "$S2V") $(vcur "$VS") $(rscur)"
# A window born since the attach (#1549) has its own header — selecting it in a
# view takes it, one way (issues #1682, #1713).
RW9=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n worker9 'while :; do sleep 300; done')
tr_ set-window-option -t "$RW9" @issue 9; tr_ set-window-option -t "$RW9" @fleet_id 99999999-0000-4000-8000-000000000009
eq "M: a window born since the attach still has its header" "" "$(tr_ show-options -wqv -t "$RW9" pane-border-status)"
out=$(printf 'a select %s\n' "$U/issue-9" | bash "$BIN/fleet-remote-view.sh" serve "$S2ID" 2>/dev/null)
eq "M: …selecting it takes the header now (off, nothing saved)" "a 0||off" "$out|$(tr_ show-options -wqv -t "$RW9" @remote_view_saved)|$(tr_ show-options -wqv -t "$RW9" pane-border-status)"
out=$( { printf 'a select %s\n' "$U/issue-9"; sleep 0.3; tr_ kill-window -t "$RW9"; printf 'b select %s\n' "$U/issue-9"; } \
       | bash "$BIN/fleet-remote-view.sh" serve "$S2ID" 2>/dev/null | tr '\n' ' ')
eq "M: selected, then gone: the remembered window is re-checked, not trusted" "a 0 b 3 " "$out"
tr_ select-window -t "=$S2V:$RW"
# The fleet's scans: every window once, under the fleet's name — so the worker
# is not AMBIGUOUS to fleet-peer-send (why #1424 had settled for a plain client).
eq "J: fleet_lw lists each window once while two view sessions hold them" "$(tr_ list-windows -t "=$RS" -F '#{session_name} #{window_id}')" "$(. "$BIN/fleet-lib.sh"; fleet_lw '#{session_name} #{window_id}' tr_)"
out=$(bash "$BIN/fleet-peer-send.sh" -L "$RS" issue:7 hi 2>&1)
hasnt "J: fleet-peer-send does not call issue 7 ambiguous beside two view sessions" "$out" "ambiguous"
has "J: …it resolved the one window and went looking for its Claude" "$out" "no live Claude session for '$RW'"
# A hook in a pane of the shared window names the FLEET — tmux's bare
# session_name there is whichever session holding the window was active last.
eq "J: FLEET_SESSION_FMT names the fleet from a pane of the shared window" "$RS" "$(tr_ display-message -p -t "$RW" '#{?#{session_group},#{session_group},#{session_name}}')"
# I2. a PLAIN client: someone on the node runs `attach` by hand — no --shell, no view
# — so it registers nothing and counts as a person. Everything back at once.
HW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n hand "env -u TMUX bash '$BIN/fleet-remote-view.sh' attach '$WID2'; sleep 300")
waitfor 10 natt 3 || fail "I: the plain client never attached" "$(tl capture-pane -p -t "$HW" | head -3)"
settle
still || fail "I: a plain client changed the node" "$(layout) vs $L0"
eq "I: …it registered nothing" "2" "$(regrows | wc -l | tr -d ' ')"
# I3. a shell arriving beside the plain client hides nothing (a view id too: a
# shell may carry a fleet-open spool).
SW3=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n shell3 "env -u TMUX bash '$BIN/fleet-remote-view.sh' attach --shell '$WID2' view3; sleep 300")
waitfor 10 natt 4 || fail "I: the third shell never attached"
settle
still || fail "I: a shell arriving beside a plain client changed the node" "$(layout) vs $L0"
eq "I: …registered as a shell, with its spool" "2 yes" "$(regrows | awk -F '\t' '$3 == "shell"' | wc -l | tr -d ' ') $([ -d "$FLEET_CONF_DIR/remote-views/view3.d" ] && echo yes)"
eq "I: …and a view session named by the id it brought (#1489)" "1" "$(tr_ has-session -t "=$RS@view-view3" 2>/dev/null && echo 1)"
# I4. that shell leaves: the plain client keeps everything.
tl kill-window -t "$SW3"
waitfor 10 natt 3 || fail "I: the third shell did not leave"
settle
still || fail "I: a shell leaving beside a plain client changed the node" "$(layout) vs $L0"
# I5. the plain client leaves: only shells remain — still nothing changes.
tl kill-window -t "$HW"
waitfor 10 natt 2 || fail "I: the plain client did not leave"
settle
still || fail "I: the plain client leaving changed the node" "$(layout) vs $L0"
eq "K: the headers stay off (one way)" "off|off |" "$(pbs) $(pbsaved)"
# I6. the nested shell leaves: the proxy alone; its row gone; still no hook.
tl kill-window -t "$SW"
waitfor 10 natt 1 || fail "I: the nested shell did not leave"
settle
still || fail "I: the nested shell leaving changed the node" "$(layout) vs $L0"
eq "I: one row left, the proxy's view" "view" "$(regrows | cut -f3 | tr '\n' ' ' | sed 's/ $//')"
eq "I: …and one view session, the proxy's (#1489)" "$VS" "$(vsess)"
eq "I: no hook on the server or the session (#1713)" "0 " "$(tr_ show-hooks -g | grep -c '\[77\]') $(tr_ show-hooks -t "=$RS:" 2>/dev/null)"

# ============================================================================
# E. close the proxy window
# ============================================================================
tl kill-window -t "$PW"
detached() { [ "$(gatt)" = 0 ]; }
waitfor 10 detached || fail "E: the remote client outlived the proxy window"
noview() { [ -z "$(vsess)" ]; }
waitfor 5 noview || fail "E: the proxy's view session outlived its client (#1489)" "$(vsess)"
eq "E: the remote worker still runs" "$RW8" "$(tr_ list-windows -t "=$RS:" -F '#{window_id}' | grep -x "$RW8")"
gone() { [ -z "$(ls "$FLEET_CONF_DIR/remote-views" 2>/dev/null)" ]; }
waitfor 5 gone || fail "E: the view registration was left behind" "$(ls "$FLEET_CONF_DIR/remote-views")"
settle
still || fail "E: the last client leaving changed the node" "$(layout) vs $L0"
eq "K: closed — the headers stay off, no marker left (one way)" "off|off |" "$(pbs) $(pbsaved)"
eq "E: no [77] hook" "0" "$(tr_ show-hooks -g | grep -c '\[77\]')"
eq "E: the legacy hooks never fired once the attach lifted them" "" "$(cat "$WORK/hook77" 2>/dev/null)"
eq "E: no session-level hook array left behind (it would shadow the fleet's [71]–[73] for good)" "" "$(tr_ show-hooks -t "=$RS:" 2>/dev/null)"
eq "E: the fleet's own hook is still in place" "1" "$(tr_ show-hooks -g | grep -c '^client-attached\[71\]')"

# ================================================================================
# L. no ⇄ (#1621): the machine's name alone marks a proxy window and a via row;
#    nothing names, matches or draws the arrow. Comments and the selftests aside,
#    only fleet-ui-lang.sh's toggle words (`live ⇄ landed`) may hold one.
arrows=$(cd "$BIN/.." && grep -n '⇄' bin/*.sh bin/*.py conf/*.conf 2>/dev/null \
         | grep -v -e '-selftest\.' -e '^bin/fleet-ui-lang\.sh:' \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
eq "L: no code line draws or matches a ⇄ (a proxy window is known by @remote)" "" "$arrows"

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-remote-view selftest: PASS (%d checks)\n' "$CHECKS"; exit 0
fi
printf 'fleet-remote-view selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
