#!/bin/bash
# fleet-land-self-selftest.sh — hermetic tests for the worker-owned self-land
# (issue #138): the shared land lease (bin/fleet-land-lease.sh) and the self-land
# driver (bin/fleet-land-self.sh). No network, no real repo, no tmux server.
#
# Part 1 — LEASE PRIMITIVES (source the helper, real mkdir/sed/kill/date):
#   acquire-fresh · busy/queue (live holder) · steal-if-stale (TTL) ·
#   steal-if-dead-pid (same host) · land_lease_mine re-validate · release-iff-mine
# Part 2 — SELF-LAND DRIVER (fake gh/git/tmux on PATH):
#   own+green PR → merges + base-pull + self-destruct (ordering) · foreign PR
#   ejected without a merge · BEHIND→green drives update-branch then merges.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LEASE_LIB="$BIN/fleet-land-lease.sh"
SELF="$BIN/fleet-land-self.sh"
[ -f "$LEASE_LIB" ] || { echo "selftest: $LEASE_LIB missing" >&2; exit 2; }
[ -x "$SELF" ]      || { echo "selftest: $SELF missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-self-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# ============================ Part 1: lease ===================================
# shellcheck source=/dev/null
. "$LEASE_LIB"
HOST="$(land_lease_host)"
NOW="$(land_lease_now)"

# 1a. fresh acquire succeeds and records our pid/host.
L1="$WORK/leases/land-fresh.lock"
land_lease_acquire "$L1" 3600 || fail "1a fresh acquire should succeed"
[ "$(sed -n 1p "$L1/holder")" = "$$" ] || fail "1a holder pid != our pid"
land_lease_mine "$L1" || fail "1a land_lease_mine should be true right after acquire"
ok "1a acquire-fresh + mine"

# 1b. a LIVE foreign holder (pid 1 = init, always alive; unexpired) ⇒ busy/queue.
L2="$WORK/leases/land-busy.lock"; mkdir -p "$L2"
printf '1\n%s\n%s\nother\n' "$HOST" "$((NOW + 9999))" > "$L2/holder"
if land_lease_acquire "$L2" 3600; then fail "1b acquire should be BUSY (live unexpired holder)"; fi
land_lease_mine "$L2" && fail "1b lease is not ours — mine must be false"
ok "1b busy/queue on a live holder"

# 1c. LIVENESS BEATS TTL (the finding-[0] guard): a same-host holder whose pid is
# alive is NOT stolen even past the TTL — a lander legitimately holds through a
# green-wait that outlasts the TTL, and stealing it would race two landers on the
# base branch. pid 1 is alive on this host; expiry is in the past.
L3="$WORK/leases/land-ttl.lock"; mkdir -p "$L3"
printf '1\n%s\n%s\nother\n' "$HOST" "$((NOW - 100))" > "$L3/holder"
if land_lease_acquire "$L3" 3600; then fail "1c a LIVE same-host holder must NOT be stolen on TTL alone"; fi
land_lease_mine "$L3" && fail "1c lease is not ours — mine must be false"
ok "1c liveness beats TTL (live same-host holder not stolen when expired)"

# 1d. steal-if-dead-pid on THIS host: a very high pid is dead, unexpired ⇒ steal.
DEAD=999999; kill -0 "$DEAD" 2>/dev/null && DEAD=888888
L4="$WORK/leases/land-deadpid.lock"; mkdir -p "$L4"
printf '%s\n%s\n%s\nghost\n' "$DEAD" "$HOST" "$((NOW + 9999))" > "$L4/holder"
land_lease_acquire "$L4" 3600 || fail "1d dead-pid same-host lease should be stolen"
land_lease_mine "$L4" || fail "1d after dead-pid steal the lease should be ours"
ok "1d steal-if-dead-pid (same host)"

# 1e. a dead pid on ANOTHER host is NOT probed — an UNEXPIRED cross-host lease holds.
L5="$WORK/leases/land-otherhost.lock"; mkdir -p "$L5"
printf '%s\notherhost-xyz\n%s\nremote\n' "$DEAD" "$((NOW + 9999))" > "$L5/holder"
if land_lease_acquire "$L5" 3600; then fail "1e cross-host unexpired lease must NOT be stolen on pid-liveness"; fi
ok "1e cross-host lease not stolen while unexpired (TTL only)"

# 1f. an EXPIRED cross-host lease IS reclaimed by the TTL (we can't probe its pid).
L6="$WORK/leases/land-otherhost-exp.lock"; mkdir -p "$L6"
printf '%s\notherhost-xyz\n%s\nremote\n' "$DEAD" "$((NOW - 100))" > "$L6/holder"
land_lease_acquire "$L6" 3600 || fail "1f expired cross-host lease should be reclaimed by TTL"
land_lease_mine "$L6" || fail "1f after TTL steal the cross-host lease should be ours"
ok "1f steal-if-stale (TTL) for a cross-host holder"

# 1g. release only when it's ours; a foreign lease is left intact.
land_lease_release "$L1"; [ -d "$L1" ] && fail "1g release should remove OUR lease"
land_lease_release "$L2"; [ -d "$L2" ] || fail "1g release must NOT remove a foreign lease"
ok "1g release-iff-mine"

# ======================= Part 2: self-land driver =============================
mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
MERGE_LOG="$WORK/merges"; UB_LOG="$WORK/updatebranch"; : > "$MERGE_LOG"; : > "$UB_LOG"

# --- fake git: no-op success; report a fixed branch for rev-parse -------------
cat > "$WORK/fakebin/git" <<'GITFAKE'
#!/bin/bash
# strip a leading `-C <dir>`
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  rev-parse)
    # `git rev-parse --abbrev-ref HEAD` → the worker's branch
    case "$*" in *--abbrev-ref*) printf '%s\n' "${GIT_BRANCH:-issue-42}" ;; *) printf 'deadbeef\n' ;; esac ;;
  *) : ;;   # fetch / pull / worktree / branch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: pr_fields TSV per scenario; log merges + update-branch ----------
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
sub="\${1:-}"; action="\${2:-}"; num="\${3:-}"
[ "\$sub" = pr ] || exit 0
case "\$action" in
  view)
    case "\$*" in
      *"--json state,mergeable"*)
        href="\${GH_HEADREF:-issue-42}"
        case "\${GH_SCENARIO:-ready}" in
          ready)   printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\t%s\n' "\$num" "\$href" ;;
          foreign) printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\t%s\n' "\$num" "\$href" ;;
          behind)
            if [ -f "$UB_LOG" ] && [ -s "$UB_LOG" ]; then
              printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\t%s\n' "\$num" "\$href"
            else
              printf 'OPEN\tMERGEABLE\tBEHIND\t-\tpass\tsha-%s\t%s\n' "\$num" "\$href"
            fi ;;
        esac ;;
      *"--json number"*) printf '%s\n' "\${num:-42}" ;;
    esac ;;
  merge)         printf '%s\n' "\$num" >> "$MERGE_LOG" ;;
  update-branch) printf '%s\n' "\$num" >> "$UB_LOG" ;;
