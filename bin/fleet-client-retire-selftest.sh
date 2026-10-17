#!/bin/bash
# fleet-client-retire-selftest.sh — bin/fleet-client-retire.sh takes away what the
# deleted two-pane client still runs on a login (issue #4283), on a sandbox HOME
# and TMUX_TMPDIR with real tmux servers:
#   A. `stop --if-unattached`: the stage server's only client is the old client's
#      own viewer inside the main server — not a person, so it is stopped (before
#      #4283 it counted as one and nothing unattended was ever stopped)
#   B. its warm lines — an ssh master whose ControlPath is in the cache's tmp/ —
#      are stopped with it, not left to their ControlPersist=10m
#   C. a server a person IS attached to is left alone (exit 3)
#   D. bin/fleet's client start runs it in the background, --if-unattached, only
#      when the old client's cache is there (FLEET_RETIRE_OLD=0 leaves it)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
command -v tmux >/dev/null 2>&1 || { echo "fleet-client-retire-selftest: SKIP (no tmux)"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "fleet-client-retire-selftest: SKIP (no perl)"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cretire.XXXXXX")
TT=$(mktemp -d /tmp/crt.XXXXXX)   # short: a socket path past ~104 bytes is refused on macOS
export HOME="$WORK/home" TMUX_TMPDIR="$TT" XDG_CACHE_HOME="$WORK/home/.cache" SHELL=/bin/sh   # zsh reads a pane's `=name` as a path
unset TMUX TMUX_PANE FLEET_SHELL_CACHE
C="$XDG_CACHE_HOME/claude-fleet/shell"
mkdir -p "$C/bin" "$C/tmp/warm"
PIDS=''
cleanup() {
  for l in fleet-shell fleet-shell-stage fleet-shell-person; do tmux -L "$l" kill-server 2>/dev/null; done
  # shellcheck disable=SC2086 # numeric pids
  [ -z "$PIDS" ] || kill -9 $PIDS 2>/dev/null
  rm -rf "$WORK" "$TT"
}
trap cleanup EXIT
# the old client's own script: a loop, and a `quit` that returns at once
printf '#!/bin/bash\n[ "$1" = quit ] && exit 0\nwhile :; do sleep 1; done\n' > "$C/bin/fleet-shell.sh"
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); case "$st" in ''|Z*) return 1 ;; esac; return 0; }
gone() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do alive "$1" || return 0; sleep 0.5; done; return 1; }
# old [stage-only] — the old client up: the stage server, the main server whose
# pane attaches the stage (its viewer), a warm loop and one warm line
old() {
  tmux -L fleet-shell-stage new-session -d -s fleet-shell-stage -x 80 -y 24 'sleep 600' || fail "tmux: stage"
  tmux -L fleet-shell new-session -d -s fleet-shell -x 80 -y 24 \
    "env -u TMUX -u TMUX_PANE tmux -L fleet-shell-stage attach-session -t =fleet-shell-stage" || fail "tmux: main"
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(tmux -L fleet-shell-stage list-clients -F x 2>/dev/null)" ] && break; sleep 0.3
  done
  [ -n "$(tmux -L fleet-shell-stage list-clients -F x 2>/dev/null)" ] || fail "the viewer never attached the stage"
  bash "$C/bin/fleet-shell.sh" warm fleet-shell </dev/null >/dev/null 2>&1 & WP=$!
  ( exec -a ssh perl -e 'sleep 600' -- -o "ControlPath=$C/tmp/warm/u-x@y.sock" -o ControlPersist=10m u-x ) & SP=$!
  disown "$WP" "$SP" 2>/dev/null
  PIDS="$PIDS $WP $SP"
  sleep 0.5
}

# --- A + B ----------------------------------------------------------------------
old
bash "$BIN/fleet-client-retire.sh" running; eq "A: running before" 0 "$?"
FLEET_RETIRE_GRACE=1 bash "$BIN/fleet-client-retire.sh" stop --quiet --if-unattached; eq "A: the viewer's own attach is no person → stopped (exit 0)" 0 "$?"
tmux -L fleet-shell-stage has-session 2>/dev/null && fail "A: the stage server still runs"
tmux -L fleet-shell has-session 2>/dev/null && fail "A: the main server still runs"
gone "$WP" || fail "A: the warm loop still runs"
gone "$SP" || fail "B: the warm line (ssh master, ControlPath in the cache's tmp/) still runs"
bash "$BIN/fleet-client-retire.sh" running; eq "A: nothing runs after" 1 "$?"

# --- C. a person attached to the main server ---------------------------------
old
# a person's client: a pty of its own (a tmux on another socket holds it)
tmux -L fleet-shell-person new-session -d -s p -x 80 -y 24 "env -u TMUX -u TMUX_PANE tmux -L fleet-shell attach-session -t =fleet-shell"
for i in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(tmux -L fleet-shell list-clients -F x 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break; sleep 0.3
done
bash "$BIN/fleet-client-retire.sh" stop --quiet --if-unattached; eq "C: a person looking → left alone (exit 3)" 3 "$?"
alive "$WP" || fail "C: the warm loop was stopped under a person"
tmux -L fleet-shell-person kill-server 2>/dev/null
FLEET_RETIRE_GRACE=1 bash "$BIN/fleet-client-retire.sh" stop --quiet; eq "C: stop without --if-unattached → 0" 0 "$?"

# --- D. bin/fleet's client start ------------------------------------------------
D="$WORK/inst"; mkdir -p "$D/bin"; export FLEET_NODE_STATE="$WORK/no-node"   # not a managed machine (that one is fleet-node-shell-retire.sh's)
cp "$BIN/fleet" "$D/bin/fleet"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$*" "${FLEET_RETIRE_OLD:-}" >> "%s/retire.calls"\n' "$WORK" > "$D/bin/fleet-client-retire.sh"
printf 'import sys\n' > "$D/bin/fleet-thin.py"
calls() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/retire.calls" ] && break; sleep 0.2; done; cat "$WORK/retire.calls" 2>/dev/null; }
rm -f "$WORK/retire.calls"; FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1
eq "D: the client start retires the old client, unattended only" "stop --quiet --if-unattached|" "$(calls)"
rm -f "$WORK/retire.calls"; FLEET_RETIRE_OLD=0 FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1; sleep 1
eq "D: FLEET_RETIRE_OLD=0 → not asked" "" "$(cat "$WORK/retire.calls" 2>/dev/null)"
rm -rf "$C/bin"; rm -f "$WORK/retire.calls"; FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1; sleep 1
eq "D: no old client's cache → not asked (byte for byte as before)" "" "$(cat "$WORK/retire.calls" 2>/dev/null)"

printf 'fleet-client-retire-selftest OK (%d checks)\n' "$CHECKS"
