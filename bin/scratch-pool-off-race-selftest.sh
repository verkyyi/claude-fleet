#!/bin/bash
# scratch-pool-off-race-selftest.sh — a slot switched OFF stays off, whatever a
# pass already in flight read (issue #4552). bin/scratch-pool.sh reads the slot's
# size (WANT) when a pass starts; a refill or a waiting ensure that read 1 before
# FLEET_SCRATCH_POOL went to 0 used to warm and publish an entry anyway, and the
# off pass (cmd_reap) kept a ready one. Real tmux on an isolated `-L` socket, the
# real session wrapper launching a fake claude TUI, the real scratch-pool.sh; the
# schedule is pinned with FIFOs on paths the production code already reads (the
# slot lock's pid file, FLEET_POOL_DISK_PROBE_CMD, the TUI's own start) — no seam:
#
#   A. a pass read on, then waits on the slot lock; the conf goes to 0 and the old
#      entries are deleted (scratch-pool-live F's steps); the pass gets the lock —
#      nothing is warmed, and F's own off tick leaves nothing
#   B. a pass holds the lock, read on under it, is paused before its spawn; the
#      conf goes to 0; the off tick waits for it, and once it ran nothing is left
#   C. an entry still warming when the slot goes off: the off tick retires it and
#      returns at once (its pass gives up, never waits out the probe)
#   D. two ensures of one slot at once warm ONE entry
#   E. a REAL claim moves the entry between the off pass listing it and killing
#      it (the pass held at its kill by the sandbox's tmux): the kill is refused,
#      the claimed session lives on — same pane, same claude — unmarked, and the
#      pass exits 0; it never touched the codex entry nor o/a's
#   E2. the same race with another writer marking the session retired meanwhile:
#      that mark stands (only the pass's own token is taken back)
#   E3. a mark another closer wrote BEFORE the pass is never owned nor written
#      over; E4. a mark that cannot be put back (ln fails) is kept aside, exit 3
#      (cheap parked windows, moved by hand at the kill — the bookkeeping only)
#   F. tmux not answering the kill, or not answering at all (no session list
#      either): the off pass exits 3 (not confirmed), the entry and its worktree
#      stay; a slot lock whose pid file cannot be read is not "free" (exit 3);
#      once tmux answers, both go
#
# POR_LEGS=<letters> runs only those of A B C (each starts from an empty pool) and
# D (D–F, in order) — to watch one go red against an older scratch-pool.sh; the
# BREAK-IT drill `pool-off-inflight` runs ABC.
# tmux / python3 / git absent → SKIP (exit 0).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
POOL="$BIN/scratch-pool.sh"
for t in tmux python3 git; do command -v "$t" >/dev/null 2>&1 || { echo "scratch-pool-off-race: $t absent — SKIP"; exit 0; }; done
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) continue ;; esac; REAL_TMUX=$t; break; done
[ -n "$REAL_TMUX" ] || { echo "scratch-pool-off-race: no tmux binary — SKIP"; exit 0; }

WORK="$(mktemp -d /tmp/por.XXXXXX)" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SESS="por$$"
export TMUX_TMPDIR="$WORK/t"; mkdir -p "$TMUX_TMPDIR"
BG=''
cleanup() {
  for p in $BG; do kill "$p" 2>/dev/null; done
  pkill -f "scratch-pool.sh ensure $SESS" 2>/dev/null     # a claim's --soon refill
  "$REAL_TMUX" -L "$SESS" kill-server 2>/dev/null
  pkill -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
nt() { "$REAL_TMUX" -L "$SESS" "$@"; }

mkdir -p "$WORK/b" "$WORK/home"
# The sandbox's tmux is the real one behind a gate: while $WORK/kill.gate exists a
# `kill-window -t <session>:<window>` (retire's) waits there (kill.hit says it
# arrived); with $WORK/kill.fail it and `list-windows -a` fail, as a server that
# does not answer; with $WORK/tmux.fail every list and kill does.
cat > "$WORK/b/tmux" <<SH
#!/bin/sh
case " \$* " in
  *" kill-window "*|*" list-windows "*|*" list-sessions "*) [ -e "$WORK/tmux.fail" ] && exit 1 ;;
