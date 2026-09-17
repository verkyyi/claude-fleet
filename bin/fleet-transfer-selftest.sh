#!/bin/bash
# Single-session transfer tests on a PRIVATE named socket, real worktrees and
# fake Claude/Codex processes. No model requests, GitHub calls or live hooks.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for dep in tmux python3 perl git; do
  command -v "$dep" >/dev/null 2>&1 || { printf 'fleet-transfer selftest: SKIP (%s missing)\n' "$dep"; exit 0; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-transfer-selftest.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
LBL="transfer-selftest-$$-$RANDOM"
TM() { tmux -L "$LBL" "$@"; }
cleanup() { TM kill-server 2>/dev/null || :; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
checks=0
fail() { printf 'fleet-transfer selftest FAIL: %s\n%s\n' "$1" "${OUT:-}" >&2; exit 1; }
ok() { checks=$((checks+1)); }

IBIN="$WORK/install/bin"; FB="$WORK/fakebin"
mkdir -p "$IBIN" "$FB" "$WORK/sessions" "$WORK/projects/actual" "$WORK/conf/fleets/$LBL"
for f in fleet-transfer.sh .fleet-transfer.py .fleet-transfer-wait.py fleet-loop.py fleet-lib.sh fleet-lang.sh session-end-hook.sh set-claude-state.sh fleet-hook-conf.sh; do cp "$BIN/$f" "$IBIN/$f"; done
export FLEET_CONF_DIR="$WORK/conf" FLEET_CC_SESSIONS_DIR="$WORK/sessions" FLEET_CC_PROJECTS_DIR="$WORK/projects"
export FLEET_TRANSFER_EXIT_WAIT=2 FLEET_TRANSFER_BOOT_WAIT=3
export TRANSFER_TEST_ROOT="$WORK"
TRANSFER_TEST_TMUX=$(command -v tmux)
export TRANSFER_TEST_TMUX
export PATH="$FB:$PATH"
# All operations use real isolated tmux; this one read seam models a client
# typing in the target window without attaching to a user's terminal.
cat > "$FB/tmux" <<'SH'
#!/bin/bash
if [ "${3:-}" = list-clients ] && [ -f "$TRANSFER_TEST_ROOT/typing-client" ]; then
  cat "$TRANSFER_TEST_ROOT/typing-client"
  exit 0
fi
exec "$TRANSFER_TEST_TMUX" "$@"
SH
chmod +x "$FB/tmux"
# The existing process-tree probe also verifies recovery: tmux's
# pane_current_command may name the interpreter/runner instead of Claude.
# shellcheck source=/dev/null
. "$IBIN/fleet-lib.sh"
MAIN="$WORK/base"
git init -q "$MAIN" || fail 'git init'
git -C "$MAIN" config user.name test; git -C "$MAIN" config user.email test@example.invalid
printf 'base\n' > "$MAIN/file"
git -C "$MAIN" add file; git -C "$MAIN" commit -qm initial || fail 'initial commit'
printf 'FLEET_MAIN=%q\nFLEET_REPO=fake/repo\n' "$MAIN" > "$FLEET_CONF_DIR/fleets/$LBL/conf"

ln -s "$(command -v perl)" "$FB/claude"
ln -s "$(command -v perl)" "$FB/codex"
cat > "$WORK/claude.pl" <<'PL'
use JSON::PP; use Cwd;
my ($sid, $mode) = @ARGV;
alarm 120;
open(my $r, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/$$.json") or die;
print $r encode_json({sessionId=>$sid, cwd=>getcwd(), peerToken=>'never-copy-the-registry-secret'}); close $r;
$| = 1; print "Claude ready $sid\n";
while (my $line = <STDIN>) {
    next unless $line =~ m{/exit};
    next if $mode eq 'stuck';
    $ENV{FLEET_SESSION_END_REASON} = 'prompt_input_exit';
    system('/bin/bash', "$ENV{TRANSFER_TEST_ROOT}/install/bin/session-end-hook.sh");
    exit 0;
}
PL
cat > "$WORK/codex.pl" <<'PL'
use JSON::PP;
alarm 120;
open(my $f, '>', "$ENV{TRANSFER_TEST_ROOT}/target-argv.json") or die;
print $f encode_json({argv=>\@ARGV, manifest=>$ENV{FLEET_HANDOFF_MANIFEST}}); close $f;
$| = 1; print "Codex ready\n";
while (<STDIN>) { }
PL
cat > "$FB/source-runner" <<'SH'
#!/bin/bash
"$TRANSFER_TEST_ROOT/fakebin/claude" "$TRANSFER_TEST_ROOT/claude.pl" "$1" "$2"
if [ "$2" = tool ]; then exec sleep 60; fi
exec /bin/bash --noprofile --norc -i
SH
cat > "$IBIN/fleet-claude.sh" <<'SH'
#!/bin/bash
[ "$1" = --agent ] && [ "$2" = claude ] && exec "$TRANSFER_TEST_ROOT/fakebin/claude" "$TRANSFER_TEST_ROOT/claude.pl" "$4" normal
[ "$1" = --agent ] && [ "$2" = codex ] || exit 90
[ ! -f "$TRANSFER_TEST_ROOT/fail-target" ] || exit 37
exec "$TRANSFER_TEST_ROOT/fakebin/codex" "$TRANSFER_TEST_ROOT/codex.pl" "$@"
SH
printf '#!/bin/sh\nexit 0\n' > "$IBIN/fleet-codex.sh"
printf '#!/bin/sh\nprintf "PreToolUse\\tbash-guard.py base-readonly-guard.py\\n"\n' > "$IBIN/fleet-hooks-emit.sh"
cat > "$FB/gh" <<'SH'
#!/bin/sh
printf 'unexpected gh invocation\n' >> "$TRANSFER_TEST_ROOT/gh-called"
exit 1
SH
chmod +x "$FB/source-runner" "$FB/gh" "$IBIN"/*.sh
TM new-session -d -s "$LBL" -n plan -c "$MAIN" || fail 'isolated tmux server'
TM set-option -g default-shell /bin/bash

spawn() { # n, issue|raw, normal|stuck|tool
  local n=$1 kind=$2 mode=$3 branch cmd
  case "$kind" in issue) branch="issue-$n" ;; *) branch="scratch-$n" ;; esac
  WT="$WORK/wt '$n percent%"
  git -C "$MAIN" worktree add -qb "$branch" "$WT" || fail 'worktree'
  SID="source-$n"
  TRANSCRIPT="$WORK/projects/actual/$SID.jsonl"
  python3 - "$SID" "$TRANSCRIPT" <<'PY'
import json, sys
sid, path = sys.argv[1:]
with open(path, 'w') as f:
    for role, text in [('user', '请继续修复原任务，保留未提交修改。'), ('assistant', '已定位问题；下一步补验证。')]:
        f.write(json.dumps({'type': role, 'sessionId': sid, 'message': {'content': [{'type': 'text', 'text': text}]}}) + '\n')
PY
  printf -v cmd '%q %q %q' "$FB/source-runner" "$SID" "$mode"
  WIN=$(TM new-window -d -t "$LBL:" -n "task-$n" -c "$WT" -P -F '#{window_id}' "$cmd") || fail 'source window'
  PANE=$(TM display-message -p -t "$WIN" '#{pane_id}')
  TM set-option -w -t "$WIN" @worktree "$WT"
  TM set-option -w -t "$WIN" @wid a1
  TM set-option -w -t "$WIN" @origin scratch-99
  TM set-option -w -t "$WIN" @claude_state "done"
  if [ "$kind" = issue ]; then TM set-option -w -t "$WIN" @issue "$n"; else TM set-option -w -t "$WIN" @raw 1; fi
  PID=''
  for ((attempt=0; attempt<30; attempt++)); do
    for f in "$WORK/sessions"/*.json; do
      [ -f "$f" ] || continue
      if grep -q "$SID" "$f"; then PID=${f##*/}; PID=${PID%.json}; break; fi
    done
    [ -n "$PID" ] && break
    sleep 0.1
  done
  [ -n "$PID" ] || fail 'source registry'
}
transfer() { OUT=$(bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$WIN" --to codex "$@" 2>&1); }
packet() { printf '%s\n' "$OUT" | sed -n 's/^handoff package: //p'; }
field() { TM display-message -p -t "$WIN" "#{@$1}"; }
stop_turn() {
  local sp
  sp=$(TM display-message -p -t "$PANE" '#{socket_path}')
  TMUX="$sp,0,0" TMUX_PANE="$PANE" bash "$IBIN/set-claude-state.sh" "done" </dev/null
}
wait_request() {
  local expected=$1 status attempt
  for ((attempt=0; attempt<100; attempt++)); do
    status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$REQUEST/state.json")
    if [ "$status" = "$expected" ] && [ -z "$(field agent_transfer_request)" ]; then return 0; fi
    [ "$status" != failed ] || [ "$expected" = failed ] || break
    sleep 0.1
  done
  OUT=$(cat "$REQUEST/state.json" "$REQUEST/wait.log")
  fail "after-turn request did not finish as $expected"
}

spawn 41 issue normal
TM set-option -wu -t "$WIN" @worktree
printf 'staged\n' > "$WT/file"; git -C "$WT" add file
printf 'unstaged\n' >> "$WT/file"; printf 'untracked\n' > "$WT/untracked"
BEFORE=$(git -C "$WT" diff --binary HEAD)
# A newer helper transcript must never win over the source process registry.
printf '{"type":"user","sessionId":"helper","message":{"content":"helper noise"}}\n' > "$WORK/projects/actual/helper.jsonl"
transfer --dry-run || fail 'dry-run'
ok; [ ! -e "$FLEET_CONF_DIR/handoffs" ] && [ ! -e "$FLEET_CONF_DIR/rotating" ] || fail 'dry-run must not write packages or leases'
ok; kill -0 "$PID" && [ "$(field cc_agent)" = '' ] || fail 'dry-run changed the source'
ok; [ -z "$(field worktree)" ] || fail 'dry-run must not stamp a missing worktree'
printf '# 人工交接\n下一步：验证 file 的改动。\n' > "$WORK/notes.md"
transfer --prepare-only --handoff "$WORK/notes.md" || fail 'prepare-only'
BUNDLE=$(packet)
ok; kill -0 "$PID" || fail 'prepare-only stopped Claude'
python3 - "$BUNDLE" "$SID" "$TRANSCRIPT" "$WT" <<'PY' || fail 'provenance, snapshot, notes, git state or private permissions'
import hashlib, json, pathlib, stat, sys
b, sid, original, wt = sys.argv[1:]; b = pathlib.Path(b)
m = json.loads((b/'manifest.json').read_text()); s = m['source']
assert s['agent'] == 'claude' and s['session_id'] == sid
assert s['transcript_path'] == original and m['workspace']['path'] == wt
assert m['target']['agent'] == 'codex' and m['fleet']['issue'] == '41'
snapshot = (b/'source.jsonl').read_bytes()
assert snapshot == pathlib.Path(original).read_bytes()
assert hashlib.sha256(snapshot).hexdigest() == s['snapshot_sha256']
assert '人工交接' in (b/'handoff.md').read_text()
assert 'never-copy-the-registry-secret' not in ''.join(f.read_text() for f in b.iterdir())
assert sid in (b/'pickup.md').read_text() and original in (b/'pickup.md').read_text()
assert 'staged' in (b/'staged.patch').read_text() and 'unstaged' in (b/'unstaged.patch').read_text()
assert 'untracked' in (b/'git-status.txt').read_text()
assert stat.S_IMODE(b.stat().st_mode) == 0o700
assert all(stat.S_IMODE(f.stat().st_mode) == 0o600 for f in b.iterdir())
PY
ok

mv "$WORK/sessions/$PID.json" "$WORK/registry-saved"
transfer --prepare-only && fail 'missing registry must not guess the newest transcript'
ok; kill -0 "$PID" || fail 'missing registry must keep source running'
mv "$WORK/registry-saved" "$WORK/sessions/$PID.json"
TM set-option -w -t "$WIN" @claude_state working
transfer && fail 'busy source must refuse cutover'; ok
TM set-option -w -t "$WIN" @claude_state "done"
SP=$(TM display-message -p -t "$PANE" '#{socket_path}')
OUT=$(TMUX="$SP,0,0" TMUX_PANE="$PANE" bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$WIN" --to codex 2>&1) \
  && fail 'source cannot replace its own tool pane'
ok
TM set-option -w -t "$WIN" @handoff_armed 1
transfer && fail 'pending auto-handoff must refuse cutover'; ok
TM set-option -wu -t "$WIN" @handoff_armed

transfer --handoff "$WORK/notes.md" || fail 'actual issue-worker cutover'
BUNDLE=$(packet)
ok; ! kill -0 "$PID" 2>/dev/null || fail 'source process must exit'
ok; [ "$(field issue)" = 41 ] && [ "$(field wid)" = a1 ] && [ "$(field origin)" = scratch-99 ] || fail 'window bindings changed'
ok; [ "$(field cc_agent)" = codex ] && [ "$(field source_session_id)" = "$SID" ] && [ "$(field source_transcript)" = "$TRANSCRIPT" ] || fail 'target provenance stamps missing'
ok; [ "$(field worktree)" = "$WT" ] || fail 'issue-worker cutover must record verified worktree'
ok; [ "$(git -C "$WT" diff --binary HEAD)" = "$BEFORE" ] && [ -f "$WT/untracked" ] || fail 'cutover modified the source work'
python3 - "$BUNDLE" "$WORK/target-argv.json" <<'PY' || fail 'target must receive the exact pickup prompt and manifest'
import json, pathlib, sys
b = pathlib.Path(sys.argv[1]); target = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert target['manifest'] == str(b/'manifest.json')
assert target['argv'][:2] == ['--agent', 'codex']
assert target['argv'][2] == (b/'pickup.md').read_text().rstrip('\n')
assert json.loads((b/'state.json').read_text())['state'] == 'started'
PY
ok
ok; [ ! -f "$WORK/gh-called" ] || fail 'transfer must suppress SessionEnd reap, not invoke GitHub'
ok; [ -z "$(field agent_transfer_until)" ] || fail 'successful transfer must release its marker'
OUT=$(bash "$BUNDLE/resume-source.sh" 2>&1) && fail 'manual recovery must refuse while Codex is alive'; ok
SENTINEL="$WIN"

spawn 42 raw normal
git -C "$WT" checkout --detach -q || fail 'detached scratch fixture'
# Clean scratch at the base commit: SessionEnd/cleanup must keep it for Codex.
transfer || fail 'clean scratch cutover'; ok
python3 - "$(packet)/manifest.json" <<'PY' || fail 'detached HEAD provenance'
import json, sys
assert json.load(open(sys.argv[1]))['workspace']['branch'] is None
PY
ok; [ -z "$(git -C "$WT" branch --show-current)" ] || fail 'transfer must preserve detached HEAD'
ok; [ "$(field raw)" = 1 ] && [ -f "$WT/file" ] || fail 'clean scratch worktree lost'
ok; [ "$(TM display-message -p -t "$SENTINEL" '#{@source_session_id}')" = source-41 ] || fail 'unrelated session changed'

spawn 43 issue stuck
transfer && fail 'unresponsive source must fail'; ok
ok; kill -0 "$PID" && [ "$(field cc_agent)" = '' ] || fail 'unresponsive source was killed or replaced'
BUNDLE=$(packet)
ok; [ -s "$BUNDLE/manifest.json" ] && [ -s "$BUNDLE/resume-source.sh" ] || fail 'failure must preserve handoff and recovery recipe'

spawn 44 issue normal
touch "$WORK/fail-target"
transfer && fail 'target startup failure must fail'; ok
BUNDLE=$(packet)
ok; [ -d "$WT" ] && [ "$(TM display-message -p -t "$PANE" '#{pane_dead}')" = 1 ] || fail 'failed target must leave retained pane and worktree'
python3 - "$BUNDLE" <<'PY' || fail 'failed target recovery metadata'
import json, pathlib, sys
b = pathlib.Path(sys.argv[1])
assert json.loads((b/'state.json').read_text())['state'] == 'failed'
assert (b/'source.jsonl').stat().st_size > 0
assert '--resume source-44' in (b/'resume-source.sh').read_text()
PY
ok
rm "$WORK/fail-target"
RLOCK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["transfer_lock_path"])' "$BUNDLE/manifest.json")
mkdir "$RLOCK" || fail 'recovery lock fixture'
OUT=$(bash "$BUNDLE/resume-source.sh" 2>&1) && fail 'recovery must not race a transfer controller'; ok
rmdir "$RLOCK"
OUT=$(bash "$BUNDLE/resume-source.sh" 2>&1) || fail 'manual recovery from dead pane'
RECOVERED=''
for ((attempt=0; attempt<30; attempt++)); do
  RECOVERED=$(fleet_pane_claude_pid "$PANE" "$LBL" 2>/dev/null) && [ -n "$RECOVERED" ] && break
  sleep 0.1
done
ok; [ -n "$RECOVERED" ] && [ "$(fleet_cc_session_id "$RECOVERED")" = "$SID" ] && [ -z "$(field cc_agent)" ] \
  || fail "manual recovery must resume Claude and clear the Codex stamp: $(TM capture-pane -p -t "$PANE")"

spawn 45 issue tool
transfer && fail 'live tool after source exit must refuse respawn'; ok
ok; [ "$(TM display-message -p -t "$PANE" '#{pane_current_command}')" = sleep ] || fail 'leftover tool must not be killed'

spawn 46 raw normal
printf '{"type":' >> "$TRANSCRIPT"
transfer --prepare-only || fail 'prepare snapshot must tolerate a partial last record'; ok
transfer && fail 'cutover with a changing/partial transcript must refuse'; ok
ok; kill -0 "$PID" || fail 'snapshot verification failure must leave source alive'

# The skill's real shape: arm from INSIDE the source turn, then Stop releases a
# detached worker. A stale done stamp cannot replace that signal, and the final
# source message must be in the actual snapshot delivered to Codex.
spawn 47 issue normal
printf '{"prompt":"继续轮询测试任务","interval_seconds":3600}\n' > "$WORK/loop.json"
TM set-option -w -t "$WIN" @claude_state working
transfer --after-turn && fail 'after-turn must require source-written notes'; ok
SP=$(TM display-message -p -t "$PANE" '#{socket_path}')
OUT=$(TMUX="$SP,0,0" TMUX_PANE="$PANE" FLEET_TRANSFER_IDLE_WAIT=30 FLEET_HANDOFF_DEFER_SECS=0 \
  bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$PANE" --to codex \
  --after-turn --handoff "$WORK/notes.md" --loop "$WORK/loop.json" 2>&1) || fail 'arm inside source tool turn'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
ok; [ -s "$REQUEST/request.json" ] && [ -s "$REQUEST/notes.md" ] || fail 'arming must preserve notes and identity'
printf 'CHANGED AFTER ARM\n' > "$WORK/notes.md"
printf '{"prompt":"CHANGED AFTER ARM","interval_seconds":60}\n' > "$WORK/loop.json"
TM set-option -w -t "$WIN" @claude_state "done"
sleep 1
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] || fail 'stale done must not release the after-turn waiter'
transfer --after-turn --handoff "$WORK/notes.md" && fail 'double arm must refuse'; ok
transfer && fail 'immediate transfer must not race the armed skill'; ok
printf '{"type":"assistant","sessionId":"source-47","message":{"content":"FINAL HANDOFF TURN"}}\n' >> "$TRANSCRIPT"
stop_turn
wait_request started; ok
MANIFEST=$(field handoff_manifest); BUNDLE=${MANIFEST%/*}
python3 - "$BUNDLE" "$REQUEST" <<'PY' || fail 'after-turn snapshot, provenance or private notes'
import json, pathlib, stat, sys
b, r = map(pathlib.Path, sys.argv[1:])
assert 'FINAL HANDOFF TURN' in (b/'source.jsonl').read_text()
assert json.loads((b/'manifest.json').read_text())['source']['session_id'] == 'source-47'
assert json.loads((r/'state.json').read_text())['detail'] == str(b/'manifest.json')
assert '人工交接' in (b/'handoff.md').read_text() and 'CHANGED AFTER ARM' not in (b/'handoff.md').read_text()
assert json.loads((b/'loop-spec.json').read_text())['interval_seconds'] == 3600
assert '继续轮询测试任务' in (b/'loop-spec.json').read_text()
assert 'CODEX_THREAD_ID' in (b/'pickup.md').read_text()
assert 'FLEET_LOOP_SPEC=' in (b/'launch.sh').read_text()
assert stat.S_IMODE(r.stat().st_mode) == 0o700
assert all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in r.iterdir())
PY
ok

spawn 48 raw normal
FLEET_TRANSFER_IDLE_WAIT=2 FLEET_HANDOFF_DEFER_SECS=0 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm timeout case'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
wait_request failed; ok
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] && [ -s "$REQUEST/notes.md" ] || fail 'timeout must preserve source and notes'

spawn 49 issue normal
FLEET_TRANSFER_IDLE_WAIT=20 FLEET_HANDOFF_DEFER_SECS=0 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm identity case'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
python3 - "$WORK/sessions/$PID.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); r = json.loads(p.read_text())
r['sessionId'] = 'changed-after-arming'; p.write_text(json.dumps(r))
PY
stop_turn
wait_request failed; ok
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] || fail 'identity change must never switch a replacement session'

spawn 50 raw normal
printf '%s %s\n' "$(date +%s)" "$WIN" > "$WORK/typing-client"
FLEET_TRANSFER_IDLE_WAIT=6 FLEET_HANDOFF_DEFER_SECS=120 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm typing hold case'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
stop_turn
sleep 1
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] || fail 'typing operator must hold the switch after Stop'
# A subsequent turn invalidates that Stop. Even a spurious done stamp after it
# must not release the request when the operator is no longer typing.
TMUX="$SP,0,0" TMUX_PANE="$PANE" bash "$IBIN/set-claude-state.sh" working </dev/null
ok; [ -z "$(field agent_transfer_ready)" ] || fail 'new turn must invalidate the old Stop'
rm "$WORK/typing-client"
TM set-option -w -t "$WIN" @claude_state "done"
wait_request failed; ok
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] || fail 'old Stop must not release a request after new activity'

printf 'fleet-transfer selftest: OK (%s checks)\n' "$checks"
