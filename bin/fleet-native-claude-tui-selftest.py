#!/usr/bin/env python3
"""Opt-in native Claude TUI lifecycle fixture with temporary trust and no real credentials."""
import argparse
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


class Terminal:
    def __init__(self, command, directory, environment):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
        try:
            self.process = subprocess.Popen(command, cwd=directory, env=environment,
                                            stdin=slave, stdout=slave, stderr=slave,
                                            start_new_session=True)
        except BaseException:
            os.close(self.master)
            raise
        finally:
            os.close(slave)
        self.output = b''

    def read(self, timeout):
        if select.select([self.master], [], [], timeout)[0]:
            try:
                data = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            self.output += data
        if len(self.output) > 2_000_000:
            raise AssertionError('native terminal output exceeded fixture bound')

    def text(self):
        output = self.output.decode('utf-8', errors='replace')
        output = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', output)
        output = re.sub(r'\x1b\[[0-9;?<>]*[A-Za-z]', ' ', output)
        return re.sub(r'\s+', ' ', output)

    def wait(self, expected, timeout=25):
        def visible():
            return expected in (self.output if isinstance(expected, bytes) else self.text())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if visible():
                return
            if self.process.poll() is not None:
                self.read(0)
                if visible():
                    return
                break
            self.read(min(0.1, max(0, deadline - time.monotonic())))
        raise AssertionError(f'native terminal did not show {expected!r}: {self.text()[-6000:]}')

    def send(self, value):
        self.output = b''
        os.write(self.master, value.encode())

    def ready(self):
        self.wait('❯\u00a0\x1b[7m '.encode())

    def finish(self):
        deadline = time.monotonic() + 15
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read(0.1)
        if self.process.poll() is None:
            raise AssertionError('native exit did not complete: ' + self.text()[-6000:])
        self.read(0)
        if self.process.returncode != 0:
            raise AssertionError(f'native exit status {self.process.returncode}: {self.text()[-6000:]}')

    def close(self):
        try:
            if self.process.poll() is None:
                os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=15)
        finally:
            os.close(self.master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default='claude')
    arguments = parser.parse_args()
    executable = shutil.which(arguments.claude)
    if not executable:
        parser.error('native Claude binary is required')
    for managed in (Path('/Library/Application Support/ClaudeCode'), Path('/etc/claude-code')):
        if managed.exists():
            parser.error('fixture requires a host without machine-managed Claude configuration')
    binary = str(Path(executable).resolve())
    fleet_root = Path(__file__).resolve().parent.parent
    checks, requests, phases = [], [], []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            requests.append({'path': self.path,
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
        with tempfile.TemporaryDirectory(prefix='fleet-native-claude-tui-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home = root / 'home'
            home.mkdir()
            repository = root / 'repository'
            environment = {'HOME': str(home), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
                           'PATH': os.environ['PATH'], 'TMPDIR': str(root), 'TERM': 'xterm-256color',
                           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                           'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                           'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
                           'ANTHROPIC_API_KEY': 'fixture-not-a-credential',
                           'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{endpoint.server_port}',
                           'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1'}

            def git(*options):
                return subprocess.check_output(['git', *map(str, options)], env=environment,
                                               stderr=subprocess.PIPE, text=True, timeout=15).strip()

            def worktrees():
                return {Path(field[9:]).resolve() for field in
                        git('-C', repository, 'worktree', 'list', '--porcelain', '-z').split('\0')
                        if field.startswith('worktree ')}

            git('init', '-q', repository)
            (repository / 'tracked.txt').write_text('fixture\n')
            (repository / '.gitignore').write_text('.claude/worktrees/\n')
            git('-C', repository, 'add', '.')
            git('-C', repository, 'commit', '-qm', 'fixture')
            version = subprocess.check_output([binary, '--version'], env=environment,
                                              text=True, timeout=15).strip()

            def start(label, *options, directory=None):
                hook = root / (label + '-hook.json')
                hook_command = shlex.join([sys.executable,
                    str(fleet_root / 'bin/fleet-native-claude-worktree-selftest.py'),
                    '--capture-hook', str(hook), '--supervisor', str(os.getpid())])
                settings = {'hooks': {'SessionStart': [{'hooks': [
                    {'type': 'command', 'command': hook_command, 'timeout': 15}]}]}}
                command = [binary, '--setting-sources', '', '--settings', json.dumps(settings),
                           '--strict-mcp-config', '--tools', '', '--model', 'claude-sonnet-4-6', *options]
                return Terminal(command, directory or repository, environment), hook

            def captured(terminal, hook):
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        return json.loads(hook.read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        if terminal.process.poll() is not None:
                            break
                        terminal.read(0.1)
                raise AssertionError('native SessionStart capture missing: ' + terminal.text()[-6000:])

            def persisted(terminal, identity):
                transcript = Path(identity['transcript_path']).resolve()
                check(transcript.is_relative_to(home), 'native transcript belongs to the temporary fixture home')
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    try:
                        records = [json.loads(line) for line in transcript.read_text().splitlines()]
                        kinds = {record.get('type') for record in records}
                        if {'user', 'assistant'} <= kinds:
                            check(True, 'crash occurs only after native user and response records are readable')
                            return
                    except (FileNotFoundError, json.JSONDecodeError):
                        pass
                    terminal.read(0.1)
                raise AssertionError('native transcript not persisted before crash: ' + str(transcript))

            terminal, hook = start('onboarding')
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
                check(str(repository) in terminal.text(), 'trust prompt names only the temporary fixture repository')
                time.sleep(1.5)
                terminal.send('\x1b[B')
                terminal.wait('❯ Yes, I trust this folder')
                time.sleep(0.5)
                terminal.send('\r')
                terminal.ready()
                captured(terminal, hook)
                terminal.send('/exit\r')
                terminal.finish()
                check(hook.exists(), 'native interactive onboarding reaches the actual SessionStart hook')
            finally:
                terminal.close()

            terminal, hook = start('clean', '--worktree', 'clean-fixture')
            try:
                terminal.ready()
                identity = captured(terminal, hook)
                worktree = Path(identity['worktree']['root'])
                check(worktree != repository and worktrees() == {repository, worktree},
                      'native TUI creates exactly one isolated registered worktree')
                terminal.send('/exit\r')
                terminal.finish()
                check(not worktree.exists(), 'clean untitled interactive session removes its worktree on exit')
                check('worktree-clean-fixture' not in git('-C', repository, 'branch', '--list'),
                      'native clean exit removes its branch')
                phases.append({'phase': 'clean', 'exit': terminal.process.returncode,
                               'removed': not worktree.exists()})
            finally:
                terminal.close()

            terminal, hook = start('dirty', '--worktree', 'dirty-fixture')
            try:
                terminal.ready()
                identity = captured(terminal, hook)
                worktree = Path(identity['worktree']['root'])
                (worktree / 'committed.txt').write_text('unpushed fixture\n')
                git('-C', worktree, 'add', 'committed.txt')
                git('-C', worktree, 'commit', '-qm', 'unpushed fixture')
                commit = git('-C', worktree, 'rev-parse', 'HEAD')
                (worktree / 'tracked.txt').write_text('uncommitted fixture\n')
                (worktree / 'untracked.txt').write_text('untracked fixture\n')
                outside = root / 'outside.txt'
                outside.write_text('outside fixture\n')
                (worktree / 'outside-link').symlink_to(outside)
                previous_requests = len(requests)
                terminal.send('offline fixture\r')
                terminal.wait('offline fixture rejection')
                check(len(requests) > previous_requests, 'dirty session sends its prompt only to the rejection fixture')
                terminal.send('/exit\r')
                terminal.wait('❯ 1. Keep worktree')
                check('uncommitted' in terminal.text(), 'native exit warns about pending work before removal')
                terminal.send('\r')
                terminal.finish()
                check((worktree / 'tracked.txt').read_text() == 'uncommitted fixture\n',
                      'native Keep preserves tracked edits')
                check((worktree / 'untracked.txt').read_text() == 'untracked fixture\n',
                      'native Keep preserves untracked files')
                check(git('-C', worktree, 'rev-parse', 'HEAD') == commit,
                      'native Keep preserves unpushed commits')
                check(Path(identity['worktree']['git_dir'], 'CLAUDE_BASE').exists(),
                      'native ownership evidence survives interactive Keep')
                phases.append({'phase': 'dirty-keep', 'exit': terminal.process.returncode,
                               'session_id': identity['session_id'], 'retained': worktree.is_dir()})
            finally:
                terminal.close()

            terminal, hook = start('resume-kept', '--resume', identity['session_id'], directory=worktree)
            try:
                terminal.ready()
                resumed = captured(terminal, hook)
                check(resumed['session_id'] == identity['session_id'] and resumed['source'] == 'resume',
                      'interactive resume retains the exact native session ID')
                check(resumed['worktree'] == identity['worktree'],
                      'interactive resume starts in the same registered worktree')
                check(worktrees() == {repository, worktree}, 'plain resume does not allocate a second worktree')
                check(git('-C', worktree, 'rev-parse', 'HEAD') == commit and
                      (worktree / 'tracked.txt').read_text() == 'uncommitted fixture\n',
                      'interactive resume preserves the branch and edits')
                terminal.send('/exit\r')
                terminal.finish()
                check(worktree.is_dir(), 'plain resume after Keep leaves the directory on normal exit')
                phases.append({'phase': 'resume-kept', 'exit': terminal.process.returncode,
                               'retained': worktree.is_dir()})
            finally:
                terminal.close()

            terminal, hook = start('reenter-remove', '--worktree', 'dirty-fixture',
                                   '--resume', identity['session_id'])
            try:
                terminal.ready()
                resumed = captured(terminal, hook)
                check(resumed['session_id'] == identity['session_id'] and
                      resumed['worktree'] == identity['worktree'],
                      'native worktree plus resume re-enters the same directory and session')
                check(worktrees() == {repository, worktree}, 'native re-entry does not allocate a second worktree')
                terminal.send('/exit\r')
                terminal.wait('❯ 1. Keep worktree')
                terminal.send('\x1b[B')
                terminal.wait('❯ Remove worktree')
                terminal.send('\r')
                terminal.finish()
                check(not worktree.exists(), 'only explicit native Remove deletes the dirty worktree')
                check('worktree-dirty-fixture' not in git('-C', repository, 'branch', '--list'),
                      'explicit native Remove also deletes the fixture branch')
                check(outside.read_text() == 'outside fixture\n',
                      'native removal preserves the target of a worktree symlink')
                phases.append({'phase': 'reenter-remove', 'exit': terminal.process.returncode,
                               'removed': not worktree.exists()})
            finally:
                terminal.close()

            terminal, hook = start('named', '--worktree', 'named-fixture', '--name', 'fixture session')
            try:
                terminal.ready()
                named = captured(terminal, hook)
                worktree = Path(named['worktree']['root'])
                terminal.send('/exit\r')
                terminal.wait('❯ 1. Keep worktree')
                terminal.send('\r')
                terminal.finish()
                check(worktree.is_dir(), 'clean session with a display name offers Keep rather than automatic removal')
                phases.append({'phase': 'named-clean-keep', 'exit': terminal.process.returncode,
                               'retained': worktree.is_dir()})
            finally:
                terminal.close()

            terminal, hook = start('crash', '--worktree', 'crash-fixture')
            try:
                terminal.ready()
                crashed = captured(terminal, hook)
                worktree = Path(crashed['worktree']['root'])
                (worktree / 'tracked.txt').write_text('interrupted fixture\n')
                previous_requests = len(requests)
                terminal.send('offline crash fixture\r')
                terminal.wait('offline fixture rejection')
                check(len(requests) > previous_requests, 'crash session sends its prompt only to the rejection fixture')
                persisted(terminal, crashed)
                terminal.process.kill()
                terminal.process.wait(timeout=15)
                check(terminal.process.returncode == -signal.SIGKILL and worktree.is_dir(),
                      'abrupt native process termination retains its worktree')
                check((worktree / 'tracked.txt').read_text() == 'interrupted fixture\n',
                      'abrupt termination preserves uncommitted edits')
                phases.append({'phase': 'crash', 'exit': terminal.process.returncode,
                               'session_id': crashed['session_id'], 'retained': worktree.is_dir()})
            finally:
                terminal.close()

            terminal, hook = start('crash-resume', '--resume', crashed['session_id'], directory=worktree)
            try:
                terminal.ready()
                resumed = captured(terminal, hook)
                check(resumed['session_id'] == crashed['session_id'] and
                      resumed['worktree'] == crashed['worktree'],
                      'interactive resume after a crash retains exact native ID and directory')
                check((worktree / 'tracked.txt').read_text() == 'interrupted fixture\n',
                      'interactive resume after a crash retains edits')
                terminal.send('/exit\r')
                terminal.wait('❯ 1. Keep worktree')
                terminal.send('\r')
                terminal.finish()
                check(worktree.is_dir(), 'post-crash native Keep retains the recovered directory')
                phases.append({'phase': 'crash-resume', 'exit': terminal.process.returncode,
                               'retained': worktree.is_dir()})
            finally:
                terminal.close()

            check((repository / 'tracked.txt').read_text() == 'fixture\n' and
                  git('-C', repository, 'status', '--porcelain') == '',
                  'all lifecycle phases leave the base checkout unchanged')
            check(len(requests) >= 2 and all(request['fixture_key'] for request in requests),
                  'all received model requests use only the fake fixture key and receive HTTP 400')
            print(json.dumps({'version': version, 'checks': checks, 'phases': phases, 'requests': requests}, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
