#!/bin/bash
# pane-border-focus-selftest.sh — no border paints keyboard focus (issue #1764).
#
# Focus is the cursor on the input line (#1756), so the split between the task
# list and the worker, and the top border line, keep ONE colour whichever pane
# holds the keys. For every conf that draws pane borders — the client's
# conf/tmux-shell.conf, the node's conf/tmux-attention.conf, and the hub's
# fleetclient mirror of the client conf — this asserts:
#
#   • pane-active-border-style is the same as pane-border-style
#   • pane-border-indicators is off (tmux's half-coloured split, 3.3+)
#   • the TASKS label in pane-border-format has no focus-dependent background
#     (no client_key_table branch, no bg=)
#
# Then it sources each conf's border lines on a private tmux server (when tmux is
# there) and checks the options as tmux reads them, so a quoting slip that the
# text check would miss still fails. fleet-client-mirror.sh --check pins the
# mirror byte for byte.
#
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
CONFS="conf/tmux-shell.conf conf/tmux-attention.conf tokenledger/internal/api/fleetclient/conf/tmux-shell.conf"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
# the value of `set -g <opt> <value>` (outer quotes stripped); last one wins, as in tmux
optval() {
  sed -n "s/^[[:space:]]*set\(-option\)\{0,1\}[[:space:]]\{1,\}-g[[:space:]]\{1,\}$2[[:space:]]\{1,\}//p" "$1" | tail -n 1 |
    sed -e "s/^\"\(.*\)\"[[:space:]]*\$/\1/" -e "s/^'\(.*\)'[[:space:]]*\$/\1/"
}

for rel in $CONFS; do
  f="$ROOT/$rel"
  [ -f "$f" ] || { [ "${rel#tokenledger/}" != "$rel" ] && continue; fail "$rel not found"; }
  ps="$(optval "$f" pane-border-style)"
  pa="$(optval "$f" pane-active-border-style)"
  [ -n "$ps" ] || fail "$rel: no pane-border-style"
  [ "$pa" = "$ps" ] || fail "$rel: pane-active-border-style [$pa] differs from pane-border-style [$ps]"
  [ "$(optval "$f" pane-border-indicators)" = off ] || fail "$rel: pane-border-indicators is not off"
  fmt="$(optval "$f" pane-border-format)"
  case "$fmt" in *TASKS*) : ;; *) fail "$rel: pane-border-format lost its TASKS label" ;; esac
  # what the @sidebar branch draws before its TASKS word — a style, never a focus test
  tasks="$(printf '%s' "$fmt" | sed -n 's/.*#{==:#{@sidebar},1},\(.*\)TASKS.*/\1/p')"
  case "$tasks" in
    *'#['*) : ;;
    *) fail "$rel: could not find the TASKS branch of pane-border-format" ;;
  esac
  case "$tasks" in
    *bg=*|*client_key_table*) fail "$rel: TASKS label is focus-dependent: [$tasks]" ;;
  esac

  REAL_TMUX="$(command -v tmux 2>/dev/null)"
  [ -n "$REAL_TMUX" ] || continue
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pbf-selftest.XXXXXX")" || exit 2
  SOCK="$WORK/s"
  grep -E '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+pane-(active-)?border-(style|indicators|format)[[:space:]]' "$f" > "$WORK/b.conf"
  "$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -x 80 -y 20 \; source-file "$WORK/b.conf" 2>"$WORK/err"
  got="$("$REAL_TMUX" -S "$SOCK" show-options -gv pane-border-style)|$("$REAL_TMUX" -S "$SOCK" show-options -gv pane-active-border-style)|$("$REAL_TMUX" -S "$SOCK" show-options -gv pane-border-indicators)"
  "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"
  [ "$got" = "$ps|$ps|off" ] || fail "$rel: as tmux reads it [$got], want [$ps|$ps|off]"
done

if [ -x "$BIN/fleet-client-mirror.sh" ] && [ -d "$ROOT/tokenledger/internal/api/fleetclient" ]; then
  "$BIN/fleet-client-mirror.sh" --check >/dev/null || fail "fleet-client-mirror.sh --check: the fleetclient mirror drifted"
fi

printf 'selftest OK: no pane border paints keyboard focus — active = inactive, indicators off, TASKS dim (#1764)\n'
