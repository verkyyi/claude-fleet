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
#
# The interactive title read is `fzf --print-query` (issue #429): fzf owns its own
# UTF-8/IME/paste-aware echo (so a CJK/IME commit is never double-drawn), cancels on
# Esc/Ctrl-C INSTANTLY (exit 130), and folds a pasted block into its single-line query
# — fixing the CJK double-echo, the 1-second-Esc, and the paste bugs the old hand-rolled
# `read -rsn1` loop (read_title/read_paste + utf8_len/bytelen) structurally couldn't. The
# fleet already mandates fzf (≥0.45) and uses it for the dash/backlog/config popups.

# Force a UTF-8 locale so any title handling below (the create channel, the window/branch
# naming, the optimistic cache row) treats a CJK/emoji title as whole CHARACTERS, not raw
# bytes (issue #408). SSH/Termius forward LANG but usually not LC_CTYPE/LC_ALL, so a tmux
# popup off a server started without them would otherwise run in the C locale. Matches the
# sibling tmux-*-rows.sh exports; en_US.UTF-8 is universal on macOS (C.UTF-8 doesn't exist
# there). Set before the phase split so BOTH the interactive read and any re-exec inherit
# it. (fzf owns the interactive editing itself now — issue #429 — but this stays useful for
# the non-interactive create/naming paths.)
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"

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
# fzf is the interactive title widget now (issue #429), so this path requires it. Guard up
# top like `gh` so BOTH phases fail with a toast instead of a broken popup if it's absent.
command -v fzf >/dev/null 2>&1 || { tmux display-message "fzf not found — cannot create issue"; exit 1; }

# phase 1: pop the input dialog that re-invokes us in `confirm` mode. Carry
# --spawn through so quick-dispatch (prefix+n) reaches phase 2 as a spawn.
if [ "$mode" != confirm ]; then
  spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
  tmux display-popup -w 90% -h 12 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg"
  exit 0
fi

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
# one-line fast filer, issue #297; there is no body prompt). Then hand the slow create
# off to the BACKGROUND so the popup closes INSTANTLY instead of blocking on the create
# (+ the worktree/window spawn).
[ "$spawn" = 1 ] && verb="New issue + worker" || verb="New issue"
title_prefix='  title ▸ '
hdr="$verb in $REPO — type a title · Enter = file · Esc = cancel"
# fzf as a pure text input (issue #429): empty candidate list (< /dev/null), --print-query
# echoes the typed line. Exit 130 = Esc/Ctrl-C → cancel; 0/1 = accepted (1 = Enter with no
# match, our normal case — --print-query still prints the query). fzf reads keys from
# /dev/tty, so it works inside `display-popup -E`; it owns UTF-8/IME/paste echo, so there is
# no double-echo (issue #422), Esc is instant (no 1s wait — issue #419), and a multi-line
# paste folds into the single-line query.
title=$(fzf --print-query --no-multi --layout=reverse --no-info --no-separator \
            --height=100% --border=none --prompt="$title_prefix" --header="$hdr" \
            < /dev/null 2>/dev/null); rc=$?
[ "$rc" -eq 130 ] && exit 0          # Esc / Ctrl-C → cancel the create
title=${title%%$'\n'*}               # the query is the first (only) line
[ -z "$title" ] && exit 0            # empty title (incl. fzf error) → cancel

# Stage the title in a temp file — it is arbitrary user text, so it is NEVER
# interpolated into the run-shell command string (only the mktemp path, which has no
# metachars, is). The bg re-exec toasts its own outcome (the popup is gone by then).
tf=$(mktemp "${TMPDIR:-/tmp}/dash-new.XXXXXX") || { tmux display-message "backlog: cannot stage the new issue"; exit 1; }
printf '%s' "$title" > "$tf"
spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
fleet_bg "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg --title-file='$tf'"
exit 0
