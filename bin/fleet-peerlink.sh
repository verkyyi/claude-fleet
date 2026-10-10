#!/bin/bash
# fleet-peerlink.sh — launchd / systemd entry of bin/fleet-peerlink.py (issue #3002,
# EPIC #2999 C5): the home machine's standing connections to the other machines.
# One per login (the .py holds an flock); KeepAlive brings it back. A bare PATH
# (launchd) finds python3 where Homebrew puts it.
command -v python3 >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec python3 "$(cd "$(dirname "$0")" && pwd)/fleet-peerlink.py" "$@"
