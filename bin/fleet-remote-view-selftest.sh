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
#                    (`@remote_view_solo`, #1475); typing reaches it; registered
#                    as a `view` row; the fleet's own global client-attached hook
#                    still fires (the rule's hooks are global too, #1485)
#   D. fleet-open  — from the remote session, the request reaches the proxy side
#                    (sent:proxy), not an escape on the remote's terminal
#   G. shared      — a client attaching AT the remote end gets status + prefix +
#                    sidebar back
#   I. shells      — (#1485) hidden ⇔ every client is a shell/view: a second
#                    `--shell` client (nested on the node, no ssh, $TMUX set) keeps
#                    it hidden; a plain hand-run attach brings everything back at
#                    once; a shell arriving beside that plain client hides nothing;
#                    the plain client leaving hides again; the last shell takes the
#                    server's hooks with it, and no session-level hook array is
#                    left to shadow the fleet's own
#   E. close       — killing the proxy window leaves the remote worker running and
#                    hands the remote session its status line + sidebar back,
#                    the registry, the hooks and the markers all gone
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
# The fleet conf's own hook (tmux-attention.conf, client-attached[71]): a hook ON
# THE SESSION — #1475's form — would shadow it; the rule's hooks are global (#1485).
tr_ set-hook -g 'client-attached[71]' "run-shell -b 'echo att >> $WORK/hook71'"
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
regrows() { local f; for f in "$FLEET_CONF_DIR"/remote-views/*; do [ -f "$f" ] && cat "$f"; done; }
eq "C: one view registered (the fleet-open back channel)" "1" "$(regrows | wc -l | tr -d ' ')"
eq "C: …a row <tty> <session> view <since> <pid> (#1485)" "$RS view" "$(regrows | awk -F '\t' '{ print $2, $3 }')"
has "C: …its tty is the proxy client's" "$(tr_ list-clients -t "=$RS" -F '#{client_tty}' | tr '\n' ' ')" "$(regrows | cut -f1)"
kill -0 "$(regrows | cut -f5)" 2>/dev/null; eq "C: …its pid is the attach shell, alive" "0" "$?"
hook71() { [ -s "$WORK/hook71" ]; }
waitfor 5 hook71 || fail "C: the fleet's own global client-attached hook did not fire for the proxy (shadowed by a session-level hook?)"
eq "C: the rule's hooks are on the server, not the session" "2 " "$(tr_ show-hooks -g | grep -c '\[77\]') $(tr_ show-hooks -t "=$RS:" 2>/dev/null)"

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
# I. shells (#1485): hidden ⇔ at least one client, and every one a shell/view
# ============================================================================
hidden() { [ "$(tr_ show-options -qv -t "=$RS:" status)" = off ] && [ "$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)" = 1 ]; }
shown() { [ -z "$(tr_ show-options -qv -t "=$RS:" status)" ] && [ -z "$(tr_ show-options -qv -t "=$RS:" @remote_view_solo)" ] && [ -z "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)" ]; }
natt() { [ "$(tr_ display-message -p -t "=$RS:" '#{session_attached}' 2>/dev/null)" = "$1" ]; }
settle() { sleep 0.7; }   # the hooks run -b; give a NEGATIVE check time to be wrong
# After G the proxy is alone again — the rule hides (the old code left the status
# line on from the helper's visit until the proxy itself left).
waitfor 5 hidden || fail "I: the proxy alone again after G — not hidden" "$(tr_ show-options -t "=$RS:" status)"
# I1. a second SHELL client, on the node itself: a pane of ANOTHER tmux server (the
# shell's own), no ssh, $TMUX left set — C5's `fleet` shell run on the machine.
SW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n shell2 "bash '$BIN/fleet-remote-view.sh' attach --shell '$WID2'; sleep 300")
waitfor 10 natt 2 || fail "I: the nested --shell client never attached" "$(tl capture-pane -p -t "$SW" | head -3)"
settle
hidden || fail "I: two shells — must stay hidden" "$(tr_ show-options -t "=$RS:" status)"
has "I: …what was saved is still the original (no re-save)" "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)" "status=- "
eq "I: …no list" "" "$(rviews)"
eq "I: the registry holds the view and the shell" "shell view " "$(regrows | cut -f3 | sort | tr '\n' ' ')"
srow=$(regrows | awk -F '\t' '$3 == "shell"')
eq "I: the shell row names the remote session" "$RS" "$(printf '%s' "$srow" | cut -f2)"
has "I: …the shell client's tty" "$(tr_ list-clients -t "=$RS" -F '#{client_tty}' | tr '\n' ' ')" "$(printf '%s' "$srow" | cut -f1)"
kill -0 "$(printf '%s' "$srow" | cut -f5)" 2>/dev/null; eq "I: …a live pid" "0" "$?"
eq "I: …and no spool: nothing drains one for a shell without a view id" "" "$(ls -d "$FLEET_CONF_DIR"/remote-views/shell-*.d 2>/dev/null)"
# I2. a PLAIN client: someone on the node runs `attach` by hand — no --shell, no view
# — so it registers nothing and counts as a person. Everything back at once.
HW=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n hand "env -u TMUX bash '$BIN/fleet-remote-view.sh' attach '$WID2'; sleep 300")
waitfor 10 natt 3 || fail "I: the plain client never attached" "$(tl capture-pane -p -t "$HW" | head -3)"
waitfor 5 shown || fail "I: a plain client did not bring status + prefix + sidebar back" "$(tr_ show-options -t "=$RS:")"
eq "I: …it registered nothing" "2" "$(regrows | wc -l | tr -d ' ')"
# I3. a shell arriving beside the plain client hides nothing (a view id too: a
# shell may carry a fleet-open spool).
SW3=$(tl new-window -d -P -F '#{window_id}' -t "=$LS:" -n shell3 "env -u TMUX bash '$BIN/fleet-remote-view.sh' attach --shell '$WID2' view3; sleep 300")
waitfor 10 natt 4 || fail "I: the third shell never attached"
settle
shown || fail "I: a shell arriving while a plain client is attached must hide nothing" "$(tr_ show-options -t "=$RS:" status)"
eq "I: …registered as a shell, with its spool" "2 yes" "$(regrows | awk -F '\t' '$3 == "shell"' | wc -l | tr -d ' ') $([ -d "$FLEET_CONF_DIR/remote-views/view3.d" ] && echo yes)"
# I4. that shell leaves: the plain client keeps everything.
tl kill-window -t "$SW3"
waitfor 10 natt 3 || fail "I: the third shell did not leave"
settle
shown || fail "I: a shell leaving beside a plain client must change nothing" "$(tr_ show-options -t "=$RS:" status)"
# I5. the plain client leaves: only shells remain — hidden again, at once.
tl kill-window -t "$HW"
waitfor 10 natt 2 || fail "I: the plain client did not leave"
waitfor 5 hidden || fail "I: the plain client left, two shells remain — not hidden again" "$(tr_ show-options -t "=$RS:" status)"
eq "I: …and the saved values are the originals" "status=- prefix=- prefix2=- " "$(tr_ show-options -qv -t "=$RS:" @remote_view_saved)"
# I6. the nested shell leaves: the proxy alone — still hidden; its row gone; the
# server's hooks stay while a shell is registered, and never land on the session.
tl kill-window -t "$SW"
waitfor 10 natt 1 || fail "I: the nested shell did not leave"
settle
hidden || fail "I: the shell left, the proxy remains — must stay hidden" "$(tr_ show-options -t "=$RS:" status)"
eq "I: one row left, the proxy's view" "view" "$(regrows | cut -f3 | tr '\n' ' ' | sed 's/ $//')"
eq "I: the server's hooks stay while a shell is registered — and none on the session" "2 " "$(tr_ show-hooks -g | grep -c '\[77\]') $(tr_ show-hooks -t "=$RS:" 2>/dev/null)"

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
hooksoff() { [ "$(tr_ show-hooks -g | grep -c '\[77\]')" = 0 ]; }
waitfor 5 hooksoff || fail "E: the rule's hooks outlived the last shell" "$(tr_ show-hooks -g | grep '\[77\]')"
eq "E: no session-level hook array left behind (it would shadow the fleet's [71]–[73] for good)" "" "$(tr_ show-hooks -t "=$RS:" 2>/dev/null)"
eq "E: the fleet's own hook is still in place" "1" "$(tr_ show-hooks -g | grep -c '^client-attached\[71\]')"

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-remote-view selftest: PASS (%d checks)\n' "$CHECKS"; exit 0
fi
printf 'fleet-remote-view selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
