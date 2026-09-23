#!/bin/bash
# fleet-pick.sh — popup picker to SWITCH between running fleets (live tmux
# sessions) and, in a fleet that hosts 2+ repos, to pick the repo it shows
# (issue #793). Enter → the chosen row; Esc cancels. Run inside
# `tmux display-popup -E` (a click on the footer-left fleet name, or the dash's
# pick key — one picker, two doors).
# Rows come from bin/fleet-list.sh (● live / ○ down · name · repo · checkout);
# we show the LIVE (●) fleets only, since switching only makes sense for those.
# The current session is marked (← current) and switching to it is a no-op.
# Two levels (issue #793): a fleet hosting 2+ repos is followed by indented rows
# `all repos` + one per repo, its current repo marked (← viewing). A repo row in
# THIS fleet sets the fleet's current repo (fleet_current_repo_set) — the dash
# filters on its next repaint, no reattach; a repo row in ANOTHER fleet sets that
# fleet's current repo, then reattaches there. A one-repo fleet shows its fleet row
# only, exactly as before.
# Graceful when only this fleet is live and it has no repos to pick: a note
# instead of an empty list.
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

# Every row carries two hidden key fields ahead of what it shows — `<fleet> US
# <repo|all|empty> US <display>` — so the pick is read from the keys, never parsed
# back out of the text (fzf --with-nth=3 draws the display only). Repo rows are
# offered only in the plain picker: the cross-fleet ● jump (FLEET_PICK_ONLY) stays
# fleet-level.
US=$'\x1f'
listing=''; nrepo=0; nfleet=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  f=$(printf '%s\n' "$row" | awk '{print $2}')
  nfleet=$((nfleet + 1))
  if [ "$f" = "$cur" ]; then listing+="$f$US$US$row  ← current"$'\n'
  else listing+="$f$US$US$row"$'\n'; fi
  [ -z "$only" ] || continue
  repos=$(fleet_repos "$f")
  case "$repos" in *$'\n'*) ;; *) continue ;; esac        # one repo: fleet row only
  fcur=$(fleet_current_repo "$f")
  n=$(printf '%s\n' "$repos" | grep -c .); i=0
  for r in all $repos; do
    i=$((i + 1)); tree='├'; [ "$i" -gt "$n" ] && tree='└'
    label=$r; [ "$r" = all ] && label='all repos'
    mark=''; [ "$r" = "$fcur" ] && mark='  ← viewing'
    listing+="$f$US$r$US     $tree $label$mark"$'\n'
    nrepo=$((nrepo + 1))
  done
done <<EOF
$rows
EOF

# Only this fleet is live and it has no repos to pick → nothing to do.
if [ "$nfleet" -le 1 ] && [ "$nrepo" = 0 ]; then
  printf 'only this fleet (%s) is live — nothing to switch to.\n' "${cur:-?}"
  sleep 2; exit 0
fi

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
# never fires the click-header bind; and it's not selectable, so the key fields
# read below never come from it.
hdr="jump to a running fleet"
[ "$nrepo" -gt 0 ] && hdr="pick a fleet or a repo"
[ -n "$only" ] && hdr="jump to a waiting fleet"   # scoped by the cross-fleet ● (issue #368)
pick=$(printf '%s\n%s' "hdr$US$US$header" "$listing" \
  | fzf --ansi --no-sort --layout=reverse-list --info=hidden --border=rounded --height=100% --no-input \
        --delimiter="$US" --with-nth=3 \
        --header-lines=1 \
        --header="$hdr  ·  enter=switch · esc=cancel · [✕ close]   [now: ${cur:-?}]" \
        --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac')

[ -n "$pick" ] || exit 0
pfleet=${pick%%"$US"*}; prest=${pick#*"$US"}; prepo=${prest%%"$US"*}
[ -n "$pfleet" ] || exit 0
# A repo row: that fleet's current repo — per fleet, shared by every screen on it.
[ -n "$prepo" ] && fleet_current_repo_set "$pfleet" "$prepo"
# This fleet: done. The dash repaints within a second (1Hz reload) and the status
# label was republished by the set — no reattach.
[ "$pfleet" = "$cur" ] && exit 0
# Each fleet is its OWN tmux server now (issue #159), so switch-client (same-server
# only) can't cross fleets. Detach this client and re-attach to the chosen fleet's
# socket in one motion: detach-client -E replaces the client with the attach once
# it detaches (tmux ≥ 3.2, already a hard dep). The socket label == the session name.
tmux detach-client -E "exec tmux -L '$(fleet_socket "$pfleet")' attach -t '$pfleet'" 2>/dev/null
