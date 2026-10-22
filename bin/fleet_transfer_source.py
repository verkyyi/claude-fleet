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
import hashlib
import re
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

def source_marks(session, pane):
    # Tabs are the shared gate's portable tmux field delimiter. Older tmux
    # renders control separators (US) visibly instead of returning their byte.
    fmt = '\t'.join('#{@' + k + '}' for k in
                       ('claude_state', 'claude_state_src', 'agent_status', 'claude_needs',
                        'claude_wait', 'loop', 'parked'))
    fields = run(['tmux', '-L', session, 'display-message', '-p', '-t', pane, fmt + '\tEND']).split('\t')
    if len(fields) != 8 or fields.pop() != 'END':
        raise ValueError('quota source metadata is incomplete')
    return fields

def quota_loop_replacement(source, mark):
    """External authorization to replace ONE session timer, never a live export.

    Native /exit must still destroy the old process/timer before any target.
    Durable records use their separate single-owner road, not this permission.
    """
    path = os.environ.get('FLEET_QUOTA_LOOP_REPLACEMENT', '')
    if not path:
        raise ValueError('quota loop requires an explicit external replacement specification')
    from fleet_transfer_cron import check_durable_store
    from fleet_transfer_durable import proc_start
    fid = run(['tmux', '-L', source['session'], 'display-message', '-p', '-t', source['pane'], '#{@fleet_id}'])
    if not fid or check_durable_store(fid, source['pid']):
        raise ValueError('external session timer replacement cannot carry a durable journal')
    previous = run(['tmux', '-L', source['session'], 'display-message', '-p', '-t', source['pane'], '#{@handoff_manifest}'])
    if previous and (Path(previous).parent / 'loop/state.json').exists():
        raise ValueError('existing Fleet timer must be resolved by its own controller')
    # The mark is only a classification hint, never current schedule evidence.
    # Refuse lossy parsing, Cron IDs, parked ownership, or mixed/unknown kinds.
    if mark and not re.fullmatch(r'kind=wakeup next=[0-9]+ ttl=[0-9]+', mark):
        raise ValueError('external replacement supports only a single session wakeup; unknown/cron mark refused')
    data = Path(path).read_bytes()
    raw = json.loads(data)
    if not isinstance(raw, dict) or not isinstance(raw.get('quota_replacement'), dict):
        raise ValueError('quota replacement needs a specification and authorization object')
    auth = raw['quota_replacement']
    expected = dict(version=1, fid=fid, session_id=source['session_id'], pid=int(source['pid']),
                    proc_start=proc_start(source['pid']))
    if not expected['proc_start'] or any(auth.get(k) != v for k, v in expected.items()):
        raise ValueError('quota replacement source identity or process fingerprint changed')
    if 'jobs' in raw or 'native_source' in raw or 'next_run_at' in raw:
        raise ValueError('replacement is a user specification, not a native export or replay deadline')
    invocation = auth.get('invocation', '')
    if not isinstance(invocation, str) or not invocation or '\n' in invocation or '\r' in invocation:
        raise ValueError('need an exact single-line authorized loop invocation')
    # Original user intent is provenance, not proof the old timer is still live.
    matches = []
    rows = Path(source['transcript']).read_text(encoding='utf-8').splitlines()
    for line in rows:
        row = json.loads(line)
        if row.get('uuid') == auth.get('user_message_uuid'):
            content = row.get('message', {}).get('content')
            text = content if isinstance(content, str) else '\n'.join(
                b.get('text', '') for b in (content or []) if isinstance(b, dict) and b.get('type') == 'text')
            if row.get('type') != 'user' or row.get('isSidechain'):
                raise ValueError('quota loop authorization is not an exact original user message')
            matches.append((row, text))
    if not auth.get('user_message_uuid') or len(matches) != 1:
        raise ValueError('missing or ambiguous original user loop authorization')
    _, text = matches[0]
    match = re.fullmatch(r'/loop ([1-9][0-9]*)([smhd]) ([^\r\n]+)', invocation)
    labels = [invocation]
    if auth.get('basis', 'user-loop') == 'user-loop':
        if not match or text != invocation:
            raise ValueError('need an exact user-authorized /loop interval and prompt; unknown loops refuse')
        seconds = int(match[1]) * dict(s=1, m=60, h=3600, d=86400)[match[2]]
        if raw.get('interval_seconds') != seconds or raw.get('prompt') != match[3]:
            raise ValueError('replacement prompt/cadence differs from the authorized invocation')
        labels.append('/loop ' + match[3])
    elif auth.get('basis') == 'historical-wakeup-spec':
        # An explicit operator replacement can retain a confirmed historical
        # rearm specification, without presenting it as current native membership.
        # The original slash-command user message separately supplies intent.
        commands = re.findall(r'<command-name>([^<]+)</command-name>', text)
        if (commands != [invocation] or raw.get('prompt') != invocation
                or auth.get('user_message_sha256') != hashlib.sha256(text.encode()).hexdigest()
                or not re.fullmatch(r'/[A-Za-z0-9_:-]+', invocation)):
            raise ValueError('historical rearm must match the exact original user command and hash')
        from fleet_loop_mark import claude_tool_results
        calls = list(claude_tool_results(rows, ('ScheduleWakeup', 'CronCreate', 'CronDelete'), strict=True))
        if not calls or calls[-1][0] != 'ScheduleWakeup':
            raise ValueError('latest confirmed scheduler specification is not a session wakeup')
        _, inp, response, _, result_at = calls[-1]
        uses = [json.loads(line) for line in rows if json.loads(line).get('uuid') == auth.get('schedule_message_uuid')]
        if len(uses) != 1 or uses[0].get('type') != 'assistant' or uses[0].get('isSidechain'):
            raise ValueError('missing exact historical schedule message')
        user_index = next(i for i, line in enumerate(rows) if json.loads(line).get('uuid') == auth['user_message_uuid'])
        use_index = next(i for i, line in enumerate(rows) if json.loads(line).get('uuid') == auth['schedule_message_uuid'])
        if user_index >= use_index:
            raise ValueError('historical rearm predates its authorization provenance')
        tools = [b for b in uses[0].get('message', {}).get('content', [])
                 if isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('id') == auth.get('schedule_tool_use_id')
                 and b.get('name') == 'ScheduleWakeup']
        mutations = [(row.get('uuid'), b.get('id')) for row in map(json.loads, rows)
                     if row.get('type') == 'assistant' and not row.get('isSidechain')
                     for b in row.get('message', {}).get('content', []) if isinstance(b, dict)
                     and b.get('type') == 'tool_use' and b.get('name') in ('ScheduleWakeup', 'CronCreate', 'CronDelete')]
        if not mutations or mutations[-1] != (auth.get('schedule_message_uuid'), auth.get('schedule_tool_use_id')):
            raise ValueError('a later scheduler mutation superseded the selected historical specification')
        if len(tools) != 1 or tools[0].get('input') != inp or inp.get('prompt') != invocation:
            raise ValueError('selected historical schedule is not the latest confirmed specification')
        if (not isinstance(response, dict) or not result_at or not response.get('scheduledFor')
                or response.get('clampedDelaySeconds') != raw.get('interval_seconds')):
            raise ValueError('historical schedule has no confirmed cadence receipt')
    else:
        raise ValueError('unknown quota replacement authorization basis')
    # Validate limits without inventing a next-fire timestamp in the proof.
    runpy.run_path(str(BIN / 'fleet-loop.py'))['spec'](raw)
    return dict(mode='authorized-replacement', authorization=auth, path=str(Path(path).resolve()),
                sha256=hashlib.sha256(data).hexdigest(), native_exit_invocations=labels)


