#!/bin/bash
# dash-issue-new.sh [confirm] — file a NEW GitHub issue straight from the backlog
# panel WITHOUT spawning a worker (pure quick-capture). Called with no args it
# opens a small popup that reads a title (required) and an optional body; the
# popup re-invokes it with `confirm`, which runs `gh issue create` against this
# fleet's repo, optimistically drops the new row into the issues cache (so the
# panel's reload shows it at once), and kicks a background refetch to make it
# authoritative. Deliberately does NOT call dash-issue-session.sh —
# this captures a backlog item; `enter` on the row later spawns the worker (or
# autofill picks it up). Empty title aborts quietly; a gh failure surfaces and
# doesn't wedge the modal.
mode="${1:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
# repo: CF_REPO (passed through the popup) wins; else the fleet's cached repo,
# else the global FLEET_REPO — matching the backlog panel's resolution.
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot create issue"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot create issue"; exit 1; }

# phase 1: pop the input dialog that re-invokes us in `confirm` mode.
if [ "$mode" != confirm ]; then
  tmux display-popup -w 72 -h 12 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm"
  exit 0
fi

# phase 2: running inside the popup — read a title (required) then an optional
# body, then file the issue. Title-only is the fast path (empty body is fine).
printf '\n  New issue in \033[1m%s\033[0m\n  (empty title = cancel)\n\n  title ▸ ' "$REPO"
IFS= read -r title
[ -z "$title" ] && exit 0
printf '  body  ▸ (optional, enter to skip) '
IFS= read -r body

if url=$(gh issue create --repo "$REPO" --title "$title" --body "$body" 2>/dev/null); then
  num="${url##*/}"; num="${num//[^0-9]/}"          # trailing #num from the issue URL
  # Optimistically insert the new row into THIS fleet's issues cache so the modal's
  # reload shows it at once (mirrors dash-issue-close.sh's optimistic drop). A
  # brand-new issue has no milestone + no assignee, matching the collector's row
  # format: "<milestone>\t#<num>\t<assignee>\t<title>". fleet_cache returns the
  # exact file the reload reads, so we never touch the .ts (no flat-cache flash).
  src=$(fleet_cache issues "$FLEET_SESSION")
  [ -n "$num" ] && [ -n "$src" ] && \
    printf '%s\t#%s\t%s\t%s\n' '· no milestone' "$num" '·' "$title" >> "$src"
  # kick a background refetch to make the cache authoritative (ordering, dedup);
  # GH_TTL=0 forces the fetch regardless of cache age.
  ( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
  tmux display-message "filed new issue #$num in $REPO ✓"
else
  printf '\n  \033[31mfailed to create issue in %s\033[0m — press any key ' "$REPO"; read -rsn1 _
fi
