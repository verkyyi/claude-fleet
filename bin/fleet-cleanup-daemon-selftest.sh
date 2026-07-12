#!/bin/bash
# fleet-cleanup-daemon-selftest.sh — hermetic smoke test for the cleanup daemon
# bin/fleet-cleanup-daemon.sh (issue #277). Derived from the retired
# fleet-autoland-selftest.sh.
#
# Drives the daemon against a FAKE fleet-cleanup.sh + FAKE diskguard + FAKE
# gh/git/tmux (no network, no tmux server, no real teardown) and asserts its core
# contract:
#   • REAPS FINAL+LIVE  a MERGED/CLOSED PR whose issue-<N> still has a live
#                        worktree or window is handed to fleet-cleanup.sh.
#   • SKIPS OPEN         an OPEN (not-final) PR is never cleaned.
#   • SKIPS CLEAN        a MERGED PR with no leftover worktree/window is not a
#                        candidate (nothing to reap).
#   • RATE-LIMIT         at most FLEET_CLEANUP_MAX_PER_TICK reaps per tick.
#   • OFF SWITCH         FLEET_CLEANUP=0 → no-op (default is ON).
#   • SINGLE-WRITER      a fresh per-repo lease held by someone else → skip.
#   • DISK GATE          diskguard --gate closed → no-op for the whole tick.
#   • DRY-RUN            --dry-run mutates NOTHING (no reap, no lease taken).
#
# Detection is cache + local: a canned prmap the daemon reads through fleet_cache,
# plus a fake `git worktree list` / `tmux list-windows` reporting which issues are
# still live. repo fake/repo → slug fake-repo.
#   issue-10 #101 MERGED  → live worktree → CANDIDATE
#   issue-11 #102 CLOSED  → live window   → CANDIDATE
#   issue-12 #103 OPEN    → not final     → skip
#   issue-13 #104 MERGED  → no debris     → skip (already clean)
#   issue-14 #105 MERGED  → live worktree → CANDIDATE
#
# Exit 0 = pass. Non-zero = fail (prints the captured log + reap record).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-cleanup-daemon.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcd-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/leases" "$WORK/main/.git"
C="$WORK/.claude-dash"; mkdir -p "$C/fleets/fake-repo" "$C/global"
CLEAN_LOG="$WORK/reaps"; : > "$CLEAN_LOG"

# The daemon + lib run from $WORK/bin so BIN resolves the fake cleanup + gate
# scripts next to them (both are invoked as "$BIN/<name>").
cp "$SRC" "$WORK/bin/fleet-cleanup-daemon.sh"
cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-cleanup-daemon.sh"

# --- fake fleet-cleanup.sh: record the PR arg, emit a `cleaned:` token -----------
cat > "$WORK/bin/fleet-cleanup.sh" <<FAKE
#!/bin/bash
pr=''
while [ "\$#" -gt 0 ]; do case "\$1" in --pr) shift; pr="\${1:-}";; -*) : ;; *) pr="\$1";; esac; shift; done
printf '%s\n' "\$pr" >> "$CLEAN_LOG"
printf 'cleaned:fake%s\n' "\$pr"
exit 0
FAKE
chmod +x "$WORK/bin/fleet-cleanup.sh"

# --- fake fleet-diskguard.sh: gate open unless $WORK/disk_closed exists ----------
cat > "$WORK/bin/fleet-diskguard.sh" <<FAKE
#!/bin/bash
if [ "\${1:-}" = --gate ]; then [ -f "$WORK/disk_closed" ] && exit 1; exit 0; fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-diskguard.sh"

# --- fake gh: only needs to be on PATH (detection is cache + local) --------------
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$WORK/fakepath/gh"

# --- fake git: report live worktrees for issue-10 + issue-14 --------------------
cat > "$WORK/fakepath/git" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  worktree)
    [ "${2:-}" = list ] && { printf 'branch refs/heads/issue-10\nbranch refs/heads/issue-14\n'; }
    ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/git"

# --- fake tmux: report a live window for issue-11 -------------------------------
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ]; then shift 2; fi
case "${1:-}" in
  list-windows) echo '11' ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

