#!/bin/bash
# fleet-cleanup-selftest.sh — hermetic tests for the seat-agnostic, no-merge
# janitor bin/fleet-cleanup.sh (issue #277). Derived from fleet-land-selftest.sh
# with every merge case dropped (cleanup never merges) and the cleanup-specific
# cases added. No network, no real repo, no tmux server: fake gh/git/tmux on PATH,
# a temp base checkout, and FLEET_HISTORY_LEDGER pointed at a temp file.
#
# Covers:
#   MERGED           → cleaned:<sha>  (+ ledger row BEFORE teardown captured the
#                                       worktree path, teardown order window →
#                                       worktree → branch, base pull happened)
#   CLOSED-unmerged  → cleaned:closed (orphan reaped, NO ledger, NO base pull)
#   OPEN             → skip:not-final (nothing torn down, nothing recorded)
#   already-torn-down (MERGED, no worktree/window) → skip:nothing (idempotent,
#                                       no duplicate ledger row, no teardown)
#   self-cwd cleanup → teardown DETACHES into the tmux server (worker-safe)
#   --dry-run        → dry:*  (no teardown, no mutation)
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLEAN="$BIN/fleet-cleanup.sh"
[ -x "$CLEAN" ] || { echo "selftest: $CLEAN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-cleanup-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/leases" "$WORK/dash"
ORDER_LOG="$WORK/order"; PULL_LOG="$WORK/pull"; LEDGER="$WORK/ledger.tsv"

# --- fake git: no-op success; log teardown ops + the base pull in order --------
# worktree list prints a block so the issue-42 worktree resolves UNLESS WT_GONE=1
# (the already-torn-down scenario). worktree remove / branch -D / pull append to
# their logs so the test can assert ordering and whether the base was pulled.
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    case "\${2:-}" in
      list)   [ "\${WT_GONE:-0}" = 1 ] || printf 'worktree %s/wt-issue-42\nHEAD deadbeef\nbranch refs/heads/issue-42\n\n' "$WORK" ;;
      remove) printf 'worktree-remove\n' >> "$ORDER_LOG" ;;
      *)      : ;;
    esac ;;
  branch)  printf 'branch-D\n' >> "$ORDER_LOG" ;;    # git branch -D issue-42
  pull)    printf 'pull\n' >> "$PULL_LOG" ;;          # git pull --ff-only
  rev-parse) printf 'deadbeef\n' ;;
  *) : ;;                                             # fetch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: pr_fields TSV per scenario --------------------------------------
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
sub="\${1:-}"; action="\${2:-}"; num="\${3:-}"
[ "\$sub" = pr ] || exit 0
case "\$action" in
  view)
    case "\$*" in
      *"--json state,headRefOid"*)
        case "\${GH_SCENARIO:-merged}" in
          merged) printf 'MERGED\tsha-%s\tissue-42\n' "\$num" ;;
          closed) printf 'CLOSED\tsha-%s\tissue-42\n' "\$num" ;;
          open)   printf 'OPEN\tsha-%s\tissue-42\n' "\$num" ;;
        esac ;;
      *"--json title"*) printf 'Fake PR %s\t2026-01-01T00:00:00Z\tsha-%s\n' "\$num" "\$num" ;;
    esac ;;
esac
exit 0
GHFAKE

# --- fake tmux: window-id for display-message; log kill-window/run-shell -------
# FAKE_SELF_WIN is the window-id display-message reports as "ours" — @1 (≠ the
# worker window @7) drives the INLINE teardown; @7 forces the DETACHED self path.
# WIN_GONE=1 drops the worker window (already-torn-down scenario).
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ]; then shift 2; fi
case "\${1:-}" in
  list-windows)  [ "\${WIN_GONE:-0}" = 1 ] || echo '@7 42' ;;   # window @7 → issue 42
  display-message)
    case "\$*" in *window_id*) echo "\${FAKE_SELF_WIN:-@1}" ;; *session_name*) echo 'testsess' ;; *) echo '' ;; esac ;;
  kill-window)   printf 'kill-window %s\n' "\${!#}" >> "$ORDER_LOG" ;;
  run-shell)     printf 'run-shell\n' >> "$ORDER_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# run fleet-cleanup against the fakes. $1=scenario; remaining args pass through.
run_clean() {
  local scenario="$1"; shift
  : > "$ORDER_LOG"; : > "$PULL_LOG"
  GH_SCENARIO="$scenario" FAKE_SELF_WIN="${FAKE_SELF_WIN:-@1}" \
  WT_GONE="${WT_GONE:-0}" WIN_GONE="${WIN_GONE:-0}" \
  TMUX='' PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" \
  FLEET_CONF_DIR="$WORK/conf" FLEET_SESSION="testsess" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_HISTORY_LEDGER="$LEDGER" \
  LAND_LEASE_DIR="$WORK/leases" LAND_POLL=0 LAND_QUEUE_TIMEOUT=2 \
    "$CLEAN" --pr 42 "$@" 2>"$WORK/err"
}

