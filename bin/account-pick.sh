#!/bin/bash
# account-pick.sh — popup picker to switch the ACTIVE subscription account (the
# one NEW fleet sessions launch under, via bin/fleet-claude.sh). Enter selects,
# Esc cancels. Run inside `tmux display-popup -E`. No-op when multi-account is
# off (no token files). Running sessions keep their account — only new spawns
# pick up the switch. If you pick a currently-limited account, `active` still
# rotates past it at spawn time so sessions don't launch on a walled account.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  *OFF*|'') printf '%s\n\n(no accounts registered — see docs/MULTI-ACCOUNT.md)\n' "$listing"; sleep 2.5; exit 0;;
esac

active=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
pick=$(printf '%s\n' "$listing" | tail -n +2 \
  | fzf --ansi --no-sort --layout=reverse --height=100% \
        --prompt='active account ▸ ' \
        --header="switch the account NEW sessions use  ·  enter=select · esc=cancel   [now: ${active}]" \
  | awk '{print $1}')

[ -n "$pick" ] || exit 0
if bash "$BIN/fleet-account.sh" use "$pick" >/dev/null 2>&1; then
  now=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
  if [ "$now" = "$pick" ]; then
    tmux display-message "fleet: new sessions now use  ${pick}"
  else
    tmux display-message "fleet: ${pick} is limited — new sessions use  ${now}"
  fi
fi
