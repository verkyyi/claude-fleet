#!/bin/bash
# fleet-account-selftest.sh — hermetic unit tests for the pure ROTATION MATH in
# bin/fleet-account.sh (the multi-account usage-limit failover). Correctness here
# decides whether the fleet fails over to a fresh subscription cleanly or thrashes
# straight back into a limited one, so the branching logic is worth pinning.
#
# Covered (all pure / deterministic — real `date` only, no network, no real tokens):
#   • dur_secs   — s/m/h/d suffixes, bare seconds, and garbage → empty.
#   • human_dur  — seconds → the coarsest d/h/m unit.
#   • acct_ttl   — per-account <label>.conf LIMIT_TTL override vs the global
#                  default, with fallback when the override is absent/invalid/0.
#   • acct_limited_until / acct_eligible — read known epochs from a temp
#                  account.limited (future = benched, past/absent = eligible;
#                  duplicate rows → the furthest-future epoch wins).
#   • pick_active — keep-current-if-eligible, rotate-past-limited round-robin
#                  (incl. wraparound), and the all-limited best-effort fallback.
#
# Sourced (not run): fleet-account.sh guards its bottom dispatch with
# `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing defines the helpers WITHOUT
# running any command — no rotation, no state writes, hermetic even if a
# repo-root fleet.conf points FLEET_ACCOUNTS_DIR at real accounts. The state
# globals are then repointed at a scratch tree. (The empty temp
# FLEET_ACCOUNTS_DIR below is belt-and-suspenders on top of that guard.)
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/fleet-account.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-account-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# Empty accounts dir at source time → OFF → the bottom dispatch is a no-op that
# can't read/rotate the caller's real accounts.
export FLEET_ACCOUNTS_DIR="$WORK/accounts"
mkdir -p "$FLEET_ACCOUNTS_DIR"

# shellcheck source=/dev/null
. "$SCRIPT"

# Repoint every piece of state fleet-account resolved at source time onto the
# scratch tree (the functions read these globals at CALL time, so this takes).
ACCT_DIR="$WORK/accounts"
# shellcheck disable=SC2034  # read by the sourced acct_ttl() as its global default
TTL=18000
FLEET_C="$WORK/cache"; mkdir -p "$FLEET_C"
STATE_LIMITED="$FLEET_C/account.limited"   # only the limited-state file is read by the tested fns

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}
rc_is() {  # <desc> <expected-rc> <actual-rc>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected rc $2, got rc $3"
}

# ============================================================================
# dur_secs — <N>[smhd] | bare seconds | garbage→empty
# ============================================================================
eq "dur_secs 30s" 30      "$(dur_secs 30s)"
eq "dur_secs 5m"  300     "$(dur_secs 5m)"
eq "dur_secs 2h"  7200    "$(dur_secs 2h)"
eq "dur_secs 1d"  86400   "$(dur_secs 1d)"
eq "dur_secs bare 45" 45  "$(dur_secs 45)"
eq "dur_secs 0s"  0       "$(dur_secs 0s)"
eq "dur_secs empty"  ""   "$(dur_secs '')"
eq "dur_secs garbage abc" "" "$(dur_secs abc)"
eq "dur_secs bad suffix 10x" "" "$(dur_secs 10x)"
eq "dur_secs lone suffix m"  "" "$(dur_secs m)"

# ============================================================================
# human_dur — seconds → coarsest d/h/m
# ============================================================================
eq "human_dur 90000 → 1d" 1d "$(human_dur 90000)"
eq "human_dur 86400 → 1d" 1d "$(human_dur 86400)"
eq "human_dur 7200 → 2h"  2h "$(human_dur 7200)"
eq "human_dur 3600 → 1h"  1h "$(human_dur 3600)"
eq "human_dur 120 → 2m"   2m "$(human_dur 120)"

# ============================================================================
# acct_ttl — per-account LIMIT_TTL override vs global default
# ============================================================================
eq "acct_ttl: no conf → global default" 18000 "$(acct_ttl noconf)"

