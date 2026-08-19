#!/bin/bash
# dash-rename.sh <target sess:idx> — the ⌃e (rename window) handler for the dash
# (issue #449). Called from an fzf `transform` binding: it arms RENAME MODE by
# stashing the highlighted row's target, then emits the fzf actions that turn the
# dash's own (normally hidden) query line into the name editor:
#
#   ⌃e  → this script: stash target, `show-input` + `change-prompt(rename ▸ )`
#         + `change-query(<current name>)` — type to edit the pre-filled name
#   ↵   → dash-enter.sh rename branch: `tmux rename-window`, drop the flag,
#         `hide-input` + restore the `▸ ` prompt (an EMPTY name cancels)
#   esc → dash-esc.sh: drop the flag, restore the prompt, rename nothing
#
# The dash's query line already IS an fzf-owned input (UTF-8 / IME / paste
# correct — the same reason ⌃n moved to `fzf --print-query` in #429), so rename
# needs no display-popup and no @popup_open bookkeeping. `--no-input` is what
# hides it; `show-input` toggles that off so keys type into the query.
#
# `unbind(?)` is NOT optional. show-input does not demote a PRINTABLE key that
# --bind already claimed: with `?` still bound (the dash's cheatsheet popup),
# typing `?` into a window name fires the popup instead of inserting a character
# — verified on fzf 0.74.3. `?` is the dash's only printable bind, so unbinding
# it for the duration is what makes the query line accept every character; the
# Enter/Esc handlers `rebind(?)` when they hide the input again.
#
# NB: this must be a SCRIPT, not an inline action — fzf matches the FIRST ')' in
# `transform(...)`, and a window name containing ')' would truncate the binding
# (the same reason dash-esc.sh exists). Names are stripped of parens below for
# the same reason on the `change-query(...)` side.
#
# Prints nothing (⇒ no fzf action at all) when rename is a no-op: already armed,
# a landed row, no target, or a row that is not a live window.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"
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
printf 'show-input+unbind(?)+change-prompt(rename ▸ )+change-query(%s)\n' "$name"
