#!/usr/bin/env python3
"""Retain worker windows while their exact native conversations are hibernated.

Only positive native evidence authorizes exit. Screen/input and process probes
can veto it, never manufacture an idle turn. Records survive controller failure;
kernel locks serialize wake, sleep and delivery. No model requests on wake.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import runpy
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid

BIN = Path(__file__).absolute().parent
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))
CODEX = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
ARGV = runpy.run_path(str(BIN / 'fleet_sleep_argv.py'))


def run(argv, **kwargs):
    return subprocess.check_output([str(x) for x in argv], text=True,
                                   stderr=subprocess.PIPE, timeout=kwargs.pop('timeout', 15), **kwargs).strip()


def save(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.sleep-')
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(data, out, ensure_ascii=False)
            out.flush(); os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def root(session):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', session):
        raise ValueError('invalid fleet session')
    return Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet'))) / 'fleets' / session / 'sleep'


@contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(path, 'a') as fd:
        os.chmod(path, 0o600)
        try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('another sleep/wake/delivery owns this worker') from None
        yield


def alive(pid):
    if int(pid) <= 0: return False
    try: os.kill(int(pid), 0); return True
    except ProcessLookupError: return False


def process_start(pid):
    if int(pid)<=0: return ''
    try: return run(['ps','-p',str(pid),'-o','lstart=','-o','comm='])
    except subprocess.CalledProcessError: return ''


def source_alive(data):
    return bool(data.get('source_start')) and process_start(data['source']['pid'])==data['source_start']


def process_tree_rss(pid):
    rows={}
    for line in run(['ps','-axo','pid=,ppid=,rss=']).splitlines():
        fields=line.split()
        if len(fields)==3 and all(f.isdigit() for f in fields):
            p,parent,rss=map(int,fields);rows[p]=(parent,rss)
    total=0;pending=[int(pid)];seen=set()
    while pending:
        p=pending.pop()
        if p in seen:continue
        seen.add(p);total+=rows.get(p,(0,0))[1]
        pending.extend(child for child,(parent,_) in rows.items() if parent==p and child!=p)
    return total


class Worker:
    def __init__(self, session, target):
        self.session = session
        self.window = self.tm('display-message', '-p', '-t', target, '#{window_id}')
        if not re.fullmatch(r'@\d+', self.window): raise ValueError('unknown window')
        if self.opt('session_name') != session: raise ValueError('wrong fleet')
        panes = self.tm('list-panes', '-t', self.window, '-F', '#{pane_id} #{@sidebar} #{@dash}').splitlines()
        workers = [p.split()[0] for p in panes if len(p.split()) == 1]
        if len(workers) != 1: raise ValueError('requires exactly one worker pane')
        self.pane = workers[0]
        if self.opt('window_name') in ('dash','plan','backlog') or self.opt('@hub') == '1':
            raise ValueError('panel/hub is not a worker')
        if not self.opt('@issue').isdigit() and self.opt('@raw') != '1':
            raise ValueError('not an issue or scratch worker')
        self.directory = root(session)
        self.lockfile = self.directory / ('window-' + self.window[1:] + '.lock')
        self.quota_directory = self.directory.parents[2] / 'handoffs' / 'quota-requests'

    def tm(self, *args):
        return run(['tmux', '-L', self.session, *args], timeout=5)

    def opt(self, name):
        return self.tm('display-message','-p','-t',getattr(self,'pane',self.window),'#{'+name+'}')

    def stamp(self, name, value):
        self.tm('set-option','-w','-t',self.window,name,str(value))

    def command(self,action):
        return shlex.join(['env','FLEET_CONF_DIR='+str(self.directory.parents[2]),
                          'python3',str(BIN/'fleet-sleep.py'),action,'--session',self.session,self.pane])

    def inspect(self):
        return json.loads(run(['bash',BIN/'fleet-transfer.sh','--session',self.session,
                              '--window',self.pane,'--to','codex','--inspect'],timeout=30))

    def visible(self):
        return self.window in self.tm('list-clients','-F','#{window_id}').splitlines()

    def record(self):
        path = Path(self.opt('@sleep_record'))
        if path.parent != self.directory or not path.name.endswith('.json'):
            raise ValueError('missing durable sleep record')
        data = json.loads(path.read_text())
        if data['session'] != self.session or data['pane'] != self.pane or data['window'] != self.window:
            raise ValueError('sleep record belongs to another worker')
        return path, data

    def phase(self, path, data, state, error=''):
        data.update(state=state, updated=time.time(), error=error)
        save(path,data)
        self.stamp('@worker_lifecycle',state if state != 'awake' else '')

    def source_key(self, source):
        return tuple(source[k] for k in ('agent','session_id','pid','worktree','home'))

    def holds_exit(self,data):
        # Some Claude versions unregister their session before SessionEnd. The
        # already-validated process fingerprint remains authoritative until exit.
        if (data['state']!='preparing' or not 0<=time.time()-data['updated']<90
                or self.opt('@worker_lifecycle')!='preparing' or not source_alive(data)):
            return False
        root_pid=int(self.opt('pane_pid'));pid=int(data['source']['pid'])
        rows=TRANSFER['process_rows']();seen=set()
        while pid!=root_pid and pid not in seen and pid in rows:
            seen.add(pid);pid=rows[pid][0]
        return pid==root_pid

    def eligible(self, manual=False):
        if self.opt('@worker_lifecycle'): raise ValueError('already sleeping or transitioning')
        if self.opt('@sleep_keep_awake') == '1': raise ValueError('keep awake enabled')
        if self.visible(): raise ValueError('a client is viewing this worker')
        if self.opt('@claude_state') != 'done': raise ValueError('worker is not done')
        for option in ('@handoff_armed','@agent_transfer_request'):
            if self.opt(option): raise ValueError('handoff/failover is pending')
        until = self.opt('@agent_transfer_until')
        if until and (not until.isdigit() or int(until) > time.time()): raise ValueError('transfer is active')
        source = self.inspect()
        source['restart_options']=source_options(source)
        self.check_quota_wait(source)
        previous = self.opt('@handoff_manifest')
        if previous:
            loop = Path(previous).parent/'loop/state.json'
            if loop.exists() and json.loads(loop.read_text()).get('status') not in ('stopped','complete','cancelled'):
                raise ValueError('Fleet loop is active')
        evidence = json.loads(self.opt('@sleep_evidence') or '{}')
        matching_stop = (evidence.get('session_id') == source['session_id']
                         and evidence.get('pane') == self.pane and evidence.get('pid') == source['pid'])
        now = time.time()
        after = int(os.environ.get('FLEET_SLEEP_AFTER','1800'))
        if after < 1: raise ValueError('invalid sleep threshold')
        if source['agent'] == 'claude':
            if not matching_stop: raise ValueError('no native Stop evidence for this process/session')
            if evidence.get('background_tasks') != [] or evidence.get('session_crons') != []:
                raise ValueError('background work/timers present or unknown')
            if evidence.get('stop_hook_active'): raise ValueError('Stop continuation is active')
            if evidence.get('permission_mode') not in ('default','acceptEdits','plan','bypassPermissions','dontAsk','auto'):
                raise ValueError('unknown Claude permission mode')
        else:
            data = source['codex_identity']
            client = RPC(data.get('remote',''),timeout=5)
            try:
                thread = client.call('thread/read',{'threadId':source['session_id'],'includeTurns':True})['thread']
                goal=client.call('thread/goal/get',{'threadId':source['session_id']}).get('goal')
                if goal and goal.get('status')!='complete': raise ValueError('Codex goal is unfinished')
                loaded=client.call('thread/loaded/list',{})
                if loaded.get('nextCursor') or not isinstance(loaded.get('data'),list):
                    raise ValueError('loaded thread inventory is incomplete')
                for sid in loaded['data']:
                    if sid==source['session_id']: continue
                    child=client.call('thread/read',{'threadId':sid,'includeTurns':False})['thread']
                    if child.get('status',{}).get('type')!='idle':
                        raise ValueError('another thread/subagent is active or unknown')
                    child_goal=client.call('thread/goal/get',{'threadId':sid}).get('goal')
                    if child_goal and child_goal.get('status')!='complete':
                        raise ValueError('another thread/subagent has an unfinished goal')
                hooks=client.call('hooks/list',{'cwds':[source['worktree']]})
                source['hook_trust']=hook_trust(hooks,source['restart_options'])
            finally: client.close()
            if thread.get('id') != source['session_id'] or thread.get('status',{}).get('type') != 'idle':
                raise ValueError('Codex is not natively idle')
            if (not thread.get('cwd') or not thread.get('path')
                    or Path(thread['cwd']).resolve()!=Path(source['worktree']).resolve()
                    or Path(thread['path']).resolve()!=Path(source['transcript']).resolve()):
                raise ValueError('Codex native worktree/history does not match this worker')
            turns = thread.get('turns') or []
            if not turns or turns[-1].get('status') != 'completed': raise ValueError('no completed Codex turn')
            last = turns[-1]
            if any(item.get('status') not in (None,'completed','failed','declined','interrupted')
                   for item in last.get('items', [])):
                raise ValueError('Codex tool is still active or unknown')
            completed = last.get('completedAt')
            if (last.get('id') and type(completed) in (int,float)
                    and math.isfinite(completed) and 0 < completed <= now):
                # Native completion is available for workers predating the Stop
                # hook and for resumed conversations. Never use screen age/mtime.
                evidence = dict(session_id=source['session_id'], pid=source['pid'], pane=self.pane,
                                at=completed, turn_id=last['id'], proof='native-completed-turn')
            elif completed is not None or not matching_stop:
                raise ValueError('no native completion time or matching Stop evidence')
        at = evidence.get('at')
        if type(at) not in (int,float) or not math.isfinite(at) or not 0 < at <= now:
            raise ValueError('invalid native idle time')
        if not manual and now-max(at,float(self.opt('@sleep_woke_at') or 0)) < after:
            raise ValueError('idle grace has not elapsed')
        # A native idle turn can still own commands. Unknown descendants veto.
        quiet_processes(source)
        draft = INPUT['snapshot'](self.session,self.pane,agent=source['agent'])
        if draft.get('state') != 'empty': raise ValueError('input contains a draft or cannot be proven empty')
        transcript = Path(source['transcript'])
        if not transcript.is_file() or not transcript.stat().st_size: raise ValueError('history is missing')
        with transcript.open('rb') as stream:
            stream.seek(-1,2)
            if stream.read(1) != b'\n': raise ValueError('history has an incomplete record')
        if any(self.inbox().glob('*.json')): raise ValueError('messages await delivery')
        return source,evidence

    def check_quota_wait(self, source):
        if not self.opt('@quota_failover'): return
        identity = [source[k] for k in ('session','window','session_id','pid','agent')]
        key = hashlib.sha256(json.dumps(identity).encode()).hexdigest()[:32]
        path = self.quota_directory / key / 'request.json'
        if not path.is_file(): raise ValueError('unverified quota failover marker')
        request = json.loads(path.read_text())
        if any(request.get('source',{}).get(k) != source[k]
               for k in ('session','window','session_id','pid','agent')):
            raise ValueError('quota request belongs to another source')
        state = request.get('state')
        if state in ('cancelled','recovered'): return
        # Only an unstarted, proactive account switch can wait until wake.
        # Hard quota failures, uncertain deliveries and cutovers remain vetoes.
        if state in ('waiting','waiting-quota','waiting-evidence') and request.get('hard') is False:
            return
        raise ValueError('quota failover is active or requires recovery')

    def sleep(self, manual=False, dry=False):
        # Match the quota reconciler's fleet lock: its waiting request cannot
        # turn into a migration between our native probe and graceful exit.
        with lock(self.quota_directory / (self.session+'.lock')), lock(self.lockfile):
            source,evidence = self.eligible(manual)
            if dry: return {'eligible':True,'session_id':source['session_id']}
            with TRANSFER['transition_lock'](source['worktree']):
                # Durable recovery is written before sending any exit request.
                path = self.directory/(str(uuid.uuid4())+'.json')
                data = dict(session=self.session,window=self.window,pane=self.pane,source=source,
                            evidence=evidence,created=time.time(),state='preparing',
                            source_start=process_start(source['pid']),
                            remain=self.opt('remain-on-exit'),resume_count=0)
                data['screen'] = self.tm('capture-pane','-p','-t',self.pane)
                data['model'] = self.opt('@cc_model')
                data['options'] = source['restart_options']
                data['rss_before_kb']=process_tree_rss(source['pid'])
                if not data['source_start']:raise ValueError('source process disappeared')
                save(path,data)
                current,current_evidence = self.eligible(manual)
                if self.source_key(current) != self.source_key(source) or current_evidence != evidence:
                    raise ValueError('source changed during preparation')
                self.stamp('@sleep_record',path)
                self.phase(path,data,'preparing')
                self.tm('set-option','-p','-t',self.pane,'remain-on-exit','on')
                # Disable input while issuing exit; do not consume user keystrokes
                # in a shell. Native programmatic deliveries use this same lock.
                self.tm('select-pane','-d','-t',self.pane)
                try:
                    if self.visible(): raise ValueError('user entered during preparation')
                    text = '\x1b[200~/exit\x1b[201~' if source['agent']=='codex' else '/exit'
                    # input-off suppresses send-keys too. A single server command
                    # queue enables only for this programmatic exit and closes
                    # the input gate again before processing another client.
                    self.tm('select-pane','-e','-t',self.pane,';',
                            'send-keys','-t',self.pane,'-l',text,';',
                            'send-keys','-t',self.pane,'Enter',';',
                            'select-pane','-d','-t',self.pane)
                    deadline = time.monotonic()+25
                    while source_alive(data) and time.monotonic()<deadline: time.sleep(.2)
                    if source_alive(data): raise ValueError('agent did not exit; no replacement started')
                    # The launcher/server guardian must finish too. Only a dead
                    # pane or its childless leftover shell may be replaced.
                    self.replaceable()
                    self.phase(path,data,'sleeping')
                    command=self.command('park')
                    self.tm('respawn-pane','-k','-t',self.pane,'-c',source['worktree'],command)
                    # Measure the settled placeholder, not its transient shell
                    # immediately after respawn (which understates memory).
                    ready=time.monotonic()+5
                    while self.opt('@sleep_park_ready')!=path.stem and time.monotonic()<ready:time.sleep(.05)
                    if self.opt('@sleep_park_ready')==path.stem:
                        data['rss_parked_kb']=process_tree_rss(self.opt('pane_pid'))
                    save(path,data)
                    if self.visible(): self.wake_locked(path,data)
                    return {'state':data['state'],'record':str(path)}
                except Exception as exc:
                    self.phase(path,data,'failed',str(exc))
                    raise
                finally:
                    if data['state'] not in ('sleeping','preparing','waking'):
                        self.tm('select-pane','-e','-t',self.pane)

    def replaceable(self):
        deadline=time.monotonic()+8
        while time.monotonic()<deadline:
            if self.opt('pane_dead')=='1': return
            pid=int(self.opt('pane_pid'))
            if TRANSFER['process_check']('shell',pid)==0: return
            try: command=run(['ps','-p',str(pid),'-o','command='])
            except subprocess.CalledProcessError:
                time.sleep(.1); continue
            if str(BIN/'fleet-sleep.py') in command and ' park ' in command: return
            time.sleep(.2)
        raise ValueError('pane still owns processes; refusing to replace it')

    def wake_locked(self,path,data):
        if data['state']=='awake': return
        if source_alive(data):
            raise ValueError('original process is still alive; inspect the failed exit')
        self.replaceable()
        source=data['source']
        if not Path(source['worktree']).is_dir() or not Path(source['transcript']).is_file():
            raise ValueError('worktree or exact history is missing')
        self.phase(path,data,'waking')
        self.tm('select-pane','-d','-t',self.pane)
        data['resume_count']+=1
        save(path,data)
        command=self.command('launch')
        self.tm('respawn-pane','-k','-t',self.pane,'-c',source['worktree'],command)
        started=time.monotonic()
        try:
            while time.monotonic()-started<40:
                try:
                    if source['agent']=='codex': self.bind_resumed_codex(source)
                    new=self.inspect()
                    if new['session_id']!=source['session_id'] or new['agent']!=source['agent']:
                        raise ValueError('resumed a different native conversation')
                    if new['pid']!=source['pid'] and INPUT['snapshot'](self.session,self.pane,agent=source['agent']).get('state')=='empty':
                        if source['agent']=='codex' and new['home']!=source['home']:
                            raise ValueError('resumed under a different Codex home')
                        data['wake_seconds']=round(time.monotonic()-started,3)
                        data['resumed_pid']=new['pid']
                        # Quota reconciliation skips waking workers. This marker
                        # belongs to the retired PID; the next tick re-evaluates
                        # the resumed owner instead of inheriting its old wait.
                        self.stamp('@quota_failover','')
                        self.stamp('@sleep_evidence','')
                        self.stamp('@sleep_woke_at',time.time())
                        self.phase(path,data,'awake')
                        return
                except (subprocess.SubprocessError,OSError): pass
                if self.opt('pane_dead')=='1': break
                time.sleep(.25)
            raise ValueError('resume is not ready; inspect the retained worker and retry')
        except Exception as exc:
            self.phase(path,data,'failed',str(exc)); raise
        finally:
            self.tm('select-pane','-e','-t',self.pane)
            self.tm('set-option','-p','-t',self.pane,'remain-on-exit',data['remain'])

    def bind_resumed_codex(self,source):
        # Remote resume may not emit SessionStart. Bind only the explicitly
        # requested UUID after the new launcher's own TUI has loaded it, using
        # read-only RPC. A newest-transcript guess would corrupt fleet identity.
        if self.opt('@codex_identity'): return
        owner=self.opt('@cc_launcher_pid')
        if not owner.isdigit() or not alive(owner): return
        if self.opt('@codex_home')!=source['home']:raise ValueError('resume account home changed')
        rows=TRANSFER['process_rows']();pending=[int(owner)];matches=[]
        while pending:
            parent=pending.pop()
            for pid,(pp,comm) in rows.items():
                if pp!=parent or pid==parent:continue
                pending.append(pid)
                if comm not in ('codex','codex-real'):continue
                args=ARGV['process_argv'](pid)
                if '--remote' in args and 'resume' in args:
                    pos=args.index('resume')
                    if args[pos+1:pos+2]==[source['session_id']]:matches.append(args)
        if len(matches)!=1:return
        args=matches[0];remote=args[args.index('--remote')+1]
        client=RPC(remote,timeout=3)
        try:
            if source['session_id'] not in client.call('thread/loaded/list',{}).get('data',[]):return
            thread=client.call('thread/read',{'threadId':source['session_id'],'includeTurns':False})['thread']
        finally:client.close()
        if thread['id']!=source['session_id'] or Path(thread['cwd']).resolve()!=Path(source['worktree']).resolve():
            raise ValueError('native resumed thread does not match saved worker')
        if not thread.get('path') or Path(thread['path']).resolve()!=Path(source['transcript']).resolve():
            raise ValueError('native resumed history does not match saved worker')
        identity=dict(source['codex_identity'],owner=owner,remote=remote)
        cmds=[]
        for key,value in (('@codex_identity',json.dumps(identity,separators=(',',':'))),
                          ('@codex_session_id',source['session_id']),('@cc_model',identity.get('model',''))):
            cmds.append(shlex.join(['set-option','-w','-t',self.window,key,value]))
        test='#{==:#{@cc_launcher_pid},'+owner+'}'
        self.tm('if-shell','-F','-t',self.pane,test,' ; '.join(cmds))

    def wake(self):
        with lock(self.lockfile):
            if not self.opt('@worker_lifecycle'): return
            path,data=self.record()
            self.wake_locked(path,data)

    def deliver(self,text):
        if not text.strip(): raise ValueError('empty message')
        # Record before waking. A timeout leaves reviewable pending data, never a
        # successful acknowledgement or an automatic duplicate of uncertain work.
        queue=self.inbox()
        token=hashlib.sha256(text.encode()).hexdigest()
        msgpath=queue/(token+'.json')
        with lock(self.lockfile):
            if self.opt('@worker_lifecycle'):
                _,saved=self.record();expected=saved['source']['session_id']
            else:expected=self.inspect()['session_id']
            message=json.loads(msgpath.read_text()) if msgpath.exists() else dict(text=text,state='pending',created=time.time(),session_id=expected)
            if message['state']=='uncertain': raise ValueError('previous delivery is uncertain; inspect '+str(msgpath))
            save(msgpath,message)
            if self.opt('@worker_lifecycle'):
                path,data=self.record(); self.wake_locked(path,data)
            source=self.inspect()
            if message['session_id']!=source['session_id']:raise ValueError('pending message belongs to an earlier conversation')
            self.stamp('@sleep_evidence','')
            try:
                if source['agent']=='codex':
                    run(['python3',BIN/'fleet-codex-session.py','send','--pane',self.pane,'--socket',self.session],input=text,timeout=20)
                else:
                    run(['bash','-c','. "$1"; text=$(cat); fleet_peer_send "$2" "$text" "${FLEET_REPORT_FROM:-fleet}"',
                         'sleep-delivery',BIN/'fleet-lib.sh',str(source['pid'])],input=text,timeout=20)
            except subprocess.TimeoutExpired:
                message['state']='uncertain'; save(msgpath,message); raise
            msgpath.unlink()

    def inbox(self):
        record=self.opt('@sleep_record')
        key=Path(record).stem if record else 'window-'+self.window[1:]
        return self.directory/('inbox-'+key)

    def drain(self):
        for path in sorted(self.inbox().glob('*.json'))[:4]:
            message=json.loads(path.read_text())
            if message['state']=='pending':self.deliver(message['text'])

    def recover(self):
        with lock(self.lockfile):
            path,data=self.record()
            if data['state']=='preparing':
                if source_alive(data):
                    self.phase(path,data,'failed','sleep controller stopped before confirming exit')
                    self.tm('select-pane','-e','-t',self.pane)
                    return
                self.replaceable()
                self.phase(path,data,'sleeping')
                command=self.command('park')
                self.tm('respawn-pane','-k','-t',self.pane,'-c',data['source']['worktree'],command)
                self.tm('select-pane','-d','-t',self.pane)
            if data['state'] in ('waking','failed'):
                try:
                    if data['source']['agent']=='codex': self.bind_resumed_codex(data['source'])
                    source=self.inspect()
                    if (source['session_id']==data['source']['session_id']
                            and source['agent']==data['source']['agent']
                            and (source['agent']!='codex' or source['home']==data['source']['home'])
                            and INPUT['snapshot'](self.session,self.pane,agent=source['agent']).get('state')=='empty'):
                        if source['pid']!=data['source']['pid']:
                            self.stamp('@quota_failover','')
                        self.stamp('@sleep_evidence','')
                        self.stamp('@sleep_woke_at',time.time())
                        self.phase(path,data,'awake')
                        self.tm('select-pane','-e','-t',self.pane)
                        self.tm('set-option','-p','-t',self.pane,'remain-on-exit',data['remain'])
                except (ValueError,OSError,subprocess.SubprocessError): pass
            if data['state']=='sleeping' and self.visible(): self.wake_locked(path,data)


def quiet_processes(source):
    rows=TRANSFER['process_rows']()
    pending=[source['pid']]; seen=set()
    while pending:
        parent=pending.pop()
        if parent in seen: continue
        seen.add(parent)
        for pid,(pp,comm) in rows.items():
            if pp!=parent or pid==parent: continue
            pending.append(pid)
            if source['agent']=='claude': raise ValueError('Claude owns background/tool processes')
            argv=ARGV['process_argv'](pid)
            remote=source['codex_identity'].get('remote','')
            native=comm in ('codex','codex-real')
            npm=(comm=='node' and len(argv)>1 and
                 str(Path(argv[1]).resolve()).endswith('/@openai/codex/bin/codex.js'))
            if native or npm:
                # Only this worker's TUI/server are infrastructure. A separately
                # spawned Codex command is background work, regardless of name.
                for flag in ('--remote','--listen'):
                    if flag in argv and argv[argv.index(flag)+1:argv.index(flag)+2]==[remote]:break
                else:raise ValueError('another Codex process owns a different endpoint')
                continue
            if len(argv)>1 and Path(argv[1]).name=='fleet-codex-runtime.py': continue
            if len(argv)>2 and Path(argv[1]).name=='fleet-loop.py' and argv[2]=='bridge': continue
            if comm=='codex-code-mode-host':
                parent_args=ARGV['process_argv'](parent)
                remote=source['codex_identity'].get('remote','')
                # The bundled persistent JS host is infrastructure only when
                # directly owned by this exact app-server and from its release.
                # Its descendants are still visited and may veto sleep.
                if ('app-server' in parent_args and '--listen' in parent_args
                        and parent_args[parent_args.index('--listen')+1:parent_args.index('--listen')+2]==[remote]
                        and ARGV['process_executable'](pid)==
                            ARGV['process_executable'](parent).with_name('codex-code-mode-host')):
                    continue
            raise ValueError('Codex owns background/tool processes')


def source_options(source):
    pid=source['pid']
    if source['agent']=='codex':
        rows=TRANSFER['process_rows']();pending=[pid];matches=[]
        while pending:
            parent=pending.pop()
            for child,(pp,comm) in rows.items():
                if pp!=parent or child==parent:continue
                pending.append(child)
                if comm not in ('codex','codex-real'):continue
                args=ARGV['process_argv'](child)
                if 'app-server' not in args:matches.append((child,args))
        if len(matches)!=1:raise ValueError('cannot identify exactly one native Codex TUI')
        pid,args=matches[0]
    else:args=ARGV['process_argv'](pid)
    return ARGV['restart_options'](args,source['agent'])


def hook_trust(response,options):
    """Carry invocation-only trust for the exact hooks already authorized.

    Remote Codex resume intentionally rechecks trust even with its bypass flag.
    Native hashes let us preserve the existing invocation without modifying the
    user's config, approving changed hooks, or accepting a review dialog.
    """
    entries=response.get('data')
    if not isinstance(entries,list) or len(entries)!=1 or entries[0].get('errors'):
        raise ValueError('Codex hook inventory is incomplete')
    bypass='--dangerously-bypass-hook-trust' in options
    trusted={}
    for hook in entries[0]['hooks']:
        if not hook['enabled']:
            if hook['trustStatus'] not in ('trusted','managed'):
                raise ValueError('disabled Codex hooks still require native review')
            trusted[hook['key']]={'enabled':False}
            continue
        if hook['trustStatus'] not in ('trusted','managed') and not bypass:
            raise ValueError('Codex hooks require review before resume')
        trusted[hook['key']]={'trusted_hash':hook['currentHash']}
    return trusted


def hook():
    if not os.environ.get('TMUX') or not os.environ.get('TMUX_PANE'): return
    if os.environ.get('CLAUDE_CODE_ENTRYPOINT','cli')!='cli': return
    payload=json.load(sys.stdin)
    if payload.get('hook_event_name')!='Stop': return
    pane=os.environ['TMUX_PANE']
    session=run(['tmux','display-message','-p','-t',pane,'#{session_name}'])
    w=Worker(session,pane)
    source=w.inspect()
    if payload.get('session_id')!=source['session_id']: return
    evidence={k:payload.get(k) for k in ('session_id','background_tasks','session_crons','stop_hook_active','permission_mode')}
    evidence.update(at=time.time(),pid=source['pid'],pane=pane,
                    config_home=os.environ.get('CLAUDE_CONFIG_DIR'),
                    accounts_dir=os.environ.get('FLEET_ACCOUNTS_DIR'))
    w.stamp('@sleep_evidence',json.dumps(evidence,separators=(',',':')))


def launch(w):
    _,data=w.record(); source=data['source']
    env=dict(os.environ)
    for key in ('FLEET_CODEX_MANAGED','FLEET_CODEX_SUBSCRIPTION','FLEET_CODEX_PROFILE',
                'FLEET_CODEX_ACCOUNT','FLEET_ACCOUNT_TARGET','FLEET_ACCOUNT_LABEL',
                'FLEET_LOOP_RECORD','FLEET_LOOP_SPEC','FLEET_LOOP_AGENT'):
        env.pop(key,None)
    env['FLEET_ACCOUNT_SELECTED']='1'
    if data['evidence'].get('accounts_dir'):
        env['FLEET_ACCOUNTS_DIR']=data['evidence']['accounts_dir']
    argv=['bash',str(BIN/'fleet-claude.sh'),'--agent',source['agent'],'--resume',source['session_id']]
    options=data.get('options',[])
    if data['model']:
        # /model can change after launch; the live native model outranks argv.
        clean=[];skip=False
        for arg in options:
            if skip:skip=False;continue
            if arg in ('-m','--model'):skip=True;continue
            if arg.startswith('--model='):continue
            clean.append(arg)
        options=clean
    if source['agent']=='codex':
        # Remote resume restores its recorded native permission profile. Codex
        # rejects permission CLI overrides, even when identical to that profile.
        clean=[];skip=False
        for arg in options:
            if skip:skip=False;continue
            if arg in ('-s','--sandbox','-a','--ask-for-approval'):skip=True;continue
            if arg=='--dangerously-bypass-approvals-and-sandbox' or arg.startswith(('--sandbox=','--ask-for-approval=')):continue
            clean.append(arg)
        options=clean
        argv+=['--codex-home',source['home']]
        sub=source['codex_identity'].get('subscription',{})
        if sub.get('profile'):
            env.update(FLEET_CODEX_PROFILE=sub['profile'],FLEET_CODEX_ACCOUNT=sub['account'])
        if data['model'] and not any(a.split('=')[0] in ('-m','--model') for a in options):
            argv+=['-m',data['model']]
    else:
        env.pop('CLAUDE_CONFIG_DIR',None)
        if data['evidence'].get('config_home'):
            env['CLAUDE_CONFIG_DIR']=data['evidence']['config_home']
        if source.get('label'): env['FLEET_ACCOUNT_LABEL']=source['label']
        # The native mode can change during the session. Preserve the rest of
        # the launch policy while replacing its old permission selection.
        clean=[];skip=False
        for arg in options:
            if skip:skip=False;continue
            if arg=='--permission-mode':skip=True;continue
            if arg.startswith('--permission-mode=') or arg=='--dangerously-skip-permissions':continue
            clean.append(arg)
        options=clean
        mode=data['evidence']['permission_mode']
        argv+=['--dangerously-skip-permissions'] if mode=='bypassPermissions' else ['--permission-mode',mode]
        if data['model'] and not any(a.split('=')[0]=='--model' for a in options):
            argv+=['--model',data['model']]
    argv+=options
    if source['agent']=='codex' and source.get('hook_trust'):
        # Per-invocation overrides only. Native hash mismatches still require
        # review; never write hooks.state into the user's durable configuration.
        toml=runpy.run_path(str(BIN/'fleet-codex-runtime.py'))['toml_value']
        argv+=['-c','hooks.state='+toml(source['hook_trust'])]
    if source['agent']=='codex':
        argv+=['-c','check_for_update_on_startup=false']
    print('Fleet: restoring saved conversation…',flush=True)
    os.chdir(source['worktree'])
    os.execvpe('bash',argv,env)


def park(w):
    path,data=w.record()
    print('\033[2J\033[H'+data.get('screen',''))
    print('\nFleet · sleeping — enter this worker to resume the saved conversation.',flush=True)
    w.stamp('@sleep_park_ready',path.stem)
    # Blocking on a descriptor, no periodic per-worker polling. tmux focus hooks
    # and explicit wake replace this exact park process under the window lock.
    import signal
    while True: signal.pause()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=('hook','scan','status','sleep','wake','park','launch','keep-awake','allow-sleep','holds-exit','deliver','restore'))
    p.add_argument('--session',default='')
    p.add_argument('window',nargs='?')
    p.add_argument('--dry-run',action='store_true')
    p.add_argument('--record',default='')
    a=p.parse_intermixed_args()
    if a.action=='hook':
        try: hook()
        except (ValueError,KeyError,OSError,subprocess.SubprocessError): pass
        return 0
    if a.action in ('scan','status'):
        mode=os.environ.get('FLEET_SLEEP','observe')
        if mode=='off' and a.action=='scan': return 0
        windows=run(['tmux','-L',a.session,'list-windows','-t',a.session,'-F','#{window_id}']).splitlines()
        cursor=root(a.session)/'cursor.json'
        if a.action=='scan' and cursor.exists():
            last=json.loads(cursor.read_text()).get('window')
            if last in windows:
                index=windows.index(last)+1;windows=windows[index:]+windows[:index]
        deadline=time.monotonic()+45
        for window in windows:
            if time.monotonic()>deadline: break
            try:
                w=Worker(a.session,window)
                if a.action=='scan' and not a.dry_run:
                    save(cursor,{'window':window})
                    if mode=='on':w.drain()
                state=w.opt('@worker_lifecycle')
                if a.action=='status':
                    result={'state':state or 'awake','record':w.opt('@sleep_record')}
                elif state:
                    if not a.dry_run and mode=='on': w.recover()
                    continue
                else: result=w.sleep(dry=a.dry_run or mode!='on')
            except (ValueError,OSError,subprocess.SubprocessError) as exc:
                result={'skip':str(exc)}
            print(json.dumps(dict(session=a.session,window=window,**result),ensure_ascii=False),flush=True)
        return 0
    w=Worker(a.session,a.window or '')
    if a.action=='sleep': print(json.dumps(w.sleep(manual=True,dry=a.dry_run)))
    elif a.action=='holds-exit':
        _,data=w.record()
        return 0 if w.holds_exit(data) else 1
    elif a.action=='wake': w.wake()
    elif a.action=='deliver': w.deliver(sys.stdin.read())
    elif a.action=='restore':
        path=Path(a.record)
        if path.parent!=w.directory: raise ValueError('restore record is outside this fleet')
        data=json.loads(path.read_text())
        if data['session']!=w.session or data['state'] not in ('sleeping','preparing','waking','failed'):
            raise ValueError('record does not describe a retained worker')
        # PID numbers from a dead server/previous boot are never kill authority.
        data.update(window=w.window,pane=w.pane)
        data['source']['pid']=0
        w.stamp('@sleep_record',path)
        w.phase(path,data,'sleeping')
        command=w.command('park')
        w.replaceable()
        w.tm('respawn-pane','-k','-t',w.pane,'-c',data['source']['worktree'],command)
    elif a.action=='park': park(w)
    elif a.action=='launch': launch(w)
    else: w.stamp('@sleep_keep_awake','1' if a.action=='keep-awake' else '')
    return 0


if __name__=='__main__':
    # The daemon timebox uses TERM. Unwind transition locks while leaving the
    # durable preparing/waking phase for reconciliation; SIGKILL cannot unwind.
    def interrupted(signum,frame): raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,interrupted)
    try: sys.exit(main())
    except (ValueError,KeyError,OSError,subprocess.SubprocessError) as exc:
        print('fleet-sleep: '+str(exc),file=sys.stderr); sys.exit(1)
