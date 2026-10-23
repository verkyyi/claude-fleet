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
import signal
import subprocess
import sys
import time
import uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_cron
import fleet_iso  # noqa: E402  the one ISO reader (issue #2024)


def save(path, value):
    path = Path(path)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def spec(value, now=None):
    if not isinstance(value, dict):
        raise ValueError('loop spec must be a JSON object')
    if 'jobs' in value:
        return fleet_cron.plan(value, now)
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


def advance(schedule, now):
    if 'jobs' in schedule:
        fleet_cron.advance(schedule, now)
    else:
        schedule['next_run_at'] = now + schedule['interval_seconds']


def wakeup_prompt(schedule, now):
    if 'jobs' not in schedule:
        return schedule['prompt']
    return '\n\n'.join('Cron job '+j['id']+' ('+j['cron']+'; '+j['timezone']+')\n'+j['prompt']+
                        '\nSchedule: '+('recurring' if j.get('recurring', True) else 'once')+
                        '\nStop condition: '+(j['stop_when'] or 'none beyond expiry')
                        for j in fleet_cron.pending(schedule, now))


def durable_ready(r, now):
    """A due durable job (issue #4280) is delivered only while its journal is
    active and the native table no longer holds it; returned or rolled back,
    it leaves this plan. True = deliver what is due now."""
    if not r.get('durable_fid') or 'jobs' not in r['schedule']:
        return True
    due = [j for j in fleet_cron.pending(r['schedule'], now) if j['id'] in r.get('durable_ids', [])]
    if not due:
        return True
    import fleet_transfer_durable as durable
    verdict = durable.gate(r['durable_fid'])
    if verdict == 'wait':
        r['detail'] = 'Durable job waits for its single-owner activation'
        return False
    if verdict == 'drop':
        for job in due:
            job['next_run_at'] = None
        fleet_cron.refresh(r['schedule'])
        r['detail'] = 'Durable job belongs to the native scheduler again; not delivered here'
        return r['schedule']['next_run_at'] is not None and now >= r['schedule']['next_run_at']
    return True


def durable_delivered(r, ids, delivery):
    mine = [i for i in ids if i in r.get('durable_ids', [])]
    if mine and r.get('durable_fid'):
        import fleet_transfer_durable as durable
        try:
            durable.complete(r['durable_fid'], delivery)
        except (OSError, ValueError) as error:
            # Delivered either way; the journal only lags. Never a resend.
            r['detail'] = 'Durable job delivered; journal not completed: ' + str(error)


def tm(r, *args):
    return subprocess.check_output(['tmux', '-L', r['fleet']['session'], *args],
                                   stderr=subprocess.PIPE, timeout=5).decode().strip()


def pane(r, fmt):
    return tm(r, 'display-message', '-p', '-t', r['fleet']['pane_id'], fmt)


def execution_check(r, *, fresh=False):
    from fleet_task_execution import check_session, refresh_session, FenceRefused
    fid = pane(r, '#{@fleet_id}')
    raw = pane(r, '#{@task_execution}')
    if not fid and not raw:
        return  # a pre-identity loop has no new execution authorization
    try:
        expected = json.loads(raw) if raw else None
    except ValueError as exc:
        raise FenceRefused('invalid task execution metadata') from exc
    if raw and not isinstance(expected, dict):
        raise FenceRefused('invalid task execution metadata')
    check = refresh_session if fresh else check_session
    check(fid, expected=expected, controlled=bool(raw))


