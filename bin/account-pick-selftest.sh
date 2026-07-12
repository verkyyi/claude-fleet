#!/bin/bash
# account-pick-selftest.sh — hermetic unit test for the pure window-SELECTION
# predicate in bin/account-pick.sh (issue #263). When `prefix A` switches the
# active subscription account it now also restarts this fleet's IDLE Claude
# windows so running sessions move onto the new account. WHICH windows get
# restarted is the one decision worth pinning: restart the wrong window and you
# interrupt a mid-turn worker or resume the wrong transcript; miss the right one
# and the session silently stays on the walled account.
#
# _ap_restart_eligible <name> <state> <raw> returns 0 iff a window is an idle,
# issue-bound Claude worker safe to restart in place:
#   • hub/backlog panels (dash/plan/backlog) are skipped by name — this also
#     leaves the steward alone (it lives in the `plan` hub);
#   • @raw scratch sessions are skipped (shared FLEET_MAIN cwd → `--continue`
#     can't resolve their transcript, issue #214);
#   • non-Claude windows (no @claude_state) are skipped;
#   • only the idle states done/needs restart — working (mid-turn) and looping
#     (between /loop iterations) are left on their current account.
#
# Sourced (not run): account-pick.sh guards its interactive body with
# `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing defines the helpers WITHOUT
# opening fzf or touching account state — hermetic, no tmux, no network.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/account-pick.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

# shellcheck source=/dev/null
. "$SCRIPT"

command -v _ap_restart_eligible >/dev/null 2>&1 \
  || { printf 'selftest: _ap_restart_eligible not defined after sourcing\n' >&2; exit 1; }

CHECKS=0
fail() { printf 'account-pick selftest FAIL: %s\n' "$1" >&2; exit 1; }

# elig <desc> <name> <state> <raw> — assert the window IS eligible (rc 0).
elig() {
  CHECKS=$((CHECKS + 1))
  if ! _ap_restart_eligible "$2" "$3" "$4"; then
    fail "$1 — expected eligible (name=$2 state=$3 raw=$4), got skipped"
  fi
}
# skip <desc> <name> <state> <raw> — assert the window is SKIPPED (rc non-zero).
skip() {
  CHECKS=$((CHECKS + 1))
  if _ap_restart_eligible "$2" "$3" "$4"; then
    fail "$1 — expected skipped (name=$2 state=$3 raw=$4), got eligible"
  fi
}

# --- Eligible: idle, issue-bound worker windows (any non-panel name) ---
elig "done worker"            issue-263 "done"  ""
elig "needs worker"           issue-9   "needs" ""
elig "scratch-named but state-bound worker" fix-thing "done" ""

# --- Skipped by state: not idle ---
skip "working is mid-turn"    issue-263 "working" ""
skip "looping is /loop"       issue-263 "looping" ""
skip "empty state (non-Claude window)" issue-263 "" ""
skip "unknown state"          issue-263 "zombie"  ""

# --- Skipped by panel name (the hub/backlog; steward lives in `plan`) ---
skip "dash panel"             dash    "done"  ""
skip "plan hub (steward)"     plan    "done"  ""
skip "backlog panel"          backlog "needs" ""

# --- Skipped: @raw scratch session (shared cwd, unresolvable transcript) ---
skip "raw scratch, done"      scratch   "done"  1
skip "raw scratch, needs"     scratch-2 "needs" 1
# raw flag empty/absent means NOT raw → a normal idle worker stays eligible.
elig "raw flag empty = normal worker" issue-1 "done" ""

# --- A panel that is somehow @raw is still skipped (name wins first) ---
skip "raw + panel name"       plan "done" 1

printf 'account-pick selftest: OK (%d checks)\n' "$CHECKS"
exit 0
