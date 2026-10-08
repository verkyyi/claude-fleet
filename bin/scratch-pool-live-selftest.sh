#!/bin/bash
# scratch-pool-live-selftest.sh — the warm pool (bin/scratch-pool.sh) on a REAL
# tmux server (issue #2233, EPIC #2230 C3): an isolated `-L` socket under a
# throwaway TMUX_TMPDIR and HOME, the real session wrapper (fleet-session-wrap.sh)
# launching a fake claude TUI through its FLEET_WRAP_LAUNCH seam, a real git origin.
# scratch-pool-selftest.sh proves every gate against a fake tmux; this one proves
# the pool actually comes up, hands out, refills and holds:
#
#   A. ensure: every slot (the repo + HOME) gets ONE entry, ready (@pool_ready 1)
#      and idle (@claude_state empty — never ran a turn); the HOME one in $HOME,
#      stamped @norepo. Needs claude_pid to see through the wrapper (#2233).
#   B. claim --repo <slug> --agent claude answers the window id inside 0.5 s, the
#      window moves into the fleet, its worktree sits on the newest origin/master;
#      a second claim on the emptied slot is exit 3
#   C. the claim's own refill puts the slot back within 30 s
#   D. a loaded machine (load/core > 1): a HOME claim is not refilled — status
#      says hold=load — and the next tick refills once the load drops
#   E. an upgrade (the entry's @agent_cfg is no longer the expected one): never
#      handed out, and the next tick replaces it
#   F. FLEET_SCRATCH_POOL=0: nothing warms, the node's claim is exit 3, the old
#      claim is a silent exit 0 — what it was before the pool went on by default
#
# tmux / python3 / git absent → SKIP (exit 0).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
POOL="$BIN/scratch-pool.sh"
for t in tmux python3 git; do command -v "$t" >/dev/null 2>&1 || { echo "scratch-pool-live: $t absent — SKIP"; exit 0; }; done
# The real binary, not a shim that forwards to whatever `tmux` PATH holds next.
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { echo "scratch-pool-live: no tmux binary — SKIP"; exit 0; }

