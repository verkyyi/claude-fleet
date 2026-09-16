#!/bin/bash
# fleet-quota-blind-selftest.sh — the FRESH-BUT-EMPTY quota alarm (issue #684):
# the second way the pre-emptive rotation goes blind, and the one no staleness
# check can ever see.
#
# Why it needs its own test. `account.quota.ts` is restamped by EVERY fetch,
# including the ones that came back with nothing — deliberately, so a dead hub is
# retried at TTL cadence instead of on every call. The cost of that choice is a
# cache that is FRESH and EMPTY, which reads as healthy to every alarm keyed on
# the stamp's age. Live on 2026-09-15 that state held at least six minutes:
#
#   wc -c account.quota            → 0            (not one row)
#   fleet-quotawatch.sh --status   → fresh 117    (refreshed 2 minutes ago)
#   ccquota budget --account all   → verdict go   (the hub was fine all along)
#
# …while the 70%/85% rotation had nothing to act on and #551's `⚠ quota stale`,
# fleet-doctor's qwatch line and the status bar were all green. The fix is a
# separate AXIS — consecutive empty fetches — not a tighter staleness bound, and
# this test pins the axis end to end: the counter in fleet-account.sh, the
# predicate in usage-lib.sh, the word `--status` answers with, and the verdict
# fleet-doctor prints. Those four are the whole visible contract; the tick's
# FLEET_NOTIFY_CMD wiring is out of scope here for the same reason #551's is —
# a real tick ends in `launchctl kickstart` and is not hermetic.
#
# The three things the alarm must NOT do, each pinned below, because an alarm
# that cries on a healthy install is one nobody reads by the second week:
#   • fire on ONE empty read (a hub blip, a fetch killed on its budget)
#   • fire on an empty POOL (no token files ⇒ nothing to have a reading about)
#   • fire on top of `stale` (no fetch is happening at all — the streak is frozen
#     history, and two red alarms for one broken daemon is one too many)
#
# Hermetic: a FAKE ccquota on PATH whose payload is switchable, a scratch accounts
# pool, scratch conf + TMPDIR + HOME. No network, no tmux server, no real tokens.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quota-blind-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"     # physical path: the scripts resolve $BIN via pwd
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
G="$WORK/.claude-dash/global"
MODE="$WORK/mode"

# --- fake ccquota. `rows` is a clean two-account payload; `empty` is ccquota's
# OWN word for "I have no reading" — verdict `unknown`, which quota_parse drops
# to zero rows (cmd/ccquota/budget.go emits go/hold/unknown, never "ok"). That is
# the shape the live incident produced, and the one the cache then froze.
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
[ "${1:-}" = version ] && { printf 'ccquota 9.9.9-testbuild\n'; exit 0; }
case "$(cat "$FAKE_MODE_FILE" 2>/dev/null)" in
  empty) printf '{"verdict":"unknown","accounts":[]}\n' ;;
  *) printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}},{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}]}\n' ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }

# Every invocation shares one environment; STREAK is the knob under test, so it is
# passed per call rather than baked in.
run() {
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" \
    CCQUOTA_HUB_URL="http://hub.test:8787" FAKE_MODE_FILE="$MODE" \
    ${STREAK:+FLEET_ACCOUNT_QUOTA_BLIND_STREAK="$STREAK"} "$@"
}
STREAK=''
fetch()  { run bash "$WORK/bin/fleet-account.sh" quota --refresh >/dev/null 2>&1; }
status() { run bash "$WORK/bin/fleet-quotawatch.sh" --status 2>/dev/null; }
blind()  { run bash -c '. "$0"; fleet_quota_blind' "$WORK/bin/usage-lib.sh" 2>/dev/null; }
counter(){ cat "$G/account.quota.empty" 2>/dev/null; }
qwatch() { run bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null \
             | grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+qwatch([[:space:]]|$)'; }
f1() { printf '%s' "$1" | cut -f1; }
f3() { printf '%s' "$1" | cut -f3; }

# 1. a hub that answers → rows cached, streak cleared, nothing to alarm about.
printf 'rows' > "$MODE"; fetch
[ "$(counter)" = "$(printf '0\t0')" ] || fail "1: a fetch that returns rows must clear the streak" "$(counter)"
[ "$(grep -c . "$G/account.quota")" = 2 ] || fail "1: the fixture must cache two rows" "$(cat "$G/account.quota")"
s=$(status); [ "$(f1 "$s")" = fresh ] || fail "1: a populated fresh cache reads fresh" "$s"
[ -z "$(blind)" ] || fail "1: nothing is blind here" "$(blind)"
ok

# 2. ONE empty read is noise, not an outage. This is the half that keeps the alarm
#    worth having: a single hub blip, or a fetch killed on FLEET_QUOTAWATCH_FETCH_BUDGET,
#    empties the cache for exactly one TTL and is gone by the next tick.
printf 'empty' > "$MODE"; fetch
[ "$(printf '%s' "$(counter)" | cut -f1)" = 1 ] || fail "2: the first empty fetch must count 1" "$(counter)"
s=$(status); [ "$(f1 "$s")" = fresh ] || fail "2: one empty read must NOT raise the alarm" "$s"
[ -z "$(blind)" ] || fail "2: one empty read must NOT raise the alarm" "$(blind)"
fetch
[ "$(printf '%s' "$(counter)" | cut -f1)" = 2 ] || fail "2: the streak must accumulate" "$(counter)"
[ -z "$(blind)" ] || fail "2: two empty reads is still under the default 3" "$(blind)"
ok

# 3. the third one IS the outage. The stamp is seconds old the whole way through —
#    that is the entire point: `stale` can never reach this state.
fetch
[ "$(printf '%s' "$(counter)" | cut -f1)" = 3 ] || fail "3: the streak must reach 3" "$(counter)"
b=$(blind); [ -n "$b" ] || fail "3: three consecutive empty reads must raise the alarm" "(nothing)"
[ "$(printf '%s' "$b" | cut -f1)" = 3 ] || fail "3: fleet_quota_blind must report the streak" "$b"
s=$(status)
[ "$(f1 "$s")" = blind ] || fail "3: --status must answer 'blind', not the 'fresh' that misled the operator" "$s"
[ "$(f3 "$s")" = 3 ] || fail "3: --status column 3 is the streak" "$s"
qage=$(printf '%s' "$s" | cut -f2)
case "$qage" in ''|*[!0-9]*) fail "3: --status column 2 must stay numeric for blind" "$s";; esac
ok

