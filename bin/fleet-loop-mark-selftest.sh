#!/bin/bash
# fleet-loop-mark-selftest.sh — the deterministic `@loop` signal (issue #1331).
#
# A worker that ran /loop ends each turn with a ScheduleWakeup (or holds a
# CronCreate job). The Stop hook used to stamp it `done`, so the dash counted it
# finished and the merged-PR reapers closed the window with the Loop inside it.
# This pins the whole chain on an ISOLATED tmux socket (PATH-shim, never the live
# server), with no live Claude:
#   1. the value model — apply()/status(): write, renew, stop, cron add/delete,
#      reader-side expiry, the fleet-loop.py ledger;
#   2. the PostToolUse hook writes and clears @loop on the pane's window, and a
#      headless `claude -p` (CLAUDE_CODE_ENTRYPOINT=sdk-cli) touches nothing;
#   3. the Stop hook stamps `looping` while a Loop is pending, `done` otherwise —
#      and `done` again once the wakeup lapses unrenewed;
#   4. fleet_window_loop (shell), fleet-reap-live.py `retained:loop`, and the EPIC
#      report's per-member probe agree on the same window.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-loop-mark: python3 absent — SKIP\n'; exit 0; }
CHECKS=0
fail() { printf 'fleet-loop-mark-selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')"; }

# --- 1. the value model ------------------------------------------------------
python3 - "$BIN" <<'PY' || fail "value model (see traceback above)"
import json, os, runpy, sys, tempfile
from pathlib import Path
M = runpy.run_path(os.path.join(sys.argv[1], 'fleet_loop_mark.py'))
apply, status = M['apply'], M['status']
T = 1_800_000_000
sw = lambda **i: {'tool_name': 'ScheduleWakeup', 'tool_input': i}

v = apply('', sw(delaySeconds=1800, prompt='x'), T)
assert v == 'kind=wakeup next=%d ttl=1800' % (T + 1800), v
assert status(v, now=T) == ('active', 'wakeup:next=%d' % (T + 1800))
# grace = max(600, ttl/2): still active 900s late, gone after
assert status(v, now=T + 1800 + 900)[0] == 'active'
assert status(v, now=T + 1800 + 901) == ('none', 'expired')
# the clamp: 10s → 60s, 9999s → 3600s, garbage → 60s
assert 'next=%d ttl=60' % (T + 60) in apply('', sw(delaySeconds=10), T)
assert 'ttl=3600' in apply('', sw(delaySeconds=9999), T)
assert 'ttl=60' in apply('', sw(delaySeconds='soon'), T)
# a short ttl still gets the 600s floor
assert status(apply('', sw(delaySeconds=60), T), now=T + 60 + 600)[0] == 'active'
# renewal moves next; stop clears
v2 = apply(v, sw(delaySeconds=600), T + 1800)
assert 'next=%d ttl=600' % (T + 2400) in v2, v2
assert apply(v2, sw(stop=True), T + 1900) == ''

