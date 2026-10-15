#!/bin/sh
# Sourced POSIX helper: a state change invalidates another login's idle reading
# immediately, between collector snapshots too. No subprocess on the hook path.
# Only the collector creates this owned, regular marker; old/missing publishers
# remain unknown to the reader. No credential or session detail is published.
fleet_idle_activity() {
  local d f l
  d="${FLEET_MACHINE_SESSIONS_DIR:-}"
  if [ -z "$d" ]; then
    if [ -d /Users/Shared/claude-fleet/sessions ]; then d=/Users/Shared/claude-fleet/sessions
    else d=/var/tmp/claude-fleet/sessions; fi
  fi
  l="${HOME%/}"; l="${l##*/}"
  f="$d/.idle-$l"
  if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then
    : > "$f" 2>/dev/null
  fi
  return 0
}
