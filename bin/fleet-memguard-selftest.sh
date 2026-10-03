#!/bin/bash
# fleet-memguard-selftest.sh — the memory watchdog's rules (issue #1292).
#
# The process table and the pressure probe are STUBBED (FLEET_MEM_PS_CMD /
# FLEET_MEM_PROBE_CMD / FLEET_MEM_TOTAL_MB), so a 40 GB process is a line in a
# fixture — but every victim is a REAL `sleep` this test owns, so "killed" and
# "left alone" are asserted with kill -0, not inferred from output. The pane half
# (@mem_killed) runs on an ISOLATED tmux socket owned by this test, and is skipped
# where no tmux exists.
#
#   1 spike + pressure warn       → killed, incident, @mem_killed, one notify
#   2 same spike, pressure normal → alive, recorded only (no notify)
#   3 slow growth to 12 GB        → alive (the ring: 11.0 → 11.5 → 12 GB)
#   3b fast growth with history   → killed (1 → 3 → 6 GB, a process older than the window)
#   3c 100 MB → 5 GB in one sample → killed (absent from the ≥256 MB ring = was small)
#   3d a fresh daemon's first look  → not growth
#   4 claude at 40 GB             → alive, recorded only
#   5 exempt regex                → alive
#   6 ≥ 50% of physical memory    → killed whatever the growth / pressure
#   7 fleet orphan, old + big     → reported, alive; a non-anchored orphan → nothing
#   8 a non-fleet process 40 GB   → untouched, not even recorded
#   9 *_ACTION=report             → never kills
#   10 the same pid twice         → one notification
#   11 --dry-run                  → kills nothing, writes nothing
#   13 a claude session ≥ 4 GB    → @claude_mem_warn on its window, ONE notify naming
#                                   it + the /fleet-handoff line; held at ≥ 90%,
#                                   cleared below; under the line never badged (#1297)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
MG="$BIN/fleet-memguard.sh"
[ -f "$MG" ] || { echo "selftest: $MG not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-memguard-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SPAWNED=''; SOCK="memgst$$"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
cleanup() {
  for p in $SPAWNED; do kill -KILL "$p" 2>/dev/null; done
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

CHECKS=0
fail() { cat "$WORK/notified" >&2 2>/dev/null; printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }
alive() { kill -0 "$1" 2>/dev/null; }
ME="$(id -u)"

# a real victim, cwd in <dir>; its pid lands in $V (no $(…): the substitution
# would wait on the background sleep's stdout for its whole 300s)
victim() { mkdir -p "$1"; ( cd "$1" && exec sleep 300 ) >/dev/null 2>&1 & V=$!; disown "$V" 2>/dev/null; SPAWNED="$SPAWNED $V"; }

# Fixture builders. AGENT is a fake `claude` the victims hang under (class fleet).
AGENT=4000001
row() { printf '%s %s %s %s %s %s\n' "$1" "$2" "$ME" "$(( $3 * 1024 ))" "$4" "$5"; }   # pid ppid rssMB etime argv
agent_row() { row "$AGENT" 4000000 600 "01:00:00" "claude --model opus"; }

printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/notified"\n' "$WORK" > "$WORK/notify.sh"; chmod +x "$WORK/notify.sh"

# run [env…] -- args : one memguard invocation in a fresh-or-kept conf dir
run() {
  env FLEET_CONF_DIR="$CONF" FLEET_CLAUDE_TMP_ROOT="$WORK/no-claude-root" \
      FLEET_NOTIFY_CMD="$WORK/notify.sh" FLEET_MEM_TOTAL_MB=65536 \
      FLEET_MEM_PS_CMD="sh $WORK/ps.sh" "$@"
}
fresh() { CONF="$WORK/conf.$1"; mkdir -p "$CONF"; : > "$WORK/notified"; printf '0' > "$WORK/cnt"; rm -f "$WORK"/table.*; }
# the ps stub serves table.1, table.2, … per call, then repeats the last one
cat > "$WORK/ps.sh" <<EOF
#!/bin/sh
n=\$(( \$(cat "$WORK/cnt") + 1 )); printf '%s' "\$n" > "$WORK/cnt"
while [ "\$n" -gt 1 ] && [ ! -f "$WORK/table.\$n" ]; do n=\$((n - 1)); done
cat "$WORK/table.\$n"
EOF
WARN='echo 2 12 40 2048'; NORMAL='echo 1 60 5 0'
nnotify() { awk '/^# ⚠/{n++} END{print n+0}' "$WORK/notified"; }

# ---- the pane: an isolated fleet socket whose pane is the victim's parent ------
PANE_PID=''; TMUX_SRV=''
if [ -n "$REAL_TMUX" ]; then
  "$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s "$SOCK" 'sleep 600' 2>/dev/null \
    && PANE_PID="$("$REAL_TMUX" -L "$SOCK" list-panes -a -F '#{pane_pid}' | head -1)" \
    && TMUX_SRV="$("$REAL_TMUX" -L "$SOCK" display-message -p '#{pid}')"
fi

# 1. spike + warn → killed ------------------------------------------------------
fresh 1; mkdir -p "$CONF/fleets/$SOCK"; : > "$CONF/fleets/$SOCK/conf"
victim "$WORK/w1"
if [ -n "$PANE_PID" ]; then
  { row "$TMUX_SRV" 1 50 "01:00:00" "tmux -L $SOCK new-session -d"
    row "$PANE_PID" "$TMUX_SRV" 5 "01:00:00" "sleep 600"
    row "$V" "$PANE_PID" 5120 "00:03" "git grep -l -E foo"; } > "$WORK/table.1"
else
  { agent_row; row "$V" "$AGENT" 5120 "00:03" "git grep -l -E foo"; } > "$WORK/table.1"
fi
out=$(run FLEET_MEM_PROBE_CMD="$WARN" bash "$MG" --once 2>&1)
sleep 0.2
alive "$V" && fail "1: a +5 GB/3s fleet command under pressure must be SIGKILLed" "$out"; ok
printf '%s' "$out" | grep -q "^spike	kill	$V" || fail "1: --once must print the spike row and its action" "$out"; ok
ls "$CONF"/diskguard/incident-mem-*.log >/dev/null 2>&1 || fail "1: no incident-mem log written"; ok
grep -q "killed (SIGKILL" "$CONF"/diskguard/incident-mem-*.log || fail "1: the incident must say it was killed"; ok
[ "$(nnotify)" = 1 ] || fail "1: expected exactly one notification, got $(nnotify)"; ok
grep -q "git grep" "$WORK/notified" || fail "1: the notification must name the command"; ok
if [ -n "$PANE_PID" ]; then
  mk="$("$REAL_TMUX" -L "$SOCK" show-options -wv -t "$SOCK:0" @mem_killed 2>/dev/null)"
  printf '%s' "$mk" | grep -q "exit 137: git grep" || fail "1: the pane's window must carry @mem_killed naming the command — got [$mk]"; ok
fi

# 2. same spike, pressure normal → recorded only ---------------------------------
fresh 2; victim "$WORK/w2"
{ agent_row; row "$V" "$AGENT" 5120 "00:03" "git grep -l -E foo"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once 2>&1)
alive "$V" || fail "2: a spike on a relaxed machine must NOT be killed" "$out"; ok
printf '%s' "$out" | grep -q "^spike-relaxed	record	$V" || fail "2: it must be listed as recorded" "$out"; ok
grep -q "recorded only" "$CONF"/diskguard/incident-mem-*.log 2>/dev/null || fail "2: the record must reach the incident log"; ok
[ "$(nnotify)" = 0 ] || fail "2: a record must not notify"; ok

# 3. slow growth to 12 GB under pressure → alive (the ring) ------------------------
fresh 3; victim "$WORK/w3"
{ agent_row; row "$V" "$AGENT" 11000 "01:00:00" "cargo build --release"; } > "$WORK/table.1"
{ agent_row; row "$V" "$AGENT" 11500 "01:00:01" "cargo build --release"; } > "$WORK/table.2"
{ agent_row; row "$V" "$AGENT" 12288 "01:00:02" "cargo build --release"; } > "$WORK/table.3"
run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_INTERVAL=1 FLEET_MEM_MAX_TICKS=3 bash "$MG" --daemon >/dev/null 2>&1
alive "$V" || fail "3: a build growing slowly to 12 GB must never be killed"; ok
[ "$(nnotify)" = 0 ] || fail "3: nothing to say about a slow build"; ok

# 3b. the same ring, fast: 1 → 3 → 6 GB on a process older than the window → killed
fresh 3b; victim "$WORK/w3b"
{ agent_row; row "$V" "$AGENT" 1000 "01:00:00" "node leaky.js"; } > "$WORK/table.1"
{ agent_row; row "$V" "$AGENT" 3000 "01:00:01" "node leaky.js"; } > "$WORK/table.2"
{ agent_row; row "$V" "$AGENT" 6000 "01:00:02" "node leaky.js"; } > "$WORK/table.3"
run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_INTERVAL=1 FLEET_MEM_MAX_TICKS=3 bash "$MG" --daemon >/dev/null 2>&1
sleep 0.2
alive "$V" && fail "3b: +5 GB inside the window (seen across samples) under pressure must be killed"; ok

# 3c. small → big between two samples (never in the ≥256 MB ring) → killed
fresh 3c; victim "$WORK/w3c"
{ agent_row; row "$V" "$AGENT" 100 "01:00:00" "node leaky.js"; } > "$WORK/table.1"
{ agent_row; row "$V" "$AGENT" 5000 "01:00:01" "node leaky.js"; } > "$WORK/table.2"
run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_INTERVAL=1 FLEET_MEM_MAX_TICKS=2 bash "$MG" --daemon >/dev/null 2>&1
sleep 0.2
alive "$V" && fail "3c: a 100 MB process that jumps to 5 GB between samples must be killed"; ok

# 3d. …but a fresh daemon's FIRST sample is not growth: 12 GB seen once, old → alive
fresh 3d; victim "$WORK/w3d"
{ agent_row; row "$V" "$AGENT" 12288 "01:00:00" "cargo build"; } > "$WORK/table.1"
run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_INTERVAL=1 FLEET_MEM_MAX_TICKS=1 bash "$MG" --daemon >/dev/null 2>&1
alive "$V" || fail "3d: the first sample of a fresh daemon must not read as growth from 0"; ok

# 4. claude at 40 GB → alive, recorded -------------------------------------------
fresh 4; victim "$WORK/w4"
{ row 4000000 1 5 "01:00:00" "tmux -L x new-session"; row "$V" 4000000 40960 "00:05" "claude --model opus --resume abc"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$WARN" bash "$MG" --once 2>&1)
alive "$V" || fail "4: a claude session is NEVER killed by memguard" "$out"; ok
printf '%s' "$out" | grep -q "record	$V" || fail "4: but it must be recorded" "$out"; ok
[ "$(nnotify)" = 0 ] || fail "4: a recorded agent must not notify"; ok

# 5. exempt → alive -------------------------------------------------------------
fresh 5; victim "$WORK/w5"
{ agent_row; row "$V" "$AGENT" 40000 "00:03" "mybuild --huge"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_EXEMPT_RE='mybuild' bash "$MG" --once 2>&1)
alive "$V" || fail "5: FLEET_MEM_EXEMPT_RE must protect a matching process" "$out"; ok
printf '%s' "$out" | grep -q -- "-exempt	record	$V" || fail "5: the exempt row is recorded as such" "$out"; ok

# 6. ≥ 50% of physical memory → killed, no growth, no pressure -------------------
fresh 6; victim "$WORK/w6"
{ agent_row; row "$V" "$AGENT" 33000 "02:00:00" "python3 crunch.py"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once 2>&1)
sleep 0.2
alive "$V" && fail "6: a fleet process at ≥50% of RAM must be killed whatever the pressure" "$out"; ok
printf '%s' "$out" | grep -q "^hard	kill	$V" || fail "6: listed as rule hard" "$out"; ok

# 7. orphans: anchored old + big → reported, alive; un-anchored → nothing --------
fresh 7
victim "$WORK/proj-issue-77/sub"; VO=$V; victim "$WORK/plain"; VN=$V
{ row "$VO" 1 3000 "1-00:00:00" "chrome-headless-shell --remote-debugging-port=0"
  row "$VN" 1 3000 "1-00:00:00" "chrome-headless-shell --remote-debugging-port=0"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once 2>&1)
alive "$VO" || fail "7: an orphan is report-only by default" "$out"; ok
printf '%s' "$out" | grep -q "^orphan	report	$VO" || fail "7: the anchored orphan must be reported" "$out"; ok
printf '%s' "$out" | grep -q "	$VN	" && fail "7: an orphan with no fleet anchor is not ours" "$out"; ok
[ "$(nnotify)" = 1 ] || fail "7: one report notification, got $(nnotify)"; ok
alive "$VN" || fail "7: the non-fleet orphan must be untouched"; ok

# 8. non-fleet 40 GB → untouched ------------------------------------------------
fresh 8; victim "$WORK/w8"
{ row 4100000 1 100 "05:00:00" "/Applications/Terminal.app/Contents/MacOS/Terminal"
  row "$V" 4100000 40960 "00:03" "java -jar big.jar"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$WARN" bash "$MG" --once 2>&1)
alive "$V" || fail "8: a process no session started is not memguard's" "$out"; ok
printf '%s' "$out" | grep -q "	$V	" && fail "8: …and is not even listed" "$out"; ok

# 9. ACTION=report never kills ----------------------------------------------------
fresh 9; victim "$WORK/w9"; V1=$V; victim "$WORK/w9b"; V2=$V; V=$V1
{ agent_row; row "$V" "$AGENT" 5120 "00:03" "git grep x"; row "$V2" "$AGENT" 40000 "02:00:00" "big"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_SPIKE_ACTION=report bash "$MG" --once 2>&1)
alive "$V" && alive "$V2" || fail "9: FLEET_MEM_SPIKE_ACTION=report must never kill (spike nor hard)" "$out"; ok

# 10. the same pid twice → one notification ----------------------------------------
run FLEET_MEM_PROBE_CMD="$WARN" FLEET_MEM_SPIKE_ACTION=report bash "$MG" --once >/dev/null 2>&1
[ "$(nnotify)" = 2 ] || fail "10: two processes reported over two passes must notify twice in total, got $(nnotify)"; ok

# 11. --dry-run → kills nothing, writes nothing -----------------------------------
fresh 11; victim "$WORK/w11"
{ agent_row; row "$V" "$AGENT" 40000 "00:03" "git grep y"; } > "$WORK/table.1"
out=$(run FLEET_MEM_PROBE_CMD="$WARN" bash "$MG" --once --dry-run 2>&1)
alive "$V" || fail "11: --dry-run must not kill" "$out"; ok
printf '%s' "$out" | grep -q "would-kill	$V" || fail "11: --dry-run must say what it would do" "$out"; ok
[ -d "$CONF/diskguard" ] && fail "11: --dry-run must write nothing"; ok
[ "$(nnotify)" = 0 ] || fail "11: --dry-run must not notify"; ok

# 12. the lib's classification is what the rules lean on --------------------------
{ row 10 1 5 "01:00:00" "tmux -L f new-session"; row 11 10 600 "01:00:00" "/Users/x/.local/share/claude/versions/2.1.0 --model opus"
  row 12 11 100 "00:10" "git status"; row 13 1 100 "00:10" "tmux new-session"; row 14 13 100 "00:10" "vim"
  row 15 1 100 "00:10" "node /usr/lib/node_modules/@openai/codex/bin/codex.js"; } > "$WORK/t12"
cls=$(FLEET_MEM_PS_CMD="cat $WORK/t12" bash -c ". '$BIN/fleet-lib.sh'; fleet_proc_mem_rows" | awk -F'\t' '{print $1 "=" $5}' | sort | tr '\n' ' ')
[ "$cls" = "10=other 11=agent 12=fleet 13=orphan 14=other 15=agent " ] \
  || fail "12: classification drifted — got [$cls] (a default-socket tmux is not a fleet; the native build is an agent)"; ok
pr=$(FLEET_MEM_PROBE_CMD='echo 4 5 97 0' bash -c ". '$BIN/fleet-lib.sh'; fleet_mem_probe")
[ "$pr" = "4 5 97 0" ] || fail "12: FLEET_MEM_PROBE_CMD must be the reading verbatim — got [$pr]"; ok

# 13. rule C — a fat SESSION: badge + one notification, never touched (#1297) -------
if [ -n "$PANE_PID" ]; then
  fresh 13; mkdir -p "$CONF/fleets/$SOCK"; : > "$CONF/fleets/$SOCK/conf"
  "$REAL_TMUX" -L "$SOCK" rename-window -t "$SOCK:0" fatwin 2>/dev/null
  warnopt() { "$REAL_TMUX" -L "$SOCK" show-options -wv -t "$SOCK:0" @claude_mem_warn 2>/dev/null; }
  fatrow() { { row "$TMUX_SRV" 1 50 "01:00:00" "tmux -L $SOCK new-session -d"
               row "$PANE_PID" "$TMUX_SRV" "$1" "3-01:00:00" "claude --model opus"; } > "$WORK/table.1"; }
  nfat() { awk '/^# 🐘/{n++} END{print n+0}' "$WORK/notified"; }
  fatrow 3800
  out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once 2>&1)
  [ -z "$(warnopt)" ] || fail "13: a session under the line must not be badged" "$out"; ok
  fatrow 5000
  out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once --dry-run 2>&1)
  printf '%s' "$out" | grep -q "^fat	would-warn	$PANE_PID	5000MB" || fail "13: --dry-run must list the fat session" "$out"; ok
  [ -z "$(warnopt)" ] || fail "13: --dry-run must not badge"; ok
  out=$(run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once 2>&1)
  alive "$PANE_PID" || fail "13: a fat session must never be killed" "$out"; ok
  [ "$(warnopt)" = "4.9G" ] || fail "13: the window must carry @claude_mem_warn=4.9G — got [$(warnopt)]" "$out"; ok
  [ "$(nfat)" = 1 ] || fail "13: expected one notification, got $(nfat)"; ok
  grep -q "fatwin" "$WORK/notified" && grep -q "fleet-peer-send.sh -L $SOCK $PANE_PID .*fleet-handoff" "$WORK/notified" \
    || fail "13: the notification must name the window and carry the /fleet-handoff line"; ok
  run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once >/dev/null 2>&1
  [ "$(nfat)" = 1 ] || fail "13: the same session must be notified ONCE, got $(nfat)"; ok
  fatrow 3800
  run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once >/dev/null 2>&1
  [ "$(warnopt)" = "3.7G" ] || fail "13: at ≥ 90% of the line the badge holds (and says the new size) — got [$(warnopt)]"; ok
  fatrow 3000
  run FLEET_MEM_PROBE_CMD="$NORMAL" bash "$MG" --once >/dev/null 2>&1
  [ -z "$(warnopt)" ] || fail "13: fallen back under 90% the badge must clear — got [$(warnopt)]"; ok
  fatrow 9000
  run FLEET_MEM_PROBE_CMD="$NORMAL" FLEET_CLAUDE_RSS_WARN_MB=0 bash "$MG" --once >/dev/null 2>&1
  [ -z "$(warnopt)" ] || fail "13: FLEET_CLAUDE_RSS_WARN_MB=0 turns rule C off"; ok
fi

printf 'fleet-memguard-selftest: %d checks passed\n' "$CHECKS"
