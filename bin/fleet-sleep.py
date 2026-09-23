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
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
import uuid

BIN = Path(__file__).absolute().parent
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))
CODEX = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
ARGV = runpy.run_path(str(BIN / 'fleet_sleep_argv.py'))
LOOP = runpy.run_path(str(BIN / 'fleet-loop.py'))
MCP = runpy.run_path(str(BIN / 'fleet_sleep_mcp.py'))
PARK = runpy.run_path(str(BIN / 'fleet_sleep_park.py'))


class NotAWorker(ValueError):
    """A window that structurally cannot be a worker (a panel or the hub): the
    scan skips it silently instead of logging a per-tick skip record for it."""


def wake_on_view():
    """FLEET_SLEEP_WAKE=dwell restores the old wake-on-arrival (issue #822's 2s
    navigation dwell, the scan's viewed-window wake, entering mid-sleep). The
    default `confirm` wakes a sleeper only from its page's double press, the
    sidebar menu, or an automatic wake (issue #1050)."""
    return os.environ.get('FLEET_SLEEP_WAKE','confirm').strip()=='dwell'


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


def process_state(pid):
    # (state, start) — the start fingerprint stays comparable across calls.
    if int(pid)<=0: return '',''
    try: fields=run(['ps','-p',str(pid),'-o','stat=','-o','lstart=','-o','comm=']).split(None,1)
    except subprocess.CalledProcessError: return '',''
    return fields[0], (fields[1] if len(fields)>1 else '')


def process_start(pid):
    return process_state(pid)[1]


def source_alive(data):
    # An exited agent stays a zombie until its parent (tmux) reaps it. BSD ps
    # renames the command to <defunct>; Linux procps prints the zombie's
    # lstart/comm exactly like the live process, so the state must be read.
    if not data.get('source_start'): return False
    state,start=process_state(data['source']['pid'])
    return start==data['source_start'] and not state.startswith('Z')


