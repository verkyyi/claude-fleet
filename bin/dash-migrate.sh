#!/bin/bash
# dash-migrate.sh <window-target> [confirm] — move the highlighted dash row onto
# another subscription account on ONE key + ONE confirm (dash ⌃l, issue #873).
#
# Unsticking a walled worker used to mean asking some Claude session to run
# `fleet-account.sh migrate …` by hand — from an iPad, in prose. This is that
# command behind a key:
#
#   ⌃l          opens a confirm popup (re-invokes us with `confirm`);
#   the popup   shows fleet-migrate.sh's OWN dry-run for this window — the account
#               it runs on → the account it would land on, and every background
#               command the move would stop (the planner's inventory, #871) — so
#               what you confirm is exactly what runs, never a second opinion;
#   y           dispatches `fleet-migrate.sh --force-bg --toast <window>` detached
#               (a move is a cold `claude` boot, ~25 s; the popup closes at once)
#               and the toast reports the outcome.
#   no move     when the dry-run plans nothing — every account benched, or the
#               window already sits on the only one with room (#567) — the popup
#               says why and offers no `y`: the refusal is fleet-migrate's own.
#
# Target: the dash row's {1} (`sess:idx`) or a fleet handle (`b3`); a header /
# landed row / panel is a silent no-op. Bare `tmux`: this runs inside the dash
# pane, so $TMUX is THIS fleet's socket (issue #159) — never another fleet.
# FLEET_DASH_MIGRATE_ANSWER (a test seam) answers the y/n without a terminal.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

target="${1:-}"; mode="${2:-}"
case "$target" in ''|hdr|landed:*) exit 0 ;; esac
target="$(fleet_wid_target "$target")"
wid=$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null) || exit 0
[ -n "$wid" ] || exit 0
name=$(tmux display-message -p -t "$wid" '#{window_name}' 2>/dev/null)
MIGRATE="${FLEET_DASH_MIGRATE_BIN:-$BIN/fleet-migrate.sh}"
# Named explicitly: the confirmed move runs as a detached run-shell job, which
# must not have to rediscover which fleet it belongs to.
SESS=$(fleet_current_session)

if ! fleet_pane_claude_pid "$wid" >/dev/null 2>&1; then
  tmux display-message "migrate: $name has no Claude process — nothing to move" 2>/dev/null || :
  exit 0
fi

if [ "$mode" != confirm ]; then
  bash "$BIN/dash-popup.sh" -w 90% -h 20 -- bash "$BIN/dash-migrate.sh" "$wid" confirm || :
  exit 0
fi

# --- inside the popup ------------------------------------------------------------
printf '\n  Migrate %s (%s) to another subscription account?\n\n' "$name" "$wid"
plan=$(bash "$MIGRATE" --session "$SESS" --dry-run --force-bg "$wid" 2>&1)
printf '%s\n' "$plan" | grep -v '^fleet-migrate: ' | sed 's/^/ /'
if ! printf '%s\n' "$plan" | grep -q 'would /exit'; then
  printf '\n  No move available — nothing will change.   [any key] close '
  [ -n "${FLEET_DASH_MIGRATE_ANSWER+x}" ] || read -rsn1 _
  echo; exit 0
fi
printf '\n  [y] migrate    [n] cancel '
if [ -n "${FLEET_DASH_MIGRATE_ANSWER+x}" ]; then ans="$FLEET_DASH_MIGRATE_ANSWER"; else read -rsn1 ans; fi
echo
case "$ans" in y|Y) ;; *) exit 0 ;; esac
fleet_bg "bash '$MIGRATE' --session '$SESS' --force-bg --toast '$wid'"
exit 0
