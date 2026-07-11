#!/bin/bash
# fleet-land-selftest.sh — hermetic tests for the seat-agnostic lander
# bin/fleet-land.sh (issue #231). No network, no real repo, no tmux server: fake
# gh/git/tmux on PATH, a temp base checkout, and FLEET_HISTORY_LEDGER pointed at a
# temp file so the ledger write stays hermetic.
#
# Covers the spec's verification list:
#   READY            → landed:<sha>  (+ merge happened, ledger row BEFORE removal,
#                                      teardown order: window → worktree → branch)
#   BEHIND           → update-branch, then land
#   CONFLICT/FAILING/DRAFT/GONE → eject:*  (never merged)
#   MERGED (already) → landed:already, base-pull + teardown, no new merge
#   moved head       → gh merge refuses (--match-head-commit) → eject:merge-failed
#   lease contention → a live foreign holder + short queue timeout → eject:lease-*
#   self-cwd land    → teardown DETACHES into the tmux server (worker-safe)
#   --dry-run        → dry:*  (no merge, no mutation)
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LAND="$BIN/fleet-land.sh"
[ -x "$LAND" ] || { echo "selftest: $LAND missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-land-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/leases" "$WORK/dash"
MERGE_LOG="$WORK/merges"; UB_LOG="$WORK/updatebranch"; ORDER_LOG="$WORK/order"
LEDGER="$WORK/ledger.tsv"

# --- fake git: no-op success; log teardown ops in order -----------------------
# worktree list prints a block so the issue-42 worktree resolves; worktree remove
# and branch -D append to ORDER_LOG so the test can assert the teardown ordering.
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    case "\${2:-}" in
      list)   printf 'worktree %s/wt-issue-42\nHEAD deadbeef\nbranch refs/heads/issue-42\n\n' "$WORK" ;;
      remove) printf 'worktree-remove\n' >> "$ORDER_LOG" ;;
      *)      : ;;
    esac ;;
  branch) printf 'branch-D\n' >> "$ORDER_LOG" ;;     # git branch -D issue-42
  rev-parse) printf 'deadbeef\n' ;;
  *) : ;;                                             # fetch / pull → succeed silently
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
        case "\${GH_SCENARIO:-ready}" in
          ready)    printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\tissue-42\n' "\$num" ;;
          conflict) printf 'OPEN\tCONFLICTING\tDIRTY\t-\tpass\tsha-%s\tissue-42\n' "\$num" ;;
          failing)  printf 'OPEN\tMERGEABLE\tBLOCKED\t-\tfail\tsha-%s\tissue-42\n' "\$num" ;;
          draft)    printf 'OPEN\tMERGEABLE\tCLEAN\tDRAFT\tpass\tsha-%s\tissue-42\n' "\$num" ;;
          gone)     printf 'CLOSED\tUNKNOWN\tUNKNOWN\t-\tnone\tsha-%s\tissue-42\n' "\$num" ;;
          merged)   printf 'MERGED\tUNKNOWN\tUNKNOWN\t-\tpass\tsha-%s\tissue-42\n' "\$num" ;;
          behind)
            if [ -s "$UB_LOG" ]; then
              printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\tissue-42\n' "\$num"
            else
              printf 'OPEN\tMERGEABLE\tBEHIND\t-\tpass\tsha-%s\tissue-42\n' "\$num"
            fi ;;
        esac ;;
      *"--json title"*) printf 'Fake PR %s\t2026-01-01T00:00:00Z\tsha-%s\n' "\$num" "\$num" ;;
    esac ;;
  merge)         [ "\${GH_MERGE_FAIL:-0}" = 1 ] && exit 1; printf '%s\n' "\$num" >> "$MERGE_LOG" ;;
  update-branch) printf '%s\n' "\$num" >> "$UB_LOG" ;;
esac
exit 0
GHFAKE