def wake_blocker(data):
    """Why a wake of this record cannot work, or None (issue #1054). The same
    preconditions wake_locked refuses on before it respawns anything: the
    original process confirmed exited, the worktree and exact history present.
    The page offers its button only when this is None."""
    if source_alive(data): return 'the original agent is still running'
    source=data.get('source') or {}
    if not source.get('worktree') or not Path(source['worktree']).is_dir(): return 'the worktree is gone'
    if not source.get('transcript') or not Path(source['transcript']).is_file(): return 'the saved conversation history is gone'
    return None


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
        if len(workers) != 1: raise NotAWorker('requires exactly one worker pane')
        self.pane = workers[0]
        if self.opt('window_name') in ('dash','plan','backlog') or self.opt('@hub') == '1':
            raise NotAWorker('panel/hub is not a worker')
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
                          'FLEET_SLEEP_WAKE_ARM='+os.environ.get('FLEET_SLEEP_WAKE_ARM','3'),
                          'python3',str(BIN/'fleet-sleep.py'),action,'--session',self.session,self.pane])

    def inspect(self):
        return json.loads(run(['bash',BIN/'fleet-transfer.sh','--session',self.session,
                              '--window',self.pane,'--to','codex','--inspect'],timeout=30))

    def visible(self):
        return self.window in self.tm('list-clients','-F','#{window_id}').splitlines()

    def current(self):
        # The session's current window — what the navigation hook fired for —
        # not a client's, so a detached select-window still counts as settling.
        return self.tm('display-message','-p','-t',self.session+':','#{window_id}')==self.window

    def record(self):
        path = Path(self.opt('@sleep_record'))
        if path.parent != self.directory or not path.name.endswith('.json'):
            raise ValueError('missing durable sleep record')
        data = json.loads(path.read_text())
        if data['session'] != self.session or data['pane'] != self.pane or data['window'] != self.window:
            raise ValueError('sleep record belongs to another worker')
        return path, data

    def phase(self, path, data, state, error=''):
        # `since` (issue #1051) is when this sleep began: kept across a re-entry
        # into `sleeping` (restore, a failed wake parked again) so the list's
        # `z <age>` counts the whole nap, and mirrored to @sleep_since so a row
        # reads one window option instead of this record.
        if state=='sleeping':
            if data.get('state')!='sleeping' or not data.get('since'): data['since']=int(time.time())
        else: data.pop('since',None)
        data.update(state=state, updated=time.time(), error=error)
        save(path,data)
        self.stamp('@sleep_since',data.get('since',''))
        if state!='sleeping': self.stamp('@sleep_wake_deferred','')
        self.stamp('@worker_lifecycle',state if state != 'awake' else '')

    def cap_full(self):
        """(n, max) when a session cap is reached, else None (issue #1058). The
        same count every spawn is refused on — fleet-lib.sh's fleet_cap_full, with
        this fleet's conf loaded — so a sleeper waking and a spawn see one number.
        A check that cannot run answers None: an unreadable cap never strands a
        wake the fleet always made before."""
        env=dict(os.environ,FLEET_CONF_DIR=str(self.directory.parents[2]))
        try:
            out=subprocess.run(['bash','-c','. "$1"; fleet_load_conf "$2"; fleet_cap_full "$2"','cap',
                                str(BIN/'fleet-lib.sh'),self.session],env=env,capture_output=True,text=True,timeout=15)
        except (OSError,subprocess.SubprocessError): return None
        parts=out.stdout.split()
        if out.returncode!=0 or len(parts)!=2 or not all(x.isdigit() for x in parts): return None
        return int(parts[0]),int(parts[1])

    @contextmanager
    def slot_lock(self):
        # Check-then-`waking` must be one step across every automatic wake on the
        # machine (the cap is global), or two due loops at N-1 both see a free
        # slot. Held only across the count + the phase stamp, never the resume.
        path=self.directory.parents[2]/'sleep-wake-slot.lock'
        path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        with open(path,'a') as fd:
            deadline=time.monotonic()+30
            while True:
                try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); break
                except BlockingIOError:
                    if time.monotonic()>deadline: raise ValueError('wake slot check is busy; retry') from None
                    time.sleep(.1)
            yield

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

    def cheap_vetoes(self):
        # The window-option gates that need no native inspection: the common
        # blockers, each independently checkable, so a diagnostic can list ALL of
        # them at once (issue #837) while eligible() still raises on the first.
        until = self.opt('@agent_transfer_until')
        return [
            (not self.opt('@worker_lifecycle'), 'already sleeping or transitioning'),
            (self.opt('@sleep_keep_awake') != '1', 'keep awake enabled'),
            (not self.visible(), 'a client is viewing this worker'),
            (self.opt('@claude_state') in ('done','looping'), 'worker is not done'),
            (not self.opt('@handoff_armed') and not self.opt('@agent_transfer_request'), 'handoff/failover is pending'),
            (not until or (until.isdigit() and int(until) <= time.time()), 'transfer is active'),
        ]

    def unmet_reasons(self):
        """Every currently-unmet sleep condition (issue #837). All the cheap
        window-option vetoes, then — only if those are clean — the first deep
        reason from a read-only eligible() probe (its ordered checks presuppose
        one another, so it cannot list past its own first failure)."""
        reasons = [msg for ok, msg in self.cheap_vetoes() if not ok]
        if not reasons:
            try:
                with lock(self.lockfile):
                    self.eligible()
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                reasons.append(str(exc))
        return reasons

    def eligible(self, manual=False):
        for ok, msg in self.cheap_vetoes():
            if not ok: raise ValueError(msg)
        source = self.inspect()
        if source['agent']=='codex' and not source.get('codex_identity',{}).get('remote','').startswith('unix:///'):
            raise ValueError('legacy Codex has no private endpoint; exact native rebind is required before sleep')
        source['restart_options']=source_options(source)
        self.check_quota_wait(source)
        source['sleep_loop']=LOOP['sleep_snapshot'](source)
        if self.opt('@claude_state')=='looping' and not source['sleep_loop']:
            raise ValueError('looping worker has no verified loop schedule')
        if source['sleep_loop'] and source['sleep_loop']['record']['status']=='waiting-quota':
            policy=runpy.run_path(str(BIN/'.fleet-failover.py'))
            account=policy['source_account'](source,policy['ACCOUNT']['inventory']())
            source['sleep_account_key']=account['key']
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
                quiet_native_children(client,source['session_id'])
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
        quiet_processes(source,evidence.get('config_home'))
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
        if not path.is_file():
            # No request at this exact identity: the marker outlived its episode.
            # That is the normal shape after a bound migration (the window's
            # pid/session changed) and after a stale preparing/selected marker
            # whose request was cleaned (#755/#809). The caller holds the same
            # fleet lock as the quota controller, so inspect the whole journal by
            # window/thread and apply the same rule as an exact match: a completed
            # episode (bound/cancelled/recovered) or a soft, unstarted proactive
            # wait never blocks sleep; an in-flight cutover or a hard failure does.
            for candidate in self.quota_directory.glob('*/request.json'):
                request=json.loads(candidate.read_text())
                owner=request.get('source',{})
                if (owner.get('session')!=self.session
                        or (owner.get('window')!=self.window and owner.get('session_id')!=source['session_id'])):
                    continue
                state=request.get('state')
                if state in ('bound','cancelled','recovered'): continue
                if state in ('waiting','waiting-quota','waiting-evidence') and request.get('hard') is False: continue
                raise ValueError('quota marker has an unresolved request for this worker')
            source['stale_quota_marker']=self.opt('@quota_failover')
            return
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
                if (self.source_key(current) != self.source_key(source) or current_evidence != evidence
                        or current.get('sleep_loop') != source.get('sleep_loop')
                        or current.get('sleep_mcp') != source.get('sleep_mcp')):
                    raise ValueError('source changed during preparation')
                self.stamp('@sleep_record',path)
                self.phase(path,data,'preparing')
                self.tm('set-option','-p','-t',self.pane,'remain-on-exit','on')
                # Disable input while issuing exit; do not consume user keystrokes
                # in a shell. Native programmatic deliveries use this same lock.
                self.tm('select-pane','-d','-t',self.pane)
                try:
                    LOOP['sleep_suspend'](source.get('sleep_loop'),path)
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
                    if wake_on_view() and self.visible(): self.wake_locked(path,data)
                    return {'state':data['state'],'record':str(path)}
                except Exception as exc:
                    self.phase(path,data,'failed',str(exc))
                    if source_alive(data):
                        self.resume_loop(path,data,source,rollback=True)
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

    def wake_locked(self,path,data,over_cap=True):
        """Resume the saved conversation. True once awake, False when an automatic
        wake (over_cap=False: a due loop, a message) found the fleet at its session
        limit (issue #1058) — it stamps @sleep_wake_deferred=cap and the next scan
        retries. The operator's own wake passes over_cap=True and always goes."""
        if data['state']=='awake': return True
        if source_alive(data):
            raise ValueError('original process is still alive; inspect the failed exit')
        self.replaceable()
        source=data['source']
        if not Path(source['worktree']).is_dir() or not Path(source['transcript']).is_file():
            raise ValueError('worktree or exact history is missing')
        if over_cap: self.phase(path,data,'waking')
        else:
            with self.slot_lock():
                if self.cap_full():
                    if self.opt('@sleep_wake_deferred')!='cap': self.stamp('@sleep_wake_deferred','cap')
                    return False
                self.phase(path,data,'waking')
        self.tm('select-pane','-d','-t',self.pane)
        data['resume_count']+=1
        save(path,data)
        command=self.command('launch')
        self.tm('respawn-pane','-k','-t',self.pane,'-c',source['worktree'],command)
        started=time.monotonic();parked=False
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
                        if not self.verify_resumed_services(data,new):
                            time.sleep(.25)
                            continue
                        data['wake_seconds']=round(time.monotonic()-started,3)
                        data['resumed_pid']=new['pid']
                        self.resume_loop(path,data,new)
                        # Quota reconciliation skips waking workers. This marker
                        # belongs to the retired PID; the next tick re-evaluates
                        # the resumed owner instead of inheriting its old wait.
                        self.stamp('@quota_failover','')
                        self.stamp('@quota_stuck','')
                        self.stamp('@sleep_evidence','')
                        self.stamp('@sleep_woke_at',time.time())
                        self.phase(path,data,'awake')
                        return True
                except (subprocess.SubprocessError,OSError): pass
                if self.opt('pane_dead')=='1': break
                time.sleep(.25)
            raise ValueError('resume is not ready; inspect the retained worker and retry')
        except Exception as exc:
            self.phase(path,data,'failed',str(exc))
            parked=self.repark_failed(path,data)
            raise
        finally:
            self.tm('select-pane','-e','-t',self.pane)
            if not parked: self.tm('set-option','-p','-t',self.pane,'remain-on-exit',data['remain'])

    def repark_failed(self,path,data):
        """A failed wake whose launcher already exited (a missing tool, a
        refused setting) leaves a dead pane: put the page back so it shows why
        and offers Retry (issue #1054). A pane still running anything — the
        resumed agent stuck on a dialog, its services — is never replaced."""
        try:
            if self.opt('pane_dead')!='1': return False
            # What the launcher printed before it died is the reason; tmux's
            # own "Pane is dead" line is not.
            said=[l.strip() for l in self.tm('capture-pane','-p','-t',self.pane).splitlines()
                  if l.strip() and not l.lstrip().startswith(('Pane is dead','Fleet: restoring'))]
            if said and 'launcher said:' not in data.get('error',''):
                data['error']=(data.get('error') or 'wake failed')+' · launcher said: '+' / '.join(said[-2:])
                save(path,data)
            self.tm('set-option','-p','-t',self.pane,'remain-on-exit','on')
            self.tm('respawn-pane','-k','-t',self.pane,'-c',data['source']['worktree'],self.command('park'))
            return True
        except (subprocess.SubprocessError,OSError,KeyError): return False

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

    def wake(self,dwell=0,nav=False,over_cap=False):
        # --nav marks the tmux navigation/attach hooks: under the default
        # FLEET_SLEEP_WAKE=confirm arriving on a sleeper only shows its page.
        if nav and not wake_on_view(): return
        if dwell>0:
            # Dwell threshold (issue #822): the navigation hooks fire for every
            # window the operator passes — the sidebar's ↑↓ follow, prefix n/p
            # scanning — and a wake resumes the agent and its MCP children.
            # Wait, then require the window to still be current: every run for
            # a passed window gives up here; only the one settled on wakes.
            time.sleep(dwell)
            if not self.current(): return
        with lock(self.lockfile):
            if not self.opt('@worker_lifecycle'): return
            path,data=self.record()
            # A navigation wake (FLEET_SLEEP_WAKE=dwell) is the operator arriving:
            # it goes like --over-cap. A bare CLI wake at a full fleet refuses
            # rather than defer — nothing would retry it (issue #1058).
            full=None if over_cap or nav or data['state']=='awake' else self.cap_full()
            if full: raise ValueError('fleet full %d/%d — pass --over-cap to wake anyway'%full)
            self.wake_locked(path,data)

    def resume_loop(self,path,data,source,rollback=False):
        snapshot=data['source'].get('sleep_loop')
        if not snapshot:return
        LOOP['sleep_resume'](snapshot,path,source,self.opt('pane_pid'),rollback=rollback)
        if not rollback:self.stamp('@claude_state','done')

    def verify_resumed_services(self,data,new):
        source=data['source']
        if not source.get('sleep_mcp'):return True
        if source['agent']=='claude':
            # No runtime status RPC: the resumed agent is awake once every saved
            # server runs again under it from an unchanged configuration.
            inventory=MCP['claude_inventory'](ARGV['process_argv'](new['pid']),new['worktree'],data['evidence'].get('config_home'))
            return MCP['verify_resume'](source,inventory,(TRANSFER['process_rows'](),new['pid'],ARGV['process_argv'],ARGV['process_executable']))
        client=RPC(new['codex_identity'].get('remote',''),timeout=5)
        try:return MCP['verify_resume'](source,MCP['inventory'](client))
        finally:client.close()

    def scheduled_wake(self,path,data):
        snapshot=data['source'].get('sleep_loop')
        if not snapshot:return False
        LOOP['sleep_retained'](snapshot,path)
        record=snapshot['record']
        if record['status']=='active':
            return time.time()>=record['schedule']['next_run_at']
        # Quota waiting is not a due timer. Only a fresh usable subscription
        # wakes it; old readings/reset timestamps alone cannot cause churn.
        account=runpy.run_path(str(BIN/'.fleet-account.py'))
        inventory=account['inventory']()
        key=data['source'].get('sleep_account_key')
        if any(a['key']==key and account['eligible'](a) for a in inventory['accounts']):return True
        if os.environ.get('FLEET_FAILOVER','0')!='1':return False
        allowed=os.environ.get('FLEET_FAILOVER_AGENTS','claude,codex').split(',')
        return bool(account['choose'](inventory,data['source']['agent'],[key],allowed=allowed)['target'])

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
                path,data=self.record()
                if not self.wake_locked(path,data,over_cap=False):
                    # Already saved above: the scan's drain delivers it once a slot frees.
                    print('fleet-sleep: queued — fleet at its session limit; delivers when a slot frees',file=sys.stderr)
                    return
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
            # Deferred at the session limit (issue #1058): the rest wait with it.
            if self.opt('@worker_lifecycle')=='sleeping' and self.opt('@sleep_wake_deferred'): break

    def recover(self):
        with lock(self.lockfile):
            path,data=self.record()
            if data['state']=='preparing':
                if source_alive(data):
                    self.resume_loop(path,data,data['source'],rollback=True)
                    self.phase(path,data,'failed','sleep controller stopped before confirming exit')
                    self.tm('select-pane','-e','-t',self.pane)
                    return
                self.replaceable()
                self.phase(path,data,'sleeping')
                command=self.command('park')
                # The park process takes the pane's input itself and swallows it.
                self.tm('respawn-pane','-k','-t',self.pane,'-c',data['source']['worktree'],command)
            if data['state'] in ('waking','failed'):
                try:
                    if data['source']['agent']=='codex': self.bind_resumed_codex(data['source'])
                    source=self.inspect()
                    if (source['session_id']==data['source']['session_id']
                            and source['agent']==data['source']['agent']
                            and (source['agent']!='codex' or source['home']==data['source']['home'])
                            and INPUT['snapshot'](self.session,self.pane,agent=source['agent']).get('state')=='empty'):
                        if not self.verify_resumed_services(data,source):return
                        if source['pid']!=data['source']['pid']:
                            self.stamp('@quota_failover','')
                            self.stamp('@quota_stuck','')
                        self.resume_loop(path,data,source,rollback=source['pid']==data['source']['pid'])
                        self.stamp('@sleep_evidence','')
                        self.stamp('@sleep_woke_at',time.time())
                        self.phase(path,data,'awake')
                        self.tm('select-pane','-e','-t',self.pane)
                        self.tm('set-option','-p','-t',self.pane,'remain-on-exit',data['remain'])
                except (ValueError,OSError,subprocess.SubprocessError): pass
            # A wake that died without reaching its own failure path (a killed
            # controller, a launcher exiting late) is re-parked here.
            if data['state']=='failed': self.repark_failed(path,data)
            if data['state']=='sleeping':
                if wake_on_view() and self.visible(): self.wake_locked(path,data)
                elif self.scheduled_wake(path,data): self.wake_locked(path,data,over_cap=False)
                elif self.opt('@sleep_wake_deferred') and not any(self.inbox().glob('*.json')):
                    self.stamp('@sleep_wake_deferred','')   # nothing waits for a slot any more


