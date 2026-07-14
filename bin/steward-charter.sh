#!/bin/bash
# steward-charter.sh — the SHARED steward-charter resolver (issue #286).
#
# Concatenates a fleet's LAYERED steward charter, LOW→HIGH precedence (a later
# layer wins on conflict, so it reads top-to-bottom):
#   1. built-in tier  = the /fleet-steward skill's charter text itself
#      (commands/fleet-steward.md, the region between the <!-- fleet:charter-begin
#      --> and <!-- fleet:charter-end --> markers) — repo-versioned + sync-installed,
#      the base standing orders every steward runs on.
#   2. repo charter    $FLEET_MAIN/.fleet/steward.md — repo-specific behaviour,
#      GATED behind FLEET_REPO_CHARTER=1 (default OFF, fail-closed). It is an
#      INJECTION SURFACE: a steward is a high-value target and the PRs it reviews
#      auto-merge on green CI, so a PR that rewrote .fleet/steward.md could steer
#      every future steward. Skipped silently when the gate is off or the file is
#      absent/unreadable.
#   3. fleet overlay   $FLEET_CONF_DIR/fleets/<sess>/steward.md — operator-owned,
#      machine-local (~/.config, only the operator writes it), so it is always
#      trusted (no gate) and wins on conflict. Skipped silently when absent.
#
# This is the ONE code path for the steward charter: commands/fleet-steward.md
# runs it at spawn/respawn, and steward-readopt-hook.sh runs it after a bare
# /clear — so the skill and the hook can never drift (the parity the selftest
# asserts). It emits ONLY the charter (no wrapper/preamble): the readopt hook adds
# its own re-adopt framing around this output.
#
# Self-contained: given just the session name it sources fleet-lib and loads that
# fleet's conf itself (the skill runs it as a subprocess, where the shell env from
# a prior `fleet_load_conf` does NOT persist). fleet_load_conf no-ops on a missing
# conf, so a caller that pre-set FLEET_MAIN/FLEET_CONF_DIR/FLEET_REPO_CHARTER in the
# environment (the selftest) keeps them.
#
# Test seam: FLEET_STEWARD_SKILL overrides the built-in-tier source file (the
# selftest points it at a temp fixture). Always exits 0 — a missing layer is a
# silent skip, never an error; the worst case is an empty charter (the built-in
# default == today's behaviour when even the skill file is unreadable).
#
# Usage: steward-charter.sh <session>
set -u

SESS="${1:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"

# Resolve this fleet's conf (FLEET_MAIN / FLEET_CONF_DIR / FLEET_REPO_CHARTER).
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
[ -n "$SESS" ] && fleet_load_conf "$SESS"

# --- 1. built-in tier: the skill's charter region -----------------------------
# Emit everything BETWEEN the begin/end markers of the /fleet-steward skill — the
# skill's executable procedure (above the begin marker) is intentionally excluded
# so re-adopting the charter never re-suggests running this resolver.
skill="${FLEET_STEWARD_SKILL:-$BIN/../commands/fleet-steward.md}"
if [ -r "$skill" ]; then
  sed -n '/<!-- fleet:charter-begin -->/,/<!-- fleet:charter-end -->/p' "$skill" \
    | sed '1d;$d'
fi

# --- 2. repo charter tier (gated, lower precedence than the overlay) -----------
repo_md="${FLEET_MAIN:-}/.fleet/steward.md"
if [ "${FLEET_REPO_CHARTER:-0}" = 1 ] && [ -r "$repo_md" ]; then
  printf '\n===== repo steward charter · %s (lower precedence) =====\n' ".fleet/steward.md"
  cat "$repo_md"
  printf '\n'
fi

# --- 3. fleet overlay tier (operator, always trusted, wins on conflict) --------
overlay_md="$FLEET_CONF_DIR/fleets/$SESS/steward.md"
if [ -n "$SESS" ] && [ -r "$overlay_md" ]; then
  printf '\n===== fleet overlay steward charter · operator (wins on conflict) =====\n'
  cat "$overlay_md"
  printf '\n'
fi

# --- 4. machine-global tap-first steer (issue #328) ----------------------------
# The ONE shared block (fleet_tap_first_block in fleet-lib.sh) appended for BOTH
# seats — a machine-global operator directive, distinct from the per-session overlay
# above. Emits nothing unless FLEET_TAP_FIRST=1 (default OFF), so the default charter
# stays byte-identical; fleet_load_conf above has already sourced the flag from this
# fleet's conf layers.
fleet_tap_first_block

exit 0