esac
case " \$* " in
  *" kill-window -t "*:*)
    [ -e "$WORK/kill.fail" ] && exit 1
    if [ -e "$WORK/kill.gate" ]; then : > "$WORK/kill.hit"; while [ -e "$WORK/kill.gate" ]; do sleep 0.05; done; fi ;;
  *" list-windows -a "*) [ -e "$WORK/kill.fail" ] && exit 1 ;;
esac
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$WORK/b/tmux"
# and its ln is the real one, failing while $WORK/ln.fail exists
REAL_LN=$(command -v ln)
printf '#!/bin/sh\n[ -e "%s/ln.fail" ] && exit 1\nexec "%s" "$@"\n' "$WORK" "$REAL_LN" > "$WORK/b/ln"
chmod +x "$WORK/b/ln"
# The fake TUI (scratch-pool-live's): `❯` + NBSP, echoes, ^U clears. While
# $WORK/tui.gate exists it waits there before drawing — an entry held warming.
cat > "$WORK/b/claude" <<PY
#!/usr/bin/env python3
import os, sys, time, tty
while os.path.exists('$WORK/tui.gate'):
    time.sleep(0.1)
tty.setraw(0)
buf = ''
def draw():
    sys.stdout.write('\x1b[2J\x1b[H' + '-' * 20 + '\r\n❯ ' + buf + '\r\n' + '-' * 20)
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
export FLEET_WRAP_LAUNCH="$WORK/b/claude" FLEET_AGENT_CFG=0 FLEET_POOL_LOCK_WAIT=30
unset TMUX TMUX_PANE FLEET_SESSION FLEET_SCRATCH_POOL

git init -q --bare -b master "$WORK/o.git" 2>/dev/null || git init -q --bare "$WORK/o.git"
git clone -q "$WORK/o.git" "$WORK/m" 2>/dev/null
( cd "$WORK/m" && git config user.email t@t && git config user.name t && git checkout -q -b master 2>/dev/null
  echo one > f && git add f && git commit -qm one && git push -q origin master ) || fail "git setup"
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS"
LOCK="$FLEET_CONF_DIR/fleets/$SESS/pool/home-claude.lock"
conf() {   # conf <pool size> [disk probe]
  { printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/m"
    printf 'FLEET_SCRATCH_POOL=%s\nFLEET_POOL_SETTLE_MIN=1\nFLEET_POOL_STABLE_HITS=2\n' "$1"
    printf 'FLEET_POOL_PROBE_TIMEOUT=40\nFLEET_POOL_WARM_TIMEOUT=20\nFLEET_POOL_CLAIM_REFILL_DELAY=0\n'
    printf "FLEET_LOAD_PROBE_CMD='echo 0.10'\nFLEET_POOL_DISK_PROBE_CMD='%s'\n" "${2:-echo 500}"
  } > "$FLEET_CONF_DIR/fleets/$SESS/conf"
}
conf 1
nt -f /dev/null new-session -d -s "$SESS" -n home -x 120 -y 30 'exec sleep 600' || fail "cannot start the isolated tmux server"

pool_wins() { nt list-windows -t "$SESS-pool" -F '#{window_id}|#{@norepo}|#{@repo}|#{@pool_ready}|#{@pool_agent}' 2>/dev/null; }
home_wins() { pool_wins | awk -F'|' '$2 == 1'; }
has_home() { [ -n "$(home_wins)" ]; }
drop_all() { for w in $(pool_wins | awk -F'|' '{ print $1 }'); do nt kill-window -t "$w"; done; }
until_() {  # until_ <tenths> <cmd…> — poll a condition, re-run every tenth
  local n=$1 _; shift
  for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done
  return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }
# finish <pid> <tenths> <want rc> <what> <log> — the background pass ends in time
# with the exit it must have; anything else is a failure with its log
finish() {
  local rc
  until_ "$2" gone "$1" || fail "$4: never finished" "$(cat "$5")"
  wait "$1"; rc=$?
  [ "$rc" = "$3" ] || fail "$4: exit $rc (want $3)" "$(cat "$5")"
}
home() { bash "$POOL" ensure "$SESS" --repo - "$@"; }
alive() { nt list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "$1"; }

