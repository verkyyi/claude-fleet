#!/bin/bash
# fleet-sleep-daemon.sh — moved (T544, EPIC T542 C6): the 60 s tick is now the
# state-reconcile unit, bin/fleet-reconcile-tick.sh. This shell forwards for one
# version so a login whose com.claude-fleet.sleep / claude-fleet-sleep.timer is
# not yet retired keeps reconciling. # compat-1v: 下一批删
exec bash "$(cd "$(dirname "$0")" && pwd)/fleet-reconcile-tick.sh" "$@"
