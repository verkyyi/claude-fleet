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
# when set), which files via the one issue channel (bin/fleet-issue-file.sh, #332)
# against this fleet's repo, optimistically
# drops the new row into the issues cache (so the panel's reload shows it at
# once), and kicks a background refetch to make it authoritative. In --spawn mode
# it then spawns the worker in the BACKGROUND so the popup closes instantly
# instead of hanging on the worktree+window+Claude launch; the spawn choke point
# (dash-issue-session.sh) toasts its OWN outcome, and a session-cap refusal still
# leaves the issue filed (files-without-spawning — the backlog item is never lost).
# A gh create failure surfaces in the popup and doesn't wedge the modal.
#
# Args (order-independent): `confirm` = phase 2 (running inside the popup);
# `--spawn` = quick-dispatch mode (spawn the worker after create);
# `--title-file=<f>` = the BACKGROUND create pass (issue #304) — the interactive
# popup has already read the title into <f> and re-execs us via fleet_bg, so we
# skip the read and just do the (slow) create. The path comes from mktemp (no
# metachars), so the single-token form is safe.
mode=""; spawn=0; title_file=""
for _a in "$@"; do
  case "$_a" in
    confirm)        mode=confirm ;;
    --spawn)        spawn=1 ;;
    --title-file=*) title_file="${_a#--title-file=}" ;;
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

# create_issue — the SLOW tail: file the issue, optimistically insert its row, kick
# the authoritative refetch, and (in --spawn mode) background-spawn the worker. It
# runs in the BACKGROUND (issue #304 — dispatched below), so a create failure toasts
# via display-message rather than waiting on a keypress in a popup that has closed.
create_issue() {
  local url num src
  # File through the ONE channel (issue #332): fleet-issue-file.sh owns the body /
  # label / provenance behaviour for every filer and prints the URL just like `gh
  # issue create` did. ⌃n is title-only (no --body, no labels), so this stays the
  # network-free-here fast path it was — the channel only adds the invisible
  # fleet:from provenance marker. The optimistic-row + background-spawn tail below
  # is UNCHANGED, so the operator-visible ⌃n / prefix+n behaviour is identical.
  if url=$("$BIN/fleet-issue-file.sh" --repo "$REPO" --title "$title" 2>/dev/null); then
    num="${url##*/}"; num="${num//[^0-9]/}"          # trailing #num from the issue URL
    # Optimistically insert the new row into THIS fleet's issues cache so the modal's
    # reload shows it (mirrors dash-issue-close.sh's optimistic drop). A brand-new
    # issue has no milestone + no assignee, matching the collector's row format:
    # "<milestone>\t#<num>\t<assignee>\t<title>". fleet_cache returns the exact file
    # the reload reads, so we never touch the .ts (no flat-cache flash).
    src=$(fleet_cache issues "$FLEET_SESSION")
    [ -n "$num" ] && [ -n "$src" ] && \
      printf '%s\t#%s\t%s\t%s\n' '· no milestone' "$num" '·' "$title" >> "$src"
    # refetch to make the cache authoritative (ordering, dedup); GH_TTL=0 forces it.
    ( GH_TTL=0 bash "$BIN/tmux-dash-collect.sh" >/dev/null 2>&1 & )
    if [ "$spawn" = 1 ] && [ -n "$num" ]; then
      # Quick-dispatch (^n): spawn the worker (worktree+window+Claude) too, in its
      # OWN background subshell so it outlives this bg pass. dash-issue-session.sh is
      # the shared spawn choke point (global + per-fleet caps, already-spawned dedup)
      # and toasts its OWN outcome, so on a cap refusal the issue is STILL filed
      # (acceptance (c)). --title names the window after the WORK without depending on
      # the optimistic row surviving the collector refetch (issue #216).
      tmux display-message "filed #$num in $REPO ✓ — spawning worker…"
      ( bash "$BIN/dash-issue-session.sh" "$num" --title "$title" >/dev/null 2>&1 & )
    else
      tmux display-message "filed new issue #$num in $REPO ✓"
    fi
  else
    tmux display-message "failed to create issue in $REPO — try again"
  fi
}

# phase 2, BACKGROUND pass: re-exec'd via fleet_bg with the title staged in a temp
# file (issue #304). Read + delete it, then run the slow create — no popup, no stdin.
if [ -n "$title_file" ]; then
  title=$(cat "$title_file" 2>/dev/null); rm -f "$title_file"
  [ -z "$title" ] && exit 0
  create_issue
  exit 0
fi

# phase 2, INTERACTIVE: running inside the popup — read a TITLE only (^n is the
# one-line fast filer, issue #297; there is no body prompt). Esc or an empty title
# cancels. Then hand the slow create off to the BACKGROUND so the popup closes
# INSTANTLY instead of blocking on `gh issue create` (+ the worktree/window spawn).
[ "$spawn" = 1 ] && verb="New issue + worker" || verb="New issue"
printf '\n  %s in \033[1m%s\033[0m\n  (empty title or Esc = cancel)\n\n  title ▸ ' "$verb" "$REPO"
read_title || exit 0                                # Esc → cancel the create directly
[ -z "$title" ] && exit 0                           # empty title → cancel

# Stage the title in a temp file — it is arbitrary user text, so it is NEVER
# interpolated into the run-shell command string (only the mktemp path, which has no
# metachars, is). The bg re-exec toasts its own outcome (the popup is gone by then).
tf=$(mktemp "${TMPDIR:-/tmp}/dash-new.XXXXXX") || { tmux display-message "backlog: cannot stage the new issue"; exit 1; }
printf '%s' "$title" > "$tf"
spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
fleet_bg "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg --title-file='$tf'"
exit 0
