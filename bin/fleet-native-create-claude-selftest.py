#!/usr/bin/env python3
"""Opt-in real Claude/tmux creation proof; task authority and finalization are fixture stubs."""
import argparse
import http.server
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import types
from unittest import mock

import fleet_launch as launch


def fixture_event(root, event):
    descriptor = os.open(root / 'config-events.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(event) + '\n').encode())
    finally:
        os.close(descriptor)


def mcp_fixture(root, name):
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get('method')
        fixture_event(root, dict(server=name, method=method, cwd=os.getcwd(), pid=os.getpid()))
        if 'id' not in request:
            continue
        if method == 'initialize':
            result = dict(protocolVersion=request['params']['protocolVersion'], capabilities={'tools': {}},
                          serverInfo={'name': name, 'version': '1'})
        elif method == 'tools/list':
            result = {'tools': [{'name': 'fixture_probe', 'description': 'Offline fixture only',
                                'inputSchema': {'type': 'object', 'properties': {}}}]}
        elif method == 'tools/call':
            result = {'content': [{'type': 'text', 'text': 'offline fixture'}]}
        else:
            result = {}
        print(json.dumps(dict(jsonrpc='2.0', id=request['id'], result=result)), flush=True)
    return 0


def configure_fleet_launcher(root, home, repository, environment, binary):
    installation = home / '.claude/fleet'
    for directory in ('bin', 'conf', 'hooks', 'mod'):
        shutil.copytree(launch.BIN.parent / directory, installation / directory,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    helper = str(Path(__file__).resolve())
    def server(name):
        return {'command': sys.executable, 'args': [helper, '--mcp-fixture', name, '--fixture-root', str(root)]}
    defaults = json.loads((installation / 'conf/agent-defaults/claude/mcp.default.json').read_text())['mcpServers']
    expected = set(defaults) | {'fixture_user', 'fixture_project'}
    config_path = home / '.claude.json'
    config = json.loads(config_path.read_text())
    config['mcpServers'] = {name: server(name) for name in set(defaults) | {'fixture_user'}}
    config_path.write_text(json.dumps(config))
    settings_path = home / '.claude/settings.json'
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    command = shlex.join([sys.executable, helper, '--hook-fixture', '--fixture-root', str(root)])
    settings['hooks'] = {event: [{'hooks': [{'type': 'command', 'command': command}]}]
                         for event in ('SessionStart', 'UserPromptSubmit')}
    settings_path.write_text(json.dumps(settings))
    (repository / '.claude').mkdir(exist_ok=True)
    (repository / '.claude/settings.json').write_text(json.dumps({'enableAllProjectMcpServers': True}))
    (repository / '.mcp.json').write_text(json.dumps({'mcpServers': {'fixture_project': server('fixture_project')}}))
    environment['FLEET_CLAUDE_BIN'] = binary
    environment['FLEET_PRETRUST'] = '0'
    (root / 'launcher').write_text('#!/bin/sh\nexec ' + shlex.quote(str(installation / 'bin/fleet-claude.sh')) + ' "$@"\n')
    return expected


def supervise_fixture(root, resume):
    context = json.loads((root / 'context.json').read_text())
    pane = os.environ['TMUX_PANE']
    if not resume:
        launch.stamp(pane, '@launch', context)
        launch.stamp(pane, '@native_worktree', json.loads((root / 'intent.json').read_text()))
        launch.tmux('set-option', '-w', '-t', pane, '@fleet_id', context['worker_id'].split('/')[1])
    arguments = [str(root / 'launcher'), '--model', 'claude-sonnet-4-6']
    if resume:
        saved_context, previous = json.loads((root / 'saved-launch.json').read_text())
        if saved_context != context:
            raise ValueError('fixture saved task context changed')
        fleet_id = context['worker_id'].split('/')[1]
        intent = launch.restore_native_worktree(context, previous, previous['worktree']['root'],
                                               previous['native_session'], 'claude', fleet_id)
        launch.stamp(pane, '@launch', context)
        launch.stamp(pane, '@launch_receipt', previous)
        launch.stamp(pane, '@native_worktree', intent)
        launch.tmux('set-option', '-w', '-t', pane, '@fleet_id', fleet_id)
        launch.tmux('set-option', '-w', '-t', pane, '@worktree', previous['worktree']['root'])
        launch.tmux('set-option', '-w', '-t', pane, '@launch_started', '1')
        arguments += ['--resume', previous['native_session']]

    def task_call(bound, mutation=None):
        if bound != context:
            raise ValueError('fixture task identity mismatch')
        if mutation:
            with (root / 'mutations.jsonl').open('a') as output:
                output.write(json.dumps(mutation) + '\n')
        return dict(owner=context['owner'], generation=context['generation'],
                    execution_owner=context['worker_id'], resolved_agent=context['provider'])

    def run(arguments, **options):
        if str(launch.BIN / 'fleet_task_control.py') in arguments:
            (root / 'finalize-requested').touch()
            return subprocess.CompletedProcess(arguments, 0, '', '')
        return subprocess.run(arguments, **options)

    process_api = types.SimpleNamespace(**vars(subprocess))
    process_api.run = run
    with mock.patch.object(launch, 'task_call', side_effect=task_call), \
            mock.patch.object(launch, 'subprocess', process_api):
        result = launch.supervise(arguments)
    (root / ('resume-exit' if resume else 'create-exit')).write_text(str(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default='claude')
    parser.add_argument('--fleet-launcher', action='store_true')
    parser.add_argument('--mcp-fixture', help=argparse.SUPPRESS)
    parser.add_argument('--hook-fixture', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--fixture-root', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--supervise-fixture', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--resume-fixture', action='store_true', help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.mcp_fixture:
        return mcp_fixture(arguments.fixture_root, arguments.mcp_fixture)
    if arguments.hook_fixture:
        payload = json.load(sys.stdin)
        fixture_event(arguments.fixture_root, dict(hook=payload['hook_event_name'], cwd=payload['cwd'],
                                                  session=payload['session_id']))
        return 0
    if arguments.supervise_fixture:
        return supervise_fixture(arguments.supervise_fixture, arguments.resume_fixture)
    for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
        if managed.exists():
            parser.error('fixture requires a host without machine-managed Claude configuration')
    if not shutil.which(arguments.claude) or not shutil.which('tmux'):
        parser.error('actual Claude and tmux binaries are required')
    binary = str(Path(shutil.which(arguments.claude)).resolve())
    terminal_type = runpy.run_path(str(launch.BIN / 'fleet-native-claude-tui-selftest.py'))['Terminal']
    checks, requests, requested_tools = [], [], []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            requested_tools.append([tool.get('name') for tool in payload.get('tools', [])])
            requests.append(self.headers.get('x-api-key') == 'fixture-not-a-credential')
            body = b'{"type":"error","error":{"type":"invalid_request_error","message":"offline fixture rejection"}}'
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
        with tempfile.TemporaryDirectory(prefix='fleet-native-create-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home, repository, socket = root / 'home', root / 'repository', root / 'tmux.sock'
            home.mkdir()
            environment = dict(HOME=str(home), CLAUDE_CONFIG_DIR=str(home / '.claude'),
                FLEET_CONF_DIR=str(home / 'fleet-conf'), PATH=os.environ['PATH'], TMPDIR=str(root),
                TERM='xterm-256color', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
                ANTHROPIC_API_KEY='fixture-not-a-credential',
                ANTHROPIC_BASE_URL=f'http://127.0.0.1:{endpoint.server_port}',
                CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1')
            if arguments.fleet_launcher:
                environment.pop('CLAUDE_CONFIG_DIR')

            def git(*options):
                return subprocess.check_output(['git', *map(str, options)], env=environment,
                                               stderr=subprocess.PIPE, text=True, timeout=15).strip()

            def tmux(*options):
                return subprocess.check_output(['tmux', '-S', str(socket), '-f', os.devnull, *options],
                                               env=environment, stderr=subprocess.PIPE, text=True, timeout=10).strip()

            def screen():
                return tmux('capture-pane', '-p', '-t', '%0', '-S', '-100')

            def config_events():
                path = root / 'config-events.jsonl'
                return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

            def wait(predicate, label, timeout=55):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.1)
                raise AssertionError(label + '\n' + screen())

            git('init', '-q', '-b', 'master', repository)
            (repository / 'tracked.txt').write_text('fixture\n')
            (repository / '.gitignore').write_text('.claude/worktrees/\n')
            git('-C', repository, 'add', '.')
            git('-C', repository, 'commit', '-qm', 'fixture')
            version = subprocess.check_output([binary, '--version'], env=environment, text=True, timeout=15).strip()
            command = [binary, '--setting-sources', '', '--strict-mcp-config', '--tools', '', '--model', 'claude-sonnet-4-6']
            terminal = terminal_type(command, repository, environment)
            try:
                terminal.wait('Choose the text style')
                terminal.send('\r')
                terminal.wait('Do you want to use this API key?')
                terminal.send('\x1b[A')
                terminal.wait('❯ Yes')
                time.sleep(0.5)
                terminal.send('\r')
                terminal.wait('Security notes:')
                terminal.send('\r')
                terminal.wait('Yes, I trust this folder')
                check(str(repository) in terminal.text(), 'only the temporary repository is trusted through native UI')
                time.sleep(1.5)
                terminal.send('\x1b[B')
                terminal.wait('❯ Yes, I trust this folder')
                time.sleep(0.5)
                terminal.send('\r')
                terminal.ready()
                terminal.send('/exit\r')
                terminal.finish()
            finally:
                terminal.close()

            expected_servers = set()
            if arguments.fleet_launcher:
                expected_servers = configure_fleet_launcher(root, home, repository, environment, binary)
                git('-C', repository, 'add', '.claude/settings.json', '.mcp.json')
                git('-C', repository, 'commit', '-qm', 'fixture native project configuration')
            intent = launch.new_native_worktree(str(repository), 'master')
            worktree = launch.native_worktree_path(intent)
            context = dict(version=1, operation_id='11111111-1111-4111-8111-111111111111',
                task='T1', owner='fixture', generation=1,
                worker_id='22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333',
                provider='claude', attempt_id='task:T1:g1')
            (root / 'intent.json').write_text(json.dumps(intent))
            (root / 'context.json').write_text(json.dumps(context))
            hook_command = shlex.join([sys.executable, str(launch.BIN / 'fleet-codex-session.py'), 'hook'])
            settings = {'hooks': {'SessionStart': [{'hooks': [
                {'type': 'command', 'command': hook_command, 'timeout': 15}]}]}}
            (root / 'settings.json').write_text(json.dumps(settings))
            launcher = '#!/bin/sh\nexec ' + shlex.join([binary, '--setting-sources', '',
                '--settings', str(root / 'settings.json'), '--strict-mcp-config', '--tools', '']) + ' "$@"\n'
            if not arguments.fleet_launcher:
                (root / 'launcher').write_text(launcher)
            (root / 'launcher').chmod(0o700)
            helper = [sys.executable, str(Path(__file__).resolve()), '--supervise-fixture', str(root)]
            receipt = None
            mcp_proofs = []
            try:
                check(not worktree.exists(), 'Fleet has not allocated a directory before the native supervisor starts')
                tmux('new-session', '-d', '-s', 'fixture', '-x', '120', '-y', '32', '-c', str(repository), shlex.join(helper))
                tmux('set-option', '-w', '-t', '%0', 'remain-on-exit', 'on')
                for phase in ('create', 'resume'):
                    event_offset = len(config_events()) if phase == 'resume' else 0
                    if phase == 'resume':
                        (root / 'saved-launch.json').write_text(json.dumps([context, receipt]))
                        tmux('kill-server')
                        check(worktree.is_dir(), 'native directory survives loss of the isolated tmux server')
                        tmux('new-session', '-d', '-s', 'fixture', '-x', '120', '-y', '32', '-c', str(repository),
                             shlex.join(helper + ['--resume-fixture']))
                        tmux('set-option', '-w', '-t', '%0', 'remain-on-exit', 'on')
                    def ready():
                        raw = tmux('display-message', '-p', '-t', '%0', '#{@launch_receipt}')
                        if not raw:
                            return False
                        observed = json.loads(raw)
                        return observed.get('phase') == ('ready' if phase == 'create' else 'resumed')
                    wait(ready, phase + ': native process/worktree receipt was not verified')
                    observed = json.loads(tmux('display-message', '-p', '-t', '%0', '#{@launch_receipt}'))
                    check(observed['native_worktree'] == intent, phase + ': receipt proves the exact creation intent')
                    check(observed['worktree'] == launch.worktree_identity(str(worktree)),
                          phase + ': receipt matches the actual registered native directory')
                    check(tmux('display-message', '-p', '-t', '%0', '#{@worktree}') == str(worktree),
                          phase + ': native hook records the actual worktree on the window')
                    check(len(git('-C', repository, 'worktree', 'list', '--porcelain').split('worktree ')) == 3,
                          phase + ': only the base and one native worktree exist')
                    if arguments.fleet_launcher:
                        def events():
                            return config_events()[event_offset:]
                        wait(lambda: expected_servers <= {row.get('server') for row in events() if row.get('method') == 'tools/list'},
                             phase + ': configured MCP servers were not all loaded')
                        check(bool(tmux('display-message', '-p', '-t', '%0', '#{@agent_cfg}')),
                              phase + ': actual Fleet configuration composer stamps its fingerprint')
                        wait(lambda: bool(tmux('display-message', '-p', '-t', '%0', '#{@mod_ver}')),
                             phase + ': native Fleet plugin did not report its version', timeout=10)
                        check(bool(tmux('display-message', '-p', '-t', '%0', '#{@mod_alive}')),
                              phase + ': native Fleet plugin reports its live heartbeat')
                        check(any(row.get('hook') == 'SessionStart' and row.get('session') == observed['native_session']
                                  and row.get('cwd') == str(worktree) for row in events()),
                              phase + ': native user hook survives Fleet hook composition')
                        check(all(row['cwd'] == str(worktree) for row in events() if row.get('method') == 'tools/list'),
                              phase + ': configured MCP servers start in the actual native worktree')
                        check(all(launch.descendant(row['pid'], observed['pid']) for row in events()
                                  if row.get('method') == 'tools/list'),
                              phase + ': MCP observations belong to this native process incarnation')
                        processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True, timeout=5)
                        core = [int(row.split(None, 1)[0]) for row in processes.splitlines()
                                if str(home / '.claude/fleet/bin/fleet-mcp.py') in row
                                and launch.descendant(int(row.split(None, 1)[0]), observed['pid'])]
                        check(len(core) == 1, phase + ': Fleet mounts exactly one core MCP process')
                        mcp_proofs = [launch.process(pid) for pid in set(core) |
                                      {row['pid'] for row in events() if row.get('method') == 'tools/list'}]
                    if receipt:
                        check(observed['native_session'] == receipt['native_session'], 'supervised resume retains the exact native session')
                        check(observed['pid'] != receipt['pid'] or observed['birth'] != receipt['birth'],
                              'supervised resume proves a new native process incarnation')
                        check((worktree / 'tracked.txt').read_text() == 'retained fixture\n', 'supervised resume retains edits')
                    else:
                        (worktree / 'tracked.txt').write_text('retained fixture\n')
                        tmux('send-keys', '-t', '%0', '-l', 'offline fixture')
                        tmux('send-keys', '-t', '%0', 'Enter')
                        wait(lambda: 'offline fixture rejection' in screen(), 'fixture model request was not rejected')
                        if arguments.fleet_launcher:
                            check(any(row.get('hook') == 'UserPromptSubmit' and row.get('session') == observed['native_session']
                                      and row.get('cwd') == str(worktree) for row in events()),
                                  'native user prompt hook survives Fleet hook composition')
                    receipt = observed
                    tmux('send-keys', '-t', '%0', '-l', '/exit')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    wait(lambda: 'Keep worktree' in screen(), phase + ': native exit chooser missing')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    wait(lambda: tmux('display-message', '-p', '-t', '%0', '#{pane_dead}') == '1', phase + ': native exit did not finish')
                    check((root / (phase + '-exit')).read_text() == '0', phase + ': native supervisor exits successfully')
                    check(worktree.is_dir(), phase + ': native Keep retains the worktree')
                    if arguments.fleet_launcher:
                        wait(lambda: not any(launch.same_process(proof) for proof in mcp_proofs),
                             phase + ': MCP process survived native exit', timeout=5)
                        check(True, phase + ': native exit leaves no observed MCP process alive')
                check((repository / 'tracked.txt').read_text() == 'fixture\n', 'base checkout contents are unchanged')
                mutations = [json.loads(line) for line in (root / 'mutations.jsonl').read_text().splitlines()]
                check(len(mutations) == 2 and all(row['state'] == 'running' for row in mutations),
                      'fixture authority sees only verified running observations, never a fabricated task success')
                check(bool(requests) and all(requests), 'all received model requests carry only the fake fixture key')
                if arguments.fleet_launcher:
                    check(not any(row.get('method') == 'tools/call' for row in config_events()), 'offline rejection executes no fixture MCP tool')
                    check(any('mcp__fleet__' in str(name) for names in requested_tools for name in names),
                          'actual Fleet MCP tool definitions reach the native model request')
                    for name in expected_servers:
                        check(any(str(tool).startswith('mcp__' + name + '__') for names in requested_tools for tool in names),
                              name + ': configured MCP tool definition reaches the native model request')
                print(json.dumps(dict(version=version, checks=checks, authority='fixture-stub', finalization='fixture-stub',
                                      launcher='fleet' if arguments.fleet_launcher else 'fixture'), indent=2))
            finally:
                if socket.exists():
                    tmux('kill-server')
                for proof in mcp_proofs:
                    if launch.same_process(proof):
                        try:
                            os.kill(proof['pid'], signal.SIGTERM)
                        except ProcessLookupError:
                            pass
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)
    return 0


if __name__ == '__main__':
    sys.exit(main())
