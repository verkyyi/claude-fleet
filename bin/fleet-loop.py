#!/usr/bin/env python3
"""Fleet-owned recurring wakeups for a transferred Codex CLI session.

Usage: fleet-loop.py status | bind | defer --seconds N [--prompt-file FILE] | stop
       fleet-loop.py from-claude --transcript FILE --output FILE

The transfer's private loop spec opts in to a per-pane Codex app server. The TUI
and scheduler use that same server; no keystrokes, second writer, global daemon,
or guessed rollout is involved. The controller ends when its TUI exits.
"""

import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import runpy
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess
import sys
import time
import uuid


def save(path, value):
    path = Path(path)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def spec(value):
    if not isinstance(value, dict):
        raise ValueError('loop spec must be a JSON object')
    prompt = value.get('prompt')
    seconds = value.get('interval_seconds')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt.encode()) > 65536:
        raise ValueError('loop prompt must contain 1..65536 UTF-8 bytes')
    if type(seconds) is not int or not 30 <= seconds <= 604800:
        raise ValueError('interval_seconds must be an integer in 30..604800')
    due = value.get('next_run_at', time.time() + seconds)
    if not isinstance(due, (int, float)) or not 0 <= due <= time.time() + 604800:
        raise ValueError('next_run_at must be a Unix timestamp within the next seven days')
    # A missing per-turn rearm retains the last chosen cadence. Never replay
    # missed intervals: a late wakeup is one turn, not a catch-up burst.
    return {'prompt': prompt, 'interval_seconds': seconds, 'next_run_at': due}


def tm(r, *args):
    return subprocess.check_output(['tmux', '-L', r['fleet']['session'], *args],
                                   stderr=subprocess.PIPE, timeout=5).decode().strip()


def pane(r, fmt):
    return tm(r, 'display-message', '-p', '-t', r['fleet']['pane_id'], fmt)


def current(r):
    f = r['fleet']
    want = '|'.join([f['session'], f['window_id'], str(r['pane_pid']), r.get('agent','codex'),
                     r['manifest'], r['worktree']])
    got = pane(r, '#{session_name}|#{window_id}|#{pane_pid}|#{@cc_agent}|#{@handoff_manifest}|#{@worktree}')
    if got != want or pane(r, '#{pane_dead}') == '1':
        raise ValueError('pane, agent, worktree or handoff identity changed')
    if r.get('thread_id'):
        sid = (claude_identity(r)['session_id'] if r.get('agent') == 'claude'
               else json.loads(pane(r, '#{@codex_identity}') or '{}').get('session_id'))
        if sid != r['thread_id']:
            raise ValueError('the TUI switched to another Codex thread')
    if r.get('owner_record'):
        owner = json.loads(Path(r['owner_record']).read_text())
        if (owner.get('active_record') != r['record_path']
                or owner.get('active_generation') != r.get('generation',0)):
            raise ValueError('loop ownership moved to another session')


class Rpc(runpy.run_path(str(Path(__file__).with_name('fleet-codex-rpc.py')))['Client']):
    """Use the same bounded native transport as Fleet's Codex session adapter."""
    def __init__(self, sock):
        super().__init__('unix://' + str(sock), timeout=10)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


@contextmanager
def locked(path, nonblocking=False):
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        yield json.loads(path.read_text())


def record_path():
    value = os.environ.get('FLEET_LOOP_RECORD', '')
    if not value and os.environ.get('TMUX_PANE'):
        manifest = subprocess.check_output(['tmux','display-message','-p','-t',os.environ['TMUX_PANE'], '#{@handoff_manifest}'],timeout=5,text=True).strip()
        if manifest:
            value = str(Path(manifest).parent / 'loop/state.json')
    if not value:
        raise ValueError('run this command inside the transferred loop session')
    return Path(value)


def thread(r, rpc):
    t = rpc.call('thread/read', {'threadId': r['thread_id'], 'includeTurns': False})['thread']
    if t['id'] != r['thread_id'] or Path(t['cwd']).resolve() != Path(r['worktree']).resolve():
        raise ValueError('Codex thread identity or working directory changed')
    if t.get('parentThreadId'):
        raise ValueError('a subagent cannot own the pane loop')
    return t


