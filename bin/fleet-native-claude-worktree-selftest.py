#!/usr/bin/env python3
"""Explicit isolated Claude Worktree probe; model requests rejected locally."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading


def capture_hook(destination, fleet_root, supervisor):
    sys.path.insert(0, str(fleet_root / 'bin'))
    import fleet_launch
    payload = json.load(sys.stdin)
    native = fleet_launch.native_parent()
    if not fleet_launch.root_native(native, supervisor):
        raise ValueError('hook native process is outside the fixture supervisor')
    record = {key: payload.get(key) for key in ('hook_event_name', 'source', 'session_id', 'cwd')}
    record.update(process=native, hook_cwd=os.getcwd(), project_dir=os.environ.get('CLAUDE_PROJECT_DIR'))
    try:
        expected = os.environ.get('FLEET_LAUNCH_WORKTREE')
        record['worktree'] = (fleet_launch.bind_native_worktree(payload, json.loads(expected)) if expected
                              else fleet_launch.worktree_identity(payload.get('cwd')))
    except (OSError, ValueError, subprocess.SubprocessError):
        record['worktree_refused'] = True
    with destination.open('x') as output:
        json.dump(record, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default='claude')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--with-hooks', action='store_true', help='explicit non-bare offline SessionStart probe')
    parser.add_argument('--capture-hook', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--supervisor', type=int, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.capture_hook:
        if not arguments.supervisor or arguments.supervisor <= 0:
            parser.error('hook capture requires its fixture supervisor')
        capture_hook(arguments.capture_hook, arguments.fleet_root, arguments.supervisor)
        return
    executable = shutil.which(arguments.claude)
    if not executable:
        parser.error('native Claude binary is required')
    binary = str(Path(executable).resolve())
    checks, requests, hooks = [], [], []
    if arguments.with_hooks:
        for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
            if managed.exists():
                parser.error('non-bare fixture requires a host without machine-managed Claude configuration')

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            requests.append({'path': self.path, 'model': payload.get('model'),
                             'fixture_key': self.headers.get('x-api-key') == 'fixture-not-a-credential'})
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
        with tempfile.TemporaryDirectory(prefix='fleet-native-claude-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home = root / 'home'
            home.mkdir()
            repo = root / 'repository'
            environment = {'HOME': str(home), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
                           'PATH': os.environ['PATH'], 'TMPDIR': str(root),
                           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                           'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                           'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
                           'ANTHROPIC_API_KEY': 'fixture-not-a-credential',
                           'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{endpoint.server_port}',
                           'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1'}

            def git(*args):
                return subprocess.check_output(['git', *map(str, args)], env=environment, text=True,
                                               stderr=subprocess.PIPE, timeout=20).strip()

            def worktrees():
                return {Path(field[9:]).resolve()
                        for field in git('-C', repo, 'worktree', 'list', '--porcelain', '-z').split('\0')
                        if field.startswith('worktree ')}

            def execute(label, *options, directory=None):
                previous = len(requests)
                mode = ['--bare']
                native_environment = dict(environment)
                hook_path = root / (label + '-hook.json')
                if arguments.with_hooks:
                    if hooks:
                        native_environment['FLEET_LAUNCH_WORKTREE'] = json.dumps(hooks[0]['worktree'])
                    command = shlex.join([sys.executable, str(Path(__file__).resolve()),
                        '--fleet-root', str(arguments.fleet_root.resolve()), '--capture-hook', str(hook_path),
                        '--supervisor', str(os.getpid())])
                    settings = {'hooks': {'SessionStart': [{'hooks': [
                        {'type': 'command', 'command': command, 'timeout': 15}]}]}}
                    mode = ['--setting-sources', '', '--settings', json.dumps(settings)]
                result = subprocess.run([binary, *mode, '-p', '--output-format', 'stream-json',
                                         '--verbose', '--tools', '', '--strict-mcp-config',
                                         '--model', 'claude-sonnet-4-6', *options, 'offline fixture'],
                                        cwd=directory or repo, env=native_environment,
                                        text=True, capture_output=True, timeout=40)
                records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
                initial = [record for record in records if record.get('type') == 'system'
                           and record.get('subtype') == 'init']
                check(len(initial) == 1, label + ': native initialization identifies one session')
                check(result.returncode == 1 and any(record.get('type') == 'result'
                      and record.get('api_error_status') == 400 for record in records),
                      label + ': only the intentional offline request rejection ends the run')
                check(len(requests) > previous, label + ': native request reaches the loopback endpoint')
                check(initial[0]['tools'] == [] and initial[0]['mcp_servers'] == [],
                      label + ': fixture cannot execute tools or MCP')
                if arguments.with_hooks:
                    check(hook_path.is_file(), label + ': native CLI actually executes the configured hook')
                    observed = json.loads(hook_path.read_text())
                    check(observed['hook_event_name'] == 'SessionStart'
                          and observed['source'] == ('startup' if label == 'create' else 'resume'),
                          label + ': native hook reports the expected lifecycle event')
                    check(observed['session_id'] == initial[0]['session_id'],
                          label + ': hook session matches native initialization')
                    observed.update(phase=label, native_cwd=initial[0]['cwd'],
                        cwd_matches_init=Path(observed['cwd']).resolve() == Path(initial[0]['cwd']).resolve())
                    if label != 'resume':
                        check(observed['cwd_matches_init'],
                              label + ': hook cwd matches the actual native Worktree')
                    else:
                        check(Path(observed['cwd']).resolve() in (repo, Path(initial[0]['cwd']).resolve()),
                              label + ': hook reports either launch cwd or restored native cwd')
                    check(Path(observed['hook_cwd']).resolve() == Path(observed['cwd']).resolve(),
                          label + ': hook process cwd agrees with its payload')
                    check(observed['process']['actual_provider'] == 'claude'
                          and observed['process']['executable'] == binary,
                          label + ': existing Fleet verifier identifies the real native ancestor')
                    if observed['cwd_matches_init']:
                        check(observed.get('worktree', {}).get('root') == str(Path(initial[0]['cwd']).resolve())
                              and (not hooks or observed['worktree'] == hooks[0]['worktree']),
                              label + ': real hook validates the registered Worktree binding')
                    else:
                        check(observed.get('worktree_refused') and 'worktree' not in observed,
                              label + ': premature base cwd cannot acquire a Worktree binding')
                    hooks.append(observed)
                return initial[0]

            git('init', '-q', repo)
            (repo / 'tracked.txt').write_text('original\n')
            git('-C', repo, 'add', '.')
            git('-C', repo, 'commit', '-qm', 'fixture')
            created = execute('create', '--worktree', 'fixture')
            worktree = Path(created['cwd']).resolve()
            check(worktree != repo and worktree.is_relative_to(repo) and worktrees() == {repo, worktree},
                  'native Claude creates exactly one registered nested Worktree')
            check(Path(git('-C', worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir')) == repo / '.git',
                  'native directory belongs to the expected Git repository')
            (worktree / 'tracked.txt').write_text('uncommitted fixture work\n')
            resumed = execute('resume', '--resume', created['session_id'])
            check(resumed['session_id'] == created['session_id'] and Path(resumed['cwd']).resolve() == worktree,
                  'resume from the base restores the exact native session and cwd')
            check(worktrees() == {repo, worktree}, 'resume does not create a second Worktree')
            check((worktree / 'tracked.txt').read_text() == 'uncommitted fixture work\n',
                  'native resume preserves uncommitted work')
            if arguments.with_hooks:
                check(hooks[0]['process']['pid'] != hooks[1]['process']['pid']
                      or hooks[0]['process']['birth'] != hooks[1]['process']['birth'],
                      'native resume preserves session identity but changes process incarnation')
                restored = execute('resume-worktree', '--resume', created['session_id'], directory=worktree)
                check(restored['session_id'] == created['session_id']
                      and Path(restored['cwd']).resolve() == worktree,
                      'explicit Worktree resume keeps the exact native session and directory')
                check(worktrees() == {repo, worktree}
                      and (worktree / 'tracked.txt').read_text() == 'uncommitted fixture work\n',
                      'explicit Worktree resume does not recreate or reset native data')
            metadata = Path(git('-C', worktree, 'rev-parse', '--absolute-git-dir'))
            check((metadata / 'CLAUDE_BASE').is_file(), 'native creator records its ownership marker')
            check((metadata / 'locked').is_file(), 'native print-mode Worktree retains its Git lock')
            drop = arguments.fleet_root / 'bin/fleet-worktree-drop.sh'
            for label in ('locked', 'explicitly-unlocked'):
                if label == 'explicitly-unlocked':
                    git('-C', repo, 'worktree', 'unlock', worktree)
                result = subprocess.run(['bash', str(drop), str(repo), str(worktree), '--force'],
                    env=dict(environment, FLEET_CONF_DIR=str(home / 'fleet-conf')), cwd=root,
                    text=True, capture_output=True, timeout=20)
                check(result.returncode == 2 and result.stdout.strip() == 'error:native-owned',
                      label + ': Fleet forced retirement defers to the native owner')
                check(worktrees() == {repo, worktree}
                      and (worktree / 'tracked.txt').read_text() == 'uncommitted fixture work\n',
                      label + ': native registration and uncommitted data remain intact')
            guard = arguments.fleet_root / 'hooks/base-readonly-guard.py'
            for label, target, expected in (('own file', worktree / 'tracked.txt', 0),
                                            ('base file', repo / 'tracked.txt', 2),
                                            ('identity marker', worktree / '.git', 2)):
                result = subprocess.run([sys.executable, str(guard)], cwd=worktree,
                    env=dict(environment, FLEET_MAIN=str(repo)), text=True, capture_output=True, timeout=10,
                    input=json.dumps({'tool_name': 'Write', 'cwd': str(worktree),
                                      'tool_input': {'file_path': str(target)}}))
                check(result.returncode == expected, 'existing Fleet guard: ' + label)
            check((repo / 'tracked.txt').read_text() == 'original\n', 'base content remains unchanged')
            check(all(request['fixture_key'] and request['path'].startswith('/v1/messages') for request in requests),
                  'observed model requests use only the fake key and loopback endpoint')
            print(json.dumps({'version': created['claude_code_version'], 'checks': checks,
                              'hooks': hooks,
                              'scope': ('non-bare print-mode with actual fixture SessionStart hooks; '
                                        if arguments.with_hooks else 'bare print-mode without hook loading; ')
                                       + 'not TUI, full MCP, authentication or Fleet launch acceptance'}, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
