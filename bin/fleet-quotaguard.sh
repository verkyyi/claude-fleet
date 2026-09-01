#!/bin/bash
# fleet-quotaguard.sh — subscription-quota circuit-breaker for auto-spawn.
#
# WHY: the disk guard stops the fleet filling a volume. Nothing stops it filling
# a QUOTA. Autofill spawns real Claude sessions on a timer, and the sessions it
# spawns are exactly the ones that spend the subscription those sessions run on.
# A dispatcher that keeps filling slots while the weekly window closes does not
# merely waste tokens — it hands the remaining budget to whichever issue happened
# to be labelled `autofill`, and the operator finds out when their own session
# is refused.
#
# This is the same shape as fleet-diskguard.sh --gate, deliberately: a cheap
# precondition that fleet-dispatch.sh consults once per tick and REFUSES to add
# load through. Same exit codes, same fail-open rule, so the two guards can be
# reasoned about identically.
#
# It does NOT measure anything itself. The measurement lives in ccquota
# (https://github.com/verkyyi/ccquota), which reads Anthropic's own account-wide
# utilization; this script is the fleet's policy on top of that answer. Keeping
# the split means the fleet has no opinion about how quota is measured, and
# ccquota has no opinion about what a fleet should do.
#
# OFF UNLESS CONFIGURED. With no ccquota on PATH and no hub configured, every
# mode is a no-op that exits 0. A fleet that has never heard of ccquota behaves
# exactly as it did before this file existed — that is a requirement, not a
# nicety: most fleets will never run a hub.
#
# Modes:
#   --gate            exit 0 to proceed, 3 to refuse (prints one line to stderr)
#   --status          print the human-readable headroom report; exit 0
#   --json            print ccquota's full report as JSON; exit 0
#   --help
#
# Config (fleet.conf; all optional):
#   FLEET_QUOTA_GATE        1 to arm the gate (default 0 = OFF, report only)
#   FLEET_QUOTA_CEILING     hold at/above this utilization %   (default 90)
#   FLEET_QUOTA_ACCOUNT     subscription to judge, or `all`
#                           (default: the account this machine is logged into)
#   FLEET_QUOTA_BIN         path to ccquota                    (default: PATH)
#   CCQUOTA_HUB_URL         hub base URL       (usually already in the environment)
#   CCQUOTA_VIEWER_TOKEN    viewer token
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

ARMED="${FLEET_QUOTA_GATE:-0}"
CEILING="${FLEET_QUOTA_CEILING:-90}"
ACCOUNT="${FLEET_QUOTA_ACCOUNT:-}"
CCQUOTA="${FLEET_QUOTA_BIN:-ccquota}"

# ccquota exits 3 to mean "hold" — the same code this script re-exports, and the
# same one fleet-diskguard.sh uses for a closed gate.
HOLD=3

have_ccquota() { command -v "$CCQUOTA" >/dev/null 2>&1; }

# Build the argv shared by every mode. `--account` is omitted when unset so
# ccquota applies its own default: the subscription THIS MACHINE is logged into,
# which is the one a session spawned here will actually spend.
ccq_args() {
  printf '%s\n' budget --ceiling "$CEILING"
  [ -n "$ACCOUNT" ] && printf '%s\n' --account "$ACCOUNT"
  return 0
}

run_ccquota() {
  local args=()
  while IFS= read -r a; do args+=("$a"); done < <(ccq_args)
  "$CCQUOTA" "${args[@]}" "$@"
}

usage() { sed -n '2,40p' "$0"; }

case "${1:---gate}" in
  --gate)
    # Not armed, not installed, or no hub: say nothing and let the fleet run.
    # A guard nobody configured must never be the reason work stopped.
    [ "$ARMED" = 1 ] || exit 0
    have_ccquota || exit 0
    [ -n "${CCQUOTA_HUB_URL:-}" ] || exit 0

    # ccquota's own gate already fails OPEN on an unreachable hub or an
    # unreadable limit, and prints its reason to stderr. Exit 3 is the only
    # refusal; anything else — including a crash — proceeds, because a broken
    # guard must not be able to halt the fleet. That is the same rule
    # fleet-diskguard.sh states as "never block the fleet on a measurement bug".
    reason=$(run_ccquota --gate 2>&1 >/dev/null)
    rc=$?
    if [ "$rc" -eq "$HOLD" ]; then
      echo "fleet-quotaguard: QUOTA NEARLY SPENT — ${reason:-at or above the ${CEILING}% ceiling}; refusing to add fleet load" >&2
      exit "$HOLD"
    fi
    if [ "$rc" -ne 0 ]; then
      echo "fleet-quotaguard: ccquota failed (rc=$rc); proceeding — ${reason}" >&2
    fi
    exit 0
    ;;
  --status)
    have_ccquota || { echo "fleet-quotaguard: ccquota is not installed; quota gating is off"; exit 0; }
    [ -n "${CCQUOTA_HUB_URL:-}" ] || { echo "fleet-quotaguard: no CCQUOTA_HUB_URL; quota gating is off"; exit 0; }
    [ "$ARMED" = 1 ] || echo "fleet-quotaguard: reporting only (set FLEET_QUOTA_GATE=1 in fleet.conf to arm)"
    run_ccquota || true
    ;;
  --json)
    have_ccquota || { echo '{"verdict":"unknown","reason":"ccquota is not installed"}'; exit 0; }
    run_ccquota --json || echo '{"verdict":"unknown","reason":"ccquota failed"}'
    ;;
  --help|-h) usage ;;
  *) echo "fleet-quotaguard: unknown mode $1" >&2; usage >&2; exit 2 ;;
esac
