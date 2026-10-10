#!/bin/bash
# fleet-orchestrator-state-selftest.sh — the orchestrator's state relay across a
# compaction (issue #2583, EPIC #2581 C2): bin/fleet-orchestrator-state.py.
#
# On an ISOLATED tmux socket (PATH shim, never the live server), with no live Claude:
#   A. PreCompact(manual) in the orchestrator window writes
#      global/orchestrator.state.json: the EPIC batch mark + its driver window
#      (@epic), the children still out and the reports past seen_seq (the
#      FLEET_ORCH_CHILDREN_CMD seam), the Loop off the transcript;
#   B. SessionStart(compact) hands it back: additionalContext with the batch number
#      and the Loop's prompt, ≤ 40 lines, the reports marked read, and — after a
#      MANUAL compaction — the resume turn started (@compact_stage restored);
#   C. a worker pane, a Codex orchestrator, a headless child, FLEET_ORCH_STATE=0:
#      nothing written, nothing printed;
#   D. a state older than 2 hours is 只当参考; 30 children still fit 40 lines;
#   E. PostToolUse ScheduleWakeup updates the loop in place, stop:true clears it;
#      a UserPromptSubmit without a [child-report] touches nothing;
#   F. fleet-compact-resume.sh --brief in the orchestrator window prints the state;
#   G. the hook table wires every event, and the Codex emit drops the command;
#   B also: SessionStart(clear) — a /fleet-handoff's new conversation (#2937) — gets
#      the picture plus the handoff doc, until another conversation picked it up.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
S="$BIN/fleet-orchestrator-state.py"
REAL_TMUX="$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux 2>/dev/null)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-orchestrator-state: python3 absent — SKIP\n'; exit 0; }
[ -n "$REAL_TMUX" ] || { printf 'fleet-orchestrator-state: tmux absent — SKIP\n'; exit 0; }
CHECKS=0
fail() { printf 'fleet-orchestrator-state-selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
has() { case "$2" in *"$3"*) ok ;; *) fail "$1 (missing '$3')" "$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1 (unexpected '$3')" "$2" ;; *) ok ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/orchstate.XXXXXX")
SOCK="$T/sock"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/tbin" "$T/conf/global/epic-running.d" "$T/home"
printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$T/tbin/tmux"; chmod +x "$T/tbin/tmux"
nt() { "$REAL_TMUX" -S "$SOCK" "$@"; }

nt -f /dev/null new-session -d -s fl -n home -x 100 -y 30 'exec sleep 600' || fail "cannot start the isolated tmux server"
OW=$(nt new-window -d -P -F '#{window_id}' -t fl: -n orchestrator 'exec sleep 600')
OP=$(nt display-message -p -t "$OW" '#{pane_id}')
nt set-option -wq -t "$OW" @fleet_role orchestrator
WW=$(nt new-window -d -P -F '#{window_id}' -t fl: -n issue-7 'exec sleep 600')
WP=$(nt display-message -p -t "$WW" '#{pane_id}')
nt set-option -wq -t "$WW" @fleet_role worker; nt set-option -wq -t "$WW" @issue 7
DW=$(nt new-window -d -P -F '#{window_id}' -t fl: -n '角色·批次' 'exec sleep 600')
nt set-option -wq -t "$DW" @epic 'o/n#2581'

NOW=$(date +%s)
printf 'epoch: %s\nttl: 2700\nepic: 2581\nrepo: o/n\nsession: fl\ntick: 3\n' "$NOW" > "$T/conf/global/epic-running.d/o-n-2581"

# The children seam: what `fleet-children.sh orchestrator --json [--since N]` answers.
cat > "$T/children" <<'EOF'
#!/bin/sh
case "$*" in
  *--since*) printf '%s\n' '{"parent":"orchestrator","seq":12,"summary":{"text":"1/3 ✓ · 1!"},"children":[],"events":[{"child":"issue-2582","state":"MERGED","pr":2590,"summary":"角色进系统提示","seq":11}]}' ;;
  *) printf '%s\n' '{"parent":"orchestrator","seq":12,"summary":{"text":"1/3 ✓ · 1!"},"children":[{"child":"issue-2583","bucket":"▸","state":"working","title":"压缩前后状态接力","pr":""},{"child":"issue-2584","bucket":"!","state":"needs","title":"拦下误按的退出","pr":2601},{"child":"issue-2582","bucket":"✓","state":"gone","title":"角色进系统提示","pr":2590,"last":{"child":"issue-2582","state":"MERGED","pr":2590,"summary":"角色进系统提示","seq":11}}]}' ;;
esac
EOF
chmod +x "$T/children"

