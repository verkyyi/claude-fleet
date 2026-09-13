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
#   • SCRATCH HEADS OFF  (default) a MERGED PR whose head is NOT issue-<N> is
#                        never a candidate — the historic behavior (issue #589).
#   • SCRATCH HEADS ON   FLEET_CLEANUP_SCRATCH_HEADS=1 adds a MERGED non-issue
#                        head whose worktree's window says `done`, and STILL
#                        excludes: a window that is `working` (pre-screened
#                        locally, zero gh), a CLOSED non-issue head, a head with
#                        no worktree, and a worktree with no live window in it.
#   • SINGLE-WRITER      a fresh per-repo lease held by someone else → skip.
#   • CANDIDATE TIMEOUT  a candidate that WEDGES is killed at
#                        FLEET_CLEANUP_CANDIDATE_TIMEOUT (tree and all — the
#                        script AND its children), logged, and the tick carries
#                        on to the remaining candidates (issue #587).
#   • DISK GATE          diskguard --gate closed → no-op for the whole tick.
#   • TRASH SWEEP        the budgeted delete of worktrees teardown renamed aside
#                        (issue #586) runs once per tick and BEFORE the disk gate.
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
#   scratch-99 #106 MERGED  → worktree + window `done`     → CANDIDATE iff armed
#   scratch-98 #107 MERGED  → worktree + window `working`  → never (operator's own)
#   scratch-97 #108 CLOSED  → worktree + window `done`     → never (MERGED-only)
#   scratch-96 #109 MERGED  → no worktree                  → never (nothing live)
#   scratch-95 #110 MERGED  → worktree, NO window in it    → never (fails closed —
#                                             worktree-autoclean.sh owns that one)
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
# Wedge on demand (timeout test): park in a child, publish BOTH pids, never
# record a reap. Mirrors the real hang — the script blocked inside a child.
if grep -qxF "\$pr" "$WORK/hang" 2>/dev/null; then
  sleep 300 & sp=\$!
  printf '%s %s\n' "\$\$" "\$sp" > "$WORK/hangpids"
  wait "\$sp"
fi
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

# --- fake git: live worktrees for issue-10/14 + the three scratch heads ---------
# FULL porcelain blocks: the daemon's live set reads the `branch` lines, and
# fleet_worktree_head (the scratch pre-screen) needs the `worktree <dir>` line too.
cat > "$WORK/fakepath/git" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    [ "\${2:-}" = list ] && {
      for b in issue-10 issue-14 scratch-99 scratch-98 scratch-97 scratch-95; do
        printf 'worktree %s/wt/%s\nHEAD deadbeef\nbranch refs/heads/%s\n\n' "$WORK" "\$b" "\$b"
      done
    }
    ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/git"

# --- fake tmux: a live window for issue-11 + the scratch windows' cwd/state -----
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ]; then shift 2; fi
case "\${1:-}" in
  list-panes)    printf '@99 %s/wt/scratch-99\n@98 %s/wt/scratch-98\n@97 %s/wt/scratch-97\n' "$WORK" "$WORK" "$WORK" ;;
  list-windows)
    case "\$*" in
      *claude_state*) printf '@99 done\n@98 working\n@97 done\n' ;;
      *)              echo '11' ;;    # the @issue probe → issue-11 has a window
    esac ;;
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
scratch-99	#106	MERGED	✓	ready
scratch-98	#107	MERGED	✓	ready
scratch-97	#108	CLOSED	·	-
scratch-96	#109	MERGED	✓	ready
scratch-95	#110	MERGED	✓	ready
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