def quota_pending_marks(fields):
    if any(fields[i] for i in (3, 4, 6)):
        return True
    if fields[5] and not os.environ.get('FLEET_QUOTA_LOOP_REPLACEMENT'):
        return True
    return False

def quota_marks(session, pane):
    fields = source_marks(session, pane)
    native = json.loads(fields[2] or '{}')
    if not isinstance(native, dict):
        raise ValueError('quota native status is invalid')
    ended = (fields[0] in ('done', 'exited') and fields[1] in ('7501', 'hook')
             and (native.get('state') == 'error' or (fields[0] == 'done' and native.get('state') in ('idle', 'done'))))
    if not ended or quota_pending_marks(fields):
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
    # OSC errors are not Stop acknowledgements. The live module must separately
    # prove the main turn stopped and the underlying prompt empty, including
    # after a person cancels the quota menu without ever running a Stop hook.
    quota_prompt_proof(session, pane)
    # A network/native tool need not own a child process. Keep unreturned tool
    # calls (and unreadable evidence) fenced even if the main turn looks stopped.
    from fleet_pending_tool import pending
    if pending(source['transcript'], strict=True)[0] != 1:
        raise ValueError('quota source has an unfinished tool or unknown tool transcript')
    quiet_processes(source)  # same live tool/MCP/subagent inventory as hibernation
    quota_schedules(source)
    quota_prompt_proof(session, pane)
    if (quota_marks(session, pane) != marks or inspect(session, pane) != source
            or inputs(session, pane, agent='claude') != view
            or pending(source['transcript'], strict=True)[0] != 1
            or fallback.quota_error(source['transcript'], sid) != signal):
        raise ValueError('quota source changed during the boundary check')


