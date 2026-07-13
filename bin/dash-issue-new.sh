#!/bin/bash
# dash-issue-new.sh [confirm] [--spawn] — file a NEW GitHub issue from a popup.
#
# Two callers share this one script (issue #205):
#   • backlog ⌃n (capture-only): file the issue, drop it in the backlog, done.
#     `enter` on the row later spawns the worker.
#   • prefix+n (quick-dispatch, --spawn): file the issue AND immediately spawn
#     its bound worker window (dash-issue-session.sh) — one keystroke → one line
#     → issue filed + worker running, zero LLM tokens in the dispatch path.
#
# Called with no args it opens a small popup that reads just a TITLE — ^n is the
# one-line fast filer (issue #297), so there is NO body prompt (add a body on
# GitHub later if you need one). Esc — or an empty title — cancels the whole
# create on the spot. The popup re-invokes it with `confirm` (carrying --spawn
# when set), which runs `gh issue create` against this fleet's repo, optimistically
# drops the new row into the issues cache (so the panel's reload shows it at
# once), and kicks a background refetch to make it authoritative. In --spawn mode
# it then spawns the worker in the BACKGROUND so the popup closes instantly
# instead of hanging on the worktree+window+Claude launch; the spawn choke point
# (dash-issue-session.sh) toasts its OWN outcome, and a session-cap refusal still
# leaves the issue filed (files-without-spawning — the backlog item is never lost).
# A gh create failure surfaces in the popup and doesn't wedge the modal.
#
# Args (order-independent): `confirm` = phase 2 (running inside the popup);
# `--spawn` = quick-dispatch mode (spawn the worker after create).
mode=""; spawn=0
for _a in "$@"; do
  case "$_a" in
    confirm) mode=confirm ;;
    --spawn) spawn=1 ;;
  esac
done
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

FLEET_SESSION=$(fleet_current_session); export FLEET_SESSION
# Overlay this fleet's per-session conf so any per-fleet knob is honored. Sourced in
# BOTH phases (this runs before the phase split), so phase 2 inside the popup sees it
# too. Repo resolution below still wins via CF_REPO.
fleet_load_conf "$FLEET_SESSION"
# repo: CF_REPO (passed through the popup) wins; else the fleet's cached repo,
# else the global FLEET_REPO — matching the backlog panel's resolution.
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -n "${CF_REPO:-}" ] && REPO="$CF_REPO"
[ -z "$REPO" ] && { tmux display-message "backlog: no repo resolved — cannot create issue"; exit 1; }
command -v gh >/dev/null 2>&1 || { tmux display-message "gh not found — cannot create issue"; exit 1; }

# phase 1: pop the input dialog that re-invokes us in `confirm` mode. Carry
# --spawn through so quick-dispatch (prefix+n) reaches phase 2 as a spawn.
if [ "$mode" != confirm ]; then
  spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
  tmux display-popup -w 76 -h 12 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg"
  exit 0
fi

# read_title: read the title char-by-char so Esc cancels the WHOLE create on the
# spot (issue #297). A plain `read` only acts on Enter, so an Esc keypress would be
# swallowed into the line instead of aborting. Enter submits, Backspace erases, Esc
# (0x1b) cancels. We treat any Esc byte as cancel WITHOUT disambiguating arrow-key
# escape sequences: macOS ships bash 3.2, whose `read -t` rejects the fractional
# timeout a peek-ahead would need, and arrow keys have no meaning in a one-line
# title field anyway (worst case: the popup closes and you press ^n again). IFS= is
# load-bearing — it keeps a typed space as ' ', so ONLY a real newline reads back as
# '' (Enter). Sets $title; returns 1 on Esc-cancel, 0 otherwise.
read_title() {
  title=""; local ch
  while IFS= read -rsn1 ch; do
    case "$ch" in
      '')               printf '\n'; return 0 ;;                            # Enter → submit
      $'\x1b')          return 1 ;;                                         # Esc → cancel
      $'\x7f'|$'\x08')  [ -n "$title" ] && { title="${title%?}"; printf '\b \b'; } ;;  # Backspace
      *)                title="$title$ch"; printf '%s' "$ch" ;;
    esac
  done
  printf '\n'; return 0                                                     # EOF → submit what we have
}

# phase 2: running inside the popup — read a TITLE only (^n is the one-line fast
# filer, issue #297; there is no body prompt). Esc or an empty title cancels.
[ "$spawn" = 1 ] && verb="New issue + worker" || verb="New issue"
printf '\n  %s in \033[1m%s\033[0m\n  (empty title or Esc = cancel)\n\n  title ▸ ' "$verb" "$REPO"
read_title || exit 0                                # Esc → cancel the create directly
[ -z "$title" ] && exit 0                           # empty title → cancel

if url=$(gh issue create --repo "$REPO" --title "$title" --body "" 2>/dev/null); then
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
  if [ "$spawn" = 1 ] && [ -n "$num" ]; then
    # Quick-dispatch (^n): the worktree+window+Claude launch is the slow part, so
    # confirm the FILING now and spawn the worker in the BACKGROUND — the popup
    # closes instantly instead of hanging (issue #297). dash-issue-session.sh stays
    # the shared spawn choke point (global + per-fleet session caps, already-spawned
    # dedup) and toasts its OWN outcome (spawned / cap-refused / already-claimed), so
    # nothing is lost once the popup is gone; on a cap refusal the issue is STILL
    # filed — the toast below plus the optimistic backlog row keep it visible
    # (acceptance (c)). Pass --title so the window is named after the WORK without
    # depending on the just-written optimistic row surviving the collector refetch
    # (issue #216). Detached via ( … & ) exactly like the collector above so it
    # outlives the popup close.
    tmux display-message "filed #$num in $REPO ✓ — spawning worker…"
    ( bash "$BIN/dash-issue-session.sh" "$num" --title "$title" >/dev/null 2>&1 & )
  else
    tmux display-message "filed new issue #$num in $REPO ✓"
  fi
else
  printf '\n  \033[31mfailed to create issue in %s\033[0m — press any key ' "$REPO"; read -rsn1 _
fi
