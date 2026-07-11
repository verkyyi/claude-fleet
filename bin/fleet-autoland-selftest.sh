#!/bin/bash
# fleet-autoland-selftest.sh — hermetic smoke test for bin/fleet-autoland.sh (issue #233).
#
# Drives the auto-land daemon against a FAKE fleet-land.sh + FAKE diskguard + FAKE gh
# (no network, no tmux server, no real merge) and asserts its CORE contract:
#   • LANDS READY       an OPEN PR whose prmap `ready` column == "ready" is landed.
#   • SKIPS NON-GREEN    behind / failing (✗) / MERGED rows are never landed.
#   • RATE-LIMIT         at most FLEET_AUTOLAND_MAX_PER_TICK lands per tick.
#   • OFF SWITCH         FLEET_AUTOLAND≠1 → no-op (nothing landed).
#   • SINGLE-WRITER      a fresh per-repo lease held by someone else → skip.
#   • DISK GATE          diskguard --gate closed → no-op for the whole tick.
#   • DRY-RUN            --dry-run mutates NOTHING (no land, no lease taken).
#   • LABEL SCOPE GUARD  FLEET_AUTOLAND_LABEL only lands PRs whose issue carries it.
#
# Detection is cache-only, so the scenario is entirely a canned prmap the daemon reads
# through fleet_cache (exactly as pr-refresh writes it): repo fake/repo → slug fake-repo.
#   issue-10 #101 OPEN ✓ ready   → LANDABLE
#   issue-11 #102 OPEN ✓ behind  → not landable (v1 leaves behind to the steward)
#   issue-12 #103 OPEN ✗ (none)  → not landable (CI not green)
#   issue-13 #104 MERGED ✓ ready → not landable (not OPEN)
#   issue-14 #105 OPEN ✓ ready   → LANDABLE
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + land record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-autoland.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fa-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases"
C="$WORK/.claude-dash"; mkdir -p "$C/fleets/fake-repo" "$C/global"
LAND_LOG="$WORK/lands"; : > "$LAND_LOG"

# The daemon + lib run from $WORK/bin so BIN resolves the fake lander + gate scripts
# sitting next to them (both are invoked as "$BIN/<name>").
cp "$SRC" "$WORK/bin/fleet-autoland.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-autoland.sh"

# --- fake fleet-land.sh: record the PR arg, emit a `landed:` token (as the real one
# does on stdout) so the daemon's token-parsing path is exercised. Never really merges.
cat > "$WORK/bin/fleet-land.sh" <<FAKE
#!/bin/bash
pr=''
while [ "\$#" -gt 0 ]; do case "\$1" in --pr) shift; pr="\${1:-}";; -*) : ;; *) pr="\$1";; esac; shift; done
printf '%s\n' "\$pr" >> "$LAND_LOG"
printf 'landed:fake%s\n' "\$pr"
exit 0
FAKE
chmod +x "$WORK/bin/fleet-land.sh"

# --- fake fleet-diskguard.sh: gate open unless $WORK/disk_closed exists ---------
cat > "$WORK/bin/fleet-diskguard.sh" <<FAKE
#!/bin/bash
if [ "\${1:-}" = --gate ]; then [ -f "$WORK/disk_closed" ] && exit 1; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake gh: the daemon only needs it to be on PATH (detection is cache-only) ---
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- caches (what the collector + pr-refresh would have written) ----------------
printf 's1\tfake-repo\tfake/repo\n' > "$C/global/sessmap"
cat > "$C/fleets/fake-repo/prmap" <<'PRMAP'
issue-10	#101	OPEN	✓	ready
issue-11	#102	OPEN	✓	behind
issue-12	#103	OPEN	✗
issue-13	#104	MERGED	✓	ready
issue-14	#105	OPEN	✓	ready
PRMAP
: > "$C/fleets/fake-repo/prmap.ts"

