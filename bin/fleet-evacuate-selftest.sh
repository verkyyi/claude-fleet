#!/bin/bash
# fleet-evacuate-selftest.sh — bin/fleet-evacuate.sh (issue #1428):
# the planned-outage evacuation (renamed from the SPOT one, #4797), with fleet-move.sh stubbed through the
# FLEET_MOVE_CMD seam and the fleets named through FLEET_EVACUATE_SESSIONS,
# so no tmux server and no hub are needed. Also pins the one line this issue
# added to fleet-move.sh: `--rebalance --max all`.
#
# What it pins:
#   A. off       CCQUOTA_FLEET unset: exit 10, the stub is NEVER called, one
#                stderr line — the single-machine degenerate case touches nothing
#   B. moves     two fleets, the stub moves 2 then 1: both called with
#                `--rebalance --max all --session <sess>`, in order; summary
#                `moved 3, left 0`; exit 0
#   C. failed    the stub reports a failure on one fleet: `left 1`, exit 1,
#                the other fleet still evacuated
#   D. deadline  FLEET_EVACUATE_SECS too small for a second fleet: the
#                first moves, the second is skipped with a `deadline` line,
#                exit 1 and the summary says so
#   E. none      no live fleet: `moved 0, left 0`, exit 0, stub never called
#   F. dry-run   --dry-run passes --dry-run through and says so
#   H. skipped   the new `moved N · skipped M · left K` summary (issue #1513):
#                moved 2, left 1 (the REFUSED one), exit 1
#   G. max-all   fleet-move.sh --rebalance --max all parses (no "--max needs a
#                number" refusal); --max x is still refused; --max all is
#                refused outside the hub module like every --via hub form
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/selftest-lib.sh"
SUT="$BIN/fleet-evacuate.sh"
CHECKS=0

st_sandbox "${TMPDIR:-/tmp}/fleet-evacuate-selftest.XXXXXX"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET FLEET_EVACUATE_SECS FLEET_EVACUATE_MARGIN FLEET_MOVE_CMD FLEET_EVACUATE_SESSIONS

# The stub fleet-move.sh: records its argv, answers per FAKE_<sess> (an
# integer N → "moved N"; "N,F" → "moved N, F failed"; "sleep" → takes 2s).
STUB="$WORK/fleet-move.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
sess=""
while [ $# -gt 0 ]; do case "$1" in --session) sess="$2"; shift 2 ;; --session=*) sess="${1#--session=}"; shift ;; *) shift ;; esac; done
v="$(eval "printf '%s' \"\${FAKE_$(printf '%s' "$sess" | tr -c 'A-Za-z0-9_' '_')-}\"")"
case "$v" in
  sleep) sleep 2; echo "fleet-move: rebalance moved 1"; exit 0 ;;
  new:*) IFS=: read -r _ n m k <<<"$v"; echo "  ↷ w ($sess): NO_ELIGIBLE_NODE"; echo "fleet-move: rebalance moved $n · skipped $m · left $k"; exit 0 ;;
  *,*) echo "fleet-move: rebalance moved ${v%%,*}, ${v##*,} failed"; exit 1 ;;
  '') echo "fleet-move: rebalance moved 0"; exit 0 ;;
  *) echo "  ✓ w ($sess): moved"; echo "fleet-move: rebalance moved $v"; exit 0 ;;
esac
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/stub.log" FLEET_MOVE_CMD="$STUB"
reset() { : > "$STUB_LOG"; }

# A. off
reset
out=$("$SUT" 2>"$WORK/err"); rc=$?
[ "$rc" -eq 10 ] || st_fail "A: exit $rc, want 10 with the module off"
[ ! -s "$STUB_LOG" ] || st_fail "A: fleet-move was called with the module off: $(cat "$STUB_LOG")"
grep -q 'module is off' "$WORK/err" || st_fail "A: stderr: $(cat "$WORK/err")"
[ -z "$out" ] || st_fail "A: stdout should be empty, got: $out"
st_count

export CCQUOTA_FLEET=1

# B. moves
reset
out=$(FLEET_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a=2 FAKE_fleet_b=1 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 0 ] || st_fail "B: exit $rc: $out"
[ "$(sed -n 1p "$STUB_LOG")" = "--rebalance --max all --session fleet-a" ] || st_fail "B: first call: $(sed -n 1p "$STUB_LOG")"
[ "$(sed -n 2p "$STUB_LOG")" = "--rebalance --max all --session fleet-b" ] || st_fail "B: second call: $(sed -n 2p "$STUB_LOG")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 2 ] || st_fail "B: $(wc -l < "$STUB_LOG") calls"
printf '%s\n' "$out" | grep -q '^evacuate: fleet-a: moving idle sessions off' || st_fail "B: no per-fleet line: $out"
printf '%s\n' "$out" | grep -q '^  │ fleet-move: rebalance moved 2' || st_fail "B: fleet-move output not relayed: $out"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 3, left 0" ] || st_fail "B: summary: $(printf '%s\n' "$out" | tail -n 1)"
st_count

