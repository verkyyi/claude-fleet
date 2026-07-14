#!/bin/bash
# fleet-base-sync-selftest.sh — hermetic smoke test for the base-sync daemon
# bin/fleet-base-sync.sh (issue #327). No network, no tmux server, no gh.
#
# Drives the daemon against REAL but LOCAL git repos (a bare "remote" + a base
# checkout clone) + a FAKE diskguard, with fleets named on argv (so the tmux
# fleet-discovery path is never taken), and asserts its core contract:
#   • BEHIND      a base behind the remote is fast-forwarded to the remote tip.
#   • CURRENT     an already-current base is a clean no-op (no error).
#   • DIVERGED    a base with a local commit → `pull --ff-only` REFUSES; the
#                  daemon surfaces it once and moves on (non-fatal, base intact).
#   • ONE-PER-REPO two fleets sharing one base checkout → the base moves ONCE
#                  (deduped on the resolved base path), the second fleet skips.
#   • SINGLE-WRITER a non-stale SHARED land lease held by someone else → skip
#                  (never fast-forward under a concurrent base-mover).
#   • DISK GATE   diskguard --gate closed → no-op for the whole tick.
#   • OFF SWITCH  FLEET_BASE_SYNC=0 → no-op (default is ON).
#   • DRY-RUN     --dry-run prints "would ff …" and moves NOTHING (no pull, no
#                  lease taken).
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + the base/remote tips).
# repo fake/repo → slug fake-repo → shared lease land-fake-repo.lock.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-base-sync.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not on PATH — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fbs-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/conf" "$WORK/leases"

# The daemon + libs run from $WORK/bin so BIN resolves the fake gate next to them.
cp "$SRC" "$WORK/bin/fleet-base-sync.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
cp "$BIN/fleet-land-lease.sh" "$WORK/bin/fleet-land-lease.sh"
chmod +x "$WORK/bin/fleet-base-sync.sh"

# --- fake fleet-diskguard.sh: gate open unless $WORK/disk_closed exists ----------
cat > "$WORK/bin/fleet-diskguard.sh" <<FAKE
#!/bin/bash
if [ "\${1:-}" = --gate ]; then [ -f "$WORK/disk_closed" ] && exit 1; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- git helpers (identity pinned so setup commits are deterministic + offline) --
REMOTE="$WORK/remote.git"; SEED="$WORK/seed"; MAIN="$WORK/main"
g() { git -c user.email=fleet@test.local -c user.name=Fleet \
          -c commit.gpgsign=false -c init.defaultBranch=master "$@"; }
commit_in() { printf '%s\n' "$2" > "$1/f"; g -C "$1" add f; g -C "$1" commit -q -m "$3"; }
main_tip()   { g -C "$MAIN" rev-parse HEAD 2>/dev/null; }
remote_tip() { g -C "$REMOTE" rev-parse master 2>/dev/null; }

# Build a fresh scenario: a bare remote @ A, a base checkout $MAIN, and the
# requested drift. Each test rebuilds so they are independent.
scene() { # $1 = behind | current | diverged
  rm -rf "$REMOTE" "$SEED" "$MAIN"
  g init -q --bare "$REMOTE"
  g clone -q "$REMOTE" "$SEED" 2>/dev/null
  commit_in "$SEED" a A
  g -C "$SEED" push -q -u origin master 2>/dev/null       # remote @ A
  g clone -q "$REMOTE" "$MAIN" 2>/dev/null                # base checkout @ A
  case "$1" in
    behind)   commit_in "$SEED" b B; g -C "$SEED" push -q origin master 2>/dev/null ;;  # remote @ B, base @ A
    current)  : ;;                                          # both @ A
    diverged) commit_in "$MAIN" c C                         # base @ C (local, off-remote)
              commit_in "$SEED" b B; g -C "$SEED" push -q origin master 2>/dev/null ;;  # remote @ B → diverged
  esac
}

