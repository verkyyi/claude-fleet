#!/bin/bash
# dash-esc.sh — Esc handler for the dash. If a rename/bind mode is in progress,
# cancel it (clear flags, restore prompt) and emit fzf actions; otherwise abort.
# NB: fzf matches the FIRST ')' in transform(...) — nested parens in inline
# actions break it, which is why this logic lives in a helper script.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"
if [ -f "$C/rename_target" ] || [ -f "$C/bind_target" ]; then
  rm -f "$C/rename_target" "$C/bind_target"
  echo "change-prompt(＋ new ▸ )+clear-query"   # back out, no relaunch
else
  echo "abort"
fi
