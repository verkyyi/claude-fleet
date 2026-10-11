#!/bin/bash
# fleet-view-peer-selftest.sh — another machine's session as near as this one's
# (issue #2751, EPIC #2999 C4, 共同约定 8): the 看台's peer windows
# (bin/fleet_view.py go_far / view-peers), their pane (bin/fleet-peerlink.py pane)
# and the far end's bare 看台 + `select` fast path (bin/fleet-remote-view.sh).
#
# Three machines on isolated sockets (bin/fleet-view-peer-rig.sh): home (the thin
# client's home, with the real C5 keeper), far1 and far2; a fake ssh whose masters
# serve a socket and whose channels run on the far machine's own tmux server.
#   A. warm     — the 看台 attaches: a window per other machine is already there
#                 (panel, @peer, @peer_view) and drawn — its pane attached to the far
#                 看台 `v1-via-home`, which is bare (status off, no key table) and
#                 opens no peer windows or links of its own
#   B. go       — go to a far session: the far 看台 switches over ONE channel
#                 (peer-select, peer_ms), then the window is selected; the person's
#                 screen shows it; @peer_cur + the far row's cur= follow; the same
#                 session again is select-window alone (peer-window); a third
#                 machine likewise
#   C. near     — 10 switches here vs 10 across (the far 看台 moving each time):
#                 the view-switch.ndjson medians, the difference within
#                 FLEET_VIEW_PEER_SLACK_MS (default 150 — the target is 50, an idle
#                 box's reading; a shared CI runner gets the slack); a switch
#                 across clears no whole screen on the client
# The line dying under a window and a 看台 reaped with its windows still open are
# docs/BREAK-IT.md rows, drilled on the same rig by
# bin/fleet-break-it-peerlink-selftest.sh (peer-window-ssh-killed / -left-behind).
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
# shellcheck disable=SC2154  # PR_U_* / PR_W_* come from the sourced rig
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo "fleet-view-peer selftest: tmux absent — SKIP"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "fleet-view-peer selftest: python3 absent — SKIP"; exit 0; }
# a short root: a control socket's path must fit AF_UNIX's 104 bytes (macOS $TMPDIR does not)
PR_WORK="$(mktemp -d /tmp/fvp.XXXXXX)" || exit 2
unset TMUX TMUX_PANE FLEET_C FLEET_STATUS_G
# shellcheck source=fleet-view-peer-rig.sh
. "$BIN/fleet-view-peer-rig.sh"
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
cleanup() { pr_down; [ -n "${FLEET_VIEW_PEER_KEEP:-}" ] && { echo "kept: $PR_WORK" >&2; return; }; rm -rf "$PR_WORK"; }
trap cleanup EXIT INT TERM
LOG="$PR_WORK/m/home/conf/logs/view-switch.ndjson"
last() { tail -1 "$LOG" 2>/dev/null; }
shows() { pr_screen | grep -q "$1"; }

pr_up || { echo "fleet-view-peer selftest: the rig did not come up — SKIP" >&2; exit 0; }
pr_attach

# --- A. warm --------------------------------------------------------------------------
pr_wait 10 eval '[ -n "$(pr_peer far1)" ] && [ -n "$(pr_peer far2)" ]' && ok || fail "A: no peer windows after the attach: $(pr_t home list-windows -a -F '#{session_name} #{window_name} #{@peer}')"
P1=$(pr_peer far1); P2=$(pr_peer far2)
[ "$(pr_t home display-message -p -t "$P1" '#{@fleet_role}')" = panel ] && ok || fail "A: a peer window is not a panel"
pr_wait 15 sh -c "'$REAL_TMUX' -L '$PR_HS' capture-pane -p -t '$P1' | grep -q SCREEN-far1-orch" && ok \
  || fail "A: far1's window never drew far1: $(pr_t home capture-pane -p -t "$P1" | tr -s '\n' | head -3)"
pr_wait 10 sh -c "'$REAL_TMUX' -L '$PR_HS' capture-pane -p -t '$P2' | grep -q SCREEN-far2-home" && ok \
  || fail "A: far2's window never drew far2: $(pr_t home capture-pane -p -t "$P2" | tr -s '\n' | head -3)"
