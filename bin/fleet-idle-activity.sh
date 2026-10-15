#!/bin/sh
# Sourced POSIX helper: a state change invalidates another login's idle reading
# immediately, between collector snapshots too. No subprocess on the hook path.
# Only the collector creates this owned, regular marker; old/missing publishers
# remain unknown to the reader. No credential or session detail is published.
fleet_idle_activity() {
  _fia_d="${FLEET_MACHINE_SESSIONS_DIR:-}"
  if [ -z "$_fia_d" ]; then
    if [ -d /Users/Shared/claude-fleet/sessions ]; then _fia_d=/Users/Shared/claude-fleet/sessions
    else _fia_d=/var/tmp/claude-fleet/sessions; fi
  fi
  _fia_l="${HOME%/}"; _fia_l="${_fia_l##*/}"
  _fia_f="$_fia_d/.idle-$_fia_l"
  if [ -f "$_fia_f" ] && [ ! -L "$_fia_f" ] && [ -w "$_fia_f" ]; then
    : > "$_fia_f" 2>/dev/null
  fi
  unset _fia_d _fia_l _fia_f
  return 0
}
