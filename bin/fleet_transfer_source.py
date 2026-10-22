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
import shlex
import shutil
import subprocess
import sys
import time
import tempfile

import fleet_session_fallback as fallback

BIN = Path(__file__).absolute().parent
ACCOUNT = runpy.run_path(str(BIN / '.fleet-account.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
RUNTIME = runpy.run_path(str(BIN / 'fleet-codex-runtime.py'))
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
    user_index = next(i for i, line in enumerate(rows) if json.loads(line).get('uuid') == auth['user_message_uuid'])
    for line in rows[user_index + 1:]:
        row = json.loads(line)
        if row.get('type') != 'assistant' or row.get('isSidechain'):
            continue
        content = row.get('message', {}).get('content', [])
        for b in content if isinstance(content, list) else []:
            if (isinstance(b, dict) and b.get('type') == 'tool_use' and b.get('name') == 'ScheduleWakeup'
                    and isinstance(b.get('input'), dict) and b['input'].get('stop')):
                raise ValueError('a later scheduler cancellation supersedes this authorization; reconcile task intent')
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
        if len(tools) != 1 or tools[0].get('input') != inp or inp.get('prompt') != invocation or inp.get('stop'):
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


def quiet_processes(source, background=None, rpc_timeout=5):
    # The same exact executable/endpoint and restartable-MCP contract as
    # hibernation, for both agents (#784/#808/#830).
    sleep = runpy.run_path(str(BIN / 'fleet_worker_life.py'))
    if source['agent'] == 'codex':
        rpc = RPC(source['codex_identity'].get('remote', ''), timeout=5)
        try: sleep['quiet_native_children'](rpc, source['session_id'])
        finally: rpc.close()
    if rpc_timeout != 5:
        return sleep['quiet_processes'](source, background=background, rpc_timeout=rpc_timeout)
    if background is None:
        return sleep['quiet_processes'](source)
    return sleep['quiet_processes'](source, background=background)

def process_start(pid):
    """(state, lstart) — lstart fingerprints the process against pid reuse."""
    try: fields = run(['ps', '-p', str(pid), '-o', 'stat=', '-o', 'lstart=']).split(None, 1)
    except (subprocess.CalledProcessError, OSError): return '', ''
    return fields[0], (fields[1] if len(fields) > 1 else '')


def missing_hook_paths(argv):
    """Read only native inline hook commands, never prompts or credentials."""
    missing = set()
    for value in argv:
        if not value.startswith('hooks.'):
            continue
        for quoted in re.findall(r'command\s*=\s*("(?:[^"\\]|\\.)*")', value):
            command = shlex.split(json.loads(quoted))
            for word in command:
                path = Path(word)
                if (path.is_absolute() and path.suffix in ('.py', '.sh')
                        and not path.exists()):
                    missing.add(str(path))
    return sorted(missing)


def repairable_loop(value, source):
    """Only a proven pre-send missing-helper pause may regain its old timer."""
    if (value.get('status') != 'paused' or value.get('thread_id') != source['session_id']
            or value.get('home') != source['home'] or value.get('worktree') != source['worktree']
            or not value.get('id') or value.get('pending_delivery')):
        raise ValueError('loop is not this exact paused maintenance owner')
    if (value.get('last_attempt', {}).get('state') != 'accepted'
            or not re.fullmatch(r"\[Errno 2\] No such file or directory: '[^']+/bin/fleet-input\.py'",
                                value.get('detail', ''))):
        raise ValueError('loop delivery is unknown or not a pre-send missing-helper failure')
    if value['schedule'].get('jobs') or type(value['schedule'].get('interval_seconds')) is not int:
        raise ValueError('maintenance requires the original single interval timer')


def native_hook_flags(source):
    life = runpy.run_path(str(BIN / 'fleet_worker_life.py'))
    rows = TRANSFER['process_rows']()
    pending, children, flags = [source['pid']], [], []
    while pending:
        pid = pending.pop()
        children.append(pid)
        flags.extend(a for a in life['ARGV']['process_argv'](pid) if a.startswith('hooks.'))
        pending.extend(p for p, row in rows.items() if row[0] == pid and p not in children)
    return flags, children


def repair_model_menu(screen):
    """A narrow native reminder with an explicit back action, never approval."""
    lines = [s.strip() for s in screen.splitlines() if s.strip()]
    if len(lines) < 6:
        return None
    tail = lines[-6:]
    if (tail[0] == 'Approaching rate limits'
            and re.fullmatch(r'Switch to [A-Za-z0-9_.-]+ for lower credit usage\?', tail[1])
            and re.fullmatch(r'[›❯] 1\. Switch to [A-Za-z0-9_.-]+\s+Fast and affordable model for easier tasks\.', tail[2])
            and tail[3] == '2. Keep current model'
            and tail[4] == '3. Keep current model (never show again)  Hide future rate limit reminders about switching models'
            and tail[5] == 'enter select · esc back'):
        return screen.strip()
    return None


def repair_menu_cancel(session, pane, fid, sid, proof, receipt):
    """One external back action, followed by an independent composer proof."""
    if receipt.exists():
        raise ValueError('model reminder return already attempted; no repeated keys')
    if repair_check(session, pane, fid, sid, allow_menu=True) != proof:
        raise ValueError('model reminder changed before return')
    with receipt.open('x') as out:
        os.chmod(receipt, 0o600)
        json.dump(dict(state='cancelling', proof=proof), out)
        out.flush(); os.fsync(out.fileno())
    directory = os.open(receipt.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    run(['tmux', '-L', session, 'send-keys', '-t', proof['source']['pane'], 'Escape'],
        env=dict(os.environ, FLEET_ALLOW_SENDKEYS='1'))
    time.sleep(0.2)
    after = repair_check(session, pane, fid, sid)
    fixed = lambda value: {k:v for k,v in value.items() if k not in ('input', 'model_menu')}
    if fixed(after) != fixed(proof):
        raise ValueError('source changed while returning from model reminder')
    save(receipt, dict(state='returned', proof=proof, after=after))
    return after


def repair_check(session, pane, fid, sid, allow_menu=False):
    source = inspect(session, pane)
    opt = lambda fmt: run(['tmux', '-L', session, 'display-message', '-p', '-t', source['pane'], fmt])
    if source['agent'] != 'codex' or source['session_id'] != sid or opt('#{@fleet_id}') != fid:
        raise ValueError('maintenance source FID/SID/agent changed')
    if opt('#{window_panes}') != '1' or opt('#{@parked}#{@park_start}#{@agent_transfer_request}'):
        raise ValueError('maintenance source has another pane/transition')
    if opt('#{@handoff_armed}') or int(opt('#{@agent_transfer_until}') or 0) > time.time():
        raise ValueError('source has an unresolved transition')
    from fleet_native_proc import process
    flags, children = native_hook_flags(source)
    missing = missing_hook_paths(flags)
    if not missing:
        raise ValueError('native process has no proven missing inline hook')
    store = BIN.resolve().parent.parent
    for item in missing:
        try:
            relative = Path(item).resolve().relative_to(store)
        except ValueError:
            raise ValueError('missing hook is outside the managed release store') from None
        if (not re.fullmatch('[0-9a-f]{12,40}', relative.parts[0])
                or not (BIN.resolve().parent/Path(*relative.parts[1:])).is_file()):
            raise ValueError('current release cannot repair the missing managed hook')
    t = native_thread(source)
    codex_quiet(t)
    if t.get('status', {}).get('type') != 'idle':
        raise ValueError('maintenance requires native idle')
    view = runpy.run_path(str(BIN / 'fleet-input.py'))['snapshot'](session, source['pane'], agent='codex')
    menu = None
    if view.get('state') != 'empty' or view.get('busy'):
        if allow_menu:
            menu = repair_model_menu(run(['tmux', '-L', session, 'capture-pane', '-p', '-t', source['pane']]))
        if not menu:
            raise ValueError('maintenance input is not proven empty; source retained')
    rpc = RPC(source['codex_identity']['remote'], timeout=10)
    try:
        if rpc.initialized.get('codexHome') != source['home']:
            raise ValueError('native runtime account HOME changed')
        queue = rpc.call('thread/queue/list', {'threadId': sid})
        if queue.get('data') != [] or queue.get('nextCursor'):
            raise ValueError('native queued input must remain with its source')
    finally:
        rpc.close()
    import fleet_session_gate as gate
    if any(r.get('state') in ('queued', 'trying', 'native', 'waking') for r in gate.records(fid)):
        raise ValueError('durable admitted input is still pending')
    loop = None
    if source.get('previous'):
        path = Path(source['previous']).parent / 'loop/state.json'
        if path.exists():
            module = runpy.run_path(str(BIN / 'fleet-loop.py'))
            with module['locked'](path) as value:
                module['current'](value)
                repairable_loop(value, source)
                if value.get('controller_pid') not in children:
                    raise ValueError('old loop controller is not owned by this source')
                loop = dict(path=str(path), before=value)
    try:
        quiet_processes(source, rpc_timeout=30)
    except (TimeoutError, subprocess.TimeoutExpired):
        raise ValueError('maintenance strict process proof timed out; source retained') from None
    result = dict(source=source, fid=fid, birth=process(source['pid']), input=view,
                processes=[process(pid) for pid in children],
                missing_hooks=sorted(missing), loop=loop,
                last_turn=(t.get('turns') or [{}])[-1].get('id'))
    if menu:
        result['model_menu'] = menu
    return result


def repair_target_home(source):
    """Resolve a live exact mirror; still ask the normal target-auth resolver."""
    home = Path(source['home'])
    conf = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet')))
    recovery = None
    if home.parent == conf/'cred-proxy/codex-homes':
        fields = dict(line.split('=', 1) for line in
                      (conf/'cred-proxy/sessions'/home.name).read_text().splitlines() if '=' in line)
        recovery = dict(sid=home.name, **{k: fields[k] for k in ('provider', 'route', 'account')})
        if fields.get('route') == 'central':
            recovery['hub_id'] = fields['hub_id']
    real, _ = ACCOUNT['codex_real_home'](str(home), recovery=recovery)
    auth = json.loads(run(['bash', BIN/'fleet-account.sh', 'target-auth', '--agent', 'codex', '--home', real]))
    if auth.get('verdict') != 'ok':
        raise ValueError('maintenance target authentication is not verified')
    return real


def target_runtime_preflight():
    return RUNTIME['target_preflight'](root=BIN.parent)


def repair_loop_restore(proof, source):
    """Resume the original paused record after its old controller is gone."""
    if not proof:
        return None
    module = runpy.run_path(str(BIN/'fleet-loop.py'))
    path, before = Path(proof['path']), proof['before']
    old_pid = before['controller_pid']
    try:
        os.kill(old_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise ValueError('original loop controller still lives; no timer rebind')
    with module['locked'](path) as current:
        for key in ('id', 'generation', 'active_record', 'active_generation',
                    'last_attempt', 'deliveries', 'schedule', 'thread_id', 'home'):
            if current.get(key) != before.get(key):
                raise ValueError('loop ownership or delivery changed during maintenance')
        if current.get('status') not in ('paused', 'stopped'):
            raise ValueError('loop has an unknown maintenance outcome')
        value = dict(current, status='active', driver='quotawatch', controller_pid=0,
                     pane_pid=int(run(['tmux','-L',source['session'],'display-message','-p',
                                       '-t',source['pane'],'#{pane_pid}'])),
                     socket=source['codex_identity']['remote'][7:], home=source['home'],
                     detail='Exact same-thread hook maintenance; original timer resumed')
        value['fleet'] = dict(value['fleet'], window_id=source['window'], pane_id=source['pane'])
        # A missed interval is never replayed; preserve the cadence and the one ID.
        value['schedule'] = dict(value['schedule'], next_run_at=time.time()+value['schedule']['interval_seconds'])
        value.update(due_since=None, deferred_reason=None)
        module['current'](value)
        module['save'](path, value)
        return {k: value[k] for k in ('id', 'status', 'thread_id', 'schedule', 'driver')}


def repair_hooks(session, pane, fid, sid, dry=False):
    """The caller holds transition lock/lease; this lock also fences admission."""
    import fleet_session_gate as gate
    from fleet_native_proc import process
    with gate.lock(fid):
        root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet')))/'handoffs'
        for path in root.glob('hook-repair-*/receipt.json'):
            old = json.loads(path.read_text())
            if old.get('proof', {}).get('fid') == fid and old.get('state') not in ('resumed', 'refused'):
                raise ValueError('prior maintenance completion is unknown; inspect its receipt, never relaunch')
        proof = repair_check(session, pane, fid, sid, allow_menu=True)
        source = proof['source']
        home = repair_target_home(source)
        runtime_proof = target_runtime_preflight()
        if dry:
            print(json.dumps(dict(state='ready', fid=fid, sid=sid, missing_hooks=proof['missing_hooks'],
                                  target_runtime=runtime_proof,
                                  loop_id=(proof['loop'] or {}).get('before', {}).get('id'),
                                  action='return-model-reminder-then-revalidate' if proof.get('model_menu') else 'resume-same-thread')))
            return
        directory = Path(tempfile.mkdtemp(prefix='hook-repair-', dir=str(root)))
        save(directory/'receipt.json', dict(state='preparing', proof=proof))
        stage = 'preparing'
        retained = None
        try:
            shutil.copyfile(source['transcript'], directory/'source.jsonl')
            before = (directory/'source.jsonl').read_bytes()
            for name, argv in [('unstaged.patch',['diff','--binary']), ('index.patch',['diff','--cached','--binary']),
                               ('git-state.txt',['status','--porcelain=v1','--branch'])]:
                (directory/name).write_text(run(['git','-C',source['worktree'],*argv])+'\n')
            runtime_proof = target_runtime_preflight()
            save(directory/'target-runtime.json', runtime_proof)
            fresh = repair_check(session, pane, fid, sid, allow_menu=True)
            if fresh != proof or repair_target_home(source) != home:
                raise ValueError('maintenance source changed during preparation')
            if proof.get('model_menu'):
                stage = 'returning-model-menu'
                save(directory/'receipt.json', dict(state=stage, proof=proof))
                proof = repair_menu_cancel(session, pane, fid, sid, proof, directory/'model-menu-return.json')
                source = proof['source']
                if Path(source['transcript']).read_bytes() != before or repair_target_home(source) != home:
                    raise ValueError('source transcript/account changed during model reminder return')
            tm = lambda *a: run(['tmux','-L',session,*a])
            stage = 'exiting'
            save(directory/'receipt.json', dict(state=stage, proof=proof))
            retained = tm('display-message','-p','-t',source['pane'],'#{remain-on-exit}') or 'off'
            tm('set-option','-w','-t',source['window'],'@agent_transfer_until',str(int(time.time())+180))
            tm('set-option','-p','-t',source['pane'],'remain-on-exit','on')
            tm('set-option','-w','-t',source['window'],'@wrap_quiet','1')
            # Empty composer was proven twice. No Escape, C-u, replay or forced kill.
            tm('send-keys','-t',source['pane'],'-l','\x1b[200~/exit\x1b[201~')
            time.sleep(0.6)
            tm('send-keys','-t',source['pane'],'Enter')
            deadline = time.monotonic()+30
            while process_start(source['pid'])[1] and time.monotonic()<deadline:
                if process(source['pid']) != proof['birth']:
                    raise ValueError('source PID was reused during maintenance')
                time.sleep(0.2)
            if process_start(source['pid'])[1]:
                raise ValueError('source did not exit; maintenance is not retried')
            deadline = time.monotonic()+10
            while True:
                live = []
                for old in proof.get('processes', []):
                    stat, birth = process_start(old['pid'])
                    if birth and not stat.startswith('Z') and process(old['pid']) == old:
                        live.append(old['pid'])
                if not live:
                    break
                if time.monotonic() >= deadline:
                    raise ValueError('source descendants still live; no new writer started')
                time.sleep(0.2)
            # Source hook exit must not have accepted a racing user/peer turn.
            data = Path(source['transcript']).read_bytes()
            if not data.startswith(before) or any(
                    json.loads(line).get('type') in ('response_item', 'event_msg')
                    for line in data[len(before):].splitlines() if line.strip()):
                raise ValueError('native transcript changed during exit; inspect retained evidence')
            # Native death can precede wrapper credential revocation/cleanup.
            # Wait for that owner; never respawn over a still-live wrapper.
            deadline = time.monotonic()+10
            while tm('display-message','-p','-t',source['pane'],'#{pane_dead}') != '1':
                pid = tm('display-message','-p','-t',source['pane'],'#{pane_pid}')
                try:
                    run(['python3', BIN/'.fleet-transfer.py', 'process', 'shell', pid])
                    break
                except (OSError, subprocess.SubprocessError):
                    if time.monotonic() >= deadline:
                        raise ValueError('source wrapper has not finished cleanup; no repeated launch') from None
                    time.sleep(0.1)
            if tm('display-message','-p','-t',source['pane'],'#{@fleet_id}') != fid:
                raise ValueError('source FID changed after exit')
            launcher = str(BIN/'fleet-session-wrap.sh')
            args = [launcher,'--agent','codex','--codex-home',home,'--resume',sid]
            command = 'exec '+shlex.join(args)
            stage = 'starting'
            save(directory/'receipt.json', dict(state=stage, proof=proof, launch=args))
            tm('respawn-pane','-k','-t',source['pane'],'-c',source['worktree'],command)
            deadline = time.monotonic()+60
            target = None
            while time.monotonic()<deadline:
                try:
                    candidate = inspect(session, source['pane'])
                    if candidate['pid'] != source['pid'] and candidate['session_id'] == sid:
                        target = candidate
                        break
                except (OSError, ValueError, subprocess.SubprocessError):
                    pass
                time.sleep(1)
            if target is None:
                raise ValueError('same native SID not bound; no repeated launch')
            if tm('display-message','-p','-t',target['pane'],'#{@fleet_id}') != fid:
                raise ValueError('target FID mismatch')
            rpc = RPC(target['codex_identity']['remote'], timeout=10)
            try:
                runtime = rpc.initialized
                RUNTIME['require_capability'](rpc)
                t = rpc.call('thread/read', {'threadId': sid, 'includeTurns': False})['thread']
                if t.get('id') != sid or Path(t['cwd']).resolve() != Path(source['worktree']).resolve():
                    raise ValueError('resumed native thread/worktree changed')
            finally:
                rpc.close()
            flags, _ = native_hook_flags(target)
            if (missing_hook_paths(flags) or not all(any(name in value for value in flags) for name in
                    ('fleet-codex-session.py', 'bash-guard.py', 'base-readonly-guard.py'))):
                raise ValueError('resumed native hook guards are not verified')
            loop = repair_loop_restore(proof['loop'], target)
            receipt = dict(state='resumed', fid=fid, sid=sid, target=target, loop=loop,
                           at=time.time(), proof=proof, initialize=runtime)
            save(directory/'receipt.json', receipt)
            stage = 'resumed'
            print(json.dumps(dict(state='resumed', fid=fid, sid=sid, receipt=str(directory/'receipt.json'), loop=loop)))
        except Exception as error:
            save(directory/'receipt.json', dict(state='refused' if stage == 'preparing' else 'recovery',
                                                stage=stage, proof=proof, reason=str(error)))
            raise
        finally:
            # No source restart or timer rearm on unknown outcomes.
            run(['tmux','-L',session,'set-option','-wu','-t',source['window'],'@agent_transfer_until'])
            if stage == 'resumed' and retained is not None:
                run(['tmux','-L',session,'set-option','-p','-t',source['pane'],'remain-on-exit',retained])

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
    q = sub.add_parser('repair-hooks'); q.add_argument('--session', required=True); q.add_argument('--pane', required=True)
    q.add_argument('--fid', required=True); q.add_argument('--sid', required=True); q.add_argument('--dry-run', action='store_true')
    for command in ('quota-dialog-check', 'quota-dialog-stop'):
        q = sub.add_parser(command); q.add_argument('--session', required=True); q.add_argument('--pane', required=True)
        q.add_argument('--sid', required=True)
    q = sub.add_parser('terminate-background'); q.add_argument('request', type=Path)
    q.add_argument('--bundle', type=Path); q.add_argument('--note')
    q = sub.add_parser('background'); q.add_argument('--pid', required=True, type=int)
    q.add_argument('--worktree', default=''); q.add_argument('--session', default='')
    a = p.parse_args()
    if a.command == 'settled': settled(a.session, a.pane)
    elif a.command == 'repair-hooks': repair_hooks(a.session, a.pane, a.fid, a.sid, a.dry_run)
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