leg() { case "${POR_LEGS:-ABCD}" in *"$1"*) return 0 ;; esac; return 1; }

# ---- A: read on, waiting on the lock; off; the pass warms nothing -----------
if leg A; then
mkdir -p "$LOCK"; mkfifo "$LOCK/pid"
home >"$WORK/a.log" 2>&1 & pa=$!; BG="$BG $pa"
# Opening the FIFO for writing returns once the pass is reading it — inside
# pool_lock, so past the size it read at its start (FLEET_SCRATCH_POOL=1).
exec 3>"$LOCK/pid"; printf '999999\n' >&3; exec 3>&-     # a dead holder: it retries in 1 s
conf 0; drop_all                                          # scratch-pool-live F's steps
exec 3>"$LOCK/pid"; rm -rf "$LOCK"; exec 3>&-             # no holder: it takes the lock
finish "$pa" 300 0 "A the pass that read on" "$WORK/a.log"
bash "$POOL" ensure "$SESS" --tick >"$WORK/a-off.log" 2>&1 || fail "A F's off tick: exit $?" "$(cat "$WORK/a-off.log")"
[ -z "$(pool_wins)" ] || fail "A a pass that read on before the off warmed an entry anyway" "$(pool_wins)
$(cat "$WORK/a.log")"
ok "A a pass that read on before the slot went off takes the lock and warms nothing"
fi

# ---- B: read on under the lock, paused before its spawn; off waits for it ----
if leg B; then
conf 1 "cat $WORK/probe.fifo >/dev/null; echo 500"
mkfifo "$WORK/probe.fifo"
home --tick >"$WORK/b.log" 2>&1 & pb=$!; BG="$BG $pb"
exec 4>"$WORK/probe.fifo"                                 # the pass is in grow_hold: lock held, size read
[ -d "$LOCK" ] || fail "B the paused pass holds no slot lock"
conf 0
# 4>&-: the probe FIFO's one writer is this shell's (its close is what lets B's pass on)
bash "$POOL" ensure "$SESS" --tick >"$WORK/b-off.log" 2>&1 4>&- & po=$!; BG="$BG $po"
sleep 1
gone "$po" && fail "B the off pass returned while a pass that read on still held the slot" "$(pool_wins)
$(cat "$WORK/b-off.log")"
exec 4>&-                                                 # let it run on: it warms and publishes
finish "$po" 300 0 "B the off pass" "$WORK/b-off.log"
[ -z "$(pool_wins)" ] || fail "B an entry published by a pass that read on survives the off pass" "$(pool_wins)
$(cat "$WORK/b.log")"
finish "$pb" 100 0 "B the paused pass" "$WORK/b.log"
[ -z "$(pool_wins)" ] && [ ! -d "$LOCK" ] || fail "B left something behind" "$(pool_wins)"
ok "B the off pass waits for a pass that read on under the lock, then nothing is left"
fi

# ---- C: an entry still warming when the slot goes off ------------------------
if leg C; then
conf 1; : > "$WORK/tui.gate"
home --tick >"$WORK/c.log" 2>&1 & pc=$!; BG="$BG $pc"
until_ 100 has_home || fail "C no warming entry appeared" "$(cat "$WORK/c.log")"
[ "$(home_wins | awk -F'|' '{ print $4 }')" = '' ] || fail "C the entry is ready already" "$(pool_wins)"
conf 0
t0=$SECONDS; bash "$POOL" ensure "$SESS" --tick >"$WORK/c-off.log" 2>&1; rc=$?; dt=$(( SECONDS - t0 ))
[ "$rc" = 0 ] || fail "C the off pass: exit $rc" "$(cat "$WORK/c-off.log")"
[ -z "$(pool_wins)" ] || fail "C a warming entry survives the off pass" "$(pool_wins)"
[ "$dt" -le 10 ] || fail "C the off pass took ${dt}s (its pass must give up on a retired entry, not wait out the probe)"
finish "$pc" 100 0 "C the warming pass" "$WORK/c.log"
rm -f "$WORK/tui.gate"
[ -z "$(pool_wins)" ] || fail "C left something behind" "$(pool_wins)"
ok "C a warming entry is retired by the off pass (${dt}s) and its pass gives up"
fi