# --- fake tmux: strip a leading -L; window-id for display-message; log ops -----
# FAKE_SELF_WIN is the window-id display-message reports as "ours" — @1 (≠ the
# worker window @7) drives the INLINE teardown; set it to @7 to force the DETACHED
# self-cwd path.
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ]; then shift 2; fi
case "\${1:-}" in
  list-windows)  echo '@7 42' ;;                     # window @7 is bound to issue 42
  display-message)
    case "\$*" in *window_id*) echo "\${FAKE_SELF_WIN:-@1}" ;; *session_name*) echo 'testsess' ;; *) echo '' ;; esac ;;
  kill-window)   printf 'kill-window %s\n' "\${!#}" >> "$ORDER_LOG" ;;   # last arg = the window id
  run-shell)     printf 'run-shell\n' >> "$ORDER_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# run fleet-land against the fakes. $1=scenario; remaining args pass through to
# fleet-land. GH_MERGE_FAIL / QT / FAKE_SELF_WIN are read from the caller's env.
run_land() {
  local scenario="$1"; shift
  : > "$ORDER_LOG"
  GH_SCENARIO="$scenario" GH_MERGE_FAIL="${GH_MERGE_FAIL:-0}" FAKE_SELF_WIN="${FAKE_SELF_WIN:-@1}" \
  TMUX='' PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" \
  FLEET_CONF_DIR="$WORK/conf" FLEET_SESSION="testsess" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_HISTORY_LEDGER="$LEDGER" \
  LAND_LEASE_DIR="$WORK/leases" LAND_POLL=0 LAND_MAX_HOLD=30 \
  LAND_QUEUE_TIMEOUT="${QT:-5}" \
    "$LAND" --pr 42 "$@" 2>"$WORK/err"
}

# --- 1. READY → merged + ledger + ordered teardown ----------------------------
: > "$MERGE_LOG"; : > "$UB_LOG"; : > "$LEDGER"
tok="$(run_land ready)"; err="$(cat "$WORK/err")"
case "$tok" in landed:*) ;; *) fail "1 expected landed:*, got '$tok'" "$err" ;; esac
grep -qx 42 "$MERGE_LOG" || fail "1 PR #42 was not merged" "$err"
# teardown ordering: kill-window BEFORE worktree-remove BEFORE branch-D
order="$(tr '\n' ' ' < "$ORDER_LOG")"
case "$order" in
  "kill-window @7 "*"worktree-remove "*"branch-D"*) ;;
  *) fail "1 teardown order wrong (want kill-window → worktree-remove → branch-D): [$order]" "$err" ;;
esac
# ledger row recorded (before removal) and it captured the worktree path
[ -s "$LEDGER" ] || fail "1 no history ledger row was written" "$err"
grep -q 'wt-issue-42' "$LEDGER" || fail "1 ledger row missing the worktree path (recorded after removal?)" "$err"
ok "1 READY → merged + ledger-before-removal + ordered teardown"

# --- 2. BEHIND → update-branch → green → merge --------------------------------
: > "$MERGE_LOG"; : > "$UB_LOG"; : > "$LEDGER"
tok="$(run_land behind)"; err="$(cat "$WORK/err")"
case "$tok" in landed:*) ;; *) fail "2 expected landed:* after update-branch, got '$tok'" "$err" ;; esac
grep -qx 42 "$UB_LOG"    || fail "2 update-branch was not called for the BEHIND PR" "$err"
grep -qx 42 "$MERGE_LOG" || fail "2 PR #42 was not merged after becoming green" "$err"
ok "2 BEHIND → update-branch → merged"

# --- 3. CONFLICT / FAILING / DRAFT / GONE → eject:* (never merged) ------------
: > "$MERGE_LOG"
tok="$(run_land conflict)"; err="$(cat "$WORK/err")"
[ "$tok" = "eject:conflict-needs-rebase" ] || fail "3a expected eject:conflict-needs-rebase, got '$tok'" "$err"
tok="$(run_land failing)";  err="$(cat "$WORK/err")"
[ "$tok" = "eject:required-check-failed" ] || fail "3b expected eject:required-check-failed, got '$tok'" "$err"
tok="$(run_land draft)";    err="$(cat "$WORK/err")"
[ "$tok" = "eject:draft" ] || fail "3c expected eject:draft, got '$tok'" "$err"
tok="$(run_land gone)";     err="$(cat "$WORK/err")"
[ "$tok" = "eject:closed-unmerged" ] || fail "3d expected eject:closed-unmerged, got '$tok'" "$err"
[ -s "$MERGE_LOG" ] && fail "3 an unlandable PR must NEVER be merged" "$(cat "$WORK/err")"
ok "3 CONFLICT/FAILING/DRAFT/GONE ejected without a merge"

