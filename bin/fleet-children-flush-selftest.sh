#!/bin/bash
# fleet-children-flush-selftest.sh — hermetic tests for issue #939: with
# FLEET_CHILD_REPORT=batch, a parent's child reports reach it as ONE
# `[children-digest]` with the global progress, not one interrupt per report.
#
# What is pinned (the issue's 完成判据):
#   BATCH     1 parent, 5 children: 3 quiet reports within the window are delivered
#             ONCE, as one digest, when the oldest has waited BATCH_SECS
#   LOUD      a loud report is delivered at once, and carries the quiet news queued
#             ahead of it
#   BARRIER   every child terminal ⇒ delivered on the next tick, without waiting
#   IDLE      an idle parent gets pending news on the next tick
#   NO DUP    a repeated tick, or a parent migrated onto a NEW window id, never
#             re-sends (the cursor is keyed by the parent's key, not its window)
#   REAPED    a parent with no window: the events stay in the ledger, exit 0
#   ENVELOPE  header `[children-digest] N/M ✓ · k ⏳ · j !`, ≤6 child lines, the
#             overflow folded, `no reply needed` last
#   IMMEDIATE the default mode keeps the cursor current, so switching to batch does
#             not replay history
#
# Runs on a DEDICATED tmux server on its own -L label (never the live server, #159);
# the peer send is stubbed at fleet_peer_send so every delivery is counted exactly.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FLUSH="$BIN/fleet-children-flush.sh"
[ -f "$FLUSH" ] || { printf 'selftest: %s missing\n' "$FLUSH" >&2; exit 2; }

CHECKS=0
fail() { printf 'fleet-children-flush selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
eq()   { ok; [ "$2" = "$3" ] || fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }
has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

for t in tmux perl python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'fleet-children-flush selftest: %s absent — skipped\n' "$t"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-children-flush.XXXXXX")" || exit 2
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
unset TMUX TMUX_PANE

LBL="fcf-selftest-$$"
cleanup() { tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# A stub bin: every script symlinked, fleet-lib.sh wrapped so fleet_peer_send
# RECORDS the envelope instead of dialling a socket.
SBIN="$WORK/stubbin"; mkdir -p "$SBIN"
for f in "$BIN"/*; do ln -sf "$f" "$SBIN/${f##*/}"; done
rm -f "$SBIN/fleet-lib.sh"
SENDS="$WORK/sends"; : > "$SENDS"
cat > "$SBIN/fleet-lib.sh" <<STUB
. "$BIN/fleet-lib.sh"
fleet_peer_send() { printf '%s\n@@END@@\n' "\$2" >> "$SENDS"; }
STUB
# shellcheck source=/dev/null
. "$SBIN/fleet-lib.sh"
sends() { grep -c '^@@END@@$' "$SENDS" | tr -d ' '; }
last_send() { awk 'BEGIN{b=""} /^@@END@@$/{last=b; b=""; next} {b=b $0 "\n"} END{printf "%s", last}' "$SENDS"; }

# gh is never needed (no `stopped` report here), but a stray call must not reach GitHub.
mkdir -p "$WORK/ghbin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/ghbin/gh"; chmod +x "$WORK/ghbin/gh"
export PATH="$WORK/ghbin:$PATH"

FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
ln -sf "$(command -v perl)" "$FAKEBIN/claude"   # comm = claude, as fleet_pane_claude_pid wants

TM() { tmux -L "$LBL" "$@"; }
TM new-session -d -s "$LBL" -n dash -c "$WORK" "sleep 600" 2>/dev/null || fail "could not start the selftest tmux server"
WID=''
new_win() { WID=$(TM new-window -d -P -F '#{window_id}' -n "$1" -c "$WORK" "$2" 2>/dev/null); [ -n "$WID" ] || fail "could not create window $1"; }
# new_parent <issue> — a window with a live fake Claude, bound to <issue>.
new_parent() {
  new_win "parent-$1" "PATH='$FAKEBIN:\$PATH' exec claude -e 'sleep 600'"
  TM set-window-option -t "$WID" @issue "$1"
  TM set-window-option -t "$WID" @claude_state working
  local p=''
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(fleet_pane_claude_pid "$WID" "$LBL" 2>/dev/null) && [ -n "$p" ] && break; sleep 0.3
  done
  [ -n "$p" ] || fail "no fake claude under parent $1"
}
# new_child <issue> <parent-issue> <state> — sets $WID.
new_child() {
  new_win "kid-$1" "sleep 600"
  TM set-window-option -t "$WID" @issue "$1"
  TM set-window-option -t "$WID" @origin "issue-$2"
  TM set-window-option -t "$WID" @claude_state "$3"
}
REPORT() { bash "$SBIN/fleet-report-parent.sh" -L "$LBL" "$@" 2>&1; }
TICK()   { bash "$SBIN/fleet-children-flush.sh" "$LBL" "$@" 2>&1; }
LDIR="$FLEET_CONF_DIR/fleets/$LBL/children"
mkdir -p "$FLEET_CONF_DIR/fleets/$LBL"
printf 'FLEET_CHILD_REPORT=batch\n' > "$FLEET_CONF_DIR/fleets/$LBL/conf"
# age_ledger <key> <secs> — back-date every event of a ledger (the clock, not a sleep).
age_ledger() {
  python3 - "$LDIR/$1.ndjson" "$2" <<'PY'
import datetime, json, sys
p, d = sys.argv[1], int(sys.argv[2])
t = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=d)).strftime('%Y-%m-%dT%H:%M:%SZ')
ev = [json.loads(l) for l in open(p) if l.strip()]
open(p, 'w').write(''.join(json.dumps(dict(e, ts=t)) + '\n' for e in ev))
PY
}

