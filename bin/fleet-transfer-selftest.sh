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
# The account state + alerts both key on TMPDIR (.fleet-account.py state_dir,
# usage-lib's cache dir): re-home it so the target-auth legs (issue #1667) never
# read or write the operator's pool state or alerts.
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
unset FLEET_FAILOVER FLEET_CODEX_HOME FLEET_CODEX_ACCOUNTS FLEET_ACCOUNT_LABEL FLEET_ACCOUNTS_DIR
if [ "${1:-}" = --proxy-home ]; then
  export HOME="$WORK/home"; mkdir -p "$HOME"
  unset CODEX_HOME FLEET_CODEX_PROFILE FLEET_CRED_SID
fi
LBL="transfer-selftest-$$-$RANDOM"
TM() { tmux -L "$LBL" "$@"; }
cleanup() { TM kill-server 2>/dev/null || :; sleep 0.2; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
checks=0
fail() { printf 'fleet-transfer selftest FAIL: %s\n%s\n' "$1" "${OUT:-}" >&2; exit 1; }
ok() { checks=$((checks+1)); }

IBIN="$WORK/install/bin"; FB="$WORK/fakebin"
mkdir -p "$IBIN" "$FB" "$WORK/sessions" "$WORK/projects/actual" "$WORK/conf/fleets/$LBL"
for f in fleet-trust.sh fleet_codex_trust.py fleet-agent-defaults.py fleet_transfer_durable.py fleet_transfer_cron.py fleet_cron.py fleet_loop_mark.py .fleet-transfer-norepo.py fleet-session-wrap.sh fleet-session-page.py fleet-codex-rpc.py fleet-codex-runtime.py fleet-input.py .fleet-account.py .fleet-failover.py fleet-codex-attention.py fleet-codex-session.py fleet-transfer.sh .fleet-transfer.py .fleet-transfer-wait.py fleet-loop.py fleet-sleep.py fleet_sleep_argv.py fleet_sleep_mcp.py fleet_sleep_park.py fleet-lib.sh usage-lib.sh fleet-lang.sh session-end-hook.sh set-claude-state.sh fleet-hook-conf.sh fleet-account.sh fleet_iso.py fleet-alerts.sh fleet-daemon-lib.sh fleet-relogin.sh; do cp "$BIN/$f" "$IBIN/$f"; done
export FLEET_CONF_DIR="$WORK/conf" FLEET_CC_SESSIONS_DIR="$WORK/sessions" FLEET_CC_PROJECTS_DIR="$WORK/projects"
cp "$BIN/fleet_needs_detail.py" "$IBIN/fleet_needs_detail.py"
# The fake ccquota (issue #1667): the ONE registered Codex profile, its login
# state read from a file; no file = no profiles, so every leg that does not set
# one sees `target auth: unknown` and runs exactly as before.
mkdir -p "$WORK/codex-home"
cat > "$FB/ccquota" <<SH
#!/bin/bash
case "\$1 \$2" in
  'codex list') [ -f "$WORK/login-state" ] || { echo '[]'; exit 0; }
     h="$WORK/codex-home"; [ ! -f "$WORK/profile-home" ] || h=\$(cat "$WORK/profile-home")
     printf '[{"name":"work","home":"%s","account":"codex:acct:1","email":"w@example.invalid","plan":"plus","default":true,"login":{"state":"%s"}}]\n' "\$h" "\$(cat "$WORK/login-state")" ;;
  # issue #1669: the device-auth login the alert's ↵ runs — here it just succeeds
  'codex login') [ "\$3" = work ] && [ "\$4" = --device-auth ] || exit 64
     printf 'Open https://auth.example.invalid/device and enter ABCD-1234\n'; printf 'valid\n' > "$WORK/login-state" ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$FB/ccquota"
export FLEET_QUOTA_BIN="$FB/ccquota"
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
$| = 1; print "Claude ready $sid\n"; print "❯ " if $mode eq 'norepo';
while (my $line = <STDIN>) {
    next unless $line =~ m{/exit};
    next if $mode eq 'stuck';
    if (-e "$ENV{TRANSFER_TEST_ROOT}/native-plan.json") {
        open(my $p, '<', "$ENV{TRANSFER_TEST_ROOT}/native-plan.json") or die;
        local $/; my $plan=decode_json(<$p>); close $p;
        # Durable tasks do not stop on exit: no dialog without a session-only one.
        goto EXITNOW unless grep { !$_->{durable} } @{$plan->{jobs}};
        print "Background work is running\nThe following will stop when you exit:\n";
        for my $job (@{$plan->{jobs}}) { print "scheduled task · $job->{cron}\n" unless $job->{durable}; }
        print "❯ 1. Exit and stop tasks\n2. Move to background and exit\n3. Stay\nEnter to confirm · Esc to cancel\n";
        local $/="\n"; my $confirm=<STDIN>;
        next unless defined($confirm) && $confirm =~ /^\s*$/;
    }
    if ($mode eq 'loop-dialog') {
        print "Background work is running\nThe following will stop when you exit:\n\n";
        print "scheduled task · Runs once in 5m · /loop continue task\n\n";
        print "❯ 1. Exit and stop tasks\n2. Move to background and exit\n3. Stay\n\n";
        print "Enter to confirm · Esc to cancel\n";
        my $confirm = <STDIN>;
        next unless defined($confirm) && $confirm =~ /^\s*$/;
    }
    EXITNOW:
    $ENV{FLEET_SESSION_END_REASON} = 'prompt_input_exit';
    system('/bin/bash', "$ENV{TRANSFER_TEST_ROOT}/install/bin/session-end-hook.sh");
    exit 0;
}
PL
cat > "$WORK/codex.pl" <<'PL'
use JSON::PP;
alarm 120;
open(my $f, '>', "$ENV{TRANSFER_TEST_ROOT}/target-argv.json") or die;
print $f encode_json({argv=>\@ARGV, manifest=>$ENV{FLEET_HANDOFF_MANIFEST}, home=>$ENV{CODEX_HOME}}); close $f;
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
if [ "$1" = --agent ] && [ "$2" = claude ]; then
  sid=target-claude
  [ "${3:-}" != --resume ] || sid=$4
  [ ! -f "$TRANSFER_TEST_ROOT/fail-source" ] || [ "${3:-}" != --resume ] || exit 38
  if [ -n "${FLEET_LOOP_SPEC:-}" ] && [ -f "$TRANSFER_TEST_ROOT/native-plan.json" ]; then
    exec python3 "$TRANSFER_TEST_ROOT/install/bin/fleet-loop.py" bridge -- "$TRANSFER_TEST_ROOT/fakebin/claude" "$TRANSFER_TEST_ROOT/claude.pl" "$sid" norepo
  fi
  exec "$TRANSFER_TEST_ROOT/fakebin/claude" "$TRANSFER_TEST_ROOT/claude.pl" "$sid" normal
fi
[ "$1" = --agent ] && [ "$2" = codex ] || exit 90
[ ! -f "$TRANSFER_TEST_ROOT/fail-target" ] || exit 37
# issue #1669: the target's credential dies as it starts (a login prompt)
if [ -f "$TRANSFER_TEST_ROOT/auth-dies" ]; then printf 'reauth_required\n' > "$TRANSFER_TEST_ROOT/login-state"; exit 37; fi
if [ "${3:-}" = --codex-home ]; then export CODEX_HOME="$4"; fi
if [ -n "${FLEET_LOOP_SPEC:-}" ] && [ -f "$TRANSFER_TEST_ROOT/native-plan.json" ]; then
  export LOOP_TEST_ROOT="$HOME" LOOP_TEST_SCRIPT="$TRANSFER_TEST_ROOT/install/bin/fleet-loop.py"
  exec python3 "$LOOP_TEST_SCRIPT" bridge -- pickup
fi
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
# Personal tmux hooks can move/remove a marked sidebar even on a private
# socket. This fixture owns its config as well as its server and worktrees.
TM -f /dev/null new-session -d -s "$LBL" -n plan -c "$MAIN" || fail 'isolated tmux server'
TM set-option -g default-shell /bin/bash

spawn() { # n, issue|raw, normal|stuck|tool|loop-dialog
  local n=$1 kind=$2 mode=$3 branch cmd
  case "$kind" in issue) branch="issue-$n" ;; *) branch="scratch-$n" ;; esac
  WT="$WORK/wt '$n percent%"
  if [ "$kind" = norepo ]; then
    WT="$HOME"
  else
    git -C "$MAIN" worktree add -qb "$branch" "$WT" || fail 'worktree'
  fi
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
  local expected=$1 state attempt
  for ((attempt=0; attempt<100; attempt++)); do
    state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$REQUEST/state.json")
    if [ "$state" = "$expected" ] && [ -z "$(field agent_transfer_request)" ]; then return 0; fi
    [ "$state" != failed ] || [ "$expected" = failed ] || break
    sleep 0.1
  done
  OUT=$(cat "$REQUEST/state.json" "$REQUEST/wait.log")
  fail "after-turn request did not finish as $expected"
}

# #4258: the same real isolated socket/process fixture, with a physical HOME.
if [ "${1:-}" = --norepo ] || [ "${1:-}" = --norepo-cron ] || [ "${1:-}" = --norepo-durable ]; then
  unset CODEX_HOME
  export HOME="$WORK/home"
  mkdir -p "$HOME/.codex"
  TM set-environment -g HOME "$HOME"
  TM set-environment -t "$LBL" HOME "$HOME"
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$HOME" > "$HOME/.codex/config.toml"
  if [ "${1:-}" = --norepo-durable ]; then
    # #4280: a mixed plan — one session-only patrol + one durable one-shot —
    # moves on the single-owner road: B still refuses before preparation, the
    # source's own CronDelete receipt + CronList withdraw it, the target's Fleet
    # loop delivers it exactly once, and failures keep exactly one owner.
    cat > "$IBIN/fleet-peer-send.sh" <<'PYPREP'
