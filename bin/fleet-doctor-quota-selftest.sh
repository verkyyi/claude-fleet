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
# It also pins WHOSE reading that verdict is about (issue #668): every one of the
# four lines names the ccquota build, because ccquota has no tagged release and
# each machine's `go install …@latest` binary drifts on its own — "ccquota is
# probably newer than this fleet" is a guess until the version is printed beside
# it. A build predating `ccquota version` must still produce the same verdict,
# just without the version, so both halves are asserted.
#
# The fixture speaks ccquota's OWN vocabulary: `verdict` is one of go / hold /
# unknown (cmd/ccquota/budget.go), never "ok". `hold` — every account is at its
# ceiling — carries perfectly good rows and must land on the same verdict as
# `go`; only `unknown` means "no reading", and quota_parse alone drops that.
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

# --- fake ccquota: account a is always a clean reading; b's SHAPE is switchable,
# as is the payload's verdict and whether this build knows `version` at all.
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = version ]; then
  # Two flavours of "this build has no `version`". `stderr` is what ccquota does
  # today (usage on stderr, exit 2). `stdout` is the one that would actually
  # poison the line: a build — or a different implementation behind
  # FLEET_QUOTA_BIN — that prints its usage on STDOUT, handing the doctor a
  # whole English sentence to stamp onto the quota verdict.
  case "${FAKE_NO_VERSION:-}" in
    stderr) printf 'ccquota: unknown command "version"\n' >&2; exit 2 ;;
    stdout) printf 'ccquota — cross-endpoint Claude Code and Codex usage monitor\n\nUsage:\n'; exit 2 ;;
  esac
  printf 'ccquota %s\n' "${FAKE_VERSION:-9.9.9-testbuild}"
  exit 0
fi
case "$(cat "$FAKE_B_SHAPE_FILE" 2>/dev/null)" in
  unavail) b='{"account_uuid":"u-b","label":"b","available":false,"reason":"no reading","headroom_pct":0}' ;;
  shape)   b='{"account_uuid":"u-b","label":"b","headroom_pct":0}' ;;
  gone)    b='{"account_uuid":"u-z","label":"not-in-pool","headroom_pct":90,"five_hour":{"utilization":10}}' ;;
  *)       b='{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}' ;;
esac
# verdict: ccquota emits go / hold / unknown only (cmd/ccquota/budget.go).
v=$(cat "$FAKE_VERDICT_FILE" 2>/dev/null); v=${v:-go}
printf '{"verdict":"%s","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2026-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}},%s]}' "$v" "$b"
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- quota line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
# the doctor's `quota` line only (its other checks depend on the host and are not
# this test's business); the leading verdict word is what we assert on.
VER='9.9.9-testbuild'      # what the fake build calls itself
NO_VER=''                 # stderr|stdout → the fake has no `version` subcommand
quota_line() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" \
  FAKE_B_SHAPE_FILE="$WORK/b-shape" FAKE_VERDICT_FILE="$WORK/verdict" \
  FAKE_VERSION="$VER" FAKE_NO_VERSION="$NO_VER" \
    bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+quota([[:space:]]|$)' | head -1
}

# 1. both accounts readable → PASS, n/n mapped. `verdict:"go"` is ccquota's own
# word for it (never "ok"), and the line names the build that said so (#668).
printf '' > "$WORK/b-shape"; printf 'go' > "$WORK/verdict"
l=$(quota_line)
case "$l" in *PASS*quota*"2/2 pool accounts mapped"*) ;; *) fail "1: a clean payload must PASS with 2/2 mapped" "$l";; esac
case "$l" in *"ccquota $VER"*) ;; *) fail "1: the PASS line must name the ccquota build" "$l";; esac
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
case "$l" in *"ccquota $VER"*) ;; *) fail "2: the unreadable-account WARN must name the ccquota build" "$l";; esac
ok

# 3. a shape the parser cannot read → FAIL. This is the acceptance case: before
# #628 the same payload produced `b 0 0 0 …` and a green PASS.
printf 'shape' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in *FAIL*quota*"payload shape not recognized for: b"*) ;; *) fail "3: an unparseable account must turn the quota line RED" "$l";; esac
case "$l" in *"ccquota $VER"*) ;; *) fail "3: the shape FAIL must name the build — the whole point of #668: its advice guesses \"probably newer than this fleet\"" "$l";; esac
ok

# 4. the pre-existing mapping warn still works: b is simply absent from ccquota's
# answer (a label it never knew), which is a naming problem, not a shape one.
printf 'gone' > "$WORK/b-shape"
l=$(quota_line)
case "$l" in
  *WARN*quota*"maps only 1/2 pool labels"*) ;;
  *) fail "4: an unmapped label must keep its own (naming) advice" "$l";;
esac
case "$l" in *"ccquota $VER"*) ;; *) fail "4: the mapping WARN must name the ccquota build" "$l";; esac
ok

# 5. verdict `hold` — every account is at its ceiling. It is NOT "no data": the
# rows are real and the rotation still needs them (quota_parse drops only
# `unknown`), so the line must read exactly as it does under `go`. A fixture that
# only ever said "ok" — a value ccquota does not emit — never showed this.
printf '' > "$WORK/b-shape"; printf 'hold' > "$WORK/verdict"
l=$(quota_line)
case "$l" in *PASS*quota*"2/2 pool accounts mapped"*) ;; *) fail "5: verdict hold still carries rows — must PASS 2/2, not be dropped as no-data" "$l";; esac
ok

# 6. a ccquota too old to have `version` (usage on stderr, non-zero). The verdict
# must be untouched and the version simply absent — asking for it may never turn
# a quota line into an error of its own.
printf 'go' > "$WORK/verdict"
NO_VER=stderr; l=$(quota_line); NO_VER=''
case "$l" in *PASS*quota*"2/2 pool accounts mapped"*) ;; *) fail "6: a build without \`version\` must not disturb the verdict" "$l";; esac
case "$l" in *"ccquota $VER"*) fail "6: no version to be had — it must be omitted, not invented" "$l";; esac
case "$l" in *"ccquota → hub"*) ;; *) fail "6: without a version the line must degrade to a bare \`ccquota\`" "$l";; esac
ok

# 7. and a build that answers `version` with its USAGE on stdout. Taking that at
# face value would splice a sentence into the verdict; only a single
# whitespace-free token counts as a version, so this degrades exactly like 6.
NO_VER=stdout; l=$(quota_line); NO_VER=''
case "$l" in *PASS*quota*"2/2 pool accounts mapped"*) ;; *) fail "7: usage-on-stdout must not disturb the verdict" "$l";; esac
case "$l" in *"cross-endpoint"*|*"Usage:"*) fail "7: usage text is not a version — it must not reach the quota line" "$l";; esac
case "$l" in *"ccquota → hub"*) ;; *) fail "7: an unusable version answer must degrade to a bare \`ccquota\`" "$l";; esac
ok

printf 'selftest OK: fleet-doctor quota verdict (%s cases — clean PASS, unreadable account WARN+named, unknown shape FAIL, unmapped label unchanged, verdict hold still mapped, all four lines version-stamped, and graceful when the build has no usable version)\n' "$CHECKS"
exit 0