def command(a):
    path = record_path()
    with locked(path) as r:
        if a.command == 'status':
            print(json.dumps(r, ensure_ascii=False, indent=2))
            return
        current(r)
        sid = claude_identity(r)['session_id'] if r.get('agent') == 'claude' else os.environ.get('CODEX_THREAD_ID', '')
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', sid):
            raise ValueError('CODEX_THREAD_ID is required; never guess the latest rollout')
        if r.get('thread_id') and r['thread_id'] != sid:
            raise ValueError('this is not the loop owner thread')
        if a.command != 'bind' and r.get('thread_id') != sid:
            raise ValueError('bind the owning thread before changing its loop')
        if a.command == 'bind':
            r['thread_id'] = sid
            if r.get('agent') != 'claude':
                with Rpc(r['socket']) as rpc:
                    thread(r, rpc)
            if r['status'] == 'unbound':
                r['status'] = 'active'
            elif r['status'] != 'active':
                raise ValueError('stopped/paused loop needs explicit operator recovery')
            if r.get('agent') != 'claude':
                tm(r, 'set-option', '-w', '-t', r['fleet']['window_id'], '@codex_thread_id', sid)
        elif a.command == 'defer':
            if r.get('agent') == 'claude' and r['status'] == 'delivering':
                acknowledge_claude(r)
            if r['status'] != 'active':
                raise ValueError('loop is not active; bind it first')
            update = dict(r['schedule'], interval_seconds=a.seconds,
                          next_run_at=time.time() + a.seconds)
            if a.prompt_file:
                update['prompt'] = Path(a.prompt_file).read_text()
            r['schedule'] = spec(update)
        elif a.command == 'stop':
            r['status'] = 'stopped'
            r['detail'] = 'Stopped by owner thread'
        save(path, r)
        print(json.dumps({'id': r['id'], 'status': r['status'],
                          'thread_id': r.get('thread_id'),
                          'next_run_at': r['schedule']['next_run_at']}, ensure_ascii=False))


def dispatch(path, now=None):
    now = time.time() if now is None else now
    try:
        with locked(path, nonblocking=True) as r:
            if r.get('agent') == 'claude' and r['status'] == 'delivering':
                current(r)
                if not acknowledge_claude(r) and now-r.get('delivery_started_at',now) > 30:
                    r.update(status='paused',detail='Claude inbox write has no transcript acknowledgement; not resending')
                save(path,r)
                return
            if r['status'] != 'active' or now < r['schedule']['next_run_at']:
                return
            try:
                current(r)
                # Wait behind a real turn, an operator dialog, or recent typing.
                if (pane(r, '#{@claude_state}') != 'done'
                        or pane(r, '#{@agent_transfer_request}')
                        or pane(r, '#{@quota_failover}')
                        or int(pane(r, '#{@agent_transfer_until}') or 0) > now
                        or pane(r, '#{@handoff_armed}') == '1'):
                    return
                for line in tm(r, 'list-clients', '-F', '#{client_activity}|#{window_id}').splitlines():
                    activity, win = line.split('|', 1)
                    if win == r['fleet']['window_id'] and now - int(activity) <= 30:
                        return
                # The same cursor/faint reader as issue relay; preserve unsent
                # drafts even after its operator-activity deferral has expired.
                if r.get('agent') or r.get('generation') is not None:
                    view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](r['fleet']['session'],r['fleet']['pane_id'])
                    if view['state'] != 'empty':
                        return
                if r.get('agent') == 'claude':
                    deliver_claude(path,r,now)
                    return
                with Rpc(r['socket']) as rpc:
                    t = thread(r, rpc)
                    if t['status']['type'] == 'active':
                        return
                    if t['status']['type'] != 'idle':
                        raise ValueError('Codex thread is no longer loaded and idle')
                    # Persist BEFORE sending. A crash/timeout after sending is
                    # ambiguous and must never cause an automatic duplicate.
                    r['status'] = 'delivering'
                    r['detail'] = 'Delivery in progress; ambiguous failures require inspection'
                    save(path, r)
                    prompt = (r['schedule']['prompt'] + '\n\n[Fleet loop wakeup ' + r['id'] + ']\n'
                              'Continue in the existing conversation language. At the end of this iteration, '
                              'use fleet-loop.py defer --seconds N to choose the next delay (optionally '
                              '--prompt-file FILE for updated context), or fleet-loop.py stop if complete, '
                              'cancelled, or ALL remaining work requires a human decision. A blocked '
                              'item must not stop other authorized monitoring responsibilities. The script is at ' +
                              str(Path(__file__).absolute()) + '. Do not recreate a Claude /loop. '
                              'Do not repeat completed work or override pending approvals. Without a change, '
                              'Fleet retains the last interval; missed intervals are never replayed.')
                    result = rpc.call('turn/start', {'threadId': r['thread_id'],
                                                    'input': [{'type': 'text', 'text': prompt}]})
                    r['last_turn_id'] = result['turn']['id']
                r['status'] = 'active'
                r['last_delivered_at'] = now
                r['deliveries'] += 1
                r['schedule']['next_run_at'] = now + r['schedule']['interval_seconds']
                r['detail'] = 'Wakeup accepted by the bound Codex thread'
            except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
                r['status'] = 'paused'
                r['detail'] = str(error)
            save(path, r)
    except BlockingIOError:
        pass


