#!/bin/bash
# usage-modal-selftest.sh — hermetic wiring test for bin/usage-modal.sh (issue
# #289 usage/account modal). The pick sets the account pointer only: moving the
# fleet's idle sessions onto it (`migrate --idle`) and the collector's
# `migrate --limited` on a rotation are retired (T546) — a full subscription is
# the pool's to change. Pinned here:
#   • neither dispatch is back;
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
SCRIPT="$BIN/usage-modal.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

# shellcheck source=/dev/null
. "$SCRIPT"

CHECKS=0
fail() { printf 'usage-modal selftest FAIL: %s\n' "$1" >&2; exit 1; }

command -v render_usage_detail >/dev/null 2>&1 \
  || fail "render_usage_detail not defined after sourcing (the modal's header renderer)"

# --- the retired moves (T546): the pick no longer moves idle sessions, the
# collector no longer moves a benched account's sessions
CHECKS=$((CHECKS + 1))
grep -Eq "migrate --idle" "$SCRIPT" && fail "the account switch must not dispatch 'migrate --idle' any more (T546)"
CHECKS=$((CHECKS + 1))
grep -Eq "migrate --limited" "$BIN/tmux-dash-collect.sh" && fail "the collector must not dispatch 'migrate --limited' any more (T546)"

# (The retired restart subcommands and the in-place restart helpers — they typed into
# panes, #511, and could never move a session under the SessionEnd hook, #512 — and
# any send-keys in usage-modal.sh are conf/gone.list's, read by gone-selftest.sh.)

# --- fleet-account.sh exposes migrate + whoami (the modal's and collector's callee)
CHECKS=$((CHECKS + 1))
grep -Eq '^  migrate\)' "$BIN/fleet-account.sh" || fail "fleet-account.sh must dispatch 'migrate' to fleet-migrate.sh"
CHECKS=$((CHECKS + 1))
[ -x "$BIN/fleet-migrate.sh" ] || fail "bin/fleet-migrate.sh missing or not executable"

# --- the collector's once-per-reset-window quota markers compare with tolerance
# (fleet_same_window): ccquota's resets_at jitters by ~1s between polls, and an
# exact compare re-armed the 70% warning every tick (seven copies to one session).
CHECKS=$((CHECKS + 1))
# (The block moved out of the collector into bin/fleet-quotawatch.sh — its own
# 60s tick — in issue #551; the marker contract is unchanged.)
grep -q 'fleet_same_window "$mk" "$qreset" && continue' "$BIN/fleet-quotawatch.sh" \
  || fail "the quota watch's markers must go through fleet_same_window"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
_t=$(mktemp); printf '1788375599' > "$_t"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788375600 || fail "fleet_same_window: 1s jitter is the same window"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788393600 && fail "fleet_same_window: the next 5h window is a new episode"
printf 'junk' > "$_t"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t" 1788375600 && fail "fleet_same_window: a non-numeric marker is not a match"
CHECKS=$((CHECKS + 1)); fleet_same_window "$_t.missing" 1788375600 && fail "fleet_same_window: a missing marker is not a match"
rm -f "$_t"

printf 'usage-modal selftest: OK (%d checks)\n' "$CHECKS"
exit 0
