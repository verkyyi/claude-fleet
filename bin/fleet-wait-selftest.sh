#!/bin/bash
# fleet-wait-selftest.sh — an idle window that is still WAITING is not done (issue #1370).
#
# Three things made a finished-looking ✓ out of a window that was not finished:
# a session whose Bash-tool job was still running and a session that scheduled
# its Loop before the @loop hook (#1331) was
# synced. This pins all three on an ISOLATED tmux socket (PATH-shim, never the live
# server), with a fake `claude` (a bash script, FLEET_CLAUDE_COMM) and transcript
# fixtures — no live Claude, no gh:
#   A. Parent    — old local/remote relationships never hold this Task or mark it
#                  looping; compatibility functions are inert, history stays;
#                  --parent-only runs this regression without native-work legs.
#   B. bg        — a Bash-tool shell still under the agent → `looping` + bg, and
#                  retained:bg; an agent with no such child → done
#   C. backfill  — a pre-hook ScheduleWakeup still pending in the transcript → the
#                  Stop writes @loop + looping; one already past its grace, a
#                  stop:true, a cron later deleted → nothing written; a window that
#                  has @loop, or a live mod, is never touched
#   D. sweep     — the `loopmark` apply step's per-fleet pass marks only what is
#                  pending and counts only the Claude windows it could read
#   E. degenerate— no children, no bg job, no Loop: the Stop writes exactly what it
#                  always did — `done`, an empty needs, a timestamp, and NO
#                  @claude_wait / @loop option at all
#   F. tool      — a fleet tool call still running under the agent (issue #1880: an
#                  MCP call Claude Code backgrounded past 120 s, the turn over) →
#                  `looping` + tool, retained:tool, fleet_child_busy / the
#                  cfg-restart judge say tool; an idle fleet-mcp.py, or one probing
#                  a new version, → done; the call returns → the re-ask writes done
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
st_need python3
[ -n "$REAL_TMUX" ] || { printf 'fleet-wait-selftest: tmux absent — SKIP\n'; exit 0; }
st_tally count

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleetwait.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
# kill-server takes the fake agents; the tool-shell children are reaped by name,
# and every one of them is bounded by its own `sleep 120` anyway.
trap 'tf kill-server 2>/dev/null; pkill -f "snapshot-fleetwait-$$" 2>/dev/null; for p in $(pgrep -f "$WORK/fbin/fleet-mcp.py" 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$WORK/path" "$WORK/conf" "$WORK/proj/-w" "$WORK/sessions"
st_tmux_socket "$WORK/path" "$SOCK" strip
PATH="$WORK/path:$PATH"; export PATH
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_REAP_MIN_AGE=0
export CLAUDE_PROJECTS_DIR="$WORK/proj" FLEET_CC_SESSIONS_DIR="$WORK/sessions"
export FLEET_CLAUDE_COMM="fakeclaude-fleetwait-$$"
unset TMUX TMUX_PANE FLEET_MOD

# The fake agent: `bg` leaves a Bash-tool shell (the shell-snapshot argv Claude's
# Bash tool runs every command under) as its direct child, as a run_in_background
# job would. The trailing `:` keeps sh from exec'ing sleep over the marker.
# `tool <mode> [pidfile]` (F, issue #1880) leaves a fleet MCP server under it — a
# fake bin/fleet-mcp.py, found by its argv shape (python + …/fleet-mcp.py), which
# runs its one call as a child the way the real server runs every tool:
#   call <pidfile>  one call (a sleep, its pid in <pidfile>); idle once it returns
#   idle            a server between calls — no child at all
#   probe           a server checking a new version: its child is `--probe`, no call
mkdir -p "$WORK/fbin"
cat > "$WORK/fbin/fleet-mcp.py" <<'PY'
import signal, subprocess, sys, time
mode = sys.argv[1] if len(sys.argv) > 1 else 'idle'
child = None
def bye(*_):
    if child is not None and child.poll() is None: child.kill()
    sys.exit(0)
signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGHUP, bye)
if mode == '--probe': time.sleep(120); sys.exit(0)
if mode == 'call':
    child = subprocess.Popen(['sleep', '120'])
    with open(sys.argv[2], 'w') as fh: fh.write(str(child.pid))
    child.wait(); child = None
