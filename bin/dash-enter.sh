#!/bin/bash
# dash-enter.sh <target sess:idx> <query> — Enter handler for the dash.
# Emits fzf actions on stdout (called from an fzf `transform` binding) and does
# the tmux side-effect. Modes:
#   bind mode    (bind flag, set by ctrl-g): bind/unbind <target> to issue query
#   rename mode  (rename flag, set by ctrl-e): rename <stored target> to query
#   typed task   (no flag, query non-empty): spawn a scratch session SEEDED with
#                the query (dash-raw-session.sh --prompt) — the dash's always-
#                visible prompt line is the quick-scratch box
#   jump         (default, empty query): select the target window
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; flag="$C/rename_target"; bindflag="$C/bind_target"
target="${1:-}"; q="${2:-}"
PROMPT='▸ '
# `rebind(?)` pairs with the `unbind(?)` dash-rename.sh emits when it arms: `?` is
# the dash's cheatsheet bind, and a bound printable key keeps firing its action
# instead of typing (fzf 0.74.3), so it is unbound for the length of the edit and
# restored here. Rebinding a key that was never unbound (a stale flag inherited by
# a freshly relaunched dash) is a harmless no-op. (The input line itself is always
# visible now — there is no show/hide to undo, only the prompt label.)
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"

# Typed task → seeded scratch. Checked FIRST, before any view logic: the prompt line
# means the same thing in the live and the landed view, and it is mode-free — a
# rename/bind in progress owns the query line instead (those branches below). The
# spawn is the ⌃s path with a prompt (--bg: cheap checks sync, slow half
# backgrounded, so the keystroke returns instantly); the query is handed over as an
# ARGUMENT ({q} is fzf-quoted), never interpolated into an action string.
if [ ! -f "$flag" ] && [ ! -f "$bindflag" ] && [ -n "${q//[[:space:]]/}" ]; then
  bash "$BIN/dash-raw-session.sh" --bg --prompt "$q" >/dev/null 2>&1
  echo "clear-query+reload(bash $ROWS)"; exit 0
fi

# LANDED view (dash ⌃t): rows carry a `landed:<pr>` / `landed:issue:<n>` /
# `landed:scratch:scratch-<n>` (#466) target, not a
# live window — Enter RESUMES that finished session, identical to ⌃o: it hands the target
# to dash-restore-session.sh, which reconstructs the removed worktree off the squash SHA and
# reopens a `claude --resume` window (#261). Every row shape resumes (dash-restore-session.sh's
# restore_key_for handles landed:issue:<n>, landed:<pr> and landed:scratch:<key>). Open the row's PR in the browser
# with ⌃p (dash-open-pr.sh) — the pre-#261 Enter behavior (#130), relocated so Enter can jump.
# Per-fleet keyed (FLEET_SESSION), matching dash-view-toggle.sh. Clear any half-set rename/bind
# flag first so a mode toggled in landed view can't leak into the next live-view Enter.
#
# Dropping the flag is NOT the whole undo (issue #454). Arming rename also UNBOUND `?` —
# the dash's cheatsheet key, which fzf otherwise keeps firing instead of typing
# (dash-rename.sh) — and relabelled the prompt. Only an explicit rebind puts it back, and
# this branch used to emit none: arm ⌃e → toggle ⌃t → Enter left `?` DEAD (and the
# `rename ▸ ` prompt up) for the rest of that fzf's life, one of the two ways `?`
# silently stopped opening the cheatsheet. So carry the same restore the Enter/Esc
# rename branches emit — but only when a flag was actually live, so a plain landed
# Enter keeps emitting exactly what it always did.
RESTORE=""
if [ "$(cat "$C/global/dash_view_${FLEET_SESSION:-default}" 2>/dev/null)" = landed ]; then
  if [ -f "$flag" ] || [ -f "$bindflag" ]; then
    RESTORE="rebind(?)+change-prompt($PROMPT)+"
  fi
  rm -f "$flag" "$bindflag"
  case "$target" in
    landed:*)   # landed:<pr> | landed:issue:<n> | landed:scratch:<key> — resume it (= ⌃o, #261)
      bash "$BIN/dash-restore-session.sh" "$target" >/dev/null 2>&1
      echo "${RESTORE}clear-query+reload(bash $ROWS)"; exit 0 ;;
  esac
fi

if [ -f "$bindflag" ]; then                       # bind-issue mode (empty q unbinds)
  t=$(cat "$bindflag"); rm -f "$bindflag"
  tmux set-window-option -t "$t" @issue "$q" 2>/dev/null
  echo "rebind(?)+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
elif [ -f "$flag" ]; then                         # rename mode
  t=$(cat "$flag"); rm -f "$flag"
  # `--` ends the flag list: without it a name starting with `-` is parsed as a
  # tmux flag ("unknown flag -d") and the rename silently fails.
  if [ -n "$q" ]; then tmux rename-window -t "$t" -- "$q" 2>/dev/null
    echo "rebind(?)+change-prompt($PROMPT)+clear-query+reload(bash $ROWS)"
  else echo "rebind(?)+change-prompt($PROMPT)+clear-query"; fi
else                                              # jump (empty query)
  # $RESTORE is empty on every normal jump; it is non-empty only for the landed-view
  # fall-through above (a non-`landed:` row while a rename/bind was armed), which must
  # put `?` and the prompt back just like the branches that own those modes (#454).
  tmux select-window -t "$target" 2>/dev/null
  echo "${RESTORE}clear-query"
fi