leg D || { printf '\n%s tests passed\n' "$pass"; exit 0; }

# ---- D: two ensures of one slot warm one entry -------------------------------
conf 1
home >"$WORK/d1.log" 2>&1 & p1=$!; home >"$WORK/d2.log" 2>&1 & p2=$!; BG="$BG $p1 $p2"
finish "$p1" 300 0 "D the first ensure" "$WORK/d1.log"; finish "$p2" 300 0 "D the second ensure" "$WORK/d2.log"
[ "$(home_wins | grep -c '|1|claude$')" = 1 ] && [ "$(home_wins | wc -l | tr -d ' ')" = 1 ] \
  || fail "D two ensures of one slot must warm exactly one entry" "$(pool_wins)"
ok "D two concurrent ensures of the HOME slot warm one entry"

# ---- E: a real claim between the off pass's listing and its kill -------------
mine=$(home_wins | awk -F'|' '{ print $1 }')
fid=$(python3 -c 'import uuid; print(uuid.uuid4())')
nt set-option -w -t "$mine" @fleet_id "$fid"
pp=$(nt display-message -p -t "$mine" '#{pane_pid}')
cpid=$(pgrep -f "$WORK/b/claude" | head -1)
mk() {   # mk <@k v>… — a parked window of another slot / agent
  local w; w=$(nt new-window -d -P -F '#{window_id}' -t "$SESS-pool:" 'exec sleep 600')
  while [ "$#" -gt 1 ]; do nt set-option -w -t "$w" "$1" "$2"; shift 2; done
  printf '%s' "$w"
}
born=$(date +%s)
wcx=$(mk @pool 1 @norepo 1 @pool_ready 1 @pool_agent codex @pool_born "$born")
wrp=$(mk @pool 1 @repo o/a @pool_ready 1 @pool_agent claude @pool_born "$born")
: > "$WORK/kill.gate"; rm -f "$WORK/kill.hit"
conf 0
bash "$POOL" ensure "$SESS" --repo - --agent claude --tick >"$WORK/e.log" 2>&1 & pe=$!; BG="$BG $pe"
until_ 100 test -e "$WORK/kill.hit" || fail "E the off pass never reached its kill" "$(cat "$WORK/e.log")"
conf 1
out=$(bash "$POOL" claim "$SESS" --repo - --agent claude 2>&1) || fail "E the real claim: exit $?" "$out"
[ "$out" = "$mine" ] || fail "E the claim handed out $out, not $mine"
conf 0; rm -f "$WORK/kill.gate"                           # the off pass's kill runs now
finish "$pe" 100 0 "E the off pass that lost the race" "$WORK/e.log"
# the claim's own --soon refill (tmux run-shell -b) runs as it always does; it may
# have read the size before the conf went back to 0 — wait it out, then nothing
# of the slot may be left by it either
refill_gone() { ! pgrep -f "scratch-pool.sh ensure $SESS --repo - --agent claude --soon" >/dev/null; }
until_ 300 refill_gone || fail "E the claim's refill never finished" "$(pool_wins)"
[ -z "$(home_wins | awk -F'|' '$5 == "claude"')" ] || fail "E the claim's refill left a HOME entry after the slot went off" "$(pool_wins)"
[ "$(nt display-message -p -t "$mine" '#{session_name}|#{pane_pid}|#{@pool}')" = "$SESS|$pp|" ] \
  || fail "E the claimed session was harmed" "$(nt list-windows -a -F '#{window_id} #{session_name} #{pane_pid}')"
kill -0 "$cpid" 2>/dev/null || fail "E the claimed session's claude ($cpid) is gone"
[ ! -e "$FLEET_CONF_DIR/global/retired/$fid" ] || fail "E the claimed session is marked retired"
alive "$wcx" && alive "$wrp" || fail "E the off pass retired another agent's / repo's entry" "$(pool_wins)"
ok "E a real claim wins the race: the kill is refused, the session (pane $pp, claude $cpid) lives on unmarked"

