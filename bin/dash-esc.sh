#!/bin/bash
# dash-esc.sh [<query>] — Esc handler for the dash. Three cases, in order:
#   * a rename/bind mode is in progress → cancel it (clear flags, restore prompt)
#   * a half-typed task on the always-visible prompt line → just clear it (a
#     second Esc then relaunches as before); never relaunch the whole dash over a
#     line the operator merely wants gone
#   * otherwise → abort (the always-on dash relaunches; the POPUP peek closes)
# NB: fzf matches the FIRST ')' in transform(...) — nested parens in inline
# actions break it, which is why this logic lives in a helper script.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"
q="${1:-}"
BIN="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$C/rename_target" ] || [ -f "$C/bind_target" ]; then
  rm -f "$C/rename_target" "$C/bind_target"
  # The restored label is the agent-labelled prompt (`claude ▸ ` / `codex ▸ `,
  # issue #554) from the same helper the dash launches with — see dash-enter.sh.
  PROMPT=$(bash "$BIN/dash-agent-prompt.sh" prompt 2>/dev/null); [ -n "$PROMPT" ] || PROMPT='▸ '
  # rebind(?) undoes dash-rename.sh's unbind — see the note in dash-enter.sh.
  echo "rebind(?)+change-prompt($PROMPT)+clear-query"   # back out, no relaunch
elif [ -n "${q//[[:space:]]/}" ]; then
  echo "clear-query"
else
  echo "abort"
fi
