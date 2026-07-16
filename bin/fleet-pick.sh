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

# fleet-list.sh emits an aligned column header as its line 1 (`FLEET REPO
# CHECKOUT`) then one row per fleet — header and rows share the SAME printf, so the
# labels sit over their columns. Capture the header to pin it at the TOP of the
# picker (issue #378), and DIM it so it reads as a header (fleet-list.sh prints it
# plain for its own CLI output — we style it here only; the dim color matches the
# backlog's muted column-title row, fleet_backlog_col_header). Take the live (●)
# rows only for the body — switching only makes sense for a running fleet.
all=$(bash "$BIN/fleet-list.sh" 2>/dev/null)
header=$(printf '\033[38;2;86;95;137m%s\033[0m' "${all%%$'\n'*}")
rows=$(printf '%s\n' "$all" | tail -n +2 | grep -E '^●' || true)

# Optional scoping (issue #368): FLEET_PICK_ONLY = a whitespace/newline-separated
# set of session names to restrict the picker to — the cross-fleet ● jump
# (fleet-xfleet-jump.sh) passes JUST the fleets that are waiting for attention.
# Unset/empty ⇒ every live fleet (the plain #S-name picker).
only="${FLEET_PICK_ONLY:-}"
if [ -n "$only" ]; then
  rows=$(printf '%s\n' "$rows" | awk -v only="$only" '
    BEGIN { n = split(only, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
    ($2 in keep)')
fi

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

# --no-input drops the query/input row (issue #359): switching is tap-to-select on
# iPad/Termius — you tap a fleet, you don't type to filter — so the input row was
# dead space whose only effect was risking a soft-keyboard pop. Hiding it also
# retires the now-inert --prompt (the prompt only ever rendered on that row).
# `[✕ close]` header token + click-header bind: an iPad/Termius tap-to-dismiss where
# Escape is a reach (issue #346) — tapping ✕/close aborts fzf → empty pick → exit.
# Bracketed as a button (issue #381): the clicked word is `[✕` or `close]`, so the
# case globs *✕*|*close* to fire on either half.
# --layout=reverse-list bottom-anchors the instruction --header (list on top,
# header below) so this modal matches the backlog (tmux-issues.sh) and dash
# (tmux-dashboard.sh); --info=hidden --border=rounded mirror the backlog's frame
# for full visual parity (issue #373).
# --header-lines=1 pins the (dimmed) column-title row at the TOP — aligned to the
# rows and OUT of the selectable set — while the instruction --header stays at the
# bottom under --layout=reverse-list, the same top-pin the backlog (#374) and usage
# modal use (issue #378). The pinned row carries no ✕/close word, so a tap there
# never fires the click-header bind; and it's not selectable, so `awk '{print $2}'`
# below never yields it as a pick.
hdr="jump to a running fleet"
[ -n "$only" ] && hdr="jump to a waiting fleet"   # scoped by the cross-fleet ● (issue #368)
pick=$(printf '%s\n%s\n' "$header" "$listing" \
  | fzf --ansi --no-sort --layout=reverse-list --info=hidden --border=rounded --height=100% --no-input \
        --header-lines=1 \
        --header="$hdr  ·  enter=switch · esc=cancel · [✕ close]   [now: ${cur:-?}]" \
        --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac' \
  | awk '{print $2}')

[ -n "$pick" ] || exit 0
[ "$pick" = "$cur" ] && exit 0
# Each fleet is its OWN tmux server now (issue #159), so switch-client (same-server
# only) can't cross fleets. Detach this client and re-attach to the chosen fleet's
# socket in one motion: detach-client -E replaces the client with the attach once
# it detaches (tmux ≥ 3.2, already a hard dep). The socket label == the session name.
tmux detach-client -E "exec tmux -L '$(fleet_socket "$pick")' attach -t '$pick'" 2>/dev/null