# ---- E2: someone else marks it retired meanwhile: that mark stands -----------
conf 1; home >"$WORK/e2.log" 2>&1 || fail "E2 warm HOME: exit $?" "$(cat "$WORK/e2.log")"
two=$(home_wins | awk -F'|' '$4 == 1 && $5 == "claude" { print $1 }')
[ -n "$two" ] || fail "E2 no ready HOME entry" "$(pool_wins)"
fid2=$(python3 -c 'import uuid; print(uuid.uuid4())'); nt set-option -w -t "$two" @fleet_id "$fid2"
: > "$WORK/kill.gate"; rm -f "$WORK/kill.hit"
conf 0
bash "$POOL" ensure "$SESS" --repo - --agent claude --tick >"$WORK/e2.log" 2>&1 & pe=$!; BG="$BG $pe"
until_ 100 test -e "$WORK/kill.hit" || fail "E2 the off pass never reached its kill" "$(cat "$WORK/e2.log")"
[ -s "$FLEET_CONF_DIR/global/retired/$fid2" ] || fail "E2 the off pass marks before its kill"
conf 1
out=$(bash "$POOL" claim "$SESS" --repo - --agent claude 2>&1) && [ "$out" = "$two" ] || fail "E2 the real claim" "$out"
conf 0
: > "$FLEET_CONF_DIR/global/retired/$fid2"                # another closer's mark (fleet_win_retire's)
rm -f "$WORK/kill.gate"
finish "$pe" 100 0 "E2 the off pass" "$WORK/e2.log"
until_ 300 refill_gone || fail "E2 the claim's refill never finished"
[ -e "$FLEET_CONF_DIR/global/retired/$fid2" ] && [ ! -s "$FLEET_CONF_DIR/global/retired/$fid2" ] \
  || fail "E2 another writer's retired mark was taken back" "$(ls -la "$FLEET_CONF_DIR/global/retired")"