def current(r):
    f = r['fleet']
    want = '|'.join([f['session'], f['window_id'], str(r['pane_pid']), r.get('agent','codex'),
                     r['manifest'], r['worktree']])
    # group-or-name (issues #1489, #2102): a bare session_name names a Fleet
    # Shell view session while one is attached, and every loop read as moved.
    binding = '#{pane_current_path}' if r.get('workspace_kind') == 'norepo' else '#{@worktree}'
    got = pane(r, '#{?#{session_group},#{session_group},#{session_name}}|#{window_id}|#{pane_pid}|#{@cc_agent}|#{@handoff_manifest}|' + binding)
    if got != want or pane(r, '#{pane_dead}') == '1':
        raise ValueError('pane, agent, worktree or handoff identity changed')
    execution_check(r)
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
        if r.get('park_fid'):
            import fleet_session_gate
            w = fleet_session_gate.window(r['park_fid'])
            if (not w or w['pane'] != os.environ.get('TMUX_PANE') or w['sid'] != r.get('thread_id')
                    or w['socket_path'] != os.environ.get('TMUX', '').split(',')[0]):
                raise ValueError('this is not the parked loop owner thread')
            sid = w['sid']
        else:
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
            if r.get('agent') != 'claude' and not r.get('park_fid'):
                with Rpc(r['socket']) as rpc:
                    thread(r, rpc)
            if r['status'] == 'unbound':
                r['status'] = 'active'
            elif r['status'] != 'active':
                raise ValueError('stopped/paused loop needs explicit operator recovery')
            if r.get('agent') != 'claude' and not r.get('park_fid'):
                tm(r, 'set-option', '-w', '-t', r['fleet']['window_id'], '@codex_thread_id', sid)
        elif a.command == 'defer':
            if 'jobs' in r['schedule']:
                raise ValueError('cron jobs retain their own cadence; use stop --job ID for an individual termination')
            # The inbox road is acknowledged from the transcript.
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
            if getattr(a, 'job', None):
                jobs = r['schedule'].get('jobs', [])
                selected = [j for j in jobs if j['id'] == a.job]
                if len(selected) != 1:
                    raise ValueError('no such cron job')
                selected[0]['next_run_at'] = None
                fleet_cron.refresh(r['schedule'])
                if r['schedule']['next_run_at'] is None:
                    r['status'] = 'complete'
                save(path, r)
                return
            r['status'] = 'stopped'
            r['detail'] = 'Stopped by owner thread'
        save(path, r)
        print(json.dumps({'id': r['id'], 'status': r['status'],
                          'thread_id': r.get('thread_id'),
                          'next_run_at': r['schedule']['next_run_at']}, ensure_ascii=False))


