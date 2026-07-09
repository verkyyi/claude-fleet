#!/bin/sh
# dash-view-toggle.sh — flip the dashboard between its LIVE session list and the
# LANDED history view (issue #130). The dash's ⌃t bind calls this, then reloads;
# tmux-dashboard-rows.sh reads $C/dash_view and hands off to the history ledger's
# row emitter when it says `landed`. Stateless toggle: live⇄landed, default live.
set -u
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C" 2>/dev/null || true
# Scope the view state PER FLEET (per tmux session), like everything else the dash
# keys off FLEET_SESSION — a single shared file would leak one fleet's toggle into
# every other fleet's dashboard on the same host (they share $C). tmux session
# names can't contain '.'/':' so they're filename-safe.
f="$C/dash_view_${FLEET_SESSION:-default}"
if [ "$(cat "$f" 2>/dev/null)" = landed ]; then
  printf 'live\n'   > "$f"
else
  printf 'landed\n' > "$f"
fi