def claude_identity(r):
    pid = r.get('native_pid')
    if not pid:
        raise ValueError('Claude loop has no registered owner process')
    os.kill(int(pid),0)
    lib = str(Path(__file__).with_name('fleet-lib.sh'))
    registry = subprocess.check_output(['bash','-c','. "$1"; fleet_cc_session_json "$2"',
                                       'fleet-loop',lib,str(pid)],timeout=5,text=True).strip()
    data = json.loads(Path(registry).read_text())
    if Path(data.get('cwd','')).resolve() != Path(r['worktree']).resolve():
        raise ValueError('Claude loop owner changed its worktree')
    return {'session_id':data['sessionId'],'registry':registry}


def claude_transcript(r):
    sid = claude_identity(r)['session_id']
    projects = Path(os.environ.get('FLEET_CC_PROJECTS_DIR',os.environ.get('CLAUDE_PROJECTS_DIR',str(Path.home()/'.claude/projects'))))
    matches = list(projects.glob('*/'+sid+'.jsonl'))
    if len(matches) != 1:
        raise ValueError('exact Claude loop transcript is unavailable')
    return matches[0]


def acknowledge_claude(r):
    path = claude_transcript(r)
    with path.open('rb') as stream:
        stream.seek(r['delivery_offset'])
        for line in stream.read(1024*1024).splitlines():
            try: row = json.loads(line)
            except ValueError: continue
            if (row.get('type') == 'user' and not row.get('isSidechain')
                    and r['delivery_id'] in json.dumps(row.get('message',{}),ensure_ascii=False)):
                r.update(status='active',last_turn_id=row.get('uuid'),last_delivered_at=r['delivery_started_at'],
                         deliveries=r.get('deliveries',0)+1,detail='Claude inbox message acknowledged in its exact transcript')
                r['schedule']['next_run_at']=r['delivery_started_at']+r['schedule']['interval_seconds']
                return True
    return False


def deliver_claude(path,r,now):
    transcript = claude_transcript(r)
    r.update(status='delivering',delivery_id='fleet-loop:'+r['id']+':'+str(uuid.uuid4()),
             delivery_started_at=now,delivery_offset=transcript.stat().st_size,
             detail='Claude inbox delivery awaiting transcript acknowledgement')
    save(path,r)  # Persist before the frame write; a timeout is never a retry.
    script=str(Path(__file__).absolute())
    prompt=(r['schedule']['prompt']+'\n\n['+r['delivery_id']+']\nContinue in the conversation language. '
            'At the end use python3 '+script+' defer --seconds N, or stop when the task is complete/cancelled '
            'or all remaining work needs a human decision. Fleet owns this timer; do not create another /loop. '
            'Do not submit saved drafts, repeat completed actions or override pending approvals.')
    subprocess.run(['bash',str(Path(__file__).with_name('fleet-peer-send.sh')),'-L',r['fleet']['session'],
                    r['fleet']['pane_id'],'-'],input=prompt,text=True,stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE,timeout=10,check=True)


def claim_owner(path,r,raw):
    previous=raw.get('previous_record')
    if previous:
        old=json.loads(Path(previous).read_text())
        owner=Path(old.get('owner_record',previous))
        r.update(owner_record=str(owner),generation=raw['generation'],record_path=str(path))
        with locked(owner) as record:
            if (old['id']!=r['id'] or record.get('active_record',previous)!=previous
                    or record.get('active_generation',old.get('generation',0))+1!=r['generation']):
                raise ValueError('loop generation was already claimed')
            record.update(active_record=str(path),active_generation=r['generation'])
            save(owner,record)
    else:
        r.update(owner_record=str(path),record_path=str(path),generation=0,
                 active_record=str(path),active_generation=0)


def claude_bridge(args,path,r,env):
    child=None
    try:
        child=subprocess.Popen(args,env=env)
        with locked(path) as record:
            record['native_pid']=child.pid
            save(path,record)
        # The token-selected launcher execs this supervisor. Bind its verified
        # subscription stamp to the actual Claude child used by the registry.
        if os.environ.get('FLEET_ACCOUNT_TARGET'):
            binding=json.loads(os.environ['FLEET_ACCOUNT_TARGET']); binding['owner']=str(child.pid)
            tm(r,'set-option','-w','-t',r['fleet']['window_id'],'@subscription_identity',json.dumps(binding))
        while child.poll() is None:
            dispatch(path)
            time.sleep(1)
        return child.returncode
    finally:
        with locked(path) as final:
            final.update(status='stopped',detail='Claude TUI/controller ended')
            save(path,final)
        if child and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()


