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
import subprocess
import sys
import tempfile
import threading
import time
import types
from unittest import mock

import fleet_launch as launch


def supervise_fixture(root, resume):
    context = json.loads((root / 'context.json').read_text())
    pane = os.environ['TMUX_PANE']
    if not resume:
        launch.stamp(pane, '@launch', context)
        launch.stamp(pane, '@native_worktree', json.loads((root / 'intent.json').read_text()))
        launch.tmux('set-option', '-w', '-t', pane, '@fleet_id', context['worker_id'].split('/')[1])
    arguments = [str(root / 'launcher'), '--model', 'claude-sonnet-4-6']
    if resume:
        previous = json.loads(launch.option(pane, '@launch_receipt'))
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
    parser.add_argument('--supervise-fixture', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--resume-fixture', action='store_true', help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.supervise_fixture:
        return supervise_fixture(arguments.supervise_fixture, arguments.resume_fixture)
    for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
        if managed.exists():
            parser.error('fixture requires a host without machine-managed Claude configuration')
    if not shutil.which(arguments.claude) or not shutil.which('tmux'):
        parser.error('actual Claude and tmux binaries are required')
    binary = str(Path(shutil.which(arguments.claude)).resolve())
    terminal_type = runpy.run_path(str(launch.BIN / 'fleet-native-claude-tui-selftest.py'))['Terminal']
    checks, requests = [], []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
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

            def git(*options):
                return subprocess.check_output(['git', *map(str, options)], env=environment,
                                               stderr=subprocess.PIPE, text=True, timeout=15).strip()

            def tmux(*options):
                return subprocess.check_output(['tmux', '-S', str(socket), '-f', os.devnull, *options],
                                               env=environment, stderr=subprocess.PIPE, text=True, timeout=10).strip()

            def screen():
                return tmux('capture-pane', '-p', '-t', '%0', '-S', '-100')

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
            (root / 'launcher').write_text(launcher)
            (root / 'launcher').chmod(0o700)
            helper = [sys.executable, str(Path(__file__).resolve()), '--supervise-fixture', str(root)]
            receipt = None
            try:
                check(not worktree.exists(), 'Fleet has not allocated a directory before the native supervisor starts')
                tmux('new-session', '-d', '-s', 'fixture', '-x', '120', '-y', '32', '-c', str(repository), shlex.join(helper))
                tmux('set-option', '-w', '-t', '%0', 'remain-on-exit', 'on')
                for phase in ('create', 'resume'):
                    if phase == 'resume':
                        tmux('respawn-pane', '-t', '%0', '-c', str(repository), shlex.join(helper + ['--resume-fixture']))
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
                    receipt = observed
                    tmux('send-keys', '-t', '%0', '-l', '/exit')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    wait(lambda: 'Keep worktree' in screen(), phase + ': native exit chooser missing')
                    tmux('send-keys', '-t', '%0', 'Enter')
                    wait(lambda: tmux('display-message', '-p', '-t', '%0', '#{pane_dead}') == '1', phase + ': native exit did not finish')
                    check((root / (phase + '-exit')).read_text() == '0', phase + ': native supervisor exits successfully')
                    check(worktree.is_dir(), phase + ': native Keep retains the worktree')
                check((repository / 'tracked.txt').read_text() == 'fixture\n', 'base checkout contents are unchanged')
                mutations = [json.loads(line) for line in (root / 'mutations.jsonl').read_text().splitlines()]
                check(len(mutations) == 2 and all(row['state'] == 'running' for row in mutations),
                      'fixture authority sees only verified running observations, never a fabricated task success')
                check(bool(requests) and all(requests), 'all received model requests carry only the fake fixture key')
                print(json.dumps(dict(version=version, checks=checks, authority='fixture-stub', finalization='fixture-stub'), indent=2))
            finally:
                if socket.exists():
                    tmux('kill-server')
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)
    return 0


if __name__ == '__main__':
    sys.exit(main())
