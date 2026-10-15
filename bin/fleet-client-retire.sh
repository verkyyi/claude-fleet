#!/bin/bash
# fleet-client-retire.sh — what the OLD client (the two-pane tmux client,
# fleet-shell.sh — deleted with issue #3008) may still have running on THIS
# computer, and taking it away.
#
#   fleet-client-retire.sh running        exit 0 when something of it still runs here
#   fleet-client-retire.sh stop [--quiet] [--if-unattached]
#
# A computer that ran the old client before this version keeps its processes
# until they are stopped: its tmux servers (`-L fleet-shell` and the companion stage server, or `fleet-node-client[-stage]` on a managed machine, plus a
# one-session view's `<label>-solo-<pid>`), its keeper, hub loop, action loop and
# warm lines — every one running from the old client's mirror, the cache's bin/
# (~/.cache/claude-fleet/shell/bin, FLEET_SHELL_CACHE). `stop` first runs that
# mirror's own `fleet-shell.sh quit` when it is still there (it gives the hub its
# lease back), then TERMs — and after FLEET_RETIRE_GRACE (3) seconds KILLs — what
# still runs from the mirror, then takes the servers down. The cache's logs stay
# (the debug bundle reads them); the thin client (fleet-thin.py) runs nothing in
# the background and is never touched. `--if-unattached`: a server someone still
# looks at is left alone (exit 3). fleet-node-shell-retire.sh is the same for a
# managed machine's logins, run by its daemon.
#
# Exit: 0 stopped / nothing ran · 1 something still runs · 2 usage · 3 left alone
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CACHE="${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}"
SOCKDIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
LABELS="fleet-shell fleet-node-client"

# labels — every tmux server label of the old client on this login that answers
labels() {
  local l f
  for l in $LABELS; do
    printf '%s\n%s-stage\n' "$l" "$l"
    for f in "$SOCKDIR/$l"-solo-*; do [ -S "$f" ] && printf '%s\n' "${f##*/}"; done
  done | while IFS= read -r l; do
    tmux -L "$l" list-sessions >/dev/null 2>&1 && printf '%s\n' "$l"
  done
}
# pids — this login's processes running from the old client's mirror (the path
# rides the environment, so the awk's own argv never matches it)
pids() {
  ps -axo pid=,user=,command= 2>/dev/null | RETIRE_PAT="$CACHE/bin/" awk -v u="$(id -un)" -v me=$$ \
    '$2 == u && $1 != me && index($0, ENVIRON["RETIRE_PAT"]) { print $1 }'
}
attached() {
  local l
  for l in $(labels); do
    [ -n "$(tmux -L "$l" list-clients -F '#{client_name}' 2>/dev/null)" ] && return 0
  done
  return 1
}

mode=${1:-}; [ $# -gt 0 ] && shift
quiet='' ifun=''
for a in "$@"; do
  case "$a" in
    --quiet) quiet=1 ;;
    --if-unattached) ifun=1 ;;
    *) printf 'fleet-client-retire: unknown %s\n' "$a" >&2; exit 2 ;;
  esac
done
say() { [ -n "$quiet" ] || { sh "$BIN/fleet-ui-lang.sh" t "$@"; echo; }; }

case "$mode" in
  running)
    [ -n "$(labels)$(pids)" ] ;;
  stop)
    if [ -z "$(labels)$(pids)" ]; then say retire_none; exit 0; fi
    [ -n "$ifun" ] && attached && exit 3
    if [ -f "$CACHE/bin/fleet-shell.sh" ]; then
      bash "$CACHE/bin/fleet-shell.sh" quit --quiet </dev/null >/dev/null 2>&1 &
      qp=$!; i=0
      while kill -0 "$qp" 2>/dev/null && [ "$i" -lt "${FLEET_RETIRE_QUIT_WAIT:-20}" ]; do sleep 1; i=$((i + 1)); done
      kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
    fi
    left=$(pids)
    if [ -n "$left" ]; then
      # shellcheck disable=SC2086  # a list of numeric pids
      kill $left 2>/dev/null
      sleep "${FLEET_RETIRE_GRACE:-3}"
      left=$(pids)
      # shellcheck disable=SC2086
      [ -z "$left" ] || kill -9 $left 2>/dev/null
    fi
    for l in $(labels); do tmux -L "$l" kill-server 2>/dev/null; done
    if [ -n "$(labels)$(pids)" ]; then
      [ -n "$quiet" ] || printf 'fleet · 旧客户端还有进程没停下：ps -ax | grep %s\n' "$CACHE/bin" >&2
      exit 1
    fi
    say retire_done
    exit 0 ;;
  *)
    sed -n '6,7p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2 ;;
esac