#!/bin/sh
cat >> "$TRANSFER_TEST_ROOT/preparation-messages"
printf '\nREQUEST\n' >> "$TRANSFER_TEST_ROOT/preparation-messages"
PYPREP
    rm "$FB/codex"; cp "$BIN/fleet-loop-fake-codex.py" "$FB/codex"; chmod +x "$FB/codex"
    durable_source() { # n — a no-repo Claude source holding the native lock, with one durable task
      spawn "$1" norepo norepo
      for k in raw worktree; do TM set-option -wu -t "$WIN" "@$k"; done
      TM set-option -w -t "$WIN" @norepo 1
      TM set-option -w -t "$WIN" @fleet_role worker
      TM set-option -w -t "$WIN" @cc_agent claude
      TM set-option -w -t "$WIN" @fleet_id "11111111-1111-4111-8111-1111111111$1"
      mkdir -p "$HOME/.claude"
      rm -f "$WORK/delivered.log" "$HOME/delivered.log"
      python3 - "$HOME" "$PID" "$TRANSCRIPT" "$SID" "$(field fleet_id)" "$IBIN" "$WORK/native-plan.json" <<'PYDURABLE'
import datetime,json,sys,time
from pathlib import Path
home,pid,transcript,sid,fid,ibin,planp=sys.argv[1:]; sys.path.insert(0,ibin)
import fleet_transfer_durable as D
start=D.proc_start(pid); now=time.time(); zone=D.local_zone()
due=datetime.datetime.now()+datetime.timedelta(days=1)
cron='%d %d %d %d *'%(13 if due.minute in (0,30) else due.minute,due.hour,due.day,due.month)
record=dict(id='2b6a2f9f',cron=cron,prompt='EPIC acceptance: reread the train metrics once',createdAt=int(now*1000),
            createdBySessionId='before-clear',createdByPid=int(pid),createdByProcStart=start,createdInProject=str(Path(home).resolve()))
(Path(home)/'.claude/scheduled_tasks.json').write_text(json.dumps(dict(tasks=[record])))
(Path(home)/'.claude/scheduled_tasks.lock').write_text(json.dumps(dict(sessionId='before-clear',pid=int(pid),procStart=start,acquiredAt=1)))
pt=datetime.datetime.fromtimestamp(now+360,datetime.timezone.utc)
patrol=dict(id='patrol',prompt='exact patrol instruction',cron=str(pt.minute)+' * * * *',recurring=True,durable=False,
            timezone='UTC',expires_at=now+7200,stop_when='')
once=dict(D.job_for(record),durable=True)
ev={'2b6a2f9f':{k:dict(value=once[k],source='native table record') for k in ('prompt','cron','durable','timezone','expires_at','stop_when')}}
plan=dict(jobs=[patrol,once],native_source=dict(confirmed=True,job_evidence=ev))
Path(planp).write_text(json.dumps(plan))
ts=datetime.datetime.now(datetime.timezone.utc).isoformat()
listed=[patrol,dict(id='2b6a2f9f',cron=cron,prompt=record['prompt'],recurring=False)]
with open(transcript,'a') as f:
    f.write(json.dumps(dict(type='system',version='2.1.295',sessionId=sid))+'\n')
    f.write(json.dumps(dict(timestamp=ts,message=dict(content=[dict(type='tool_use',id='list0',name='CronList',input={})])))+'\n')
    f.write(json.dumps(dict(timestamp=ts,toolUseResult=dict(jobs=listed),message=dict(content=[dict(type='tool_result',tool_use_id='list0')])))+'\n')
PYDURABLE
      TM set-option -w -t "$WIN" @loop "kind=cron id=patrol@$(( $(date +%s)+7200 ))"
      cp "$HOME/.claude/scheduled_tasks.json" "$WORK/native-before.json"
      DFID=$(field fleet_id)
      JOURNAL="$FLEET_CONF_DIR/transfer-durable/$DFID.json"
    }
    as_source() { local sp; sp=$(TM display-message -p -t "$PANE" '#{socket_path}'); TMUX="$sp,0,0" TMUX_PANE="$PANE" "$@"; }
    native_receipts() { # the source's own CronDelete of the durable id, then CronList (patrol only)
      python3 - "$HOME" "$TRANSCRIPT" <<'PYNATIVE'
import datetime,json,os,sys
from pathlib import Path
home,transcript=sys.argv[1:]; store=Path(home)/'.claude/scheduled_tasks.json'
t=json.loads(store.read_text()); t['tasks']=[x for x in t['tasks'] if x['id']!='2b6a2f9f']
tmp=str(store)+'.native'; open(tmp,'w').write(json.dumps(t)); os.rename(tmp,store)
ts=datetime.datetime.now(datetime.timezone.utc).isoformat()
rows=[('del','CronDelete',dict(id='2b6a2f9f'),'Cancelled job 2b6a2f9f'),('list1','CronList',{},None)]
with open(transcript,'a') as f:
    for tid,name,inp,res in rows:
        if res is None:
            res=dict(jobs=[j for j in json.load(open(os.environ['TRANSFER_TEST_ROOT']+'/native-plan.json'))['jobs'] if j['id']=='patrol'])
        f.write(json.dumps(dict(timestamp=ts,message=dict(content=[dict(type='tool_use',id=tid,name=name,input=inp)])))+'\n')
        f.write(json.dumps(dict(timestamp=ts,toolUseResult=res,message=dict(content=[dict(type='tool_result',tool_use_id=tid)])))+'\n')
PYNATIVE
    }
    jstate() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$JOURNAL"; }
    prepare_source() { # export (stages the inert copy) → begin → CronDelete + CronList → confirm
      OUT=$(as_source python3 "$IBIN/fleet-loop.py" export-cron --session "$LBL" --jobs-file "$WORK/native-plan.json" 2>&1) \
        || fail 'source export of the mixed plan'
      [ "$(jstate)" = staged ] || fail 'export must stage the durable journal'
      cmp "$HOME/.claude/scheduled_tasks.json" "$WORK/native-before.json" || fail 'staging touched the native table'
      python3 "$IBIN/fleet_transfer_durable.py" begin "$DFID" || fail 'durable write-ahead'
      native_receipts
      python3 "$IBIN/fleet_transfer_durable.py" confirm "$DFID" "$TRANSCRIPT" || fail 'durable receipt confirmation'
      [ "$(jstate)" = withdrawn ] || fail 'confirmed receipts must withdraw the journal'
    }

    # the zone native cron uses is always a key ZoneInfo accepts (issue #4309):
    # a runner's `…/zoneinfo//UTC` link and an absolute TZ once gave `/UTC`.
    ok; OUT=$(python3 - "$IBIN" "$WORK" <<'PYZONE'
import os,sys; sys.path.insert(0,sys.argv[1]); import fleet_transfer_durable as D
w=sys.argv[2]; dbl=os.path.join(w,'lt-dbl'); rel=os.path.join(w,'lt-rel')
for p,t in ((dbl,'/usr/share/zoneinfo//UTC'),(rel,'../usr/share/zoneinfo/Asia/Shanghai')):
    if os.path.lexists(p): os.unlink(p)
    os.symlink(t,p)
got=[D.local_zone('',dbl),D.local_zone('/UTC',rel),D.local_zone(':/UTC',rel),D.local_zone('',rel),
     D.local_zone('No/Such',dbl),D.local_zone('',os.path.join(w,'none'))]
print(' '.join(got))
PYZONE
)
    [ "$OUT" = 'UTC UTC UTC Asia/Shanghai UTC UTC' ] || fail "local_zone must give a ZoneInfo key: $OUT"

    # 0) road 2 — the source cannot run its own CronDelete (quota, stuck): this
    #    controller takes its durable task, ONLY inside the isolation boundary.
    printf 'Keep the source and reminder running.\n' > "$WORK/durable-notes.md"
    durable_source 99
    TM set-option -wu -t "$WIN" @loop
    printf '{"jobs":[{"id":"2b6a2f9f","durable":true}]}\n' > "$WORK/native-plan.json"   # loop-bridge targets only
    # Claude processes already on this machine (a developer's own sessions) are
    # accounted for as running elsewhere; CI has none.
    python3 - "$IBIN" "$WORK/sessions" <<'PYKNOWN'
import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]); import fleet_transfer_durable as D
for pid in D.claude_processes():
    f=Path(sys.argv[2])/('%d.json'%pid)
    if not f.exists(): f.write_text(json.dumps(dict(sessionId='known-%d'%pid,cwd='/elsewhere')))
PYKNOWN
    mkdir -p "$WORK/stray"; ln -sf /bin/sleep "$WORK/stray/claude"
    "$WORK/stray/claude" 60 & STRAY=$!
    sleep 0.3
    transfer --durable-takeover --handoff "$WORK/durable-notes.md" && fail 'an unknown live Claude must refuse the takeover'
    printf '%s' "$OUT" | grep -q "pid $STRAY" || fail 'the takeover refusal must name the unknown Claude'
    kill -0 "$PID" || fail 'a refused takeover exited the source'
    cmp "$HOME/.claude/scheduled_tasks.json" "$WORK/native-before.json" || fail 'a refused takeover changed native tasks'
    [ ! -e "$JOURNAL" ] || fail 'a refused takeover staged a journal'
    kill "$STRAY"; wait "$STRAY" 2>/dev/null
    ok
    transfer --durable-takeover --handoff "$WORK/durable-notes.md" || { cat "$(packet)/pane-target-failed.txt" >&2 2>/dev/null; fail 'isolated durable takeover'; }
    kill -0 "$PID" 2>/dev/null && fail 'source must exit before Fleet takes its task'
    BUNDLE=$(packet)
    python3 - "$BUNDLE/loop/state.json" "$JOURNAL" "$IBIN" "$HOME" "$WORK/native-before.json" <<'PYTAKE' || fail 'road 2: one Fleet delivery, every other record kept'
