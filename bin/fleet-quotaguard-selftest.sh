#!/bin/bash
# fleet-quotaguard-selftest.sh — hermetic test for bin/fleet-quotaguard.sh.
#
# Asserts the gate's contract against a FAKE ccquota (no hub, no network, no real
# subscription):
#   • DISARMED       FLEET_QUOTA_GATE unset/0 → exit 0 even when ccquota says hold.
#                    The guard must be opt-in; a fleet that never configured it
#                    behaves exactly as it did before the file existed.
#   • NOT INSTALLED  no ccquota on PATH → exit 0, even when armed.
#   • NO HUB         armed and installed but no CCQUOTA_HUB_URL → exit 0.
#   • HOLD           armed + ccquota exits 3 → exit 3, and the reason ccquota
#                    printed survives into OUR stderr line (that string is what
#                    lands in the dispatcher log; losing it leaves an operator
#                    with "quota gate closed" and nothing to act on).
#   • GO             armed + ccquota exits 0 → exit 0, silent.
#   • FAILS OPEN     armed + ccquota crashes (exit 1, or killed) → exit 0. A
#                    broken guard must never be able to halt the fleet. This is
#                    the control for HOLD: without it, "returns 3" and "returns
#                    anything nonzero" are indistinguishable, and a guard that
#                    stopped the fleet on its own bugs would pass every other
#                    assertion here.
#   • CEILING PASSED the configured ceiling actually reaches ccquota's argv.
#
# Exit 0 = pass. Non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-quotaguard.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
ARGV="$TMP/argv"

# A fake ccquota whose exit code is whatever $TMP/rc says. It records its argv so
# the test can prove the ceiling and account actually got through.
cat > "$FAKEBIN/ccquota" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV_FILE"
echo "fake ccquota reason: window nearly spent" >&2
exit "$(cat "$RC_FILE")"
FAKE
chmod +x "$FAKEBIN/ccquota"

FAILED=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=1; }

# run <expected-rc> <label> — invokes the guard with the current env, capturing
# stderr. Sets $STDERR for the caller.
run() {
  local want="$1" label="$2" rc
  STDERR=$("$SRC" --gate 2>&1 >/dev/null); rc=$?
  [ "$rc" -eq "$want" ] || fail "$label: exit $rc, want $want (stderr: $STDERR)"
}

export ARGV_FILE="$ARGV" RC_FILE="$TMP/rc"
echo 3 > "$TMP/rc"          # fake ccquota says HOLD unless told otherwise

# --- 1. disarmed: ccquota says hold, the guard must not ---
PATH="$FAKEBIN:$PATH" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=0 run 0 "disarmed must not gate"

# --- 2. armed but ccquota absent ---
PATH="$TMP/empty:/usr/bin:/bin" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=1 run 0 "missing ccquota must not gate"

# --- 3. armed, installed, but no hub configured ---
PATH="$FAKEBIN:$PATH" FLEET_QUOTA_GATE=1 CCQUOTA_HUB_URL='' \
  run 0 "no hub must not gate"

# --- 4. armed + hold ---
: > "$ARGV"
PATH="$FAKEBIN:$PATH" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=1 FLEET_QUOTA_CEILING=77 run 3 "armed + hold must refuse"
case "$STDERR" in
  *"window nearly spent"*) ;;
  *) fail "the reason from ccquota did not survive into our stderr: $STDERR" ;;
esac
case "$(cat "$ARGV")" in
  *"--ceiling 77"*) ;;
  *) fail "configured ceiling never reached ccquota: $(cat "$ARGV")" ;;
esac

# --- 5. armed + go ---
echo 0 > "$TMP/rc"
PATH="$FAKEBIN:$PATH" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=1 run 0 "armed + headroom must proceed"

# --- 6. CONTROL: armed + ccquota broken must still proceed ---
echo 1 > "$TMP/rc"
PATH="$FAKEBIN:$PATH" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=1 run 0 "a failing ccquota must fail OPEN, not halt the fleet"

# --- 7. the account override reaches ccquota when set ---
: > "$ARGV"; echo 0 > "$TMP/rc"
PATH="$FAKEBIN:$PATH" CCQUOTA_HUB_URL=http://hub.invalid \
  FLEET_QUOTA_GATE=1 FLEET_QUOTA_ACCOUNT=all run 0 "account override"
case "$(cat "$ARGV")" in
  *"--account all"*) ;;
  *) fail "FLEET_QUOTA_ACCOUNT never reached ccquota: $(cat "$ARGV")" ;;
esac

[ "$FAILED" = 0 ] && { echo "fleet-quotaguard-selftest: PASS"; exit 0; }
exit 1