elif mode == 'probe':
    child = subprocess.Popen([sys.executable, __file__, '--probe'])
time.sleep(120)
bye()
PY
FAKE="$WORK/$FLEET_CLAUDE_COMM.sh"
cat > "$FAKE" <<SH
#!/bin/bash
case "\${1:-}" in
  bg)   sh -c ': /shell-snapshots/snapshot-fleetwait-$$; sleep 120; :' & ;;
  tool) python3 "$WORK/fbin/fleet-mcp.py" "\${2:-idle}" "\${3:-}" & ;;
esac
sleep 120 &
wait
SH
chmod +x "$FAKE"

SESS=fleet1370
tf -f /dev/null new-session -d -s "$SESS" -n par "exec sleep 300" || st_fail "cannot start isolated tmux"
win() {   # <name> <@issue> [@origin] [command] → window id
  local w
  w=$(tf new-window -d -P -F '#{window_id}' -t "$SESS" -n "$1" "${4:-exec sleep 300}")
  tf set-window-option -t "$w" @issue "$2"
  [ -n "${3:-}" ] && tf set-window-option -t "$w" @origin "$3"
  printf '%s' "$w"
}
PAR=$(tf display-message -p -t "$SESS:par" '#{window_id}')
tf set-window-option -t "$PAR" @issue 100
TMUXV="$SOCK,1,0"
opt()  { tf display-message -p -t "$1" "#{$2}"; }
hasopt() { tf show-options -w -t "$1" 2>/dev/null | grep -q "^$2 "; }
pane() { tf display-message -p -t "$1" '#{pane_id}'; }
stop() {  # <win> [payload] [extra args] — the Stop hook, as Claude Code runs it
  local p; p=$(pane "$1")
  printf '%s' "${2:-}" | env TMUX="$TMUXV" TMUX_PANE="$p" sh "$BIN/set-claude-state.sh" ${3:-} 'done' >/dev/null 2>&1
}
reap() { python3 "$BIN/fleet-reap-live.py" "$1" --socket-name "$SESS"; }
. "$BIN/fleet-lib.sh"

# --- A. retired Parent waits ------------------------------------------------------
# These are real independent tmux windows carrying pre-retirement metadata.
# Neither another Task's native activity nor its Loop is this Task's work.
K1=$(win kid1 101 issue-100)
tf set-window-option -t "$K1" @claude_state working
stop "$PAR"
st_eq "A: another Task's work cannot turn this Stop into looping" 'done' "$(opt "$PAR" @claude_state)"
st_eq "A: no Parent wait reason is stamped" '' "$(opt "$PAR" @claude_wait)"
out=$(fleet_window_waiting_children "$SESS" "$PAR"); rc=$?
st_eq "A: old waiting_children entry is inert" "1 " "$rc $out"
out=$(reap "$PAR"); rc=$?
st_eq "A: no Parent relationship holds the idle task" "0 " "$rc $out"
out=$(python3 - "$BIN" "$SESS" "$PAR" <<'PYLOOP'
import runpy, sys
loop = runpy.run_path(sys.argv[1] + '/fleet-loop.py')
print(','.join(loop['wait_reasons']({'fleet': {'session': sys.argv[2], 'window_id': sys.argv[3]}})))
PYLOOP
)
st_eq "A: a due Loop does not wait for another Task" '' "$out"
K2=$(win kid2 102 issue-101)
for state in working needs 'done'; do
  tf set-window-option -t "$K2" @claude_state "$state"
  stop "$PAR"
  st_eq "A: a distant legacy Task in $state does not affect Stop" 'done ' "$(opt "$PAR" @claude_state) $(opt "$PAR" @claude_wait)"
