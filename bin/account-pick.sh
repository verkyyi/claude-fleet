#!/bin/bash
# account-pick.sh — popup picker to switch the ACTIVE subscription account (the
# one NEW fleet sessions launch under, via bin/fleet-claude.sh). Enter selects,
# Esc cancels. Run inside `tmux display-popup -E`. No-op when multi-account is
# off (no token files). Running sessions keep their account — only new spawns
# pick up the switch. If you pick a currently-limited account, `active` still
# rotates past it at spawn time so sessions don't launch on a walled account.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  *OFF*|'') printf '%s\n\n(no accounts registered — see docs/MULTI-ACCOUNT.md)\n' "$listing"; sleep 2.5; exit 0;;
esac

# --- Machine-wide window usage header (aggregate, NOT per-account — one shared
# ~/.claude, so transcripts can't be attributed to an OAuth account). The 5h/7d
# proxy + the official weekly/N-hour % (fresh-gated) come from usage-lib.sh, the
# same shared reader the footer colors and the usage popup (prefix+u) render, so
# this header can't drift from them. Empty when neither cache has anything. ---
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"
usg=$(fleet_usage_summary_plain)

active=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
hdr="switch the account NEW sessions use  ·  enter=select · esc=cancel   [now: ${active}]"
[ -n "$usg" ] && hdr="${usg}"$'\n'"${hdr}"

# --header-lines=1 pins the table's column-title row (line 1 of `list`) so it
# stays aligned with the data rows and out of the selectable set; the usage
# summary rides above it via --header. Data rows lead with the bare label, so
# `awk '{print $1}'` recovers the pick even with the trailing ANSI in STATE.
pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% --header-lines=1 \
        --prompt='active account ▸ ' \
        --header="$hdr" \
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
