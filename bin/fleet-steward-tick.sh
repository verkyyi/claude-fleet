#!/bin/sh
# fleet-steward-tick.sh — the steward's beat with no model (issue #2670, EPIC #2668
# C2): beat · delta · answer · sheet · card. The whole spec is bin/fleet_steward.py's
# header; this name is the one the role, the skill and home_watch call.
exec python3 "$(cd "$(dirname "$0")" && pwd)/fleet_steward.py" "$@"