FV="$PR_FS1@view-v1-via-home"
pr_t far1 has-session -t "=$FV" 2>/dev/null && ok || fail "A: no far 看台 $FV on far1: $(pr_t far1 list-sessions)"
[ "$(pr_t far1 show-options -v -t "=$FV:" status 2>/dev/null)" = off ] && ok || fail "A: the far 看台 draws a status line"
[ "$(pr_t far1 show-options -v -t "=$FV:" key-table 2>/dev/null)" != fleet-view ] && ok || fail "A: the far 看台 holds the key table"
pr_t far1 list-windows -a -F '#{@peer}' | grep -q . && fail "A: the far machine made peer windows of its own" || ok
n=$(pr_in far1 python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("p", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(len(m.live_thin_views()))' "$BIN/fleet-peerlink.py")
[ "$n" = 0 ] && ok || fail "A: far1's keeper would count the far 看台 as a client of its own ($n)"
[ "$(pr_cur)" != "$P1" ] && ok || fail "A: the attach landed on a peer window"

# --- B. go ------------------------------------------------------------------------------
pr_wait 10 pr_up_link far1 || fail "B: far1's link never came up"
pr_go "$PR_U_far1/fid-a"; rc=$?
[ "$rc" = 0 ] && ok || fail "B: go to far1/a answered $rc: $(last)"
[ "$(pr_cur)" = "$P1" ] && ok || fail "B: the 看台 is not on far1's window ($(pr_cur))"
last | grep -q '"method":"peer-select"' && last | grep -q '"peer_ms"' && ok || fail "B: not logged peer-select: $(last)"
pr_wait 5 shows SCREEN-far1-a && ok || fail "B: the screen does not show far1/a: $(pr_screen | tr -s '\n' | head -3)"
printf 'B: the person'"'"'s screen after the switch to far1/a:\n%s\n' "$(pr_screen | sed '/^ *$/d' | head -3 | sed 's/^/   | /')"
[ "$(pr_t home display-message -p -t "$P1" '#{@peer_cur}')" = "wid:$PR_U_far1/fid-a" ] && ok || fail "B: @peer_cur did not follow"
pr_wait 5 grep -q "cur=$PR_U_far1/fid-a" "$PR_WORK/m/far1/conf/remote-views/v1-via-home" && ok \
  || fail "B: the far row's cur=: $(cat "$PR_WORK/m/far1/conf/remote-views/v1-via-home")"
pr_go "$PR_W_home_l1"; pr_go "$PR_U_far1/fid-a"; rc=$?
[ "$rc" = 0 ] && last | grep -q '"method":"peer-window"' && ok || fail "B: back to the session far1 already shows is not select-window alone: $(last)"
pr_go "$PR_U_far1/fid-b" && pr_wait 5 shows SCREEN-far1-b && ok || fail "B: far1/b: $(last) / $(pr_screen | tr -s '\n' | head -2)"
# a far row the hub names by its KEY (`<fleet UUID>/<key>`, the readable alias
# fleet_worker_id_key — what remote_<sess> carries), not its @fleet_id: the far
# end resolves it as rv_select does (issue #3007: the fast path answered 3, gone)
pr_go "$PR_U_far1/orchestrator" && pr_wait 5 shows SCREEN-far1-orch && ok \
  || fail "B: far1 by key (orchestrator): $(last) / $(pr_screen | tr -s '\n' | head -2)"
pr_wait 10 pr_up_link far2
pr_go "$PR_U_far2/fid-c" && [ "$(pr_cur)" = "$P2" ] && pr_wait 5 shows SCREEN-far2-c && ok || fail "B: far2/c: $(last)"
pr_go "$PR_W_home_l2" && pr_wait 5 shows SCREEN-home-l2 && ok || fail "B: back home: $(last)"

# --- C. as near as here ---------------------------------------------------------------------
: > "$LOG"
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ $((i % 2)) = 1 ]; then pr_go "$PR_W_home_l1"; else pr_go "$PR_W_home_l2"; fi
done
for i in 1 2 3 4 5 6 7 8 9 10; do
  if [ $((i % 2)) = 1 ]; then pr_go "$PR_U_far1/fid-a"; else pr_go "$PR_U_far1/fid-b"; fi
done
read -r MED_HERE MED_FAR MED_PEER < <(python3 - "$LOG" <<'PY'
import json, statistics, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
here = [r["ms"] for r in recs if r["method"] == "select-window"]
far = [r["ms"] for r in recs if r["method"] == "peer-select"]
peer = [r["peer_ms"] for r in recs if r["method"] == "peer-select"]
print(statistics.median(here) if len(here) == 10 else -1, statistics.median(far) if len(far) == 10 else -1,
      statistics.median(peer) if peer else -1)
PY
)
printf 'C: median switch here %s ms · across %s ms (the channel %s ms) · difference %s ms\n' \
  "$MED_HERE" "$MED_FAR" "$MED_PEER" "$(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "$MED_HERE" "$MED_FAR")"
[ "$MED_HERE" != -1 ] && [ "$MED_FAR" != -1 ] && ok || fail "C: not 10 + 10 switches: $(cat "$LOG")"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) <= float(sys.argv[3]) else 1)' \
  "$MED_HERE" "$MED_FAR" "${FLEET_VIEW_PEER_SLACK_MS:-150}" && ok \
  || fail "C: across is ${MED_FAR} ms against ${MED_HERE} ms here — more than ${FLEET_VIEW_PEER_SLACK_MS:-150} ms apart"
"$REAL_TMUX" -L "$PR_TL" pipe-pane -t "=$PR_TL:view" "cat > '$PR_WORK/client.bytes'"
sleep 0.3; pr_go "$PR_U_far1/fid-a"; pr_wait 5 shows SCREEN-far1-a; sleep 0.5
"$REAL_TMUX" -L "$PR_TL" pipe-pane -t "=$PR_TL:view"
python3 - "$PR_WORK/client.bytes" <<'PY' && ok || fail "C: a switch across cleared the client's whole screen"
import sys
b = open(sys.argv[1], "rb").read()
sys.exit(1 if (b"\x1b[2J" in b or b"\x1b[H\x1b[J" in b or b"\x1bc" in b) else 0)
PY

[ "$FAIL" = 0 ] || { printf 'fleet-view-peer selftest: %d failure(s) of %d checks\n' "$FAIL" "$((FAIL + CHECKS))" >&2; exit 1; }
printf 'selftest OK: fleet-view-peer (%d checks — warm · go · near)\n' "$CHECKS"