def quiet_native_children(client,session_id):
    loaded=client.call('thread/loaded/list',{})
    if loaded.get('nextCursor') or not isinstance(loaded.get('data'),list):
        raise ValueError('loaded thread inventory is incomplete')
    for sid in loaded['data']:
        if sid==session_id:continue
        child=client.call('thread/read',{'threadId':sid,'includeTurns':False})['thread']
        if child.get('status',{}).get('type')!='idle':
            raise ValueError('another thread/subagent is active or unknown')
        goal=client.call('thread/goal/get',{'threadId':sid}).get('goal')
        if goal and goal.get('status')!='complete':
            raise ValueError('another thread/subagent has an unfinished goal')


def quiet_processes(source,config_home=None,background=None,strict=True):
    # background=None is hibernation's contract: any unverified child vetoes.
    # A list collects those pids instead (still walking their descendants) —
    # failover's hard-wall grace passes one (#871), and so does child_busy (#864);
    # every other veto still raises. strict=False is child_busy's question — "is
    # the agent still running WORK?" — asked from inside its own Stop hook: the
    # MCP restartability contract is dropped (see fleet_sleep_mcp.classify), the
    # caller's own ancestry (the hook chain) is never work, and under Claude only
    # a Bash-tool shell counts — concurrent Stop hooks and caffeinate are Claude's
    # own per-turn machinery, not a job the worker left running.
    rows=TRANSFER['process_rows']()
    pending=[source['pid']]; seen=set()
    lenient={} if strict else {'strict':False}   # hibernation's call shape unchanged
    if not strict:
        pid=os.getpid()
        while pid in rows and pid not in seen and pid!=source['pid']:
            seen.add(pid);pid=rows[pid][0]
    mcp_pids=set()
    # Non-strict Claude needs no inventory: only a Bash-tool shell counts there,
    # and no MCP server is one — so a missing/odd ~/.claude.json cannot blind it.
    if strict and source['agent']=='claude' and any(pp==source['pid'] for pp,_ in rows.values()):
        # Claude starts its stdio MCP servers as direct children and has no RPC
        # to enumerate them; the effective config is rebuilt from its own argv
        # and store (issue #784). Nothing else beneath Claude is infrastructure.
        inventory=MCP['claude_inventory'](ARGV['process_argv'](source['pid']),source['worktree'],config_home)
        mcp_pids=MCP['classify'](source,inventory,rows,source['pid'],ARGV['process_argv'],ARGV['process_executable'],**lenient)
    while pending:
        parent=pending.pop()
        if parent in seen: continue
        seen.add(parent)
        for pid,(pp,comm) in rows.items():
            if pp!=parent or pid==parent or pid in seen: continue
            if (not strict and source['agent']=='claude' and parent==source['pid']
                    and pid not in mcp_pids and not tool_shell(pid)): continue
            pending.append(pid)
            if source['agent']=='claude':
                if pid in mcp_pids: continue
                if background is not None: background.append(pid); continue
                try:name=ARGV['process_executable'](pid).name
                except OSError:name='unknown'
                raise ValueError('Claude owns unverified background/tool process: pid=%s executable=%s' % (pid,name))
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
                if native and 'app-server' in argv:
                    children=[p for p,(pp,c) in rows.items() if pp==pid and c!='codex-code-mode-host']
                    if children:
                        client=RPC(remote,timeout=5)
                        try:mcp_pids.update(MCP['classify'](source,MCP['inventory'](client),rows,pid,ARGV['process_argv'],ARGV['process_executable'],**lenient))
                        finally:client.close()
                continue
            if pid in mcp_pids:continue
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
            if background is not None: background.append(pid); continue
            try:name=ARGV['process_executable'](pid).name
            except OSError:name='unknown'
            raise ValueError('Codex owns unverified background/tool process: pid=%s executable=%s' % (pid,name))