def quota_dialog(screen):
    """Only the native quota menu, including its bottom input guide.

    Escape cancels this menu without selecting an upgrade or auto-resume. An
    armed auto-resume, unknown option, truncated menu or another dialog refuses.
    The transcript and OSC state are independently required by the caller.
    """
    title = 'What do you want to do?'
    if title not in screen:
        raise ValueError('no native quota choice dialog')
    body = screen.rsplit(title, 1)[1].strip()
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    if not lines or lines[-1] != 'Enter to confirm · Esc to cancel':
        raise ValueError('quota dialog input guide changed')
    labels, selected = [], 0
    for line in lines[:-1]:
        m = re.fullmatch(r'(❯ )?(\d+)\. (.+)', line)
        if not m or int(m[2]) != len(labels) + 1:
            raise ValueError('quota dialog options are not fully visible')
        selected += bool(m[1])
        label = m[3]
        if (label != 'Stop and wait for limit to reset' and label != 'Upgrade your plan'
                and not re.fullmatch(r'Wait here, then continue automatically at [^\r\n]+', label)):
            raise ValueError('quota dialog option changed or auto-resume is armed')
        labels.append(label)
    if selected != 1 or labels.count('Stop and wait for limit to reset') != 1 or len(labels) != len(set(labels)):
        raise ValueError('quota dialog is incomplete')
    return hashlib.sha256(body.encode()).hexdigest()


def quota_schedules(source):
    if os.environ.get('FLEET_QUOTA_LOOP_REPLACEMENT'):
        return quota_loop_replacement(source, source_marks(source['session'], source['pane'])[5])
    return runpy.run_path(str(BIN / '.fleet-transfer-norepo.py'))['schedule_readiness'](
        source['session'], source['pane'], source['transcript'], source['pid'], source['session_id'], '', 'claude')



def quota_prompt_proof(session, pane):
    # Reuse the existing native read-only park.v1 proof: no active main turn,
    # and $.prompt.read().text is empty even beneath a modal. The visible
    # choice cursor cannot prove this. Old/unresponsive modules refuse safely.
    from fleet_session_gate import park_proof
    socket = run(['tmux', '-L', session, 'display-message', '-p', '-t', pane, '#{socket_path}'])
    proof = park_proof(dict(agent='claude', sock=session, socket_path=socket, pane=pane))
    if not isinstance(proof, dict) or proof.get('ok') is not True:
        raise ValueError('native quota prompt/turn is not proven empty and stopped: ' + str(proof.get('why', 'unknown') if isinstance(proof, dict) else 'unknown'))
    return proof

def quota_dialog_check(session, pane, sid):
    source = inspect(session, pane)
    if source.get('agent') != 'claude' or source.get('state') != 'needs' or source.get('session_id') != sid:
        raise ValueError('quota dialog source conversation changed')
    marks = source_marks(session, pane)
    native = json.loads(marks[2] or '{}')
    if not isinstance(native, dict):
        raise ValueError('quota native status is invalid')
    if (marks[0:2] != ['needs', '7501'] or quota_pending_marks(marks)
            or native.get('state') != 'blocked' or native.get('app') != 'claude-code'
            or native.get('kind') or native.get('msg') != 'dialog open'):
        raise ValueError('source is not a native quota dialog without pending work')
    signal = fallback.quota_error(source['transcript'], sid)
    if not signal:
        raise ValueError('source has no exact native hard-quota error')
    # No typing over an attached person, including a live terminal view.
    clients = run(['tmux', '-L', session, 'list-clients', '-F', '#{client_activity} #{window_id}'])
    for row in clients.splitlines():
        activity, _, window = row.partition(' ')
        if window == source['window'] and (not activity.isdigit() or time.time() - int(activity) <= 30):
            raise ValueError('a person is using the quota dialog')
    screen = run(['tmux', '-L', session, 'capture-pane', '-p', '-t', pane])
    fingerprint = quota_dialog(screen)
    quiet_processes(source)
    # Use the existing scheduler authority even for a worktree source; an empty
    # @loop alone does not prove that native Cron/durable work is absent.
    quota_schedules(source)
    prompt = quota_prompt_proof(session, pane)
    if inspect(session, pane) != source or source_marks(session, pane) != marks:
        raise ValueError('quota dialog changed during the boundary check')
    if quota_dialog(run(['tmux', '-L', session, 'capture-pane', '-p', '-t', pane])) != fingerprint:
        raise ValueError('quota dialog changed during the boundary check')
    if fallback.quota_error(source['transcript'], sid) != signal:
        raise ValueError('quota transcript changed during the boundary check')
    return dict(source=source, marks=marks, signal=signal, fingerprint=fingerprint, screen=screen, native_prompt=prompt)