# Short paths: a unix socket's path is capped at 104 bytes (macOS).
WORK="$(mktemp -d /tmp/psl.XXXXXX)" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SESS="psl$$"
export TMUX_TMPDIR="$WORK/t"; mkdir -p "$TMUX_TMPDIR"
cleanup() {
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
nt() { "$REAL_TMUX" -L "$SESS" "$@"; }
o()  { nt display-message -p -t "$1" "#{$2}" 2>/dev/null; }

# ---- the sandbox: a tmux on PATH that is the real one, a fake claude ----------
mkdir -p "$WORK/b" "$WORK/home"
ln -s "$REAL_TMUX" "$WORK/b/tmux"
cat > "$WORK/b/claude" <<'PY'
#!/usr/bin/env python3
# A fake Claude Code TUI: an input box that echoes what is typed, ^U clears it.
import os, sys, termios, tty
tty.setraw(0)
buf = ''
def draw():
    sys.stdout.write('\x1b[2J\x1b[H' + '-' * 20 + '\r\n❯ ' + buf + '\r\n' + '-' * 20)
    sys.stdout.flush()
draw()
while True:
    c = os.read(0, 1).decode('utf-8', 'ignore')
    if not c:
        break
    buf = '' if c == '\x15' else buf + c
    draw()
PY
chmod +x "$WORK/b/claude"
export PATH="$WORK/b:$PATH" HOME="$WORK/home" SHELL=/bin/sh
export FLEET_CONF_DIR="$WORK/c" FLEET_SKIP_GLOBAL_CONF=1 FLEET_ADMIT=0
export FLEET_WRAP_LAUNCH="$WORK/b/claude" FLEET_AGENT_CFG=0
unset TMUX TMUX_PANE FLEET_SESSION FLEET_SCRATCH_POOL

# ---- a real origin, the fleet's checkout of it, the fleet conf ----------------
git init -q --bare -b master "$WORK/o.git" 2>/dev/null || git init -q --bare "$WORK/o.git"
git clone -q "$WORK/o.git" "$WORK/m" 2>/dev/null
( cd "$WORK/m" && git config user.email t@t && git config user.name t && git checkout -q -b master 2>/dev/null
  echo one > f && git add f && git commit -qm one && git push -q origin master ) || fail "git setup"
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS"
conf() {   # conf <pool size> [extra line]
  { printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/m"
    printf 'FLEET_SCRATCH_POOL=%s\nFLEET_POOL_SETTLE_MIN=1\nFLEET_POOL_STABLE_HITS=2\n' "$1"
    printf 'FLEET_POOL_PROBE_TIMEOUT=40\nFLEET_POOL_WARM_TIMEOUT=20\nFLEET_POOL_CLAIM_REFILL_DELAY=0\n'
    printf "FLEET_POOL_DISK_PROBE_CMD='echo 500'\n"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
  } > "$FLEET_CONF_DIR/fleets/$SESS/conf"
}
conf 1 "FLEET_LOAD_PROBE_CMD='echo 0.10'"
nt -f /dev/null new-session -d -s "$SESS" -n home -x 120 -y 30 'exec sleep 600' || fail "cannot start the isolated tmux server"

pool_wins() { nt list-windows -t "$SESS-pool" -F '#{window_id}|#{@norepo}|#{@repo}|#{@pool_ready}' 2>/dev/null; }
ready_in() {  # ready_in <secs> <slot> — true once `status` shows that slot ready=1
  local _
  for _ in $(seq 1 "$1"); do
    bash "$POOL" status "$SESS" 2>/dev/null | grep -q "^slot $2 agent=claude want=1 ready=1" && return 0
    sleep 1
  done
  return 1
}
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# ---- A: every slot comes up ready and idle -----------------------------------
bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
rows=$(pool_wins)
[ "$(printf '%s\n' "$rows" | grep -c '|1$')" = 2 ] || fail "A one ready entry per slot (o/a, HOME)" "$rows
$(bash "$POOL" status "$SESS" 2>&1)"
wa=$(printf '%s\n' "$rows" | awk -F'|' '$3 == "o/a" { print $1 }'); wh=$(printf '%s\n' "$rows" | awk -F'|' '$2 == 1 { print $1 }')
[ -n "$wa" ] && [ -n "$wh" ] || fail "A a repo entry and a HOME entry" "$rows"
for w in "$wa" "$wh"; do [ -z "$(o "$w" @claude_state)" ] || fail "A $w ran a turn while warming"; done
[ "$(o "$wh" pane_current_path)" = "$HOME" ] || fail "A the HOME entry runs in \$HOME" "$(o "$wh" pane_current_path)"
[ -z "$(o "$wh" @worktree)" ] && [ -z "$(o "$wh" @repo)" ] || fail "A the HOME entry has no worktree and no repo"
out=$(bash "$POOL" status "$SESS" 2>&1)
printf '%s\n' "$out" | grep -qx 'slot o/a agent=claude want=1 ready=1' && printf '%s\n' "$out" | grep -qx 'slot HOME agent=claude want=1 ready=1' \
  || fail "A status shows both slots ready" "$out"
ok "A ensure: the repo slot and the HOME slot each hold one ready, idle entry"

# ---- B: the node's claim — fast, moved, on the newest master ------------------
( cd "$WORK/m" && echo two > g && git add g && git commit -qm two && git push -q origin master \
  && git fetch -q origin ) || fail "B push"
t0=$(ms); out=$(bash "$POOL" claim "$SESS" --repo o/a --agent claude 2>&1); rc=$?; dt=$(( $(ms) - t0 ))
[ "$rc" = 0 ] && [ "$out" = "$wa" ] || fail "B the claim answers the repo entry's id" "rc=$rc out=$out want=$wa"
[ "$dt" -le 500 ] || fail "B the claim took ${dt} ms (> 500)"
[ "$(o "$wa" session_name)" = "$SESS" ] || fail "B the claimed window lives in the fleet now"
wt=$(o "$wa" @worktree)
[ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$WORK/m" rev-parse origin/master)" ] || fail "B the worktree sits on the newest origin/master"
FLEET_POOL_CLAIM_REFILL_DELAY=60 bash "$POOL" claim "$SESS" --repo o/a --agent claude >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "B an emptied slot answers exit 3" "rc=$rc"
ok "B claim --repo o/a --agent claude: ${dt} ms, moved, worktree on origin/master; empty slot → exit 3"

# ---- C: the slot is back within 30 s -----------------------------------------
ready_in 30 o/a || fail "C the claim's refill did not bring o/a back within 30 s" "$(bash "$POOL" status "$SESS" 2>&1)"
ok "C the claimed slot is refilled within 30 s"

# ---- D: a loaded machine only shrinks ----------------------------------------
conf 1 "FLEET_LOAD_PROBE_CMD='echo 3.00'"
out=$(bash "$POOL" claim "$SESS" --repo - --agent claude 2>&1) || fail "D the HOME claim" "$out"
sleep 4; bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
out=$(bash "$POOL" status "$SESS" 2>&1)
printf '%s\n' "$out" | grep -qx 'slot HOME agent=claude want=1 ready=0 hold=load 3.00/core > 1' || fail "D a loaded machine must not refill HOME" "$out"
conf 1 "FLEET_LOAD_PROBE_CMD='echo 0.10'"
bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
ready_in 5 HOME || fail "D the next quiet tick refills HOME" "$(bash "$POOL" status "$SESS" 2>&1)"
ok "D load over 1/core: no refill (hold=load); the next quiet tick refills"

# ---- E: an upgrade replaces the pool -----------------------------------------
mkdir -p "$FLEET_CONF_DIR/global"; printf 'claude NEW x\n' > "$FLEET_CONF_DIR/global/agent-cfg.expected"
old=$(pool_wins | awk -F'|' '$3 == "o/a" { print $1 }')
nt set-option -w -t "$old" @agent_cfg OLD
out=$(FLEET_POOL_CLAIM_REFILL_DELAY=60 bash "$POOL" claim "$SESS" --repo o/a --agent claude 2>&1); rc=$?
[ "$rc" = 3 ] || fail "E an entry on the old configuration was handed out" "rc=$rc out=$out"
bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
[ -n "$old" ] || fail "E no o/a entry to age"
nt list-windows -a -F '#{window_id}' | grep -qx "$old" && fail "E the old-config entry is still there" "$(pool_wins)"
ready_in 5 o/a || fail "E the tick replaced it with a fresh entry" "$(bash "$POOL" status "$SESS" 2>&1)"
rm -f "$FLEET_CONF_DIR/global/agent-cfg.expected"
ok "E an old-config entry is never handed out; the tick replaces it"

# ---- F: pool off is the old behaviour ----------------------------------------
conf 0 "FLEET_LOAD_PROBE_CMD='echo 0.10'"
before=$(pool_wins | wc -l)
for w in $(pool_wins | awk -F'|' '{ print $1 }'); do nt kill-window -t "$w"; done
bash "$POOL" ensure "$SESS" --tick >/dev/null 2>&1
[ -z "$(pool_wins)" ] || fail "F FLEET_SCRATCH_POOL=0 warmed something" "$(pool_wins)"
bash "$POOL" claim "$SESS" --repo - --agent claude >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "F pool off: the node's claim is exit 3" "rc=$rc"
out=$(bash "$POOL" claim "$SESS" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "F pool off: the old claim is a silent exit 0" "rc=$rc out=$out"
ok "F FLEET_SCRATCH_POOL=0: nothing warms, no claim (had $((before)) entries before)"

printf '\n%s tests passed\n' "$pass"
exit 0
