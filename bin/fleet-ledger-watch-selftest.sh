#!/bin/bash
# fleet-ledger-watch-selftest.sh — hermetic smoke test for the ledger-watch daemon
# bin/fleet-ledger-watch.sh (issue #320). Derived from fleet-cleanup-daemon-selftest.sh.
#
# Drives the daemon across TWO ticks against a FAKE tmux (a canned window list I
# swap between ticks) + a FAKE fleet-history.sh (records every `record-closed`
# call) + a FAKE diskguard — no network, no tmux server, no real ledger. Asserts
# the snapshot-diff contract:
#   • VANISHED→RECORD  a worker window present last tick, gone this tick, not
#                       landed → handed to `fleet-history.sh record-closed` once.
#   • STILL-LIVE       a window present in BOTH ticks → never recorded.
#   • @raw EXCLUDED    a window with @raw=1 is never snapshotted → never recorded,
#                       even when it vanishes.
#   • PANEL EXCLUDED   a window with no @issue (dash/plan) is never recorded.
#   • DEDUP TOKEN      record-closed reporting "already in ledger" (a landed / prior
#                       row) is logged as skipped, not counted as a new record.
#   • FIRST TICK       no prior snapshot → records nothing (just seeds the snapshot).
#   • TRANSIENT EMPTY  an empty window read (session gone / tmux glitch) → skip the
#                       tick, KEEP the prior snapshot (never false-record live work).
#   • DRY-RUN          calls the recorder for nothing and does NOT overwrite the snapshot.
#   • OFF SWITCH       FLEET_LEDGER_WATCH=0 → no-op (default is ON).
#   • SINGLE-WRITER    a fresh per-repo lease held by someone else → skip.
#   • DISK GATE        diskguard --gate closed → no-op for the whole tick.
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + record-closed calls).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-ledger-watch.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/flw-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases"
REC_LOG="$WORK/records"; : > "$REC_LOG"
WINDOWS="$WORK/windows";  : > "$WINDOWS"

# The daemon + lib run from $WORK/bin so BIN resolves the fake history + gate
# scripts next to them (both invoked as "$BIN/<name>").
cp "$SRC" "$WORK/bin/fleet-ledger-watch.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-ledger-watch.sh"

# --- fake fleet-history.sh: log every record-closed --issue, emit a token --------
# issue 20 simulates a session ALREADY in the ledger (landed / a prior tick) → the
# "already in ledger — skipped" token, so the daemon's dedup-token handling is exercised.
cat > "$WORK/bin/fleet-history.sh" <<FAKE
#!/bin/bash
sub="\${1:-}"; shift 2>/dev/null || true
issue=''
while [ "\$#" -gt 0 ]; do case "\$1" in --issue) shift; issue="\${1:-}";; esac; shift; done
printf '%s\t%s\n' "\$sub" "\$issue" >> "$REC_LOG"
if [ "\$issue" = 20 ]; then printf 'closed #%s → already in ledger — skipped\n' "\$issue"
else printf 'closed-unlanded #%s → ledger (session s)\n' "\$issue"; fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-history.sh"

# --- fake fleet-diskguard.sh: gate open unless $WORK/disk_closed exists -----------
cat > "$WORK/bin/fleet-diskguard.sh" <<FAKE
#!/bin/bash
if [ "\${1:-}" = --gate ]; then [ -f "$WORK/disk_closed" ] && exit 1; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake tmux: `list-windows` echoes the canned $WORK/windows (swapped per tick) -
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ]; then shift 2; fi
case "\${1:-}" in
  list-windows) cat "$WINDOWS" 2>/dev/null ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