# C. failed
reset
out=$(FLEET_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a="1,1" FAKE_fleet_b=1 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 1 ] || st_fail "C: exit $rc, want 1: $out"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 2 ] || st_fail "C: the failure stopped the second fleet"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 2, left 1" ] || st_fail "C: summary: $(printf '%s\n' "$out" | tail -n 1)"
st_count

# D. deadline — a 2s first move against a 3s budget with a 2s margin: the
# second fleet cannot start.
reset
out=$(FLEET_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a=sleep FAKE_fleet_b=1 \
  FLEET_EVACUATE_SECS=3 FLEET_EVACUATE_MARGIN=2 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 1 ] || st_fail "D: exit $rc, want 1: $out"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 1 ] || st_fail "D: $(wc -l < "$STUB_LOG") calls, want 1 (deadline)"
printf '%s\n' "$out" | grep -q '^evacuate: fleet-b: deadline' || st_fail "D: no deadline line: $out"
printf '%s\n' "$out" | grep -q 'left 0 (deadline cut the run)' || st_fail "D: summary: $out"
st_count

# E. none
reset
out=$(FLEET_EVACUATE_SESSIONS="" "$SUT" 2>&1); rc=$?
[ "$rc" -eq 0 ] || st_fail "E: exit $rc: $out"
[ ! -s "$STUB_LOG" ] || st_fail "E: fleet-move called with no fleet"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 0, left 0" ] || st_fail "E: summary: $out"
st_count

# F. dry-run
reset
out=$(FLEET_EVACUATE_SESSIONS="fleet-a" FAKE_fleet_a=1 "$SUT" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || st_fail "F: exit $rc: $out"
[ "$(sed -n 1p "$STUB_LOG")" = "--rebalance --max all --session fleet-a --dry-run" ] || st_fail "F: call: $(sed -n 1p "$STUB_LOG")"
printf '%s\n' "$out" | grep -q 'left 0 (dry-run)' || st_fail "F: summary: $out"
st_count

# H. skipped (#1513) — fleet-move.sh's `moved N · skipped M · left K` summary:
# the first session was REFUSED and skipped, the next two moved; `left` comes
# from K (the skipped one is still here), and the run is not "everything moved".
reset
out=$(FLEET_EVACUATE_SESSIONS="fleet-a" FAKE_fleet_a="new:2:1:1" "$SUT" 2>&1); rc=$?
[ "$rc" -eq 1 ] || st_fail "H: exit $rc, want 1 (one session left): $out"
printf '%s\n' "$out" | grep -q '^  │   ↷ w (fleet-a): NO_ELIGIBLE_NODE' || st_fail "H: ↷ line not relayed: $out"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 2, left 1" ] || st_fail "H: summary: $(printf '%s\n' "$out" | tail -n 1)"
st_count

# G. fleet-move.sh --max all parses; --max x does not; both refused with the
# module off, like every hub form.
mv_out=$(CCQUOTA_FLEET=1 "$BIN/fleet-move.sh" --rebalance --max all --session no-such-fleet 2>&1); mv_rc=$?
printf '%s' "$mv_out" | grep -q -- '--max needs' && st_fail "G: --max all refused: $mv_out"
[ "$mv_rc" -ne 2 ] || st_fail "G: --max all is a usage error ($mv_out)"
mv_out=$(CCQUOTA_FLEET=1 "$BIN/fleet-move.sh" --rebalance --max x 2>&1); mv_rc=$?
[ "$mv_rc" -eq 2 ] && printf '%s' "$mv_out" | grep -q -- '--max needs a number, or all' || st_fail "G: --max x: rc=$mv_rc $mv_out"
mv_out=$(env -u CCQUOTA_FLEET "$BIN/fleet-move.sh" --rebalance --max all 2>&1); mv_rc=$?
[ "$mv_rc" -eq 2 ] && printf '%s' "$mv_out" | grep -q 'needs the hub module' || st_fail "G: off: rc=$mv_rc $mv_out"
st_count

printf 'fleet-evacuate selftest: OK (%d checks)\n' "$CHECKS"
