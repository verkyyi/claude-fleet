#!/bin/bash
# fleet-collect-kick.sh — the COLLECTOR's slice of the daemon self-heal. Kept as
# its own entry point (issue #636 shipped it, #638 wired it into the status bar,
# the quota watch and fleet-doctor) but the logic now lives in ONE generalized
# place: bin/fleet-daemon-watch.sh, which does the same thing for every interval
# unit (issue #639).
#
# WHY IT MOVED. #636's fault was not collector-shaped. Two days after the
# collector got its alarm + self-heal, the same machine showed launchd had stopped
# scheduling EVERY StartInterval unit in this user domain inside the same two
# minutes, while the two KeepAlive units never missed a frame — so cleanup stopped
# reaping workers, dispatch stopped autofilling, base-sync stopped fast-forwarding
# the base, issue-bridge stopped relaying comments, and nothing said a word,
# because only the collector had a heartbeat that could go stale. A self-heal that
# knows one unit's name is the wrong shape for that. See bin/fleet-daemon-lib.sh
# for the measurements and the relative-interval threshold that replaced the
# absolute 600s one (a collector running once per 7–14 min read `fresh` for hours).
#
# Contract UNCHANGED, so every existing caller keeps working:
#   fleet-collect-kick.sh                 # kick iff stale + cooldown elapsed
#   fleet-collect-kick.sh --force [--now] # kick regardless of staleness (--now
#                                         #   also skips the cooldown + the
#                                         #   "a tick is running" guard)
#   fleet-collect-kick.sh --dry-run       # say what it would do, touch nothing
#   fleet-collect-kick.sh --status        # fresh|stale|never <TAB> age <TAB> kick-age
#
# Env: FLEET_COLLECT_STALE (absolute override; the default is now relative to the
#      unit's own StartInterval — FLEET_DAEMON_STALE_MULT × 60)
#      FLEET_COLLECT_KICK_COOLDOWN (600)  FLEET_COLLECT_KICK_TRACE (1800)
#      FLEET_COLLECT_KICK (1 — set 0 to disable the self-heal and keep the alarm)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
esac
exec bash "$BIN/fleet-daemon-watch.sh" --unit collect "$@"
