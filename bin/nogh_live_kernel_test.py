#!/usr/bin/env python3
"""Linux CI ONLY: real private net/PID namespace, firewall and strace checks.

No fixture result from this entry is a live C9 receipt. The outer 45-second
deadline includes namespace creation, all probes and namespace destruction.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'bin'))
from nogh_live_contract import Refused, require
from nogh_live_observer import MARKER_FD, PHASES, STRACE_OPTIONS, Trace


def inside():
    require(sys.platform == 'linux' and os.getuid() == 0 and os.getpid() == 1, 'ISOLATED_PID1_REQUIRED')
    subprocess.run(['ip', 'link', 'set', 'lo', 'up'], check=True, timeout=2,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    spec = importlib.util.spec_from_file_location('render', ROOT / 'extras/managed-node/render.py')
    render = importlib.util.module_from_spec(spec); spec.loader.exec_module(render)
    destinations = [dict(ip=ip, port=18443, protocol='tcp') for ip in ('127.0.0.1', '::1')]
    guard = render.c9_egress_guard('isolated-test', destinations, destinations)
    result = subprocess.run(guard['command'], capture_output=True, timeout=5)
    require(result.returncode == 0 and result.stdout.strip() == b'C9_GUARD_READY', 'REAL_GUARD_FAILED')
    listeners, stop = [], threading.Event()
    def serve(sock):
        while not stop.is_set():
            try:
                conn, _ = sock.accept()
                with conn:
                    conn.sendall(b'allowed')
                    conn.settimeout(0.5)
                    conn.recv(64)
            except socket.timeout:
                pass
            except OSError:
                break
    try:
        for family, ip in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
            for port in (18443, 443):
                sock = socket.socket(family, socket.SOCK_STREAM)
                if family == socket.AF_INET6: sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind((ip, port)); sock.listen(); sock.settimeout(0.2)
                listeners.append(sock)
                threading.Thread(target=serve, args=(sock,), daemon=True).start()
        with tempfile.TemporaryDirectory(prefix='c9-kernel-') as temporary:
            probe = Path(temporary) / 'probe.py'
            probe.write_text('''import ctypes, os, socket, subprocess
os.write(198, b'.')
libc = ctypes.CDLL(None, use_errno=True)
assert libc.syscall(425, 1, 0) == -1 and ctypes.get_errno() == 38
for family, ip in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
    with socket.socket(family, socket.SOCK_STREAM) as s:
        s.settimeout(1); s.connect((ip, 18443)); assert s.recv(7) == b'allowed'
        s.sendall(b'PRIVATE_PAYLOAD_SENTINEL')
    with socket.socket(family, socket.SOCK_STREAM) as s:
        s.settimeout(1)
        try: s.connect((ip, 443))
        except OSError: pass
        else: raise RuntimeError('deny failed')
subprocess.run(['/usr/bin/gh', '--version'], check=True, stdout=subprocess.DEVNULL)
os.write(198, b'.' * END_SIZE)
'''.replace('END_SIZE', str(PHASES.index('end') + 1)))
            plan = dict(routes=[dict(**{'from': 'node-a'}, ip=r['ip'], port=r['port'],
                                    protocol='tcp', purpose='hub') for r in destinations], endpoints=[])
            trace = Trace(plan, 'node-a')
            read_fd, write_fd = os.pipe()
            marker = os.open('/dev/null', os.O_WRONLY)
            os.dup2(marker, MARKER_FD); os.close(marker)
            failure = []
            def consume():
                try:
                    with os.fdopen(read_fd) as source:
                        while True:
                            line = source.readline(262145)
                            if not line: break
                            trace.feed(line)
                except BaseException:
                    failure.append('ACTUAL_STRACE_FORMAT_REFUSED')
            reader = threading.Thread(target=consume, daemon=True); reader.start()
            proc = subprocess.Popen(['/usr/bin/strace', *STRACE_OPTIONS, '-o', '/proc/self/fd/%d' % write_fd,
                                     sys.executable, str(probe)],
                                    pass_fds=(write_fd, MARKER_FD), stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin', 'HOME': temporary})
            os.close(write_fd); os.close(MARKER_FD)
            code = proc.wait(timeout=8)
            reader.join(timeout=1)
            require(not reader.is_alive() and not failure, 'ACTUAL_OBSERVER_LOST')
            proof = trace.finish(code)
            counts = proof['intervals']['startup']
            require(counts.get('github_network', 0) >= 2 and counts.get('allow_hub', 0) >= 2
                    and counts.get('github_cli', 0) >= 1 and counts.get('io_uring_fenced', 0) >= 1,
                    'ACTUAL_CONTROL_COUNTS_MISSING')
            require('PRIVATE_PAYLOAD_SENTINEL' not in json.dumps(proof), 'PAYLOAD_IN_EVIDENCE')
    finally:
        stop.set()
        for listener in listeners: listener.close()


def main():
    signal.alarm(45)
    if sys.argv[1:] in (['--lifetime-cancel'], ['--lifetime-timeout']):
        require(os.getpid() == 1, 'ISOLATED_PID1_REQUIRED')
        read_fd, write_fd = os.pipe()
        if os.fork() == 0:
            if os.fork() == 0:
                os.write(write_fd, b'x')
            time.sleep(60)
            os._exit(1)
        require(os.read(read_fd, 1) == b'x', 'DESCENDANT_NOT_STARTED')
        print('READY', flush=True)
        if sys.argv[-1] == '--lifetime-timeout':
            signal.signal(signal.SIGALRM, lambda *_: os._exit(125))
            signal.alarm(1)
            signal.pause()
        require(sys.stdin.buffer.read(1) == b'x', 'CANCEL_INPUT')
        os._exit(125)
    if sys.argv[1:] == ['--inside']:
        inside()
        return
    require(sys.platform == 'linux', 'LINUX_KERNEL_TEST_REQUIRED')
    started = time.monotonic()
    result = subprocess.run(['sudo', '-n', 'unshare', '--mount', '--pid', '--fork', '--kill-child',
                             '--net', '--mount-proc', sys.executable, str(Path(__file__).resolve()), '--inside'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=40)
    # Inner output contains fixed refusal codes only, never raw trace/payload.
    if result.returncode:
        allowed = result.stderr.decode('ascii', 'ignore').strip()
        if allowed.startswith('FAIL C9 ') and len(allowed) < 200:
            print(allowed, file=sys.stderr)
    require(result.returncode == 0, 'ISOLATED_KERNEL_OR_OBSERVER_TEST_FAILED')
    for action in ('--lifetime-cancel', '--lifetime-timeout'):
        child = subprocess.Popen(['sudo', '-n', 'unshare', '--mount', '--pid', '--fork', '--kill-child',
                                  '--net', '--mount-proc', sys.executable, str(Path(__file__).resolve()), action],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            ready, _, _ = select.select([child.stdout], [], [], 3)
            require(ready and os.read(child.stdout.fileno(), 6) == b'READY\n', 'LIFETIME_NOT_READY')
            if action == '--lifetime-cancel':
                child.stdin.write(b'x'); child.stdin.flush()
            require(child.wait(timeout=3) == 125, 'LIFETIME_EXIT_CHANGED')
            # Both detached generations inherited stdout. EOF is a kernel
            # witness that PID1's exit closed ALL namespace descendants.
            ready, _, _ = select.select([child.stdout], [], [], 1)
            require(ready and os.read(child.stdout.fileno(), 1) == b'', 'DESCENDANT_SURVIVED_PID1')
        finally:
            if child.poll() is None:
                child.kill(); child.wait(timeout=1)
            child.stdin.close(); child.stdout.close()
    require(time.monotonic() - started < 45, 'KERNEL_ENTRY_BUDGET')
    print('PASS C9 isolated kernel/observer entry; live NOT RUN')


if __name__ == '__main__':
    try:
        main()
    except BaseException as exc:
        code = str(exc) if isinstance(exc, Refused) else type(exc).__name__
        print('FAIL C9 ' + code, file=sys.stderr)
        sys.exit(1)
