#!/bin/bash
# fleet-xfleet-jump.sh — one-tap jump to ANOTHER fleet that needs attention (issue
# #368). Bound to a click on the ORANGE cross-fleet "● N" dot in status-left
# (range=user|xfleet). Enumerates the OTHER live fleets whose @attn_needs > 0 (the
# same needy-window unit the dot shows) and:
#   0 waiting  → a brief note, then exit (the dot was already clearing under you).
#   1 waiting  → detach-and-reattach to its socket — the fleet-switch rail
#                (detach-client -E, NOT switch-client: each fleet is its OWN tmux
#                server, issue #159), the same motion fleet-pick.sh uses on select.
#   ≥2 waiting → hand off to fleet-pick.sh scoped (FLEET_PICK_ONLY) to JUST the
#                waiting fleets, so you pick which one to jump to.
# Run inside `tmux display-popup -E` on THIS fleet's client, so bare `tmux` inherits
# this fleet's socket via $TMUX; each per-OTHER-fleet read names `-L <sock>`
# explicitly (that fleet is a different server). Reuses fleet_sockets + fleet-pick.sh.
#
#   --list : print the resolved waiting fleets (one per line) and exit with no side
#            effect — the selftest hook for jump-target resolution, and a way to see
#            what a click would target. XFLEET_CUR overrides the current fleet name
#            (which #S normally yields) when there is no attached client to read it
#            from, so the headless selftest can drive it.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"          # fleet_sockets / fleet_socket (per-fleet socket, #159)

mode="${1:-}"
cur="${XFLEET_CUR:-$(tmux display-message -p '#S' 2>/dev/null)}"

# Which OTHER live fleets are waiting? @attn_needs > 0 — the needy-window count the
# spinner publishes per fleet (same unit as the orange dot's @attn_other_windows).
# Loop over a here-doc of the socket list (NOT `$(fleet_sockets | while … case …)`:
# a `case` inside a command-substituted pipeline trips the bash 3.2 parser, the
# macOS system bash this runs under). $waiting = the waiting fleets, one per line.
socks=$(fleet_sockets)
waiting=''
while IFS= read -r sock; do
  [ -n "$sock" ] || continue
  [ "$sock" = "$cur" ] && continue
  n=$(tmux -L "$sock" show-options -t "$sock" -qv @attn_needs 2>/dev/null)
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || continue
  if [ -z "$waiting" ]; then waiting="$sock"; else waiting="$waiting
$sock"; fi
done <<EOF
$socks
EOF

count=0
[ -n "$waiting" ] && count=$(printf '%s\n' "$waiting" | grep -c .)

if [ "$mode" = --list ]; then
  [ -n "$waiting" ] && printf '%s\n' "$waiting"
  exit 0
fi

if [ "$count" -eq 0 ]; then
  printf 'no other fleet is waiting right now.\n'; sleep 2; exit 0
fi

if [ "$count" -eq 1 ]; then
  # Exactly one → jump straight there. detach-client -E replaces this client with an
  # attach to the target fleet's socket once it detaches (tmux ≥ 3.2, already a hard
  # dep). The socket label == the session name.
  tmux detach-client -E "exec tmux -L '$(fleet_socket "$waiting")' attach -t '$waiting'" 2>/dev/null
  exit 0
fi

# ≥2 waiting → let the operator pick, scoped to JUST the waiting fleets. Reuse the
# fleet picker (it does the same detach-and-reattach on the chosen fleet).
FLEET_PICK_ONLY="$waiting" exec bash "$BIN/fleet-pick.sh"
