#!/bin/bash
# usage-modal-selftest.sh — hermetic wiring test for bin/usage-modal.sh (issue
# #289 usage/account modal). The modal's one side effect beyond the account
# pointer is "move this fleet's idle sessions onto the account I just picked";
# since issue #512 that is bin/fleet-migrate.sh's job (close + `--resume` in a new
# window — the in-place `--continue` restart of #263/#495 could not work under
# the SessionEnd hook), so what is worth pinning here is the DISPATCH:
#   • the pick backgrounds `fleet-account.sh migrate --idle` via run-shell -b
#     (issue #304: the popup must return instantly);
#   • the collector backgrounds `migrate --limited` on a limit rotation
#     (issue #495's intent, #512's mechanism);
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

# --- the pick dispatches migrate --idle in the background (issues #263/#304/#512)
CHECKS=$((CHECKS + 1))
grep -Eq "run-shell -b .*fleet-account.sh' migrate --idle" "$SCRIPT" \
  || fail "the account switch must dispatch 'fleet-account.sh migrate --idle' via run-shell -b"

# --- the collector dispatches migrate --limited on a rotation (issue #495 → #512)
CHECKS=$((CHECKS + 1))
grep -Eq "run-shell -b .*fleet-account.sh' migrate --limited" "$BIN/tmux-dash-collect.sh" \
  || fail "the collector must dispatch 'fleet-account.sh migrate --limited' via run-shell -b on a rotation"
CHECKS=$((CHECKS + 1))
grep -Eq -e '--restart-after-rotate' -e '--restart-idle' "$BIN/tmux-dash-collect.sh" "$SCRIPT" \
  && fail "retired restart subcommands still referenced (--restart-idle / --restart-after-rotate)"

# --- the in-place restart helpers are gone: they typed into panes (issue #511) and
# could never move a session under the SessionEnd hook (issue #512).
for fn in _ap_restart_window restart_idle_claude_windows _ap_restart_eligible _ap_pane_claude_pid; do
  CHECKS=$((CHECKS + 1))
  command -v "$fn" >/dev/null 2>&1 && fail "$fn still defined in usage-modal.sh — retired by issue #512 (fleet-migrate.sh)"
done
CHECKS=$((CHECKS + 1))
grep -q 'send-keys' "$SCRIPT" && fail "usage-modal.sh must not send-keys into panes (issue #437/#511)"

# --- fleet-account.sh exposes migrate + whoami (the modal's and collector's callee)
CHECKS=$((CHECKS + 1))
grep -Eq '^  migrate\)' "$BIN/fleet-account.sh" || fail "fleet-account.sh must dispatch 'migrate' to fleet-migrate.sh"
CHECKS=$((CHECKS + 1))
[ -x "$BIN/fleet-migrate.sh" ] || fail "bin/fleet-migrate.sh missing or not executable"

printf 'usage-modal selftest: OK (%d checks)\n' "$CHECKS"
exit 0
