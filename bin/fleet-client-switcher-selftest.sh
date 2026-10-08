#!/usr/bin/env bash
# fleet-client-switcher-selftest.sh — ⌘K, the switcher (issue #2266, EPIC #2259 C7).
#
#   A  the lines (fleet-quickopen.py switch): every session the list knows, most
#      recent first (the one in view last), each with how long ago it was in
#      view; then 「+ 新会话」, a rule, and the layout flip — 「打开多会话视图」
#      in the one-session view (@fleet_layout solo), 「收起侧栏」 in any other —
#      and last 「退出 fleet」 (issue #2349).
#      A query filters the sessions and never the tail.
#   B  ↵ on a session (switch-run <key>) hands `jump=<key>` to the list pane's
#      queue — the list's own jump, as ⌘P's ↵ does.
#   C  ↵ on the flip (switch-run layout:multi / layout:solo) writes
#      FLEET_CLIENT_LAYOUT into fleet.conf's [client] (remembered) and switches
#      the running client (fleet-shell.sh layout <v> <session>); ↵ on 「+ 新会话」
#      opens a HOME session through the one primitive (fleet-shell.sh
#      home-session claude) on the popup's client session; ↵ on 「退出 fleet」
#      runs fleet-shell.sh quit <session> (issue #2349).
#   D  the history keeps `seen` beside `mru` (visit), and drops what fell off it.
#
# tmux runs on an isolated socket (-S under a temp dir), never a fleet's.
# Drives: bin/fleet-quickopen.py, bin/fleet-conf.sh, conf/tmux-shell.conf.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'FAIL %s\n' "$1" >&2; [ $# -gt 1 ] && printf '  got: %s\n' "$2" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: no tmux"; exit 0; }

W=$(mktemp -d "${TMPDIR:-/tmp}/fswitcher.XXXXXX") || fail "mktemp"
SOCK="$W/s"
cleanup() { tmux -S "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
export HOME="$W/home" FLEET_SWITCH_STATE="$W/state" FLEET_CONF_DIR="$W/conf"
mkdir -p "$HOME" "$FLEET_SWITCH_STATE" "$FLEET_CONF_DIR"
unset FLEET_CLIENT_LAYOUT

tmux -S "$SOCK" -f /dev/null new-session -d -s sw -x 120 -y 30 'cat' || fail "tmux did not start"
tmux -S "$SOCK" split-window -d -t sw: 'cat' || fail "split"
LIST=$(tmux -S "$SOCK" list-panes -t sw: -F '#{pane_id}' | head -1)
tmux -S "$SOCK" set-option -p -t "$LIST" @sidebar 1
pid=$(tmux -S "$SOCK" display-message -p '#{pid}')
export TMUX="$SOCK,$pid,0"

now=$(date +%s)
printf '%s\n' \
  "@1	working		alpha task	m5	verkyyi/claude-fleet	" \
  "@2	needs	!	beta fix	m4	verkyyi/claude-fleet	" \
  "@3	idle		gamma notes	m5		" \
  "wid:f/home-1	idle		home claude	m5		" > "$FLEET_SWITCH_STATE/switch-rows.tsv"
cat > "$FLEET_SWITCH_STATE/switch-history.json" <<EOF
{"stack": ["@3", "@2", "@1"], "at": 2, "mru": ["@1", "@2", "@3"],
 "seen": {"@1": $now, "@2": $((now - 300)), "@3": $((now - 7200))}}
EOF
Q() { python3 "$BIN/fleet-quickopen.py" "$@"; }

# --- A ----------------------------------------------------------------------------
tmux -S "$SOCK" set-option -g @fleet_layout solo
out=$(Q switch)
want="@2	beta fix	5m
@3	gamma notes	2h
wid:f/home-1	home claude	
@1	alpha task	<1m"
[ "$(printf '%s\n' "$out" | sed -n '1,4p')" = "$want" ] || fail "A: the sessions, most recent first, the one in view last, with ages" "$out"; ok
[ "$(printf '%s\n' "$out" | sed -n 5p)" = '!new	+ 新会话' ] || fail "A: 「+ 新会话」 is not right under the sessions" "$out"; ok
[ "$(printf '%s\n' "$out" | sed -n 6p)" = '--' ] || fail "A: no rule between 「+ 新会话」 and the flip" "$out"; ok
[ "$(printf '%s\n' "$out" | sed -n 7p)" = '!layout:multi	打开多会话视图' ] || fail "A: the one-session view's last line is not 打开多会话视图 (layout:multi)" "$out"; ok
[ "$(printf '%s\n' "$out" | sed -n 8p)" = '!quit	退出 fleet' ] || fail "A: the last line is not 退出 fleet (quit, issue #2349)" "$out"; ok
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 8 ] || fail "A: more than 4 sessions + 4 tail lines" "$out"; ok
tmux -S "$SOCK" set-option -g @fleet_layout multi
Q switch | tail -2 | head -1 | grep -q '^!layout:solo	' || fail "A: the multi-session view's flip is not 收起侧栏 (layout:solo)" "$(Q switch)"; ok
tmux -S "$SOCK" set-option -g @fleet_layout auto
Q switch | tail -2 | head -1 | grep -q '^!layout:solo	' || fail "A: an old user's auto layout does not offer 收起侧栏" "$(Q switch)"; ok
Q switch | tail -1 | grep -q '^!quit	' || fail "A: 退出 fleet is not the last line in the multi-session view" "$(Q switch)"; ok
out=$(Q switch gam)
[ "$(printf '%s\n' "$out" | head -1 | cut -f1)" = "@3" ] || fail "A: a query does not filter the sessions" "$out"; ok
[ "$(printf '%s\n' "$out" | grep -c '^@\|^wid:')" = 1 ] || fail "A: a query keeps rows it does not match" "$out"; ok
[ "$(printf '%s\n' "$out" | tail -4 | cut -f1 | tr '\n' ' ')" = "!new -- !layout:solo !quit " ] || fail "A: a query hid the tail" "$out"; ok