# 4. …and fleet-doctor turns it RED. Before #684 this exact state PASSed, which is
#    how six minutes of blind rotation went unnoticed on a box with a green doctor.
l=$(qwatch)
case "$l" in *FAIL*qwatch*"FRESH BUT EMPTY"*) ;; *) fail "4: the doctor must FAIL its qwatch line on a fresh-but-empty cache" "$l";; esac
case "$l" in *"#684"*) ;; *) fail "4: the verdict must cite the issue that explains it" "$l";; esac
case "$l" in *"ccquota budget --account all --json"*) ;; *) fail "4: the verdict must say how to check the hub" "$l";; esac
ok

# 5. recovery is immediate and unconditional — one fetch with rows clears it. A
#    streak that needed its own decay would leave the alarm up after the hub came
#    back, and an alarm that outlives its cause is the next thing to be ignored.
printf 'rows' > "$MODE"; fetch
[ "$(counter)" = "$(printf '0\t0')" ] || fail "5: rows must clear the streak outright" "$(counter)"
[ -z "$(blind)" ] || fail "5: the alarm must clear with the condition" "$(blind)"
s=$(status); [ "$(f1 "$s")" = fresh ] || fail "5: --status must go back to fresh" "$s"
l=$(qwatch)
case "$l" in *PASS*qwatch*) ;; *) fail "5: the doctor must go green again" "$l";; esac
ok

# 6. an EMPTY POOL is not blind, it is unconfigured. A hub URL set before any token
#    file exists is an ordinary state of a half-installed fleet, and ccquota having
#    no rows for zero accounts is the correct answer, not an outage. Seeded with a
#    live streak first, so this pins the CLEAR and not merely the absence of a bump.
printf '9\t%s\n' "$(( $(date +%s) - 900 ))" > "$G/account.quota.empty"
mv "$WORK/accounts/a" "$WORK/a.tok"; mv "$WORK/accounts/b" "$WORK/b.tok"
printf 'empty' > "$MODE"; fetch
[ "$(counter)" = "$(printf '0\t0')" ] || fail "6: a pool with no tokens must never count as blind" "$(counter)"
[ -z "$(blind)" ] || fail "6: a pool with no tokens must never raise the alarm" "$(blind)"
mv "$WORK/a.tok" "$WORK/accounts/a"; mv "$WORK/b.tok" "$WORK/accounts/b"
ok

# 7. STALE WINS. A stamp that has stopped moving means no fetch is happening at
#    all, so the streak is frozen history rather than a live reading — and the
#    deeper failure (the daemon is not running) is the one to report.
printf 'empty' > "$MODE"; fetch; fetch; fetch
[ "$(f1 "$(status)")" = blind ] || fail "7: precondition — the streak must be live before backdating" "$(status)"
printf '%s\n' "$(( $(date +%s) - 700 ))" > "$G/account.quota.ts"    # > FLEET_ACCOUNT_QUOTA_STALE
s=$(status); [ "$(f1 "$s")" = stale ] || fail "7: a stale stamp must win over the blind streak" "$s"
[ -z "$(blind)" ] || fail "7: fleet_quota_blind must stand down while the watch is stale" "$(blind)"
ok

# 8. the knob is real in both directions. 0 turns the alarm off outright (an
#    operator running a pool ccquota genuinely cannot read needs that escape
#    hatch); 1 fires on the first empty read.
printf '%s\n' "$(date +%s)" > "$G/account.quota.ts"                 # fresh again
STREAK=0
[ -z "$(blind)" ] || fail "8: FLEET_ACCOUNT_QUOTA_BLIND_STREAK=0 must switch the alarm off" "$(blind)"
[ "$(f1 "$(status)")" = fresh ] || fail "8: with the alarm off --status must not say blind" "$(status)"
STREAK=1
[ -n "$(blind)" ] || fail "8: FLEET_ACCOUNT_QUOTA_BLIND_STREAK=1 must fire on a streak of 1"
printf 'rows' > "$MODE"; fetch
[ -z "$(blind)" ] || fail "8: …and still clear on the first good fetch" "$(blind)"
STREAK=''
ok

printf 'selftest PASS: %s checks (counter · noise floor · alarm · doctor · recovery · empty pool · stale precedence · knob)\n' "$CHECKS"
exit 0