# CronCreate: the id from the structured response (dict) or the text form
cc = lambda resp, **i: {'tool_name': 'CronCreate', 'tool_input': dict(dict(cron='7 * * * *', prompt='x'), **i), 'tool_response': resp}
c1 = apply('', cc({'id': 'd250bcc6', 'recurring': True}), T)
assert c1 == 'kind=cron id=d250bcc6@%d' % (T + 7 * 86400 + 900), c1
c2 = apply(c1, cc('Scheduled recurring task ab12cd34 (7 * * * *).'), T)
assert 'id=d250bcc6@' in c2 and ',ab12cd34@' in c2, c2
assert status(c2, now=T)[1] == 'cron:d250bcc6,ab12cd34'
# an unparseable response records nothing (and never invents an id)
assert apply('', cc('ok'), T) == ''
# a pinned one-shot expires 600s after its fire time, not after 7 days
import time as _t
fire = int(_t.mktime((2027, 3, 14, 15, 9, 0, 0, 0, -1)))
o = apply('', cc({'id': 'one1'}, cron='9 15 14 3 *', recurring=False), fire - 3600)
assert o == 'kind=cron id=one1@%d' % (fire + 600), o
# CronDelete removes that id; the last one clears
cd = lambda j: {'tool_name': 'CronDelete', 'tool_input': {'id': j}}
c3 = apply(c2, cd('d250bcc6'), T)
assert c3 == 'kind=cron id=ab12cd34@%d' % (T + 7 * 86400 + 900), c3
assert apply(c3, cd('ab12cd34'), T) == ''
assert apply(c3, cd('nope'), T) == c3
# both halves at once; stopping the wakeup keeps the cron
both = apply(v, cc({'id': 'cafe01'}), T)
assert both.startswith('kind=wakeup,cron next=') and 'id=cafe01@' in both, both
assert apply(both, sw(stop=True), T) == 'kind=cron id=cafe01@%d' % (T + 7 * 86400 + 900)
# a lapsed half is pruned on the next write
assert apply(v, cc({'id': 'cafe01'}), T + 99999).startswith('kind=cron id=cafe01@')
# malformed values read as none; unset reads unset
assert status('garbage next=x id=@@', now=T) == ('none', 'expired')
assert status('', now=T) == ('none', 'unset')
# the fleet-loop.py ledger: a loop that will still deliver counts
with tempfile.TemporaryDirectory() as d:
    (Path(d) / 'loop').mkdir()
    man = str(Path(d) / 'manifest.json')
    for st, want in (('active', 'active'), ('waiting-quota', 'active'), ('hibernating', 'active'),
                     ('delivering', 'active'), ('stopped', 'none'), ('complete', 'none')):
        (Path(d) / 'loop/state.json').write_text(json.dumps({'status': st}))
        assert status('', man, T)[0] == want, st
    (Path(d) / 'loop/state.json').write_text('{torn')
    assert status('', man, T)[0] == 'none'
PY
CHECKS=$((CHECKS+1))

# --- isolated tmux --------------------------------------------------------------
[ -n "$REAL_TMUX" ] || { printf 'fleet-loop-mark-selftest: OK (%d checks; tmux absent — skipped the socket half)\n' "$CHECKS"; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loopmark.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
trap 'tf kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$WORK/path" "$WORK/conf"
cat > "$WORK/path/tmux" <<SH
#!/bin/sh
case "\${1:-}" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
SH
chmod +x "$WORK/path/tmux"
PATH="$WORK/path:$PATH"; export PATH
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
SESS=fleet1331
tf -f /dev/null new-session -d -s "$SESS" -n worker 'exec sleep 300' || fail "cannot start isolated tmux"
PANE=$(tf display-message -p -t "$SESS:worker" '#{pane_id}')
WIN=$(tf display-message -p -t "$PANE" '#{window_id}')
tf set-window-option -t "$PANE" @issue 1331
TMUXV="$SOCK,1,0"
loopv() { tf display-message -p -t "$PANE" '#{@loop}'; }
st()    { tf display-message -p -t "$PANE" '#{@claude_state}'; }
hookpost() {   # <json> [entrypoint]
  printf '%s' "$1" | env TMUX="$TMUXV" TMUX_PANE="$PANE" CLAUDE_CODE_ENTRYPOINT="${2:-cli}" \
    python3 "$BIN/fleet_loop_mark.py" hook
}
stop() { env TMUX="$TMUXV" TMUX_PANE="$PANE" sh "$BIN/set-claude-state.sh" done </dev/null >/dev/null 2>&1; }

# --- 2. the PostToolUse hook ----------------------------------------------------
hookpost '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":1800,"prompt":"/loop check"}}'
case "$(loopv)" in "kind=wakeup next="*" ttl=1800") CHECKS=$((CHECKS+1)) ;; *) fail "ScheduleWakeup must write @loop" "$(loopv)" ;; esac
hookpost '{"tool_name":"ScheduleWakeup","tool_input":{"stop":true}}'
eq "ScheduleWakeup stop:true clears @loop" "" "$(loopv)"
hookpost '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":600}}' sdk-cli
eq "a headless claude -p's schedule is not this pane's" "" "$(loopv)"
hookpost '{"tool_name":"Bash","tool_input":{"command":"true"}}'
eq "an unrelated tool writes nothing" "" "$(loopv)"
hookpost 'not json'
eq "a malformed payload writes nothing" "" "$(loopv)"
hookpost '{"tool_name":"CronCreate","tool_input":{"cron":"7 * * * *","prompt":"x"},"tool_response":{"id":"ab12cd34"}}'
case "$(loopv)" in "kind=cron id=ab12cd34@"*) CHECKS=$((CHECKS+1)) ;; *) fail "CronCreate must record the job id" "$(loopv)" ;; esac

