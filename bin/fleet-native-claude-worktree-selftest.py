#!/usr/bin/env python3
"""Explicit credential-free Claude native Worktree probe; no live Fleet access."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default='claude')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    executable = shutil.which(arguments.claude)
    if not executable:
        parser.error('native Claude binary is required')
    binary = str(Path(executable).resolve())
    checks, requests = [], []

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

            def execute(label, *options):
                previous = len(requests)
                result = subprocess.run([binary, '--bare', '-p', '--output-format', 'stream-json',
                                         '--verbose', '--tools', '', '--strict-mcp-config',
                                         '--model', 'claude-sonnet-4-6', *options, 'offline fixture'],
                                        cwd=repo, env=environment, text=True, capture_output=True, timeout=40)
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
                              'scope': 'bare print-mode creation/resume and direct guard checks only; '
                                       'not TUI, hook loading, full MCP, authentication or Fleet launch acceptance'}, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
