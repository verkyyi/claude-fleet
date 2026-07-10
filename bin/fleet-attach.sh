#!/bin/bash
# fleet-attach.sh — fast-path (re)attach to an ALREADY-RUNNING fleet (issue #212).
#
# `cf` with no args means "take me back to my running fleet." When a fleet is
# already live on its named socket (issue #159) there is no reason to walk the
# heavier fleet-up path (disk gate, conf write, hub rebuild, collector kick) or
# any restore machinery — we just (re)attach to the live tmux server. This is
# that fast path; cf calls it FIRST and only falls through to fleet-up.sh when
# nothing is running (exit 10).
#
# Selection:
#   0 live fleets → exit 10 (nothing to attach; the caller falls through to up).
#   1 live fleet  → (re)attach straight to it.
#   N live fleets → the picker (fleet-pick.sh) when we're interactive inside tmux;
#                   otherwise the most-recently-active fleet, so a non-interactive
#                   caller (or one outside tmux) still lands somewhere sensible.
#
# Cross-socket rule (issue #159): each fleet is its OWN tmux server, so you cannot
# switch-client across them. From INSIDE another fleet we detach + re-attach in one
# motion (detach-client -E, tmux ≥ 3.2); from OUTSIDE tmux we plain attach. Already
# sitting in the (only) live fleet → nothing to do.
#
# Prints the attach hint on any failure so the operator can finish by hand.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# (re)attach the caller to fleet session $1, honoring the cross-socket rule.
attach_to() {
  local sess="$1" sock
  sock=$(fleet_socket "$sess")
  if [ -n "${TMUX:-}" ]; then
    # Inside a tmux client already (some fleet). If it's THIS fleet, we're done.
    local cur
    cur=$(tmux display-message -p '#S' 2>/dev/null)
    if [ "$cur" = "$sess" ]; then
      echo "fleet-attach: already on '$sess'." >&2
      return 0
    fi
    # Cross-socket: switch-client can't reach another server (issue #159), so
    # detach this client and re-attach to the target socket in one motion. -E runs
    # the replacement command post-detach (tmux ≥ 3.2, already a hard dep).
    tmux detach-client -E "exec tmux -L '$sock' attach -t '$sess'" 2>/dev/null \
      || { echo "fleet-attach: could not switch — attach by hand: tmux -L $sock attach -t $sess" >&2; return 1; }
  else
    # Outside tmux: just attach. exec so the client owns this terminal directly.
    exec tmux -L "$sock" attach -t "$sess" \
      || { echo "fleet-attach: could not attach — try: tmux -L $sock attach -t $sess" >&2; return 1; }
  fi
}

# Of the given live sessions, print the most-recently-active one (highest
# #{session_activity}). Ties / unreadable activity fall back to the last listed.
most_recent() {
  local best="" bestt=-1 s t
  for s in "$@"; do
    t=$(tmux -L "$(fleet_socket "$s")" display-message -p -t "$s" '#{session_activity}' 2>/dev/null)
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    if [ "$t" -ge "$bestt" ]; then bestt="$t"; best="$s"; fi
  done
  printf '%s' "$best"
}

# Live fleets = configured fleets whose tmux server answers (fleet_sockets, #159).
live=$(fleet_sockets)
n=$(printf '%s' "$live" | grep -c . || true)

if [ "${n:-0}" -eq 0 ]; then
  # Nothing running — signal the caller (cf) to take the fleet-up/restore path.
  exit 10
fi

if [ "$n" -eq 1 ]; then
  attach_to "$(printf '%s\n' "$live" | head -n1)"
  exit
fi

# Multiple live fleets. Interactive inside tmux → the blessed fzf picker, which
# already handles the cross-socket detach+attach and marks the current fleet.
if [ -n "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ] && command -v fzf >/dev/null 2>&1 \
   && [ -x "$BIN/fleet-pick.sh" ]; then
  exec bash "$BIN/fleet-pick.sh"
fi

# Non-interactive, or outside tmux: land on the most-recently-active fleet.
# shellcheck disable=SC2046
attach_to "$(most_recent $(printf '%s\n' "$live"))"