import json,sys,runpy,time
from pathlib import Path
path,journal,ibin,home,before=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4]),Path(sys.argv[5])
for _ in range(40):
    if path.exists() and json.loads(path.read_text()).get('status')=='active': break
    time.sleep(.1)
j=json.loads(journal.read_text()); assert j['state']=='active' and j['road']=='fence',j
assert not (journal.parent/'launch.gate').exists()
assert json.loads((home/'.claude/scheduled_tasks.json').read_text())['tasks']==[]
log=home/'delivered.log'
loop=runpy.run_path(ibin+'/fleet-loop.py')
due=[x for x in json.loads(path.read_text())['schedule']['jobs'] if x['id']=='2b6a2f9f'][0]['next_run_at']
for now in (due-1,due,due+1,due+3600): loop['dispatch'](path,now=now)
lines=log.read_text().splitlines()
assert len(lines)==1 and 'reread the train metrics once' in lines[0],lines
assert json.loads(journal.read_text())['state']=='complete'
PYTAKE
    ok

    # 1) B: no preparation yet — every entry refuses, nothing changes.
    durable_source 96
    printf 'Keep the source and reminder running.\n' > "$WORK/durable-notes.md"
    for mode in --dry-run --prepare-only --after-turn; do
      transfer "$mode" --handoff "$WORK/durable-notes.md" && fail 'durable source without its native receipt must refuse'
      printf '%s' "$OUT" | grep -q 'durable.*execution owner' || fail 'durable refusal must explain missing execution owner'
      kill -0 "$PID" || fail 'durable refusal exited the source'
      cmp "$HOME/.claude/scheduled_tasks.json" "$WORK/native-before.json" || fail 'durable refusal changed native tasks'
      ! ls -d "$FLEET_CONF_DIR"/handoffs/*-"$SID"-* >/dev/null 2>&1 || fail 'durable refusal wrote a handoff'
      ok
    done
    transfer --from-panel || fail 'durable panel must request source preparation'
    grep -q 'Call native CronList now' "$WORK/preparation-messages" || fail 'panel did not ask for current CronList'
    grep -q "fleet_transfer_durable.py begin $DFID" "$WORK/preparation-messages" || fail 'panel did not give the write-ahead step'
    grep -q 'native CronDelete' "$WORK/preparation-messages" || fail 'panel did not ask for the native CronDelete'
    grep -q "fleet_transfer_durable.py confirm $DFID" "$WORK/preparation-messages" || fail 'panel did not give the receipt check'
    ok

    # 2) success: the target's Fleet loop delivers the durable task once, on time.
    prepare_source
    PREP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$FLEET_CONF_DIR/transfer-preparation/$DFID.json")
    printf 'Fleet-Preparation-Request: %s\nVerified source notes.\n' "$PREP" > "$WORK/panel-notes.md"
    transfer --handoff "$WORK/panel-notes.md" || { cat "$(packet)/pane-target-failed.txt" >&2 2>/dev/null; fail 'mixed durable cutover'; }
    kill -0 "$PID" 2>/dev/null && fail 'source must exit before the target owns its task'
    BUNDLE=$(packet)
    python3 - "$BUNDLE/loop/state.json" "$JOURNAL" "$IBIN" "$HOME" <<'PYDELIVER' || fail 'durable delivered exactly once by the target loop'
import json,sys,runpy,time
from pathlib import Path
path,journal,ibin,home=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3],Path(sys.argv[4])
sys.path.insert(0,ibin)
for _ in range(40):
    if path.exists() and json.loads(path.read_text()).get('status')=='active': break
    time.sleep(.1)
r=json.loads(path.read_text()); assert r['status']=='active',r
j=json.loads(journal.read_text()); assert j['state']=='active' and j['target']['agent']=='codex',j
assert r['durable_fid']==j['fid'] and r['durable_ids']==['2b6a2f9f'],r
assert '2b6a2f9f' not in [t['id'] for t in json.loads((home/'.claude/scheduled_tasks.json').read_text())['tasks']]
log=home/'delivered.log'
loop=runpy.run_path(ibin+'/fleet-loop.py')
jobs={x['id']:x for x in r['schedule']['jobs']}
patrol,once=jobs['patrol']['next_run_at'],jobs['2b6a2f9f']['next_run_at']
assert patrol<once
loop['dispatch'](path,now=patrol)                  # the session-only patrol, on its own round
lines=log.read_text().splitlines(); assert len(lines)==1 and 'exact patrol instruction' in lines[0],lines
assert 'reread the train metrics' not in lines[0]
# The patrol keeps its rounds through its one final round after expiry (native 2.1.295).
while True:
    nxt=[x for x in json.loads(path.read_text())['schedule']['jobs'] if x['id']=='patrol'][0]['next_run_at']
    if nxt is None or nxt>=once: break
    loop['dispatch'](path,now=nxt)
patrols=len(log.read_text().splitlines())
assert patrols>=2 and all('reread the train metrics' not in x for x in log.read_text().splitlines())
loop['dispatch'](path,now=once-1)                  # not yet
assert len(log.read_text().splitlines())==patrols
loop['dispatch'](path,now=once)                    # on time
loop['dispatch'](path,now=once+1)                  # never again
loop['dispatch'](path,now=once+3600)
lines=log.read_text().splitlines()
assert sum('reread the train metrics once' in x for x in lines)==1,lines
j=json.loads(journal.read_text()); assert j['state']=='complete',j['state']
r=json.loads(path.read_text()); assert jobs and [x['next_run_at'] for x in r['schedule']['jobs'] if x['id']=='2b6a2f9f']==[None]
PYDELIVER
    ok

    # 3) the target fails: the source comes back through the Fleet loop, which
    #    owns the durable task from then on (no native re-create, no duplicate).
    durable_source 97
    prepare_source
    PREP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$FLEET_CONF_DIR/transfer-preparation/$DFID.json" 2>/dev/null || :)
    touch "$WORK/fail-target"
    transfer --handoff "$WORK/durable-notes.md" && fail 'failed durable target reported success'
    rm "$WORK/fail-target"
    BUNDLE=$(packet)
    python3 - "$BUNDLE" "$JOURNAL" "$SID" <<'PYBACK' || fail 'rollback must hand the durable task to the resumed source loop'
import json,sys,time
from pathlib import Path
b,journal,sid=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
assert json.loads((b/'state.json').read_text())['state']=='rolled_back'
for _ in range(40):
    j=json.loads(journal.read_text())
    if j['state']=='active': break
    time.sleep(.1)
assert j['state']=='active' and j['target']['agent']=='claude',j
r=json.loads((b/'rollback/loop/state.json').read_text())
assert r['agent']=='claude' and r['thread_id']==sid and r['durable_fid']==j['fid'],r
assert [x['id'] for x in r['schedule']['jobs']]==['patrol','2b6a2f9f']
PYBACK
    ok

    # 4) a check fails before /exit, after the receipt: the still-running source
    #    is asked to re-create its task natively, and only its receipt settles it.
    durable_source 98
    prepare_source
    : > "$WORK/preparation-messages"
    # An out-of-bounds exit wait dies after the package, before the claim and /exit.
    OUT=$(FLEET_TRANSFER_EXIT_WAIT=99 bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$WIN" --to codex --handoff "$WORK/durable-notes.md" 2>&1) \
      && fail 'an out-of-bounds exit wait must refuse'
    printf '%s' "$OUT" | grep -q 'timeout bounds' || fail 'the refusal came from somewhere else'
    kill -0 "$PID" || fail 'a refused cutover exited the source'
    [ "$(jstate)" = restoring ] || { printf '%s\n' "$OUT" >&2; fail "a pre-exit failure must ask the source to restore (got $(jstate))"; }
    grep -q 'CronCreate' "$WORK/preparation-messages" || fail 'the source was not asked for the native re-create'
    python3 - "$HOME" "$TRANSCRIPT" <<'PYCREATE'
import datetime,json,os,sys
from pathlib import Path
home,transcript=sys.argv[1:]; store=Path(home)/'.claude/scheduled_tasks.json'
before=json.load(open(os.environ['TRANSFER_TEST_ROOT']+'/native-before.json'))['tasks'][0]
t=json.loads(store.read_text()); t['tasks'].append(dict(before,id='c0ffee00'))
tmp=str(store)+'.native'; open(tmp,'w').write(json.dumps(t)); os.rename(tmp,store)
ts=datetime.datetime.now(datetime.timezone.utc).isoformat()
inp=dict(cron=before['cron'],prompt=before['prompt'],recurring=False,durable=True)
with open(transcript,'a') as f:
    f.write(json.dumps(dict(timestamp=ts,message=dict(content=[dict(type='tool_use',id='mk',name='CronCreate',input=inp)])))+'\n')
    f.write(json.dumps(dict(timestamp=ts,toolUseResult=dict(id='c0ffee00',durable=True),message=dict(content=[dict(type='tool_result',tool_use_id='mk')])))+'\n')
PYCREATE
    python3 "$IBIN/fleet_transfer_durable.py" confirm-restored "$DFID" "$TRANSCRIPT" || fail 'native re-create receipt'
    [ "$(jstate)" = rolled_back ] || fail 'the re-create must settle the rollback'
    ok
    printf 'fleet-transfer durable handover selftest: PASS (%s checks)\n' "$checks"
    exit 0
  fi
  if [ "${1:-}" != --norepo-cron ]; then
  spawn 91 norepo norepo
  TM set-option -wu -t "$WIN" @raw
  TM set-option -wu -t "$WIN" @worktree
  TM set-option -w -t "$WIN" @norepo 1
  TM set-option -w -t "$WIN" @fleet_role worker
  TM set-option -w -t "$WIN" @fleet_role_def orchestrator
  TM set-option -w -t "$WIN" @fleet_id 11111111-1111-4111-8111-111111111191
  TM set-option -w -t "$WIN" @agent_spawn 1
  TM set-option -w -t "$WIN" @task T91
  transfer --prepare-only || fail 'managed no-repo orchestrator must prepare'
  BUNDLE=$(packet)
  python3 - "$BUNDLE" "$SID" "$HOME" <<'PYNO' || fail 'no-repo packet provenance'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'manifest.json').read_text())
assert m['source']['session_id']==sys.argv[2]
assert m['workspace']==dict(kind='norepo',path=sys.argv[3],branch=None,head=None,repo='')
assert m['fleet']['identity']['fleet_id']=='11111111-1111-4111-8111-111111111191'
assert m['fleet']['identity']['fleet_role_def']=='orchestrator'
assert m['fleet']['identity']['task']=='T91'
assert not (p/'git-status.txt').exists()
PYNO
  ok; kill -0 "$PID" || fail 'prepare killed source'
  [ -z "$(field worktree)" ] && [ -z "$(field raw)" ] || fail 'no-repo must not manufacture worktree/raw'
  TM set-option -w -t "$WIN" @claude_state working
  transfer --dry-run && fail 'busy dry-run must refuse'
  ok; kill -0 "$PID" || fail 'busy refusal killed source'
  TM set-option -w -t "$WIN" @claude_state 'done'
  TM set-option -w -t "$WIN" @fleet_role panel
  transfer --prepare-only && fail 'renamed panel must refuse'
  ok
  # Legacy unstamped panels must take the unified role reader's fallback,
  # rather than merely failing a later HOME identity check by coincidence.
  OLD_NAME=$(TM display-message -p -t "$WIN" '#{window_name}')
  TM set-option -wu -t "$WIN" @fleet_role
  for old_panel in home dash; do
    TM rename-window -t "$WIN" "$old_panel"
    transfer --prepare-only && fail 'legacy unstamped panel must refuse'
    printf '%s' "$OUT" | grep -q 'panel windows cannot be transferred' || fail 'legacy panel did not use role fallback'
  done
  TM rename-window -t "$WIN" "$OLD_NAME"
  ok
  TM set-option -w -t "$WIN" @fleet_role worker
  TM set-option -wu -t "$WIN" @fleet_id
  transfer --prepare-only && fail 'unstamped HOME session must refuse'
  ok
  TM set-option -w -t "$WIN" @fleet_id 11111111-1111-4111-8111-111111111191
  TM set-option -w -t "$WIN" @loop 'kind=cron id=a@9999999999 cron=a@*/15_*_*_*_*'
  transfer --dry-run && fail 'unknown native schedule must refuse'
  ok; kill -0 "$PID" || fail 'schedule refusal killed source'
  # Panel preparation uses the normal peer bridge and leaves the process alive.
  cat > "$IBIN/fleet-peer-send.sh" <<'PYPREP'
