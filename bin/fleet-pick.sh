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

pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% \
        --prompt='switch to fleet ▸ ' \
        --header="jump to a running fleet  ·  enter=switch · esc=cancel   [now: ${cur:-?}]" \
  | awk '{print $2}')

[ -n "$pick" ] || exit 0
[ "$pick" = "$cur" ] && exit 0
if tmux switch-client -t "$pick" 2>/dev/null; then
  tmux display-message "fleet: switched to  ${pick}"
fi
