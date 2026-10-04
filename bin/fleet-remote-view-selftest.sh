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
#   B. open        — a proxy window `@remote=m4:<wid>`, named `⇄m4 …` (#1475), selected;
#                    a second row of the same machine RETARGETS it (still one)
#   H. local view  — (#1475) the local sidebar's `jump` on a remote row lands in
#                    the proxy window WITH the view: the list on the left, the other
#                    machine's pane on the right; `sync` keeps it there (a proxy
#                    window is a task window); `jump` on a local row takes it back;
#                    `prefix h` (`back`) returns to the last local window
#   C. attach      — the proxy is a client of the remote session, on the worker's
#                    window, status line + prefix off (saved), its sidebar gone
#                    (`@remote_view_solo`, #1475); typing reaches it
#   D. fleet-open  — from the remote session, the request reaches the proxy side
#                    (sent:proxy), not an escape on the remote's terminal
#   G. shared      — a client attaching AT the remote end gets status + prefix +
#                    sidebar back
#   E. close       — killing the proxy window leaves the remote worker running and
#                    hands the remote session its status line + sidebar back
#   F. skipped     — a proxy window is no dash row, no session in either cap
#                    tally, no fleet-restore row, no sleep candidate
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
# options → dropped; `-O check|exit|forward` → the master's answers; then host, cmd
op=''
while [ $# -gt 0 ]; do
  case "$1" in
    -O) op=$2; shift 2 ;;
    -o|-S|-L) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
[ -n "$op" ] && exit 0
shift                                    # the host
unset TMUX TMUX_PANE
cd "$HOME" && exec bash -c "$*"
EOF
chmod +x "$SHIM/tmux" "$SHIM/ssh"
export PATH="$SHIM:$PATH"
export FLEET_REMOTE_SSH_CMD="$SHIM/ssh"
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
RW=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n worker7 "cat > '$WORK/typed'")
tr_ set-window-option -t "$RW" @issue 7
RW8=$(tr_ new-window -d -P -F '#{window_id}' -t "$RS:" -n worker8 'while :; do sleep 300; done')
tr_ set-window-option -t "$RW8" @issue 8
# The remote fleet's own sidebar view, in the worker's window (#1475: it goes
# while the proxy is the only client, and comes back with the status line).
RVP=$(tr_ split-window -d -h -b -f -l 30 -P -F '#{pane_id}' -t "$RW" 'while :; do sleep 300; done')
tr_ set-option -p -t "$RVP" @sidebar 1

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
eq "B: named for the row and its machine — ⇄m4, the pane header's word too (#1475)" "⇄m4 侧边栏" "$(tl display-message -p -t "$PW" '#{window_name}')"
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
attached() { [ "$(tr_ display-message -p -t "=$RS:" '#{session_attached}' 2>/dev/null)" = 1 ]; }
waitfor 10 attached || fail "C: the proxy never attached to the remote session"
eq "C: the remote session shows the worker's window" "$RW" "$(tr_ display-message -p -t "=$RS:" '#{window_id}')"
eq "C: remote status line off while the proxy is its only client" "off" "$(tr_ show-options -qv -t "=$RS:" status)"
eq "C: remote prefix off" "None" "$(tr_ show-options -qv -t "=$RS:" prefix)"
has "C: what it was is saved" "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)" "status=- "
eq "C: the remote session is marked solo — its sidebar draws no list (#1475)" "1" "$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)"
rviews() { tr_ list-panes -s -t "$RS" -F '#{pane_id} #{@sidebar}' | awk '$2 == 1 { print $1 }' | tr '\n' ' '; }
eq "C: …the view it had is gone" "" "$(rviews)"
tl send-keys -t "$PW" 'hello-from-m5' Enter
typed() { grep -q 'hello-from-m5' "$WORK/typed" 2>/dev/null; }
waitfor 5 typed || fail "C: typing in the proxy window never reached the remote pane" "$(cat "$WORK/typed" 2>/dev/null)"
nviews=0; for f in "$FLEET_CONF_DIR"/remote-views/*; do [ -f "$f" ] && nviews=$((nviews + 1)); done
eq "C: one view registered (the fleet-open back channel)" "1" "$nviews"

# B (cont.): another row of the same machine retargets the SAME window
PW2=$(FLEET_SESSION=$LS bash "$BIN/fleet-remote-view.sh" open "$WID2" 2>/dev/null)
eq "B: a second row of m4 reuses the proxy window" "$PW" "$PW2"
eq "B: still exactly one proxy, now on the new worker" "$PW m4:$WID2" "$(proxies)"
on8() { [ "$(tr_ display-message -p -t "=$RS:" '#{window_id}' 2>/dev/null)" = "$RW8" ] && attached; }
waitfor 10 on8 || fail "B: the retargeted proxy never showed worker 8" "$(tr_ display-message -p -t "=$RS:" '#{window_id}')"

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
hasnt "F: fleet-restore's snapshot format names no proxy" "$snap" "⇄m4"
sl=$(FLEET_SLEEP=observe python3 "$BIN/fleet-sleep.py" scan --session "$LL" --dry-run 2>/dev/null)
hasnt "F: the sleeper reports nothing about the proxy" "$sl" "\"$PW\""

# ============================================================================
# G. someone attaches AT the remote end → its session gets status + prefix back
# ============================================================================
HW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n helper "env -u TMUX $REAL_TMUX -L $RS attach -t '=$RS'")   # quoted: zsh expands a bare =word
two() { [ "$(tr_ display-message -p -t "=$RS:" '#{session_attached}' 2>/dev/null)" = 2 ]; }
waitfor 10 two || fail "G: the second client never attached"
back() { [ -z "$(tr_ show-options -qv -t "=$RS:" status)" ] && [ -z "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)" ]; }
waitfor 5 back || fail "G: a client at the remote end did not get the status line back" "$(tr_ show-options -t "=$RS:" status)"
eq "G: …and the solo marker is gone: its sidebar may draw again (#1475)" "" "$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)"
tl kill-window -t "$HW"
one() { [ "$(tr_ display-message -p -t "=$RS:" '#{session_attached}' 2>/dev/null)" = 1 ]; }
waitfor 5 one || fail "G: the helper client did not leave"

# ============================================================================
# E. close the proxy window
# ============================================================================
tl kill-window -t "$PW"
detached() { [ "$(tr_ display-message -p -t "=$RS:" '#{session_attached}' 2>/dev/null)" = 0 ]; }
waitfor 10 detached || fail "E: the remote client outlived the proxy window"
eq "E: the remote worker still runs" "$RW8" "$(tr_ list-windows -t "=$RS:" -F '#{window_id}' | grep -x "$RW8")"
restored() { [ -z "$(tr_ show-options -qv -t "=$RS:" status)" ]; }
waitfor 5 restored || fail "E: the remote session's status line was not handed back" "$(tr_ show-options -t "=$RS:" status)"
eq "E: the saved marker is gone" "" "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)"
eq "E: the solo marker too" "" "$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)"
gone() { [ -z "$(ls "$FLEET_CONF_DIR/remote-views" 2>/dev/null)" ]; }
waitfor 5 gone || fail "E: the view registration was left behind" "$(ls "$FLEET_CONF_DIR/remote-views")"

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-remote-view selftest: PASS (%d checks)\n' "$CHECKS"; exit 0
fi
printf 'fleet-remote-view selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
