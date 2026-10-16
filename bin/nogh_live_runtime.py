#!/usr/bin/env python3
"""Opt-in C9 test-container entrypoints, never a node daemon.

Only the renderer's exclusive PID-1 container can run guard/supervise. Input is
a bounded private binding, followed by fixed phase commands over attach/stdin.
There is no shell-command RPC and no attachment to pre-existing processes.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import pwd
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import time

from nogh_live_contract import Refused, canonical, read_private, require, validate, write_private
from nogh_live_observer import MARKER_FD, PHASES, STRACE_OPTIONS, Trace

STATE = Path('/run/fleet-c9')
WORKLOAD = Path('/opt/fleet-c9/workload')
ROOT = Path(__file__).resolve().parent


def emit(value):
    sys.stdout.buffer.write(canonical(value) + b'\n')
    sys.stdout.buffer.flush()


def binding(plan, role):
    validate(plan)
    ep = next((e for e in plan['endpoints'] if e['role'] == role), None)
    require(ep is not None, 'ENDPOINT_MISSING')
    require(os.environ.get('C9_POD_UID') == ep['uid']
            and os.environ.get('C9_NAMESPACE') == plan['namespace']
            and os.environ.get('C9_POD_NAME') == ep['name'], 'LOCAL_OBJECT_CHANGED')
    require(sys.platform == 'linux' and os.getpid() == 1 and os.getuid() == 0,
            'EXCLUSIVE_TEST_PID1_REQUIRED')
    require(os.environ.get('C9_TEST_ONLY') == '1', 'TEST_ONLY')
    return ep


def build_digest():
    files = ('nogh_live_runtime.py', 'nogh_live_contract.py', 'nogh_live_observer.py',
             'nogh_live_gateway.py', 'nogh_live_probe.py', 'nogh_live_http.py', 'nogh_live_identity.py')
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files}
    return 'sha256:' + hashlib.sha256(canonical(hashes)).hexdigest()


def guard(role):
    # The API server already assigned Pod UID/IP. The controller sends the
    # original full binding over attach; only then can this init container exit.
    signal.alarm(55)
    line = sys.stdin.buffer.readline(1024 * 1024 + 1)
    require(len(line) <= 1024 * 1024 and line.endswith(b'\n'), 'BINDING_INPUT_LIMIT')
    plan = json.loads(line)
    ep = binding(plan, role)
    require(ep['observer_digest'] == build_digest(), 'OBSERVER_DIGEST_CHANGED')
    build = json.loads((ROOT / 'c9-build.json').read_text())
    require(build['source_sha'] == plan['source_sha'], 'SOURCE_DIGEST_CHANGED')
    # The image records the checked strace binary; a package replaced at runtime
    # cannot silently change what the observer understands.
    require(hashlib.sha256(Path('/usr/bin/strace').read_bytes()).hexdigest() == build['strace_sha256'],
            'STRACE_BINARY_CHANGED')
    outgoing = [{k: r[k] for k in ('ip', 'port', 'protocol')}
                for r in plan['routes'] if r['from'] == role and r['purpose'] != 'github_restored']
    endpoints = {e['role']: e for e in plan['endpoints']}
    ingress = [dict(ip=endpoints[r['from']]['pod_ip'], port=r['port'], protocol=r['protocol'])
               for r in plan['routes'] if r['to'] == role]
    spec = importlib.util.spec_from_file_location('c9_render', ROOT / 'managed-render.py')
    render = importlib.util.module_from_spec(spec); spec.loader.exec_module(render)
    command = render.c9_egress_guard(ep['image'], outgoing, ingress)['command']
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=5, env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'})
    require(result.returncode == 0 and result.stdout.strip() == b'C9_GUARD_READY', 'GUARD_NOT_INSTALLED')
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_private(STATE / 'plan.json', plan)
    resolver = next(e['pod_ip'] for e in plan['endpoints'] if e['role'] == 'dns')
    fd = os.open(STATE / 'resolv.conf', os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, 'w') as target:
        target.write('nameserver %s\noptions attempts:1 timeout:1\n' % resolver)
    write_private(STATE / 'guard.json', dict(plan_digest=validate(plan), endpoint_uid=ep['uid'],
                                          generation=plan['generation'], installed=True))
    emit(dict(type='guard', endpoint_uid=ep['uid'], plan_digest=validate(plan), installed=True, live='NOT RUN'))
    return 0


def restored_policy(plan, enabled):
    """Only the trusted proxy supervisor owns this private late-allow chain."""
    import ipaddress
    routes = [r for r in plan['routes'] if r['purpose'] == 'github_restored']
    require(plan['row'] == 'A4' and routes, 'RESTORED_SCOPE')
    env = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'}
    for family in (4, 6):
        prefix = 'iptables' if family == 4 else 'ip6tables'
        backends = []
        for backend in ('nft', 'legacy'):
            check = subprocess.run([prefix + '-' + backend, '-S', 'C9_RESTORED'], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=1)
            if check.returncode == 0:
                backends.append(prefix + '-' + backend)
        require(len(backends) == 1, 'PRIVATE_CHAIN_AMBIGUOUS')
        for route in routes:
            address = ipaddress.ip_address(route['ip'])
            if address.version != family:
                continue
            rule = ['C9_RESTORED', '-d', '%s/%d' % (address, address.max_prefixlen),
                    '-p', 'tcp', '--dport', str(route['port']), '-j', 'ACCEPT']
            result = subprocess.run([backends[0], '-w', '1', '-A' if enabled else '-D', *rule], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
            require(result.returncode == 0, 'RESTORED_POLICY_FAILED')


def marker(phase):
    require(phase in PHASES, 'UNKNOWN_PHASE')
    # Only this traced broker retains the marker FD. Workload children close it.
    size = PHASES.index(phase) + 1
    require(os.write(MARKER_FD, b'.' * size) == size, 'MARKER_SHORT_WRITE')
    path = STATE / 'phase.next'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as target:
        target.write(phase)
    os.replace(path, STATE / 'phase')


def private_process():
    """Every trusted interpreter sets this AFTER exec, before reading secrets."""
    libc = ctypes.CDLL(None, use_errno=True)
    require(libc.prctl(4, 0, 0, 0, 0) == 0, 'OBSERVER_PRIVACY_FAILED')
    return libc


def workload_identity(ep):
    """Normal test login, never root or an identity capable of reaching root."""
    account = pwd.getpwnam(ep['login'])
    require(account.pw_uid >= 10000 and account.pw_gid >= 10000, 'UNPRIVILEGED_LOGIN_REQUIRED')
    directory = Path('/tmp/c9-workload')
    directory.mkdir(mode=0o700, exist_ok=False)
    os.chown(directory, account.pw_uid, account.pw_gid)
    return dict(user=account.pw_uid, group=account.pw_gid, extra_groups=[], cwd=directory,
                env=dict(os.environ, HOME=str(directory)))


def work(role, phase):
    """Verify the kernel credentials after Popen's UID transition, before exec."""
    require(os.getuid() >= 10000 and os.geteuid() == os.getuid(), 'WORKLOAD_UID')
    status = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
    require(all(int(status[k].strip(), 16) == 0 for k in ('CapPrm', 'CapEff', 'CapInh', 'CapAmb'))
            and status['NoNewPrivs'].strip() == '1', 'WORKLOAD_CAPABILITIES')
    os.execv(str(WORKLOAD), [str(WORKLOAD), phase])