def dispatch(path, now=None):
    now = time.time() if now is None else now
    try:
        # Never hold a loop/FID lock across Hub I/O. A failed refresh holds the
        # existing schedule without claiming it was revoked or delivered.
        preview = json.loads(Path(path).read_text())
        if not preview.get('park_fid'):
            execution_check(preview, fresh=True)
    except (OSError, ValueError, subprocess.SubprocessError):
        return
    try:
        with locked(path, nonblocking=True) as r:
            if r.get('park_fid'):
                return  # C3 owns delivery through the same conversation's gate.
            if r['status'] == 'unbound':
                try:
                    current(r)
                    if r.get('agent') == 'claude':
                        sid = claude_identity(r)['session_id']
                    else:
                        adapter = runpy.run_path(str(Path(__file__).with_name('fleet-codex-session.py')))
                        identity = adapter['identity'](r['fleet']['pane_id'],r['fleet']['session'])
                        if identity.get('remote') != 'unix://' + r['socket']:
                            return
                        sid = identity['session_id']
                        r['home'] = identity['home']
                    r.update(thread_id=sid,status='active')
                    save(path,r)
                    if r.get('durable_fid'):
                        # Bound after the source exited (bridge()): this loop is
                        # the durable job's one owner from here (issue #4280).
                        try:
                            import fleet_transfer_durable as durable
                            durable.activate(r['durable_fid'], dict(agent=r.get('agent','codex'), session=sid,
                                                                    record=str(path)))
                        except (OSError, ValueError) as error:
                            r['detail'] = 'Durable job not activated: ' + str(error)
                            save(path,r)
                except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError):
                    return  # Native SessionStart has not bound the root yet.
            if r.pop('pending_delivery', None):
                # A launch-proof delivery left from before EPIC T497 C8: its road
                # is gone; the round stays due and goes the pane's own road.
                if r['status'] == 'delivering':
                    r['status'] = 'active'
            if r.get('agent') == 'claude' and r['status'] == 'delivering':
                current(r)
                if not acknowledge_claude(r) and now-r.get('delivery_started_at',now) > 30:
                    r.update(status='paused',detail='Claude inbox write has no transcript acknowledgement; not resending')
                save(path,r)
                return
            if 'jobs' in r['schedule']:
                for job in r['schedule']['jobs']:
                    # A recurring job keeps its one final round past expiry
                    # (fleet_cron.final_fire, native 2.1.295); a one-shot does not.
                    if not job.get('recurring', True) and job['expires_at'] is not None and job['expires_at'] <= now:
                        job['next_run_at'] = None
                fleet_cron.refresh(r['schedule'])
                if r['schedule']['next_run_at'] is None:
                    r.update(status='complete', detail='Every cron job expired or stopped')
                    save(path, r)
                    return
            if r['status'] == 'waiting-quota':
                # The quota failover planner that paused it is retired (T546):
                # release the wait, next round on the interval. compat-1v: 下一批删
                r.update(status='active', detail='Quota wait released: the pool changes a full subscription')
                r.pop('quota_request', None)
                if r['schedule'].get('interval_seconds'):
                    r['schedule']['next_run_at'] = now + r['schedule']['interval_seconds']
                save(path, r)
                return
            elif r['status'] != 'active' or now < r['schedule']['next_run_at']:
                return
            if not durable_ready(r, now):
                save(path, r)
                return
            r['due_since'] = r.get('due_since') or now
            try:
                current(r)
                why = hold(r, now)
                if why:
                    defer(path, r, why)
                    return
                # The pane's own road (EPIC T497 C8 retired the launch-proof one):
                # the Claude inbox, or the Codex thread below — not an atomic accept.
                if r.get('agent') == 'claude':
                    attempt(r, now, 'legacy_unfenced', 'delivering', 'claude_inbox')
                    deliver_claude(path,r,now)
                    return
                with Rpc(r['socket']) as rpc:
                    t = thread(r, rpc)
                    if t['status']['type'] == 'active':
                        defer(path, r, 'runtime:active')
                        return
                    if t['status']['type'] != 'idle':
                        raise ValueError('Codex thread is no longer loaded and idle')
                    # Persist BEFORE sending. A crash/timeout after sending is
                    # ambiguous and must never cause an automatic duplicate.
                    r['status'] = 'delivering'
                    r['detail'] = 'Delivery in progress; ambiguous failures require inspection'
                    attempt(r, now, 'legacy_unfenced', 'delivering', 'turn_start')
                    save(path, r)
                    prompt = codex_prompt(r, now)
                    due_ids = [j['id'] for j in fleet_cron.pending(r['schedule'], now)] if 'jobs' in r['schedule'] else []
                    execution_check(r)
                    result = rpc.call('turn/start', {'threadId': r['thread_id'],
                                                    'input': [{'type': 'text', 'text': prompt}]})
                    r['last_turn_id'] = result['turn']['id']
                delivered(r, now, due_ids, r['last_turn_id'], 'Wakeup accepted by the bound Codex thread')
            except (OSError, ValueError, KeyError, TypeError, EOFError, RuntimeError, subprocess.SubprocessError) as error:
                r['status'] = 'paused'
                r['detail'] = str(error)
            save(path, r)
    except BlockingIOError:
        pass


def codex_prompt(r, now):
    if 'jobs' in r['schedule']:
        return wakeup_prompt(r['schedule'], now) + '\n\nFleet owns these independent cron schedules. Preserve their cadence, timezone and expiry. Do not rearm or recreate them. Stop only a completed job with fleet-loop.py stop --job ID; do not stop other monitoring. Continue in the existing conversation language.'
    return (wakeup_prompt(r['schedule'], now) + '\n\n[Fleet loop wakeup ' + r['id'] + ']\n'
            'Continue in the existing conversation language. At the end of this iteration, '
            'use fleet-loop.py defer --seconds N to choose the next delay (optionally '
            '--prompt-file FILE for updated context), or fleet-loop.py stop if complete, '
            'cancelled, or ALL remaining work requires a human decision. A blocked '
            'item must not stop other authorized monitoring responsibilities. The script is at ' +
            str(Path(__file__).absolute()) + '. Do not recreate a Claude /loop. '
            'Do not repeat completed work or override pending approvals. Without a change, '
            'Fleet retains the last interval; missed intervals are never replayed.')


