#!/usr/bin/env python3
# bin-inventory: 人工入口 — 旧 Codex 会话一次续接（#4775），docs/dev/NATIVE-OBSERVE.md
"""One-shot continuation of a legacy Codex session whose fixed hooks are gone.

--preflight reads (never writes) the idle original and prints a manifest with
the original message; --apply stops it, resumes the SAME SID through the current
standard launcher and hands the message over as the new lifetime's first turn.
Intent is saved before each effect; replay never retries one, and only the
message stages may be re-entered, settling by receipt (docs/dev/NATIVE-OBSERVE.md).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid

import fleet_native_observe as observe
import fleet_agent_mcp as MCP
from fleet_agent_argv import process_env

BIN = Path(__file__).resolve().parent
require = observe.require
launch = observe.launch
authority = observe.authority
SLEEP = runpy.run_path(str(BIN / 'fleet_worker_life.py'))
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
ROUTING = ('@fleet_id', '@repo', '@issue', '@raw', '@worktree', '@task', '@origin',
           '@origin_fid', '@agent_def', '@fleet_role', '@launch', '@launch_receipt')
CONFLICTS = ('@handoff_armed', '@agent_transfer_request', '@loop')
UNCONFIRMED = {'preflight': 'source-retained', 'stop': 'stop-unconfirmed',
               'stopped': 'stop-unconfirmed', 'reserve': 'admission-unconfirmed',
               'launch': 'launch-unconfirmed', 'started': 'target-unconfirmed',
               'deliver': 'delivery-unconfirmed', 'bound': 'binding-unconfirmed',
               'consumed': 'consumption-unconfirmed'}
SOURCE_STAGES = ('preflight', 'stop', 'stopped', 'reserve', 'launch', 'started')
# A resumed Codex thread runs SessionStart (source=resume) only when its first
# turn starts (measured on 0.162.1, #4775), so the new lifetime is bound to its
# reservation by the original message's own turn. These stages may be re-entered:
# deliver settles an earlier attempt by its receipt before any new native write,
# bound and consumed only read.
TARGET_STAGES = ('deliver', 'bound', 'consumed')
RESUME_FROM = {'started': 'deliver', 'delivery-rejected': 'deliver', 'delivery-unconfirmed': 'deliver',
               'binding-unconfirmed': 'bound', 'consumption-unconfirmed': 'consumed'}


class Rejected(ValueError):
    """The native refused the delivery: nothing was started, still owed."""


def save(path, value):
    """Private write-ahead record, including a directory fsync after rename."""
    fd, temporary = tempfile.mkstemp(prefix='.continue-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600, 'private owned 0600 record required')
        return json.load(stream)


def message(plan):
    """The original message: its operation id and text. Required — without a
    first turn the resumed lifetime never binds to its reservation."""
    m = plan.get('message')
    require(isinstance(m, dict) and set(m) == {'operation', 'text'}
            and isinstance(m['operation'], str) and str(uuid.UUID(m['operation'])) == m['operation']
            and isinstance(m['text'], str) and 0 < len(m['text']) <= 65536,
            'original message needs exactly an operation UUID and its text')
    return m


def execute(path, plan, backend, transition=None):
    """Called under the target lock. Never retry an unacknowledged effect."""
    if path.exists():
        record = read(path)
        require(record.get('plan') == plan, 'operation already belongs to another source')
        return record
    message(plan)   # a missing or malformed original message refuses before any effect
    record = dict(version=2, plan=plan, reservation=str(uuid.uuid4()), state='prepared',
                  message_consumption_verified=False, new_kernel_lifetime_requested=True,
                  new_kernel_lifetime_verified=False)
    save(path, record)
    for stage in SOURCE_STAGES:
        if stage == 'stop' and transition is not None:
            # The existing transition lock's durable request marker survives an
            # unknown outcome/controller exit. No TTL can authorize cleanup.
            save(transition / 'request', dict(kind='native-continuation', journal=str(path),
                                             source=plan['proof']))
        record.update(state=stage + '-requested', stage=stage)
        save(path, record)
        try:
            method = getattr(backend, stage)
            result = method(plan, record['reservation']) if stage in ('reserve', 'launch', 'started') else method(plan)
            record[stage] = result
            save(path, record)
        except Exception:
            # Details can contain native argv or account metadata. The stage is
            # enough to distinguish retained source, stopped source, and target.
            record['state'] = UNCONFIRMED[stage]
            save(path, record)
            return record
    record['state'] = 'started'
    save(path, record)
    return deliver(path, record, backend, transition)


def deliver(path, record, backend, transition=None):
    """The original message as the resumed lifetime's first turn, then its proof.

    Only after `started`: the original writer is stopped and the target is the
    standard launcher's resume of the same SID, idle, so the message cannot reach
    the old process (whose missing Stop hook would loop it, #4775). deliver uses
    the native start-if-idle (thread/queue + clientUserMessageId = operation): a
    lost ACK or a repeated call settles the earlier attempt by its receipt and is
    never resent; rejected = provably not started (still owed). The turn's own
    SessionStart binds the lifetime (bound, read-only); consumed re-reads the
    persisted thread on a fresh connection. Unknown is never consumed.
    """
    first = RESUME_FROM.get(record.get('state'))
    if first is None:
        return record
    require('started' in record and record['started'].get('native_identity'),
            'original message waits for a started new lifetime')
    for stage in TARGET_STAGES[TARGET_STAGES.index(first):]:
        record.update(state=stage + '-requested', stage=stage)
        save(path, record)
        try:
            if stage == 'deliver':
                record[stage] = backend.deliver(record['plan'], record, commit=lambda: save(path, record))
            else:
                record[stage] = getattr(backend, stage)(record['plan'], record)
            save(path, record)
        except Rejected:
            record['state'] = 'delivery-rejected'
            save(path, record)
            return record
        except Exception:
            record['state'] = UNCONFIRMED[stage]
            save(path, record)
            return record
        if stage == 'bound':
            record['new_kernel_lifetime_verified'] = True
    record.update(state='consumed', message_consumption_verified=True)
    save(path, record)
    if transition is not None and (transition / 'request').exists():
        (transition / 'request').unlink()
    return record


def protected_execute(path, plan, backend):
    """Same atomic lock as rotate/transfer/cleanup, held across every stage."""
    if path.exists():
        record = read(path)
        require(record.get('plan') == plan, 'operation already belongs to another source')
        if record.get('state') in RESUME_FROM:
            # An unconfirmed message stage kept the lock (its request names this
            # journal); only this operation may re-enter it, to settle by receipt.
            request = dict(kind='native-continuation', journal=str(path), source=plan['proof'])
            with TRANSFER['adopt_transition'](plan['binding']['@worktree'], request) as lock:
                return deliver(path, read(path), backend, transition=lock)
    with TRANSFER['transition_lock'](plan['binding']['@worktree']) as lock:
        if path.exists():
            record = read(path)
            require(record.get('plan') == plan, 'operation already belongs to another source')
            if record.get('stage') not in (None, 'preflight') and record.get('state') != 'consumed':
                save(lock / 'request', dict(kind='native-continuation', journal=str(path), source=plan['proof']))
            return deliver(path, record, backend, transition=lock)
        return execute(path, plan, backend, transition=lock)


def automatic_capability():
    """The three contracts #4775 required, each shown on a real Codex
    (0.162.1, bin/fleet_native_continue_native_test.py — isolated HOME/tmux/
    socket, fixture hub and Responses):

    - original-message-operation: the message is the resumed lifetime's first
      turn through native start-if-idle (thread/queue + clientUserMessageId),
      journaled before the write, settled by receipt, re-read on its own;
    - continuous-execution-gate: nothing is ever handed to the original (a
      missing `python3 <deleted>` Stop hook exits 2 and loops every new turn —
      the drill's --loop-control); it is stopped only idle with no queue,
      request or goal, and the message runs under the CURRENT hooks;
    - missing-config-mcp-stop: the fleet's own MCP services are remounted by the
      resumed lifetime, so their old config path and readiness do not matter —
      identity and an empty tree beneath them still do; strict is unchanged.
    No environment override: a probe cannot change what this says.
    """
    return dict(state='available', reason='', version=2, missing_capabilities=[],
                min_native_version='%d.%d' % observe.runtime.CODEX_ACCEPT_MIN,
                evidence='bin/fleet_native_continue_native_test.py',
                stop_submitted=False, new_admission_requested=False,
                message_consumption_verified=False)


def reconcile(record, backend):
    """Read current evidence once. Never repair stamps, save or retry effects."""
    result = dict(state='target-unconfirmed', journal_state=record['state'],
                  new_kernel_lifetime_verified=False, message_consumption_verified=False)
    if record.get('state') == 'consumed' and record.get('message_consumption_verified') is True:
        # The journal's own independent re-read; reconcile never repeats it.
        result.update(state='consumed', new_kernel_lifetime_verified=True,
                      message_consumption_verified=True, consumed=record.get('consumed'))
        return result
    if 'deliver' not in record:
        # Not bindable before the message's turn: the journal's own state stands.
        result['state'] = record['state']
        return result
    try:
        result['bound'] = backend.bound(record['plan'], record, seconds=0)
        result.update(state='bound', new_kernel_lifetime_verified=True)
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, EOFError):
        pass
    return result


def routing(row):
    return {key: launch.option(row['pane'], key, row['socket']) for key in ROUTING}


def workspace(path):
    """Hash tracked and nonignored untracked bytes without changing the tree."""
    base = ['git', '--no-optional-locks', '-C', path]
    require((Path(path) / '.git').is_file(), 'a linked worktree is required')
    paths = subprocess.check_output(base + ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], timeout=15)
    digest = hashlib.sha256()
    for raw in sorted(set(paths.split(b'\0')) - {b''}):
        relative = os.fsdecode(raw)
        p = Path(path) / relative
        require(not p.is_dir(), 'submodule worktrees require their own continuation contract')
        digest.update(raw + b'\0')
        if p.is_symlink():
            digest.update(b'link\0' + os.fsencode(os.readlink(p)))
        elif p.exists():
            digest.update(str(stat.S_IMODE(p.stat().st_mode)).encode() + b'\0')
            with p.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
        else:
            digest.update(b'missing')
    status = subprocess.check_output(base + ['status', '--porcelain=v1', '-z'], timeout=15)
    index = subprocess.check_output(base + ['ls-files', '--stage', '-z'], timeout=15)
    head = subprocess.check_output(base + ['rev-parse', 'HEAD'], timeout=5).decode().strip()
    return dict(head=head, files_sha256=digest.hexdigest(), status_sha256=hashlib.sha256(status).hexdigest(),
                index_sha256=hashlib.sha256(index).hexdigest())


def source_process(plan):
    row, proof = plan['binding'], plan['proof']
    session = launch.option(row['pane'], '?#{session_group},#{session_group},#{session_name}', row['socket'])
    require(session, 'source fleet is unknown')
    # The contract reader resolves a worktree through the fleet's repo registry.
    # A window argument would make it use the fleet's named socket, which need
    # not be this explicitly selected socket (isolated tests use absolute paths).
    return dict(agent='codex', pid=proof['pid'], session_id=proof['native_session'],
                worktree=row['@worktree'], codex_identity=plan['identity'],
                session=session)


def fleet_mounts():
    """The MCP services the CURRENT standard launcher mounts, as it spells them.

    fleet-codex.sh writes exactly `fleet-mcp.py --mount codex` (and the orch
    group's); a service whose effective native config equals one of these is
    mounted afresh by the resumed lifetime from this install (issue #4775).
    """
    mounts = {}
    for group in ([], ['--group', 'orch']):
        out = subprocess.run([sys.executable, str(BIN / 'fleet-mcp.py'), '--mount', 'codex', *group],
                             capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        require(out.returncode == 0 and out.stdout.strip(), 'current fleet MCP mount is unavailable')
        key, value = observe.inline_override(out.stdout.strip())
        require(key.startswith('mcp_servers.') and isinstance(value, dict), 'current fleet MCP mount is unreadable')
        mounts[key.split('.', 1)[1]] = value
    return mounts


def remounted(configured):
    """Configured services the resumed lifetime remounts: same command, args, env."""
    fields = ('command', 'args', 'env_vars', 'env')
    current = fleet_mounts()
    return sorted(name for name, conf in configured.items()
                  if name in current and isinstance(conf, dict) and conf.get('enabled', True)
                  and all(conf.get(k) == current[name].get(k) for k in fields))


def native_ready(plan):
    """Fresh observations, NOT an atomic compare-and-accept primitive.

    Only idle/completed is eligible. A missing Stop retry loop remains active;
    neither a hook error nor completed tool items authorize interrupting it.
"""
    row, proof = plan['binding'], plan['proof']
    client = observe.runtime.RPC(plan['identity']['remote'], timeout=5, peer_pid=proof['pid'])
    try:
        response = client.call('thread/resume', dict(threadId=proof['native_session'], excludeTurns=True))
        require(response['thread']['id'] == proof['native_session'], 'native rejoin changed identity')
        require(not any('id' in e and 'method' in e for e in client.events), 'native has a pending server request')
        thread = client.call('thread/read', dict(threadId=proof['native_session'], includeTurns=True))['thread']
        require(thread.get('id') == proof['native_session'] and not thread.get('parentThreadId'), 'native root changed')
        require(thread.get('status', {}).get('type') == 'idle'
                and not thread.get('status', {}).get('activeFlags'), 'native attention or unknown status')
        turns = thread.get('turns') or []
        require(turns and turns[-1].get('itemsView') in (None, 'full')
                and isinstance(turns[-1].get('items'), list), 'complete current turn metadata required')
        turn = turns[-1]
        known = {'userMessage', 'agentMessage', 'reasoning', 'plan', 'hookPrompt', 'commandExecution',
                 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'webSearch', 'imageView'}
        for item in turn.get('items', []):
            require(item.get('type') in known and item.get('status') in (None, 'completed', 'failed', 'declined', 'interrupted'),
                    'active or unsupported native tool item')
            if item.get('type') in ('commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall'):
                require(item.get('status') in ('completed', 'failed', 'declined', 'interrupted'), 'tool completion is unknown')
        require(turn.get('status') == 'completed', 'native idle turn is not completed')
        goal = client.call('thread/goal/get', dict(threadId=proof['native_session']))
        require(isinstance(goal, dict) and 'goal' in goal and goal['goal'] is None,
                'native goal requires its own lifecycle contract')
        require(client.call('thread/loaded/list', {}).get('data') == [proof['native_session']], 'other native threads exist')
        # A queued input would start on THIS lifetime the moment it is idle,
        # through hooks that no longer run. Nothing may wait there.
        queued = client.call('thread/queue/list', dict(threadId=proof['native_session'], limit=1))
        require(queued.get('data') == [] and not queued.get('nextCursor'), 'native has queued input')
        require(not any('id' in e and 'method' in e for e in client.events), 'native has a pending server request')
        configured, _ = MCP.inventory(client)
        source = source_process(plan)
        mounts = remounted(configured)
        # The fleet's own servers are mounted afresh by the resumed lifetime, so
        # their old config path and readiness do not matter: identity and an
        # empty process tree beneath them still do (fleet_agent_mcp.classify).
        SLEEP['quiet_processes'](source, remounted=mounts)
        require(observe.kernel(proof['pid']) == plan['processes']['native'], 'native kernel lifetime changed')
        # Config hashes prove unchanged effective config. shell-exec is only
        # the dependency's measured exec-target basis, never historical code.
        return dict(mode='idle', turn_id=turn['id'], mcp_config=source.get('sleep_mcp', {}),
                    mcp_basis=source.get('sleep_mcp_basis', {}), mcp_remounted=mounts)
    finally:
        client.close()


def inspect(pane, socket, pid, sid):
    plan = observe.inspect(pane, socket, pid, sid)
    require(plan['hub']['phase'] == 'observed', 'observe the original execution separately before continuation')
    require(plan['hooks']['state'] == 'missing', 'this entry only continues missing fixed hooks')
    row = plan['binding']
    require(os.environ.get('TMUX_PANE') != pane or os.environ.get('TMUX', '').split(',')[0] != row['socket'],
            'run continuation outside its source pane')
    for key in CONFLICTS:
        require(not launch.option(pane, key, row['socket']), 'source has a conflicting lifecycle or schedule')
    until = launch.option(pane, '@agent_transfer_until', row['socket'])
    require(not until or (until.isdigit() and int(until) < time.time()), 'transfer is pending')
    require(INPUT['snapshot'](row['socket'], pane, 'codex')['state'] == 'empty', 'source input is not empty/known')
    plan['routing'] = routing(row)
    plan['workspace'] = workspace(row['@worktree'])
    plan['readiness'] = native_ready(plan)
    plan['continuation_version'] = 1
    return plan


def descendants(pid):
    found, todo = [], [pid]
    while todo:
        out = subprocess.run(['pgrep', '-P', str(todo.pop())], capture_output=True, text=True, timeout=5).stdout
        children = [int(v) for v in out.split()]
        found.extend(children)
        todo.extend(children)
    return found


def is_app_server(pid):
    try:
        argv = observe.process_argv(pid)
        return ('app-server' in argv and '--listen' in argv
                and launch.native_tool(observe.kernel(pid)['executable']) == 'codex')
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def wait_for(fn, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            result = fn()
            if result:
                return result
        except (ValueError, OSError, subprocess.SubprocessError, EOFError):
            pass
        if time.monotonic() >= deadline:
            raise ValueError('bounded continuation check unconfirmed')
        time.sleep(.2)


def unavailable(error):
    # Public result: do not include process argv, environment or HTTP bodies.
    reason = 'source-unverified'
    if isinstance(error, ValueError):
        message = str(error)
        if 'not ready or has unknown runtime status' in message:
            reason = 'mcp-not-ready'
        elif 'no restartability contract' in message:
            reason = 'mcp-contract-missing'
        elif message == 'native attention or unknown status':
            reason = 'native-not-idle'
    return dict(state='unavailable', reason=reason, stop_submitted=False,
                new_admission_requested=False, message_consumption_verified=False)


class Native:
    def preflight(self, plan):
        require(automatic_capability()['state'] == 'available',
                'automatic continuation unavailable')
        require(plan.get('continuation_version') == 1, 'not a continuation manifest')
        row, proof = plan['binding'], plan['proof']
        current = inspect(row['pane'], row['socket'], proof['pid'], proof['native_session'])
        observe.same_plan(plan, current)
        for key in ('routing', 'workspace', 'readiness'):
            require(plan[key] == current[key], 'continuation source changed: ' + key)
        require(all((BIN / name).is_file() for name in ('fleet-session-wrap.sh', 'fleet-codex.sh', 'fleet-hooks-emit.sh')),
                'current standard launcher is unavailable')
        return dict(verified=True, readiness=current['readiness'])

    def stop(self, plan):
        # Recheck directly before the first native mutation. This is observation
        # plus a supported stop, not a promise of atomic idle-only acceptance.
        self.preflight(plan)
        row, proof = plan['binding'], plan['proof']
        require(plan['readiness']['mode'] == 'idle', 'only a completed idle source may exit')
        require(routing(row) == plan['routing'], 'routing changed before exit')
        require(observe.kernel(proof['pid']) == plan['processes']['native'], 'native changed before exit')
        require(INPUT['snapshot'](row['socket'], row['pane'], 'codex')['state'] == 'empty', 'input changed before exit')
        SLEEP['quiet_processes'](source_process(plan), remounted=plan['readiness'].get('mcp_remounted'))
        launch.tmux('set-option', '-w', '-t', row['pane'], '@wrap_quiet', '1', socket=row['socket'])
        launch.tmux('send-keys', '-t', row['pane'], '-l', '\x1b[200~/exit\x1b[201~', socket=row['socket'])
        launch.tmux('send-keys', '-t', row['pane'], 'Enter', socket=row['socket'])
        return dict(exit_submitted_once=True)

    def stopped(self, plan):
        row, proof = plan['binding'], plan['proof']
        result = wait_for(lambda: authority.prove_stopped(dict(proof)), 30)
        # A dead writer alone does not authorize replacing a live wrapper/tool.
        wait_for(lambda: launch.option(row['pane'], 'pane_dead', row['socket']) == '1', 10)
        require(routing(row) == plan['routing'], 'source routing changed after exit')
        require(workspace(row['@worktree']) == plan['workspace'], 'worktree changed during stop')
        ack = authority.start_call(plan['context']['repo'], plan['context']['reservation'], 'stopped',
                                   native_identity=proof, execution_stopped=True)
        require(all(ack.get(k) == plan['hub'].get(k) for k in observe.START_KEYS)
                and ack.get('native_identity') == proof and ack.get('phase') == 'stopped', 'original stop acknowledgement differs')
        return dict(kernel=result, hub_confirmation=ack)

    def reserve(self, plan, reservation):
        authority.prove_stopped(dict(plan['proof']))
        ack = authority.start_call(plan['context']['repo'], reservation, 'reserve')
        require(ack.get('reservation') == reservation and ack.get('phase') == 'reserved'
                and all(ack.get(k) == plan['hub'][k] for k in ('repo', 'owner', 'endpoint_id')),
                'new standard admission unconfirmed')
        return ack

    def launch(self, plan, reservation):
        row = plan['binding']
        authority.prove_stopped(dict(plan['proof']))
        require(routing(row) == plan['routing'] and launch.option(row['pane'], 'pane_dead', row['socket']) == '1',
                'source pane no longer stopped and retained')
        require(workspace(row['@worktree']) == plan['workspace'], 'worktree changed before resume')
        home = plan['account'].get('real_home') or plan['identity']['home']
        argv = [str(BIN / 'fleet-session-wrap.sh'), '--agent', 'codex', '--codex-home', home,
                '--resume', plan['proof']['native_session']]
        if plan['routing'].get('@agent_def'):
            argv[1:1] = ['--as', plan['routing']['@agent_def']]
        # The standard wrapper owns credentials, provider, permission/trust and
        # authority begin. Do not copy the old environment, packet or hook pin.
        command = shlex.join(['env', '-u', 'FLEET_WRAP_LAUNCH', '-u', 'FLEET_AUTHORITY_CONTEXT',
                             '-u', 'FLEET_LAUNCH_CONTEXT', '-u', 'FLEET_AUTHORITY_START',
                             'FLEET_AUTHORITY_START=' + reservation,
                             'FLEET_AUTHORITY_EXPECTED=' + json.dumps(dict(
                                 {k: plan['hub'][k] for k in observe.START_KEYS}, reservation=reservation)),
                             'FLEET_AUTHORITY_RESUME_SID=' + plan['proof']['native_session'],
                             'FLEET_EXIT_CLOSE_SECS=0', 'bash', *argv])
        launch.tmux('respawn-pane', '-t', row['pane'], '-c', row['@worktree'], command, socket=row['socket'])
        return dict(standard_wrapper=str(BIN / 'fleet-session-wrap.sh'), reservation=reservation,
                    native_session=plan['proof']['native_session'])

    def started(self, plan, reservation):
        """The standard launcher's resume of the same SID: a new kernel under a new
        launcher and supervisor, admitted with the new reservation, its private
        thread loaded and idle. Everything but the registration, which only the
        first turn's SessionStart writes (bound)."""
        row, sid = plan['binding'], plan['proof']['native_session']
        def check():
            authority.prove_stopped(dict(plan['proof']))
            require(routing(row) == plan['routing'], 'target routing differs')
            require(launch.option(row['pane'], 'pane_dead', row['socket']) != '1', 'target launcher exited')
            owner = launch.option(row['pane'], '@cc_launcher_pid', row['socket'])
            require(owner.isdigit() and int(owner) != plan['processes']['launcher']['pid'], 'target launcher not yet stamped')
            # A resume names its thread as @codex_pending until its SessionStart
            # writes @codex_identity (fleet-codex.sh, #4728) — on 0.162.1 that is
            # the first turn's; a release that runs it at resume time says so here.
            pending = json.loads(launch.option(row['pane'], '@codex_pending', row['socket'])
                                 or launch.option(row['pane'], '@codex_identity', row['socket']) or '{}')
            require(pending.get('session_id') == sid and pending.get('owner') == owner, 'target does not resume the original SID')
            servers = [pid for pid in descendants(int(owner)) if is_app_server(pid)]
            require(len(servers) == 1, 'target native server is unknown or ambiguous')
            native = observe.kernel(servers[0])
            scope = observe.process_scope(native['pid'])
            context = json.loads(scope.get('FLEET_AUTHORITY_CONTEXT', '{}'))
            require(context.get('reservation') == reservation and context.get('repo') == plan['context']['repo']
                    and context.get('worker_id') == plan['context']['worker_id']
                    and scope.get('FLEET_CODEX_LAUNCHER_PID') == owner, 'target authority scope differs')
            supervisor = observe.kernel(context['supervisor'])
            require(observe.kernel(int(owner))['ppid'] == supervisor['pid'] and launch.root_native(native, supervisor['pid'])
                    and launch.descendant(supervisor['pid'], int(launch.option(row['pane'], 'pane_pid', row['socket']))),
                    'target process ancestry is unproven')
            expected = dict({k: plan['hub'][k] for k in observe.START_KEYS}, reservation=reservation)
            admitted = process_env(native['pid'], {'FLEET_AUTHORITY_ADMISSION'})['values']
            authority.check_start_ack(expected, json.loads(admitted.get('FLEET_AUTHORITY_ADMISSION', '{}')), 'starting')
            remote = scope.get('FLEET_CODEX_REMOTE', '')
            require(remote.startswith('unix:///') and observe.process_argv(native['pid'])[-3:] == ['app-server', '--listen', remote],
                    'target private RPC is unproven')
            proof = dict({k: native[k] for k in ('pid', 'birth', 'executable')},
                         worker_id=plan['context']['worker_id'], native_session=sid)
            require(proof['pid'] != plan['proof']['pid'], 'target is the original lifetime')
            client = observe.runtime.RPC(remote, timeout=5, peer_pid=native['pid'])
            try:
                require(client.call('thread/loaded/list', {}).get('data') == [sid], 'target root thread is unknown')
                thread = client.call('thread/read', dict(threadId=sid, includeTurns=True))['thread']
                require(thread.get('status', {}).get('type') == 'idle' and Path(thread.get('cwd', '')).resolve()
                        == Path(row['@worktree']).resolve(), 'target thread is not idle in its worktree')
                anchor = (thread.get('turns') or [{}])[-1].get('id')
                require(anchor == plan['readiness']['turn_id'], 'target history differs from the stopped original')
            finally:
                client.close()
            require(workspace(row['@worktree']) == plan['workspace'], 'worktree changed during resume')
            return dict(native_identity=proof, remote=remote, owner=int(owner),
                        supervisor=supervisor['pid'], anchor_turn_id=anchor)
        return wait_for(check, 45)

    def target(self, plan, record):
        """The started lifetime, unchanged; the original still stopped."""
        st, row = record['started'], plan['binding']
        authority.prove_stopped(dict(plan['proof']))
        native = observe.kernel(st['native_identity']['pid'])
        require(launch.same_identity(native, st['native_identity']),
                'target lifetime changed')
        require(routing(row) == plan['routing'], 'target routing changed')
        return st

    def deliver(self, plan, record, commit=lambda: None):
        m, st, row = message(plan), self.target(plan, record), plan['binding']
        sid, op, anchor = plan['proof']['native_session'], m['operation'], record['started']['anchor_turn_id']
        rt = observe.runtime
        client = rt.RPC(st['remote'], timeout=30, peer_pid=st['native_identity']['pid'])
        try:
            version = rt.codex_version(client)
            require(version is not None and version[:2] >= rt.CODEX_ACCEPT_MIN, 'native start-if-idle is unverified here')
            if record.get('delivery_attempt'):
                # Settle the earlier attempt before anything new: never a blind resend.
                qid = rt.codex_queued(client, sid, op)
                if qid is not None:
                    state, why, tid, _ = rt.codex_settle(client, sid, qid, op, anchor)
                else:
                    found, tid, _ = rt.codex_receipt(client, sid, op, anchor)
                    state, why = (('accepted', 'native_receipt') if found else
                                  ('unknown', 'receipt_scan_incomplete') if found is None else ('absent', ''))
                if state == 'absent':
                    idle = client.call('thread/read', dict(threadId=sid))['thread']['status']['type'] == 'idle'
                    require(idle, 'earlier delivery attempt unsettled')
                    state = 'retry'
            else:
                state = 'retry'
            if state == 'retry':
                thread = client.call('thread/read', dict(threadId=sid))['thread']
                if thread['status']['type'] != 'idle':
                    raise Rejected('precheck_not_idle')
                require(workspace(row['@worktree']) == plan['workspace'], 'worktree changed before delivery')
                record['delivery_attempt'] = dict(operation=op, anchor_turn_id=anchor, at=time.time())
                commit()   # written before the native write, so a retry settles it
                try:
                    q = client.call('thread/queue/add', dict(threadId=sid, clientUserMessageId=op,
                                                             input=[dict(type='text', text=m['text'])]))['queuedSubmission']
                except ValueError:
                    raise Rejected('native_add_refused') from None
                require(q.get('clientUserMessageId') == op, 'native receipt mismatch')
                state, why, tid, _ = rt.codex_settle(client, sid, q.get('id'), op, anchor, wait=10.0)
            if state == 'rejected':
                raise Rejected(why)
            require(state == 'accepted' and isinstance(tid, str) and tid, 'original message delivery unconfirmed')
            return dict(operation=op, turn_id=tid, anchor_turn_id=anchor, method='thread/queue', reason=why,
                        native_identity=st['native_identity'])
        finally:
            client.close()

    def bound(self, plan, record, seconds=30):
        """The first turn's SessionStart registered the started lifetime."""
        row, reservation = plan['binding'], record['reservation']
        started = record['started']['native_identity']
        def check():
            authority.prove_stopped(dict(plan['proof']))
            require(routing(row) == plan['routing'], 'target routing differs')
            receipt = json.loads(launch.option(row['pane'], '@authority_receipt', row['socket']) or '{}')
            proof = receipt.get('native_identity', {})
            require(receipt.get('reservation') == reservation and receipt.get('repo') == plan['context']['repo']
                    and receipt.get('worker_id') == plan['context']['worker_id'], 'target admission not yet bound')
            expected = dict(plan['hub'], reservation=reservation)
            observe.check_ack(expected, proof, receipt.get('hub_confirmation'))
            require(proof == started, 'target bound a lifetime other than the started one')
            native = observe.kernel(proof['pid'])
            require(launch.same_identity(native, proof)
                    and launch.root_native(native, receipt['supervisor']), 'target kernel differs from its authority receipt')
            scope = observe.process_scope(native['pid'])
            context = json.loads(scope.get('FLEET_AUTHORITY_CONTEXT', '{}'))
            require(all(context.get(k) == receipt.get(k) for k in ('repo', 'worker_id', 'reservation', 'supervisor')),
                    'target inherited authority differs')
            admission = receipt.get('admission', {})
            authority.check_start_ack({k: expected[k] for k in observe.START_KEYS}, admission, 'starting')
            import fleet_native_registration as registration
            registered = registration.read(registration.journal_path(dict(context=context, proof=proof)))
            require(registered.get('state') == 'observed/local_registered'
                    and registered.get('context') == context and registered.get('proof') == proof,
                    'target local registration is still pending')
            require(all(launch.option(row['pane'], k, row['socket']) == registered['values'][k]
                        for k in ('@authority_receipt', '@codex_session_id')),
                    'target differs from its confirmed local commit')
            data = observe.runtime.CODEX['identity'](row['pane'], row['socket'])
            require(data.get('session_id') == proof['native_session'], 'target native identity not bound')
            client = observe.runtime.RPC(data['remote'], timeout=5, peer_pid=proof['pid'])
            try:
                thread = observe.runtime.thread(client, proof, row['@worktree'])
                require(thread['status']['type'] in ('active', 'idle'), 'target native thread not loaded')
                # What the continuation let go of must be back, from this install.
                mounts = plan['readiness'].get('mcp_remounted', [])
                if mounts:
                    configured, statuses = MCP.inventory(client)
                    require(remounted(configured) == mounts
                            and all(MCP.runtime_ready(statuses.get(name, {})) for name in mounts),
                            'target has not remounted the fleet MCP services yet')
            finally:
                client.close()
            return dict(authority_receipt=receipt, native_identity=proof)
        return check() if seconds == 0 else wait_for(check, seconds)

    def consumed(self, plan, record):
        """An independent read of the bound thread: the accepted turn carries the
        operation as its userMessage clientId. The delivery's own answer is not it."""
        m, accepted, st = message(plan), record['deliver'], self.target(plan, record)
        sid = plan['proof']['native_session']
        client = observe.runtime.RPC(st['remote'], timeout=5, peer_pid=st['native_identity']['pid'])
        try:
            found, turn, _ = observe.runtime.codex_receipt(client, sid, m['operation'], accepted['anchor_turn_id'])
        finally:
            client.close()
        require(found is True and turn == accepted['turn_id'], 'original message consumption unconfirmed')
        return dict(operation=m['operation'], turn_id=turn, native_session=sid, source='native-reread')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--preflight', action='store_true')
    action.add_argument('--apply', type=Path)
    action.add_argument('--status', type=Path)
    action.add_argument('--reconcile', type=Path)
    parser.add_argument('--pane')
    parser.add_argument('--socket', default='')
    parser.add_argument('--pid', type=int)
    parser.add_argument('--sid')
    parser.add_argument('--message-file', type=Path, help='--preflight: the original message (UTF-8 text)')
    parser.add_argument('--operation', help='--preflight: its operation id (default: a new UUID)')
    args = parser.parse_args()
    if (args.preflight or args.apply) and automatic_capability()['state'] != 'available':
        print(json.dumps(automatic_capability(), indent=2))
        return 1
    if args.preflight:
        require(args.pane and args.pid and args.sid and args.message_file,
                'explicit pane/PID/SID and the original message are required')
        text = args.message_file.read_text(encoding='utf-8')
        try:
            plan = inspect(args.pane, args.socket, args.pid, args.sid)
        except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, EOFError) as error:
            print(json.dumps(unavailable(error), indent=2))
            return 1
        plan['message'] = dict(operation=args.operation or str(uuid.uuid4()), text=text)
        message(plan)
        print(json.dumps(plan, indent=2))
        return 0
    if args.status:
        print(json.dumps(read(args.status), indent=2))
        return 0
    if args.reconcile:
        result = reconcile(read(args.reconcile), Native())
        print(json.dumps(result, indent=2))
        return 0 if result['state'] == 'consumed' else 1
    plan = read(args.apply)
    with observe.target_lock(plan):
        root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'native-continuations'
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(root.stat().st_uid == os.getuid() and stat.S_IMODE(root.stat().st_mode) == 0o700, 'unsafe journal directory')
        key = hashlib.sha256(json.dumps(plan['proof'], sort_keys=True).encode()).hexdigest()
        path = root / (key + '.json')
        record = protected_execute(path, plan, Native())
        print(json.dumps(dict(journal=str(path), state=record['state'], stage=record.get('stage'),
                              new_kernel_lifetime_requested=True,
                              new_kernel_lifetime_verified=record.get('new_kernel_lifetime_verified', False),
                              message_consumption_verified=record.get('message_consumption_verified', False)), indent=2))
        return 0 if record['state'] == 'consumed' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, EOFError):
        print('continuation refused or unconfirmed; preserve the original execution/journal', file=sys.stderr)
        sys.exit(1)