done
tf set-window-option -t "$K2" @loop "kind=wakeup next=$(( $(date +%s) + 900 )) ttl=900"
stop "$PAR" '' '--via mod'
st_eq "A: another Task's Loop does not affect mod done" 'done ' "$(opt "$PAR" @claude_state) $(opt "$PAR" @claude_wait)"
out=$(reap "$K2"); rc=$?
st_eq "A: its own native Loop still protects the actual owner" "1 retained:loop" "$rc $out"
# Old looping(children) observations clear on the existing idle re-evaluation.
tf set-window-option -t "$PAR" @claude_state looping
tf set-window-option -t "$PAR" @claude_wait children
fleet_window_reeval "$SESS" "$PAR" >/dev/null
st_eq "A: stale children-only wait clears without touching the other Task" 'done ' "$(opt "$PAR" @claude_state) $(opt "$PAR" @claude_wait)"
st_eq "A: independent Task is untouched" working "$(opt "$K1" @claude_state)"
tf kill-window -t "$K2"; tf kill-window -t "$K1"
# Both retained function names are inert, including for a former remote child.
# A deliberately observable legacy reader must never be consulted for liveness.
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS/children"
ledger="$FLEET_CONF_DIR/fleets/$SESS/children/issue-100.ndjson"
printf '%s\n' '{"child":"issue-501","state":"WAITING","summary":"historic"}' > "$ledger"
cp "$ledger" "$WORK/ledger-before"
fleet_remote_children() { printf 'called\n' >> "$WORK/remote-read"; printf 'issue-501\tworking\n'; }
out=$(_fleet_remote_tally "$SESS" issue-100); rc=$?
st_eq "A: old remote tally is inert" "1 " "$rc $out"
out=$(fleet_window_wait "$SESS" "$PAR"); rc=$?
st_eq "A: ordinary wait ignores legacy remote relationships" "1 " "$rc $out"
[ ! -e "$WORK/remote-read" ] || st_fail "A: liveness must not read the old remote map"
cmp -s "$ledger" "$WORK/ledger-before" || st_fail "A: history bytes changed"
CHECKS=$((CHECKS+2))
if [ "${1:-}" = --parent-only ]; then
  printf 'fleet-wait-selftest: OK (%d Parent retirement checks)\n' "$CHECKS"
  exit 0
fi

# --- B. bg ----------------------------------------------------------------------------
BGW=$(win bgw 110 '' "exec bash $FAKE bg")
IDW=$(win idw 111 '' "exec bash $FAKE")
# wait for both fake agents (and the bg one's tool shell) to be up
for _ in $(seq 1 50); do
  pgrep -f "snapshot-fleetwait-$$" >/dev/null 2>&1 && [ "$(pgrep -f "$FLEET_CLAUDE_COMM" | wc -l)" -ge 2 ] && break
  sleep 0.1
done
stop "$BGW"
st_eq "B: a Bash-tool job under the agent → looping + bg" "looping bg" "$(opt "$BGW" @claude_state) $(opt "$BGW" @claude_wait)"
tf set-window-option -t "$BGW" @claude_state 'done'
out=$(reap "$BGW"); rc=$?
st_eq "B: reap-live retains it" "1 retained:bg" "$rc $out"
stop "$IDW"
st_eq "B: an agent with no tool shell under it → done" 'done' "$(opt "$IDW" @claude_state)"
hasopt "$IDW" @claude_wait && st_fail "B: no reason, no option" "$(tf show-options -w -t "$IDW")"
CHECKS=$((CHECKS+1))
pkill -f "snapshot-fleetwait-$$" 2>/dev/null
for _ in $(seq 1 50); do pgrep -f "snapshot-fleetwait-$$" >/dev/null 2>&1 || break; sleep 0.1; done
stop "$BGW"
st_eq "B: the job ended → the next Stop is done" 'done' "$(opt "$BGW" @claude_state)"
tf kill-window -t "$BGW"; tf kill-window -t "$IDW"

# --- C. backfill ----------------------------------------------------------------------
iso() { python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
NOW=$(date +%s)
tr_wake() {  # <file> <epoch> <input-json> — one ScheduleWakeup call + its result
  printf '{"type":"user","message":{"content":"hi"}}\n' >> "$1"
  printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"w%s","name":"ScheduleWakeup","input":%s}]}}\n' "$(iso "$2")" "$2" "$3" >> "$1"
  printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"w%s","content":"ok"}]}}\n' "$(iso "$2")" "$2" >> "$1"
}
LW=$(win loopw 120)
T1="$WORK/proj/-w/t1.jsonl"; : > "$T1"
tr_wake "$T1" $((NOW - 600)) '{"delaySeconds":1800,"prompt":"/loop check"}'
stop "$LW" "{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$T1\"}"
case "$(opt "$LW" @loop)" in "kind=wakeup next=$((NOW + 1200)) ttl=1800") CHECKS=$((CHECKS+1)) ;;
  *) st_fail "C: a pending pre-hook wakeup must be backfilled" "$(opt "$LW" @loop)" ;; esac