# A transcript whose last ScheduleWakeup is pending.
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
TR="$T/tr.jsonl"
cat > "$TR" <<EOF
{"type":"assistant","timestamp":"$TS","message":{"content":[{"type":"tool_use","id":"tu1","name":"ScheduleWakeup","input":{"delaySeconds":1200,"prompt":"/fleet-epic-watch 2581","reason":"watching the batch"}}]}}
{"type":"user","timestamp":"$TS","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"scheduled"}]}}
EOF

run() {   # run <pane> <stdin json> [env…]
  local p="$1" j="$2"; shift 2
  printf '%s' "$j" | env PATH="$T/tbin:$PATH" HOME="$T/home" FLEET_CONF_DIR="$T/conf" TMUX="$SOCK,1,0" TMUX_PANE="$p" \
    CLAUDE_CODE_ENTRYPOINT=cli FLEET_ORCH_CHILDREN_CMD="$T/children" FLEET_COMPACT_RESUME=0 "$@" python3 "$S" hook
}
STATE="$T/conf/global/orchestrator.state.json"
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$STATE" "$1"; }

# --- A. PreCompact writes the state -------------------------------------------
out=$(run "$OP" "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"transcript_path\":\"$TR\"}")
[ -z "$out" ] || fail "A: PreCompact printed something" "$out"; ok
[ -s "$STATE" ] || fail "A: no state file written"; ok
[ "$(field "d['batches'][0]['epic']")" = 2581 ] || fail "A: batch not recorded" "$(cat "$STATE")"; ok
[ "$(field "d['batches'][0]['driver']")" = '角色·批次' ] || fail "A: driver window not found by @epic" "$(cat "$STATE")"; ok
[ "$(field "d['loop']['prompt']")" = '/fleet-epic-watch 2581' ] || fail "A: loop prompt not read off the transcript" "$(cat "$STATE")"; ok
[ "$(field "d['loop']['delay']")" = 1200 ] || fail "A: loop delay" "$(cat "$STATE")"; ok
[ "$(field "d['trigger']")" = manual ] || fail "A: trigger not kept"; ok
[ "$(field "[k['child'] for k in d['waiting']]")" = "['issue-2583', 'issue-2584']" ] || fail "A: waiting children" "$(cat "$STATE")"; ok
[ "$(field "[e['child'] for e in d['unread_reports']]")" = "['issue-2582']" ] || fail "A: unread reports" "$(cat "$STATE")"; ok

# --- B. SessionStart(compact) hands it back -----------------------------------
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"compact"}')
ctx=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])') \
  || fail "B: SessionStart did not print hook JSON" "$out"
has "B: the role line" "$ctx" '你是这台 fleet 的编排会话'
has "B: the batch number" "$ctx" 'EPIC #2581'
has "B: the driver" "$ctx" '角色·批次'
has "B: the loop prompt" "$ctx" '/fleet-epic-watch 2581'
has "B: re-arm step" "$ctx" '重新 arm 循环'
has "B: waiting child" "$ctx" 'issue-2584'
has "B: unread report" "$ctx" 'issue-2582 MERGED'
hasnt "B: fresh state is not 只当参考" "$ctx" '只当参考'
[ "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" -le 40 ] || fail "B: more than 40 lines" "$ctx"; ok
[ "$(field "d['seen_seq']")" = 12 ] || fail "B: reports not marked read"; ok
[ "$(nt display-message -p -t "$OP" '#{@compact_stage}')" = restored ] || fail "B: a manual compaction did not start the resume turn"; ok
# a second compaction with no new report: nothing unread any more
run "$OP" "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"transcript_path\":\"$TR\"}" >/dev/null
[ "$(field "len(d['unread_reports'])")" = 0 ] || fail "B: a read report came back unread" "$(cat "$STATE")"; ok
nt set-option -wqu -t "$OP" @compact_stage
run "$OP" '{"hook_event_name":"SessionStart","source":"compact"}' >/dev/null
[ -z "$(nt display-message -p -t "$OP" '#{@compact_stage}')" ] || fail "B: an AUTO compaction (it carries on) got a resume turn"; ok
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"resume"}'); has "B: resume injects too" "$out" 'EPIC #2581'
# a /fleet-handoff's new conversation (source clear, issue #2937) gets the picture too,
# and — while the handoff record has not been picked up by another — its doc
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"clear","session_id":"s-1"}')
has "B: clear injects (a handoff's new conversation)" "$out" 'EPIC #2581'
hasnt "B: no handoff record, no doc" "$out" '接力文档'
mkdir -p "$T/conf/fleets/fl"
printf 'sid=s-0\nstore=/x/handoff.md\npickup=/fleet-handoff pickup /x/handoff.md\nat=%s\nctx=65\n' "$(date +%s)" \
  > "$T/conf/fleets/fl/orchestrator.handoff"
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"clear","session_id":"s-1"}')
has "B: the handoff doc named" "$out" '接力文档：/x/handoff.md'
has "B: the next step is the doc's" "$out" '照接力文档的 NEXT ACTION'
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"compact","session_id":"s-1"}')
hasnt "B: a compaction does not re-point at the handoff" "$out" '接力文档'
printf 'next=s-1\n' >> "$T/conf/fleets/fl/orchestrator.handoff"
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"startup","session_id":"s-2"}')
has "B: a later startup still gets the picture" "$out" 'EPIC #2581'
hasnt "B: a doc another conversation picked up is not named again" "$out" '接力文档'
rm -f "$T/conf/fleets/fl/orchestrator.handoff"

