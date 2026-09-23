#!/bin/bash
# dash-rename.sh <target sess:idx> — the ⌃e (rename window) handler for the dash
# (issue #449). Called from an fzf `transform` binding: it arms RENAME MODE by
# stashing the highlighted row's target, then emits the fzf actions that turn the
# dash's own query line — the always-visible quick-scratch prompt — into the name
# editor for the length of the edit:
#
#   ⌃e  → this script: stash target, `change-prompt(rename ▸ )`
#         + `change-query(<current name>)` — type to edit the pre-filled name
#   ↵   → dash-enter.sh rename branch: `tmux rename-window`, drop the flag,
#         restore the `▸ ` prompt (an EMPTY name cancels)
#   esc → dash-esc.sh: drop the flag, restore the prompt, rename nothing
#
# The dash's query line already IS an fzf-owned input (UTF-8 / IME / paste
# correct — the same reason ⌃n moved to `fzf --print-query` in #429), so rename
# needs no display-popup and no @popup_open bookkeeping. While the flag is armed,
# dash-enter.sh treats the query as the NAME, not as a task to seed a scratch with.
#
# `unbind(?)` is NOT optional. A PRINTABLE key that --bind claimed fires its action
# instead of typing — verified on fzf 0.74.3. The dash binds `?` as a transform
# that only opens the cheatsheet on an EMPTY query, but a name being edited can be
# emptied mid-way, so for the duration of a rename it is unbound outright; the
# Enter/Esc handlers `rebind(?)` when they restore the prompt.
#
# NB: this must be a SCRIPT, not an inline action — fzf matches the FIRST ')' in
# `transform(...)`, and a window name containing ')' would truncate the binding
# (the same reason dash-esc.sh exists). Names are stripped of parens below for
# the same reason on the `change-query(...)` side.
#
# Prints nothing (⇒ no fzf action at all) when rename is a no-op: already armed,
# a landed row, no target, or a row that is not a live window.
#
# `--wid <@id|handle> [name]` is the SECOND entry (issue #898): the task sidebar's
# row menu edits the name in the sidebar's own input line and hands it here as
# an argv word — no tmux or shell parser ever sees it. Renames that window by its
# stable id (never an index) with the same rule as dash-enter.sh's rename
# branch: an EMPTY name cancels. Without [name] it reads `@rename_to` off the
# window (and clears it) — a seam for callers that can only set an option.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"

if [ "${1:-}" = --wid ]; then
  BIN="$(cd "$(dirname "$0")" && pwd)"
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" 2>/dev/null || true
  w="${2:-}"
  command -v fleet_wid_target >/dev/null 2>&1 && w="$(fleet_wid_target "$w")"
  case "$w" in @[0-9]*) ;; *) exit 0 ;; esac
  if [ "$#" -ge 3 ]; then name="$3"
  else name=$(tmux show-options -wqv -t "$w" @rename_to 2>/dev/null)
  fi
  tmux set-option -uw -t "$w" @rename_to 2>/dev/null || :
  [ -n "$name" ] || exit 0
  tmux rename-window -t "$w" -- "$name" 2>/dev/null || exit 0
  exit 0
fi
target="${1:-}"

# LANDED view (dash ⌃t): rows are finished sessions, not live windows, so ⌃e is
# inert there — same per-fleet keyed read dash-enter.sh does (FLEET_SESSION).
[ "$(cat "$C/global/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ] && exit 0

# Already armed → no-op. ⌃e is fzf's default end-of-line binding, so a stray
# second press must not re-arm and blow away a half-typed name.
[ -f "$flag" ] && exit 0

case "$target" in
  landed:*|"") exit 0 ;;   # a landed row leaking through / no highlighted row
esac

# Read the CURRENT name to pre-fill the editor — and use it as the liveness
# check: a stale row whose window is gone can't be renamed, so don't arm at all
# (an armed flag with no window would swallow the next Enter). Resolve it by
# LISTING the session and matching the index exactly, NOT via `display-message
# -t <sess>:<idx>`: tmux silently falls back to the session's CURRENT window for
# an index that no longer exists (rc 0), which would pre-fill some other window's
# name against a dead target. Session names can't contain ':', so the split is safe.
name=$(tmux list-windows -t "${target%%:*}" -F '#{window_index} #{window_name}' 2>/dev/null \
  | awk -v i="${target##*:}" '$1==i{sub(/^[0-9]+ /,""); print; exit}')
[ -n "$name" ] || exit 0

mkdir -p "$C" 2>/dev/null || true
printf '%s\n' "$target" > "$flag" || exit 0
name=${name//[()]/}   # keep change-query(...) parseable (fzf stops at the first ')')
printf 'unbind(?)+change-prompt(rename ▸ )+change-query(%s)\n' "$name"