# --- caches (what the collector + pr-refresh would have written) ----------------
printf 's1\tfake-repo\tfake/repo\n' > "$C/global/sessmap"
cat > "$C/fleets/fake-repo/prmap" <<'PRMAP'
issue-10	#101	MERGED	✓	ready
issue-11	#102	CLOSED	·	-
issue-12	#103	OPEN	✓	ready
issue-13	#104	MERGED	✓	ready
issue-14	#105	MERGED	·	-
PRMAP
: > "$C/fleets/fake-repo/prmap.ts"

run() { # extra args (session / --dry-run) → runs the daemon, appends to $WORK/log
  TMPDIR="$WORK" \
  PATH="$WORK/fakepath:$PATH" \
  FLEET_CONF_DIR="$WORK/conf" \
  FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
    bash "$WORK/bin/fleet-cleanup-daemon.sh" "$@" >>"$WORK/log" 2>&1
}
reset() { : > "$CLEAN_LOG"; : > "$WORK/log"; rm -rf "$WORK/leases"/* 2>/dev/null || true; }
conf() { { printf 'FLEET_REPO="fake/repo"\n'; printf 'FLEET_MAIN="%s"\n' "$WORK/main"; printf '%s\n' "$@"; } > "$WORK/conf/s1.conf"; }
reaped_list() { tr '\n' ' ' < "$CLEAN_LOG" | sed 's/ *$//'; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- log ---\n' >&2; cat "$WORK/log" 2>/dev/null >&2
         printf -- '--- reaps: [%s] ---\n' "$(reaped_list)" >&2; exit 1; }

# ================================ tests =========================================

# 1) REAPS FINAL+LIVE, SKIPS OPEN + CLEAN, default cap 4 → 101, 102, 105 in order.
reset
conf   # FLEET_CLEANUP unset → default ON
run s1
[ "$(reaped_list)" = "101 102 105" ] || fail "default should reap [101 102 105] (final+live), got [$(reaped_list)]"
grep -q 'cleaned:fake101' "$WORK/log" || fail "should log the cleaned token for #101"
for n in 103 104; do
  grep -qxF "$n" "$CLEAN_LOG" && fail "#$n must NOT be reaped (open / already-clean)"
done

# 2) RATE-LIMIT: cap 1 reaps only the first candidate (#101).
reset
conf 'FLEET_CLEANUP_MAX_PER_TICK=1'
run s1
[ "$(reaped_list)" = "101" ] || fail "cap 1 should reap only [101], got [$(reaped_list)]"

# 3) OFF SWITCH: FLEET_CLEANUP=0 → no-op.
reset
conf 'FLEET_CLEANUP=0'
run s1
[ -s "$CLEAN_LOG" ] && fail "FLEET_CLEANUP=0 must reap nothing"
grep -q 'cleanup off' "$WORK/log" || fail "FLEET_CLEANUP=0 should log 'cleanup off'"

# 4) DISK GATE closed → whole tick is a no-op (checked before the per-fleet loop).
reset
conf
touch "$WORK/disk_closed"
run s1
rm -f "$WORK/disk_closed"
[ -s "$CLEAN_LOG" ] && fail "a closed disk gate must reap nothing"
grep -q 'disk gate closed' "$WORK/log" || fail "a closed disk gate should log 'disk gate closed'"

# 5) DRY-RUN mutates nothing: no cleanup call, no lease left behind.
reset
conf
run --dry-run s1
[ -s "$CLEAN_LOG" ] && fail "--dry-run must not call the janitor"
ls "$WORK/leases"/cleanup-*.lock >/dev/null 2>&1 && fail "--dry-run must not take a lease"
grep -q 'would clean PR #101' "$WORK/log" || fail "--dry-run should log 'would clean PR #101'"

# 6) SINGLE-WRITER: a fresh (non-stale) per-repo lease held by someone else → skip.
reset
conf
mkdir -p "$WORK/leases/cleanup-fake-repo.lock"
printf 'someone-else\n9999999999\n' > "$WORK/leases/cleanup-fake-repo.lock/holder"
run s1
[ -s "$CLEAN_LOG" ] && fail "a held lease must block this tick (reap nothing)"
grep -q 'another cleaner holds the lease' "$WORK/log" || fail "should log the lease-held skip"
rm -rf "$WORK/leases"/* 2>/dev/null || true

printf 'selftest PASS: reaps final+live · skips open+clean · cap · off-switch · disk-gate · dry-run · single-writer\n'
exit 0
