#!/bin/bash
# fleet-claude.sh — launch `claude` under the fleet's currently-active
# subscription account, then hand off with exec. Transparent passthrough when
# no accounts are registered (bin/fleet-account.sh prints nothing) — so the
# spawn scripts can route EVERY session through this without changing behavior
# for single-account installs.
#
# It exports CLAUDE_CODE_OAUTH_TOKEN for the active account and stamps the
# window's @cc_account option with that account's label, so the collector can
# attribute a "hit your … limit" banner back to the right account and rotate.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

label=$("$BIN/fleet-account.sh" active 2>/dev/null)
if [ -n "$label" ]; then
  tok=$("$BIN/fleet-account.sh" token "$label" 2>/dev/null)
  if [ -n "$tok" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    tmux set-option -w @cc_account "$label" 2>/dev/null || true
  fi
fi

exec claude "$@"
