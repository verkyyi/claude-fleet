#!/usr/bin/env python3
"""Opt-in real Codex drill for the one-shot continuation (#4775).

Pass --codex /absolute/native/codex. Like fleet_native_observe_native_test.py:
isolated HOME / tmux socket / FLEET_CONF_DIR, the native binary, wrapper,
launcher, runtime and credential proxy are real; authority HTTP and Responses
are fixtures (no real account, no provider quota). The original session starts
from a disposable copy of this install which is then deleted, so its fixed
hooks are gone; the continuation stops it and resumes the SAME SID through the
CURRENT standard launcher, then hands the original message over idle accept.

--mcp fleet mounts the fleet's own MCP server from the deleted copy (the SPACE
shape: its config path is gone with the install); the default mounts none.
Only the disposable socket and processes this drill started are ever stopped.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from unittest import mock
import uuid

import fleet_native_observe as observe
import fleet_native_continue as continuation

BIN = Path(__file__).resolve().parent


def wait_for(fn, seconds=30, what='isolated native condition'):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = fn()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError(what + ' timed out')


def step(name, detail=''):
    print(name + ': PASS' + (' (' + detail + ')' if detail else ''), flush=True)


class Fixture(BaseHTTPRequestHandler):
    """Authority start + Responses. One start record per reservation."""

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
            from urllib.parse import urlparse, parse_qs
            q = parse_qs(urlparse(self.path).query)
            key = (q.get('reservation') or [self.server.current])[0]
            return self.answer(200, self.server.starts.get(key, {}))
        return self.answer(200, dict(trusted=True, state='ok'))

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        if '/authority/start?' in self.path:
            if self.headers.get('Authorization') != 'Bearer fixture-node':
                return self.answer(401, dict(error='fixture unauthorized'))
            action, key = request['action'], request.get('reservation')
            self.server.actions.append((action, key))
            if action == 'reserve':
                self.server.starts[key] = dict(reservation=key, repo='fixture/repo', owner='fixture-owner',
                                               endpoint_id='fixture-node', phase='reserved')
                self.server.current = key
            start = self.server.starts.get(key)
            if start is None:
                return self.answer(404, dict(error='fixture unknown reservation'))
            if action == 'begin':
                start.update(phase='starting', worker_id=request['worker_id'])
            elif action == 'observe':
                start.update(phase='observed', native_identity=request['native_identity'])
            elif action == 'recover-observe':
                start.update(phase='observed', native_identity=request['native_identity'])
            elif action == 'stopped':
                start['phase'] = 'stopped'
            return self.answer(200, start)
        if '/responses' not in self.path:
            return self.answer(200, {})
        self.server.requests.append(request)
        if len(self.server.requests) == 1 and self.server.command:
            args = dict(cmd=self.server.command, yield_time_ms=30000, max_output_tokens=100)
            output = [dict(type='function_call', id='fc_fixture', call_id='call_fixture',
                           name='exec_command', arguments=json.dumps(args))]
        else:
            text = 'fixture-native-complete-' + str(len(self.server.requests))
            output = [dict(type='message', id='msg_fixture', role='assistant', status='completed',
                           content=[dict(type='output_text', text=text, annotations=[])])]
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


class Traced(continuation.Native):
    """The product backend, printing why a stage raised (the journal keeps only the stage)."""
    def __getattribute__(self, name):
        attr = super().__getattribute__(name)
        if name in ('preflight', 'stop', 'stopped', 'reserve', 'launch', 'bound', 'deliver', 'consumed'):
            def traced(*a, **k):
                try:
                    return attr(*a, **k)
                except Exception as error:
                    print('stage %s raised %s: %s' % (name, type(error).__name__, error), file=sys.stderr, flush=True)
                    raise
            return traced
        return attr


def verbose_wait_for(fn, seconds):
    """continuation.wait_for, printing each distinct reason it is still waiting."""
    until, last = time.monotonic() + seconds, None
    while True:
        try:
            result = fn()
            if result:
                return result
        except (ValueError, OSError, subprocess.SubprocessError, EOFError) as error:
            if str(error) != last:
                print('waiting: %s: %s' % (type(error).__name__, error), file=sys.stderr, flush=True)
                last = str(error)
        if time.monotonic() >= until:
            raise ValueError('bounded continuation check unconfirmed')
        time.sleep(.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', required=True)
    parser.add_argument('--mcp', choices=('none', 'fleet'), default='none')
    parser.add_argument('--old-ref', help='git ref the deleted legacy install is taken from (default: this tree)')
    parser.add_argument('--loop-control', action='store_true',
                        help='remove the install while a tool runs: show the missing-Stop-hook loop and that nothing touches it')
    parser.add_argument('--keep', action='store_true', help='leave the temp dir for inspection')
    parser.add_argument('--evidence', help='new absolute private JSON file outside the repository')
    args = parser.parse_args()
    assert Path(args.codex).is_absolute()
    os.umask(0o077)
    directory = tempfile.mkdtemp(prefix='native-continue-', dir='/tmp')
    root = Path(directory).resolve()
    old, home, conf, repo = (root / n for n in ('old', 'home', 'conf', 'repo'))
    work = root / 'work'
    for p in (home, conf, repo):
        p.mkdir()
    if args.old_ref:
        old.mkdir()
        archive = subprocess.run(['git', '-C', str(BIN.parent), 'archive', args.old_ref, 'bin', 'conf', 'hooks', 'commands'],
                                 capture_output=True, check=True).stdout
        subprocess.run(['tar', '-x', '-C', str(old)], input=archive, check=True)
    else:
        for name in ('bin', 'conf', 'hooks', 'commands'):
            shutil.copytree(BIN.parent / name, old / name, ignore=shutil.ignore_patterns('__pycache__'))
    fake = root / 'tools'
    fake.mkdir()
    (fake / 'codex').symlink_to(args.codex)
    env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TERM', 'TMPDIR') if k in os.environ}
    path = ':'.join(p for p in os.environ['PATH'].split(':') if 'tmux-shim' not in p)
    env.update(HOME=str(home), FLEET_CONF_DIR=str(conf), CODEX_HOME=str(home / '.codex'),
               PATH=str(fake) + ':' + path, FLEET_SKIP_GLOBAL_CONF='1',
               FLEET_EXIT_CLOSE_SECS='0', FLEET_CLOSE_ON_EXIT='0', FLEET_PERSONAL='0',
               FLEET_CRED_PROXY='1', FLEET_CRED_QUOTA_PUSH='', FLEET_CRED_BUDGET='0',
               FLEET_CODEX_VERSION_CHECK='0', CCQUOTA_FLEET='1', FLEET_MCP='1',
               GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
               FLEET_WRAP_LAUNCH=str(old / 'bin/fleet-codex.sh'))
    git = lambda *a: subprocess.check_output(['git', *a], env=env, text=True).strip()
    git('-C', str(repo), 'init', '-q', '-b', 'master')
    (repo / 'tracked.txt').write_text('tracked\n')
    git('-C', str(repo), 'add', 'tracked.txt')
    git('-C', str(repo), '-c', 'user.name=f', '-c', 'user.email=f@f', 'commit', '-qm', 'fixture')
    git('-C', str(repo), 'worktree', 'add', '-q', '-b', 'issue-1', str(work))
    work = work.resolve()
    (work / 'dirty.txt').write_text('original uncommitted bytes\n')
    (work / 'tracked.txt').write_text('tracked, modified and unstaged\n')
    native_home = home / '.codex'
    (native_home / 'sessions').mkdir(parents=True)
    token = 'fixture.' + base64.urlsafe_b64encode(json.dumps(dict(exp=int(time.time()) + 3600)).encode()).decode().rstrip('=') + '.fixture'
    (native_home / 'auth.json').write_text(json.dumps(dict(tokens=dict(access_token=token, account_id='fixture-account'))))
    (native_home / 'config.toml').write_text('[projects.' + json.dumps(str(work)) + ']\ntrust_level="trusted"\n')
    if args.mcp == 'none':
        (root / 'mcp.json').write_text('{"mcpServers":{}}')
        env['FLEET_MCP_CONFIG'] = str(root / 'mcp.json')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    server.starts, server.requests, server.actions = {}, [], []
    server.current = server.legacy = None
    tool = root / 'held-tool.py'
    tool.write_text('import os,time,pathlib\np=pathlib.Path(' + repr(str(root)) + ')\n'
                    '(p/"tool-start").write_text(str(os.getpid()))\n'
                    'end=time.monotonic()+120\n'
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

    def tree_hash():
        return continuation.workspace(str(work))

    proxy = subprocess.Popen([sys.executable, str(BIN / 'fleet-cred-proxy.py'), '--state', str(conf / 'cred-proxy'),
                              'serve', '--max-seconds', '600', '--log', str(root / 'proxy.log')], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    owned, report = [], dict(native=True, authority='fixture', provider='fixture', mcp=args.mcp)
    pane = None
    try:
        wait_for(lambda: (conf / 'cred-proxy/port').exists())
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'isolated', '-c', str(work), 'sleep 600')
        pane = tmux('display-message', '-p', '#{pane_id}')
        tmux('set-option', '-w', '-t', pane, 'remain-on-exit', 'on')
        for key, value in dict(fleet_id=str(uuid.uuid4()), repo='fixture/repo', worktree=str(work),
                               fleet_role='worker', issue='1').items():
            tmux('set-option', '-w', '-t', pane, '@' + key, value)
        command = shlex.join(['env', *[k + '=' + v for k, v in env.items()], 'bash', str(old / 'bin/fleet-session-wrap.sh'),
                              '-m', 'gpt-5.4', 'Run the isolated fixture tool then finish.'])
        tmux('respawn-pane', '-k', '-t', pane, '-c', str(work), command)

        def natives():
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
        found = wait_for(natives, 60, 'original native')
        assert len(found) == 1
        pid = found[0]
        owned.append(observe.kernel(pid))
        server.legacy = server.current
        remote = observe.process_scope(pid)['FLEET_CODEX_REMOTE']

        def rpc_call(method, params, peer=pid, address=None):
            client = observe.runtime.RPC(address or remote, timeout=5, peer_pid=peer)
            try:
                return client.call(method, params)
            finally:
                client.close()
        sid = wait_for(lambda: rpc_call('thread/loaded/list', {}).get('data'), 30, 'original thread')[0]
        assert rpc_call('thread/loaded/list', {})['data'] == [sid]
        wait_for(lambda: (root / 'tool-start').exists(), 60, 'original tool')
        tool_identity = observe.kernel(int((root / 'tool-start').read_text()))
        owned.append(tool_identity)
        report['mcp_before_removal'] = {x['name']: continuation.MCP.runtime_ready(x)
                                        for x in rpc_call('mcpServerStatus/list', {})['data']}
        import fleet_sleep_argv
        children = [int(c) for c in subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout.split()]
        mcp_env = {}
        for child in children:
            argv = observe.process_argv(child)
            if len(argv) > 1 and Path(argv[1]).name == 'fleet-mcp.py':
                mcp_env[' '.join(argv[2:]) or 'core'] = sorted(fleet_sleep_argv.process_env(child, set())['names'])
        report['mcp_child_env_names'] = mcp_env
        native_only = {'FLEET_CRED_SID', 'FLEET_CODEX_SESSION_CRED', 'FLEET_AUTHORITY_CONTEXT', 'PYTHONPYCACHEPREFIX', 'GIT_CONFIG_GLOBAL'}
        assert mcp_env and all(not native_only & set(names) for names in mcp_env.values()), mcp_env
        step('codex-0.162.1-mcp-child-env', 'allowlist + env_vars only, native-only variables absent')

        def thread_now():
            return rpc_call('thread/read', dict(threadId=sid, includeTurns=True))['thread']

        def idle():
            try:
                t = thread_now()
            except ValueError:
                return False
            return t['status']['type'] == 'idle' and t['turns'][-1].get('status') == 'completed' and t
        if not args.loop_control:
            # SPACE's shape: the original finished its work while its install
            # still existed and was idle when the install went away.
            (root / 'release').touch()
            wait_for(lambda: (root / 'tool-done').exists(), 30, 'tool completion')
            wait_for(idle, 60, 'original idle with its hooks present')
        before_tree = tree_hash()
        shutil.rmtree(old)
        step('old-install-removed', 'original tool still running' if args.loop_control else 'original idle')
        checkenv = dict(env, TMUX=socket + ',0,0', TMUX_PANE='%9999', CCQUOTA_HUB_URL='https://url-only.invalid')
        checkenv.pop('CCQUOTA_TOKEN', None)
        checkenv.pop('FLEET_WRAP_LAUNCH', None)
        with mock.patch.dict(os.environ, checkenv, clear=True):
            observe.authority.ticket._CREDS = None
            plan = observe.inspect(pane, socket, pid, sid)
            assert plan['hooks']['state'] == 'missing' and plan['hub']['phase'] == 'observed', plan['hooks']
            step('legacy-observed', 'hooks missing, hub phase observed')
            if args.loop_control:
                try:
                    continuation.inspect(pane, socket, pid, sid)
                    raise AssertionError('active original accepted')
                except (ValueError, OSError, subprocess.SubprocessError) as error:
                    report['active_refusal'] = continuation.unavailable(error)['reason']
                assert observe.kernel(pid) == owned[0] and observe.kernel(tool_identity['pid']) == tool_identity
                assert not (root / 'tool-done').exists()
                step('active-original-refused', report['active_refusal'] + '; native and tool undisturbed')
                (root / 'release').touch()
                wait_for(lambda: (root / 'tool-done').exists(), 30, 'tool completion')
                # The missing Stop hook (`python3 <deleted>` exits 2) blocks the stop,
                # so the turn feeds itself: unbounded model requests, no gate.
                first = len(server.requests)
                time.sleep(10)
                looped = len(server.requests) - first
                t = thread_now()
                hook_prompts = sum(i['type'] == 'hookPrompt' for i in t['turns'][-1]['items'])
                assert t['status']['type'] == 'active' and looped > 20 and hook_prompts > 20, (t['status'], looped)
                report.update(loop_requests_10s=looped, loop_hook_prompts=hook_prompts)
                step('missing-stop-hook-loops', '%d model requests in 10s, %d hookPrompt items, never idle' % (looped, hook_prompts))
                stops = [a for a in server.actions if a[0] in ('stopped', 'reserve')]
                for _ in range(3):
                    try:
                        continuation.inspect(pane, socket, pid, sid)
                        raise AssertionError('looping original accepted')
                    except (ValueError, OSError, subprocess.SubprocessError) as error:
                        assert continuation.unavailable(error)['reason'] in ('native-not-idle', 'source-unverified')
                    time.sleep(1)
                assert observe.kernel(pid) == owned[0] and [a for a in server.actions if a[0] in ('stopped', 'reserve')] == stops
                assert tmux('display-message', '-p', '-t', pane, '#{pane_dead}') == '0'
                step('looping-original-never-stopped-or-fed', 'continuation refuses; no stop, reservation or input')
                if args.evidence:
                    destination = Path(args.evidence)
                    assert destination.is_absolute() and BIN.parent not in destination.resolve().parents
                    with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
                        json.dump(report, stream, indent=2, default=str)
                return 0
            thread = wait_for(idle, 5, 'original still idle')
            old_turns = [t['id'] for t in thread['turns']]
            report['mcp_after_removal'] = {x['name']: continuation.MCP.runtime_ready(x)
                                           for x in rpc_call('mcpServerStatus/list', {})['data']}
            for wrong in (str(uuid.uuid4()), None):
                try:
                    continuation.inspect(pane, socket, pid + 1 if wrong is None else pid, wrong or sid)
                    raise AssertionError('foreign identity accepted')
                except (ValueError, OSError, subprocess.SubprocessError):
                    pass
            assert observe.kernel(pid) == owned[0] and len(server.starts) == 1
            step('foreign-sid-and-pid-refused', 'no write, original undisturbed')
            cplan = continuation.inspect(pane, socket, pid, sid)
            step('continuation-inspect', 'remounted=' + ','.join(cplan['readiness']['mcp_remounted'])
                 + ' mcp_ready_after_removal=' + json.dumps(report['mcp_after_removal']))
            operation = str(uuid.uuid4())
            marker = 'continued-original-message-' + operation
            cplan['message'] = dict(operation=operation, text=marker)
            journal_root = conf / 'native-continuations'
            journal_root.mkdir(mode=0o700)
            journal = journal_root / 'drill.json'
            # Draft input in the original pane: the first stop must refuse with no effect.
            tmux('send-keys', '-t', pane, '-l', 'draft words')
            record = continuation.protected_execute(journal_root / 'draft.json', cplan, continuation.Native())
            assert record['state'] in ('source-retained', 'stop-unconfirmed') and 'reserve' not in record, record['state']
            report['draft_refusal'] = record['state']
            assert observe.kernel(pid) == owned[0] and len(server.starts) == 1
            step('stop-refused-no-second-writer', 'draft input -> ' + record['state'] + '; original alive, no reservation')
            tmux('send-keys', '-t', pane, 'C-u')
            time.sleep(1)
            actions_before, requests_before = len(server.actions), len(server.requests)
            real_settle = observe.runtime.codex_settle

            def lost_ack(*a, **k):
                # The add reached the native; its answer never reached us.
                raise EOFError('injected: connection lost after thread/queue/add')
            with mock.patch.object(continuation, 'wait_for', verbose_wait_for), \
                    mock.patch.object(observe.runtime, 'codex_settle', lost_ack):
                record = continuation.protected_execute(journal, cplan, Traced())
            assert record['state'] == 'delivery-unconfirmed' and record.get('delivery_attempt'), record['state']
            assert not record['message_consumption_verified']
            step('delivery-ack-lost', 'journal delivery-unconfirmed; the attempt was written before the native add')
            settles = 0
            while record['state'] != 'consumed' and settles < 10:
                # Re-apply as an operator would: it settles by the receipt, never resends.
                settles += 1
                time.sleep(2)
                with     mock.patch.object(continuation, 'wait_for', verbose_wait_for):
                    record = continuation.protected_execute(journal, cplan, Traced())
            report['reapply_count'] = settles
            assert observe.runtime.codex_settle is real_settle
            report['journal_state'] = record['state']
            if record['state'] != 'consumed':
                print('journal: ' + json.dumps({k: v for k, v in record.items() if k != 'plan'}, default=str)[:3000], file=sys.stderr)
            assert record['state'] == 'consumed', record['state']
            new = record['bound']['native_identity']
            owned.append(observe.kernel(new['pid']))
            try:
                observe.kernel(pid)
                raise AssertionError('original native still alive')
            except (ValueError, OSError, subprocess.SubprocessError):
                pass
            assert new['native_session'] == sid and new['pid'] != pid
            step('continued-same-sid-new-lifetime', 'pid %d -> %d' % (pid, new['pid']))
            new_remote = observe.process_scope(new['pid'])['FLEET_CODEX_REMOTE']
            assert observe.hook_boundary(observe.process_argv(new['pid']))['state'] != 'missing'
            mcp_new = {x['name']: continuation.MCP.runtime_ready(x)
                       for x in rpc_call('mcpServerStatus/list', {}, new['pid'], new_remote)['data']}
            assert all(mcp_new.get(n) for n in cplan['readiness']['mcp_remounted']), mcp_new
            report['mcp_new_lifetime'] = mcp_new
            step('new-lifetime-current-hooks-and-mcp', json.dumps(mcp_new))
            thread = rpc_call('thread/read', dict(threadId=sid, includeTurns=True), new['pid'], new_remote)['thread']
            hits = [(t['id'], i) for t in thread['turns'] for i in t['items']
                    if i['type'] == 'userMessage' and marker in json.dumps(i)]
            assert len(hits) == 1 and hits[0][0] == record['consumed']['turn_id'] and hits[0][0] not in old_turns
            assert hits[0][1].get('clientId') == operation, hits[0][1]
            assert sum(marker in json.dumps(r) for r in server.requests) >= 1
            receipt = record['deliver']
            # Nothing ran on the original between readiness and its exit, and the
            # resumed lifetime's own Stop hook ends its turn: every model request
            # since carries the message, and the thread settles idle.
            later = server.requests[requests_before:]
            assert later and all(marker in json.dumps(r) for r in later), len(later)
            settled = wait_for(lambda: (lambda t: t['status']['type'] == 'idle' and t['turns'][-1]['status'] == 'completed' and t)(
                rpc_call('thread/read', dict(threadId=sid, includeTurns=True), new['pid'], new_remote)['thread']), 30,
                'continued turn settles under current hooks')
            assert settled['turns'][-1]['id'] == hits[0][0]
            assert not any(i['type'] == 'hookPrompt' for i in settled['turns'][-1]['items'])
            report['continued_requests'] = len(later)
            step('no-turn-on-original-and-current-stop-hook-settles', '%d model request(s), all with the message' % len(later))
            report['delivery_settled_by'] = receipt['reason']
            step('original-message-consumed-once', 'turn=%s receipt=%s reread=%s' % (
                hits[0][0], receipt['method'], record['consumed']['source']))
            requests, actions = len(server.requests), len(server.actions)
            again = continuation.protected_execute(journal, cplan, continuation.Native())
            assert again == record and len(server.requests) == requests and len(server.actions) == actions
            step('repeat-apply-no-effect')
            old_reservation = cplan['context']['reservation']
            late = observe.authority.start_call(cplan['context']['repo'], old_reservation, 'stopped',
                                                native_identity=cplan['proof'], execution_stopped=True)
            assert late.get('reservation') == old_reservation
            current = continuation.reconcile(continuation.read(journal), continuation.Native())
            assert current['state'] == 'consumed' and record['bound']['authority_receipt']['reservation'] != old_reservation
            assert continuation.Native().bound(cplan, record, seconds=0)['native_identity'] == new
            step('late-old-stop-proof-keeps-new-identity')
            assert (work / 'dirty.txt').read_bytes() == b'original uncommitted bytes\n'
            assert tree_hash() == before_tree
            step('dirty-files-and-tree-hash-kept')
            report.update(sid=sid, original=cplan['proof'], new_lifetime=new, operation=operation,
                          receipt=receipt, consumed=record['consumed'], tree=before_tree,
                          actions=server.actions[actions_before:], remounted=cplan['readiness']['mcp_remounted'])
            if args.evidence:
                destination = Path(args.evidence)
                assert destination.is_absolute() and BIN.parent not in destination.resolve().parents
                with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
                    json.dump(report, stream, indent=2, default=str)
    except Exception:
        try:
            print(tmux('capture-pane', '-p', '-t', pane or 'isolated', '-S', '-25'), file=sys.stderr)
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
        for process in owned:
            try:
                if observe.kernel(process['pid']) == process:
                    os.kill(process['pid'], signal.SIGTERM)
            except (ProcessLookupError, ValueError, subprocess.SubprocessError):
                pass
        time.sleep(1)
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print('kept: ' + str(root), file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
