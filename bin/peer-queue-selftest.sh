#!/bin/bash
# peer-queue-selftest.sh — what cannot be delivered now waits for its recipient on
# THIS machine (issue #1647, EPIC #1645 C4): bin/fleet-peer-queue.sh, and the
# senders that use it — fleet-report-parent.sh and fleet-peer-send.sh. On an
# isolated tmux server, a sandbox conf dir, a fake `claude` (a perl symlink) and a
# real unix-socket peer inbox, pins:
#   A  three children report while their parent's Claude is DOWN: each says
#      `queued →`, exit 3, @reported stamped, nothing reaches the inbox; the
#      delivery book has three QUEUED rows and the parent's ledger three rows.
#   B  the parent's Claude comes back: one drain delivers all three — three
#      envelopes in the inbox, each exactly once — and a second drain adds none;
#      the book says DELIVERED for each, the queue is empty.
#   C  a drain for another identity (--fid) leaves an item alone; an item whose
#      recipient is not live stays queued.
#   D  a sleeping parent at a full fleet (fleet-sleep.py deliver exit 3): the
#      report is `queued →`, exit 3 — never `reported` — and not double-queued.
#   E  a recipient that never comes back: after FLEET_PEER_QUEUE_TTL the drain
#      drops it and the book says EXPIRED.
#   F  `wait`: DELIVERED 0, FAILED/EXPIRED 1, nothing yet 3.
#   G  fleet-peer-send.sh to a window with no live Claude: `queued →`, exit 3,
#      queued for that window's @fleet_id; delivered by the drain once it is up.
#   H  the degenerate case: no queue dir ⇒ drain prints nothing, creates nothing.
# tmux / perl / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'peer-queue selftest: tmux absent — SKIP'; exit 0; }
command -v perl >/dev/null 2>&1 || { echo 'peer-queue selftest: perl absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'peer-queue selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/peer-queue.XXXXXX")" || exit 2
L="pq$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_CHILD_REPORT FLEET_PEER_QUEUE_TTL

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { tmux -L "$L" "$@"; }
INBOX_PID=''
cleanup() { tmux -L "$L" kill-server 2>/dev/null; [ -n "$INBOX_PID" ] && kill "$INBOX_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# A shadow bin/: every script a symlink to the real one, except fleet-sleep.py — a
# fake whose `deliver` records the message and answers 3 (held at a full fleet).
SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/fleet-sleep.py"
cat > "$SB/fleet-sleep.py" <<'PY'
import os, sys
if "deliver" in sys.argv:
    with open(os.path.join(os.environ["FLEET_CONF_DIR"], "sleep-held"), "a") as f:
        f.write(sys.stdin.read().replace("\n", " ") + "\n")
    sys.exit(3)
sys.exit(0)
PY

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"; ln -sf "$(command -v perl)" "$FAKE/claude"

INBOX_LOG="$WORK/inbox.ndjson"; : > "$INBOX_LOG"
INBOX_SOCK="$WORK/inbox.sock"
python3 - "$INBOX_SOCK" "$INBOX_LOG" <<'PY' &
import os, socket, sys
path, log = sys.argv[1], sys.argv[2]
try: os.unlink(path)
except OSError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); s.listen(8)
while True:
    c, _ = s.accept()
    buf = b""
    while True:
        d = c.recv(65536)
        if not d: break
        buf += d
    c.close()
    with open(log, "ab") as fh: fh.write(buf)
PY
INBOX_PID=$!
disown "$INBOX_PID" 2>/dev/null || :
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$INBOX_SOCK" ] && break; sleep 0.3; done
[ -S "$INBOX_SOCK" ] || { echo 'peer-queue selftest: the fake inbox never appeared' >&2; exit 1; }
frames() { grep -c '"type":[[:space:]]*"auth"' "$INBOX_LOG" 2>/dev/null | tr -d ' '; }
mentions() { grep -o "$1" "$INBOX_LOG" 2>/dev/null | grep -c . | tr -d ' '; }

tf -f /dev/null new-session -d -s "$L" -n dash -c "$WORK" 'sleep 600' 2>/dev/null \
  || { echo 'peer-queue selftest: cannot start an isolated tmux server — SKIP'; exit 0; }
win() { tf new-window -d -P -F '#{window_id}' -n "$1" -c "$WORK" "${2:-sleep 600}"; }
# claude_up <window> — a live fake Claude in the window, registered on the inbox.
claude_up() {
  local p=''
  tf respawn-pane -k -t "$1" "PATH='$FAKE:\$PATH' exec claude -e 'sleep 600'"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(fleet_pane_claude_pid "$1" "$L" 2>/dev/null) && [ -n "$p" ] && break; sleep 0.3
  done
  [ -n "$p" ] || return 1
  printf '{"sessionId":"sid-%s","messagingSocketPath":"%s"}\n' "$p" "$INBOX_SOCK" > "$FLEET_CC_SESSIONS_DIR/$p.json"
  printf '{"peerToken":"tok"}\n' > "$FLEET_CC_SESSIONS_DIR/$p.deadbeef.key"
}

Q="$FLEET_CONF_DIR/fleets/$L/peer-queue"
BOOK="$FLEET_CONF_DIR/fleets/$L/delivery.ndjson"
LEDGER="$FLEET_CONF_DIR/fleets/$L/children/issue-50.ndjson"
qn() { ls "$Q"/*.json 2>/dev/null | wc -l | tr -d ' '; }
rows() { grep -c "\"state\": \"$1\"" "$BOOK" 2>/dev/null | tr -d ' '; }
PQ() { bash "$BIN/fleet-peer-queue.sh" "$@"; }

# --- H: degenerate --------------------------------------------------------------------
out=$(PQ drain -L "$L"); rc=$?
ok; [ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$Q" ] && [ ! -e "$BOOK" ] || fail "H: nothing queued ⇒ drain is silent and creates nothing" "rc=$rc out=$out"

# --- A: three reports while the parent's Claude is down -------------------------------
P=$(win parent); tf set-window-option -t "$P" @issue 50
PFID=$(fleet_window_fid "$L" "$P" "$L")
for n in 61 62 63; do
  c=$(win "child-$n"); tf set-window-option -t "$c" @issue "$n"; tf set-window-option -t "$c" @origin issue-50
  out=$(bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$c" --state blocked --summary "kid $n stuck" 2>&1); rc=$?
  ok; [ "$rc" = 3 ] && case "$out" in "queued → issue-50 ($P): BLOCKED"*) true ;; *) false ;; esac \
    || fail "A: report $n while the parent is down ⇒ queued, exit 3" "rc=$rc $out"
  ok; [ "$(tf show-options -wqv -t "$c" @reported)" = 1 ] || fail "A: a queued report stamps @reported ($n)"
done
ok; [ "$(qn)" = 3 ] && [ "$(frames)" = 0 ] || fail "A: three queued, nothing delivered" "queue=$(qn) frames=$(frames)"
ok; [ "$(rows QUEUED)" = 3 ] || fail "A: three QUEUED rows in the delivery book" "$(cat "$BOOK" 2>/dev/null)"
ok; [ "$(grep -c . "$LEDGER" 2>/dev/null)" = 3 ] || fail "A: the parent's ledger has the three reports" "$(cat "$LEDGER" 2>/dev/null)"
ok; [ "$(grep -l "\"to_fid\": \"$PFID\"" "$Q"/*.json | wc -l | tr -d ' ')" = 3 ] || fail "A: queued for the parent's @fleet_id" "$PFID"

# --- C: a drain for another identity, and a recipient not live, leave items alone -------
PQ drain -L "$L" --fid 00000000-1111-4222-8333-444444444444 >/dev/null
ok; [ "$(qn)" = 3 ] && [ "$(frames)" = 0 ] || fail "C: --fid of someone else delivers nothing" "queue=$(qn)"
PQ drain -L "$L" >/dev/null
ok; [ "$(qn)" = 3 ] && [ "$(frames)" = 0 ] || fail "C: the parent still has no Claude ⇒ all three wait" "queue=$(qn) frames=$(frames)"

# --- B: the parent is back: delivered, each once ---------------------------------------
claude_up "$P" || fail "B: no fake claude came up under the parent"
out=$(PQ drain -L "$L" --fid "$PFID"); rc=$?
ok; [ "$rc" = 0 ] && [ "$(qn)" = 0 ] && [ "$(frames)" = 3 ] || fail "B: one drain delivers all three" "rc=$rc out=$out queue=$(qn) frames=$(frames)"
for n in 61 62 63; do
  ok; [ "$(mentions "issue #$n")" = 1 ] || fail "B: child $n's report delivered exactly once" "$(mentions "issue #$n")"
done
PQ drain -L "$L" >/dev/null
ok; [ "$(frames)" = 3 ] || fail "B: a second drain delivers nothing again" "frames=$(frames)"
ok; [ "$(rows DELIVERED)" = 3 ] || fail "B: three DELIVERED rows" "$(cat "$BOOK")"

# --- D: a sleeper at a full fleet holds it: queued, never reported ---------------------
S=$(win sleeper); tf set-window-option -t "$S" @issue 70; tf set-window-option -t "$S" @worker_lifecycle sleeping
c=$(win child-71); tf set-window-option -t "$c" @issue 71; tf set-window-option -t "$c" @origin issue-70
before=$(qn)
out=$(bash "$SB/fleet-report-parent.sh" -L "$L" --win "$c" --state merged 2>&1); rc=$?
ok; [ "$rc" = 3 ] && case "$out" in "queued → issue-70"*"asleep at a full fleet"*) true ;; *) false ;; esac \
  || fail "D: a sleeper at a full fleet ⇒ queued, exit 3" "rc=$rc $out"
ok; grep -q 'issue #71' "$FLEET_CONF_DIR/sleep-held" 2>/dev/null && [ "$(qn)" = "$before" ] \
  || fail "D: held by the sleeper, not queued twice" "queue=$(qn)"

# --- E: never comes back ⇒ EXPIRED -------------------------------------------------------
G=$(win ghost); GFID=$(fleet_window_fid "$L" "$G" "$L"); tf kill-window -t "$G"
printf 'are you there?' | PQ put -L "$L" --to-fid "$GFID" --kind message --rid r-ghost --to ghost >/dev/null
PQ drain -L "$L" >/dev/null
ok; [ "$(qn)" = 1 ] || fail "E: within the TTL a gone recipient's item waits" "queue=$(qn)"
sleep 1
FLEET_PEER_QUEUE_TTL=0 PQ drain -L "$L" >/dev/null
ok; [ "$(qn)" = 0 ] && grep -q '"rid": "r-ghost".*"state": "EXPIRED"' "$BOOK" || fail "E: past the TTL ⇒ dropped, EXPIRED" "queue=$(qn) $(tail -1 "$BOOK")"

# --- F: wait -------------------------------------------------------------------------------
PQ note -L "$L" --rid r-ok --state delivered --to x --via hub
PQ note -L "$L" --rid r-bad --state failed --to x --via hub
PQ wait -L "$L" --rid r-ok --secs 0 >/dev/null; a=$?
PQ wait -L "$L" --rid r-bad --secs 0 >/dev/null; b=$?
PQ wait -L "$L" --rid r-ghost --secs 0 >/dev/null; c=$?
PQ wait -L "$L" --rid r-none --secs 0 >/dev/null; d=$?
ok; [ "$a$b$c$d" = 0113 ] || fail "F: wait DELIVERED 0 · FAILED 1 · EXPIRED 1 · nothing 3" "$a$b$c$d"

# --- G: peer-send to a window with no live Claude ----------------------------------------
W=$(win worker-80); tf set-window-option -t "$W" @issue 80
WFID=$(fleet_window_fid "$L" "$W" "$L")
out=$(bash "$BIN/fleet-peer-send.sh" -L "$L" "$W" 'hello, 80' 2>&1); rc=$?
ok; [ "$rc" = 3 ] && case "$out" in "queued → $W"*) true ;; *) false ;; esac \
  && grep -q "\"to_fid\": \"$WFID\"" "$Q"/*.json || fail "G: no live Claude ⇒ queued for its @fleet_id, exit 3" "rc=$rc $out"
claude_up "$W" || fail "G: no fake claude came up under the worker"
PQ drain -L "$L" >/dev/null
ok; [ "$(mentions 'hello, 80')" = 1 ] && [ "$(qn)" = 0 ] || fail "G: delivered by the drain once it is up" "$(mentions 'hello, 80') queue=$(qn)"
out=$(bash "$BIN/fleet-peer-send.sh" -L "$L" issue:80 'again, 80' 2>&1); rc=$?
ok; [ "$rc" = 0 ] && case "$out" in "sent → "*) true ;; *) false ;; esac || fail "G: a live Claude ⇒ sent, exit 0" "rc=$rc $out"

if [ "$FAIL" -eq 0 ]; then printf 'peer-queue selftest: PASS (%d checks)\n' "$CHECKS"; exit 0; fi
printf 'peer-queue selftest: %d FAILED of %d\n' "$FAIL" "$CHECKS" >&2; exit 1
