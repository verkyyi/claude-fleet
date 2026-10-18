#!/usr/bin/env python3
"""Normal Codex authority registration. Never the #4510 recovery protocol.

One observe request per reservation/lifetime, one three-field local CAS. A later
prompt only reads the exact registration; it cannot retry a lost ACK or CAS.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import tempfile

import fleet_launch as launch
import fleet_repo_authority as authority

LOCAL = ('@authority_receipt', '@codex_identity', '@codex_session_id')
BINDING = ('socket_path', 'pid', 'pane_id', 'window_id', 'pane_pid', '@fleet_id',
           '@repo', '@worktree', '@cc_agent', '@cc_launcher_pid', '@launch',
           '@launch_receipt', '@handoff_armed')


class Unconfirmed(ValueError):
    pass


def require(value, reason):
    if not value:
        raise ValueError(reason)


def read_options(pane, socket, keys):
    return {k: launch.option(pane, k, socket) for k in keys}


def snapshot(payload):
    context = json.loads(os.environ.get('FLEET_AUTHORITY_CONTEXT', '{}'))
    admission = json.loads(os.environ.get('FLEET_AUTHORITY_ADMISSION', '{}'))
    # #4573: a window with a registered linked worktree also carries `worktree`.
    require(set(context) - {'worktree'} == {'repo', 'worker_id', 'reservation', 'supervisor'},
            'unknown authority context')
    require(type(context['supervisor']) is int and context['supervisor'] > 1, 'unknown supervisor')
    require(all(admission.get(k) == context[k] for k in ('repo', 'worker_id', 'reservation')),
            'independent admission differs from context')
    authority.check_start_ack(admission, admission, 'starting')
    require(admission['repo'] == authority.repo_identity(admission['repo']), 'noncanonical repo')
    pane = os.environ.get('TMUX_PANE', '')
    socket = os.environ.get('TMUX', '').split(',')[0]
    owner = os.environ.get('FLEET_CODEX_LAUNCHER_PID', '')
    require(pane.startswith('%') and pane[1:].isdigit() and os.path.isabs(socket) and owner.isdigit(),
            'explicit original socket/pane/launcher required')
    row = read_options(pane, socket, BINDING)
    require(row['socket_path'] == socket and row['pane_id'] == pane
            and row['@cc_agent'] == 'codex' and row['@cc_launcher_pid'] == owner
            and row['@repo'].lower() == context['repo']
            and context['worker_id'].split('/')[-1] == row['@fleet_id']
            and launch.valid_uuid(row['@fleet_id']) and os.path.isabs(row['@worktree'])
            and not any(row[k] for k in ('@launch', '@launch_receipt', '@handoff_armed')),
            'current execution binding differs')
    if 'worktree' in context:
        require(launch.validate_worktree(context['worktree']) == launch.worktree_identity(row['@worktree']),
                'authority worktree differs from the window')
    native = launch.native_parent()
    require(native.get('actual_provider') == 'codex' and launch.valid_uuid(payload.get('session_id')),
            'native provider/session unknown')
    expected_sid = os.environ.get('FLEET_AUTHORITY_RESUME_SID')
    require(not expected_sid or payload['session_id'] == expected_sid, 'resume changed original native SID')
    processes = {name: launch.process(int(pid)) for name, pid in
                 (('native', native['pid']), ('launcher', owner), ('supervisor', context['supervisor']),
                  ('pane', row['pane_pid']), ('server', row['pid']))}
    require(all(processes['native'][k] == native[k] for k in ('pid', 'birth', 'executable'))
            and processes['launcher']['ppid'] == context['supervisor']
            and launch.root_native(native, context['supervisor'])
            and launch.descendant(native['pid'], int(owner))
            and launch.descendant(context['supervisor'], int(row['pane_pid'])), 'native ancestry differs')
    require(Path(payload.get('cwd', '')).resolve() == Path(row['@worktree']).resolve(), 'native cwd differs')
    proof = {k: native[k] for k in ('pid', 'birth', 'executable')}
    proof.update(worker_id=context['worker_id'], native_session=payload['session_id'])
    return dict(context=context, admission=admission, pane=pane, socket=socket, row=row,
                processes=processes, proof=proof, local=read_options(pane, socket, LOCAL))


def unchanged(s, local=None):
    require(read_options(s['pane'], s['socket'], BINDING) == s['row'], 'execution binding changed')
    require(all(launch.process(p['pid']) == p for p in s['processes'].values()), 'kernel lifetime changed')
    if local is not None:
        require(read_options(s['pane'], s['socket'], LOCAL) == local, 'local registration changed')


def check_identity(s, data):
    require(isinstance(data, dict) and data.get('owner') == s['row']['@cc_launcher_pid']
            and data.get('session_id') == s['proof']['native_session']
            and data.get('home') == str(Path(os.environ.get('CODEX_HOME', '~/.codex')).expanduser().resolve())
            and data.get('remote') == os.environ.get('FLEET_CODEX_REMOTE')
            and data.get('remote') and data.get('cwd') == s['row']['@worktree'],
            'Codex identity differs from this execution')


def journal_path(s, create=False):
    root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'native-registrations'
    if create:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not root.is_symlink() and root.stat().st_uid == os.getuid()
            and stat.S_IMODE(root.stat().st_mode) == 0o700, 'unsafe registration directory')
    key = json.dumps([s['context'], s['proof']], sort_keys=True).encode()
    return root / (hashlib.sha256(key).hexdigest() + '.json')


def read(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW)) as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600, 'unsafe registration journal')
        return json.load(stream)


def save(path, record):
    fd, tmp = tempfile.mkstemp(prefix='.registration-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def registered(s, record):
    require(record.get('context') == s['context'] and record.get('proof') == s['proof']
            and record.get('state') == 'observed/local_registered', 'authority registration remains unconfirmed')
    values = record['values']
    receipt = json.loads(values['@authority_receipt'])
    authority.check_start_ack(s['admission'], receipt['hub_confirmation'], 'observed', s['proof'])
    require(all(receipt.get(k) == v for k, v in s['context'].items()), 'authority receipt context differs')
    require(receipt.get('native_identity') == s['proof'] and receipt.get('admission') == s['admission'],
            'saved receipt differs from native/admission')
    check_identity(s, json.loads(values['@codex_identity']))
    require(values['@codex_session_id'] == s['proof']['native_session'], 'local SID differs')
    # Telemetry may enrich the identity, but it cannot change its execution.
    actual = json.loads(s['local']['@codex_identity'] or '{}')
    check_identity(s, actual)
    require(s['local']['@authority_receipt'] == values['@authority_receipt']
            and s['local']['@codex_session_id'] == values['@codex_session_id'], 'local ACK/SID differs')
    unchanged(s, s['local'])
    return record


def verify_registered(payload):
    """Subsequent ordinary prompts: reads only, no observe/recovery/retry."""
    s = snapshot(payload)
    return registered(s, read(journal_path(s)))


def commit(s, values):
    unchanged(s, s['local'])
    guards = dict(s['row'], **s['local'])
    conditions = []
    for key, value in guards.items():
        escaped = value.replace('#', '##').replace(',', '#,').replace('}', '#}')
        conditions.append('#{==:#{' + key + '},' + escaped + '}')
    condition = conditions[0]
    for other in conditions[1:]:
        condition = '#{&&:' + condition + ',' + other + '}'
    commands = ' ; '.join(shlex.join(['set-option', '-w', '-t', s['pane'], k, v]) for k, v in values.items())
    launch.tmux('if-shell', '-F', '-t', s['pane'], condition, commands, socket=s['socket'])
    unchanged(s, values)


def observe(payload, identity):
    s = snapshot(payload)
    check_identity(s, identity)
    path = journal_path(s, create=True)
    # Exclusive creation is the once-only admission to this observe operation.
    # Even an empty file after a crash forbids a second POST.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return registered(s, read(path))
    os.close(fd)
    record = dict(context=s['context'], proof=s['proof'], binding=s['row'], before=s['local'],
                  state='hub-unconfirmed/local-unchanged')
    save(path, record)
    try:
        unchanged(s, s['local'])
        ack = authority.start_call(s['context']['repo'], s['context']['reservation'],
                                   'observe', native_identity=s['proof'])
        authority.check_start_ack(s['admission'], ack, 'observed', s['proof'])
    except Exception:
        raise Unconfirmed('hub-unconfirmed/local-unchanged') from None
    receipt = dict(s['context'], native_identity=s['proof'], admission=s['admission'], hub_confirmation=ack)
    values = {'@authority_receipt': json.dumps(receipt, separators=(',', ':')),
              '@codex_identity': json.dumps(identity, separators=(',', ':')),
              '@codex_session_id': s['proof']['native_session']}
    record.update(state='hub-confirmed/local-pending', values=values)
    save(path, record)
    try:
        commit(s, values)
    except Exception:
        raise Unconfirmed('hub-confirmed/local-pending') from None
    record['state'] = 'observed/local_registered'
    save(path, record)
    return record
