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

# Force a UTF-8 locale so read_title's per-char loop strips a WHOLE character on
# backspace, not a single byte (issue #408). SSH/Termius forward LANG but usually
# not LC_CTYPE/LC_ALL, so a tmux popup off a server started without them runs in the
# C locale — where `${title%?}` over a CJK glyph leaves a broken half-char and the
# popup appears to hang. Matches the sibling tmux-*-rows.sh exports; en_US.UTF-8 is
# universal on macOS (C.UTF-8 doesn't exist there). Set before the phase split so
# BOTH the interactive read and any re-exec inherit it.
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

# phase 1: pop the input dialog that re-invokes us in `confirm` mode. Carry
# --spawn through so quick-dispatch (prefix+n) reaches phase 2 as a spawn.
if [ "$mode" != confirm ]; then
  spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
  tmux display-popup -w 90% -h 12 -E "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg"
  exit 0
fi

# utf8_len <byte> -> total byte length (1..4) of the char this LEAD byte starts;
# 1 for ASCII/stray. C-locale byte value so high bytes are unsigned 128..255,
# folded (+256) to survive printf signedness. macOS bash 3.2 reads bytes, not
# chars, so we reassemble the glyph ourselves and echo it atomically — a per-byte
# echo splits a multibyte sequence across tmux read boundaries and renders □/dupes
# (issue #422).
utf8_len() {
  local b; b=$(LC_ALL=C printf '%d' "'$1" 2>/dev/null); [ "$b" -lt 0 ] && b=$((b+256))
  if   [ "$b" -ge 240 ]; then echo 4
  elif [ "$b" -ge 224 ]; then echo 3
  elif [ "$b" -ge 192 ]; then echo 2
  else echo 1; fi
}

# read_title <prompt-prefix>: read the title char-by-char so Esc cancels the WHOLE
# create on the spot (issue #297) and a multi-line PASTE folds into one line instead
# of the first embedded newline truncating + submitting it (issue #419). A plain
# `read` only acts on Enter, so an Esc keypress would be swallowed into the line
# instead of aborting. Enter submits, Backspace erases, Esc (0x1b) cancels. IFS= is
# load-bearing — it keeps a typed space as ' ', so ONLY a real newline reads back as
# '' (Enter). Sets $title; returns 1 on Esc-cancel, 0 otherwise.
#
# Esc is disambiguated by a one-byte PEEK (issue #419): bracketed-paste markers and
# arrow keys both START with ESC, so a bare `$'\x1b') return 1` would make every paste
# (which the terminal brackets as ESC[200~ … ESC[201~ once we enable DEC mode 2004)
# cancel the popup. So on ESC we peek the next byte with `read -t 1`:
#   • nothing follows within 1s (a real lone Esc, or EOF) → cancel (return 1);
#   • ESC '[' … CSI → read it to its final byte: '200~' is a paste-start, so hand the
#     body to read_paste; any other CSI (arrow keys, …) has no meaning in a one-line
#     field → ignore. A non-'[' escape (Alt / SS3) is likewise ignored.
# `-t 1` is an INTEGER timeout because macOS ships bash 3.2.57 (no sub-second `-t`):
# a lone-Esc cancel waits ≤1s, a pasted/arrow burst returns instantly.
#
# Backspace REDRAWS the whole input line — \r to column 0, reprint <prefix>$title,
# then \033[K to clear the tail — instead of the old incremental `printf '\b \b'`
# (issue #408). Byte-wise cursor math can't erase a WIDE glyph: a CJK char occupies
# 2 terminal cells but '\b \b' backs up only 1, so the cursor desynced and the popup
# appeared to hang. A full redraw needs no cursor width math — the terminal re-lays
# the current (valid) $title — so wide CJK/full-width chars, emoji, and mixed
# ASCII+CJK all erase correctly. Pairs with the forced UTF-8 locale up top, which
# makes `${title%?}` strip a whole character (not a byte) before the redraw.
#
# The INPUT echo assembles a WHOLE glyph before writing it (issue #422): bash 3.2
# reads one BYTE per `read -rsn1`, so echoing each byte split a multibyte sequence
# across tmux's pane-read boundaries and rendered □/duplicated cells. We read the
# lead byte's continuation bytes (utf8_len) and `printf '%s'` the complete char once.
# ASCII is unchanged (utf8_len 1, inner loop skipped), so the fast path is untouched.
read_title() {
  local prefix="$1" ch seq c2 cbuf clen i
  title=""
  while IFS= read -rsn1 ch; do
    case "$ch" in
      '')               printf '\n'; return 0 ;;                            # Enter → submit
      $'\x1b')                                                              # Esc → peek: lone-Esc cancel vs a paste/CSI marker
        if IFS= read -rsn1 -t 1 seq; then                                   # a byte followed → an escape sequence, not a lone Esc
          if [ "$seq" = '[' ]; then
            seq=""                                                          # accumulate the CSI params after '['
            while IFS= read -rsn1 -t 1 c2; do
              seq="$seq$c2"
              case "$c2" in [~a-zA-Z]) break ;; esac                        # CSI final byte
            done
            [ "$seq" = '200~' ] && read_paste "$prefix"                     # paste start → consume the body; other CSI → ignore
          fi
          # non-'[' escape (Alt / SS3) → ignore: no meaning in a one-line field
        else
          return 1                                                         # lone Esc (nothing followed within 1s / EOF) → cancel
        fi ;;
      $'\x7f'|$'\x08')  [ -n "$title" ] && { title="${title%?}"; printf '\r%s%s\033[K' "$prefix" "$title"; } ;;  # Backspace → width-correct redraw
      *)                # assemble the WHOLE glyph (read its continuation bytes) before echoing it once (issue #422)
        cbuf="$ch"; clen=$(utf8_len "$ch"); i=1
        while [ "$i" -lt "$clen" ]; do IFS= read -rsn1 ch || break; cbuf="$cbuf$ch"; i=$((i+1)); done
        title="$title$cbuf"; printf '%s' "$cbuf" ;;
    esac
  done
  printf '\n'; return 0                                                     # EOF → submit what we have
}