st_eq "C: …and the Stop stamps looping + loop" "looping loop" "$(opt "$LW" @claude_state) $(opt "$LW" @claude_wait)"
# only-add: an existing @loop is never rewritten from the transcript
tf set-window-option -t "$LW" @loop "kind=cron id=keep01@$((NOW + 999))"
stop "$LW" "{\"transcript_path\":\"$T1\"}"
st_eq "C: an existing @loop is left as it is" "kind=cron id=keep01@$((NOW + 999))" "$(opt "$LW" @loop)"
tf kill-window -t "$LW"
for case_ in expired stop deleted mod subagent error; do
  W=$(win "c-$case_" 121)
  T="$WORK/proj/-w/c-$case_.jsonl"; : > "$T"
  case "$case_" in
    expired) tr_wake "$T" $((NOW - 7200)) '{"delaySeconds":1800,"prompt":"x"}' ;;
    stop)    tr_wake "$T" $((NOW - 900)) '{"delaySeconds":1800,"prompt":"x"}'
             tr_wake "$T" $((NOW - 600)) '{"stop":true}' ;;
    deleted) printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"c1","name":"CronCreate","input":{"cron":"7 * * * *","prompt":"x"}}]}}\n' "$(iso $((NOW-900)))" >> "$T"
             printf '{"type":"user","timestamp":"%s","toolUseResult":{"id":"ab12cd34"},"message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"Scheduled ab12cd34"}]}}\n' "$(iso $((NOW-900)))" >> "$T"
             printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"c2","name":"CronDelete","input":{"id":"ab12cd34"}}]}}\n' "$(iso $((NOW-600)))" >> "$T"
             printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"c2","content":"ok"}]}}\n' "$(iso $((NOW-600)))" >> "$T" ;;
    mod)     tr_wake "$T" $((NOW - 60)) '{"delaySeconds":1800,"prompt":"x"}'
             tf set-window-option -t "$W" @mod_alive "$NOW" ;;
    subagent) printf '{"isSidechain":true,"timestamp":"%s","message":{"content":[{"type":"tool_use","id":"s1","name":"ScheduleWakeup","input":{"delaySeconds":1800}}]}}\n' "$(iso $((NOW-60)))" >> "$T"
             printf '{"isSidechain":true,"timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"ok"}]}}\n' "$(iso $((NOW-60)))" >> "$T" ;;
    error)   printf '{"timestamp":"%s","message":{"content":[{"type":"tool_use","id":"e1","name":"ScheduleWakeup","input":{"delaySeconds":1800}}]}}\n' "$(iso $((NOW-60)))" >> "$T"
             printf '{"timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"e1","is_error":true,"content":"no"}]}}\n' "$(iso $((NOW-60)))" >> "$T" ;;
  esac
  stop "$W" "{\"transcript_path\":\"$T\"}"
  st_eq "C: $case_ → no @loop written" "" "$(opt "$W" @loop)"
  st_eq "C: $case_ → done" 'done' "$(opt "$W" @claude_state)"
  tf kill-window -t "$W"
done
# a cron job still alive is marked; the CLI says what it did
W=$(win c-cron 122)
T="$WORK/proj/-w/c-cron.jsonl"; : > "$T"
printf '{"timestamp":"%s","message":{"content":[{"type":"tool_use","id":"c1","name":"CronCreate","input":{"cron":"7 * * * *","prompt":"x"}}]}}\n{"timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"c1","content":"Scheduled recurring task ab12cd34 (7 * * * *)."}]}}\n' \
  "$(iso $((NOW-900)))" "$(iso $((NOW-900)))" >> "$T"
