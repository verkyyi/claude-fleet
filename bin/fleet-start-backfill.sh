#!/bin/bash
# fleet-start-backfill.sh <sess> <window_id> <owner/name> <title-file> <body-file>
# — 手续后补 (issue #2234, EPIC #2230 C4 → C5): the paperwork of a start that was
# answered from the warm pool. The session is already working on the person's
# words; this files its issue and binds the window to it in place — the one road a
# scratch becomes a worker by (fleet-issue-file.sh --bind → fleet-bind.sh: the
# `scratch-K` branch renamed `issue-N`, @issue stamped, the claim written), its
# @fleet_id untouched (EPIC #2230 共同约定 6).
#
# Run DETACHED by fleet-control-read.sh `start … new` once the first turn is in,
# never on the start's clock. fleet-bind.sh acts on the CALLING pane, so it runs
# here as that window's pane: TMUX = this fleet's socket, TMUX_PANE = its pane.
# The two files are this script's own and removed whatever happens; every outcome
# is one line in $FLEET_CONF_DIR/control/backfill.log.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
sess="${1:-}" win="${2:-}" repo="${3:-}" titlef="${4:-}" bodyf="${5:-}"
trap 'rm -f "$titlef" "$bodyf"' EXIT
log() {
  local d="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/control"
  mkdir -p "$d" 2>/dev/null
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sess" "$win" "$*" >> "$d/backfill.log" 2>/dev/null
}
case "$win" in @[0-9]*) ;; *) log "refused: no window"; exit 2 ;; esac
[ -n "$sess" ] && [ -n "$repo" ] && [ -f "$titlef" ] || { log "refused: usage"; exit 2; }
title=$(cat "$titlef"); body=''
[ -f "$bodyf" ] && body=$(cat "$bodyf")
sock=$(fleet_socket "$sess")
sp=$(tmux -L "$sock" display-message -p '#{socket_path}' 2>/dev/null)
pane=$(tmux -L "$sock" display-message -p -t "$win" '#{pane_id}' 2>/dev/null)
case "$pane" in %[0-9]*) ;; *) log "refused: $win is gone"; exit 1 ;; esac
out=$(TMUX="$sp,0,0" TMUX_PANE="$pane" FLEET_SESSION="$sess" \
      bash "$BIN/fleet-issue-file.sh" --repo "$repo" --from hub --title "$title" ${body:+--body "$body"} --bind 2>&1)
rc=$?
log "rc=$rc $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
exit "$rc"