# 7) CANDIDATE TIMEOUT (issue #587): #101 wedges → killed at the budget, and the
#    tick still reaps #102 + #105. Without the budget the daemon blocks forever
#    here and launchd starts no further tick for ANY fleet.
reset
printf '101\n' > "$WORK/hang"; rm -f "$WORK/hangpids"
conf 'FLEET_CLEANUP_CANDIDATE_TIMEOUT=2'
t0=$(date +%s)
run s1
t1=$(date +%s)
rm -f "$WORK/hang"
[ "$(reaped_list)" = "102 105" ] || fail "a wedged #101 must not stop the tick: expected [102 105], got [$(reaped_list)]"
grep -q 'timeout after 2s' "$WORK/log" || fail "should log the per-candidate timeout for #101"
grep -q '1 timed out' "$WORK/log" || fail "the tick summary should count the timeout"
[ $((t1 - t0)) -lt 60 ] || fail "the tick took $((t1 - t0))s — the budget did not bound it"
# The kill is a TREE kill: the wedged script AND the child it was blocked in.
read -r hpid hchild < "$WORK/hangpids" 2>/dev/null || fail "the wedged fake never published its pids"
kill -0 "$hpid" 2>/dev/null   && fail "the timed-out cleanup script (pid $hpid) survived the budget"
kill -0 "$hchild" 2>/dev/null && fail "the timed-out cleanup's child (pid $hchild) survived the budget"

# 8) The timeout SPENDS A SLOT: cap 1 + a wedged #101 → nothing else is tried,
#    so one sick candidate can never stretch a tick to cap x budget + more.
reset
printf '101\n' > "$WORK/hang"
conf 'FLEET_CLEANUP_CANDIDATE_TIMEOUT=2' 'FLEET_CLEANUP_MAX_PER_TICK=1'
run s1
rm -f "$WORK/hang"
[ -s "$CLEAN_LOG" ] && fail "cap 1 spent on a timeout must reap nothing, got [$(reaped_list)]"
grep -q 'slot 1/1' "$WORK/log" || fail "a timed-out candidate should consume slot 1/1"

# 9) TRASH SWEEP: the budgeted delete of DROPPED worktrees runs once per tick and
#    BEFORE the disk gate — teardown no longer deletes a worktree inline, it renames
#    it into a sibling .fleet-trash/ (issue #586), and a closed gate means the volume
#    is full, which is exactly when those bytes most need releasing. Gating the sweep
#    on free disk is the one ordering that can deadlock.
reset
conf
mkdir -p "$WORK/.fleet-trash/main-issue-99.1700000000.4242"
echo bytes > "$WORK/.fleet-trash/main-issue-99.1700000000.4242/big"
touch "$WORK/disk_closed"
run s1
rm -f "$WORK/disk_closed"
[ -e "$WORK/.fleet-trash/main-issue-99.1700000000.4242" ] \
  && fail "the trash sweep must run even with the disk gate closed (it is what frees the disk)"
grep -q 'worktree trash swept:1 left:0' "$WORK/log" || fail "the sweep should log what it freed"
[ -s "$CLEAN_LOG" ] && fail "a closed disk gate must still reap nothing"

# 10) SCRATCH HEADS, DEFAULT OFF: a MERGED non-issue head is never a candidate.
reset
conf   # FLEET_CLEANUP_SCRATCH_HEADS unset → default OFF
run s1
[ "$(reaped_list)" = "101 102 105" ] || fail "the default must ignore non-issue heads, got [$(reaped_list)]"
for n in 106 107 108 109; do
  grep -qxF "$n" "$CLEAN_LOG" && fail "#$n (non-issue head) must NOT be a candidate by default"
done

# 11) SCRATCH HEADS ARMED: #106 joins (window `done`); 107/108/109 still excluded.
reset
conf 'FLEET_CLEANUP_SCRATCH_HEADS=1' 'FLEET_CLEANUP_MAX_PER_TICK=10'
run s1
[ "$(reaped_list)" = "101 102 105 106" ] || fail "armed should reap [101 102 105 106], got [$(reaped_list)]"
grep -qxF 107 "$CLEAN_LOG" && fail "#107 must be pre-screened out — its window is 'working'"
grep -q "not done" "$WORK/log" || fail "the 'working' pre-screen should log why #107 was left alone"
grep -qxF 108 "$CLEAN_LOG" && fail "#108 must be excluded — a CLOSED non-issue head is never in scope"
grep -qxF 109 "$CLEAN_LOG" && fail "#109 must be excluded — its head has no worktree"
grep -qxF 110 "$CLEAN_LOG" && fail "#110 must be excluded — no live window sits in its worktree (fail closed)"

printf 'selftest PASS: reaps final+live · skips open+clean · cap · off-switch · disk-gate · dry-run · single-writer · candidate-timeout · trash-sweep · scratch-heads off/armed\n'
exit 0
