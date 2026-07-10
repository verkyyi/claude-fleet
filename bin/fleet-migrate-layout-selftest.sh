#!/bin/bash
# fleet-migrate-layout-selftest.sh — hermetic test for bin/fleet-migrate-layout.sh
# (issue #181). Builds a legacy flat-layout fixture, runs the migrator, asserts the
# new per-fleet layout, verifies content is PRESERVED, that globals are untouched,
# that an unmappable (orphan) bridge file is left in place, and that a second run is
# a clean no-op (idempotent). No network, no tmux. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
MIG="$BIN/fleet-migrate-layout.sh"
[ -f "$MIG" ] || { echo "selftest: $MIG not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-migrate-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/conf"
mkdir -p "$ROOT"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
CHECKS=0
exists()  { CHECKS=$((CHECKS+1)); [ -e "$1" ] || fail "expected to exist: $1"; }
absent()  { CHECKS=$((CHECKS+1)); [ -e "$1" ] && fail "expected ABSENT: $1"; return 0; }
content() { CHECKS=$((CHECKS+1)); [ "$(cat "$2" 2>/dev/null)" = "$1" ] || fail "content mismatch in $2 (want [$1])"; }

# --- build the legacy fixture -------------------------------------------------
# Two fleets: fleet-acme (acme/widgets → slug acme-widgets) and fleet-bolt
# (bolt/gizmo → slug bolt-gizmo).
printf 'FLEET_REPO="acme/widgets"\nFLEET_MAIN="/x/acme"\n' > "$ROOT/fleet-acme.conf"
printf 'FLEET_REPO="bolt/gizmo"\n'                          > "$ROOT/fleet-bolt.conf"
# a backup file that must NOT be migrated (only *.conf moves)
printf 'old\n' > "$ROOT/fleet-acme.conf.bak"

mkdir -p "$ROOT/restore"
printf 'FLEET\tfleet-acme\tacme/widgets\t/x/acme\tmain\n' > "$ROOT/restore/fleet-acme.map"
printf 'FLEET\tfleet-bolt\tbolt/gizmo\t/x/bolt\tmain\n'   > "$ROOT/restore/fleet-bolt.map"
: > "$ROOT/restore/autorestore.on"                 # global — must stay
printf 'log line\n' > "$ROOT/restore/restore.log"  # global — must stay

mkdir -p "$ROOT/issue-bridge"
printf 'c123\n'          > "$ROOT/issue-bridge/bridge_acme-widgets.seen"
printf '2026-07-09T00:00:00Z\n' > "$ROOT/issue-bridge/bridge_acme-widgets.since"
# orphan: slug matches no configured fleet → must be LEFT in place
printf 'c999\n' > "$ROOT/issue-bridge/bridge_ghost-repo.seen"

mkdir -p "$ROOT/watch"
printf 'k1\nk2\n' > "$ROOT/watch/watch_bolt-gizmo.keys"
printf '3\n'      > "$ROOT/watch/watch_bolt-gizmo.needs"

mkdir -p "$ROOT/sweep"
printf '1783600000\n' > "$ROOT/sweep/fleet-acme.due"

# globals that must never move
mkdir -p "$ROOT/accounts" "$ROOT/diskguard"
: > "$ROOT/accounts/personal"
: > "$ROOT/diskguard/incident.log"

# --- run the migrator ---------------------------------------------------------
FLEET_CONF_DIR="$ROOT" bash "$MIG" >/dev/null 2>&1 || fail "migrator exited non-zero"

# --- assert the new layout ----------------------------------------------------
content 'FLEET_REPO="acme/widgets"
FLEET_MAIN="/x/acme"' "$ROOT/fleets/fleet-acme/conf"
absent  "$ROOT/fleet-acme.conf"
exists  "$ROOT/fleet-acme.conf.bak"                 # backup untouched
content 'FLEET_REPO="bolt/gizmo"' "$ROOT/fleets/fleet-bolt/conf"
absent  "$ROOT/fleet-bolt.conf"

content 'FLEET	fleet-acme	acme/widgets	/x/acme	main' "$ROOT/fleets/fleet-acme/restore.map"
absent  "$ROOT/restore/fleet-acme.map"
exists  "$ROOT/fleets/fleet-bolt/restore.map"
absent  "$ROOT/restore/fleet-bolt.map"
exists  "$ROOT/restore/autorestore.on"              # global restore control stays
content 'log line' "$ROOT/restore/restore.log"

content 'c123'                  "$ROOT/fleets/fleet-acme/bridge/seen"
content '2026-07-09T00:00:00Z'  "$ROOT/fleets/fleet-acme/bridge/since"
absent  "$ROOT/issue-bridge/bridge_acme-widgets.seen"
# orphan bridge file (no fleet for its slug) is LEFT in place
exists  "$ROOT/issue-bridge/bridge_ghost-repo.seen"

content 'k1
k2' "$ROOT/fleets/fleet-bolt/watch/keys"
content '3' "$ROOT/fleets/fleet-bolt/watch/needs"
absent  "$ROOT/watch/watch_bolt-gizmo.keys"

content '1783600000' "$ROOT/fleets/fleet-acme/sweep.due"
absent  "$ROOT/sweep/fleet-acme.due"

# globals untouched
exists  "$ROOT/accounts/personal"
exists  "$ROOT/diskguard/incident.log"

# --- idempotent re-run: a clean no-op, layout unchanged -----------------------
FLEET_CONF_DIR="$ROOT" bash "$MIG" >/dev/null 2>&1 || fail "re-run exited non-zero"
content 'c123' "$ROOT/fleets/fleet-acme/bridge/seen"   # still there, unchanged
exists  "$ROOT/fleets/fleet-bolt/conf"
exists  "$ROOT/issue-bridge/bridge_ghost-repo.seen"    # orphan still parked

# --- dual-migrate safety: a NEW-layout file present + a stale legacy dup -------
# Re-create a legacy conf whose new-layout conf already exists → the migrator must
# KEEP the new one and DROP the stale legacy source (never clobber newer state).
printf 'FLEET_REPO="acme/STALE"\n' > "$ROOT/fleet-acme.conf"
FLEET_CONF_DIR="$ROOT" bash "$MIG" >/dev/null 2>&1 || fail "dup re-run exited non-zero"
content 'FLEET_REPO="acme/widgets"
FLEET_MAIN="/x/acme"' "$ROOT/fleets/fleet-acme/conf"     # new one preserved
absent  "$ROOT/fleet-acme.conf"                          # stale legacy dropped

printf 'selftest OK: fleet-migrate-layout (%s assertions — legacy→per-fleet move, content preserved, globals untouched, orphan parked, idempotent, no-clobber)\n' "$CHECKS"