def tool_shell(pid):
    # Claude's Bash tool (foreground, run_in_background, Monitor) runs every
    # command as `<shell> -c source <config>/shell-snapshots/snapshot-…`; no hook,
    # MCP server or helper Claude starts on its own sources one.
    try:return any('/shell-snapshots/snapshot-' in arg for arg in ARGV['process_argv'](pid))
    except OSError:return False


def child_busy(session,target,pid=0):
    """The pids a worker's agent still owns beyond its MCP services (issue #864).

    A child whose turn ended while a run_in_background test or a PR-gate waiter
    (`tools/await-pr.sh`) still runs under it has not STOPPED — it is waiting, and
    its parent must not hear otherwise. Same walk hibernation vetoes on, minus the
    restartability contract: an uncontracted MCP server is not work in progress.
    A known Claude pid (fleet_pane_claude_pid) skips the native inspect.
    """
    w=Worker(session,target)
    if pid:
        source=dict(agent='claude',pid=pid,codex_identity={},
                    worktree=w.opt('@worktree') or w.opt('pane_current_path'))
    else:
        source=w.inspect()
    try:config_home=json.loads(w.opt('@sleep_evidence') or '{}').get('config_home')
    except ValueError:config_home=None
    background=[]
    quiet_processes(source,config_home or os.environ.get('CLAUDE_CONFIG_DIR'),background=background,strict=False)
    return background


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
    """The sleeping page (issues #1049/#1050). Blocks on its tty and signals —
    no timer except the arm countdown (EPIC #1048 rule 4). It owns the pane's
    input and discards every byte that is not a press of its one button, so
    nothing typed here ever reaches the resumed agent (rule 3)."""
    path,data=w.record()
    try: arm=max(float(os.environ.get('FLEET_SLEEP_WAKE_ARM') or 3),1.0)
    except ValueError: arm=3.0
    button=PARK['WakeButton'](arm,'retry' if data.get('state')=='failed' else 'wake')
    # SIGWINCH only flags, via the wakeup pipe: select() returns and the loop
    # redraws — never re-entrant (PEP 475 would otherwise just resume select).
    rd,wr=os.pipe()
    for fd in (rd,wr): os.set_blocking(fd,False)
    signal.set_wakeup_fd(wr)
    signal.signal(signal.SIGWINCH,lambda *_:None)
    for sig in (signal.SIGINT,signal.SIGQUIT,signal.SIGTSTP): signal.signal(sig,signal.SIG_IGN)
    signal.signal(signal.SIGHUP,lambda *_:sys.exit(0))
    saved=None
    if os.isatty(0):
        saved=termios.tcgetattr(0); mode=termios.tcgetattr(0)
        mode[0]&=~(termios.IXON|termios.ICRNL)
        mode[3]&=~(termios.ECHO|termios.ICANON|termios.ISIG|termios.IEXTEN)
        mode[6][termios.VMIN],mode[6][termios.VTIME]=1,0
        termios.tcsetattr(0,termios.TCSANOW,mode)
    mouse=lambda on:sys.stdout.write('\033[?1000'+('h' if on else 'l')+'\033[?1006'+('h' if on else 'l'))
    facts,rows,fds,full,cost,blocker=None,set(),[rd,0],None,False,None
    try:
        mouse(True)
        redraw=True
        while True:
            now=time.monotonic()
            if button.expire(now): redraw=True
            if redraw:
                redraw=False
                if facts is None:
                    try: path,data=w.record()
                    except (ValueError,KeyError,OSError): pass
                    facts=park_facts(w,data)
                    blocker=wake_blocker(data) if button.state!='waking' else None
                footer=PARK['blocked_lines'](blocker) if blocker else button.lines(now)
                if button.state=='armed' and not blocker:
                    if cost: footer=[PARK['DIM']+' '+cost+' '+PARK['RESET']]+footer
                    if full: footer=[PARK['cap_line'](*full)]+footer
                frame=park_frame(w,data,footer,facts)
                n=frame.count('\n')+1
                rows=set(range(n-len(footer)+1,n+1))
                sys.stdout.write('\033[2J\033[H'+frame); sys.stdout.flush()
                if w.opt('@sleep_park_ready')!=path.stem:
                    w.stamp('@sleep_park_ready',path.stem)
                    # sleep() closed the input gate before /exit; the page
                    # reopens it only for itself.
                    w.tm('select-pane','-e','-t',w.pane)
            try: ready=select.select(fds,[],[],button.timeout(time.monotonic()))[0]
            except InterruptedError: ready=[rd]
            if not ready: redraw=True
            if rd in ready:
                try:
                    while os.read(rd,64): pass
                except BlockingIOError: pass
                facts,redraw=None,True
            if 0 in ready:
                chunk=os.read(0,4096)
                if not chunk: fds.remove(0); continue
                # A discarded key changes nothing on the page: no redraw for it.
                for _ in range(PARK['presses'](chunk,rows)):
                    if blocker:
                        # No button (issue #1054). A press re-reads the facts,
                        # so a cause fixed meanwhile brings the button back.
                        facts,redraw=None,True
                        break
                    redraw=True
                    was=button.state
                    if button.press(time.monotonic()):
                        # Re-checked at the press, not only at the last draw:
                        # a wake that cannot start would leave "waking…" up.
                        try: blocker=wake_blocker(w.record()[1])
                        except (ValueError,KeyError,OSError) as exc: blocker=str(exc)
                        if blocker:
                            button.state,facts='rest',None
                            break
                        mouse(False); sys.stdout.flush()
                        park_wake(w)
                    elif was!='armed' and button.state=='armed':
                        # Read once per arm, not polled: the second press wakes
                        # anyway (over the limit by one), so this only informs.
                        full=w.cap_full()
                        # The records only change when some worker sleeps or
                        # wakes; one read for this page is enough (#1053).
                        if cost is False: cost=park_cost(w,data)
    finally:
        try:
            mouse(False); sys.stdout.flush()
            if saved is not None: termios.tcsetattr(0,termios.TCSANOW,saved)
        except (OSError,ValueError): pass


