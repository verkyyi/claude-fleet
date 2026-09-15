#!/bin/bash
# fleet-doctor-quota-selftest.sh — the `quota` verdict in bin/fleet-doctor.sh, which
# is the only place a HUMAN is told that the pre-emptive rotation is running on
# incomplete data (issue #628).
#
# Why it needs its own test: the rows alone cannot carry this. An account ccquota
# cannot read produces NO row — deliberately, because a row of zeroes reads as a
# brand-new idle subscription and used to make that account both un-benchable and
# the first landing spot of a ceiling fan-out. But "no row" is also what a label
# ccquota has simply never heard of looks like, and the two need different advice.
# quota_parse says which on STDERR; the doctor is what turns that into a verdict:
#
#   clean payload          → PASS  (n/n pool accounts mapped)
#   available:false        → WARN, NAMING the account — expected while a token is
#                            fresh, but invisible to the rotation for as long as
#                            it lasts, so it must never be silent.
#   neither window present → FAIL  — the contract itself drifted (ccquota newer
#                            than this fleet); nobody is rotating on this account
#                            and no amount of ⚠ quota stale would ever say so.
#
# Hermetic: a FAKE ccquota on PATH, a scratch accounts pool, scratch conf +
# TMPDIR. No network, no tmux server, no real tokens. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-quota-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"     # physical path: the scripts resolve $BIN via pwd
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"      # else the perms check warns, not our line
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"

# --- fake ccquota: account a is always a clean reading; b's SHAPE is switchable.
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
case "$(cat "$FAKE_B_SHAPE_FILE" 2>/dev/null)" in
  unavail) b='{"account_uuid":"u-b","label":"b","available":false,"reason":"no reading","headroom_pct":0}' ;;
  shape)   b='{"account_uuid":"u-b","label":"b","headroom_pct":0}' ;;
  gone)    b='{"account_uuid":"u-z","label":"not-in-pool","headroom_pct":90,"five_hour":{"utilization":10}}' ;;
  *)       b='{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}' ;;
esac
printf '{"verdict":"ok","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}},%s]}' "$b"
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- quota line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
# the doctor's `quota` line only (its other checks depend on the host and are not
# this test's business); the leading verdict word is what we assert on.
quota_line() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" \
  FAKE_B_SHAPE_FILE="$WORK/b-shape" \
    bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+quota([[:space:]]|$)' | head -1
}

# 1. both accounts readable → PASS, n/n mapped.
printf '' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in *PASS*quota*"2/2 pool accounts mapped"*) ;; *) fail "1: a clean payload must PASS with 2/2 mapped" "$l";; esac
ok

# 2. ccquota says it cannot read b → WARN that NAMES b. Not a PASS (the rotation
# is blind to b) and not a FAIL (ccquota is behaving correctly, and one readable
# account is still enough to rotate on).
printf 'unavail' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in
  *WARN*quota*"NO reading for: b"*) ;;
  *) fail "2: available:false must WARN and name the account" "$l";;
esac
case "$l" in *"1/2 pool labels have one"*) ;; *) fail "2: the warn must count the labels that DO have a reading" "$l";; esac
case "$l" in *"never picked as a migrate landing spot"*) ;; *) fail "2: the warn must say what the missing row costs" "$l";; esac
ok

# 3. a shape the parser cannot read → FAIL. This is the acceptance case: before
# #628 the same payload produced `b 0 0 0 …` and a green PASS.
printf 'shape' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in *FAIL*quota*"payload shape not recognized for: b"*) ;; *) fail "3: an unparseable account must turn the quota line RED" "$l";; esac
ok

# 4. the pre-existing mapping warn still works: b is simply absent from ccquota's
# answer (a label it never knew), which is a naming problem, not a shape one.
printf 'gone' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in
  *WARN*quota*"maps only 1/2 pool labels"*) ;;
  *) fail "4: an unmapped label must keep its own (naming) advice" "$l";;
esac
ok

printf 'selftest OK: fleet-doctor quota verdict (%s cases — clean PASS, unreadable account WARN+named, unknown shape FAIL, unmapped label unchanged)\n' "$CHECKS"
exit 0