# --- run helper: a fresh env pointing FLEET_C (via TMPDIR) at our sandbox --------
run() { # extra args (session / --dry-run) → runs the daemon, appends to $WORK/log
  TMPDIR="$WORK" \
  PATH="$WORK/fakepath:$PATH" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-autoland.sh" "$@" >>"$WORK/log" 2>&1
}
reset() { : > "$LAND_LOG"; : > "$WORK/log"; rm -rf "$WORK/leases"/* 2>/dev/null || true; }
conf() { printf '%s\n' "$@" > "$WORK/conf/s1.conf"; }
landed_list() { tr '\n' ' ' < "$LAND_LOG" | sed 's/ *$//'; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- lands: [%s] ---\n' "$(landed_list)" >&2; exit 1; }

# ================================ tests =========================================

# 1) LANDS READY + SKIPS NON-GREEN + default cap 1 → exactly #101 (first ready row).
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1'
run s1
[ "$(landed_list)" = "101" ] || fail "default cap 1 should land only #101 (first ready), got [$(landed_list)]"
grep -q 'landed:fake101' "$WORK/log" || fail "should log the landed token for #101"
for n in 102 103 104 105; do
  grep -qxF "$n" "$LAND_LOG" && fail "#$n must NOT land (behind/failing/merged/over-cap)"
done

# 2) RATE-LIMIT: cap 2 lands BOTH ready rows (#101, #105) and nothing else.
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1' 'FLEET_AUTOLAND_MAX_PER_TICK=2'
run s1
[ "$(landed_list)" = "101 105" ] || fail "cap 2 should land [101 105] in prmap order, got [$(landed_list)]"
for n in 102 103 104; do
  grep -qxF "$n" "$LAND_LOG" && fail "#$n must NOT land under cap 2 either"
done

# 3) OFF SWITCH: FLEET_AUTOLAND=0 → no-op.
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=0'
run s1
[ -s "$LAND_LOG" ] && fail "FLEET_AUTOLAND=0 must land nothing"
grep -q 'autoland off' "$WORK/log" || fail "FLEET_AUTOLAND=0 should log 'autoland off'"

# 4) DISK GATE closed → whole tick is a no-op (checked before the per-fleet loop).
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1' 'FLEET_AUTOLAND_MAX_PER_TICK=2'
touch "$WORK/disk_closed"
run s1
rm -f "$WORK/disk_closed"
[ -s "$LAND_LOG" ] && fail "a closed disk gate must land nothing"
grep -q 'disk gate closed' "$WORK/log" || fail "a closed disk gate should log 'disk gate closed'"

# 5) DRY-RUN mutates nothing: no land call, no lease left behind.
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1' 'FLEET_AUTOLAND_MAX_PER_TICK=2'
run --dry-run s1
[ -s "$LAND_LOG" ] && fail "--dry-run must not call the lander"
ls "$WORK/leases"/autoland-*.lock >/dev/null 2>&1 && fail "--dry-run must not take a lease"
grep -q 'would land PR #101' "$WORK/log" || fail "--dry-run should log 'would land PR #101'"
grep -q 'would land PR #105' "$WORK/log" || fail "--dry-run should log 'would land PR #105'"

# 6) SINGLE-WRITER: a fresh (non-stale) per-repo lease held by someone else → skip.
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1'
mkdir -p "$WORK/leases/autoland-fake-repo.lock"
printf 'someone-else\n9999999999\n' > "$WORK/leases/autoland-fake-repo.lock/holder"
run s1
[ -s "$LAND_LOG" ] && fail "a held lease must block this tick (land nothing)"
grep -q 'another autolander holds the lease' "$WORK/log" || fail "should log the lease-held skip"
rm -rf "$WORK/leases"/* 2>/dev/null || true

# 7) LABEL SCOPE GUARD: only PRs whose bound issue carries FLEET_AUTOLAND_LABEL land.
#    issue 10 has 'autoland', issue 14 does not → only #101 lands (fail-closed on #105).
reset
conf 'FLEET_REPO="fake/repo"' 'FLEET_AUTOLAND=1' 'FLEET_AUTOLAND_MAX_PER_TICK=2' \
     'FLEET_AUTOLAND_LABEL="autoland"'
cat > "$C/fleets/fake-repo/labels" <<'LAB'
10	autoland,priority:p1
14	priority:p2
LAB
run s1
[ "$(landed_list)" = "101" ] || fail "label gate should land only #101 (issue 10 has 'autoland'), got [$(landed_list)]"
grep -q "missing gate label 'autoland'" "$WORK/log" || fail "should log the gate-miss skip for #105"
rm -f "$C/fleets/fake-repo/labels"

printf 'selftest PASS: lands ready · skips non-green · cap · off-switch · disk-gate · dry-run · single-writer · label-gate\n'
exit 0
