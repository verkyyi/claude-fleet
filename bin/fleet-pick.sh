#!/bin/bash
# fleet-pick.sh — popup picker to SWITCH between running fleets (live tmux
# sessions). Enter → switch-client to the chosen fleet; Esc cancels. Run inside
# `tmux display-popup -E` (bound to a click on the footer-left fleet name).
# Rows come from bin/fleet-list.sh (● live / ○ down · name · repo · checkout);
# we show the LIVE (●) fleets only, since switching only makes sense for those.
# The current session is marked (← current) and switching to it is a no-op.
# Graceful when only this fleet is live: shows a note instead of an empty list.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"          # fleet_socket (per-fleet tmux socket, issue #159)

cur=$(tmux display-message -p '#S' 2>/dev/null)

# Live fleets only (● marker), from fleet-list.sh minus its header row.
rows=$(bash "$BIN/fleet-list.sh" 2>/dev/null | tail -n +2 | grep -E '^●' || true)

if [ -z "$rows" ]; then
  printf 'no live fleets found.\n'; sleep 2; exit 0
fi

# Only this fleet is live → nothing to switch to.
count=$(printf '%s\n' "$rows" | grep -c .)
if [ "$count" -le 1 ]; then
  printf 'only this fleet (%s) is live — nothing to switch to.\n' "${cur:-?}"
  sleep 2; exit 0
fi

# Mark the current session inline so it's obvious which one you're on.
listing=$(printf '%s\n' "$rows" | awk -v cur="$cur" \
  '{ print (($2 == cur) ? $0 "  ← current" : $0) }')

# "✕ close" header token + click-header bind: an iPad/Termius tap-to-dismiss where
# Escape is a reach (issue #346) — tapping ✕/close aborts fzf → empty pick → exit.
pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% \
        --prompt='switch to fleet ▸ ' \
        --header="jump to a running fleet  ·  enter=switch · esc=cancel · ✕ close   [now: ${cur:-?}]" \
        --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in ✕|close) echo abort ;; esac' \
  | awk '{print $2}')

[ -n "$pick" ] || exit 0
[ "$pick" = "$cur" ] && exit 0
# Each fleet is its OWN tmux server now (issue #159), so switch-client (same-server
# only) can't cross fleets. Detach this client and re-attach to the chosen fleet's
# socket in one motion: detach-client -E replaces the client with the attach once
# it detaches (tmux ≥ 3.2, already a hard dep). The socket label == the session name.
tmux detach-client -E "exec tmux -L '$(fleet_socket "$pick")' attach -t '$pick'" 2>/dev/null
