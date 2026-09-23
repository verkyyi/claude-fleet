#!/bin/bash
# fleet-repo-ask.sh [<sess>] — the per-spawn "which repo?" prompt (issues #794, #1034).
# Run inside `tmux display-popup -E`: lists <sess>'s (default: this fleet's) hosted
# repos, prints the picked owner/name on stdout, nothing (exit 1) on Esc. Filing a
# new issue with no row/heading repo to go on runs it (dash-issue-new.sh), since an
# issue always belongs to one repo. It ASKS a destination and sets nothing — the
# footer repo picker it was carved out of is gone (#1034).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"          # fleet_repos

rsess="${1:-$(tmux display-message -p '#S' 2>/dev/null)}"

# `[✕ close]` header token + click-header bind: an iPad/Termius tap-to-dismiss where
# Escape is a reach (issue #346) — tapping ✕/close aborts fzf → empty pick → exit.
# Bracketed as a button (issue #381): the clicked word is `[✕` or `close]`, so the
# case globs *✕*|*close* to fire on either half.
CLOSE_BIND='click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac'

# Every row carries a hidden key field ahead of what it shows — `<repo> US <display>`
# — so the pick is read from the key (fzf --with-nth=2 draws the display only).
# --no-input: tap-to-select on iPad/Termius (issue #359).
US=$'\x1f'; listing=''
while IFS= read -r r; do
  [ -n "$r" ] && listing+="$r$US  $r"$'\n'
done <<EOF2
$(fleet_repos "$rsess")
EOF2
[ -n "$listing" ] || exit 1
pick=$(printf '%s' "$listing" \
  | fzf --ansi --no-sort --layout=reverse-list --info=hidden --border=rounded --height=100% --no-input \
        --delimiter="$US" --with-nth=2 \
        --header="which repo?  ·  enter=pick · esc=cancel · [✕ close]" \
        --bind "$CLOSE_BIND")
[ -n "$pick" ] || exit 1
printf '%s\n' "${pick%%"$US"*}"