# --- 1. MERGED → cleaned + ledger-before-teardown + ordered teardown + base pull
: > "$LEDGER"
tok="$(run_clean merged)"; err="$(cat "$WORK/err")"
case "$tok" in cleaned:*) ;; *) fail "1 expected cleaned:*, got '$tok'" "$err" ;; esac
# teardown ordering: kill-window BEFORE worktree-remove BEFORE branch-D
order="$(tr '\n' ' ' < "$ORDER_LOG")"
case "$order" in
  "kill-window @7 "*"worktree-remove "*"branch-D"*) ;;
  *) fail "1 teardown order wrong (want kill-window → worktree-remove → branch-D): [$order]" "$err" ;;
esac
# ledger row recorded BEFORE removal (it captured the still-live worktree path)
[ -s "$LEDGER" ] || fail "1 no history ledger row was written" "$err"
grep -q 'wt-issue-42' "$LEDGER" || fail "1 ledger row missing the worktree path (recorded after removal?)" "$err"
# base fast-forward happened
[ -s "$PULL_LOG" ] || fail "1 merged cleanup must fast-forward the base (git pull --ff-only)" "$err"
ok "1 MERGED → cleaned + ledger-before-teardown + ordered teardown + base pull"

# --- 2. CLOSED-unmerged → cleaned:closed, orphan reaped, NO ledger, NO base pull
: > "$LEDGER"
tok="$(run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "cleaned:closed" ] || fail "2 expected cleaned:closed, got '$tok'" "$err"
grep -q 'worktree-remove' "$ORDER_LOG" || fail "2 closed-unmerged must reap the orphan worktree" "$err"
[ -s "$PULL_LOG" ] && fail "2 closed-unmerged must NOT fast-forward the base (nothing merged)" "$err"
[ -s "$LEDGER" ]   && fail "2 closed-unmerged must NOT record a landed-session ledger row" "$err"
ok "2 CLOSED-unmerged → cleaned:closed, orphan reaped, no ledger, no base pull"

# --- 3. OPEN → skip:not-final, nothing torn down, nothing recorded ------------
: > "$LEDGER"
tok="$(run_clean open)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:not-final" ] || fail "3 expected skip:not-final, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "3 an OPEN (not-final) PR must not be torn down" "$err"
[ -s "$LEDGER" ]    && fail "3 an OPEN PR must not record a ledger row" "$err"
ok "3 OPEN → skip:not-final, no teardown, no ledger"

# --- 4. already-torn-down (MERGED, no worktree/window) → skip:nothing, idempotent
: > "$LEDGER"
tok="$(WT_GONE=1 WIN_GONE=1 run_clean merged)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:nothing" ] || fail "4 expected skip:nothing on an already-cleaned PR, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "4 already-cleaned PR must not tear anything down" "$err"
[ -s "$LEDGER" ]    && fail "4 already-cleaned PR must not append a duplicate ledger row" "$err"
ok "4 already-torn-down → skip:nothing (idempotent, no dup ledger, no teardown)"

# --- 5. self-cwd cleanup → teardown DETACHES into the tmux server (worker-safe) -
: > "$LEDGER"
tok="$(FAKE_SELF_WIN=@7 run_clean merged)"; err="$(cat "$WORK/err")"
case "$tok" in cleaned:*) ;; *) fail "5 expected cleaned:* on the self-cwd path, got '$tok'" "$err" ;; esac
grep -qx run-shell "$ORDER_LOG" || fail "5 self-cwd teardown must detach via tmux run-shell" "$err"
grep -q 'worktree-remove' "$ORDER_LOG" && fail "5 self-cwd teardown must NOT remove the worktree inline (it detaches)" "$err"
ok "5 self-cwd cleanup → teardown detaches into the tmux server"

# --- 6. --dry-run → dry:*, no teardown, no mutation ---------------------------
: > "$LEDGER"
tok="$(run_clean merged --dry-run)"; err="$(cat "$WORK/err")"
[ "$tok" = "dry:would-clean-merged" ] || fail "6 expected dry:would-clean-merged, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "6 --dry-run must not tear anything down" "$err"
[ -s "$LEDGER" ]    && fail "6 --dry-run must not record a ledger row" "$err"
ok "6 --dry-run classifies without mutating"

printf '\nselftest OK: %s assertions passed (no-merge janitor bin/fleet-cleanup.sh)\n' "$pass"
exit 0
