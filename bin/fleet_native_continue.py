#!/usr/bin/env python3
"""Guarded prototype for one-shot legacy Codex continuation.

Automatic preflight/apply return unavailable before any target read or effect:
the native continuous-execution gate and the missing-config/MCP stop contract
are still missing. The isolated controller saves intent before each effect;
replay never retries one. The original message is not a resume prompt: once the
new lifetime is bound it goes through the runtime's idle accept under its own
operation id, and only an independently re-read receipt counts as consumed.
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

BIN = Path(__file__).resolve().parent
require = observe.require
launch = observe.launch
authority = observe.authority
SLEEP = runpy.run_path(str(BIN / 'fleet-sleep.py'))
INPUT = runpy.run_path(str(BIN / 'fleet-input.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
ROUTING = ('@fleet_id', '@repo', '@issue', '@raw', '@worktree', '@task', '@origin',
           '@origin_fid', '@agent_def', '@fleet_role', '@launch', '@launch_receipt')
CONFLICTS = ('@handoff_armed', '@agent_transfer_request', '@worker_lifecycle', '@loop')
UNCONFIRMED = {'preflight': 'source-retained', 'stop': 'stop-unconfirmed',
               'stopped': 'stop-unconfirmed', 'reserve': 'admission-unconfirmed',
               'launch': 'launch-unconfirmed', 'bound': 'target-unconfirmed',
               'deliver': 'delivery-unconfirmed', 'consumed': 'consumption-unconfirmed'}
# A message stage may be re-entered: the runtime's per-delivery journal settles
# an earlier attempt by its receipt before any new native write (#4617).
MESSAGE_RESUMABLE = ('bound', 'delivery-rejected', 'delivery-unconfirmed', 'consumption-unconfirmed')


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


def execute(path, plan, backend, transition=None):
    """Called under the target lock. Never retry an unacknowledged effect."""
    if path.exists():
        record = read(path)
        require(record.get('plan') == plan, 'operation already belongs to another source')
        return record
    message(plan)   # a malformed original message refuses before any effect
    record = dict(version=1, plan=plan, reservation=str(uuid.uuid4()), state='prepared',
                  message_consumption_verified=False, new_kernel_lifetime_requested=True,
                  new_kernel_lifetime_verified=False)
    save(path, record)
    for stage in ('preflight', 'stop', 'stopped', 'reserve', 'launch', 'bound'):
        if stage == 'stop' and transition is not None:
            # The existing transition lock's durable request marker survives an
            # unknown outcome/controller exit. No TTL can authorize cleanup.
            save(transition / 'request', dict(kind='native-continuation', journal=str(path),
                                             source=plan['proof']))
        record.update(state=stage + '-requested', stage=stage)
        save(path, record)
        try:
            method = getattr(backend, stage)
            result = method(plan, record['reservation']) if stage in ('reserve', 'launch', 'bound') else method(plan)
            record[stage] = result
            save(path, record)
        except Exception:
            # Details can contain native argv or account metadata. The stage is
            # enough to distinguish retained source, stopped source, and target.
            record['state'] = UNCONFIRMED[stage]
            save(path, record)
            return record
    record['state'] = 'bound'
    record['new_kernel_lifetime_verified'] = True
    save(path, record)
    if transition is not None:
        (transition / 'request').unlink()
    return deliver(path, record, backend)


def message(plan):
    """The original message's operation, or None for a continuation without one."""
    m = plan.get('message')
    if m is None:
        return None
    require(isinstance(m, dict) and set(m) == {'operation', 'text'}
            and isinstance(m['operation'], str) and str(uuid.UUID(m['operation'])) == m['operation']
            and isinstance(m['text'], str) and 0 < len(m['text']) <= 65536,
            'original message needs exactly an operation UUID and its text')
    return m


