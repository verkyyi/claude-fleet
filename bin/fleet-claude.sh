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
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

# Default spawned sessions to opus (never let a new window fall back to sonnet).
# Overridable per install/fleet via FLEET_MODEL in fleet.conf; set it empty to
# defer to the user's own `claude` default. Skipped if the caller already passed
# an explicit --model (so an intentional override still wins).
model_flag=()
if [ -z "${FLEET_MODEL+x}" ]; then FLEET_MODEL="opus"; fi
if [ -n "$FLEET_MODEL" ]; then
  case " $* " in
    *" --model "*|*" --model="*) : ;;               # caller already chose a model
    *) model_flag=(--model "$FLEET_MODEL") ;;
  esac
fi

label=$("$BIN/fleet-account.sh" active 2>/dev/null)
if [ -n "$label" ]; then
  tok=$("$BIN/fleet-account.sh" token "$label" 2>/dev/null)
  if [ -n "$tok" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    tmux set-option -w @cc_account "$label" 2>/dev/null || true
  fi
fi

exec claude ${model_flag[@]+"${model_flag[@]}"} "$@"