# --- B ----------------------------------------------------------------------------
tmux -S "$SOCK" set-option -p -t "$LIST" @sidebar_do ''
Q switch-run @2 sw || fail "B: switch-run on a session exited non-zero"
do_=$(tmux -S "$SOCK" show-options -pqv -t "$LIST" @sidebar_do)
[ "$do_" = "jump=@2 " ] || fail "B: ↵ on a session did not queue jump=<key> on the list" "$do_"; ok

# --- C ----------------------------------------------------------------------------
seam="$W/seam.sh"; rec="$W/seam.log"
cat > "$seam" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "${FLEET_SHELL_SESSION:-}" "$*" >> "$SEAM_LOG"
EOF
chmod +x "$seam"
export SEAM_LOG="$rec" FLEET_SWITCH_LAYOUT_CMD="$seam" FLEET_SWITCH_NEW_CMD="$seam home-session claude"
Q switch-run layout:multi sw || fail "C: switch-run layout:multi exited non-zero"
grep -qx 'sw|multi sw' "$rec" || fail "C: the running client was not switched to multi" "$(cat "$rec")"; ok
grep -q '^export FLEET_CLIENT_LAYOUT=multi$' "$FLEET_CONF_DIR/fleet.conf" || fail "C: multi was not remembered" "$(cat "$FLEET_CONF_DIR/fleet.conf")"; ok
( set +u; export FLEET_SHELL=1; . "$FLEET_CONF_DIR/fleet.conf"; [ "$FLEET_CLIENT_LAYOUT" = multi ] ) \
  || fail "C: fleet.conf's [client] does not give the shell multi" "$(cat "$FLEET_CONF_DIR/fleet.conf")"; ok
Q switch-run layout:solo sw || fail "C: switch-run layout:solo exited non-zero"
grep -qx 'sw|solo sw' "$rec" || fail "C: 收起侧栏 did not switch the client to solo" "$(cat "$rec")"; ok
[ "$(grep -c 'FLEET_CLIENT_LAYOUT=' "$FLEET_CONF_DIR/fleet.conf")" = 1 ] && grep -q '^export FLEET_CLIENT_LAYOUT=solo$' "$FLEET_CONF_DIR/fleet.conf" \
  || fail "C: 收起侧栏 did not write solo back (one line)" "$(cat "$FLEET_CONF_DIR/fleet.conf")"; ok
Q switch-run layout:bogus sw && fail "C: a layout that is not multi / solo was taken"; ok
: > "$rec"
Q switch-run new sw || fail "C: switch-run new exited non-zero"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$rec" ] && break; sleep 0.2; done
grep -qx 'sw|home-session claude' "$rec" || fail "C: 「+ 新会话」 did not open a HOME Claude session on the client" "$(cat "$rec")"; ok
# the real command when no seam: the one HOME-session primitive
grep -q '"fleet-shell.sh"), "home-session", "claude"' "$BIN/fleet-quickopen.py" || fail "C: 「+ 新会话」 is not fleet-shell.sh home-session claude"; ok
grep -q '"fleet-shell.sh"), "layout"' "$BIN/fleet-quickopen.py" || fail "C: the flip is not fleet-shell.sh layout"; ok
# 退出 fleet (issue #2349): fleet-shell.sh quit, on the popup's client session
: > "$rec"
FLEET_SWITCH_QUIT_CMD="$seam quit" Q switch-run quit sw || fail "C: switch-run quit exited non-zero"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$rec" ] && break; sleep 0.2; done
grep -qx 'sw|quit sw' "$rec" || fail "C: 「退出 fleet」 did not quit the client (fleet-shell.sh quit <session>)" "$(cat "$rec")"; ok
grep -q '"fleet-shell.sh"), "quit"' "$BIN/fleet-quickopen.py" || fail "C: 「退出 fleet」 is not fleet-shell.sh quit"; ok

# --- D ----------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("q", os.path.join(sys.argv[1], "fleet-quickopen.py"))
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
h = {"stack": [], "at": -1, "mru": [], "seen": {}}
t0 = int(time.time())
q.visit(h, "@a"); q.visit(h, "@b")
assert set(h["seen"]) == {"@a", "@b"} and h["seen"]["@b"] >= t0, h
h["mru"] = h["mru"][:1]
q.visit(h, "@c")
assert "@a" not in h["seen"], h          # fell off mru: gone from seen
q.save(h)
assert q.load() == h, (q.load(), h)
old = {"stack": ["@x"], "at": 0, "mru": ["@x"]}  # a history from before #2266
q.save(old)
assert q.load()["seen"] == {}, q.load()
assert q.ago(0) == "" and q.ago(t0 - 90, t0) == "1m" and q.ago(t0 - 3 * 86400, t0) == "3d"
PY
ok

echo "fleet-client-switcher-selftest: OK ($CHECKS checks)"
