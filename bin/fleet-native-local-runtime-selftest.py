#!/usr/bin/env python3
"""Explicit offline native TUI/runtime ownership probe, never a live Fleet launch."""
import argparse
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import runpy
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time


def stop(process):
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    executable = shutil.which(arguments.codex)
    if not executable:
        parser.error('native Codex binary is required')
    binary = str(Path(executable).resolve())
    client_type = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-codex-rpc.py'))['Client']
    checks, phases, requests = [], [], []

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append({'path': self.path, 'authorization': bool(self.headers.get('Authorization'))})
            body = b'{"error":{"message":"offline runtime fixture: inference disabled"}}'
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    endpoint = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    serving = threading.Thread(target=endpoint.serve_forever, daemon=True)
    serving.start()
    try:
        for label, worktree, bypass in (('local', False, False), ('worktree', True, False),
                                        ('worktree-bypass', True, True)):
            with tempfile.TemporaryDirectory(prefix='fleet-local-', dir='/tmp') as temporary:
                root = Path(temporary).resolve()
                home = root / 'home'
                codex_home = home / '.codex'
                codex_home.mkdir(parents=True)
                environment = {'HOME': str(home), 'CODEX_HOME': str(codex_home), 'PATH': os.environ['PATH'],
                               'TMPDIR': str(root), 'XDG_CONFIG_HOME': str(home / '.config'),
                               'XDG_CACHE_HOME': str(home / '.cache'), 'TERM': 'xterm-256color',
                               'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                               'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                               'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}

                def git(*values):
                    return subprocess.check_output(['git', *map(str, values)], env=environment,
                                                   text=True, stderr=subprocess.PIPE, timeout=15).strip()

                base = root / 'repo'
                git('init', '--quiet', base)
                (base / 'tracked').write_text('original\n')
                git('-C', base, 'add', 'tracked')
                git('-C', base, 'commit', '--quiet', '-m', 'fixture')
                original_head = git('-C', base, 'rev-parse', 'HEAD')
                (codex_home / 'config.toml').write_text(
                    'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
                    '[features]\ndaemon_auto_start=true\nhooks=false\nremote_plugin=false\n'
                    '[model_providers.offline]\nname="offline fixture"\n'
                    f'base_url="http://127.0.0.1:{endpoint.server_port}/v1"\n'
                    'wire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n'
                    '[projects.' + json.dumps(str(base)) + ']\ntrust_level="trusted"\n')
                version = subprocess.check_output([binary, '--version'], env=environment,
                                                  text=True, stderr=subprocess.PIPE, timeout=10).strip()
                with (root / 'server.log').open('w') as logfile:
                    backend = subprocess.Popen([binary, 'app-server', '--listen', 'unix://'], cwd=base,
                                               env=environment, stdin=subprocess.DEVNULL, stdout=logfile,
                                               stderr=logfile, start_new_session=True)
                    child = descriptor = rpc = None
                    try:
                        socket_path = codex_home / 'app-server-control/app-server-control.sock'
                        deadline = time.monotonic() + 10
                        while not socket_path.exists() and backend.poll() is None and time.monotonic() < deadline:
                            time.sleep(.05)
                        check(socket_path.exists() and backend.poll() is None, label + ': owned foreground backend ready')
                        rpc = client_type('unix://' + str(socket_path), timeout=4, peer_pid=backend.pid)
                        state = json.loads(subprocess.check_output([binary, 'app-server', 'daemon', 'version'],
                                           env=environment, cwd=base, text=True, stderr=subprocess.PIPE, timeout=10))
                        check(state['status'] == 'running' and Path(state['socketPath']).resolve() == socket_path.resolve(),
                              label + ': native discovery identifies the kernel-verified owned socket: '
                              + json.dumps(state).replace(str(root), '<fixture>'))
                        check(state['cliVersion'] == state['appServerVersion'] and state['managedCodexVersion'] is None,
                              label + ': same native build without a managed package installation')
                        check(rpc.call('thread/loaded/list', {})['data'] == [], label + ': backend initially owns no threads')
                        config = rpc.call('config/read', {'includeLayers': False})['config']
                        check(config['model_provider'] == 'offline', label + ': backend configuration uses only fixture provider')
                        before = len(requests)
                        descriptor, slave = pty.openpty()
                        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
                        command = [binary, '--cd', str(base)]
                        if worktree:
                            command.append('--worktree')
                        if bypass:
                            command.append('--dangerously-bypass-hook-trust')
                        command.append('Offline ownership fixture. Do not run tools.')
                        try:
                            child = subprocess.Popen(command, cwd=base, env=environment, stdin=slave,
                                                     stdout=slave, stderr=slave, start_new_session=True)
                        finally:
                            os.close(slave)
                        metadata = None
                        terminal = bytearray()
                        deadline = time.monotonic() + 25
                        while time.monotonic() < deadline and child.poll() is None:
                            if select.select([descriptor], [], [], .1)[0]:
                                try:
                                    chunk = os.read(descriptor, 65536)
                                except OSError:
                                    break
                                terminal.extend(chunk)
                                for query, answer in ((b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[c', b'\x1b[?1;2c'),
                                                      (b'\x1b[>c', b'\x1b[>0;1;0c')):
                                    if query in terminal:
                                        os.write(descriptor, answer)
                                        terminal = terminal.replace(query, b'')
                                terminal = terminal[-32768:]
                            for rollout in codex_home.glob('sessions/**/*.jsonl'):
                                with rollout.open() as stream:
                                    try:
                                        first = json.loads(stream.readline())
                                    except json.JSONDecodeError:
                                        continue
                                if first.get('type') == 'session_meta':
                                    metadata = first['payload']
                            if metadata is not None and len(requests) > before:
                                break
                        check(child.poll() is None and metadata is not None, label + ': real TUI remains alive with native metadata')
                        check(len(requests) == before + 1 and requests[-1]['path'] == '/v1/responses'
                              and not requests[-1]['authorization'], label + ': exactly one loopback request without credentials')
                        identifier = metadata['id']
                        cwd = Path(metadata['cwd']).resolve()
                        loaded = rpc.call('thread/loaded/list', {})['data']
                        observed = rpc.call('thread/read', {'threadId': identifier, 'includeTurns': False})['thread']
                        check(observed['id'] == identifier and Path(observed['cwd']).resolve() == cwd,
                              label + ': native history reports exact root and cwd')
                        check(observed['modelProvider'] == 'offline', label + ': native thread provider is the fixture')
                        check((identifier in loaded) == (not bypass), label + ': live ownership matches bypass boundary')
                        check((observed['status']['type'] == 'notLoaded') == bypass,
                              label + ': readable history does not imply live ownership')
                        statuses = [event['params']['status']['type'] for event in rpc.events
                                    if event.get('method') == 'thread/status/changed'
                                    and event.get('params', {}).get('threadId') == identifier]
                        check(bool(statuses) == (not bypass), label + ': native status events follow actual owner')
                        if worktree:
                            check(cwd != base and cwd.is_relative_to(codex_home / 'worktrees'),
                                  label + ': native worktree is outside base checkout')
                            common = git('-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir')
                            check(Path(common).resolve() == base / '.git', label + ': native directory belongs to fixture repository')
                            check(git('-C', cwd, 'rev-parse', 'HEAD') == original_head,
                                  label + ': native worktree starts from original commit')
                        else:
                            check(cwd == base, label + ': non-worktree control retains base cwd')
                        marker = cwd / 'uncommitted-fixture'
                        marker.write_text('preserve\n')
                        stop(child)
                        check(marker.read_text() == 'preserve\n', label + ': TUI shutdown preserves uncommitted data')
                        if worktree:
                            check(not (base / marker.name).exists() and (base / 'tracked').read_text() == 'original\n',
                                  label + ': base checkout remains unchanged')
                        check(not (home / 'Library/LaunchAgents').exists()
                              and not (home / '.config/systemd').exists()
                              and not (codex_home / 'packages').exists(), label + ': no managed package or service installed')
                        check(backend.poll() is None, label + ': owned backend remains alive until fixture cleanup')
                        phases.append({'phase': label, 'version': version, 'owns_live_thread': identifier in loaded,
                                       'thread_state': observed['status']['type'], 'native_statuses': statuses,
                                       'worktree': worktree, 'hook_trust_bypass': bypass})
                    finally:
                        stop(child)
                        if descriptor is not None:
                            os.close(descriptor)
                        if rpc is not None:
                            rpc.close()
                        stop(backend)
        print(json.dumps({'scope': 'offline runtime ownership, not authentication, guards, MCP or panel acceptance',
                          'checks': checks, 'phases': phases}, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
