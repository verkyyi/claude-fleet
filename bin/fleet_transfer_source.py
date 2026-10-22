#!/usr/bin/env python3
"""What a manual move needs to know about its SOURCE (T546, EPIC T542 C2).

The three checks fleet-transfer.sh / fleet-migrate.sh borrowed from the retired
quota failover planner (`.fleet-failover.py`), moved here unchanged:

  settled --session S --pane P          a `looping` Codex source between rounds is
                                        as settled as `done` (#786); exit 1 + why
  background --pid N [--worktree W] [--session S]
                                        every non-infrastructure process a Claude
                                        owns, as JSON [{pid,argv,cwd,start}] (#873)
  terminate-background DIR [--bundle B] [--note WHY]
                                        stop what DIR/background.json recorded,
                                        start-fingerprint checked (#871)

A full subscription is the pool's to change now; nothing here picks an account.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time

import fleet_session_fallback as fallback

BIN = Path(__file__).absolute().parent
ACCOUNT = runpy.run_path(str(BIN / '.fleet-account.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
ATTENTION = runpy.run_path(str(BIN / 'fleet-codex-attention.py'))
save, read = ACCOUNT['save'], ACCOUNT['read']
background_note = TRANSFER['background_note']


def run(argv, timeout=15, **kwargs):
    return subprocess.check_output([str(x) for x in argv], timeout=timeout,
                                   stderr=subprocess.PIPE, text=True, **kwargs).strip()


def inspect(session, window):
    return json.loads(run(['bash', BIN / 'fleet-transfer.sh', '--session', session,
                          '--window', window, '--to', 'codex', '--inspect'], timeout=30))


# The providers a fleet Codex thread runs on: OpenAI's own, or the pool's credential
# proxy (`model_provider="fleet"`, fleet-codex.sh / fleet-run.sh) — every pooled
# session's. Anything else is a thread the fleet did not start (T630).
FLEET_PROVIDERS = ('openai', 'fleet')


def native_thread(source):
    data = source['codex_identity']
    rpc = RPC(data.get('remote', ''), timeout=5)
    try:
        t = ATTENTION['thread_read'](rpc, dict(data, session_id=source['session_id']), include_turns=True)
    finally:
        rpc.close()
    if (t['id'] != source['session_id'] or t.get('modelProvider') not in FLEET_PROVIDERS
            or Path(t['cwd']).resolve() != Path(source['worktree']).resolve()):
        raise ValueError('native Codex thread/provider changed')
    return t


def codex_quiet(thread):
    if thread.get('status', {}).get('type') not in ('idle', 'systemError'):
        raise ValueError('source Codex turn or approval is still active')
    if any(i.get('status') not in (None, 'completed', 'failed', 'declined', 'interrupted')
           for t in (thread.get('turns') or [])[-1:] for i in t.get('items', [])):
        raise ValueError('source Codex tool is still active')


def looping_settled(source, thread):
    """A `looping` Codex source whose round ended cleanly is as settled as `done`:
    an idle thread with no live item (codex_quiet) and a completed last turn."""
    turns = thread.get('turns') or []
    return (source.get('agent') == 'codex' and source.get('state') == 'looping'
            and bool(turns) and turns[-1].get('status') == 'completed')


def settled(session, pane):
    """fleet-transfer.sh's manual source_ready for a `looping` Codex source."""
    source = inspect(session, pane)
    thread = native_thread(source)
    codex_quiet(thread)
    if not looping_settled(source, thread):
        raise ValueError('source is not a looping Codex worker between rounds')


def quota_marks(session, pane):
    fmt = '\x1f'.join('#{@' + k + '}' for k in
                       ('claude_state', 'claude_state_src', 'agent_status', 'claude_needs',
                        'claude_wait', 'loop', 'parked'))
    fields = run(['tmux', '-L', session, 'display-message', '-p', '-t', pane, fmt + '\x1fEND']).split('\x1f')
    if len(fields) != 8 or fields.pop() != 'END':
        raise ValueError('quota source metadata is incomplete')
    native = json.loads(fields[2] or '{}')
    ended = (fields[0] in ('done', 'exited') and fields[1] in ('7501', 'hook')
             and (native.get('state') == 'error' or (fields[0] == 'done' and native.get('state') in ('idle', 'done'))))
    if not ended or any(fields[3:]):
        raise ValueError('quota source is not a native error boundary without pending work')
    return fields


def quota_settled(session, pane, sid):
    """Native Claude API failure: an ended turn, NOT a dead agent.

    OSC 7501 calls API errors `exited`. Verify the exact quota transcript,
    exportable prompt and absence of live tools/background processes before
    admitting this boundary through the normal controller. Never restamp done.
    """
    source = inspect(session, pane)
    if source.get('agent') != 'claude' or source.get('state') not in ('done', 'exited') or source.get('session_id') != sid:
        raise ValueError('quota source conversation changed')
    marks = quota_marks(session, pane)
    signal = fallback.quota_error(source['transcript'], sid)
    if not signal:
        raise ValueError('source has no exact native hard-quota error')
    inputs = runpy.run_path(str(BIN / 'fleet-input.py'))['snapshot']
    view = inputs(session, pane, agent='claude')
    if view.get('state') != 'empty':
        raise ValueError('quota source prompt is not safely exportable')
    quiet_processes(source)  # same live tool/MCP/subagent inventory as hibernation
    if (quota_marks(session, pane) != marks or inspect(session, pane) != source
            or inputs(session, pane, agent='claude') != view
            or fallback.quota_error(source['transcript'], sid) != signal):
        raise ValueError('quota source changed during the boundary check')