# ============================================================================
# BATCH — 1 parent, 5 children; 3 quiet reports inside the window → ONE digest
# ============================================================================
new_parent 900; P900="$WID"
new_child 901 900 'done';  K901="$WID"
new_child 902 900 'done';  K902="$WID"
new_child 903 900 working; K903="$WID"   # fixing its red CI
new_child 904 900 working; K904="$WID"
new_child 905 900 working; K905="$WID"

out=$(REPORT --win "$K901" --state merged --pr 11 --summary 'comparator rebuilt'); rc=$?
eq 'batch: a quiet report exits 0' 0 "$rc"
REPORT --win "$K902" --state merged --pr 12 >/dev/null
REPORT --win "$K903" --state failed --pr 13 --summary 'RED: CI failure or merge conflict; fixing it' >/dev/null
eq 'batch: quiet reports are only RECORDED — nothing sent' 0 "$(sends)"
eq 'batch: a recorded child is stamped @reported (no reaper backstop repeat)' 1 \
  "$(TM display-message -p -t "$K901" '#{@reported}')"
eq 'batch: the ledger holds all three' 3 "$(grep -c . "$LDIR/issue-900.ndjson" | tr -d ' ')"

out=$(TICK)
eq 'a tick inside the window (parent working, 2 kids working) holds' 0 "$(sends)"
TICK >/dev/null
eq '…and so does the next one' 0 "$(sends)"

age_ledger issue-900 301
out=$(TICK)
eq 'the oldest news past BATCH_SECS → exactly one digest' 1 "$(sends)"
ok; has 'digest → issue-900' "$out" && has '· age ·' "$out" || fail "the tick must name the parent and the reason" "$out"
msg=$(last_send)
python3 - "$msg" <<'PY' || fail "the digest is not the fixed shape (see above)" "$msg"
import sys
l = sys.argv[1].rstrip('\n').split('\n')
assert l[0] == '[children-digest] 2/5 ✓', l[0]
body = l[1:-1]
assert len(body) == 3, body
assert body[0].startswith('  ▸ issue #903 "kid-903" FAILED (PR #13) — RED'), body[0]  # still working ⇒ ▸, sorted first
assert any(b.startswith('  ✓ issue #901 "kid-901" MERGED (PR #11) — comparator rebuilt') for b in body), body
assert any(b.startswith('  ✓ issue #902 "kid-902" MERGED (PR #12)') for b in body), body
assert l[-1].startswith('no reply needed'), l[-1]
PY
eq 'the cursor sits beside the ledger at the last delivered seq' 3 "$(tr -d ' \n' < "$LDIR/issue-900.cursor")"
TICK >/dev/null; TICK >/dev/null
eq 'NO DUP: repeated ticks after a delivery send nothing' 1 "$(sends)"

# ============================================================================
# LOUD — delivered at once, carrying the quiet news queued ahead of it
# ============================================================================
TM set-window-option -t "$K904" @claude_state 'done'
REPORT --win "$K904" --state merged --pr 14 >/dev/null
eq 'a fresh quiet report waits' 1 "$(sends)"
TM set-window-option -t "$K905" @claude_state needs   # set-claude-state.sh blocked
out=$(REPORT --win "$K905" --state blocked --summary 'needs a token only the operator has')
eq 'LOUD: a blocked report is delivered at once' 2 "$(sends)"
msg=$(last_send)
ok; has '  ! issue #905 "kid-905" BLOCKED — needs a token only the operator has' "$msg" \
  || fail "the loud line must be in the digest" "$msg"
ok; has '  ✓ issue #904 "kid-904" MERGED (PR #14)' "$msg" \
  || fail "the quiet news queued ahead must ride along" "$msg"
ok; has 'issue #901' "$msg" && fail "an already-delivered child must not be re-listed" "$msg"
eq 'LOUD: …and the cursor moved past both' 5 "$(tr -d ' \n' < "$LDIR/issue-900.cursor")"
TICK >/dev/null
eq 'LOUD: the tick after it sends nothing' 2 "$(sends)"

# ============================================================================
# NO DUP across a migrate: same key, NEW window id → same cursor
# ============================================================================
TM kill-window -t "$P900"
new_parent 900; P900B="$WID"
ok; [ "$P900B" != "$P900" ] || fail "the migrated parent should be a new window id"
TICK >/dev/null
eq 'a parent migrated onto a new window id is not re-sent old news' 2 "$(sends)"