def bridge(args):
    manifest = Path(os.environ['FLEET_HANDOFF_MANIFEST']).resolve()
    m = json.loads(manifest.read_text())
    if Path(os.environ['FLEET_LOOP_SPEC']).resolve() != Path(m['loop_spec_path']).resolve():
        raise ValueError('loop spec must belong to this transfer manifest')
    try:
        os.kill(m['source']['pid'], 0)
    except ProcessLookupError:
        pass
    else:
        raise ValueError('source process must have exited before enabling the Codex loop')
    raw = json.loads(Path(os.environ['FLEET_LOOP_SPEC']).read_text())
    schedule = spec(raw)
    ident = raw.get('id') or hashlib.sha256(str(manifest).encode()).hexdigest()[:20]
    directory = manifest.parent / 'loop'
    directory.mkdir(mode=0o700)  # No accidental restart/duplicate controller.
    path = directory / 'state.json'
    agent = os.environ.get('FLEET_LOOP_AGENT',m.get('target',{}).get('agent','codex'))
    r = {'schema_version': 1, 'id': ident, 'status': 'unbound', 'manifest': str(manifest),
         'fleet': m['fleet'], 'source': m['source'], 'worktree': m['workspace']['path'],
         'agent': agent, 'schedule': schedule, 'socket': '', 'thread_id': None,
         'deliveries': raw.get('deliveries',0), 'last_delivered_at':raw.get('last_delivered_at'),
         'controller_pid': os.getpid()}
    r['pane_pid'] = int(pane(r, '#{pane_pid}'))
    current(r)
    claim_owner(path,r,raw)
    save(path, r)
    env = dict(os.environ, FLEET_LOOP_RECORD=str(path))
    env.pop('CODEX_THREAD_ID', None)
    env.pop('CODEX_SESSION_ID', None)
    if agent == 'claude':
        env.pop('FLEET_CODEX_REMOTE',None)
        return claude_bridge(args,path,r,env)
    # Reuse the existing guarded runtime: SIGKILL of this controller cannot
    # leak its app-server, and all profile/config flags reach both processes.
    def prepare(remote, runtime_env):
        runtime_env['FLEET_LOOP_RECORD'] = str(path)
        with locked(path) as record:
            record['socket']=remote[7:]
            save(path,record)
    last_tick=[0.0]
    def tick():
        if time.monotonic()-last_tick[0]>=1:
            last_tick[0]=time.monotonic()
            dispatch(path)
    os.environ['FLEET_LOOP_RECORD']=str(path)
    os.environ.pop('CODEX_THREAD_ID',None)
    os.environ.pop('CODEX_SESSION_ID',None)
    try:
        return runpy.run_path(str(Path(__file__).with_name('fleet-codex-runtime.py')))['run'](args,prepare=prepare,tick=tick)
    finally:
        with locked(path) as final:
            final['status']='stopped'
            final['detail']='Codex TUI/controller ended; no automatic replay'
            save(path,final)


def from_claude(a):
    calls = {}
    last = None
    scheduled_at = None
    with Path(a.transcript).open() as history:
        for line in history:
            row = json.loads(line)
            if row.get('isSidechain'):
                continue
            content = row.get('message', {}).get('content', [])
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get('type') == 'tool_use' and b.get('name') == 'ScheduleWakeup':
                    calls[b['id']] = (b['input'], row.get('timestamp'))
                if b.get('type') == 'tool_result' and b.get('tool_use_id') in calls and not b.get('is_error'):
                    last, scheduled_at = calls[b['tool_use_id']]
    if not last or last.get('stop') or not last.get('prompt'):
        raise ValueError('no successful self-paced ScheduleWakeup to import; inspect the source')
    value = {'prompt': last['prompt'], 'interval_seconds': last['delaySeconds']}
    if scheduled_at:
        value['next_run_at'] = datetime.datetime.fromisoformat(scheduled_at.replace('Z', '+00:00')).timestamp() + last['delaySeconds']
    value = spec(value)
    save(Path(a.output), value)
    print('Saved last successful self-paced loop. Verify it is still intended before passing --loop: ' + a.output)


def main():
    os.umask(0o077)
    if len(sys.argv) > 2 and sys.argv[1:3] == ['bridge', '--']:
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda *_: sys.exit(128))
        return bridge(sys.argv[3:])
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('bind', 'status', 'stop'):
        sub.add_parser(name)
    d = sub.add_parser('defer')
    d.add_argument('--seconds', type=int, required=True)
    d.add_argument('--prompt-file')
    c = sub.add_parser('from-claude')
    c.add_argument('--transcript', required=True)
    c.add_argument('--output', required=True)
    a = p.parse_args()
    if a.command == 'from-claude':
        from_claude(a)
    else:
        command(a)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print('fleet-loop: ' + str(error), file=sys.stderr)
        sys.exit(1)