#!/bin/sh
cat >> "$TRANSFER_TEST_ROOT/preparation-messages"
printf '\nREQUEST\n' >> "$TRANSFER_TEST_ROOT/preparation-messages"
PYPREP
  transfer --from-panel --dry-run || fail 'panel must offer preparation'
  case "$OUT" in *preparation-needed:*) ;; *) fail 'missing preparation status' ;; esac
  [ ! -e "$FLEET_CONF_DIR/transfer-preparation" ] || fail 'dry-run created a request'
  transfer --from-panel || fail 'panel preparation request'
  transfer --from-panel || fail 'panel preparation dedup'
  [ "$(grep -c '^REQUEST$' "$WORK/preparation-messages")" = 1 ] || fail 'preparation sent twice'
  kill -0 "$PID" || fail 'preparation exited the source'
  PREP="$FLEET_CONF_DIR/transfer-preparation/$(field fleet_id).json"
  FIRST_PREP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$PREP")
  printf 'Fleet-Preparation-Request: %s\nVerified source notes.\n' "$FIRST_PREP" > "$WORK/panel-notes.md"
  python3 - "$PREP" <<'PYEXPIRE'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['expires_at']=0
open(p,'w').write(json.dumps(r))
PYEXPIRE
  transfer --after-turn --handoff "$WORK/panel-notes.md" && fail 'expired panel request armed'
  printf '%s' "$OUT" | grep -q 'panel preparation expired or changed identity/target' || fail 'expiry check did not run'
  [ -z "$(field agent_transfer_request)" ] || fail 'expired request changed arm state'
  transfer --from-panel || fail 'explicit panel retry after expired acknowledged request'
  [ "$(grep -c '^REQUEST$' "$WORK/preparation-messages")" = 2 ] || fail 'panel retry not delivered once'
  SECOND_PREP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$PREP")
  [ "$FIRST_PREP" != "$SECOND_PREP" ] || fail 'retry reused preparation id'
  transfer --after-turn --handoff "$WORK/panel-notes.md" && fail 'old notes armed under new preparation'
  printf '%s' "$OUT" | grep -q 'request id missing or superseded' || fail 'stale note generation was not checked'
  [ -z "$(field agent_transfer_request)" ] || fail 'old generation left a waiter'
  printf 'Fleet-Preparation-Request: %s\nVerified source notes.\n' "$SECOND_PREP" > "$WORK/panel-notes.md"
  TM set-option -wu -t "$WIN" @loop
  FLEET_TRANSFER_IDLE_WAIT=8 transfer --after-turn --handoff "$WORK/panel-notes.md" || fail 'current generation failed to arm'
  PENDING_PREP=$(field agent_transfer_request)
  python3 - "$PENDING_PREP/request.json" "$SECOND_PREP" <<'PYGEN' || fail 'waiter lost preparation generation'
import json,sys
assert json.load(open(sys.argv[1]))['preparation_id']==sys.argv[2]
PYGEN
  python3 "$IBIN/.fleet-transfer-norepo.py" reject-request "$LBL" "$PANE" "$SECOND_PREP" || fail 'source explicit rejection'
  for _ in {1..30}; do [ -z "$(field agent_transfer_request)" ] && break; sleep 0.1; done
  [ -z "$(field agent_transfer_request)" ] || fail 'rejected generation waiter did not release'
  kill -0 "$PID" || fail 'rejected generation exited source'
  TM set-option -w -t "$WIN" @loop 'kind=cron id=a@9999999999 cron=a@*/15_*_*_*_*'
  transfer --from-panel || fail 'explicit retry after source rejection'
  [ "$(grep -c '^REQUEST$' "$WORK/preparation-messages")" = 3 ] || fail 'source rejection retry was not sent'
  python3 "$IBIN/.fleet-transfer-norepo.py" reject-request "$LBL" "$PANE" "$SECOND_PREP" 2>/dev/null && fail 'old rejection ended new preparation'
  python3 - "$PREP" <<'PYMISMATCH'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); r['session_id']='wrong-source'
open(p,'w').write(json.dumps(r))
PYMISMATCH
  transfer --after-turn --handoff "$WORK/panel-notes.md" && fail 'wrong source identity armed'
  printf '%s' "$OUT" | grep -q 'panel preparation expired or changed identity/target' || fail 'identity check did not run'
  kill -0 "$PID" || fail 'rejected request exited source'
  transfer --from-panel || fail 'prepare current source after old identity record'
  FINAL_PREP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_id"])' "$PREP")
  printf 'Fleet-Preparation-Request: %s\nVerified source notes.\n' "$FINAL_PREP" > "$WORK/panel-notes.md"
  ok
  TM set-option -wu -t "$WIN" @loop
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$HOME" > "$HOME/.codex/config.toml"
  transfer --dry-run && fail 'explicit untrusted HOME must refuse'
  ok; kill -0 "$PID" || fail 'trust refusal killed source'
  printf '[projects."%s"]\ntrust_level = "trusted"\n' "$HOME" > "$HOME/.codex/config.toml"
  cat > "$WORK/codex.pl" <<'PLNATIVE'
use JSON::PP; use Cwd;
alarm 60;
my $record = encode_json({owner=>"$$", session_id=>'22222222-2222-4222-8222-222222222222',
                         home=>"$ENV{HOME}/.codex", cwd=>getcwd()});
system('tmux','set-option','-w','-t',$ENV{TMUX_PANE},'@cc_launcher_pid',"$$");
system('tmux','set-option','-w','-t',$ENV{TMUX_PANE},'@codex_identity',$record);
$|=1; print "Codex native ready\n";
while (<STDIN>) { }
PLNATIVE
  transfer --handoff "$WORK/panel-notes.md" || fail 'managed no-repo native cutover'
  python3 - "$PREP" "$FINAL_PREP" <<'PYCOMPLETE' || fail 'cutover did not complete exact preparation'
import json,sys
r=json.load(open(sys.argv[1])); assert r['request_id']==sys.argv[2] and r['state']=='completed',r
PYCOMPLETE
  ok
  kill -0 "$PID" 2>/dev/null && fail 'source must exit before target starts'
  [ "$(field fleet_id)" = 11111111-1111-4111-8111-111111111191 ] && [ "$(field fleet_role_def)" = orchestrator ] \
    && [ "$(field origin)" = scratch-99 ] && [ "$(field task)" = T91 ] && [ "$(field agent_spawn)" = 1 ] || fail 'cutover lost identity/role/routing'
  [ -z "$(field worktree)" ] && [ -z "$(field raw)" ] || fail 'cutover invented a repository binding'
  ok
  # Failed target must restore the exact source once, with no second writer.
  spawn 92 norepo norepo
  for k in raw worktree; do TM set-option -wu -t "$WIN" "@$k"; done
  TM set-option -w -t "$WIN" @norepo 1
  TM set-option -w -t "$WIN" @fleet_role worker
  TM set-option -w -t "$WIN" @fleet_id 11111111-1111-4111-8111-111111111192
  touch "$WORK/fail-target"
  transfer && fail 'failed target cannot report success'
  BUNDLE=$(packet)
  python3 - "$BUNDLE/state.json" <<'PYBACK' || fail 'source must roll back'