[ "$(nt display-message -p -t "$two" '#{session_name}')" = "$SESS" ] || fail "E2 the claimed session was harmed"
for f in "$FLEET_CONF_DIR"/global/retired/*.unmark.*; do [ -e "$f" ] && fail "E2 a side file was left behind" "$f"; done
ok "E2 a retired mark another closer wrote meanwhile stands; only the pass's own is taken back"

# ---- E3 / E4: a mark already there; a mark that cannot be put back -----------
RET="$FLEET_CONF_DIR/global/retired"
race_moved() {  # race_moved <fid> — a parked HOME entry, moved into the fleet at the off pass's kill;
                # sets RW (the window) and pe (the off pass) in THIS shell
  local w; w=$(mk @pool 1 @norepo 1 @pool_ready 1 @pool_agent claude @pool_born "$(date +%s)" @fleet_id "$1")
  : > "$WORK/kill.gate"; rm -f "$WORK/kill.hit"
  bash "$POOL" ensure "$SESS" --repo - --agent claude --tick >"$WORK/e3.log" 2>&1 & pe=$!; BG="$BG $pe"
  until_ 100 test -e "$WORK/kill.hit" || fail "E3 the off pass never reached its kill" "$(cat "$WORK/e3.log")"
  nt move-window -s "$w" -t "$SESS:"
  RW=$w
}
fid3=$(python3 -c 'import uuid; print(uuid.uuid4())'); printf 'other closer\n' > "$RET/$fid3"
race_moved "$fid3"; w3=$RW; rm -f "$WORK/kill.gate"
finish "$pe" 100 0 "E3 the off pass" "$WORK/e3.log"
[ "$(cat "$RET/$fid3")" = 'other closer' ] || fail "E3 a mark already there was written over or taken" "$(ls -la "$RET")"
alive "$w3" || fail "E3 the moved session was killed"
fid4=$(python3 -c 'import uuid; print(uuid.uuid4())')
race_moved "$fid4"; w4=$RW
: > "$RET/$fid4"; : > "$WORK/ln.fail"; rm -f "$WORK/kill.gate"   # another closer's mark, then ln breaks
finish "$pe" 100 3 "E4 the off pass that could not put a mark back" "$WORK/e3.log"
rm -f "$WORK/ln.fail"
grep -q "could not put back the retired mark" "$WORK/e3.log" || fail "E4 the pass must say what it kept" "$(cat "$WORK/e3.log")"
side=''; for f in "$RET/$fid4".unmark.*; do [ -e "$f" ] && side=$f; done
[ -n "$side" ] || fail "E4 the mark's side copy must be kept" "$(ls -la "$RET")"
alive "$w4" || fail "E4 the moved session was killed"
nt kill-window -t "$w3"; nt kill-window -t "$w4"
ok "E3 a mark already there is never owned nor written over; E4 one that cannot be put back is kept aside, exit 3"

# ---- F: tmux not answering: kept, and said ---------------------------------
nt kill-window -t "$wcx" 2>/dev/null; nt kill-window -t "$wrp" 2>/dev/null   # E2's own reap may have retired them (not usable: no account)
conf 1; bash "$POOL" ensure "$SESS" --repo o/a >"$WORK/f.log" 2>&1 || fail "F warm o/a: exit $?" "$(cat "$WORK/f.log")"
wa=$(pool_wins | awk -F'|' '$3 == "o/a" && $4 == 1 { print $1 }')
wt=$(nt display-message -p -t "$wa" '#{@worktree}')
[ -n "$wa" ] && [ -d "$wt" ] || fail "F no ready o/a entry with a worktree" "$(pool_wins)"
conf 0; : > "$WORK/kill.fail"
bash "$POOL" ensure "$SESS" --repo o/a --tick >"$WORK/f-off.log" 2>&1; rc=$?
[ "$rc" = 3 ] || fail "F an unanswered kill must not read as off: exit $rc" "$(cat "$WORK/f-off.log")"
alive "$wa" && [ -d "$wt" ] || fail "F an unknown outcome must keep the entry and its worktree"
rm -f "$WORK/kill.fail"; : > "$WORK/tmux.fail"
bash "$POOL" ensure "$SESS" --repo o/a --tick >"$WORK/f-off.log" 2>&1; rc=$?
rm -f "$WORK/tmux.fail"
[ "$rc" = 3 ] || fail "F a server that lists nothing must not read as off: exit $rc" "$(cat "$WORK/f-off.log")"
alive "$wa" && [ -d "$wt" ] || fail "F tmux not answering must keep the entry and its worktree"
OLOCK="$FLEET_CONF_DIR/fleets/$SESS/pool/$(printf 'o/a' | tr '/' '-')-claude.lock"
mkdir -p "$OLOCK"; printf '%s\n' "$$" > "$OLOCK/pid"; chmod 000 "$OLOCK/pid"
if cat "$OLOCK/pid" >/dev/null 2>&1; then chmod 600 "$OLOCK/pid"; rm -rf "$OLOCK"   # root reads anything: no such case
else
  FLEET_POOL_LOCK_WAIT=2 bash "$POOL" ensure "$SESS" --repo o/a --tick >"$WORK/f-off.log" 2>&1; rc=$?
  chmod 600 "$OLOCK/pid"; rm -rf "$OLOCK"
  [ "$rc" = 3 ] && grep -q 'not confirmed off' "$WORK/f-off.log" || fail "F an unreadable lock pid must not read as free: exit $rc" "$(cat "$WORK/f-off.log")"
  ls "$FLEET_CONF_DIR/fleets/$SESS/pool/" >/dev/null
fi
bash "$POOL" ensure "$SESS" --repo o/a --tick >"$WORK/f-off.log" 2>&1 || fail "F the off pass once tmux answers: exit $?" "$(cat "$WORK/f-off.log")"
! alive "$wa" && [ ! -d "$wt" ] || fail "F once tmux answers, the entry and its worktree go" "$(pool_wins)"
ok "F tmux not answering (kill, or anything): exit 3, entry and worktree kept; unreadable lock pid: exit 3; answered: retired"

printf '\n%s tests passed\n' "$pass"
exit 0
