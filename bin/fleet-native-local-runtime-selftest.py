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
    parser.add_argument('--launch-flags', action='store_true', help='also verify per-launch configuration, profiles and permission flags')
    parser.add_argument('--native-config', action='store_true', help='also exercise explicit native default installation in an idle fixture')
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
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            requests.append({'path': self.path, 'authorization': bool(self.headers.get('Authorization')),
                             'model': payload.get('model')})
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
    scenarios = [('local', False, False, [], 'probe', 'never', 'read-only'),
                 ('worktree', True, False, [], 'probe', 'never', 'read-only'),
                 ('worktree-bypass', True, True, [], 'probe', 'never', 'read-only')]
    if arguments.launch_flags:
        common_flags = ['-c', 'check_for_update_on_startup=false', '-c', 'features.hooks=true',
                        '-c', 'project_doc_fallback_filenames=["CLAUDE.md"]']
        scenarios.extend([
            ('worktree-config', True, False, common_flags, 'probe', 'never', 'read-only'),
            ('worktree-config-same-model', True, False, ['-c', 'model="probe"'],
             'probe', 'never', 'read-only'),
            ('worktree-config-file', True, False, [], 'probe', 'never', 'read-only'),
            ('worktree-file-and-native-flags', True, False,
             ['--model', 'probe-native', '--sandbox', 'workspace-write', '--ask-for-approval', 'on-request'],
             'probe-native', 'on-request', 'workspace-write'),
            ('worktree-model-flag', True, False, ['--model', 'probe-model-flag'],
             'probe-model-flag', 'never', 'read-only'),
            ('worktree-permissions', True, False, ['--dangerously-bypass-approvals-and-sandbox'],
             'probe', 'never', 'danger-full-access'),
            ('worktree-profile', True, False, ['--profile', 'fixture'],
             'probe-profile', 'on-request', 'workspace-write'),
            ('worktree-combined', True, False, [*common_flags, '--profile', 'fixture',
             '--dangerously-bypass-approvals-and-sandbox', '-c', 'model="probe-override"'],
             'probe-override', 'never', 'danger-full-access')])
    if arguments.native_config:
        scenarios.append(('worktree-native-config', True, False, [], 'probe', 'never', 'read-only'))
    try:
        for label, worktree, bypass, extra_flags, expected_model, expected_approval, expected_sandbox in scenarios:
            expected_owner = not bypass and label not in (
                'worktree-config', 'worktree-config-same-model', 'worktree-profile', 'worktree-combined')
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
                (codex_home / 'fixture.config.toml').write_text(
                    'model="probe-profile"\napproval_policy="on-request"\nsandbox_mode="workspace-write"\n')
                if label in ('worktree-config-file', 'worktree-file-and-native-flags'):
                    configuration = codex_home / 'config.toml'
                    configuration.write_text('check_for_update_on_startup=false\n'
                                             'project_doc_fallback_filenames=["CLAUDE.md"]\n'
                                             + configuration.read_text().replace('hooks=false', 'hooks=true'))
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
                        if label == 'worktree-native-config':
                            configuration = codex_home / 'config.toml'
                            original = configuration.read_bytes()
                            installer = arguments.fleet_root / 'bin/fleet-agent-defaults.py'
                            install_args = ['--root', str(arguments.fleet_root), '--codex-home', str(codex_home),
                                            '--codex-native-remote', 'unix://' + str(socket_path),
                                            '--codex-native-peer-pid', str(backend.pid), '--skip', 'claude',
                                            '--skip', 'codex.mcp', '--skip', 'codex.skills',
                                            '--override', str(root / 'no-overrides.json')]

                            def install(action, extra=()):
                                return subprocess.run(['python3', str(installer), action, *install_args, *extra],
                                                      env=environment, cwd=base, capture_output=True, text=True, timeout=15)

                            preview = install('apply', ['--dry-run'])
                            check(preview.returncode == 0 and configuration.read_bytes() == original,
                                  label + ': native installer dry-run writes nothing: ' + preview.stderr)
                            check(install('check').returncode == 1, label + ': native check reports missing defaults')
                            wrong_peer = install('apply', ['--codex-native-peer-pid', str(backend.pid + 100000)])
                            check(wrong_peer.returncode == 2 and configuration.read_bytes() == original,
                                  label + ': mismatched kernel peer cannot install defaults')
                            applied = install('apply')
                            check(applied.returncode == 0, label + ': native installer applies missing defaults: ' + applied.stderr)
                            installed = configuration.read_bytes()
                            check(installed != original and b'check_for_update_on_startup = false' in installed,
                                  label + ': native writer publishes defaults')
                            check(install('apply').returncode == 0 and configuration.read_bytes() == installed,
                                  label + ': native installation is byte-idempotent')
                            check(install('check').returncode == 0, label + ': native check confirms filled defaults')
                            native_apply = runpy.run_path(str(installer))['native_codex_defaults']
                            other_home = root / 'another-home'
                            other_home.mkdir()
                            try:
                                native_apply(rpc, other_home, {'check_for_update_on_startup': False}, {}, [])
                            except ValueError:
                                wrong_home = True
                            else:
                                wrong_home = False
                            check(wrong_home and not (other_home / 'config.toml').exists(),
                                  label + ': native backend cannot configure a different home')
                            layers = rpc.call('config/read', {'includeLayers': True})['layers']
                            user = next(layer for layer in layers if layer['name'].get('type') == 'user'
                                        and not layer['name'].get('profile'))
                            configuration.write_bytes(installed + b'\n# preserve concurrent comment\n')
                            rpc.call('config/batchWrite', {'filePath': str(configuration),
                                'expectedVersion': user['version'], 'reloadUserConfig': False,
                                'edits': [{'keyPath': 'project_doc_fallback_filenames', 'value': ['CLAUDE.md'],
                                           'mergeStrategy': 'upsert'}]})
                            check(b'# preserve concurrent comment' in configuration.read_bytes(),
                                  label + ': comment-only edits survive native publication, not a bytewise version contract')
                            fixture_servers = {'native.fixture': {'command': '/usr/bin/false', 'enabled': False}}
                            check(len(native_apply(rpc, codex_home, {}, fixture_servers, [])) == 1,
                                  label + ': native writer installs an inert dotted-name MCP fixture')
                            check(native_apply(rpc, codex_home, {}, fixture_servers, []) == [],
                                  label + ': native MCP installation is idempotent')
                            installed = configuration.read_bytes()
                            layers = rpc.call('config/read', {'includeLayers': True})['layers']
                            user = next(layer for layer in layers if layer['name'].get('type') == 'user'
                                        and not layer['name'].get('profile'))
                            changed = installed.replace(b'model_reasoning_effort = "high"', b'model_reasoning_effort = "low"')
                            check(changed != installed, label + ': concurrent edit changes a configuration value')
                            configuration.write_bytes(changed + b'\n# concurrent fixture edit\n')
                            concurrent = configuration.read_bytes()
                            try:
                                rpc.call('config/batchWrite', {'filePath': str(configuration),
                                    'expectedVersion': user['version'], 'reloadUserConfig': False,
                                    'edits': [{'keyPath': 'check_for_update_on_startup', 'value': True,
                                               'mergeStrategy': 'replace'}]})
                            except ValueError:
                                conflict = True
                            else:
                                conflict = False
                            check(conflict and configuration.read_bytes() == concurrent,
                                  label + ': native stale-version refusal preserves concurrent user edit')
                        config = rpc.call('config/read', {'includeLayers': False})['config']
                        check(config['model_provider'] == 'offline', label + ': backend configuration uses only fixture provider')
                        before = len(requests)
                        descriptor, slave = pty.openpty()
                        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
                        command = [binary, '--cd', str(base), *extra_flags]
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
                        metadata = turn_context = None
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
                                    for line in stream:
                                        try:
                                            record = json.loads(line)
                                        except json.JSONDecodeError:
                                            continue
                                        if record.get('type') == 'session_meta':
                                            metadata = record['payload']
                                        if record.get('type') == 'turn_context':
                                            turn_context = record['payload']
                            if (metadata is not None and len(requests) > before
                                    and (not arguments.launch_flags or turn_context is not None)):
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
                        check((identifier in loaded) == expected_owner, label + ': live ownership matches launch boundary; '
                              + json.dumps({'loaded': identifier in loaded, 'status': observed['status']}))
                        check((observed['status']['type'] == 'notLoaded') == (not expected_owner),
                              label + ': readable history does not imply live ownership')
                        statuses = [event['params']['status']['type'] for event in rpc.events
                                    if event.get('method') == 'thread/status/changed'
                                    and event.get('params', {}).get('threadId') == identifier]
                        check(bool(statuses) == expected_owner, label + ': native status events follow actual owner')
                        if label == 'worktree-native-config':
                            previous = configuration.read_bytes()
                            check(install('apply').returncode == 2 and configuration.read_bytes() == previous,
                                  label + ': loaded native thread prevents configuration installation')
                        if arguments.launch_flags:
                            check(requests[-1]['model'] == expected_model, label + ': request uses selected model')
                            check(turn_context is not None and turn_context['model'] == expected_model,
                                  label + ': persisted native turn uses selected model')
                            check(turn_context['approval_policy'] == expected_approval
                                  and turn_context['sandbox_policy']['type'] == expected_sandbox,
                                  label + ': native turn retains requested permission policy: '
                                  + json.dumps({'approval': turn_context['approval_policy'],
                                                'sandbox': turn_context['sandbox_policy']['type']}))
                            unchanged = rpc.call('config/read', {'includeLayers': False})['config']
                            check(unchanged['model'] == 'probe' and unchanged['model_provider'] == 'offline'
                                  and unchanged['approval_policy'] == 'never'
                                  and unchanged['sandbox_mode'] == 'read-only',
                                  label + ': per-launch flags do not mutate backend base configuration')
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
                                       'worktree': worktree, 'hook_trust_bypass': bypass,
                                       'flags': extra_flags, 'request_model': requests[-1]['model']})
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