import json,sys
assert json.load(open(sys.argv[1]))['state']=='rolled_back'
PYBACK
  BACK=$(fleet_pane_claude_pid "$PANE" "$LBL")
  [ "$(fleet_cc_session_id "$BACK")" = "$SID" ] || fail 'rollback lost source native identity'
  [ "$(field fleet_id)" = 11111111-1111-4111-8111-111111111192 ] || fail 'rollback changed lifelong identity'
  ok
  rm "$WORK/fail-target"
  # A target which is alive but never binds must never be killed/replaced with a second writer.
  spawn 93 norepo norepo
  for k in raw worktree; do TM set-option -wu -t "$WIN" "@$k"; done
  TM set-option -w -t "$WIN" @norepo 1
  TM set-option -w -t "$WIN" @fleet_role worker
  TM set-option -w -t "$WIN" @fleet_id 11111111-1111-4111-8111-111111111193
  printf 'alarm 60; $|=1; print "unbound target\\n"; while (<STDIN>) {}\n' > "$WORK/codex.pl"
  transfer && fail 'unbound live process cannot report takeover'
  printf '%s' "$OUT" | grep -q 'refusing a second writer' || fail 'must explicitly refuse unsafe rollback'
  [ "$(field cc_agent)" = codex ] || fail 'live target cannot be relabelled as a resumed source'
  fleet_pane_claude_pid "$PANE" "$LBL" >/dev/null 2>&1 && fail 'unsafe rollback launched a second writer'
  ok
  fi
  # Full mixed native Cron handover through a real private RPC server/TUI,
  # then failed-target rollback through the real Claude scheduler supervisor.
  rm "$FB/codex"
  cp "$BIN/fleet-loop-fake-codex.py" "$FB/codex"; chmod +x "$FB/codex"
  for n in 94 95; do
    spawn "$n" norepo norepo
    for k in raw worktree; do TM set-option -wu -t "$WIN" "@$k"; done
    TM set-option -w -t "$WIN" @norepo 1
    TM set-option -w -t "$WIN" @fleet_role worker
    TM set-option -w -t "$WIN" @cc_agent claude
    TM set-option -w -t "$WIN" @fleet_id "11111111-1111-4111-8111-1111111111$n"
    python3 - "$WORK/native-plan.json" "$TRANSCRIPT" "$PID" "$SID" "$(field fleet_id)" <<'PYNATIVE'
import datetime,json,sys,time
p,transcript,pid,sid,fid=sys.argv[1:]; now=time.time()
jobs=[]
for ident,offset,recurring in [('once',180,False),('patrol',360,True)]:
    dt=datetime.datetime.fromtimestamp(now+offset,datetime.timezone.utc)
    jobs.append(dict(id=ident,prompt='exact '+ident+' instruction',cron=str(dt.minute)+' * * * *',
                     recurring=recurring,durable=False,timezone='UTC',expires_at=now+7200,stop_when=''))
raw=dict(jobs=jobs,native_source=dict(pid=int(pid),session_id=sid,fleet_id=fid,confirmed=True))
open(p,'w').write(json.dumps(raw))
ts=datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(transcript,'a') as f:
    f.write(json.dumps(dict(timestamp=ts,message=dict(content=[dict(type='tool_use',id='list',name='CronList',input={})])))+'\n')
    f.write(json.dumps(dict(timestamp=ts,toolUseResult=jobs,message=dict(content=[dict(type='tool_result',tool_use_id='list')])))+'\n')
PYNATIVE
    TM set-option -w -t "$WIN" @loop "kind=cron id=once@$(( $(date +%s)+7200 )),patrol@$(( $(date +%s)+7200 ))"
    if [ "$n" = 95 ]; then touch "$WORK/fail-target"; fi
    if transfer --loop "$WORK/native-plan.json"; then
      [ "$n" = 94 ] || fail 'failed cron target reported success'
    else
      if [ "$n" != 95 ]; then
        cat "$(packet)/pane-target-failed.txt" >&2
        fail 'mixed native cron cutover failed'
      fi
    fi
    BUNDLE=$(packet)
    record="$BUNDLE/loop/state.json"
    if [ "$n" = 95 ]; then record="$BUNDLE/rollback/loop/state.json"; fi
    python3 - "$record" "$n" "$SID" "$IBIN" <<'PYCRONCHECK' || fail 'mixed cron ownership/delivery/rollback'
import json,sys,runpy,time
from pathlib import Path
path=Path(sys.argv[1]); n=sys.argv[2]; sid=sys.argv[3]; sys.path.insert(0,sys.argv[4])
for _ in range(40):
    if path.exists() and json.loads(path.read_text()).get('status')=='active': break
    time.sleep(.1)
r=json.loads(path.read_text()); assert r['status']=='active',r
assert [(j['id'],j['prompt'],j['recurring'],j['stop_when']) for j in r['schedule']['jobs']]==[('once','exact once instruction',False,''),('patrol','exact patrol instruction',True,'')]
if n=='95':
    assert r['agent']=='claude' and r['thread_id']==sid
    assert json.loads((path.parents[2]/'state.json').read_text())['state']=='rolled_back'
else:
    assert r['thread_id']=='12345678-1234-1234-1234-123456789abc'
    loop=runpy.run_path(str(Path(sys.argv[4])/'fleet-loop.py'))
    due=r['schedule']['jobs'][0]['next_run_at']
    loop['dispatch'](path,now=due)
    loop['dispatch'](path,now=due+1)
    r=json.loads(path.read_text())
    if r['deliveries']!=1:
        print(loop['tm'](r,'display-message','-p','-t',r['fleet']['pane_id'],'state=#{@claude_state}|life=#{@worker_lifecycle}|request=#{@agent_transfer_request}|quota=#{@quota_failover}|until=#{@agent_transfer_until}|armed=#{@handoff_armed}'))
        print(runpy.run_path(str(Path(sys.argv[4])/'fleet-input.py'))['snapshot'](r['fleet']['session'],r['fleet']['pane_id'],agent='codex'))
    assert r['deliveries']==1,r
    assert r['schedule']['jobs'][0]['next_run_at'] is None
    assert r['schedule']['jobs'][1]['next_run_at'] is not None
PYCRONCHECK
    kill -0 "$PID" 2>/dev/null && fail 'native source stayed alive alongside scheduler'
    [ -z "$(field loop)" ] || fail 'native marker survived handover'
    rm "$WORK/native-plan.json"
    ok
  done
  printf 'fleet-transfer norepo selftest: PASS (%s checks)\n' "$checks"
  exit 0
fi

if [ "${1:-}" != --proxy-home ]; then
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
TM set-option -w -t "$WIN" @claude_state looping
transfer && fail 'a looping CLAUDE source is not a settled Codex round'; ok
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
ok; ! fleet_pid_alive "$PID" || fail 'source process must exit'
ok; [ "$(field issue)" = 41 ] && [ "$(field wid)" = a1 ] && [ "$(field origin)" = scratch-99 ] || fail 'window bindings changed'
ok; [ "$(field cc_agent)" = codex ] && [ "$(field source_session_id)" = "$SID" ] && [ "$(field source_transcript)" = "$TRANSCRIPT" ] || fail 'target provenance stamps missing'
ok; [ "$(field worktree)" = "$WT" ] || fail 'issue-worker cutover must record verified worktree'
ok; [ -n "$(field migrated_at)" ] && [ -z "$(field migrated_banner)" ] || fail 'cutover must stamp @migrated_at, and no @migrated_banner off a wall-free source (#870)'
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

spawn 51 raw loop-dialog
printf '{"prompt":"continue task","interval_seconds":3600}\n' > "$WORK/loop.json"
FLEET_TRANSFER_EXIT_WAIT=5 transfer --loop "$WORK/loop.json" || fail 'source loop exit confirmation'; ok
ok; ! fleet_pid_alive "$PID" && [ "$(field cc_agent)" = codex ] || fail 'source timer must exit before Codex starts'
ok; [ -s "$(packet)/loop-exit-confirmation.txt" ] || fail 'exit confirmation evidence missing'
python3 - "$IBIN/.fleet-transfer.py" "$(packet)/loop-exit-confirmation.txt" <<'PY' || fail 'unknown or unrelated dialogs must not be confirmed'
import pathlib, runpy, sys
confirm = runpy.run_path(sys.argv[1])['loop_exit_confirmation']
screen = pathlib.Path(sys.argv[2]).read_text()
assert confirm(screen)
assert not confirm(screen.replace('❯ 1.', '  1.').replace('2. Move', '❯ 2. Move'))
assert not confirm(screen.replace('scheduled task · Runs once in 5m · /loop continue task', 'background task · build'))
assert not confirm(screen.replace('scheduled task ·', 'scheduled task · Runs once in 3m · /loop extra\nscheduled task ·'))
assert not confirm(screen + '\nNormal Claude prompt\n')
assert not confirm(screen.replace('Enter to confirm · Esc to cancel', ''))
PY
ok