def deliver(path, record, backend):
    """Hand the original message to the bound lifetime, then verify consumption.

    Never before the new lifetime is bound: the original writer is stopped and
    the target is confirmed first, so the message cannot reach the old process.
    The operation id is the runtime's delivery_id (Codex clientUserMessageId), so
    a lost ACK or a repeated call settles the earlier attempt instead of sending
    again. Rejected = provably not started (still owed); unknown is never consumed.
    """
    if message(record['plan']) is None or record.get('state') not in MESSAGE_RESUMABLE:
        return record
    require(record.get('new_kernel_lifetime_verified') is True and 'bound' in record,
            'original message waits for a confirmed new lifetime')
    # A delivery already accepted is only re-verified, never handed over again.
    stages = ('consumed',) if record.get('state') == 'consumption-unconfirmed' else ('deliver', 'consumed')
    for stage in stages:
        record.update(state=stage + '-requested', stage=stage)
        save(path, record)
        try:
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
    record.update(state='consumed', message_consumption_verified=True)
    save(path, record)
    return record


def protected_execute(path, plan, backend):
    """Same atomic lock as rotate/transfer/cleanup, held across every stage."""
    with TRANSFER['transition_lock'](plan['binding']['@worktree']) as lock:
        if path.exists():
            record = read(path)
            require(record.get('plan') == plan, 'operation already belongs to another source')
            if record.get('stage') in ('stop', 'stopped', 'reserve', 'launch', 'bound') and record.get('state') != 'bound':
                save(lock / 'request', dict(kind='native-continuation', journal=str(path), source=plan['proof']))
            return deliver(path, record, backend)
        return execute(path, plan, backend, transition=lock)