# read_paste <prompt-prefix>: consume a bracketed-paste body — we're already past the
# ESC[200~ start marker — up to the ESC[201~ end marker, folding it into the one-line
# title (issue #419). Every embedded newline (''), CR ($'\r'), and tab folds to a
# SINGLE space with no leading space, no runs, and no trailing space: a lazy `pending`
# flag is set on whitespace and flushed only just before the next real char (and only
# when $title already holds content), so a paste that ends in a newline drops its
# trailing space cleanly. Ordinary bytes accumulate onto the GLOBAL $title and echo
# like the typed fast path — assembling a whole UTF-8 glyph before the single echo
# (issue #422), so a multibyte char is never split across writes. The end marker is
# spotted the same way read_title spots the start — ESC → `-t 1` peek → '[' → CSI →
# '201~'. Does NOT auto-submit: it returns to
# read_title so the operator reviews the pasted title and presses Enter (or edits it).
read_paste() {
  local prefix="$1" ch seq c2 pending=0 cbuf clen i
  while IFS= read -rsn1 ch; do
    case "$ch" in
      $'\x1b')                                                              # maybe the ESC[201~ end marker
        if IFS= read -rsn1 -t 1 seq && [ "$seq" = '[' ]; then
          seq=""
          while IFS= read -rsn1 -t 1 c2; do
            seq="$seq$c2"
            case "$c2" in [~a-zA-Z]) break ;; esac
          done
          [ "$seq" = '201~' ] && break                                     # end of paste → back to read_title
          # any other CSI inside a paste → ignore, keep consuming
        fi ;;                                                              # lone Esc / non-'[' inside a paste → ignore
      ''|$'\r'|$'\t')   pending=1 ;;                                        # embedded newline/CR/tab → lazy single space
      *)                                                                    # ordinary byte → flush a pending space (never leading), then accumulate
        if [ "$pending" = 1 ]; then
          [ -n "$title" ] && { title="$title "; printf ' '; }
          pending=0
        fi
        # assemble the WHOLE glyph before echoing it once (issue #422) — same as read_title
        cbuf="$ch"; clen=$(utf8_len "$ch"); i=1
        while [ "$i" -lt "$clen" ]; do IFS= read -rsn1 ch || break; cbuf="$cbuf$ch"; i=$((i+1)); done
        title="$title$cbuf"; printf '%s' "$cbuf" ;;
    esac
  done
  printf '\r%s%s\033[K' "$prefix" "$title"                                  # normalize the shown line to $title (folded, markers stripped)
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
# The prompt prefix is shared: printed once here to draw the field, and handed to
# read_title so its backspace redraw reprints the exact same leader (issue #408).
title_prefix='  title ▸ '
printf '\n  %s in \033[1m%s\033[0m\n  (empty title or Esc = cancel)\n\n%s' "$verb" "$REPO" "$title_prefix"
# Bracketed paste (issue #419): enable DEC mode 2004 so the terminal brackets a paste
# as ESC[200~ … ESC[201~ — read_title folds that into a single-line title instead of
# the first embedded newline truncating + submitting it. Disable on EVERY exit path;
# this phase always ends in `exit`, so a trap EXIT is the clean guarantee (arm it
# BEFORE enabling so cleanup can never be skipped). Terminals without bracketed paste
# send the paste raw → identical to before (first line kept), no regression.
trap 'printf "\033[?2004l"' EXIT
printf '\033[?2004h'
read_title "$title_prefix" || exit 0                # Esc → cancel the create directly
[ -z "$title" ] && exit 0                           # empty title → cancel

# Stage the title in a temp file — it is arbitrary user text, so it is NEVER
# interpolated into the run-shell command string (only the mktemp path, which has no
# metachars, is). The bg re-exec toasts its own outcome (the popup is gone by then).
tf=$(mktemp "${TMPDIR:-/tmp}/dash-new.XXXXXX") || { tmux display-message "backlog: cannot stage the new issue"; exit 1; }
printf '%s' "$title" > "$tf"
spawn_arg=""; [ "$spawn" = 1 ] && spawn_arg=" --spawn"
fleet_bg "CF_REPO='$REPO' bash '$BIN/dash-issue-new.sh' confirm$spawn_arg --title-file='$tf'"
exit 0