printf 'LIMIT_TTL=7d\n' > "$ACCT_DIR/weekly.conf"
eq "acct_ttl: LIMIT_TTL=7d override" 604800 "$(acct_ttl weekly)"

printf 'LIMIT_TTL = 90m \n' > "$ACCT_DIR/spaced.conf"   # whitespace tolerated
eq "acct_ttl: whitespace-tolerant override" 5400 "$(acct_ttl spaced)"

printf 'LIMIT_TTL=garbage\n' > "$ACCT_DIR/bad.conf"
eq "acct_ttl: invalid override → global fallback" 18000 "$(acct_ttl bad)"

printf 'LIMIT_TTL=0s\n' > "$ACCT_DIR/zero.conf"          # 0 is not >0 → fallback
eq "acct_ttl: zero override → global fallback" 18000 "$(acct_ttl zero)"

# ============================================================================
# acct_limited_until / acct_eligible — epochs in a temp account.limited
# ============================================================================
NOW=$(now)
FUT=$((NOW + 10000)); PAST=$((NOW - 10000)); FUT2=$((NOW + 20000))

# No state file → not limited, eligible.
eq "limited_until: no state file" 0 "$(acct_limited_until acctA)"
acct_eligible acctA; rc_is "eligible: no state file" 0 $?

{ printf 'acctA\t%s\tbenched\n' "$FUT"
  printf 'acctB\t%s\texpired\n' "$PAST"
  printf 'acctA\t%s\tbenched-longer\n' "$FUT2"   # dup row → furthest-future wins
} > "$STATE_LIMITED"

eq "limited_until: future row picks furthest epoch" "$FUT2" "$(acct_limited_until acctA)"
eq "limited_until: expired row → 0" 0 "$(acct_limited_until acctB)"
eq "limited_until: unknown label → 0" 0 "$(acct_limited_until acctZ)"

acct_eligible acctA; rc_is "eligible: benched acct is NOT eligible" 1 $?
acct_eligible acctB; rc_is "eligible: expired acct IS eligible" 0 $?
acct_eligible acctZ; rc_is "eligible: unknown acct IS eligible" 0 $?

# ============================================================================
# pick_active — keep / rotate round-robin / all-limited fallback
# ============================================================================
# Three real token files; pin their order with FLEET_ACCOUNTS so the round-robin
# is deterministic regardless of readdir/sort locale.
: > "$ACCT_DIR/a"; : > "$ACCT_DIR/b"; : > "$ACCT_DIR/c"
export FLEET_ACCOUNTS="a b c"

limit() { printf '%s\t%s\ttest\n' "$1" "$((NOW + 10000))" >> "$STATE_LIMITED"; }
clear_limits() { : > "$STATE_LIMITED"; }

# 1. current is eligible → keep it (no rotation).
clear_limits
eq "pick_active: keep eligible current" b "$(pick_active b)"

# 2. current limited, next eligible → rotate to the next round-robin.
clear_limits; limit a
eq "pick_active: rotate past limited current → next" b "$(pick_active a)"

# 3. current + next both limited → skip to the first eligible after them.
clear_limits; limit a; limit b
eq "pick_active: skip two limited → c" c "$(pick_active a)"

# 4. wraparound: current is the LAST and limited → wrap to the first eligible.
clear_limits; limit c
eq "pick_active: wraparound from last → a" a "$(pick_active c)"

# 5. current not in the pool (start<0), all eligible → first eligible.
clear_limits
eq "pick_active: unknown current → first eligible" a "$(pick_active zzz)"

# 6. empty current, all eligible → first in order.
clear_limits
eq "pick_active: empty current → first" a "$(pick_active '')"

# 7. ALL limited, current present → best-effort keep current (sessions still launch).
clear_limits; limit a; limit b; limit c
eq "pick_active: all limited, keep current" b "$(pick_active b)"

# 8. ALL limited, current NOT in pool → fall back to the first label.
eq "pick_active: all limited, unknown current → L[0]" a "$(pick_active zzz)"

printf 'selftest OK: fleet-account rotation math (%s assertions — dur/human, acct_ttl, limited/eligible, pick_active)\n' "$CHECKS"