def wait_reasons(r):
    """The Stop hook's wait reasons asked FRESH, minus `loop` (issue #4431).

    fleet_window_wait's loop half is this very ledger's pending wakeup: it must
    not hold its own due delivery. children / bg / tool / human still hold it.
    An answer that cannot be read is `unknown`, which holds too.
    """
    lib = str(Path(__file__).with_name('fleet-lib.sh'))
    try:
        out = subprocess.run(['bash', '-c', '. "$1"; s=$2; w=$3; '
                              'fleet_window_waiting_children "$s" "$w" >/dev/null 2>&1 && echo children; '
                              'fleet_window_bg_busy "$s" "$w" 1 && echo bg; '
                              'fleet_window_tool_busy "$s" "$w" && echo tool; '
                              'fleet_window_human "$s" "$w" >/dev/null && echo human; echo ok',
                              'fleet-loop', lib, r['fleet']['session'], r['fleet']['window_id']],
                             capture_output=True, text=True, timeout=15).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return ['unknown']
    return [w for w in out if w != 'ok'] if out[-1:] == ['ok'] else ['unknown']


def hold(r, now):
    """Why a due wakeup waits now ('' = none). The panel word is read only for the
    states it alone knows (a turn, a question); `looping` is re-asked, never trusted."""
    if r.get('quota_transfer_state'):
        # A late native binding must not enable a replacement timer after its
        # transfer failed/timed out. Only the controller's verified target starts it.
        try:
            transfer = json.loads(Path(r['quota_transfer_state']).read_text())
            if transfer.get('state') != 'started':
                return 'quota-transfer-unconfirmed'
        except (OSError, ValueError, TypeError, AttributeError):
            return 'quota-transfer-unconfirmed'
    if pane(r, '#{@agent_transfer_request}') or int(pane(r, '#{@agent_transfer_until}') or 0) > now:
        return 'transfer'
    if pane(r, '#{@handoff_armed}') == '1':
        return 'handoff'
    state = pane(r, '#{@claude_state}')
    if state == 'working':
        return 'active_turn'
    if state.startswith('needs'):
        return 'attention'
    if state not in ('done', 'looping'):
        return 'state:' + (state or 'unknown')
    waits = wait_reasons(r)
    if waits:
        return 'wait:' + ','.join(waits)
    for line in tm(r, 'list-clients', '-F', '#{client_activity}|#{window_id}').splitlines():
        activity, win = line.split('|', 1)
        if win == r['fleet']['window_id'] and now - int(activity) <= 30:
            return 'recent_input'
    # The same cursor/faint reader as issue relay; preserve unsent drafts even
    # after its operator-activity deferral has expired.
    if r.get('agent') or r.get('generation') is not None:
        view = runpy.run_path(str(Path(__file__).with_name('fleet-input.py')))['snapshot'](r['fleet']['session'],r['fleet']['pane_id'],agent=r.get('agent'))
        if view['state'] != 'empty':
            return 'input_draft'
    return ''


def attempt(r, now, fence, state, reason, **extra):
    r['last_attempt'] = dict(at=now, fence=fence, state=state, reason=reason,
                             owner_generation=r.get('generation', 0), **extra)


def defer(path, r, why):
    """Still due, nothing sent: say why on the ledger (status stays as it was)."""
    r['deferred_reason'] = why
    save(path, r)


def delivered(r, now, due_ids, turn, detail):
    r.update(status='active', last_delivered_at=now, deliveries=r.get('deliveries', 0) + 1,
             accepted_turn=turn, last_turn_id=turn, due_since=None, deferred_reason=None, detail=detail)
    r.pop('pending_delivery', None)
    if r.get('last_attempt'):
        r['last_attempt'].update(state='accepted', turn_id=turn)
    advance(r['schedule'], now)
    durable_delivered(r, due_ids, turn)


