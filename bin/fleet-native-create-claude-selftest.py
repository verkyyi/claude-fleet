#!/usr/bin/env python3
"""Opt-in real Claude/tmux creation proof with isolated task or repository authority fixtures."""
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
import urllib.parse
from unittest import mock

import fleet_launch as launch
import fleet_repo_authority as authority


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


def supervise_fixture(root, resume, local_authority=False, restore_entrypoint=False):
    context = json.loads((root / 'context.json').read_text())
    pane = os.environ['TMUX_PANE']
    arguments = [str(root / 'launcher'), '--model', 'claude-sonnet-4-6']
    if local_authority:
        if resume:
            previous = json.loads((root / 'saved-authority.json').read_text())
            intent = authority.restore_native_worktree(previous, previous['worktree']['root'],
                previous['native_identity']['native_session'], 'claude', context['worker_id'].split('/')[1], context['repo'])
            launch.stamp(pane, '@authority_receipt', previous)
            launch.stamp(pane, '@native_worktree', intent)
            launch.tmux('set-option', '-w', '-t', pane, '@worktree', previous['worktree']['root'])
            arguments += ['--resume', previous['native_identity']['native_session']]
        else:
            launch.stamp(pane, '@native_worktree', json.loads((root / 'intent.json').read_text()))
        launch.tmux('set-option', '-w', '-t', pane, '@fleet_id', context['worker_id'].split('/')[1])
        launch.tmux('set-option', '-w', '-t', pane, '@repo', context['repo'])
        if restore_entrypoint:
            launch.tmux('set-option', '-w', '-t', pane, '@raw', '1')
            launch.tmux('set-option', '-w', '-t', pane, '@cc_agent', 'claude')
            wrapper = root / 'home/.claude/fleet/bin/fleet-session-wrap.sh'
            return subprocess.call(['bash', str(wrapper), *arguments[1:]])
        result = authority.supervise(arguments)
        (root / ('resume-exit' if resume else 'create-exit')).write_text(str(result))
        return result
    if not resume:
        launch.stamp(pane, '@launch', context)
        launch.stamp(pane, '@native_worktree', json.loads((root / 'intent.json').read_text()))
        launch.tmux('set-option', '-w', '-t', pane, '@fleet_id', context['worker_id'].split('/')[1])
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
    parser.add_argument('--local-authority', action='store_true')
    parser.add_argument('--restore-entrypoint', action='store_true')
    parser.add_argument('--raw-entrypoint', action='store_true')
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
        return supervise_fixture(arguments.supervise_fixture, arguments.resume_fixture,
                                 arguments.local_authority, arguments.restore_entrypoint)
    if arguments.raw_entrypoint and not arguments.restore_entrypoint:
        parser.error('--raw-entrypoint requires --restore-entrypoint')
    if arguments.restore_entrypoint and not arguments.local_authority:
        parser.error('--restore-entrypoint requires --local-authority')
    if arguments.local_authority and not arguments.fleet_launcher:
        parser.error('--local-authority requires --fleet-launcher')
    for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
        if managed.exists():
            parser.error('fixture requires a host without machine-managed Claude configuration')
    if not shutil.which(arguments.claude) or not shutil.which('tmux'):
        parser.error('actual Claude and tmux binaries are required')
    binary = str(Path(shutil.which(arguments.claude)).resolve())
    terminal_type = runpy.run_path(str(launch.BIN / 'fleet-native-claude-tui-selftest.py'))['Terminal']
    checks, requests, requested_tools = [], [], []
    admission_events, admission_errors, reservations = [], [], {}

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/v1/node/client':  # the launcher's client-lease lookup, not admission
                self.send_response(404)
                self.end_headers()
                return
            if self.path.startswith('/v1/fleet/tickets/authority/start?'):
                # The independent reserved read the supervisor takes before begin.
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                key = query.get('reservation', [''])[0]
                row = reservations.get(key)
                valid = (arguments.local_authority
                         and self.headers.get('Authorization') == 'Bearer fixture-authority-only'
                         and query == {'repo': [context['repo']], 'reservation': [key]}
                         and row is not None and row['state'] == 'reserved')
                if not valid:
                    admission_errors.append('unexpected reserved read: ' + self.path)
                body = json.dumps(dict(repo=context['repo'], reservation=key, owner='fixture-owner',
                                       endpoint_id='fixture-node', phase='reserved')
                                  if valid else {'error': 'unexpected read'}).encode()
                self.send_response(200 if valid else 409)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            valid = (arguments.raw_entrypoint and self.path.startswith('/v1/fleet/tickets/authority?')
                     and self.headers.get('Authorization') == 'Bearer fixture-authority-only'
                     and urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                     == {'repo': [context['repo']], 'gate': ['1']})
            if not valid:
                admission_errors.append('unexpected authority gate request: ' + self.path)
            body = json.dumps({'mode': 'legacy'} if valid else {'error': 'unexpected gate'}).encode()
            self.send_response(200 if valid else 409)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            nonlocal intent, worktree
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            if self.path.startswith('/v1/fleet/tickets/authority/start'):
                try:
                    if not arguments.local_authority or self.headers.get('Authorization') != 'Bearer fixture-authority-only':
                        raise ValueError('unexpected authority credential or mode')
                    if urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query) != {'repo': [context['repo']]}:
                        raise ValueError('unexpected authority repository')
                    key, action = payload['reservation'], payload['action']
                    if not launch.valid_uuid(key):
                        raise ValueError('invalid reservation')
                    previous = reservations.get(key)
                    if action == 'reserve' and previous is None:
                        reservations[key] = dict(state='reserved')
                    elif action == 'begin' and previous and previous['state'] == 'reserved':
                        if arguments.raw_entrypoint and len(reservations) == 1:
                            worker = payload['worker_id'].split('/')
                            if len(worker) != 2 or worker[0] != context['worker_id'].split('/')[0] or not launch.valid_uuid(worker[1]):
                                raise ValueError('raw entrypoint minted a different node identity')
                            windows = [row.split('|', 1) for row in tmux('list-windows', '-t', 'fixture',
                                '-F', '#{@fleet_id}|#{@native_worktree}').splitlines()]
                            matched = [row[1] for row in windows if len(row) == 2 and row[0] == worker[1]]
                            if len(matched) != 1:
                                raise ValueError('raw admission lacks one matching native window')
                            intent = launch.validate_native_worktree(json.loads(matched[0]))
                            if intent['root'] != str(repository):
                                raise ValueError('raw admission names another repository')
                            worktree = launch.native_worktree_path(intent)
                            context['worker_id'] = payload['worker_id']
                        if payload['worker_id'] != context['worker_id']:
                            raise ValueError('different admitted worker')
                        previous['state'] = 'started'
                    elif action == 'observe' and previous and previous['state'] in ('started', 'observed'):
                        proof = payload['native_identity']
                        if proof['worker_id'] != context['worker_id'] or not launch.same_process(proof):
                            raise ValueError('observation has no matching live native process')
                        if previous.get('proof', proof) != proof:
                            raise ValueError('observation changed native identity')
                        previous.update(state='observed', proof=proof)
                    elif action == 'stopped' and previous and previous['state'] == 'observed':
                        if (payload['native_identity'] != previous['proof'] or not payload['execution_stopped']
                                or launch.same_process(previous['proof'])):
                            raise ValueError('stop lacks the exact stopped native proof')
                        previous['state'] = 'stopped'
                    else:
                        raise ValueError('invalid authority transition')
                    admission_events.append(dict(payload, worktree_exists=worktree.exists()))
                    # The exact acknowledgement the supervisor and observe hook check.
                    ack = dict(repo=context['repo'], reservation=key, owner='fixture-owner',
                               endpoint_id='fixture-node', phase=dict(begin='starting', observe='observed',
                               stopped='stopped').get(action, 'reserved'))
                    if action != 'reserve':
                        ack['worker_id'] = context['worker_id']
                    if action == 'observe':
                        ack['native_identity'] = payload['native_identity']
                    body = json.dumps(ack).encode()
                    code = 200
                except (KeyError, ValueError) as error:
                    admission_errors.append(str(error))
                    body, code = json.dumps({'error': str(error)}).encode(), 409
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
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
            pane_target = '%0'
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
            if arguments.restore_entrypoint:
                shim = root / 'tmux-bin'
                shim.mkdir()
                # The fleet's own tmux-shim execs the first other tmux on PATH --
                # this shim -- so resolve past it or the two exec each other forever.
                real_tmux = next(str(c.resolve()) for c in (Path(d) / 'tmux' for d in os.environ['PATH'].split(os.pathsep))
                                 if c.is_file() and os.access(c, os.X_OK) and c.parent.name != 'tmux-shim')
                (shim / 'tmux').write_text('#!/bin/sh\ncase "$1" in\n'
                    '  -L) [ "$2" = fixture ] || exit 2; shift 2 ;;\n'
                    '  -S) [ "$2" = ' + shlex.quote(str(socket)) + ' ] || exit 2; shift 2 ;;\n'
                    'esac\nexec ' + shlex.join([real_tmux, '-S', str(socket)]) + ' "$@"\n')
                (shim / 'tmux').chmod(0o700)
                environment.update(PATH=str(shim) + os.pathsep + environment['PATH'], SHELL='/bin/sh',
                                   FLEET_EXIT_CLOSE_SECS='0', FLEET_WRAP_FAST_FAIL='0')

            def git(*options):
                return subprocess.check_output(['git', *map(str, options)], env=environment,
                                               stderr=subprocess.PIPE, text=True, timeout=15).strip()

            def tmux(*options):
                targeted = [pane_target if option == '%0' else option for option in options]
                try:
                    return subprocess.check_output(['tmux', '-S', str(socket), '-f', os.devnull, *targeted],
                                                   env=environment, stderr=subprocess.PIPE, text=True, timeout=10).strip()
                except subprocess.CalledProcessError as error:
                    raise AssertionError('tmux ' + ' '.join(targeted[:2]) + ' failed: ' + (error.stderr or '').strip()) from error

            def restore_command(option):
                script = home / '.claude/fleet/bin/fleet-restore.sh'
                result = subprocess.run(['bash', str(script), option], env=environment, text=True,
                                        capture_output=True, timeout=90)
                if result.returncode:
                    raise AssertionError('actual restore entrypoint failed: ' + result.stdout + result.stderr)
                check(True, 'actual restore entrypoint succeeds: ' + option)
                return result.stdout

            def screen():
                return tmux('capture-pane', '-p', '-t', '%0', '-S', '-100')

            def prompt_shows(value):
                rows = screen().splitlines()
                return any(' '.join(row.split()) == '❯ ' + value and following.lstrip().startswith('─')
                           for row, following in zip(rows, rows[1:]))

            def config_events():
                path = root / 'config-events.jsonl'
                return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

            def wait(predicate, label, timeout=55):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.1)
                raise AssertionError(label + '\n' + screen() + '\n' + json.dumps(
                    dict(admission_events=admission_events, admission_errors=admission_errors, reservations=reservations))
                    + '\n' + tmux('display-message', '-p', '-t', '%0',
                        '#{pane_current_command}|#{cursor_x}|#{cursor_y}|#{@claude_state}|#{@scratch_prefill_result}'))

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
            if arguments.local_authority:
                context = dict(repo='acme/widgets', worker_id=context['worker_id'])
                fleet_config = Path(environment['FLEET_CONF_DIR']) / 'fleets/fixture'
                (fleet_config / 'repos').mkdir(parents=True)
                (fleet_config / 'conf').write_text('FLEET_TASK_AUTHORITY="legacy"\nFLEET_MODEL="claude-sonnet-4-6"\n')
                (fleet_config / 'identity').write_text(context['worker_id'].split('/')[0] + '\n')
                (fleet_config / 'repos/acme-widgets.conf').write_text(
                    'FLEET_REPO="acme/widgets"\nFLEET_MAIN=' + shlex.quote(str(repository)) + '\nFLEET_BASE_BRANCH="master"\n')
                environment.update(CCQUOTA_HUB_URL=f'http://127.0.0.1:{endpoint.server_port}',
                                   CCQUOTA_TOKEN='fixture-authority-only', FLEET_TASK_AUTHORITY='legacy')
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
            if arguments.local_authority:
                helper += ['--local-authority']
            if arguments.restore_entrypoint:
                helper += ['--restore-entrypoint']
            receipt_option = '@authority_receipt' if arguments.local_authority else '@launch_receipt'
            def read_receipt():
                raw = tmux('display-message', '-p', '-t', '%0', '#{' + receipt_option + '}')
                observed = json.loads(raw) if raw else {}
                if arguments.local_authority and observed:
                    observed = dict(observed, **observed['native_identity'])
                return observed
            receipt = None
            mcp_proofs = []
            try:
                check(not worktree.exists(), 'Fleet has not allocated a directory before the native supervisor starts')
                if arguments.raw_entrypoint:
                    tmux('new-session', '-d', '-s', 'fixture', '-n', 'dash', '-x', '120', '-y', '32',
                         '-c', str(repository), 'sleep 120')
                    script = home / '.claude/fleet/bin/dash-raw-session.sh'
                    result = subprocess.run(['bash', str(script), '--native-worktree', '--node', 'local',
                        '--agent', 'claude', '--repo', context['repo'], '--origin', 'hub', '--print',
                        '--name', 'saved', '--draft', 'native fixture request', 'fixture'], env=environment,
                        capture_output=True, text=True, timeout=90)
                    if result.returncode:
                        raise AssertionError('actual raw entrypoint failed: ' + result.stdout + result.stderr)
                    rows = result.stdout.strip().splitlines()
                    if len(rows) != 1 or len(rows[0].split('\t')) != 4:
                        raise AssertionError('raw entrypoint returned no unique window receipt: ' + result.stdout)
                    created = rows[0].split('\t')
                    pane_target = tmux('display-message', '-p', '-t', created[0], '#{pane_id}')
                    check(True, 'actual raw entrypoint admits and creates one native window')
                else:
                    tmux('new-session', '-d', '-s', 'fixture', '-n', 'saved', '-x', '120', '-y', '32', '-c', str(repository), shlex.join(helper))
                tmux('set-option', '-w', '-t', '%0', 'remain-on-exit', 'on')
                for phase in ('create', 'resume'):
                    event_offset = len(config_events()) if phase == 'resume' else 0
                    if phase == 'resume':
                        if arguments.restore_entrypoint:
                            restore_command('--snapshot')
                            mapping = (fleet_config / 'restore.map').read_text()
                            saved = [row.split('\t') for row in mapping.splitlines() if row.startswith('AUTHORITY\t')]
                            if len(saved) != 1 or json.loads(saved[0][2])['reservation'] != receipt['reservation']:
                                raise AssertionError('actual snapshot lost the ordinary admission receipt:\n' + mapping)
                            check(True, 'actual snapshot persists the observed ordinary admission receipt')
                        elif arguments.local_authority:
                            (root / 'saved-authority.json').write_text(tmux('display-message', '-p', '-t', '%0', '#{@authority_receipt}'))
                        else:
                            (root / 'saved-launch.json').write_text(json.dumps([context, receipt]))
                        tmux('kill-server')
                        # the next new-session on this socket must not reach the server
                        # still on its way out («server exited unexpectedly»)
                        for _ in range(100):
                            if not socket.exists():
                                break
                            time.sleep(0.05)
                        check(worktree.is_dir(), 'native directory survives loss of the isolated tmux server')
                        if arguments.restore_entrypoint:
                            tmux('new-session', '-d', '-s', 'fixture', '-n', 'dash', '-x', '120', '-y', '32',
                                 '-c', str(repository), 'sleep 120')
                            report = restore_command('--restore')
                            windows = [row.split('|') for row in tmux('list-windows', '-t', 'fixture',
                                '-F', '#{@fleet_id}|#{pane_id}').splitlines()]
                            restored = [row[1] for row in windows if len(row) == 2 and row[0] == context['worker_id'].split('/')[1]]
                            check(len(restored) == 1, 'actual restore reconstructs exactly one matching native window')
                            pane_target = restored[0]
                            check(tmux('display-message', '-p', '-t', '%0', '#{@restore_outcome}') == 'resumed',
                                  'actual restore reports a native prompt, not a bare shell: ' + report.strip())
                        else:
                            tmux('new-session', '-d', '-s', 'fixture', '-x', '120', '-y', '32', '-c', str(repository),
                                 shlex.join(helper + ['--resume-fixture']))
                            tmux('set-option', '-w', '-t', '%0', 'remain-on-exit', 'on')
                    def ready():
                        observed = read_receipt()
                        if arguments.local_authority:
                            return bool(observed) and (not receipt or observed['reservation'] != receipt['reservation'])
                        return observed.get('phase') == ('ready' if phase == 'create' else 'resumed')
                    wait(ready, phase + ': native process/worktree receipt was not verified')
                    observed = read_receipt()
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
                                and '--group orch' not in row   # the dispatch group (#4334) is not the core
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
                        check(not requests, 'native startup sends no model request before explicit input')
                        draft = 'native fixture request' if arguments.raw_entrypoint else 'offline fixture'
                        if not arguments.raw_entrypoint:
                            tmux('send-keys', '-t', '%0', '-l', draft)
                        wait(lambda: prompt_shows(draft), 'native unsent draft was not visible in its input line')
                        if arguments.raw_entrypoint:
                            check(created[2:] == [str(worktree), observed['worker_id'].split('/')[1]],
                                  'raw window receipt matches the admitted native directory and worker')
                            check(True, 'actual creation entrypoint delivers the draft without fixture keystrokes')
                        check(not requests, 'visible native draft remains unsent until Enter')
                        tmux('send-keys', '-t', '%0', 'Enter')
                        wait(lambda: 'offline fixture rejection' in screen(), 'fixture model request was not rejected')
                        if arguments.fleet_launcher:
                            check(any(row.get('hook') == 'UserPromptSubmit' and row.get('session') == observed['native_session']
                                      and row.get('cwd') == str(worktree) for row in events()),
                                  'native user prompt hook survives Fleet hook composition')
                    receipt = observed
                    tmux('send-keys', '-t', '%0', '-l', '/exit')
                    wait(lambda: prompt_shows('/exit'), phase + ': native exit command was not rendered in its input line')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    wait(lambda: 'Keep worktree' in screen(), phase + ': native exit chooser missing')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    if arguments.restore_entrypoint:
                        wait(lambda: tmux('display-message', '-p', '-t', '%0', '#{@wrap_exit_rc}|#{@claude_state}') == '0|exited',
                             phase + ': actual wrapper did not observe native exit')
                        check(tmux('display-message', '-p', '-t', '%0', '#{@claude_state}') == 'exited',
                              phase + ': actual wrapper retains the exited session rather than deleting its window')
                        check(tmux('display-message', '-p', '-t', '%0', '#{pane_dead}') == '0',
                              phase + ': actual wrapper remains available for explicit reconnection')
                    else:
                        wait(lambda: tmux('display-message', '-p', '-t', '%0', '#{pane_dead}') == '1', phase + ': native exit did not finish')
                        check((root / (phase + '-exit')).read_text() == '0', phase + ': native supervisor exits successfully')
                    check(worktree.is_dir(), phase + ': native Keep retains the worktree')
                    if arguments.fleet_launcher:
                        wait(lambda: not any(launch.same_process(proof) for proof in mcp_proofs),
                             phase + ': MCP process survived native exit', timeout=5)
                        check(True, phase + ': native exit leaves no observed MCP process alive')
                check((repository / 'tracked.txt').read_text() == 'fixture\n', 'base checkout contents are unchanged')
                if arguments.local_authority:
                    check(not admission_errors, 'ordinary authority accepts every exact native identity transition'
                          + ('' if not admission_errors else ': ' + '; '.join(admission_errors)))
                    check(len(reservations) == 2 and all(row['state'] == 'stopped' for row in reservations.values()),
                          'creation and exact resume each finish their own admission reservation')
                    check([row['action'] for row in admission_events] == ['reserve', 'begin', 'observe', 'stopped'] * 2,
                          'ordinary admission precedes each verified observation and stopped report')
                    check(not any(row['worktree_exists'] for row in admission_events[:2])
                          and all(row['worktree_exists'] for row in admission_events[2:]),
                          'initial admission completes before native directory creation; resume retains it')
                    check(not tmux('display-message', '-p', '-t', '%0', '#{@launch}'),
                          'ordinary native creation never fabricates an accepted task context')
                else:
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
                print(json.dumps(dict(version=version, checks=checks, authority='loopback-local-stub' if arguments.local_authority else 'fixture-stub',
                                      finalization='native-stop' if arguments.local_authority else 'fixture-stub',
                                      recovery='actual-snapshot-and-wrapper' if arguments.restore_entrypoint else 'receipt-validator',
                                      creation='actual-raw-entrypoint' if arguments.raw_entrypoint else 'supervisor',
                                      launcher='fleet' if arguments.fleet_launcher else 'fixture'), indent=2))
            finally:
                fixture_processes = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True, timeout=5)
                fixture_proofs = [launch.process(int(row.split(None, 1)[0])) for row in fixture_processes.splitlines()
                                  if str(home / '.claude/fleet/bin/') in row]
                if socket.exists():
                    tmux('kill-server')
                for proof in mcp_proofs + fixture_proofs:
                    if launch.same_process(proof):
                        try:
                            os.kill(proof['pid'], signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and any(launch.same_process(proof) for proof in fixture_proofs):
                    time.sleep(0.1)
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)
    return 0


if __name__ == '__main__':
    sys.exit(main())