run() { # extra args (session(s) / --dry-run) → runs the daemon, appends to $WORK/log
  TMPDIR="$WORK" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_LAND_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-base-sync.sh" "$@" >>"$WORK/log" 2>&1
}
reset() { : > "$WORK/log"; rm -rf "$WORK/leases"/* 2>/dev/null || true; }
conf() { # $1 = session name; remaining args = extra conf lines
  local s="$1"; shift
  { printf 'FLEET_REPO="fake/repo"\n'
    printf 'FLEET_MAIN="%s"\n' "$MAIN"
    printf 'FLEET_BASE_BRANCH="master"\n'
    printf '%s\n' "$@"
  } > "$WORK/conf/$s.conf"
}

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- base=%s remote=%s ---\n' "$(main_tip)" "$(remote_tip)" >&2; exit 1; }

# ================================ tests =========================================

# 1) BEHIND → fast-forward the base to the remote tip.
reset; scene behind; conf s1   # FLEET_BASE_SYNC unset → default ON
run s1
[ "$(main_tip)" = "$(remote_tip)" ] || fail "behind: base should fast-forward to the remote tip"
grep -q ': ff ' "$WORK/log" || fail "behind: should log the fast-forward move (': ff ')"
ls "$WORK/leases"/land-*.lock >/dev/null 2>&1 && fail "behind: the land lease must be released after the pull"

# 2) CURRENT → clean no-op (no move, no error).
reset; scene current; conf s1
before="$(main_tip)"
run s1
[ "$(main_tip)" = "$before" ] || fail "current: an up-to-date base must not move"
grep -q 'already current' "$WORK/log" || fail "current: should log 'already current'"

# 3) DIVERGED → --ff-only refuses, surfaced once, non-fatal, base intact.
reset; scene diverged; conf s1
before="$(main_tip)"
run s1 || fail "diverged: a refused fast-forward must be non-fatal (daemon exit 0)"
[ "$(main_tip)" = "$before" ] || fail "diverged: a diverged base must be left untouched"
grep -q 'would not fast-forward' "$WORK/log" || fail "diverged: should surface 'would not fast-forward'"
ls "$WORK/leases"/land-*.lock >/dev/null 2>&1 && fail "diverged: the land lease must be released even on refusal"

# 4) ONE-PER-REPO: two fleets sharing one base checkout → the base moves ONCE.
reset; scene behind; conf s1; conf s2
run s1 s2
[ "$(main_tip)" = "$(remote_tip)" ] || fail "two-fleets: the base should still reach the remote tip"
[ "$(grep -c ': ff ' "$WORK/log")" = 1 ] || fail "two-fleets: exactly ONE base-mover should fast-forward (got $(grep -c ': ff ' "$WORK/log"))"
grep -q 'already synced this tick' "$WORK/log" || fail "two-fleets: the second fleet should skip (deduped on base path)"

# 5) SINGLE-WRITER: a non-stale SHARED land lease held by someone else → skip.
reset; scene behind; conf s1
before="$(main_tip)"
mkdir -p "$WORK/leases/land-fake-repo.lock"
printf '99999\notherhost-zzz\n9999999999\nsomeone-else\n' > "$WORK/leases/land-fake-repo.lock/holder"
run s1
[ "$(main_tip)" = "$before" ] || fail "single-writer: a held land lease must block the fast-forward"
grep -q 'land lease busy' "$WORK/log" || fail "single-writer: should log the lease-busy skip"
rm -rf "$WORK/leases"/* 2>/dev/null || true

# 6) DISK GATE closed → whole tick is a no-op (checked before the per-fleet loop).
reset; scene behind; conf s1
before="$(main_tip)"
touch "$WORK/disk_closed"
run s1
rm -f "$WORK/disk_closed"
[ "$(main_tip)" = "$before" ] || fail "disk-gate: a closed gate must move nothing"
grep -q 'disk gate closed' "$WORK/log" || fail "disk-gate: should log 'disk gate closed'"

# 7) OFF SWITCH: FLEET_BASE_SYNC=0 → no-op.
reset; scene behind; conf s1 'FLEET_BASE_SYNC=0'
before="$(main_tip)"
run s1
[ "$(main_tip)" = "$before" ] || fail "off-switch: FLEET_BASE_SYNC=0 must move nothing"
grep -q 'base-sync off' "$WORK/log" || fail "off-switch: should log 'base-sync off'"

# 8) DRY-RUN: prints intent, moves NOTHING, takes no lease.
reset; scene behind; conf s1
before="$(main_tip)"
run --dry-run s1
[ "$(main_tip)" = "$before" ] || fail "dry-run: must not move the base"
grep -q 'would ff ' "$WORK/log" || fail "dry-run: should log 'would ff …'"
ls "$WORK/leases"/land-*.lock >/dev/null 2>&1 && fail "dry-run: must not take a lease"

printf 'selftest PASS: behind·current·diverged · one-per-repo · single-writer · disk-gate · off-switch · dry-run\n'
exit 0