def recover(session):
    """Reattach only exact crash-restored owners on the existing quota tick.

    A living bridge still owns its timer. Explicit stops, interrupted deliveries,
    paused records, replacement threads and old ownership generations never run.
    No extra daemon or background scheduler is started here.
    """
    root = Path(os.environ.get('FLEET_CONF_DIR',str(Path.home()/'.config/claude-fleet'))) / 'handoffs'
    try:
        import fleet_transfer_durable as durable
        durable.recover_all()   # interrupted durable handovers (issue #4280)
    except (OSError, ValueError):
        pass
    adapter = runpy.run_path(str(Path(__file__).with_name('fleet-codex-session.py')))
    rows = adapter['tmux'](['list-windows','-t',session,'-F',
        '#{window_id}|#{pane_id}|#{pane_pid}|#{pane_current_path}|#{@cc_agent}|#{@handoff_manifest}|#{@reported}'],session)
    windows = [line.split('|',6) for line in rows.splitlines()]
    for path in list(root.glob('*/loop/state.json')) + list(root.glob('*/rollback/loop/state.json')):
        try:
            with locked(path,nonblocking=True) as r:
                if r.get('park_fid'):
                    continue  # C3 restores identity and delivers through the gate.
                if r.get('status') not in ('active', 'waiting-quota') or r['fleet']['session'] != session or not r.get('thread_id'):
                    continue
                pid = r.get('controller_pid',0)
                if pid:
                    try: os.kill(pid,0)
                    except ProcessLookupError: pass
                    else: continue
                if r.get('owner_record'):
                    owner = json.loads(Path(r['owner_record']).read_text())
                    if owner.get('active_record') != str(path): continue
                matches=[]
                for win,pane_id,pane_pid,cwd,agent,manifest,reported in windows:
                    if (reported == '1' or manifest != r['manifest'] or agent != r.get('agent','codex')
                            or Path(cwd).resolve() != Path(r['worktree']).resolve()): continue
                    candidate=dict(r,fleet=dict(r['fleet'],window_id=win,pane_id=pane_id),pane_pid=int(pane_pid))
                    if agent == 'codex':
                        identity=adapter['identity'](pane_id,session)
                        if identity.get('session_id') != r['thread_id'] or not identity.get('remote'): continue
                        if r.get('home') and identity.get('home') != r['home']: continue
                        candidate['socket']=identity['remote'][7:]
                    else:
                        lib=str(Path(__file__).with_name('fleet-lib.sh'))
                        native=subprocess.check_output(['bash','-c','. "$1"; fleet_pane_claude_pid "$2" "$3"',
                            'fleet-loop',lib,pane_id,session],text=True,timeout=5).strip()
                        candidate['native_pid']=int(native)
                        if claude_identity(candidate)['session_id'] != r['thread_id']: continue
                    matches.append(candidate)
                if len(matches) != 1: continue
                restored=matches[0]
                restored.update(controller_pid=0,driver='quotawatch',detail='Exact restored session reattached by the existing quota tick')
                current(restored)
                save(path,restored)
            dispatch(path)
        except (OSError,ValueError,KeyError,TypeError,EOFError,subprocess.SubprocessError):
            continue


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
                advance(r['schedule'], r['delivery_started_at'])
                durable_delivered(r, r.get('delivery_jobs', []), r['delivery_id'])
                return True
    return False


