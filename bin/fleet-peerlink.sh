#!/bin/bash
# fleet-peerlink.sh — launchd / systemd entry of bin/fleet-peerlink.py (issue #3002,
# EPIC #2999 C5): the home machine's standing connections to the other machines.
# One per login (the .py holds an flock); KeepAlive brings it back. A bare PATH
# (launchd) finds python3 where Homebrew puts it.
#
# FLEET_PEERLINK_MODE (issue #3482): `all` (the default — a standing link to every
# login of yours on the other machines) or `demand` (only while a thin view wants
# one, closed when it no longer does). Read from the machine's fleet.conf (#1623)
# when the environment does not set it — that one name only, nothing else of the
# file enters the keeper's environment.
command -v python3 >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -z "${FLEET_PEERLINK_MODE:-}" ]; then
  _conf="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
  _m=$(for f in "$(cd "$(dirname "$0")/.." && pwd)/fleet.conf" "$_conf/fleet.settings" "$_conf/fleet.conf"; do
         # shellcheck source=/dev/null
         [ -f "$f" ] && . "$f" >/dev/null 2>&1
       done; printf '%s' "${FLEET_PEERLINK_MODE:-}")
  [ -n "$_m" ] && export FLEET_PEERLINK_MODE="$_m"
fi
exec python3 "$(cd "$(dirname "$0")" && pwd)/fleet-peerlink.py" "$@"