# --- 3. the Stop hook + 4. every reader agree -----------------------------------
stop
eq "Stop with a pending cron job stamps looping" looping "$(st)"
. "$BIN/fleet-lib.sh"
out=$(fleet_window_loop "$SESS" "$WIN"); rc=$?
eq "fleet_window_loop answers active" "0 active cron:ab12cd34" "$rc $out"
out=$(python3 "$BIN/fleet-reap-live.py" "$WIN" --socket-name "$SESS"); rc=$?
eq "fleet-reap-live.py retains it" "1 retained:loop" "$rc $out"
# even a classifier/demote `done` stamped over it: the mark, not the state, decides
tf set-window-option -t "$PANE" @claude_state done
out=$(FLEET_REAP_MIN_AGE=0 python3 "$BIN/fleet-reap-live.py" "$WIN" --socket-name "$SESS"); rc=$?
eq "…ahead of the state and age gates" "1 retained:loop" "$rc $out"
out=$(bash "$BIN/fleet-epic-loopers.sh" --session "$SESS" --repo o/r 1331 4242)
eq "the EPIC report's probe: looping member + a gone one" \
   "1331	looping	cron:ab12cd34"$'\n'"4242	gone	-" "$out"

hookpost '{"tool_name":"CronDelete","tool_input":{"id":"ab12cd34"}}'
eq "CronDelete of the last job clears @loop" "" "$(loopv)"
stop
eq "Stop with no Loop stamps done (today's behaviour)" done "$(st)"
out=$(fleet_window_loop "$SESS" "$WIN"); rc=$?
eq "fleet_window_loop answers none" "1 none unset" "$rc $out"
out=$(FLEET_REAP_MIN_AGE=0 python3 "$BIN/fleet-reap-live.py" "$WIN" --socket-name "$SESS"); rc=$?
case "$out" in retained:loop) fail "no @loop must never answer retained:loop" "$out" ;; esac
CHECKS=$((CHECKS+1))
out=$(bash "$BIN/fleet-epic-loopers.sh" --session "$SESS" --repo o/r 1331)
eq "the EPIC probe: an idle member" "1331	idle	unset" "$out"

# a wakeup nobody renewed: past next + grace the Loop has stopped on its own
now=$(date +%s)
tf set-window-option -t "$PANE" @loop "kind=wakeup next=$((now - 3600)) ttl=1800"
stop
eq "Stop after an unrenewed wakeup lapsed stamps done" done "$(st)"
out=$(fleet_window_loop "$SESS" "$WIN"); rc=$?
eq "fleet_window_loop: the lapsed mark reads expired" "1 none expired" "$rc $out"
tf set-window-option -t "$PANE" @loop "kind=wakeup next=$((now + 600)) ttl=600"
stop
eq "a live wakeup stamps looping" looping "$(st)"

# a fleet-loop.py ledger loop with no @loop mark (a transferred Codex/Claude loop)
tf set-window-option -u -t "$PANE" @loop
mkdir -p "$WORK/handoff/loop"
printf '{"status":"active"}\n' > "$WORK/handoff/loop/state.json"
tf set-window-option -t "$PANE" @handoff_manifest "$WORK/handoff/manifest.json"
stop
eq "a live loop ledger stamps looping" looping "$(st)"
printf '{"status":"stopped"}\n' > "$WORK/handoff/loop/state.json"
stop
eq "a stopped loop ledger stamps done" done "$(st)"

printf 'fleet-loop-mark-selftest: OK (%d checks)\n' "$CHECKS"