def quiet_processes(source, background=None):
    # The same exact executable/endpoint and restartable-MCP contract as
    # hibernation, for both agents (#784/#808/#830).
    sleep = runpy.run_path(str(BIN / 'fleet_worker_life.py'))
    if source['agent'] == 'codex':
        rpc = RPC(source['codex_identity'].get('remote', ''), timeout=5)
        try: sleep['quiet_native_children'](rpc, source['session_id'])
        finally: rpc.close()
    if background is None:
        return sleep['quiet_processes'](source)
    return sleep['quiet_processes'](source, background=background)


def process_start(pid):
    """(state, lstart) — lstart fingerprints the process against pid reuse."""
    try: fields = run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'lstart=']).split(None, 1)
    except (subprocess.CalledProcessError, OSError): return '', ''
    return fields[0], (fields[1] if len(fields) > 1 else '')


def process_cwd(pid):
    try: return os.readlink('/proc/%d/cwd' % pid)
    except OSError: pass
    try: out = run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'])
    except (subprocess.CalledProcessError, OSError): return ''
    return next((line[1:] for line in out.splitlines() if line.startswith('n')), '')


def background_inventory(source):
    """Every non-infrastructure process the source owns, as [{pid,argv,cwd,start}]:
    the hibernation walk, collecting instead of raising on an unverified child.
    Any OTHER veto (a foreign Codex endpoint, an active subagent) still raises."""
    pids = []
    quiet_processes(source, background=pids)
    argv = runpy.run_path(str(BIN / 'fleet_agent_argv.py'))['process_argv']
    entries = []
    for pid in pids:
        state, start = process_start(pid)
        if not start or state.startswith('Z'): continue
        try: args = [str(x) for x in argv(pid)]
        except OSError: args = []
        entries.append(dict(pid=pid, argv=args, cwd=process_cwd(pid), start=start))
    return entries


def claude_background(pid, worktree='', session=''):
    """background_inventory() for a Claude pid named directly (#873):
    fleet-migrate.sh --force-bg has only the pane's Claude pid, its worktree (the
    MCP inventory) and the fleet (the MCP contract)."""
    return background_inventory(dict(pid=int(pid), agent='claude', worktree=worktree or '',
                                     session=session or '', codex_identity={}))


def terminate_background(request, bundle=None, why=None):
    """Stop the processes recorded in <request>/background.json (#871).

    Only a pid whose start fingerprint still matches is signalled — a reused pid
    is never touched. With `why` (fleet-migrate.sh --force-bg, #873) the note is
    printed for the caller's resume nudge; with `bundle` it is appended to the
    package's pickup.md / handoff.md."""
    entries = read(Path(request) / 'background.json', [])
    if not entries: return
    live = []
    for e in entries:
        state, start = process_start(e['pid'])
        if start and start == e.get('start') and not state.startswith('Z'):
            try: os.kill(e['pid'], 15); live.append(e); e['stopped'] = 'SIGTERM'
            except ProcessLookupError: e['stopped'] = 'exited'
        else: e['stopped'] = 'exited'
    deadline = time.time() + 5
    while live and time.time() < deadline:
        time.sleep(0.2)
        live = [e for e in live if process_start(e['pid'])[1] == e['start']
                and not process_start(e['pid'])[0].startswith('Z')]
    for e in live:
        try: os.kill(e['pid'], 9); e['stopped'] = 'SIGKILL'
        except ProcessLookupError: pass
    save(Path(request) / 'background.json', entries)
    if why:
        print(background_note(entries, why), end='')
    if bundle:
        note = background_note(entries)
        for name in ('pickup.md', 'handoff.md'):
            with (Path(bundle) / name).open('a', encoding='utf-8') as out: out.write(note)


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='command', required=True)
    q = sub.add_parser('settled'); q.add_argument('--session', required=True); q.add_argument('--pane', required=True)
    q = sub.add_parser('quota-settled'); q.add_argument('--session', required=True); q.add_argument('--pane', required=True)
    q.add_argument('--sid', required=True)
    q = sub.add_parser('terminate-background'); q.add_argument('request', type=Path)
    q.add_argument('--bundle', type=Path); q.add_argument('--note')
    q = sub.add_parser('background'); q.add_argument('--pid', required=True, type=int)
    q.add_argument('--worktree', default=''); q.add_argument('--session', default='')
    a = p.parse_args()
    if a.command == 'settled': settled(a.session, a.pane)
    elif a.command == 'quota-settled': quota_settled(a.session, a.pane, a.sid)
    elif a.command == 'terminate-background': terminate_background(a.request, a.bundle, a.note)
    else: print(json.dumps(claude_background(a.pid, a.worktree, a.session), ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError) as error:
        print('fleet-transfer-source: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__),
              file=sys.stderr)
        sys.exit(1)