# issue #1668: a target that exits at startup is ROLLED BACK in the same pane —
# the source resumed under the SAME session id within the boot wait, stamps put
# back, state.json rolled_back, @transfer_note + the pane itself say
# 「切换失败，已退回」, a ▲ transfer-rolled-back event, lease + remain-on-exit
# released, the package kept; an automatic retry is held off.
spawn 44 issue normal
touch "$WORK/fail-target"
T0=$SECONDS
transfer && fail 'target startup failure must not report success'; ok
BUNDLE=$(packet)
ok; [ $(( SECONDS - T0 )) -lt 60 ] || fail 'rollback must finish within 60 seconds'
ok; printf '%s' "$OUT" | grep -q '^fleet-transfer: rolled-back: 切换失败，已退回：codex exited at startup (status 37)' || fail "rollback must say so: $OUT"
BACK=$(fleet_pane_claude_pid "$PANE" "$LBL" 2>/dev/null) || BACK=''
ok; [ -n "$BACK" ] && [ "$BACK" != "$PID" ] && [ "$(fleet_cc_session_id "$BACK")" = "$SID" ] \
  || fail "the source must be resumed under the same session id: $(TM capture-pane -p -t "$PANE")"
ok; [ -z "$(field cc_agent)" ] && [ -z "$(field handoff_manifest)" ] && [ -z "$(field source_session_id)" ] \
  && [ -z "$(field migrated_at)" ] && [ "$(field claude_state)" = "done" ] || fail 'rollback must restore the source stamps'
ok; [ "$(field transfer_note)" = '切换失败，已退回：codex exited at startup (status 37)' ] && [ -n "$(field transfer_rolled_back)" ] \
  || fail "rollback must stamp @transfer_note: $(field transfer_note)"
ok; TM capture-pane -p -S - -t "$PANE" | grep -q '▲ 切换失败，已退回' || fail 'the pane must say it rolled back'
ok; grep -q $'\ttransfer-rolled-back\t.*切换失败，已退回' "$TMPDIR/.claude-dash/global/alerts.events" 2>/dev/null \
  || fail 'rollback must raise a transfer-rolled-back event'
ok; ! fleet_rotate_lease_held "$WT" >/dev/null 2>&1 && [ "$(TM display-message -p -t "$PANE" '#{remain-on-exit}')" != on ] \
  || fail 'rollback must release the lease and remain-on-exit'
python3 - "$BUNDLE" "$SID" <<'PY' || fail 'rolled-back package'
import json, pathlib, sys
b = pathlib.Path(sys.argv[1])
st = json.loads((b/'state.json').read_text())
assert st['state'] == 'rolled_back' and 'codex exited at startup (status 37)' in st['detail'], st
assert json.loads((b/'manifest.json').read_text())['source']['session_id'] == sys.argv[2]
assert (b/'pane-target-failed.txt').exists() and (b/'source.jsonl').stat().st_size > 0
PY
ok
# The hold: an AUTOMATIC cutover (here an after-turn arm) of a just-rolled-back
# window refuses before anything; a manual one is the operator's call and goes.
printf '# 人工交接\n下一步：验证。\n' > "$WORK/notes44.md"
transfer --after-turn --handoff "$WORK/notes44.md" && fail 'an automatic retry right after a rollback must be held'
ok; printf '%s' "$OUT" | grep -q '^fleet-transfer: rolled-back: rolled back' && [ -z "$(field agent_transfer_request)" ] \
  && kill -0 "$BACK" || fail "the hold must refuse without touching the source: $OUT"
PID=$BACK
# The source cannot come back either: one attempt, `failed`, pane retained,
# ▲ transfer-failed — never a loop. A manual cutover is not held.
touch "$WORK/fail-source"
transfer && fail 'a double failure must fail'; ok
BUNDLE=$(packet)
ok; printf '%s' "$OUT" | grep -q 'did not resume either' || fail "double failure must say so: $OUT"
ok; [ "$(TM display-message -p -t "$PANE" '#{pane_dead}')" = 1 ] && [ -d "$WT" ] || fail 'double failure must retain the dead pane'
ok; [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$BUNDLE/state.json")" = failed ] || fail 'double failure must stay failed'
ok; case "$(field transfer_note)" in 切换失败，原会话也未能恢复*) ;; *) false ;; esac || fail "double-failure note: $(field transfer_note)"
ok; grep -q $'\ttransfer-failed\t' "$TMPDIR/.claude-dash/global/alerts.events" || fail 'double failure must raise transfer-failed'
ok; [ "$(grep -c $'\ttransfer-rolled-back\t' "$TMPDIR/.claude-dash/global/alerts.events")" = 1 ] || fail 'a double failure must not roll back twice'
python3 - "$BUNDLE" <<'PY' || fail 'failed target recovery metadata'
import json, pathlib, sys
b = pathlib.Path(sys.argv[1])
assert json.loads((b/'state.json').read_text())['state'] == 'failed'
assert (b/'source.jsonl').stat().st_size > 0
assert '--resume source-44' in (b/'resume-source.sh').read_text()
PY
ok
rm "$WORK/fail-source"
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

# issue #1667: the TARGET's login is read before the source is asked anything.
# With the one Codex profile reauth_required, --dry-run and the cutover refuse
# (exit 1, `target-auth: …`), the source keeps running untouched, no package is
# written, no lease taken, and a ▲ transfer-refused event is recorded; once the
# profile is valid the same cutover goes through.
printf 'reauth_required\n' > "$WORK/login-state"
spawn 52 issue normal
PKGS=$(find "$FLEET_CONF_DIR/handoffs" -mindepth 1 -maxdepth 1 ! -name retry | wc -l | tr -d ' ')
transfer --codex-home "$WORK/codex-home" --dry-run && fail 'dry-run onto a reauth_required profile must refuse'
ok; printf '%s' "$OUT" | grep -q 'target auth: REFUSED · Codex profile needs a verified subscription login: work (reauth_required)' || fail "dry-run must name the login: $OUT"
transfer --codex-home "$WORK/codex-home" && fail 'cutover onto a reauth_required profile must refuse'
ok; printf '%s' "$OUT" | grep -q '^fleet-transfer: target-auth: Codex profile needs a verified subscription login: work (reauth_required)' || fail "the refusal must be target-auth: $OUT"
ok; kill -0 "$PID" && [ -z "$(field cc_agent)" ] && TM capture-pane -p -t "$PANE" | grep -q "Claude ready $SID" || fail 'a refused target must leave the source running, untouched'
ok; [ "$(find "$FLEET_CONF_DIR/handoffs" -mindepth 1 -maxdepth 1 ! -name retry | wc -l | tr -d ' ')" = "$PKGS" ] && ! fleet_rotate_lease_held "$WT" >/dev/null 2>&1 || fail 'a refusal must write no package and take no lease'
ok; grep -q $'\ttransfer-refused\t.*reauth_required' "$TMPDIR/.claude-dash/global/alerts.events" 2>/dev/null \
  || fail "a refusal must record a transfer-refused event: $(cat "$TMPDIR/.claude-dash/global/alerts.events" 2>/dev/null)"
ok; R52=$(ls -d "$FLEET_CONF_DIR/handoffs/retry/$LBL"-* 2>/dev/null | head -n 1) && [ -e "$R52/pending" ] \
  && grep -q '"origin": "refused"' "$R52/request.json" && grep -q '"wait": "codex/work"' "$R52/request.json" \
  || fail "a refused manual switch must leave a pending retry record (issue #1669): $(cat "$R52/request.json" 2>/dev/null)"
ok; grep -q $'\ttransfer-refused\t.*登录后自动重试' "$TMPDIR/.claude-dash/global/alerts.events" || fail 'the refusal event must say it will be retried'
printf 'valid\n' > "$WORK/login-state"
transfer --codex-home "$WORK/codex-home" || fail "a valid profile must still cut over: $OUT"
ok; ! fleet_pid_alive "$PID" && [ "$(field cc_agent)" = codex ] || fail 'the valid-login cutover must switch'
ok; printf '%s' "$OUT" | grep -q 'codex started' || fail "valid-login cutover output: $OUT"
ok; [ ! -e "$R52/pending" ] && grep -q '"state": "superseded"' "$R52/request.json" || fail 'a switch done by hand must supersede the waiting retry'

# issue #1669 (EPIC #1665 C5): the TARGET's credential dies as it starts → the
# switch rolls back AND leaves a retry record; while the login is still dead a
# resume touches nothing; ↵ re-login (`fleet-relogin.sh login codex/work`, the
# fake device flow) makes it valid and the SAME conversation is switched — once.
spawn 53 issue normal
touch "$WORK/auth-dies"
transfer --codex-home "$WORK/codex-home" && fail 'a target whose login dies at start must not report success'
ok; printf '%s' "$OUT" | grep -q '^fleet-transfer: rolled-back:' || fail "it must roll back: $OUT"
R53=$(printf '%s\n' "$OUT" | sed -n 's/^fleet-transfer: retry recorded: //p')
python3 - "$R53" <<'PY2' || fail "the rollback must record a pending retry: $OUT"
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); r = json.loads((d/'request.json').read_text())
assert r['state'] == 'pending' and r['origin'] == 'rolled_back' and r['wait'] == 'codex/work', r
assert r['sid'] == 'source-53' and r['to'] == 'codex' and r['why'].startswith('target-auth: '), r
assert (d/'pending').exists() and oct(d.stat().st_mode & 0o777) == '0o700'
PY2
ok; grep -q $'\ttransfer-rolled-back\t.*登录后自动重试' "$TMPDIR/.claude-dash/global/alerts.events" || fail 'the rollback event must say it will be retried'
rm "$WORK/auth-dies"
BACK=$(fleet_pane_claude_pid "$PANE" "$LBL" 2>/dev/null) || fail 'source must be back after the rollback'
OUT=$(bash "$IBIN/fleet-relogin.sh" resume 2>&1) || fail "resume: $OUT"
ok; printf '%s' "$OUT" | grep -q 'still waiting' && [ -e "$R53/pending" ] && kill -0 "$BACK" && [ -z "$(field cc_agent)" ] \
  || fail "a resume while the login is still dead must leave everything as it is: $OUT"