def quota_dialog_stop(session, pane, sid):
    """Called ONLY under the controller's transfer lock and rotation lease.

    Write ahead of the one Escape. An uncertain dismissal is never retried.
    Escape preserves any hidden draft; it must then be proved empty by the same
    quota_settled check as every later controller boundary. No state is stamped.
    """
    evidence = quota_dialog_check(session, pane, sid)
    root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))
    root = root / 'quota-dialog-stop'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = hashlib.sha256(json.dumps([session, sid]).encode()).hexdigest()
    path = root / (key + '.json')
    evidence.update(state='dismissing', at=time.time())
    try:
        with path.open('x') as out:
            os.chmod(path, 0o600)
            json.dump(evidence, out, ensure_ascii=False)
            out.flush(); os.fsync(out.fileno())
        directory = os.open(root, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)
    except FileExistsError:
        raise ValueError('quota dialog dismissal already attempted; inspect retained evidence') from None
    try:
        # Recheck after write-ahead and immediately before the only keypress.
        if quota_dialog_check(session, pane, sid) != {k: v for k, v in evidence.items() if k not in ('state', 'at')}:
            raise ValueError('quota dialog changed before cancellation')
        run(['tmux', '-L', session, 'send-keys', '-t', pane, 'Escape'],
            env=dict(os.environ, FLEET_ALLOW_SENDKEYS='1'))
        deadline = time.monotonic() + 5
        while True:
            after = inspect(session, pane)
            if {k:v for k,v in after.items() if k != 'state'} != {k:v for k,v in evidence['source'].items() if k != 'state'}:
                raise ValueError('quota source identity changed after cancellation')
            if after.get('state') in ('done', 'exited'):
                quota_settled(session, pane, sid)
                evidence.update(state='settled', after=after,
                                screen_after=run(['tmux', '-L', session, 'capture-pane', '-p', '-t', pane]))
                save(path, evidence)
                return
            if time.monotonic() >= deadline:
                raise ValueError('native quota dialog did not settle; source retained, no retry')
            time.sleep(0.1)
    except Exception as error:
        evidence.update(state='recovery', reason=str(error))
        save(path, evidence)
        raise


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
    for command in ('quota-dialog-check', 'quota-dialog-stop'):
        q = sub.add_parser(command); q.add_argument('--session', required=True); q.add_argument('--pane', required=True)
        q.add_argument('--sid', required=True)
    q = sub.add_parser('terminate-background'); q.add_argument('request', type=Path)
    q.add_argument('--bundle', type=Path); q.add_argument('--note')
    q = sub.add_parser('background'); q.add_argument('--pid', required=True, type=int)
    q.add_argument('--worktree', default=''); q.add_argument('--session', default='')
    a = p.parse_args()
    if a.command == 'settled': settled(a.session, a.pane)
    elif a.command == 'quota-settled': quota_settled(a.session, a.pane, a.sid)
    elif a.command == 'quota-dialog-check': quota_dialog_check(a.session, a.pane, a.sid)
    elif a.command == 'quota-dialog-stop': quota_dialog_stop(a.session, a.pane, a.sid)
    elif a.command == 'terminate-background': terminate_background(a.request, a.bundle, a.note)
    else: print(json.dumps(claude_background(a.pid, a.worktree, a.session), ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError) as error:
        print('fleet-transfer-source: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__),
              file=sys.stderr)
        sys.exit(1)