out=$(python3 "$BIN/fleet_loop_mark.py" backfill "$W" --transcript "$T" --socket-name "$SESS"); rc=$?
case "$rc $out" in "0 marked kind=cron id=ab12cd34@"*) CHECKS=$((CHECKS+1)) ;; *) st_fail "C: a live CronCreate is backfilled" "$rc $out" ;; esac
out=$(python3 "$BIN/fleet_loop_mark.py" backfill "$W" --transcript "$T" --socket-name "$SESS"); rc=$?
st_eq "C: a second backfill is a no-op" "1 skip has-loop" "$rc $out"
# a torn first line (a tail read starts mid-line) is skipped, not fatal
python3 - "$BIN" "$NOW" <<'PY' || st_fail "C: the tail reader (see traceback above)"
import json, runpy, sys, tempfile, os
M = runpy.run_path(os.path.join(sys.argv[1], 'fleet_loop_mark.py'))
now = int(sys.argv[2])
row = lambda ts, c: json.dumps({'timestamp': ts, 'message': {'content': c}})
import datetime
iso = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).isoformat()
lines = ['{"torn', row(iso(now - 60), [{'type': 'tool_use', 'id': 'a', 'name': 'ScheduleWakeup', 'input': {'delaySeconds': 600}}]),
         row(iso(now - 60), [{'type': 'tool_result', 'tool_use_id': 'a', 'content': 'ok'}])]
v = M['replay'](lines, now)
assert v == 'kind=wakeup next=%d ttl=600' % (now + 540), v
with tempfile.NamedTemporaryFile('w', suffix='.jsonl', delete=False) as fh:
    fh.write('x' * 5000 + '\n' + '\n'.join(lines[1:]) + '\n')
assert M['tail_lines'](fh.name, 1000) == lines[1:], M['tail_lines'](fh.name, 1000)
os.unlink(fh.name)
PY
CHECKS=$((CHECKS+1))
tf kill-window -t "$W"

# --- D. sweep (the `loopmark` apply step's pass) -------------------------------------
SID1=11111111-2222-3333-4444-555555555555; SID2=66666666-7777-8888-9999-aaaaaaaaaaaa
: > "$WORK/proj/-w/$SID1.jsonl"; tr_wake "$WORK/proj/-w/$SID1.jsonl" $((NOW - 60)) '{"delaySeconds":1200,"prompt":"x"}'
: > "$WORK/proj/-w/$SID2.jsonl"; tr_wake "$WORK/proj/-w/$SID2.jsonl" $((NOW - 9000)) '{"delaySeconds":1200,"prompt":"x"}'
D1=$(win d1 130); tf set-window-option -t "$D1" @cc_session_id "$SID1"
D2=$(win d2 131); tf set-window-option -t "$D2" @cc_session_id "$SID2"
D3=$(win d3 132); tf set-window-option -t "$D3" @cc_agent codex
tf new-window -d -t "$SESS" -n dash "exec sleep 300"
out=$(python3 "$BIN/fleet_loop_mark.py" sweep --socket-name "$SESS"); rc=$?
# par + d1 + d2 have no codex/panel exemption; par has no transcript → not counted
st_eq "D: sweep marks the pending one of the two Claude windows it can read" "0 marked=1 windows=2" "$rc $out"
case "$(opt "$D1" @loop)" in "kind=wakeup next="*) CHECKS=$((CHECKS+1)) ;; *) st_fail "D: d1 must be marked" "$(opt "$D1" @loop)" ;; esac
st_eq "D: the lapsed one is not" "" "$(opt "$D2" @loop)"
out=$(python3 "$BIN/fleet_loop_mark.py" sweep --socket-name "$SESS"); rc=$?
st_eq "D: a second sweep finds it already marked" "0 marked=0 windows=2" "$rc $out"
tf kill-window -t "$D1"; tf kill-window -t "$D2"; tf kill-window -t "$D3"; tf kill-window -t "$SESS:dash"

# --- E. degenerate: nothing to wait on → today's Stop, byte for byte -------------------
E=$(win plain 140)
stop "$E"
got="$(tf show-options -w -t "$E" | grep '^@' | cut -d' ' -f1 | sort | tr '\n' ' ')$(opt "$E" @claude_state)/$(opt "$E" @claude_needs)"
# …plus @claude_state_src (issue #2537): every state write says who made it.
want="@claude_needs @claude_state @claude_state_src @claude_state_ts @issue done/"
st_eq "E: the window carries exactly today's options" "$want" "$got"
stop "$E" '{"hook_event_name":"Stop","transcript_path":"/nonexistent/x.jsonl"}'
got="$(tf show-options -w -t "$E" | grep '^@' | cut -d' ' -f1 | sort | tr '\n' ' ')$(opt "$E" @claude_state)/$(opt "$E" @claude_needs)"
st_eq "E: …with a payload too" "$want" "$got"
out=$(fleet_window_wait "$SESS" "$E"); rc=$?
st_eq "E: fleet_window_wait answers nothing" "1 " "$rc $out"

