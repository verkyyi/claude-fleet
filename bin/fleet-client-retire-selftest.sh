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
#   D. bin/fleet's client start runs it in the background, --if-unattached
#      (FLEET_RETIRE_OLD=0 leaves it) — since #4827 with or without the old
#      client's cache
#   E. (issue #4827) any client's leftover on a client-only install: an ssh
#      master with no parent and no terminal, ControlPath in the fleet's cache,
#      and a loop of the install's — counted, the `background` row WARNs, stop
#      takes them (and what runs under them), the row PASSes; a process with a
#      live parent is left; on a 承载 install (bin/fleet-up.sh) none is ours
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
# a stand-in for any script of the old client's mirror (its fleet-shell.sh is gone
# since #3008): a loop running from the cache's bin/, which is what stop looks for
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$C/bin/old-client-loop.sh"
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); case "$st" in ''|Z*) return 1 ;; esac; return 0; }
gone() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$1" || return 0; sleep 0.5; done; return 1; }
# old [stage-only] — the old client up: the stage server, the main server whose
# pane attaches the stage (its viewer), a warm loop and one warm line
old() {
  tmux -L fleet-shell-stage new-session -d -s fleet-shell-stage -x 80 -y 24 'sleep 600' || fail "tmux: stage"
  tmux -L fleet-shell new-session -d -s fleet-shell -x 80 -y 24 \
    "env -u TMUX -u TMUX_PANE tmux -L fleet-shell-stage attach-session -t =fleet-shell-stage" || fail "tmux: main"
  local _; for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -n "$(tmux -L fleet-shell-stage list-clients -F x 2>/dev/null)" ] && break; sleep 0.3
  done
  [ -n "$(tmux -L fleet-shell-stage list-clients -F x 2>/dev/null)" ] || fail "the viewer never attached the stage"
  bash "$C/bin/old-client-loop.sh" warm fleet-shell </dev/null >/dev/null 2>&1 & WP=$!
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
for _ in 1 2 3 4 5 6 7 8 9 10; do
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
calls() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/retire.calls" ] && break; sleep 0.2; done; cat "$WORK/retire.calls" 2>/dev/null; }
rm -f "$WORK/retire.calls"; FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1
eq "D: the client start retires the old client, unattended only" "stop --quiet --if-unattached|" "$(calls)"
rm -f "$WORK/retire.calls"; FLEET_RETIRE_OLD=0 FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1; sleep 1
eq "D: FLEET_RETIRE_OLD=0 → not asked" "" "$(cat "$WORK/retire.calls" 2>/dev/null)"
rm -rf "${C:?}/bin"; rm -f "$WORK/retire.calls"; FLEET_CLIENT_UPDATED=1 sh "$D/bin/fleet" </dev/null >/dev/null 2>&1
eq "D: no old client's cache → still asked (any client's leftovers, #4827)" "stop --quiet --if-unattached|" "$(calls)"

# --- E. any client's leftovers (issue #4827) -----------------------------------
I="$HOME/.claude/fleet"; mkdir -p "$I/bin" "$XDG_CACHE_HOME/claude-fleet/cm"
cp "$BIN/fleet-client-retire.sh" "$BIN/fleet-ui-lang.sh" "$I/bin/"
[ -f "$BIN/../conf/ui-strings.tsv" ] && mkdir -p "$I/conf" && cp "$BIN"/../conf/ui-* "$I/conf/" 2>/dev/null
export FLEET_CONF_DIR="$WORK/conf"
CM="$XDG_CACHE_HOME/claude-fleet/cm"
# orphan <name> <argv…> — a process with no parent (PPID 1) and no terminal (setsid)
orphan() {
  local n=$1; shift
  ( ( exec -a "$n" perl -MPOSIX -e 'POSIX::setsid(); if (fork() == 0) { sleep 600; exit } sleep 600' -- "$@" </dev/null >/dev/null 2>&1 & ) & )
}
orphan ssh -o "ControlPath=$CM/u@m1:22" -o ControlPersist=10m -N m1
orphan bash "$I/bin/fleet-warm-loop.sh" warm
# a process with a live parent (a person's own, or a running client's): never ours
( exec -a ssh perl -e 'sleep 600' -- -o "ControlPath=$CM/kept" m2 ) & KP=$!; PIDS="$PIDS $KP"
sleep 1
OP=$(ps -axo pid=,ppid=,command= | OC="$CM/u@m1" OW="$I/bin/fleet-warm-loop.sh" awk 'index($0, ENVIRON["OC"]) || index($0, ENVIRON["OW"]) { print $1 }' | tr '\n' ' ')
PIDS="$PIDS $OP"
eq "E: two leftovers + their children found" 4 "$(printf '%s\n' $OP | grep -c .)"
eq "E: count — 4 processes, 1 ssh master" "$(printf '4\t1')" "$(bash "$I/bin/fleet-client-retire.sh" count)"
r=$(bash "$I/bin/fleet-client-retire.sh" background)
case "$r" in WARN*'后台进程 4'*'ssh 主连接 1'*'多余文件 0'*) CHECKS=$((CHECKS + 1)) ;; *) fail "E: background row before — got [$r]" ;; esac
# a 承载 install: its daemons run with no parent from the same paths — never ours
: > "$I/bin/fleet-up.sh"
eq "E: a 承载 install counts none of it" "$(printf '0\t0')" "$(bash "$I/bin/fleet-client-retire.sh" count)"
rm -f "$I/bin/fleet-up.sh"
FLEET_RETIRE_GRACE=1 bash "$I/bin/fleet-client-retire.sh" stop --quiet --if-unattached; eq "E: stop → 0" 0 "$?"
for p in $OP; do gone "$p" || fail "E: leftover $p still runs"; done
alive "$KP" || fail "E: a process with a live parent was stopped"
r=$(bash "$I/bin/fleet-client-retire.sh" background)
case "$r" in PASS*'后台进程 0'*'ssh 主连接 0'*'多余文件 0'*) CHECKS=$((CHECKS + 1)) ;; *) fail "E: background row after — got [$r]" ;; esac
# the files an update left: a third version dir and a staging dir
V="$HOME/.claude/fleet2"; mkdir -p "$V.versions/a/bin" "$V.versions/b/bin" "$V.versions/c/bin" "$V.versions/.staging/bin"
cp "$BIN/fleet-client-retire.sh" "$BIN/fleet-ui-lang.sh" "$V.versions/b/bin/"; touch "$V.versions/a/bin/x" "$V.versions/c/bin/y" "$V.versions/.staging/bin/z"
ln -s "$V.versions/b" "$V"; echo a > "$V.versions/.prev"
r=$(bash "$V/bin/fleet-client-retire.sh" background)
case "$r" in WARN*'多余文件 2'*) CHECKS=$((CHECKS + 1)) ;; *) fail "E: extra files beside the install — got [$r]" ;; esac

printf 'fleet-client-retire-selftest OK (%d checks)\n' "$CHECKS"