def deliver_claude(path,r,now):
    transcript = claude_transcript(r)
    r.update(status='delivering',delivery_id='fleet-loop:'+r['id']+':'+str(uuid.uuid4()),
             delivery_jobs=[j['id'] for j in fleet_cron.pending(r['schedule'], now)] if 'jobs' in r['schedule'] else [],
             delivery_started_at=now,delivery_offset=transcript.stat().st_size,
             detail='Claude inbox delivery awaiting transcript acknowledgement')
    save(path,r)  # Persist before the frame write; a timeout is never a retry.
    script=str(Path(__file__).absolute())
    prompt=(wakeup_prompt(r['schedule'], now)+'\n\n['+r['delivery_id']+']\nContinue in the conversation language. '
            'At the end use python3 '+script+' defer --seconds N, or stop when the task is complete/cancelled '
            'or all remaining work needs a human decision. Fleet owns this timer; do not create another /loop. '
            'Do not submit saved drafts, repeat completed actions or override pending approvals.')
    if 'jobs' in r['schedule']:
        prompt = wakeup_prompt(r['schedule'], now) + '\n\n['+r['delivery_id']+']\nFleet owns these cron jobs. Do not recreate timers or defer their cadence. Stop a completed job with fleet-loop.py stop --job ID; keep other monitoring active.'
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
    code=None
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
        code=child.returncode
        return code
    finally:
        with locked(path) as final:
            if code == 0 and not final.get('park_fid'):
                final['status']='stopped'
            final['detail']='Claude TUI/controller ended; exact crash restore may reattach an active loop'
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
         'agent': agent, 'workspace_kind': m['workspace'].get('kind', 'worktree'), 'schedule': schedule, 'socket': '', 'thread_id': None,
         'deliveries': raw.get('deliveries',0), 'last_delivered_at':raw.get('last_delivered_at'),
         'controller_pid': os.getpid()}
    if m.get('quota_loop_replacement'):
        r['quota_transfer_state'] = str(manifest.parent / 'state.json')
    if m.get('durable_fid'):
        r.update(durable_fid=m['durable_fid'], durable_ids=m.get('durable_ids', []))
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
    code=None
    try:
        code=runpy.run_path(str(Path(__file__).with_name('fleet-codex-runtime.py')))['run'](args,prepare=prepare,tick=tick)
        return code
    finally:
        with locked(path) as final:
            if code == 0 and not final.get('park_fid'):
                final['status']='stopped'
            final['detail']='Codex TUI/controller ended; exact crash restore may reattach an active loop'
            save(path,final)


def from_claude(a):
    # The transcript walk is fleet_loop_mark.py's (issue #1370): the same reading
    # backfills a pre-#1331 session's @loop, so the two can never disagree on which
    # ScheduleWakeup was the last successful one.
    walk = runpy.run_path(str(Path(__file__).with_name('fleet_loop_mark.py')))['claude_tool_results']
    last = None
    scheduled_at = None
    with Path(a.transcript).open() as history:
        for _name, inp, _resp, use_ts, _res_ts in walk(history, ('ScheduleWakeup',), strict=True):
            last, scheduled_at = inp, use_ts
    if not last or last.get('stop') or not last.get('prompt'):
        raise ValueError('no successful self-paced ScheduleWakeup to import; inspect the source')
    value = {'prompt': last['prompt'], 'interval_seconds': last['delaySeconds']}
    if scheduled_at:
        value['next_run_at'] = fleet_iso.parse(scheduled_at).timestamp() + last['delaySeconds']
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
    for name in ('bind', 'status'):
        sub.add_parser(name)
    c = sub.add_parser('stop'); c.add_argument('--job')
    c = sub.add_parser('recover'); c.add_argument('--session',required=True)
    d = sub.add_parser('defer')
    d.add_argument('--seconds', type=int, required=True)
    d.add_argument('--prompt-file')
    c = sub.add_parser('export-cron')
    c.add_argument('--jobs-file', required=True)
    c.add_argument('--session', required=True)
    c.add_argument('--pane', default=os.environ.get('TMUX_PANE', ''))
    c = sub.add_parser('from-claude')
    c.add_argument('--transcript', required=True)
    c.add_argument('--output', required=True)
    a = p.parse_args()
    if a.command == 'export-cron':
        from fleet_transfer_cron import export
        export(a.jobs_file, a.session, a.pane)
    elif a.command == 'from-claude':
        from_claude(a)
    elif a.command == 'recover':
        recover(a.session)
    else:
        command(a)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print('fleet-loop: ' + str(error), file=sys.stderr)
        sys.exit(1)
