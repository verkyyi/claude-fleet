#!/bin/sh
# Sourced POSIX helper: a state change invalidates another login's idle reading
# immediately, between collector snapshots too.
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

# Private, persistent counters for local observers (#4412). A byte append cannot
# lose concurrent writes or a same-second state round trip; no timestamps, read /
# modify / write, or consumption by a reader. Keep counters after window reap.
# The observer provisions the root: until the first local observation, no extra
# hook work. Each counter needs one byte per hook edge, not a log of event data.
# Identity is socket path + tmux server pid + window id (ids do not repeat within
# a server). Resolve once per hook, reuse for its closing edge even if reaped.
fleet_idle_window_activity() {
  _fiw_root="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/idle-cost/activity"
  [ -d "$_fiw_root" ] || return 0
  if [ -z "${_fiw_identity:-}" ]; then
    [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
    _fiw_row=$(tmux display-message -p -t "$TMUX_PANE" '#{?@fleet_role,=#{@fleet_role},#{window_name}}|#{socket_path}/#{pid}/#{window_id}' 2>/dev/null) || return 0
    # Same role fallback as IdleGuard.local / FLEET_ROLE_AWK.
    case "${_fiw_row%%|*}" in
      =worker) _fiw_identity=${_fiw_row#*|} ;;
      =*|home|plan|dash|backlog) _fiw_identity=- ;;
      *) _fiw_identity=${_fiw_row#*|} ;;
    esac
  fi
  case "$_fiw_identity" in /*/[0-9]*/@[0-9]*) ;; *) return 0 ;; esac
  _fiw_file="$_fiw_root$_fiw_identity"
  [ -d "${_fiw_file%/*}" ] || mkdir -p "${_fiw_file%/*}" 2>/dev/null || return 0
  printf . >> "$_fiw_file" 2>/dev/null
  return 0
}
