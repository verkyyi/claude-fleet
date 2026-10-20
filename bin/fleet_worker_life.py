#!/usr/bin/env python3
"""A worker window's life: delivery, busy and the reap hold.

Moved out of fleet-sleep.py (T545, EPIC T542 C7); hibernation itself was
deleted (T548, C8), so nothing here waits for or wakes a sleeper:

  hook        the Stop hook's evidence (@sleep_evidence) — the busy reader's config home
  busy        exit 0 = busy (prints the pids), 1 = idle, 2 = cannot tell
  deliver     the message on stdin, typed into the live agent
  hold/release  the reap hold (@reap_hold)

holds-exit · dispose · restore answered for a sleep record; none is written
any more, so for one version they exit as «nothing held» (1 / 0 / 0).
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).absolute().parent


class LazyModule(dict):
    def __init__(self, filename):
        super().__init__()
        self.filename = filename
        self.loaded = False

    def load(self):
        if not self.loaded:
            self.update(runpy.run_path(str(BIN / self.filename)))
            self.loaded = True

    def __missing__(self, key):
        self.load()
        if key not in self:
            raise KeyError(key)
        return self[key]

    def copy(self):
        self.load()
        return super().copy()


TRANSFER = LazyModule('.fleet-transfer.py')
INPUT = LazyModule('fleet-input.py')
CODEX = LazyModule('fleet-codex-session.py')
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
ARGV = LazyModule('fleet_agent_argv.py')
MCP = LazyModule('fleet_agent_mcp.py')


class NotAWorker(ValueError):
    """A window that structurally cannot be a worker (a panel or the hub): the
    scan skips it silently instead of logging a per-tick skip record for it."""


def run(argv, **kwargs):
    # errors='replace' (issue #3129): a child's stderr may hold raw bytes it
    # echoed (macOS awk's «illegal byte sequence»), never a reason to fail.
    return subprocess.check_output([str(x) for x in argv], text=True, errors='replace',
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
        except BlockingIOError: raise ValueError('another delivery owns this worker') from None
        yield


# bin/fleet-lib.sh's FLEET_SESSION_FMT: the fleet's own name from any window or
# pane, never a grouped view session's (issue #1489).
SESSION_FMT='#{?#{session_group},#{session_group},#{session_name}}'


class Worker:
    def __init__(self, session, target):
        self.session = session
        identity = self.tm('display-message', '-p', '-t', target,
                           '#{window_id}|' + SESSION_FMT).split('|', 1)
        if len(identity) != 2: raise ValueError('unknown window')
        self.window, owner_session = identity
        if not re.fullmatch(r'@\d+', self.window): raise ValueError('unknown window')
        # The fleet a window belongs to is its session's GROUP when it has one
        # (issue #2622): with a client on a grouped view session
        # (`<fleet>@view-<id>`) tmux answers a bare #{session_name} with the
        # view's name, and every worker read `wrong fleet` — nothing slept.
        if owner_session != session: raise ValueError('wrong fleet')
        panes = self.tm('list-panes', '-t', self.window, '-F', '#{pane_id} #{@sidebar} #{@dash}').splitlines()
        workers = [p.split()[0] for p in panes if len(p.split()) == 1]
        if len(workers) != 1: raise NotAWorker('requires exactly one worker pane')
        self.pane = workers[0]
        metadata = self.tm('display-message', '-p', '-t', self.pane,
                           '#{==:#{@hub},1}|#{@issue}|#{@raw}|#{window_name}').split('|', 3)
        if len(metadata) != 4: raise ValueError('worker metadata unavailable')
        hub, issue, raw, name = metadata
        if name in ('dash','plan','backlog','home') or hub == '1':
            raise NotAWorker('panel/hub is not a worker')
        if not issue.isdigit() and raw != '1':
            raise ValueError('not an issue or scratch worker')
        self.directory = root(session)
        self.lockfile = self.directory / ('window-' + self.window[1:] + '.lock')

    def tm(self, *args):
        return run(['tmux', '-L', self.session, *args], timeout=5)

    def opt(self, name):
        return self.tm('display-message','-p','-t',getattr(self,'pane',self.window),'#{'+name+'}')

    def stamp(self, name, value):
        self.tm('set-option','-w','-t',self.window,name,str(value))

    def inspect(self):
        return json.loads(run(['bash',BIN/'fleet-transfer.sh','--session',self.session,
                              '--window',self.pane,'--to','codex','--inspect'],timeout=30))

    def deliver(self,text):
        if not text.strip(): raise ValueError('empty message')
        # Record before waking. A timeout leaves reviewable pending data, never a
        # successful acknowledgement or an automatic duplicate of uncertain work.
        queue=self.inbox()
        token=hashlib.sha256(text.encode()).hexdigest()
        msgpath=queue/(token+'.json')
        with lock(self.lockfile):
            expected=self.inspect()['session_id']
            message=json.loads(msgpath.read_text()) if msgpath.exists() else dict(text=text,state='pending',created=time.time(),session_id=expected)
            if message['state']=='uncertain': raise ValueError('previous delivery is uncertain; inspect '+str(msgpath))
            save(msgpath,message)
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
        return self.directory/('inbox-window-'+self.window[1:])


def hook():
    if not os.environ.get('TMUX') or not os.environ.get('TMUX_PANE'): return
    if os.environ.get('CLAUDE_CODE_ENTRYPOINT','cli')!='cli': return
    payload=json.load(sys.stdin)
    if payload.get('hook_event_name')!='Stop': return
    pane=os.environ['TMUX_PANE']
    session=run(['tmux','display-message','-p','-t',pane,SESSION_FMT])
    w=Worker(session,pane)
    source=w.inspect()
    if payload.get('session_id')!=source['session_id']: return
    evidence={k:payload.get(k) for k in ('session_id','background_tasks','session_crons','stop_hook_active','permission_mode')}
    evidence.update(at=time.time(),pid=source['pid'],pane=pane,
                    config_home=os.environ.get('CLAUDE_CONFIG_DIR'),
                    accounts_dir=os.environ.get('FLEET_ACCOUNTS_DIR'))
    w.stamp('@sleep_evidence',json.dumps(evidence,separators=(',',':')))


def quiet_native_children(client,session_id):
    loaded=client.call('thread/loaded/list',{})
    if loaded.get('nextCursor') or not isinstance(loaded.get('data'),list):
        raise ValueError('loaded thread inventory is incomplete')
    if session_id not in loaded['data']:
        raise ValueError('native session is no longer loaded')
    for sid in loaded['data']:
        if sid==session_id:continue
        child=client.call('thread/read',{'threadId':sid,'includeTurns':False})['thread']
        if child.get('status',{}).get('type')!='idle':
            raise ValueError('another thread/subagent is active or unknown')
        goal=client.call('thread/goal/get',{'threadId':sid}).get('goal')
        if goal and goal.get('status')!='complete':
            raise ValueError('another thread/subagent has an unfinished goal')


def codex_idle_turn(client, source):
    """The existing sleep native-idle proof, also used by the busy reader.

    This is a synchronous native read, not a cached runtime/task snapshot. The
    shared observation contract (#4434) remains the delivery controller's owner.
    """
    sid = source['session_id']
    thread = client.call('thread/read', {'threadId': sid, 'includeTurns': True})['thread']
    if thread.get('id') != sid or thread.get('status', {}).get('type') != 'idle':
        raise ValueError('Codex is not natively idle')
    if (not thread.get('cwd') or not thread.get('path')
            or Path(thread['cwd']).resolve() != Path(source['worktree']).resolve()
            or Path(thread['path']).resolve() != Path(source['transcript']).resolve()):
        raise ValueError('Codex native worktree/history does not match this worker')
    turns = thread.get('turns') or []
    if not turns or turns[-1].get('status') != 'completed':
        raise ValueError('no completed Codex turn')
    last = turns[-1]
    if any(item.get('status') not in (None, 'completed', 'failed', 'declined', 'interrupted')
           for item in last.get('items', [])):
        raise ValueError('Codex tool is still active or unknown')
    goal = client.call('thread/goal/get', {'threadId': sid}).get('goal')
    if goal and goal.get('status') != 'complete':
        raise ValueError('Codex goal is unfinished')
    quiet_native_children(client, sid)
    return last


def codex_busy_binding(w, source):
    # Reuse C3's kernel birth/ownership proof; no new identity store or adapter.
    from fleet_launch import process, inspect
    data = source['codex_identity']
    if (data.get('owner') != str(source['pid']) or data.get('session_id') != source['session_id']
            or data.get('home') != source['home'] or not data.get('remote', '').startswith('unix:///')):
        raise ValueError('no current Codex native binding')
    launch = w.opt('@launch')
    receipt = inspect(json.loads(launch), w.pane, w.session) if launch else None
    if receipt and receipt['native_session'] != source['session_id']:
        raise ValueError('Codex launch belongs to another native session')
    return (tuple(source[k] for k in ('pid', 'session_id', 'home', 'worktree', 'transcript')),
            data.get('remote'), process(source['pid']), receipt)


def quiet_processes(source,config_home=None,background=None,strict=True,remounted=None):
    # background=None is hibernation's contract: any unverified child vetoes.
    # A list collects those pids instead (still walking their descendants) —
    # failover's hard-wall grace passes one (#871), and so does child_busy (#864);
    # every other veto still raises. strict=False is child_busy's question — "is
    # the agent still running WORK?" — asked from inside its own Stop hook: the
    # MCP restartability contract is dropped (see fleet_agent_mcp.classify), the
    # caller's own ancestry (the hook chain) is never work, and under Claude only
    # a Bash-tool shell counts — concurrent Stop hooks and caffeinate are Claude's
    # own per-turn machinery, not a job the worker left running.
    rows=TRANSFER['process_rows']()
    pending=[source['pid']]; seen=set()
    lenient={} if strict else {'strict':False}   # hibernation's call shape unchanged
    if remounted:
        # The continuation's proven remount (issue #4775, fleet_agent_mcp.classify);
        # strict only, and only Codex reports the services it names.
        if not strict or source['agent']!='codex': raise ValueError('remounted MCP services need a strict Codex walk')
        lenient['remounted']=frozenset(remounted)
    if not strict:
        pid=os.getpid()
        while pid in rows and pid not in seen and pid!=source['pid']:
            seen.add(pid);pid=rows[pid][0]
    mcp_pids=set()
    helpers=set()
    helper_dir=None
    if not strict and source['agent']=='codex':
        root_argv=ARGV['process_argv'](source['pid'])
        if len(root_argv)>1 and Path(root_argv[1]).name=='fleet-codex.sh':
            helper_dir=Path(root_argv[1]).resolve().parent
    # Non-strict Claude needs no inventory: only a Bash-tool shell counts there,
    # and no MCP server is one — so a missing/odd ~/.claude.json cannot blind it.
    if strict and source['agent']=='claude' and any(pp==source['pid'] for pp,_ in rows.values()):
        # Claude starts its stdio MCP servers as direct children and has no RPC
        # to enumerate them; the effective config is rebuilt from its own argv
        # and store (issue #784). Nothing else beneath Claude is infrastructure.
        inventory=MCP['claude_inventory'](ARGV['process_argv'](source['pid']),source['worktree'],config_home)
        mcp_pids=MCP['classify'](source,inventory,rows,source['pid'],ARGV['process_argv'],ARGV['process_executable'],**lenient)
    if source['agent']=='codex' and rows.get(source['pid'],(0,''))[1] in ('codex','codex-real'):
        # A bound native server can itself be the root, rather than a child of
        # the shell launcher. It needs the same inventory as a nested server.
        argv=ARGV['process_argv'](source['pid'])
        remote=source['codex_identity'].get('remote','')
        if 'app-server' in argv and '--listen' in argv:
            if not remote or argv[argv.index('--listen')+1:argv.index('--listen')+2]!=[remote]:
                raise ValueError('bound Codex server owns a different endpoint')
            client=RPC(remote,timeout=5)
            # A measured Codex release only: its MCP children's environment is what
            # shell_exec_argv can account for (issue #4537); Claude's call passes none.
            try:mcp_pids.update(MCP['classify'](source,MCP['inventory'](client),rows,source['pid'],ARGV['process_argv'],ARGV['process_executable'],env_reader=MCP['shell_exec_reader'](client,ARGV['process_env']),**lenient))
            finally:client.close()
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
                        try:mcp_pids.update(MCP['classify'](source,MCP['inventory'](client),rows,pid,ARGV['process_argv'],ARGV['process_executable'],env_reader=MCP['shell_exec_reader'](client,ARGV['process_env']),**lenient))
                        finally:client.close()
                continue
            if pid in mcp_pids:continue
            runtime=len(argv)>1 and Path(argv[1]).name=='fleet-codex-runtime.py'
            bridge=len(argv)>2 and Path(argv[1]).name=='fleet-loop.py' and argv[2]=='bridge'
            if runtime or bridge:
                if strict: continue  # sleep's existing restartability contract
                if (helper_dir and Path(argv[1]).resolve()==helper_dir/Path(argv[1]).name
                        and (parent==source['pid'] or (runtime and '--guard' in argv and parent in helpers))):
                    helpers.add(pid)
                    continue
            if comm in ('codex-code-mode-host','codex-code-mode'):
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


def child_busy(session,target,pid=0,reap=False):
    """The pids a worker's agent still owns beyond its MCP services (issue #864).

    A child whose turn ended while a run_in_background test or a PR-gate waiter
    (`tools/await-pr.sh`) still runs under it has not STOPPED — it is waiting, and
    its parent must not hear otherwise. Same walk hibernation vetoes on, minus the
    restartability contract: an uncontracted MCP server is not work in progress.
    A known Claude pid (fleet_pane_claude_pid) skips the native inspect.
    reap=True adds native-idle proof only at disposal; a Stop hook runs before
    the native turn completes and must not wait on its own completion.
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
    if source['agent']=='codex' and reap:
        binding=codex_busy_binding(w,source)
        client=RPC(source['codex_identity']['remote'],timeout=5)
        try:
            turn=codex_idle_turn(client,source)
            if not turn.get('id'):raise ValueError('no completed Codex turn identity')
            quiet_processes(source,config_home,background=background,strict=False)
            # No cached idle or stale launch can waive the process gate. A turn
            # starting or a replacement session during classification vetoes.
            if codex_busy_binding(w,w.inspect())!=binding:
                raise ValueError('Codex binding changed during busy check')
            if codex_idle_turn(client,source).get('id')!=turn.get('id'):
                raise ValueError('Codex turn changed during busy check')
        finally:client.close()
    else:
        quiet_processes(source,config_home or os.environ.get('CLAUDE_CONFIG_DIR'),background=background,strict=False)
    return background


ACTIONS=('hook','busy','holds-exit','deliver','dispose','restore','hold','release')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=ACTIONS)
    p.add_argument('--session',default='')
    p.add_argument('window',nargs='?')
    p.add_argument('--record',default='')
    p.add_argument('--pid',type=int,default=0,help='busy: the Claude pid already resolved for this pane')
    p.add_argument('--reap',action='store_true',help='busy: require current native idle proof before disposal')
    a=p.parse_intermixed_args()
    if a.action=='hook':
        try: hook()
        except (ValueError,KeyError,OSError,subprocess.SubprocessError): pass
        return 0
    if a.action=='busy':
        # Exit 0 = busy (prints the pids), 1 = idle, 2 = cannot tell (fleet-sleep:
        # on stderr). Unknown retains the window, never permission to reap.
        try:pids=child_busy(a.session,a.window or '',a.pid,reap=a.reap)
        except Exception as exc:
            print('fleet-sleep: '+str(exc),file=sys.stderr)
            return 2
        if not pids: return 1
        print(' '.join(map(str,pids)))
        return 0
    # compat-1v: 下一批删 — no sleep record is written since T548 (C8): nothing
    # holds an exit, nothing to retire or put back.
    if a.action=='holds-exit': return 1
    if a.action in ('dispose','restore'): return 0
    w=Worker(a.session,a.window or '')
    if a.action=='deliver': w.deliver(sys.stdin.read())
    # A reap HOLD (issue #1244): fleet-reap-live.py retains a held worker, so no
    # automatic cleanup and no ⌃x takes it until `release`.
    else: w.stamp('@reap_hold','1' if a.action=='hold' else '')
    return 0


if __name__=='__main__':
    # A timebox stops us with TERM: unwind the worker lock rather than die in it.
    def interrupted(signum,frame): raise SystemExit(128+signum)
    signal.signal(signal.SIGTERM,interrupted)
    try: sys.exit(main())
    except (ValueError,KeyError,OSError,subprocess.SubprocessError) as exc:
        print('fleet-sleep: '+str(exc),file=sys.stderr); sys.exit(2 if 'busy' in sys.argv[1:2] else 1)