# ============================================================================
# IDLE — an idle parent gets pending news on the next tick
# ============================================================================
TM set-window-option -t "$K902" @claude_state working   # keep the barrier out of it
REPORT --win "$K902" --state reaped --verdict merged >/dev/null
TICK >/dev/null
eq 'a working parent + a working kid + young news: hold' 2 "$(sends)"
TM set-window-option -t "$P900B" @claude_state 'done'
out=$(TICK)
eq 'IDLE: the parent went idle → delivered' 3 "$(sends)"
ok; has '· idle ·' "$out" || fail "the reason must be idle" "$out"
TM set-window-option -t "$P900B" @claude_state working

# ============================================================================
# BARRIER — every child terminal → delivered without waiting
# ============================================================================
new_parent 910
new_child 911 910 working; K911="$WID"
new_child 912 910 working; K912="$WID"
TM set-window-option -t "$K911" @claude_state 'done'
REPORT --win "$K911" --state merged --pr 21 >/dev/null
TICK >/dev/null
eq 'one of two kids still working: hold' 3 "$(sends)"
TM set-window-option -t "$K912" @claude_state 'done'
REPORT --win "$K912" --state merged --pr 22 >/dev/null
out=$(TICK)
eq 'BARRIER: all children terminal → one digest' 4 "$(sends)"
ok; has 'digest → issue-910' "$out" && has '· barrier ·' "$out" || fail "the reason must be barrier" "$out"
ok; has '[children-digest] 2/2 ✓' "$(last_send)" || fail "the barrier digest header" "$(last_send)"

# ============================================================================
# OVERFLOW — more than 6 changed children fold into one line
# ============================================================================
new_parent 920
for n in 1 2 3 4 5 6 7 8; do
  new_child "92$n" 920 'done'
  REPORT --win "$WID" --state merged --pr "3$n" >/dev/null
done
TICK >/dev/null
msg=$(last_send)
eq 'OVERFLOW: 8 terminal kids → one digest' 5 "$(sends)"
eq 'OVERFLOW: header + 6 lines + fold + no-reply = 9 lines' 9 "$(printf '%s\n' "$msg" | grep -c .)"
ok; has '  … 2 more — fleet-children.sh' "$msg" || fail "the overflow must fold" "$msg"

# ============================================================================
# REAPED parent — events stay in the ledger, nothing errors
# ============================================================================
new_parent 930; P930="$WID"
new_child 931 930 'done'; K931="$WID"
new_child 932 930 working
TM kill-window -t "$P930"
out=$(REPORT --win "$K931" --state merged --pr 41); rc=$?
eq 'REAPED: a report to a gone parent exits 0' 0 "$rc"
age_ledger issue-930 400
out=$(TICK); rc=$?
eq 'REAPED: the tick exits 0' 0 "$rc"
eq 'REAPED: nothing sent' 5 "$(sends)"
eq 'REAPED: the event stays in the ledger' 1 "$(grep -c '"issue-931"' "$LDIR/issue-930.ndjson" | tr -d ' ')"
ok; [ -f "$LDIR/issue-930.cursor" ] && fail "REAPED: no cursor may move for an undelivered digest"
out=$(TICK --dry-run)
ok; has 'kept in the ledger' "$out" || fail "--dry-run must say why a reaped parent is skipped" "$out"

# Stale news (older than a day) is history: never turned into a surprise digest.
new_parent 940
new_child 941 940 'done'
REPORT --win "$WID" --state merged --pr 51 >/dev/null
age_ledger issue-940 90000
TICK >/dev/null
eq 'STALE: day-old undelivered news is not flushed' 5 "$(sends)"

# ============================================================================
# IMMEDIATE — the default keeps the cursor current; switching to batch replays nothing
# ============================================================================
printf 'FLEET_CHILD_REPORT=immediate\n' > "$FLEET_CONF_DIR/fleets/$LBL/conf"
new_parent 950
new_child 951 950 'done'; K951="$WID"
REPORT --win "$K951" --state merged --pr 61 >/dev/null
eq 'IMMEDIATE: sent one by one, as before' 6 "$(sends)"
ok; has '[child-report] issue #951' "$(last_send)" || fail "immediate still sends a [child-report]" "$(last_send)"
eq 'IMMEDIATE: the cursor follows the delivery' 1 "$(tr -d ' \n' < "$LDIR/issue-950.cursor")"
TICK >/dev/null
eq 'IMMEDIATE: the tick does nothing in immediate mode' 6 "$(sends)"
printf 'FLEET_CHILD_REPORT=batch\n' > "$FLEET_CONF_DIR/fleets/$LBL/conf"
TICK >/dev/null
eq 'switched to batch: already-delivered news is not replayed' 6 "$(sends)"

# The usage rail.
out=$(bash "$FLUSH" --bogus 2>&1); rc=$?
eq 'an unknown flag exits 2' 2 "$rc"
out=$(bash "$FLUSH" -h 2>&1); rc=$?
eq '-h exits 0' 0 "$rc"
ok; has 'children-digest' "$out" || fail "-h must print the header" "$out"

printf 'fleet-children-flush selftest: %s checks passed\n' "$CHECKS"