# --- 4. already MERGED → landed:already, base pulled + teardown, no new merge --
: > "$MERGE_LOG"; : > "$LEDGER"
tok="$(run_land merged)"; err="$(cat "$WORK/err")"
[ "$tok" = "landed:already" ] || fail "4 expected landed:already, got '$tok'" "$err"
[ -s "$MERGE_LOG" ] && fail "4 an already-merged PR must not be re-merged" "$err"
grep -q 'wt-issue-42' "$LEDGER" || fail "4 already-merged path must still record the ledger" "$err"
ok "4 already-merged → landed:already, base-pull + ledger, no re-merge"

# --- 5. moved head → gh merge refuses (--match-head-commit) → eject:merge-failed
: > "$MERGE_LOG"
tok="$(GH_MERGE_FAIL=1 run_land ready)"; err="$(cat "$WORK/err")"
[ "$tok" = "eject:merge-failed" ] || fail "5 expected eject:merge-failed on a refused merge, got '$tok'" "$err"
[ -s "$MERGE_LOG" ] && fail "5 a refused (moved-head) merge must not be logged as merged" "$err"
ok "5 moved head (--match-head-commit refuses) → eject:merge-failed"

# --- 6. lease contention: a live foreign holder + short timeout → eject -------
# Seed the shared land lease with a LIVE, unexpired foreign holder (pid 1 = init),
# at the EXACT path fleet-land derives, so the second lander must queue + give up.
SLUG="$(cd "$BIN" && . ./fleet-lib.sh && fleet_slug "$(fleet_norm_repo acme/widgets)")"
LEASE="$WORK/leases/land-$SLUG.lock"
mkdir -p "$LEASE"
printf '1\n%s\n%s\nother-lander\n' "$(hostname -s 2>/dev/null || hostname)" "$(( $(date +%s) + 9999 ))" > "$LEASE/holder"
: > "$MERGE_LOG"
tok="$(QT=0 run_land ready)"; err="$(cat "$WORK/err")"
[ "$tok" = "eject:lease-wait-timeout" ] || fail "6 expected eject:lease-wait-timeout while a foreign lander holds the lease, got '$tok'" "$err"
[ -s "$MERGE_LOG" ] && fail "6 must NOT merge while another lander holds the lease (single-writer)" "$err"
rm -rf "$LEASE"
ok "6 lease contention → second lander ejects (single-writer), no merge"

# --- 7. self-cwd land → teardown DETACHES into the tmux server (worker-safe) ---
# When the caller's own window IS the worker window, an inline kill-window would
# saw off the branch it sits on — so teardown must detach via `tmux run-shell -b`.
: > "$MERGE_LOG"; : > "$LEDGER"
tok="$(FAKE_SELF_WIN=@7 run_land ready)"; err="$(cat "$WORK/err")"
case "$tok" in landed:*) ;; *) fail "7 expected landed:* on the self-cwd path, got '$tok'" "$err" ;; esac
grep -qx run-shell "$ORDER_LOG" || fail "7 self-cwd teardown must detach via tmux run-shell" "$err"
grep -q 'worktree-remove' "$ORDER_LOG" && fail "7 self-cwd teardown must NOT remove the worktree inline (it detaches)" "$err"
ok "7 self-cwd land → teardown detaches into the tmux server"

# --- 8. --dry-run → dry:*, no merge, no mutation ------------------------------
: > "$MERGE_LOG"; : > "$UB_LOG"; : > "$ORDER_LOG"
tok="$(run_land ready --dry-run)"; err="$(cat "$WORK/err")"
[ "$tok" = "dry:would-merge" ] || fail "8 expected dry:would-merge, got '$tok'" "$err"
[ -s "$MERGE_LOG" ] && fail "8 --dry-run must not merge" "$err"
[ -s "$ORDER_LOG" ] && fail "8 --dry-run must not tear anything down" "$err"
ok "8 --dry-run classifies without mutating"

printf '\nselftest OK: %s assertions passed (seat-agnostic lander bin/fleet-land.sh)\n' "$pass"
exit 0
