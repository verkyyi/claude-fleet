#!/bin/bash
# fleet-pick.sh — popup picker for the repo THIS fleet shows (issues #793, #980).
# Enter → the chosen row; Esc cancels. Run inside `tmux display-popup -E` (a click
# on the footer-left fleet name, or the dash's pick key — one picker, two doors).
#
# One fleet per login (EPIC #977): every repo lives in the one fleet, so there is
# no other fleet to switch to and the picker has no fleet level (issue #980 retired
# the fleet rows, the orange other-fleet dot and its jump). Rows are `all repos` +
# one per hosted repo, the current one marked (← viewing). A pick sets the fleet's
# current repo (fleet_current_repo_set) — the dash filters on its next repaint and
# the footer label is republished; nothing reattaches.
# A one-repo fleet has nothing to pick: a note instead of an empty list.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"          # fleet_repos / fleet_current_repo(_set)

cur=$(tmux display-message -p '#S' 2>/dev/null)

# `[✕ close]` header token + click-header bind: an iPad/Termius tap-to-dismiss where
# Escape is a reach (issue #346) — tapping ✕/close aborts fzf → empty pick → exit.
# Bracketed as a button (issue #381): the clicked word is `[✕` or `close]`, so the
# case globs *✕*|*close* to fire on either half.
CLOSE_BIND='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac'

# --repo-only [<sess>] (issue #794): the same picker, ASKING rather than setting —
# <sess>'s (default: this fleet's) hosted repos only, no `all`; prints the picked
# owner/name on stdout, nothing on Esc. Filing a new issue under `all` runs it
# (dash-issue-new.sh), since an issue always belongs to one repo.
if [ "${1:-}" = --repo-only ]; then
  rsess="${2:-$cur}"
  US=$'\x1f'; listing=''
  while IFS= read -r r; do
    [ -n "$r" ] && listing+="$r$US  $r"$'\n'
  done <<EOF
$(fleet_repos "$rsess")
EOF
  [ -n "$listing" ] || exit 1
  pick=$(printf '%s' "$listing" \
    | fzf --ansi --no-sort --layout=reverse-list --info=hidden --border=rounded --height=100% --no-input \
          --delimiter="$US" --with-nth=2 \
          --header="which repo?  ·  enter=pick · esc=cancel · [✕ close]" \
          --bind "$CLOSE_BIND")
  [ -n "$pick" ] || exit 1
  printf '%s\n' "${pick%%"$US"*}"
  exit 0
fi

repos=$(fleet_repos "$cur")
case "$repos" in
  *$'\n'*) ;;
  *) printf 'this fleet (%s) hosts one repo (%s) — nothing to pick.\n' "${cur:-?}" "${repos:-?}"
     sleep 2; exit 0 ;;
esac

# Every row carries a hidden key field ahead of what it shows — `<repo|all> US
# <display>` — so the pick is read from the key, never parsed back out of the text
# (fzf --with-nth=2 draws the display only).
US=$'\x1f'
fcur=$(fleet_current_repo "$cur")
listing=''
for r in all $repos; do
  label=$r; [ "$r" = all ] && label='all repos'
  mark=''; [ "$r" = "$fcur" ] && mark='  ← viewing'
  listing+="$r$US  $label$mark"$'\n'
done

# --no-input drops the query/input row (issue #359): picking is tap-to-select on
# iPad/Termius, so the input row was dead space whose only effect was risking a
# soft-keyboard pop. --layout=reverse-list bottom-anchors the instruction --header
# so this modal matches the backlog (tmux-issues.sh) and dash (tmux-dashboard.sh);
# --info=hidden --border=rounded mirror the backlog's frame (issue #373).
pick=$(printf '%s' "$listing" \
  | fzf --ansi --no-sort --layout=reverse-list --info=hidden --border=rounded --height=100% --no-input \
        --delimiter="$US" --with-nth=2 \
        --header="pick a repo  ·  enter=view · esc=cancel · [✕ close]   [fleet: ${cur:-?}]" \
        --bind "$CLOSE_BIND")

[ -n "$pick" ] || exit 0
prepo=${pick%%"$US"*}
[ -n "$prepo" ] || exit 0
# The fleet's current repo — shared by every screen on it. The dash repaints within
# a second (1Hz reload) and the status label is republished by the set.
fleet_current_repo_set "$cur" "$prepo"
