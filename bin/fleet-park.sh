#!/bin/sh
# fleet-park.sh — park a stuck session, wake it when what it waits for arrives
# (issue #2671, EPIC #2668 C3). The whole spec is bin/fleet_park.py's header.
exec python3 "$(cd "$(dirname "$0")" && pwd)/fleet_park.py" "$@"
