#!/usr/bin/env python3
"""Opt-in real Codex drill, with isolated HOME/tmux and fixture HTTP services.

Pass --codex /absolute/native/codex. No real account or network provider is used.
The native binary, wrapper, supervisor, launcher, runtime and credential proxy
are real. Authority HTTP and Responses are fixtures, separately covered in Go.
"""
import argparse
import base64
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import fleet_native_observe as observe

# The scenario is a live native whose observation never landed while its tool
# runs. Since #4553 the launcher's SessionStart fails closed on a refused
# observation (the turn stops), so such a session can only have been started by
# an older install: the deleted legacy install is that tree by default.
LEGACY_REF = 'b58f00d7^'

BIN = Path(__file__).resolve().parent


def wait_for(fn, seconds=30):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = fn()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('isolated native condition timed out')


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, value):
        raw = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if '/authority/start?' in self.path:
            return self.answer(200, self.server.start)
        return self.answer(200, dict(trusted=True, state='ok'))

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if '/authority/start?' in self.path:
            if self.headers.get('Authorization') != 'Bearer fixture-node':
                return self.answer(401, dict(error='fixture unauthorized'))
            action = request['action']
            if action == 'reserve':
                self.server.start = dict(reservation=request['reservation'], repo='fixture/repo',
                    owner='fixture-owner', endpoint_id='fixture-node', phase='reserved')
            elif action == 'begin':
                self.server.start.update(phase='starting', worker_id=request['worker_id'])
            elif action == 'observe':
                # The real SessionStart hook reaches this failure before local stamps.
                self.server.initial_observe += 1
                return self.answer(503, dict(error='deliberate first observation failure'))
            elif action == 'recover-observe':
                if self.server.start['phase'] != 'observed':
                    self.server.effects += 1
                self.server.start.update(phase='observed', native_identity=request['native_identity'])
                if self.server.lose_ack:
                    self.server.lose_ack = False
                    self.close_connection = True
                    return
            elif action == 'stopped':
                self.server.start['phase'] = 'stopped'
            return self.answer(200, self.server.start)
        if '/responses' not in self.path:
            return self.answer(200, {})
        self.server.requests.append(request)
        first = len(self.server.requests) == 1
        if first:
            args = dict(cmd=self.server.command, yield_time_ms=30000, max_output_tokens=100)
            output = [dict(type='function_call', id='fc_fixture', call_id='call_fixture',
                           name='exec_command', arguments=json.dumps(args))]
        else:
            output = [dict(type='message', id='msg_fixture', role='assistant', status='completed',
                           content=[dict(type='output_text', text='fixture-native-complete', annotations=[])])]
        response = dict(id='resp_fixture_' + str(len(self.server.requests)), object='response', status='completed',
                        output=output, usage=dict(input_tokens=10, output_tokens=10, total_tokens=20))
        events = [dict(type='response.created', response=dict(response, status='in_progress', output=[]))]
        for index, item in enumerate(output):
            events.extend([dict(type='response.output_item.added', output_index=index, item=item),
                           dict(type='response.output_item.done', output_index=index, item=item)])
        events.append(dict(type='response.completed', response=response))
        raw = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', required=True)
    parser.add_argument('--keep-install', action='store_true', help='normal-message control, old hooks remain available')
    parser.add_argument('--old-ref', default=LEGACY_REF,
                        help='git ref the deleted legacy install is taken from (default: before #4553)')
    parser.add_argument('--evidence', help='new absolute private JSON file outside the repository')
    args = parser.parse_args()
    assert Path(args.codex).is_absolute()
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix='native-observe-', dir='/tmp') as directory:
        root = Path(directory).resolve()
        old, home, conf, repo, work = (root / n for n in ('old', 'home', 'conf', 'repo', 'work'))
        for p in (home, conf, repo):
            p.mkdir()
        # Extract the legacy implementation, then remove THIS disposable installation.
        old.mkdir()
        archive = subprocess.run(['git', '-C', str(BIN.parent), 'archive', args.old_ref, 'bin', 'conf', 'hooks', 'commands'],
                                 capture_output=True, check=True).stdout
        subprocess.run(['tar', '-x', '-C', str(old)], input=archive, check=True)
        fake = root / 'tools'
        fake.mkdir()
        (fake / 'codex').symlink_to(args.codex)
        env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TERM', 'TMPDIR') if k in os.environ}
        env.update(HOME=str(home), FLEET_CONF_DIR=str(conf), CODEX_HOME=str(home / '.codex'),
                   PATH=str(fake) + ':' + os.environ['PATH'], FLEET_SKIP_GLOBAL_CONF='1',
                   FLEET_EXIT_CLOSE_SECS='0', FLEET_CLOSE_ON_EXIT='0', FLEET_PERSONAL='0',
                   FLEET_CRED_PROXY='1', FLEET_CRED_QUOTA_PUSH='', FLEET_CRED_BUDGET='0',
                   FLEET_CODEX_VERSION_CHECK='0', CCQUOTA_FLEET='1', FLEET_MCP='1',
                   GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                   FLEET_WRAP_LAUNCH=str(old / 'bin/fleet-codex.sh'))
        # Repo authority (#4573) wants the window's worktree to be a registered
        # linked worktree of FLEET_MAIN, not a plain directory.
        git = lambda *a: subprocess.check_output(['git', *a], env=env, text=True).strip()
        git('-C', str(repo), 'init', '-q', '-b', 'master')
        (repo / 'tracked.txt').write_text('tracked\n')
        git('-C', str(repo), 'add', 'tracked.txt')
        git('-C', str(repo), '-c', 'user.name=f', '-c', 'user.email=f@f', 'commit', '-qm', 'fixture')
        git('-C', str(repo), 'worktree', 'add', '-q', '-b', 'issue-1', str(work))
        native_home = home / '.codex'
        (native_home / 'sessions').mkdir(parents=True)
        token = 'fixture.' + base64.urlsafe_b64encode(json.dumps(dict(exp=int(time.time()) + 3600)).encode()).decode().rstrip('=') + '.fixture'
        (native_home / 'auth.json').write_text(json.dumps(dict(tokens=dict(access_token=token, account_id='fixture-account'))))
        (native_home / 'config.toml').write_text('[projects.' + json.dumps(str(work)) + ']\ntrust_level="trusted"\n')
        (root / 'mcp.json').write_text('{"mcpServers":{}}')
        env['FLEET_MCP_CONFIG'] = str(root / 'mcp.json')
        (work / 'dirty.txt').write_text('original uncommitted bytes\n')
        dirty = (work / 'dirty.txt').read_bytes()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        server.start, server.requests = {}, []
        server.initial_observe = server.effects = 0
        marker = 'existing-fixture-message-' + str(uuid.uuid4())
        server.lose_ack = False
        tool = root / 'held-tool.py'
        tool.write_text('import os,time,pathlib\np=pathlib.Path(' + repr(str(root)) + ')\n'
                        '(p/"tool-start").write_text(str(os.getpid()))\n'
                        'end=time.monotonic()+90\n'
                        'while not (p/"release").exists() and time.monotonic()<end: time.sleep(.1)\n'
                        '(p/"tool-done").write_text("completed")\n')
        server.command = 'python3 ' + str(tool)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = 'http://127.0.0.1:' + str(server.server_port)
        (conf / 'node.env').write_text('CCQUOTA_HUB_URL=' + url + '\nCCQUOTA_TOKEN=fixture-node\n')
        env['FLEET_CRED_CODEX_URL'] = url + '/provider'
        (conf / 'node-probe.json').write_text('{"loc":"US","anthropic":"reachable","openai":"reachable","verdict":"ok"}')
        (conf / 'fleet.conf').write_text('FLEET_CRED_PROXY=1\nFLEET_CRED_CODEX_URL=' + url + '/provider\n')
        fleet = conf / 'fleets/isolated'
        (fleet / 'repos').mkdir(parents=True)
        (fleet / 'identity').write_text(str(uuid.uuid4()) + '\n')
        (fleet / 'fleet.conf').write_text('FLEET_SESSION=isolated\n')
        (fleet / 'repos/fixture-repo.conf').write_text('FLEET_REPO=fixture/repo\nFLEET_MAIN=' + str(repo) + '\n')
        (fleet / 'repos/.order').write_text('fixture-repo\n')
        socket = str(root / 'tmux')
        def tmux(*a):
            return subprocess.check_output(['tmux', '-S', socket, *a], env=env, text=True).strip()
        proxy = subprocess.Popen([sys.executable, str(BIN / 'fleet-cred-proxy.py'), '--state', str(conf / 'cred-proxy'),
                                  'serve', '--max-seconds', '180', '--log', str(root / 'proxy.log')], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        natives, owned_processes = [], []
        try:
            config_check = subprocess.run([args.codex, 'mcp', 'list', '--json'], env=env, capture_output=True, text=True)
            assert config_check.returncode == 0, 'isolated native config: ' + config_check.stderr
            wait_for(lambda: (conf / 'cred-proxy/port').exists())
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'isolated', '-c', str(work), 'sleep 180')
            pane = tmux('display-message', '-p', '#{pane_id}')
            tmux('set-option', '-w', '-t', pane, 'remain-on-exit', 'on')
            for key, value in dict(fleet_id=str(uuid.uuid4()), repo='fixture/repo', worktree=str(work), fleet_role='worker').items():
                tmux('set-option', '-w', '-t', pane, '@' + key, value)
            import shlex
            command = shlex.join(['env', *[k + '=' + v for k, v in env.items()], 'bash', str(old / 'bin/fleet-session-wrap.sh'),
                                 '-m', 'gpt-5.4', 'Run the isolated fixture tool then finish.'])
            tmux('respawn-pane', '-k', '-t', pane, '-c', str(work), command)
            def find_native():
                if tmux('display-message', '-p', '-t', pane, '#{pane_dead}') == '1':
                    raise AssertionError('isolated launcher exited')
                found, todo = [], [int(tmux('display-message', '-p', '-t', pane, '#{pane_pid}'))]
                while todo:
                    pid = todo.pop()
                    children = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True)
                    todo.extend(int(v) for v in children.stdout.split())
                    try:
                        argv = observe.process_argv(pid)
                        if ('app-server' in argv and '--listen' in argv
                                and Path(observe.kernel(pid)['executable']).name == 'codex'):
                            found.append(pid)
                    except (OSError, ValueError):
                        pass
                return found
            natives = wait_for(find_native, 45)
            assert len(natives) == 1
            pid = natives[0]
            owned_processes.append(observe.kernel(pid))
            remote = observe.process_scope(pid)['FLEET_CODEX_REMOTE']
            rpc = observe.runtime.RPC(remote, timeout=5, peer_pid=pid)
            try:
                loaded = wait_for(lambda: rpc.call('thread/loaded/list', {}).get('data'))
                assert len(loaded) == 1
                sid = loaded[0]
                print('native-private-peer-and-thread: PASS', flush=True)
                wait_for(lambda: (root / 'tool-start').exists(), 45)
                print('native-tool-started: PASS', flush=True)
                tool_identity = observe.kernel(int((root / 'tool-start').read_text()))
                owned_processes.append(tool_identity)
                def user_messages():
                    thread = rpc.call('thread/read', dict(threadId=sid, includeTurns=True))['thread']
                    return [(turn['id'], item) for turn in thread['turns'] for item in turn['items'] if item['type'] == 'userMessage']
                before_messages = user_messages()
                assert server.initial_observe and not tmux('show-option', '-wqv', '-t', pane, '@codex_identity')
                if not args.keep_install:
                    shutil.rmtree(old)
                checkenv = dict(env, TMUX=socket + ',0,0', TMUX_PANE=pane, CCQUOTA_HUB_URL='https://url-only.invalid')
                checkenv.pop('CCQUOTA_TOKEN', None)
                with __import__('unittest.mock', fromlist=['patch']).patch.dict(os.environ, checkenv, clear=True):
                    observe.authority.hubrest._CREDS = None
                    plan = observe.inspect(pane, socket, pid, sid)
                    assert plan['hooks']['state'] == ('paths-present' if args.keep_install else 'missing')
                    # Negative identities are exercised against this same live
                    # native, before any recovery write. A stale birth models a
                    # reused PID; it is not a claim that the kernel recycled it.
                    try:
                        observe.inspect(pane, socket, pid, str(uuid.uuid4()))
                        raise AssertionError('foreign SID accepted')
                    except observe.Refusal:
                        pass
                    for changed in ('birth', 'phase', 'reservation'):
                        stale = copy.deepcopy(plan)
                        if changed == 'birth':
                            stale['processes']['native']['birth'] += '-prior-lifetime'
                        elif changed == 'phase':
                            stale['phase']['turn'] = {'id': 'previous-turn'}
                        else:
                            stale['context']['reservation'] = str(uuid.uuid4())
                        try:
                            observe.apply(stale)
                            raise AssertionError('stale native manifest accepted: ' + changed)
                        except observe.Refusal:
                            pass
                    assert server.effects == 0
                    assert not tmux('show-option', '-wqv', '-t', pane, '@codex_identity')
                    print('native-foreign-sid-and-stale-birth-turn-reservation: PASS (no observation write)', flush=True)
                    server.lose_ack = True
                    try:
                        observe.apply(plan)
                        raise AssertionError('lost ACK was treated as confirmed')
                    except observe.RecoveryFailure as error:
                        assert error.stage == 'hub-unconfirmed/local-unchanged'
                    assert not tmux('show-option', '-wqv', '-t', pane, '@codex_identity')
                    original_tmux = observe.launch.tmux
                    def partial(*argv, **kwargs):
                        if argv[0] == 'if-shell':
                            original_tmux(*argv[:-1], argv[-1].split(' ; ')[0], **kwargs)
                            raise OSError('injected local partial write')
                        return original_tmux(*argv, **kwargs)
                    with __import__('unittest.mock', fromlist=['patch']).patch.object(observe.launch, 'tmux', side_effect=partial):
                        try:
                            observe.apply(plan)
                            raise AssertionError('local partial write reported success')
                        except observe.RecoveryFailure as error:
                            assert error.stage == 'hub-confirmed/local-pending'
                    assert tmux('show-option', '-wqv', '-t', pane, '@authority_receipt')
                    assert not tmux('show-option', '-wqv', '-t', pane, '@codex_identity')
                    result = observe.apply(plan)
                    assert result['local_registered'] and server.effects == 1
                    observe.apply(plan)
                    assert server.effects == 1
                    assert observe.kernel(pid) == plan['processes']['native']
                    assert (work / 'dirty.txt').read_bytes() == dirty
                    assert not (root / 'tool-done').exists()
                    assert observe.kernel(tool_identity['pid']) == tool_identity
                    assert user_messages() == before_messages
                    print('native-active-observation: PASS (old install ' + ('present' if args.keep_install else 'removed') + ')', flush=True)
                (root / 'release').touch()
                wait_for(lambda: (root / 'tool-done').exists())
                print('native-tool-uninterrupted: PASS', flush=True)
                # This message is fixture-only and goes through the existing
                # queue helper. Acceptance is read from native items, not rc 0.
                delivered = subprocess.run([sys.executable, str(BIN / 'fleet-codex-session.py'), 'send',
                                           '--pane', pane], input=marker, env=dict(env, TMUX=socket + ',0,0', TMUX_PANE=pane),
                                          capture_output=True, text=True, timeout=20)
                assert delivered.returncode == 0, 'normal message helper refused: ' + delivered.stderr
                if args.keep_install:
                    received = wait_for(lambda: [x for x in user_messages() if marker in json.dumps(x)])
                    assert len(received) == 1 and received[0][0]
                    wait_for(lambda: any(marker in json.dumps(r) for r in server.requests))
                    assert len([x for x in user_messages() if marker in json.dumps(x)]) == 1
                    print('native-normal-message-item-and-turn: PASS (queue rc alone is not consumption)', flush=True)
                else:
                    time.sleep(2)
                    received = [x for x in user_messages() if marker in json.dumps(x)]
                    print('old-hooks-missing: queue acknowledged; native consumption ' + ('observed' if received else 'UNCONFIRMED') +
                          '; future_turns_verified=false', flush=True)
                # Owned fixture only: dead original native is refused, never
                # replaced by this recovery entry. No live fleet is inspected.
                os.kill(plan['processes']['tui']['pid'], signal.SIGTERM)
                def gone():
                    try: observe.kernel(pid)
                    except (ValueError, OSError, subprocess.SubprocessError): return True
                    return False
                wait_for(gone)
                try:
                    observe.inspect(pane, socket, pid, sid)
                    raise AssertionError('dead native accepted')
                except (ValueError, OSError, subprocess.SubprocessError):
                    pass
                assert server.effects == 1
                print('dead-original-native-retained: PASS', flush=True)
                if args.evidence:
                    destination = Path(args.evidence)
                    assert destination.is_absolute() and BIN.parent not in destination.resolve().parents
                    with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
                        json.dump(dict(native=True, authority='fixture', provider='fixture', manifest=plan,
                            foreign_sid_refused=True, stale_manifest_refused=['birth', 'turn', 'reservation'],
                            receipt=result, tool_identity=tool_identity, tool_completed=True, local_partial_retry=True,
                            observe_effects=server.effects, dirty_sha256=hashlib.sha256(dirty).hexdigest(),
                            message_receipt=received, message_consumption=bool(received),
                            old_install_present=args.keep_install, dead_original_refused=True), stream, indent=2)
            finally:
                rpc.close()
        except Exception:
            try:
                print(tmux('capture-pane', '-p', '-S', '-35'), file=sys.stderr)
            except Exception:
                pass
            raise
        finally:
            # Only the disposable isolated socket and owned processes are stopped.
            subprocess.run(['tmux', '-S', socket, 'kill-server'], env=env, capture_output=True)
            proxy.terminate()
            proxy.wait(timeout=10)
            server.shutdown()
            server.server_close()
            for process in owned_processes:
                try:
                    if observe.kernel(process['pid']) == process:
                        os.kill(process['pid'], signal.SIGTERM)
                except (ProcessLookupError, ValueError, subprocess.SubprocessError):
                    pass
            # Native databases and hooks may still be closing their private files.
            time.sleep(1)
    return 0


if __name__ == '__main__':
    sys.exit(main())