bash "$IBIN/fleet-transfer.sh" --retry "$R53" >/dev/null 2>&1; rc=$?
ok; [ "$rc" = 3 ] && [ -e "$R53/pending" ] || fail "--retry on a still-dead login must exit 3 and stay pending (rc=$rc)"
# a slow runner: the retry child boots Codex under the same wait as any cutover
OUT=$(FLEET_TRANSFER_BOOT_WAIT=10 bash "$IBIN/fleet-relogin.sh" login codex/work </dev/null 2>&1) || fail "re-login: $OUT"
ok; printf '%s' "$OUT" | grep -q 'https://auth.example.invalid/device' && printf '%s' "$OUT" | grep -q '已自动接着切换' \
  || fail "the re-login must show the device link and then switch: $OUT
--- retry transfer.log:
$(cat "$R53/transfer.log" "$R53/retry.err" 2>&1)"
ok; ! fleet_pid_alive "$BACK" && [ "$(field cc_agent)" = codex ] && [ "$(field source_session_id)" = source-53 ] \
  || fail "after the login the same conversation must be on Codex: $(TM capture-pane -p -t "$PANE")"
python3 - "$R53" <<'PY2' || fail 'the retried record must be done, attempted once'
import json, pathlib, sys
d = pathlib.Path(sys.argv[1]); r = json.loads((d/'request.json').read_text())
assert r['state'] == 'done' and r['attempts'] == 1 and not (d/'pending').exists(), r
PY2
ok; grep -q $'\ttransfer-retried\t' "$TMPDIR/.claude-dash/global/alerts.events" || fail 'a landed retry must leave a transfer-retried event'
OUT=$(bash "$IBIN/fleet-relogin.sh" resume 2>&1)
ok; printf '%s' "$OUT" | grep -q 'no switch was waiting' || fail "a second resume must find nothing: $OUT"
OUT=$(bash "$IBIN/fleet-transfer.sh" --retry "$R53" 2>&1) && fail 'a done record must not be retried'
ok; printf '%s' "$OUT" | grep -q 'not pending' || fail "a second --retry must say it was retried already: $OUT"

# …and a retry that fails AGAIN is final: no new record, `failed`, never a loop.
printf 'reauth_required\n' > "$WORK/login-state"
spawn 54 issue normal
transfer --codex-home "$WORK/codex-home" && fail 'refused'
R54=$(printf '%s\n' "$OUT" | sed -n 's/^fleet-transfer: retry recorded: //p')
ok; [ -e "$R54/pending" ] || fail "the refusal must record a retry: $OUT"
printf 'valid\n' > "$WORK/login-state"; touch "$WORK/auth-dies"
OUT=$(bash "$IBIN/fleet-relogin.sh" resume 2>&1)
ok; printf '%s' "$OUT" | grep -q '重试失败，不再重试' || fail "a failing retry must say it is final: $OUT"
ok; grep -q '"state": "failed"' "$R54/request.json" && [ ! -e "$R54/pending" ] \
  && [ -z "$(ls "$FLEET_CONF_DIR"/handoffs/retry/*/pending 2>/dev/null)" ] || fail "a failed retry must not re-record: $(cat "$R54/request.json")"
BACK=$(fleet_pane_claude_pid "$PANE" "$LBL" 2>/dev/null) || BACK=''
ok; [ -n "$BACK" ] && [ "$(fleet_cc_session_id "$BACK")" = source-54 ] || fail 'the failed retry must still roll the source back'
rm "$WORK/auth-dies"; printf 'valid\n' > "$WORK/login-state"
PKGS=$(ls "$FLEET_CONF_DIR/handoffs" | wc -l | tr -d ' ')
OUT=$(bash "$IBIN/fleet-relogin.sh" resume 2>&1)
ok; printf '%s' "$OUT" | grep -q 'no switch was waiting' && kill -0 "$BACK" && [ -z "$(field cc_agent)" ] \
  && [ "$(ls "$FLEET_CONF_DIR/handoffs" | wc -l | tr -d ' ')" = "$PKGS" ] \
  || fail "after a failed retry nothing runs again, even once the login is fine: $OUT"
ok; grep -q $'\ttransfer-retry-failed\t' "$TMPDIR/.claude-dash/global/alerts.events" || fail 'a failed retry must leave a transfer-retry-failed event'
rm -f "$WORK/login-state"

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
fi

