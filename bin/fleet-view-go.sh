#!/bin/bash
# fleet-view-go.sh <看台> <worker_id|@window> [--how <what>] [--client <c>] —
# THE way a 看台 changes session (issue #3000, EPIC #2999 C2, 共同约定 8): the ⌘P
# popup's ↵, ⌘↓ ⌘↑ ⌘[ ⌘], C4's other machines and C7's keys all come through
# here. <看台> is its id or its session name (`fleet@view-<id>`). Exit 0 switched ·
# 2 no such 看台 · 3 another machine / login not connected yet (C4) · 4 gone.
# Every call is one line of $FLEET_CONF_DIR/logs/view-switch.ndjson.
# The one implementation is fleet_view.go (bin/fleet_view.py).
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-quickopen.py" go "$@"
