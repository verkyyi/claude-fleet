#!/bin/bash
# usage-modal-selftest.sh — hermetic wiring test for bin/usage-modal.sh (issue
# #289 usage/account modal). It picks nothing since T550 (the pool picks the
# subscription): the account table is read-only. Moving the fleet's idle
# sessions (`migrate --idle`) and the collector's `migrate --limited` on a
# rotation are retired (T546) too. Pinned here:
#   • no pick (`fleet-account.sh use`) and neither dispatch is back;
#   • none of the retired in-place restart helpers linger (they typed into panes).
# The selection matrices themselves live in fleet-migrate-selftest.sh.
#
# Sourced (not run): usage-modal.sh guards its interactive body with
# `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing defines the helpers WITHOUT
# opening fzf or touching account state — hermetic, no tmux, no network.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SCRIPT="$BIN/usage-modal.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

# shellcheck source=/dev/null
. "$SCRIPT"

CHECKS=0

command -v render_usage_detail >/dev/null 2>&1 \
  || st_fail "render_usage_detail not defined after sourcing (the modal's header renderer)"

# --- the retired pick (T550) and moves (T546): the modal sets no account, the
# collector no longer moves a benched account's sessions
CHECKS=$((CHECKS + 1))
grep -Eq 'fleet-account\.sh" use|^[^#]*fzf ' "$SCRIPT" && st_fail "the modal must not pick an account any more (T550)"
CHECKS=$((CHECKS + 1))
grep -Eq "migrate --idle" "$SCRIPT" && st_fail "the account switch must not dispatch 'migrate --idle' any more (T546)"
CHECKS=$((CHECKS + 1))
grep -Eq "migrate --limited" "$BIN/tmux-dash-collect.sh" && st_fail "the collector must not dispatch 'migrate --limited' any more (T546)"

# (The retired restart subcommands and the in-place restart helpers — they typed into
# panes, #511, and could never move a session under the SessionEnd hook, #512 — and
# any send-keys in usage-modal.sh are conf/gone.list's, read by gone-selftest.sh.)

# --- fleet-account.sh exposes migrate + whoami (the modal's and collector's callee)
CHECKS=$((CHECKS + 1))
grep -Eq '^  migrate\)' "$BIN/fleet-account.sh" || st_fail "fleet-account.sh must dispatch 'migrate' to fleet-migrate.sh"
CHECKS=$((CHECKS + 1))
[ -x "$BIN/fleet-migrate.sh" ] || st_fail "bin/fleet-migrate.sh missing or not executable"

# --- once-per-reset-window markers compare with tolerance (fleet_same_window):
# ccquota's resets_at jitters by ~1s between polls, and an exact compare re-armed
# a once-per-window action every tick.
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
_t=$(mktemp); printf '1788375599' > "$_t"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788375600 || st_fail "fleet_same_window: 1s jitter is the same window"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788393600 && st_fail "fleet_same_window: the next 5h window is a new episode"
printf 'junk' > "$_t"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788375600 && st_fail "fleet_same_window: a non-numeric marker is not a match"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t.missing" 1788375600 && st_fail "fleet_same_window: a missing marker is not a match"
rm -f "$_t"

printf 'usage-modal selftest: OK (%d checks)\n' "$CHECKS"
exit 0