conf() { { printf 'FLEET_REPO="fake/repo"\n'; printf 'FLEET_MAIN="%s"\n' "$WORK/main"; printf '%s\n' "$@"; } > "$WORK/conf/s1.conf"; }
# window list rows: window-id|@issue|@raw|@worktree|pane_current_path|window_name
windows() { printf '%s\n' "$@" > "$WINDOWS"; }
run() {
  TMPDIR="$WORK" \
  PATH="$WORK/fakepath:$PATH" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-ledger-watch.sh" "$@" >>"$WORK/log" 2>&1
}
reset_log() { : > "$WORK/log"; }
recorded_list() { awk -F'\t' '$1=="record-closed"{printf "%s ",$2}' "$REC_LOG" | sed 's/ *$//'; }
reset_all() { : > "$REC_LOG"; : > "$WORK/log"; rm -rf "$WORK/leases"/* "$WORK/conf/fleets" 2>/dev/null || true; }
SNAP="$WORK/conf/fleets/s1/ledgerwatch.snap"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- record-closed calls: [%s] ---\n' "$(recorded_list)" >&2
         printf -- '--- snapshot ---\n' >&2; cat "$SNAP" 2>/dev/null >&2; exit 1; }

conf   # FLEET_LEDGER_WATCH unset → default ON

# ================================ tests =========================================

# 1) FIRST TICK seeds the snapshot, records nothing. Windows: two workers (10,11),
#    one @raw-with-issue (44 — must be excluded), one panel (dash, no @issue).
reset_all
windows '@1|10|0||/wk/issue-10|fix-ten' \
        '@2|11|0||/wk/issue-11|fix-eleven' \
        '@4|44|1||/main|raw-issue' \
        '@5|||||dash'
run s1
[ -z "$(recorded_list)" ] || fail "first tick must record nothing, got [$(recorded_list)]"
[ -f "$SNAP" ] || fail "first tick must seed the durable snapshot"
grep -q '^10	' "$SNAP" || fail "snapshot must contain worker issue 10"
grep -q '^11	' "$SNAP" || fail "snapshot must contain worker issue 11"
grep -q '^44	' "$SNAP" && fail "@raw window (issue 44) must NOT be snapshotted"
grep -qi 'dash' "$SNAP" && fail "panel window (dash) must NOT be snapshotted"

# 2) VANISHED→RECORD + STILL-LIVE: tick 2 drops 11 (and the @raw 44); 10 stays.
#    Only 11 is handed to record-closed; 10 (still live) and 44 (never snapshotted)
#    are not.
reset_log
windows '@1|10|0||/wk/issue-10|fix-ten' \
        '@5|||||dash'
run s1
[ "$(recorded_list)" = "11" ] || fail "vanished worker 11 must be recorded once (10 live, 44 @raw), got [$(recorded_list)]"
grep -q 'recorded 1 closed-unlanded' "$WORK/log" || fail "log should report 1 recorded row"
# snapshot now reflects the live set: 10 present, 11 gone.
grep -q '^10	' "$SNAP" || fail "snapshot must still contain live issue 10"
grep -q '^11	' "$SNAP" && fail "snapshot must drop the vanished issue 11"

# 3) DEDUP TOKEN: a landed/prior session (issue 20) that vanishes is handed to
#    record-closed, but the "already in ledger" token means it is NOT counted as a
#    new record (idempotency is enforced by fleet-history; the daemon just reports it).
reset_all
windows '@1|20|0||/wk/issue-20|landed-twenty'
run s1                                   # seed
reset_log
windows '@9|||||dash'                     # 20 vanished (was landed+reaped)
run s1
[ "$(recorded_list)" = "20" ] || fail "vanished 20 must still be handed to record-closed, got [$(recorded_list)]"
grep -q 'recorded 0 closed-unlanded' "$WORK/log" || fail "an 'already in ledger' token must count as 0 recorded"

# 4) TRANSIENT EMPTY read → skip tick, KEEP the prior snapshot (no false record).
reset_all
windows '@1|10|0||/wk/issue-10|fix-ten' '@2|11|0||/wk/issue-11|fix-eleven'
run s1                                    # seed snapshot with 10,11
reset_log
windows                                    # empty read (session gone / glitch)
run s1
[ -z "$(recorded_list)" ] || fail "an empty window read must record nothing, got [$(recorded_list)]"
grep -q 'skip tick' "$WORK/log" || fail "empty read should log a skipped tick"
grep -q '^11	' "$SNAP" || fail "empty read must NOT clobber the prior snapshot (11 lost)"
# and a following real tick with only 10 still detects 11 vanished (snapshot intact).
reset_log
windows '@1|10|0||/wk/issue-10|fix-ten'
run s1
[ "$(recorded_list)" = "11" ] || fail "after a kept snapshot, 11's vanish must still be caught, got [$(recorded_list)]"

# 5) DRY-RUN: calls the recorder for nothing and does NOT overwrite the snapshot.
reset_all
windows '@1|10|0||/wk/issue-10|fix-ten' '@2|11|0||/wk/issue-11|fix-eleven'
run s1                                    # seed 10,11
reset_log
windows '@1|10|0||/wk/issue-10|fix-ten'   # 11 vanished
run --dry-run s1
[ -z "$(recorded_list)" ] || fail "--dry-run must not call record-closed, got [$(recorded_list)]"
grep -q 'would record closed-unlanded issue #11' "$WORK/log" || fail "--dry-run should log the would-record"
grep -q '^11	' "$SNAP" || fail "--dry-run must NOT overwrite the snapshot (11 must remain)"
ls "$WORK/leases"/ledgerwatch-*.lock >/dev/null 2>&1 && fail "--dry-run must not take a lease"

# 6) OFF SWITCH: FLEET_LEDGER_WATCH=0 → no-op.
reset_all
conf 'FLEET_LEDGER_WATCH=0'
windows '@1|10|0||/wk/issue-10|fix-ten'
run s1
[ -f "$SNAP" ] && fail "FLEET_LEDGER_WATCH=0 must not even snapshot"
grep -q 'ledger-watch off' "$WORK/log" || fail "off-switch should log 'ledger-watch off'"
conf   # restore default-on

# 7) SINGLE-WRITER: a fresh (non-stale) per-repo lease held by someone else → skip.
reset_all
mkdir -p "$WORK/leases/ledgerwatch-fake-repo.lock"
printf 'someone-else\n9999999999\n' > "$WORK/leases/ledgerwatch-fake-repo.lock/holder"
windows '@1|10|0||/wk/issue-10|fix-ten'
run s1
[ -f "$SNAP" ] && fail "a held lease must block this tick (no snapshot written)"
grep -q 'another ledger-watcher holds the lease' "$WORK/log" || fail "should log the lease-held skip"
rm -rf "$WORK/leases"/* 2>/dev/null || true

# 8) DISK GATE closed → whole tick is a no-op (checked before the per-fleet loop).
reset_all
touch "$WORK/disk_closed"
windows '@1|10|0||/wk/issue-10|fix-ten'
run s1
rm -f "$WORK/disk_closed"
[ -f "$SNAP" ] && fail "a closed disk gate must not snapshot"
grep -q 'disk gate closed' "$WORK/log" || fail "a closed disk gate should log 'disk gate closed'"

printf 'selftest PASS: seed · vanished→record · still-live · @raw/panel excluded · dedup-token · transient-empty · dry-run · off-switch · single-writer · disk-gate\n'
exit 0