def park_wake(w):
    # Detached (EPIC #1048 rule 6): wake_locked respawns this pane, killing us.
    # fleet-sleep.sh loads the fleet conf; a sandbox without it runs the .py.
    sh=BIN/'fleet-sleep.sh'
    # --over-cap: the operator's own wake always goes, one over at a full fleet (#1058).
    command=shlex.join(['bash',str(sh),'wake',w.session,w.window,'--over-cap']) if sh.exists() else w.command('wake')+' --over-cap'
    w.tm('run-shell','-b',command+' >/dev/null 2>&1')


def park_cost(w,data):
    records=[]
    for path in w.directory.glob('*.json'):
        try: records.append(json.loads(path.read_text()))
        except (OSError,ValueError): pass
    return PARK['wake_cost'](data,[r for r in records if isinstance(r,dict)])


def park_facts(w,data):
    opts={}
    for key,name in (('issue','@issue'),('title','window_name'),('repo','@repo'),('prci','@prci'),('reap_key','@reap_key')):
        try: opts[key]=w.opt(name)
        except subprocess.SubprocessError: pass
    return PARK['gather'](data,opts)


def park_frame(w,data,footer_lines=None,facts=None):
    if facts is None: facts=park_facts(w,data)
    try: cols,rows=os.get_terminal_size(sys.stdout.fileno())
    except OSError: cols,rows=int(w.opt('pane_width')),int(w.opt('pane_height'))
    return PARK['render_park'](data,facts,cols,rows,footer_lines)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=('hook','scan','status','sleep','wake','park','launch','keep-awake','allow-sleep','holds-exit','deliver','restore','why','busy'))
    p.add_argument('--session',default='')
    p.add_argument('window',nargs='?')
    p.add_argument('--dry-run',action='store_true')
    p.add_argument('--record',default='')
    p.add_argument('--pid',type=int,default=0,help='busy: the Claude pid already resolved for this pane')
    p.add_argument('--dwell',type=float,default=0,help='wake only if the window is still current after this many seconds')
    p.add_argument('--nav',action='store_true',help='wake: from a navigation/attach hook; a no-op unless FLEET_SLEEP_WAKE=dwell')
    p.add_argument('--over-cap',action='store_true',help='wake: the operator\'s own wake — goes even at the session limit (issue #1058)')
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
            except NotAWorker:
                continue
            except (ValueError,OSError,subprocess.SubprocessError) as exc:
                reason=str(exc)
                if isinstance(exc,subprocess.CalledProcessError) and exc.stderr:
                    reason=exc.stderr.strip()[-400:]
                result={'skip':reason}
            # A timestamp on every record: the log had none, so the last analysis
            # had to correlate by hand (#755/#809 follow-up). Emit-only; not state.
            record=dict(session=a.session,window=window,at=time.strftime('%Y-%m-%dT%H:%M:%S'),**result)
            print(json.dumps(record,ensure_ascii=False),flush=True)
        return 0
    if a.action=='busy':
        # Exit 0 = busy (prints the pids), 1 = idle, 2 = cannot tell (fleet-sleep:
        # on stderr). A caller that must not guess treats 2 as idle.
        pids=child_busy(a.session,a.window or '',a.pid)
        if not pids: return 1
        print(' '.join(map(str,pids)))
        return 0
    w=Worker(a.session,a.window or '')
    if a.action=='why': print(json.dumps({'window':w.window,'reasons':w.unmet_reasons()},ensure_ascii=False))
    elif a.action=='sleep': print(json.dumps(w.sleep(manual=True,dry=a.dry_run)))
    elif a.action=='holds-exit':
        _,data=w.record()
        return 0 if w.holds_exit(data) else 1
    elif a.action=='wake': w.wake(dwell=a.dwell,nav=a.nav,over_cap=a.over_cap)
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
        print('fleet-sleep: '+str(exc),file=sys.stderr); sys.exit(2 if 'busy' in sys.argv[1:2] else 1)