esac
exit 0
GHFAKE

# --- fake tmux: window-id for display-message; swallow the rest ---------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
case "${1:-}" in
  display-message)
    case "$*" in *window_id*) echo '@7' ;; *session_name*) echo 'testsess' ;; *) echo '' ;; esac ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

run_self() { # $1=scenario $2=headref  → prints token on stdout, progress captured
  GH_SCENARIO="$1" GH_HEADREF="$2" GIT_BRANCH="issue-42" \
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  LAND_SELF_LEASE_DIR="$WORK/leases2" LAND_SELF_POLL=0 LAND_SELF_MAX_HOLD=30 \
  LAND_SELF_QUEUE_TIMEOUT=5 LAND_SELF_DRY_DESTRUCT=1 \
    "$SELF" --pr "${3:-42}" 2>"$WORK/err"
}

# 2a. own + green → merges, prints landed:, self-destruct ordering is sane.
: > "$MERGE_LOG"; : > "$UB_LOG"
tok="$(run_self ready issue-42 42)"
err="$(cat "$WORK/err")"
case "$tok" in landed:*) ;; *) fail "2a expected landed:*, got '$tok'" "$err" ;; esac
grep -qx 42 "$MERGE_LOG" || fail "2a PR #42 was not merged" "$err"
# self-destruct: kill-window must precede worktree-remove which precedes branch -D
printf '%s\n' "$err" | grep -Eq 'kill-window .*worktree remove --force .*branch -D' \
  || fail "2a self-destruct command ordering wrong (kill-window → worktree remove → branch -D)" "$err"
# ...and the git steps are silenced so run-shell shows no overlay on the steward (issue #192)
printf '%s\n' "$err" | grep -Eq 'branch -D.*; \} >/dev/null 2>&1' \
  || fail "2a self-destruct must redirect the git steps to /dev/null (no run-shell overlay)" "$err"
ok "2a own+green → merged + base-pull + ordered, silenced self-destruct"

# 2b. foreign PR (head != our branch) → ejected, NEVER merged.
: > "$MERGE_LOG"; : > "$UB_LOG"
tok="$(run_self foreign issue-99 42)"; rc_err="$(cat "$WORK/err")"
[ "$tok" = "eject:not-own-pr" ] || fail "2b expected eject:not-own-pr, got '$tok'" "$rc_err"
[ -s "$MERGE_LOG" ] && fail "2b a foreign PR must NOT be merged" "$rc_err"
ok "2b foreign PR ejected without a merge"

# 2c. BEHIND → update-branch → green → merge.
: > "$MERGE_LOG"; : > "$UB_LOG"
tok="$(run_self behind issue-42 42)"; b_err="$(cat "$WORK/err")"
case "$tok" in landed:*) ;; *) fail "2c expected landed:* after update-branch, got '$tok'" "$b_err" ;; esac
grep -qx 42 "$UB_LOG"    || fail "2c update-branch was not called for the BEHIND PR" "$b_err"
grep -qx 42 "$MERGE_LOG" || fail "2c PR #42 was not merged after becoming green" "$b_err"
ok "2c BEHIND → update-branch → merged"

printf '\nselftest OK: %s assertions passed (lease primitives + self-land driver)\n' "$pass"
exit 0
