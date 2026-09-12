#!/bin/bash
# fleet-hook-conf.sh [--session <sess>] KEY [KEY…] — resolve FLEET_* knobs the way a
# Claude Code hook MUST (issue #561): global fleet.conf → this fleet's overlay.
#
# A hook runs with the pane's environment, and NOTHING exports the conf into that
# environment: fleet.conf is assignments-only, the launcher (fleet-claude.sh) never
# `set -a`s it, and fleet-lib exports only the global-only cap keys (#399). So a
# hook that reads `${FLEET_X:-default}` from its env sees the default — always.
# That is how FLEET_AUTO_HANDOFF_PCT=60 sat inert in the global conf for weeks
# while every one of 134 handoff cycles was worker-initiated (#561; same class as
# #472, where FLEET_MODEL was a conf key only the launcher could see). The rule
# (docs/ARCHITECTURE.md → "Hooks read the conf"): a hook that needs a FLEET_* knob
# LOADS THE CONF; the launcher does not export. A bash hook sources fleet-lib.sh and
# runs fleet_load_conf "$(fleet_current_session)" itself (session-end-hook.sh); a
# `sh`-wired hook cannot (fleet-lib is bash-only), so it calls THIS script — the one
# resolution path fleet-doctor.sh also evaluates, so "conf says 60, hook sees 0"
# cannot hide again.
#
# Precedence = exactly what a sourcing script sees: the environment is the floor,
# the global fleet.conf (sibling of this bin/, auto-sourced by fleet-lib) overrides
# it, the per-fleet overlay (fleet_load_conf, global-only keys stripped per #237)
# overrides that. The session comes from --session <sess> (fleet-doctor, no tmux
# needed), else from $TMUX_PANE the way a hook resolves it — and only when $TMUX is
# set: outside tmux there is no fleet to overlay, so the default socket is never
# touched. Output: one line per KEY, the resolved value ('' when nothing sets it).
# Never fails on a missing lib / conf / server — it prints what it could resolve, so
# a caller's `${x:-0}` default is the fail-open (auto-handoff OFF, base = master).
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"

sess=''
if [ "${1:-}" = "--session" ]; then sess="${2:-}"; shift 2; fi
[ "$#" -gt 0 ] || { printf 'usage: fleet-hook-conf.sh [--session <sess>] KEY [KEY…]\n' >&2; exit 2; }

if [ -f "$BIN/fleet-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" >/dev/null 2>&1
  if [ -z "$sess" ] && [ -n "${TMUX:-}" ]; then sess=$(fleet_current_session 2>/dev/null); fi
  [ -n "$sess" ] && fleet_load_conf "$sess" >/dev/null 2>&1
fi

for k in "$@"; do
  case "$k" in
    *[!A-Za-z0-9_]*|[0-9]*|"") printf 'fleet-hook-conf: not a shell identifier: %s\n' "$k" >&2; printf '\n'; continue ;;
  esac
  printf '%s\n' "${!k:-}"
done
exit 0