def automatic_capability():
    # Normal returned-error hooks are not a fail-closed native execution gate,
    # and a missing-config/MCP-not-ready source has no supported drain/stop proof
    # (the strict gate's refusal stays, #4537). The original message rides idle
    # accept after binding (deliver/consumed), but counts only once a real Codex
    # run shows it. No environment override: isolated probes cannot enable product.
    return dict(state='unavailable', reason='native-continuation-capability-missing',
                missing_capabilities=['continuous-execution-gate', 'missing-config-mcp-stop'],
                pending_native_evidence=['original-message-operation'],
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
    if not all(k in record for k in ('stopped', 'reserve')) or record.get('stage') not in ('launch', 'bound', 'deliver', 'consumed'):
        result['state'] = record['state']
        return result
    try:
        result['bound'] = backend.bound(record['plan'], record['reservation'], seconds=0)
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
        require(not any('id' in e and 'method' in e for e in client.events), 'native has a pending server request')
        source = source_process(plan)
        SLEEP['quiet_processes'](source)
        require(observe.kernel(proof['pid']) == plan['processes']['native'], 'native kernel lifetime changed')
        # Config hashes prove unchanged effective config. shell-exec is only
        # the dependency's measured exec-target basis, never historical code.
        return dict(mode='idle', turn_id=turn['id'], mcp_config=source.get('sleep_mcp', {}),
                    mcp_basis=source.get('sleep_mcp_basis', {}))
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
                'automatic continuation unavailable: native execution gate and message operation missing')
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
        SLEEP['quiet_processes'](source_process(plan))
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

    def bound(self, plan, reservation, seconds=30):
        row = plan['binding']
        def check():
            authority.prove_stopped(dict(plan['proof']))
            require(routing(row) == plan['routing'], 'target routing differs')
            receipt = json.loads(launch.option(row['pane'], '@authority_receipt', row['socket']) or '{}')
            proof = receipt.get('native_identity', {})
            require(receipt.get('reservation') == reservation and receipt.get('repo') == plan['context']['repo']
                    and receipt.get('worker_id') == plan['context']['worker_id'], 'target admission not yet bound')
            expected = dict(plan['hub'], reservation=reservation)
            observe.check_ack(expected, proof, receipt.get('hub_confirmation'))
            require(proof.get('native_session') == plan['proof']['native_session'] and proof != plan['proof'],
                    'target did not resume the original SID with a new lifetime')
            native = observe.kernel(proof['pid'])
            require(all(native[k] == proof[k] for k in ('pid', 'birth', 'executable'))
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
            finally:
                client.close()
            require(workspace(row['@worktree']) == plan['workspace'], 'worktree changed before continuation confirmed')
            return dict(authority_receipt=receipt, native_identity=proof, workspace=plan['workspace'])
        return check() if seconds == 0 else wait_for(check, seconds)

    def target(self, plan, record):
        """The bound lifetime, read fresh: same SID, the bound PID/birth, never the original."""
        row, bound = plan['binding'], record['bound']['native_identity']
        snap = observe.runtime.read(row['pane'], socket=row['socket'])
        ident = snap.get('identity') or {}
        require(ident.get('native_session') == plan['proof']['native_session']
                and all(ident.get(k) == bound.get(k) for k in ('pid', 'birth', 'executable'))
                and ident.get('pid') != plan['proof']['pid'], 'message target is not the bound new lifetime')
        require(routing(row) == plan['routing'], 'target routing changed before delivery')
        return snap

    def deliver(self, plan, record):
        m = message(plan)
        snap = self.target(plan, record)
        # The continuation hands over the same tree it stopped; the turn may change it.
        require(workspace(plan['binding']['@worktree']) == plan['workspace'], 'worktree changed before delivery')
        result = observe.runtime.accept_if_idle(plan['binding']['pane'], snap, m['operation'], m['text'],
                                                plan['binding']['socket'])
        if result.get('state') == 'rejected':
            raise Rejected(result.get('reason') or 'rejected')
        receipt = result.get('receipt') or {}
        require(result.get('state') == 'accepted' and result.get('delivery_id') == m['operation']
                and receipt.get('delivery_id') == m['operation']
                and receipt.get('native_session') == plan['proof']['native_session']
                and isinstance(receipt.get('turn_id'), str) and receipt['turn_id'],
                'original message delivery unconfirmed')
        return dict(operation=m['operation'], receipt=receipt,
                    native_identity={k: snap['identity'].get(k) for k in observe.runtime.NATIVE})

    def consumed(self, plan, record):
        """An independent read of the bound thread: the accepted turn carries the
        operation as its userMessage clientId. The delivery's own answer is not it."""
        m, accepted = message(plan), record['deliver']['receipt']
        self.target(plan, record)
        row, sid = plan['binding'], plan['proof']['native_session']
        data = observe.runtime.CODEX['identity'](row['pane'], row['socket'])
        require(data.get('session_id') == sid, 'target native identity changed')
        client = observe.runtime.RPC(data['remote'], timeout=5, peer_pid=record['bound']['native_identity']['pid'])
        try:
            found, turn, _ = observe.runtime.codex_receipt(client, sid, m['operation'], accepted.get('anchor_turn_id'))
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
    args = parser.parse_args()
    if args.preflight or args.apply:
        print(json.dumps(automatic_capability(), indent=2))
        return 1
    if args.preflight:
        require(args.pane and args.pid and args.sid, 'explicit pane/PID/SID required')
        try:
            plan = inspect(args.pane, args.socket, args.pid, args.sid)
        except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, EOFError) as error:
            print(json.dumps(unavailable(error), indent=2))
            return 1
        print(json.dumps(plan, indent=2))
        return 0
    if args.status:
        print(json.dumps(read(args.status), indent=2))
        return 0
    if args.reconcile:
        result = reconcile(read(args.reconcile), Native())
        print(json.dumps(result, indent=2))
        return 0 if result['state'] in ('bound', 'consumed') else 1
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
        return 0 if record['state'] == ('consumed' if message(plan) else 'bound') else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError, EOFError):
        print('continuation refused or unconfirmed; preserve the original execution/journal', file=sys.stderr)
        sys.exit(1)