# Codex source fixture: the launcher owns the pane and exits through the real
# --codex-exit cleanup path. The transfer lease must retain that same window.
cat > "$WORK/codex-source.pl" <<'PL'
use JSON::PP; use Cwd; use Time::HiRes qw(time); use IO::Select;
my ($sid, $home, $transcript, $mode) = @ARGV;
alarm 120;
my $pane = $ENV{TMUX_PANE};
system('tmux', 'set-option', '-w', '-t', $pane, '@cc_agent', 'codex');
system('tmux', 'set-option', '-w', '-t', $pane, '@cc_launcher_pid', "$$");
system('tmux', 'set-option', '-w', '-t', $pane, '@codex_identity', encode_json({session_id=>$sid, owner=>"$$", home=>$home, transcript=>$transcript, cwd=>getcwd()}));
$|=1; print "Codex source ready\n";
# A real TUI receives bytes without canonical line buffering. Like Codex, an
# unbracketed typing burst absorbs Enter as a pasted newline. The old readline
# fixture falsely passed /exit + immediate Enter even when the TUI never quit.
system('stty', '-icanon', '-echo', 'min', '1', 'time', '0') == 0 or die;
my ($pending, $draft, $last, $paste) = ('', '', 0, 0);
my $input = IO::Select->new(\*STDIN);
while ($input->can_read(30)) {
    sysread(STDIN, my $chunk, 4096) or last;
    $pending .= $chunk;
    while (length $pending) {
        if ($pending =~ s/^\e\[200~//) { $paste=1; next; }
        if ($pending =~ s/^\e\[201~//) { $paste=0; $last=0; next; }
        last if $pending =~ /^\e(?:\[(?:2(?:0(?:[01])?)?)?)?$/;
        my $key=substr($pending, 0, 1, '');
        if ($key eq "\x15") { $draft=''; $last=0; next; }
        next if $key eq "\e";
        if (!$paste && $key =~ /[\r\n]/ && time-$last >= 0.03) {
            my $line=$draft; $draft=''; $line =~ s/\s+$//;
            next unless $line eq '/exit' && $mode ne 'stuck';
            system('/bin/bash', "$ENV{TRANSFER_TEST_ROOT}/install/bin/session-end-hook.sh", '--codex-exit', "$$");
            exit 0;
        }
        $draft .= $key;
        $last=time unless $paste;
    }
}
PL
spawn_codex() {
  local n=$1 cmd
  WT="$WORK/codex wt '$n"; git -C "$MAIN" worktree add -qb "issue-$n" "$WT" || fail 'Codex worktree'
  SID="11111111-1111-4111-8111-1111111111$n"
  CHOME=${3:-"$WORK/codex home's account"}; mkdir -p "$CHOME/sessions/2026/09/17"
  TRANSCRIPT="$CHOME/sessions/2026/09/17/rollout-$SID.jsonl"
  python3 - "$TRANSCRIPT" "$SID" "$WT" <<'PYSOURCE'
import json, pathlib, sys
path, sid, wt = sys.argv[1:]
rows=[{'type':'session_meta','payload':{'id':sid,'cwd':wt}}]
for role, text in [('user','继续修复原任务'),('assistant','已验证，下一步提交修改')]:
    rows.append({'type':'response_item','payload':{'type':'message','role':role,'content':[{'type':'input_text' if role=='user' else 'output_text','text':text}]}})
pathlib.Path(path).write_text(''.join(json.dumps(r)+'\n' for r in rows))
PYSOURCE
  printf -v cmd 'exec %q %q %q %q %q %q' "$FB/codex" "$WORK/codex-source.pl" "$SID" "$CHOME" "$TRANSCRIPT" "${2:-normal}"
  WIN=$(TM new-window -d -t "$LBL:" -n "codex-$n" -c "$WT" -P -F '#{window_id}' "$cmd") || fail 'Codex pane'
  PANE=$(TM display-message -p -t "$WIN" '#{pane_id}')
  TM set-option -w -t "$WIN" @worktree "$WT"
  TM set-option -w -t "$WIN" @issue "$n"
  TM set-option -w -t "$WIN" @claude_state "done"
  for ((attempt=0; attempt<30; attempt++)); do
    [ -n "$(field codex_identity)" ] && break
    sleep 0.1
  done
  PID=$(field cc_launcher_pid); [ -n "$PID" ] || fail 'Codex launcher identity'
}
if [ "${1:-}" = --proxy-home ]; then
  REAL_HOME="$HOME/.codex"
  MIRROR="$FLEET_CONF_DIR/cred-proxy/codex-homes/source-fixture"
  mkdir -p "$REAL_HOME/sessions" "$MIRROR" "$FLEET_CONF_DIR/cred-proxy/sessions"
  printf '%s\n' "$REAL_HOME" > "$MIRROR/.fleet-real-home"
  ln -s "$REAL_HOME/sessions" "$MIRROR/sessions"
  printf 'provider=codex\naccount=default\nroute=direct\n' > "$FLEET_CONF_DIR/cred-proxy/sessions/source-fixture"
  printf '%s\n' "$REAL_HOME" > "$WORK/profile-home"
  printf 'valid\n' > "$WORK/login-state"
  printf 'Continue the same task after this clean Stop.\n' > "$WORK/notes.md"
  export FLEET_FAILOVER=1
  spawn_codex 66 normal "$MIRROR"
  export CODEX_HOME="$MIRROR"
  # The successor binds a native identity; no API/model or live login is used.
  cat > "$WORK/codex.pl" <<'PLPROXY'
use JSON::PP; use Cwd;
alarm 60;
my $record = encode_json({owner=>"$$", session_id=>'22222222-2222-4222-8222-222222222222',
                         home=>$ENV{CODEX_HOME}, cwd=>getcwd()});
system('tmux','set-option','-w','-t',$ENV{TMUX_PANE},'@cc_launcher_pid',"$$");
system('tmux','set-option','-w','-t',$ENV{TMUX_PANE},'@codex_identity',$record);
$|=1; print "Codex native successor bound\n";
while (<STDIN>) { }
PLPROXY
  TM set-option -w -t "$WIN" @claude_state working
  transfer --dry-run && fail 'busy proxy source must refuse immediate transfer'; ok
  printf 'reauth_required\n' > "$WORK/login-state"
  transfer --after-turn --handoff "$WORK/notes.md" && fail 'invalid target login must refuse arm'; ok
  [ -z "$(field agent_transfer_request)" ] && kill -0 "$PID" || fail 'auth refusal altered source'
  printf 'valid\n' > "$WORK/login-state"
  SP=$(TM display-message -p -t "$PANE" '#{socket_path}')
  OUT=$(TMUX="$SP,0,0" TMUX_PANE="$PANE" FLEET_TRANSFER_IDLE_WAIT=20 FLEET_HANDOFF_DEFER_SECS=0 \
    bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$PANE" --to codex \
    --after-turn --handoff "$WORK/notes.md" 2>&1) || fail 'valid proxy home must arm without an explicit target home'
  REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
  [ -s "$REQUEST/request.json" ] || fail 'arm returned no durable request'; ok
  TM set-option -w -t "$WIN" @claude_state done
  sleep 1
  kill -0 "$PID" || fail 'arm/stale done was mistaken for clean Stop'; ok
  TM set-option -w -t "$WIN" @claude_state working
  stop_turn
  wait_request started; ok
  fleet_pid_alive "$PID" && fail 'source survived the clean handoff'
  MANIFEST=$(field handoff_manifest); BUNDLE=${MANIFEST%/*}
  python3 "$IBIN/.fleet-transfer.py" target-ready "$BUNDLE" "$LBL" "$PANE" >/dev/null \
    || fail 'armed/started is not proof of native successor binding'; ok
  python3 - "$MANIFEST" "$MIRROR" "$REAL_HOME" "$WT" "$SID" <<'PYPROXY' || fail 'same-task provenance or normalized launch home lost'
import json, sys
m=json.load(open(sys.argv[1]))
assert m['source']['codex_home']==sys.argv[2] and m['source']['session_id']==sys.argv[5]
assert m['target']['codex_home']==sys.argv[3] and m['workspace']['path']==sys.argv[4]
assert m['source_resume_argv'][4]==sys.argv[2]
PYPROXY
  ok
  printf 'fleet-transfer proxy-home selftest: PASS (%s checks; arm and native successor bound separately)\n' "$checks"
  exit 0
fi
spawn_codex 61
# A visible sidebar must neither block handoff nor become its source pane.
SIDEBAR=$(TM split-window -hd -t "$PANE" -P -F '#{pane_id}' 'sleep 120')
transfer --prepare-only && fail 'a second ordinary pane must still refuse'; ok
TM set-option -p -t "$SIDEBAR" @sidebar 1
TM select-pane -t "$SIDEBAR"
transfer --prepare-only --handoff "$WORK/notes.md" || fail 'prepare Codex native handoff'
BUNDLE=$(packet)
python3 - "$BUNDLE" "$SID" "$CHOME" <<'PYCODEX' || fail 'Codex provenance or text rendering'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]);m=json.loads((p/'manifest.json').read_text())
assert m['source']['agent']=='codex' and m['source']['session_id']==sys.argv[2]
assert m['source']['codex_home']==sys.argv[3] and m['source']['registry_path'] is None
assert m['source_resume_argv'][1:]==['--agent','codex','--codex-home',sys.argv[3],'resume',sys.argv[2]]
assert '继续修复原任务' in (p/'history.md').read_text()
assert '已验证' in (p/'history.md').read_text()
PYCODEX
ok
TM select-pane -t "$PANE"
TM set-option -w -t "$WIN" @cc_launcher_pid 99999999
transfer --prepare-only && fail 'stale Codex launcher must refuse'
TM set-option -w -t "$WIN" @cc_launcher_pid "$PID"; ok
TM set-option -w -t "$WIN" @claude_state working
transfer && fail 'busy Codex source must refuse'; ok
# looping is accepted only on native evidence (#786); a thread that cannot be
# read as idle with a completed last turn still refuses.
TM set-option -w -t "$WIN" @claude_state looping
transfer && fail 'an unverifiable looping Codex source must refuse'; ok
TM set-option -w -t "$WIN" @claude_state working
TM set-option -w -t "$WIN" @handoff_armed 1
FLEET_TRANSFER_IDLE_WAIT=20 FLEET_HANDOFF_DEFER_SECS=0 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm Codex context cycle'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
kill -0 "$PID" || fail 'Codex exited before fresh Stop'
stop_turn; wait_request started; ok
fleet_pid_alive "$PID" && fail 'Codex source survived cutover'
[ "$(field source_agent)" = codex ] && [ "$(field source_session_id)" = "$SID" ] || fail 'Codex cycle provenance lost'
[ "$(TM display-message -p -t "$SIDEBAR" '#{window_id}')" = "$WIN" ] || fail 'handoff removed the sidebar'; ok
TM kill-pane -t "$SIDEBAR"
python3 - "$WORK/target-argv.json" "$CHOME" <<'PYHOME' || fail 'Codex cycle changed account home'
import json, sys
assert json.load(open(sys.argv[1]))['home']==sys.argv[2]
PYHOME
ok
spawn_codex 64
printf '#!/bin/sh\nexit 1\n' > "$IBIN/fleet-codex-account.sh"; chmod +x "$IBIN/fleet-codex-account.sh"
transfer --require-codex-idle && fail 'unverified native idle must refuse account cutover'
kill -0 "$PID" || fail 'failed native idle check must preserve source'; ok
NEXT_HOME="$WORK/next Codex account"; mkdir -p "$NEXT_HOME"
transfer --codex-home "$NEXT_HOME" || fail 'Codex account cutover'
BUNDLE=$(packet)
python3 - "$WORK/target-argv.json" "$BUNDLE" "$CHOME" "$NEXT_HOME" <<'PYROTATE' || fail 'account cutover lost source or target home'
import json,pathlib,sys
launch=json.load(open(sys.argv[1]));m=json.loads((pathlib.Path(sys.argv[2])/'manifest.json').read_text())
assert launch['home']==sys.argv[4]
assert m['target']['codex_home']==sys.argv[4]
assert m['source']['codex_home']==sys.argv[3]
assert m['source_resume_argv'][4]==sys.argv[3]
PYROTATE
ok
spawn_codex 62
TM set-option -w -t "$WIN" @handoff_armed 1
FLEET_TRANSFER_IDLE_WAIT=20 FLEET_HANDOFF_DEFER_SECS=0 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm Codex stale-source case'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
TM set-option -w -t "$WIN" @codex_identity '{}'
stop_turn; wait_request failed
kill -0 "$PID" || fail 'changed Codex identity must preserve source'; ok
[ "$(field handoff_armed)" = 1 ] || fail 'failed waiter must not unlatch a changed Codex identity'; ok
spawn_codex 63 stuck
transfer && fail 'stuck Codex source must refuse replacement'
kill -0 "$PID" || fail 'stuck Codex source must not be killed'; ok
BUNDLE=$(packet)
python3 - "$BUNDLE" <<'PYTIMEOUT' || fail 'exit timeout must retain the actual failure and screen'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
assert 'source did not exit' in json.loads((p/'state.json').read_text())['detail']
assert (p/'pane-exit-timeout.txt').is_file()
PYTIMEOUT
ok
TM set-option -w -t "$WIN" @handoff_armed 1
FLEET_TRANSFER_IDLE_WAIT=20 FLEET_HANDOFF_DEFER_SECS=0 transfer --after-turn --handoff "$WORK/notes.md" || fail 'arm failed Codex cycle'
REQUEST=$(printf '%s\n' "$OUT" | sed -n 's/^after-turn request: //p')
stop_turn; wait_request failed
kill -0 "$PID" || fail 'failed cycle killed the original source'
[ -z "$(field handoff_armed)" ] || fail 'failed cycle must release the old context latch for retry'; ok

# Reverse handoff uses exact Claude registry readiness in the retained pane.
spawn_codex 65
OUT=$(bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$PANE" --to claude 2>&1) || fail 'Codex to Claude cutover'
BUNDLE=$(packet)
python3 - "$BUNDLE" "$SID" <<'PYREVERSE' || fail 'reverse handoff lost native target binding or source path'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads((p/'manifest.json').read_text())
assert m['source']['agent']=='codex' and m['source']['session_id']==sys.argv[2]
assert m['target']['agent']=='claude' and m['target']['session_id']=='target-claude'
assert m['source']['transcript_path'] and m['target']['bound_at']
PYREVERSE
ok
# Same-agent Claude continuation preserves its native UUID and saved draft.
spawn 66 issue normal
printf '1、做。2、' > "$WORK/unsent.txt"
OUT=$(bash "$IBIN/fleet-transfer.sh" --session "$LBL" --window "$PANE" --to claude --native-resume --draft-file "$WORK/unsent.txt" 2>&1) || fail 'native Claude continuation'
BUNDLE=$(packet)
python3 - "$BUNDLE" <<'PYNATIVE' || fail 'native UUID or unsent draft contract'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads((p/'manifest.json').read_text())
assert m['source']['session_id']==m['target']['session_id']=='source-66'
assert m['native_resume'] is True and m['draft']['state']=='unsent'
assert pathlib.Path(m['draft']['path']).read_text()=='1、做。2、'
assert '1、做。2、' not in (p/'pickup.md').read_text()
PYNATIVE
ok

printf 'fleet-transfer selftest: OK (%s checks)\n' "$checks"
