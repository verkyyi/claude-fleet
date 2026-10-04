#!/bin/bash
# fleet-spot-evacuate-selftest.sh — bin/fleet-spot-evacuate.sh (issue #1428):
# the SPOT node's SIGTERM evacuation, with fleet-move.sh stubbed through the
# FLEET_MOVE_CMD seam and the fleets named through FLEET_SPOT_EVACUATE_SESSIONS,
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
#   D. deadline  FLEET_SPOT_EVACUATE_SECS too small for a second fleet: the
#                first moves, the second is skipped with a `deadline` line,
#                exit 1 and the summary says so
#   E. none      no live fleet: `moved 0, left 0`, exit 0, stub never called
#   F. dry-run   --dry-run passes --dry-run through and says so
#   G. max-all   fleet-move.sh --rebalance --max all parses (no "--max needs a
#                number" refusal); --max x is still refused; --max all is
#                refused outside the hub module like every --via hub form
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-spot-evacuate.sh"
CHECKS=0
fail() { printf 'fleet-spot-evacuate selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-spot-evacuate-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET FLEET_SPOT_EVACUATE_SECS FLEET_SPOT_EVACUATE_MARGIN FLEET_MOVE_CMD FLEET_SPOT_EVACUATE_SESSIONS

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
[ "$rc" -eq 10 ] || fail "A: exit $rc, want 10 with the module off"
[ ! -s "$STUB_LOG" ] || fail "A: fleet-move was called with the module off: $(cat "$STUB_LOG")"
grep -q 'module is off' "$WORK/err" || fail "A: stderr: $(cat "$WORK/err")"
[ -z "$out" ] || fail "A: stdout should be empty, got: $out"
ok

export CCQUOTA_FLEET=1

# B. moves
reset
out=$(FLEET_SPOT_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a=2 FAKE_fleet_b=1 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "B: exit $rc: $out"
[ "$(sed -n 1p "$STUB_LOG")" = "--rebalance --max all --session fleet-a" ] || fail "B: first call: $(sed -n 1p "$STUB_LOG")"
[ "$(sed -n 2p "$STUB_LOG")" = "--rebalance --max all --session fleet-b" ] || fail "B: second call: $(sed -n 2p "$STUB_LOG")"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 2 ] || fail "B: $(wc -l < "$STUB_LOG") calls"
printf '%s\n' "$out" | grep -q '^evacuate: fleet-a: moving idle sessions off' || fail "B: no per-fleet line: $out"
printf '%s\n' "$out" | grep -q '^  │ fleet-move: rebalance moved 2' || fail "B: fleet-move output not relayed: $out"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 3, left 0" ] || fail "B: summary: $(printf '%s\n' "$out" | tail -n 1)"
ok

# C. failed
reset
out=$(FLEET_SPOT_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a="1,1" FAKE_fleet_b=1 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "C: exit $rc, want 1: $out"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 2 ] || fail "C: the failure stopped the second fleet"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 2, left 1" ] || fail "C: summary: $(printf '%s\n' "$out" | tail -n 1)"
ok

# D. deadline — a 2s first move against a 3s budget with a 2s margin: the
# second fleet cannot start.
reset
out=$(FLEET_SPOT_EVACUATE_SESSIONS="fleet-a fleet-b" FAKE_fleet_a=sleep FAKE_fleet_b=1 \
  FLEET_SPOT_EVACUATE_SECS=3 FLEET_SPOT_EVACUATE_MARGIN=2 "$SUT" 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "D: exit $rc, want 1: $out"
[ "$(wc -l < "$STUB_LOG" | tr -d ' ')" = 1 ] || fail "D: $(wc -l < "$STUB_LOG") calls, want 1 (deadline)"
printf '%s\n' "$out" | grep -q '^evacuate: fleet-b: deadline' || fail "D: no deadline line: $out"
printf '%s\n' "$out" | grep -q 'left 0 (deadline cut the run)' || fail "D: summary: $out"
ok

# E. none
reset
out=$(FLEET_SPOT_EVACUATE_SESSIONS="" "$SUT" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "E: exit $rc: $out"
[ ! -s "$STUB_LOG" ] || fail "E: fleet-move called with no fleet"
[ "$(printf '%s\n' "$out" | tail -n 1)" = "evacuate: moved 0, left 0" ] || fail "E: summary: $out"
ok

# F. dry-run
reset
out=$(FLEET_SPOT_EVACUATE_SESSIONS="fleet-a" FAKE_fleet_a=1 "$SUT" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "F: exit $rc: $out"
[ "$(sed -n 1p "$STUB_LOG")" = "--rebalance --max all --session fleet-a --dry-run" ] || fail "F: call: $(sed -n 1p "$STUB_LOG")"
printf '%s\n' "$out" | grep -q 'left 0 (dry-run)' || fail "F: summary: $out"
ok

# G. fleet-move.sh --max all parses; --max x does not; both refused with the
# module off, like every hub form.
mv_out=$(CCQUOTA_FLEET=1 "$BIN/fleet-move.sh" --rebalance --max all --session no-such-fleet 2>&1); mv_rc=$?
printf '%s' "$mv_out" | grep -q -- '--max needs' && fail "G: --max all refused: $mv_out"
[ "$mv_rc" -ne 2 ] || fail "G: --max all is a usage error ($mv_out)"
mv_out=$(CCQUOTA_FLEET=1 "$BIN/fleet-move.sh" --rebalance --max x 2>&1); mv_rc=$?
[ "$mv_rc" -eq 2 ] && printf '%s' "$mv_out" | grep -q -- '--max needs a number, or all' || fail "G: --max x: rc=$mv_rc $mv_out"
mv_out=$(env -u CCQUOTA_FLEET "$BIN/fleet-move.sh" --rebalance --max all 2>&1); mv_rc=$?
[ "$mv_rc" -eq 2 ] && printf '%s' "$mv_out" | grep -q 'needs the hub module' || fail "G: off: rc=$mv_rc $mv_out"
ok

printf 'fleet-spot-evacuate selftest: OK (%d checks)\n' "$CHECKS"