# --- C. nobody else -----------------------------------------------------------
cp "$STATE" "$T/before"
out=$(run "$WP" "{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"transcript_path\":\"$TR\"}")
out="$out$(run "$WP" '{"hook_event_name":"SessionStart","source":"compact"}')"
[ -z "$out" ] && cmp -s "$STATE" "$T/before" || fail "C: a worker pane read or wrote the orchestrator state" "$out"; ok
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"compact"}' CLAUDE_CODE_ENTRYPOINT=sdk-cli)
[ -z "$out" ] || fail "C: a headless child got the state" "$out"; ok
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"compact"}' FLEET_ORCH_STATE=0)
[ -z "$out" ] || fail "C: FLEET_ORCH_STATE=0 still injected" "$out"; ok
nt set-option -wq -t "$OW" @cc_agent codex
out=$(run "$OP" '{"hook_event_name":"SessionStart","source":"compact"}')
[ -z "$out" ] || fail "C: a Codex orchestrator got the state (convention 5)" "$out"; ok
nt set-option -wqu -t "$OW" @cc_agent

# --- D. stale and long --------------------------------------------------------
python3 - "$STATE" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p))
d['ts'] = int(time.time()) - 3 * 3600
d['waiting'] = [dict(child='issue-%d' % n, bucket='▸', state='working', title='t', pr='') for n in range(30)]
d['unread_reports'] = [dict(child='issue-%d' % n, state='MERGED', pr=n, summary='s', seq=n) for n in range(20)]
d['batches'] = [dict(epic=n, repo='o/n', driver='d', tick='1', last_tick=int(time.time()), fresh=True) for n in range(9)]
json.dump(d, open(p, 'w'))
PY
ctx=$(env FLEET_CONF_DIR="$T/conf" python3 "$S" brief --no-mark)
has "D: stale state" "$ctx" '只当参考'
[ "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" -le 40 ] || fail "D: a long state broke 40 lines" "$ctx"; ok
has "D: the loop survives the cut" "$ctx" '重新 arm 循环'

# --- E. incremental -----------------------------------------------------------
run "$OP" '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":600,"prompt":"<<autonomous-loop-dynamic>>"}}' >/dev/null
[ "$(field "d['loop']['prompt']")" = '<<autonomous-loop-dynamic>>' ] || fail "E: ScheduleWakeup did not update the loop" "$(cat "$STATE")"; ok
[ "$(field "d['loop']['delay']")" = 600 ] || fail "E: delay"; ok
run "$OP" '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"stop":true}}' >/dev/null
[ "$(field "d['loop']")" = None ] || fail "E: stop did not clear the loop"; ok
cp "$STATE" "$T/before"
run "$OP" '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}' >/dev/null
cmp -s "$STATE" "$T/before" || fail "E: an ordinary prompt touched the state"; ok

# --- F. the /fleet-compact-resume brief ---------------------------------------
out=$(env PATH="$T/tbin:$PATH" FLEET_CONF_DIR="$T/conf" TMUX="$SOCK,1,0" TMUX_PANE="$OP" bash "$BIN/fleet-compact-resume.sh" --brief)
has "F: compact-resume brief is the orchestrator's" "$out" '[fleet compact-resume] orchestrator'
has "F: compact-resume brief carries the state" "$out" '在跟的批次'

# --- G. wiring ----------------------------------------------------------------
python3 - "$ROOT/hooks/settings-hooks.json" <<'PY' || fail "G: the hook table does not wire every event"
import json, sys
h = json.load(open(sys.argv[1]))['hooks']
cmd = 'fleet-orchestrator-state.py hook'
def wired(ev, matcher=None):
    return any(cmd in x.get('command', '') for g in h[ev] if matcher is None or g.get('matcher') == matcher
               for x in g.get('hooks', []))
assert wired('PreCompact') and not [g for g in h['PreCompact'] if any(cmd in x['command'] for x in g['hooks']) and g.get('matcher')], 'PreCompact: every trigger'
assert wired('SessionStart', 'compact|resume|startup'), 'SessionStart'
assert wired('SessionEnd'), 'SessionEnd'
assert wired('PostToolUse', 'ScheduleWakeup|CronCreate|CronDelete'), 'PostToolUse'
assert wired('UserPromptSubmit'), 'UserPromptSubmit'
PY
ok
if [ -f "$BIN/fleet-hooks-emit.sh" ]; then
  em=$(bash "$BIN/fleet-hooks-emit.sh" --target codex 2>/dev/null)
  [ -n "$em" ] || fail "G: the codex emit printed nothing"
  hasnt "G: Codex gets no orchestrator state hook" "$em" 'fleet-orchestrator-state.py'
fi

printf 'fleet-orchestrator-state-selftest: PASS (%d checks)\n' "$CHECKS"