# --- F. tool (issue #1880) -------------------------------------------------------------
# Claude Code moves an MCP call past 120 s to a background task and the turn ends
# with the call in flight: #1876's worker read `done` for 2m44s while its
# pr_verdict --wait ran on. The fact is the fleet MCP server's live child.
rm -f "$WORK/tw.pid"
TW=$(win tw 150 '' "exec bash $FAKE tool call $WORK/tw.pid")
TI=$(win ti 151 '' "exec bash $FAKE tool idle")
TP=$(win tp 152 '' "exec bash $FAKE tool probe")
for _ in $(seq 1 50); do
  [ -s "$WORK/tw.pid" ] && pgrep -f "fbin/fleet-mcp.py --probe" >/dev/null 2>&1 && break
  sleep 0.1
done
fleet_window_tool_busy "$SESS" "$TW"; st_eq "F: a server with a live call is busy" 0 $?
fleet_window_tool_busy "$SESS" "$TI"; st_eq "F: an idle server is not a call" 1 $?
fleet_window_tool_busy "$SESS" "$TP"; st_eq "F: a server probing a new version is not" 1 $?
FLEET_TOOL_WAIT=0 fleet_window_tool_busy "$SESS" "$TW"; st_eq "F: FLEET_TOOL_WAIT=0 turns it off" 1 $?
stop "$TW"
st_eq "F: a fleet tool call in flight → looping + tool" "looping tool" "$(opt "$TW" @claude_state) $(opt "$TW" @claude_wait)"
out=$(fleet_child_busy "$SESS" "$TW"); rc=$?
st_eq "F: fleet_child_busy says tool (gh never asked)" "0 tool" "$rc $out"
tf set-window-option -t "$TW" @claude_state 'done'
out=$(reap "$TW"); rc=$?
st_eq "F: reap-live retains it" "1 retained:tool" "$rc $out"
# the cfg-restart judge: a stale session stamped `done` by a writer that never asked
# is still not reopened while its call runs
mkdir -p "$WORK/conf/global"; printf 'claude fp-new x\n' > "$WORK/conf/global/agent-cfg.expected"
tf set-window-option -t "$TW" @agent_cfg fp-old \; set-window-option -t "$TW" @claude_state_ts 1
out=$(fleet_cfg_restart_why "$SESS" "$TW"); rc=$?
st_eq "F: cfg-restart refuses: tool" "1 tool" "$rc $out"
rm -f "$WORK/conf/global/agent-cfg.expected"
stop "$TI"
st_eq "F: an idle server → done" 'done' "$(opt "$TI" @claude_state)"
hasopt "$TI" @claude_wait && st_fail "F: no reason, no option" "$(tf show-options -w -t "$TI")"
CHECKS=$((CHECKS+1))
stop "$TP"
st_eq "F: a probing server → done" 'done' "$(opt "$TP" @claude_state)"
# the call returns: the re-ask (the sleep tick's fleet-wait-reeval.sh) writes done
stop "$TW"
st_eq "F: still in flight → still looping" "looping tool" "$(opt "$TW" @claude_state) $(opt "$TW" @claude_wait)"
kill "$(cat "$WORK/tw.pid")" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$(cat "$WORK/tw.pid")" 2>/dev/null || break; sleep 0.1; done
out=$(fleet_window_reeval "$SESS" "$TW"); rc=$?
st_eq "F: the call returned → the re-ask writes done" "0 looping (tool) -> done" "$rc $out"
hasopt "$TW" @claude_wait && st_fail "F: the reason goes with it" "$(tf show-options -w -t "$TW")"
CHECKS=$((CHECKS+1))
tf kill-window -t "$TW"; tf kill-window -t "$TI"; tf kill-window -t "$TP"

printf 'fleet-wait-selftest: OK (%d checks)\n' "$CHECKS"