def broker(role):
    """Traced control parent. All services and actions are its descendants."""
    for path in list(Path('/proc/self/fd').iterdir()):
        fd = int(path.name)
        if fd > 2 and fd != MARKER_FD:
            try: os.close(fd)
            except OSError: pass
    libc = private_process()
    plan = read_private(STATE / 'plan.json')
    ep = next(e for e in plan['endpoints'] if e['role'] == role)
    if role in ('hub', 'node-a', 'node-b'):
        require('sha256:' + hashlib.sha256(WORKLOAD.read_bytes()).hexdigest() == ep['command_digest'],
                'WORKLOAD_DIGEST_CHANGED')
    # The observer alone retains ptrace; neither the broker nor any workload can
    # attach another process or undo the network guard. Workloads run as the
    # normal dedicated login with no capabilities, never as this trusted root.
    for capability in (12, 13, 19):  # NET_ADMIN, NET_RAW, SYS_PTRACE
        require(libc.prctl(24, capability, 0, 0, 0) == 0, 'DROP_OBSERVER_CAP_FAILED')
    class Header(ctypes.Structure):
        _fields_ = [('version', ctypes.c_uint32), ('pid', ctypes.c_int)]
    class Caps(ctypes.Structure):
        _fields_ = [('effective', ctypes.c_uint32), ('permitted', ctypes.c_uint32),
                    ('inheritable', ctypes.c_uint32)]
    header, caps = Header(0x20080522, 0), (Caps * 2)()
    require(libc.capget(ctypes.byref(header), caps) == 0, 'READ_CAPABILITIES_FAILED')
    for capability in (12, 13, 19):
        for field in ('effective', 'permitted', 'inheritable'):
            setattr(caps[capability // 32], field,
                    getattr(caps[capability // 32], field) & ~(1 << (capability % 32)))
    require(libc.capset(ctypes.byref(header), caps) == 0, 'DROP_OBSERVER_CAP_FAILED')
    require(libc.prctl(38, 1, 0, 0, 0) == 0, 'NO_NEW_PRIVILEGES_FAILED')
    marker('startup')
    # This must be a real injected syscall, not just an environment toggle.
    require(libc.syscall(425, 1, 0) == -1 and ctypes.get_errno() == 38, 'IO_URING_PROBE_FAILED')
    proxy_ep = next(e for e in plan['endpoints'] if e['role'] == 'proxy')
    proxy_ports = {r['port'] for r in plan['routes'] if r['to'] == 'proxy'}
    require(len(proxy_ports) == 1, 'PROXY_PORT_AMBIGUOUS')
    proxy_url = 'http://%s:%d' % (proxy_ep['pod_ip'], next(iter(proxy_ports)))
    for key in list(os.environ):
        if key.lower() in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'):
            os.environ.pop(key)
    os.environ.update(HTTP_PROXY=proxy_url, HTTPS_PROXY=proxy_url, http_proxy=proxy_url,
                      https_proxy=proxy_url, NO_PROXY=','.join(e['pod_ip'] for e in plan['endpoints']))
    for name in ('SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS', 'GIT_SSL_CAINFO'):
        os.environ[name] = '/run/c9-credentials/ca.pem'
    identity = workload_identity(ep) if role in ('hub', 'node-a', 'node-b') else None
    started, phase = False, 'startup'
    children = []
    greeted = False
    for raw in sys.stdin.buffer:
        require(len(raw) <= 1024, 'CONTROL_LIMIT')
        request = json.loads(raw)
        require(set(request) == {'action', 'phase'}, 'CONTROL_FIELDS')
        action, requested = request['action'], request['phase']
        require(requested in PHASES, 'UNKNOWN_PHASE')
        if action == 'hello':
            require(not greeted and requested == 'startup', 'DUPLICATE_HELLO')
            greeted = True
            emit(dict(type='ready', phase=phase))
            continue
        require(greeted, 'HELLO_REQUIRED')
        if action == 'mark':
            require(requested != 'startup', 'DUPLICATE_START')
            marker(requested); phase = requested
            emit(dict(type='marked', phase=phase))
        elif action == 'run':
            require(requested == phase and phase != 'end', 'PHASE_CHANGED')
            if phase == 'startup':
                require(not started, 'ALREADY_STARTED')
                started = True
                if role in ('dns', 'proxy'):
                    # Only the independent gateway may write protocol metadata.
                    children.append(subprocess.Popen([sys.executable, str(ROOT / 'nogh_live_gateway.py'), role],
                                                     stdin=subprocess.DEVNULL, close_fds=True))
                    ready_deadline = time.monotonic() + 2
                    while not (STATE / 'gateway-ready.json').exists():
                        require(children[-1].poll() is None and time.monotonic() < ready_deadline,
                                'GATEWAY_NOT_READY')
                        time.sleep(0.01)
                    require(read_private(STATE / 'gateway-ready.json') == dict(role=role), 'GATEWAY_READY_CHANGED')
                if identity is not None:
                    children.append(subprocess.Popen([sys.executable, str(ROOT / 'nogh_live_runtime.py'),
                                                   'work', role, 'start'], stdin=subprocess.DEVNULL,
                                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                                 close_fds=True, **identity))
                emit(dict(type='result', phase=phase, exit=0))
                continue
            require(started, 'NOT_STARTED')
            if phase == 'identity':
                if role != 'hub':
                    emit(dict(type='result', phase=phase, exit=0))
                    continue
                command = [sys.executable, str(ROOT / 'nogh_live_probe.py'), 'identity']
            elif phase.startswith(('deny:', 'allow:')):
                command = [sys.executable, str(ROOT / 'nogh_live_probe.py'), phase.split(':')[1]]
            elif identity is None:
                emit(dict(type='result', phase=phase, exit=0))
                continue  # fixed gateway remains independently observed
            else:
                command = [sys.executable, str(ROOT / 'nogh_live_runtime.py'), 'work', role, phase]
            p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, close_fds=True,
                                 **({} if phase == 'identity' or phase.startswith(('deny:', 'allow:')) else identity))
            try:
                code = p.wait(timeout=5 if phase.startswith('allow:') else 2 if phase.startswith('deny:') else 30)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait(); code = 124
            emit(dict(type='result', phase=phase, exit=code))
            require(code == 0, 'ACTION_FAILED')
        elif action == 'finish':
            require(phase == requested == 'end', 'END_MARKER_REQUIRED')
            if identity is not None:
                stopped = subprocess.run([sys.executable, str(ROOT / 'nogh_live_runtime.py'),
                                          'work', role, 'stop'], stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         timeout=2, close_fds=True, **identity)
                require(stopped.returncode == 0, 'NORMAL_STOP_FAILED')
            # Stop only direct children we created; namespace PID1 handles any
            # uncooperative/detached descendants on failure. Such a run cannot
            # pass because its trace never closes normally.
            for child in children:
                if child.poll() is None: child.terminate()
            for child in children:
                try: child.wait(timeout=1)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            return 0
        elif action == 'cancel':
            return 125
        else:
            raise Refused('UNKNOWN_CONTROL')
    raise Refused('CONTROL_EOF_BEFORE_FINISH')


def supervise(role):
    plan = read_private(STATE / 'plan.json')
    ep = binding(plan, role)
    installed = read_private(STATE / 'guard.json')
    require(installed == dict(plan_digest=validate(plan), endpoint_uid=ep['uid'],
                              generation=plan['generation'], installed=True), 'GUARD_BINDING_CHANGED')
    require(ep['observer_digest'] == build_digest(), 'OBSERVER_DIGEST_CHANGED')
    for path in list(Path('/proc/self/fd').iterdir()):
        try: target = os.readlink(path)
        except FileNotFoundError: continue
        require(not target.startswith('socket:'), 'INHERITED_SOCKET')
    # No workload may ptrace the supervisor or read its private trace pipe.
    private_process()
    read_fd, write_fd = os.pipe()
    marker_read, marker_write = os.pipe()
    os.dup2(marker_write, MARKER_FD, inheritable=True)
    os.close(marker_write)
    trace = Trace(plan, role)
    argv = ['/usr/bin/strace', *STRACE_OPTIONS, '-o', '/proc/self/fd/%d' % write_fd,
            sys.executable, str(Path(__file__).resolve()), 'broker', role]
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               pass_fds=(write_fd, MARKER_FD), close_fds=True)
    os.close(write_fd); os.close(MARKER_FD)
    selector = selectors.DefaultSelector()
    streams = {read_fd: 'trace', marker_read: 'marker', sys.stdin.fileno(): 'input',
               process.stdout.fileno(): 'output', process.stderr.fileno(): 'error'}
    for fd, name in streams.items():
        os.set_blocking(fd, False); selector.register(fd, selectors.EVENT_READ, name)
    buffers = {name: bytearray() for name in streams.values()}
    errors, trace_eof, results, gateway = False, False, {}, []
    restored = False
    drained = set()
    deadline = time.monotonic() + plan['budget_seconds']
    try:
        while selector.get_map():
            require(time.monotonic() < deadline, 'DEADLINE_EXCEEDED')
            for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                fd, name = key.fd, key.data
                block = os.read(fd, 65536)
                if not block:
                    selector.unregister(fd)
                    drained.add(name)
                    if name == 'trace': trace_eof = True
                    if name == 'input' and process.poll() is None:
                        process.stdin.close()
                    continue
                if name == 'marker': continue
                if name == 'error':
                    errors = True  # no raw diagnostic is retained or printed
                    continue
                buffers[name].extend(block)
                require(len(buffers[name]) <= 262144, 'STREAM_LIMIT')
                while b'\n' in buffers[name]:
                    line, _, rest = buffers[name].partition(b'\n')
                    buffers[name] = bytearray(rest)
                    if name == 'trace':
                        trace.feed(line.decode('utf-8', 'strict') + '\n')
                    elif name == 'input':
                        request = json.loads(line)
                        require(set(request) == {'action', 'phase'} and request['action'] in
                                ('hello', 'mark', 'run', 'finish', 'cancel') and request['phase'] in PHASES, 'CONTROL_FIELDS')
                        if role == 'proxy' and request['action'] == 'mark':
                            enable = request['phase'] == 'row:A4-restored'
                            if enable != restored:
                                restored_policy(plan, enable)
                                restored = enable
                        process.stdin.write(canonical(request) + b'\n'); process.stdin.flush()
                    else:
                        value = json.loads(line)
                        if value.get('type') == 'gateway':
                            require(role in ('dns', 'proxy') and set(value) ==
                                    {'type', 'source', 'category', 'phase'}, 'GATEWAY_FORMAT')
                            require(value['source'] in {e['role'] for e in plan['endpoints']}
                                    and value['category'] in ('github_network', 'unknown', 'allow_provider',
                                                              'allow_forge', 'allow_dns', 'allow_github_restored',
                                                              'success_provider', 'success_forge', 'success_github_restored')
                                    and value['phase'] in PHASES and len(gateway) < 100000, 'GATEWAY_SCOPE')
                            gateway.append(value)
                        else:
                            require(value.get('type') in ('ready', 'marked', 'result')
                                    and value.get('phase') in PHASES, 'BROKER_FORMAT')
                            if value['type'] == 'result':
                                require(set(value) == {'type', 'phase', 'exit'} and type(value['exit']) is int,
                                        'BROKER_FORMAT')
                                results[value['phase']] = value['exit']
                            else:
                                require(set(value) == {'type', 'phase'}, 'BROKER_FORMAT')
                            emit(value)
            if process.poll() is not None and {'trace', 'output', 'error', 'marker'} <= drained:
                break
        code = process.wait(timeout=1)
        require({'trace', 'output', 'error', 'marker'} <= drained and trace_eof and not errors
                and not any(buffers[k] for k in ('trace', 'output', 'input')), 'OBSERVER_LOST')
        proof = trace.finish(code)
        proof.update(type='observation', role=role, endpoint_uid=ep['uid'], generation=plan['generation'],
                     execution_generation=ep['execution_generation'], plan_digest=validate(plan),
                     command_results=results, gateway=gateway)
        write_private(STATE / 'observation.json', proof)
        emit(proof)
        return 0
    finally:
        # In this entrypoint we ARE the exclusive test PID1. Its exit closes the
        # namespace; never use a host process scan, kill(-1), or a shared cgroup.
        selector.close()
        if process.poll() is None:
            process.terminate()
        for fd in (read_fd, marker_read):
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('guard', 'supervise', 'broker', 'work'))
    parser.add_argument('role', choices=('hub', 'node-a', 'node-b', 'proxy', 'dns'))
    parser.add_argument('phase', nargs='?')
    args = parser.parse_args()
    def stop(*_):
        raise Refused('CANCELLED_OR_EXPIRED')
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGALRM, stop)
    signal.alarm(55)
    try:
        if args.action == 'work':
            require(args.phase in (*PHASES, 'start', 'stop'), 'WORKLOAD_PHASE')
            return work(args.role, args.phase)
        return {'guard': guard, 'supervise': supervise, 'broker': broker}[args.action](args.role)
    except BaseException as exc:
        # The exception may originate in a JSON value, executable or syscall;
        # only this constant crosses the evidence boundary.
        code = str(exc) if isinstance(exc, Refused) else 'C9_RUNTIME_UNAVAILABLE'
        emit(dict(type='failure', code=code, live='NOT RUN'))
        return 125


if __name__ == '__main__':
    sys.exit(main())
