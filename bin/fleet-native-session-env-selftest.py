#!/usr/bin/env python3
"""Explicit offline concurrent-TUI/MCP environment probe; no live Fleet access."""
import argparse
import ast
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import runpy
import select
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


NAMES = ('TMUX', 'TMUX_PANE', 'FLEET_CONF_DIR', 'FLEET_SESSION', 'FLEET_WORKER_CRED',
         'FLEET_MCP_BIN', 'FLEET_MCP_ORCH')
MCP = '''import json, os, sys
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'session-fixture', 'version': '1'}}
    elif method == 'tools/list':
        result = {'tools': [{'name': 'inspect', 'description': 'Read only fixture identity',
                            'inputSchema': {'type': 'object', 'properties': {}}}]}
    elif method == 'tools/call':
        observed = {'pid': os.getpid(), 'cwd': os.getcwd(),
                    'environment': {name: os.environ.get(name) for name in sys.argv[1:]},
                    'metadata': request.get('params', {}).get('_meta')}
        result = {'content': [{'type': 'text', 'text': json.dumps(observed)}]}
    elif method == 'resources/list':
        result = {'resources': []}
    elif method == 'resources/templates/list':
        result = {'resourceTemplates': []}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
'''
HOOK = '''import json, os, pathlib, runpy, sys
payload = json.load(sys.stdin)
path = pathlib.Path(sys.argv[2]) / (payload['session_id'] + '.json')
path.with_suffix('.started').write_text(json.dumps(payload))
launch = runpy.run_path(sys.argv[1])
observed = {'payload': payload,
            'environment': {name: os.environ.get(name) for name in sys.argv[4:]}}
try:
    observed['native'] = launch['native_parent']()
    if sys.argv[3]:
        client_type = runpy.run_path(sys.argv[3])['Client']
        socket = pathlib.Path(os.environ['CODEX_HOME']) / 'app-server-control/app-server-control.sock'
        client = client_type('unix://' + str(socket), timeout=3, peer_pid=observed['native']['pid'])
        try:
            observed['thread'] = client.call('thread/read', {'threadId': payload['session_id'], 'includeTurns': False})['thread']
        finally:
            client.close()
except Exception as error:
    observed['error'] = str(error)
path.write_text(json.dumps(observed))
'''


def process_exists(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def launch(binary, base, codex_home, environment, prior_ids, stop, ready, supervised=False, fork_from='', resume_from=''):
    descriptor, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 32, 120, 0, 0))
    child = None
    try:
        try:
            operation = ['resume', resume_from] if resume_from else ['fork', fork_from] if fork_from else []
            command = [binary, *operation, '--cd', str(base), *([] if resume_from else ['--worktree']),
                       'Offline session environment fixture. Do not run tools.']
            if supervised:
                command = [sys.executable, '-c',
                           'import subprocess,sys; raise SystemExit(subprocess.call(sys.argv[1:]))', *command]
            child = subprocess.Popen(command,
                                     cwd=base, env=environment, stdin=slave, stdout=slave, stderr=slave,
                                     start_new_session=True)
        finally:
            os.close(slave)
        terminal = bytearray()
        deadline = time.monotonic() + 30
        while child.poll() is None and time.monotonic() < deadline:
            if select.select([descriptor], [], [], .1)[0]:
                try:
                    terminal.extend(os.read(descriptor, 65536))
                except OSError:
                    break
                for query, answer in ((b'\x1b[6n', b'\x1b[1;1R'), (b'\x1b[c', b'\x1b[?1;2c'),
                                      (b'\x1b[>c', b'\x1b[>0;1;0c')):
                    if query in terminal:
                        os.write(descriptor, answer)
                        terminal = terminal.replace(query, b'')
                terminal = terminal[-32768:]
            found = []
            for rollout in codex_home.glob('sessions/**/*.jsonl'):
                with rollout.open() as stream:
                    try:
                        first = json.loads(stream.readline())
                    except json.JSONDecodeError:
                        continue
                if first.get('type') == 'session_meta' and (
                        first['payload']['id'] == resume_from if resume_from else first['payload']['id'] not in prior_ids):
                    found.append(first['payload'])
            if len(found) == 1 and ready(found[0]['id']):
                return child, descriptor, found[0]
        raise AssertionError('native TUI did not create one distinct session')
    except BaseException:
        stop(child)
        os.close(descriptor)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--hooks', action='store_true', help='also inspect reviewed SessionStart hook environment and native ancestry')
    parser.add_argument('--fork-seed', action='store_true', help='with --hooks, inspect native forks of explicitly named empty threads')
    arguments = parser.parse_args()
    if arguments.fork_seed and not arguments.hooks:
        parser.error('--fork-seed requires --hooks')
    executable = shutil.which(arguments.codex)
    if not executable:
        parser.error('native Codex binary is required')
    binary = str(Path(executable).resolve())
    client_type = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-codex-rpc.py'))['Client']
    stop = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-native-local-runtime-selftest.py'))['stop']
    checks, requests, observations = [], [], []
    hook_observations = []
    seed_observations = []
    lifecycle_names = (*NAMES, 'FLEET_CODEX_LAUNCHER_PID', 'FLEET_LAUNCH_CONTEXT', 'FLEET_AUTHORITY_CONTEXT')
    launch_api = runpy.run_path(str(arguments.fleet_root / 'bin/fleet_launch.py')) if arguments.hooks else None

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    source = ast.parse((arguments.fleet_root / 'bin/fleet-mcp.py').read_text())
    declared = [ast.literal_eval(node.value) for node in source.body if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == 'CODEX_ENV' for target in node.targets)]
    check(declared == [list(NAMES)], 'fixture tracks the current Fleet MCP environment contract')

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            requests.append({'path': self.path, 'authorization': bool(self.headers.get('Authorization')),
                             'cache_key': body.get('prompt_cache_key')})
            body = b'{"error":{"message":"offline fixture: inference disabled"}}'
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
        with tempfile.TemporaryDirectory(prefix='fleet-native-env-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home, base = root / 'home', root / 'repo'
            codex_home = home / '.codex'
            codex_home.mkdir(parents=True)
            environment = {'HOME': str(home), 'CODEX_HOME': str(codex_home), 'PATH': os.environ['PATH'],
                           'TMPDIR': str(root), 'TERM': 'xterm-256color',
                           'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache'),
                           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                           'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                           'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}

            def git(*values):
                return subprocess.check_output(['git', *map(str, values)], env=environment,
                                               text=True, stderr=subprocess.PIPE, timeout=15).strip()

            git('init', '--quiet', base)
            (base / 'tracked').write_text('unchanged\n')
            git('-C', base, 'add', 'tracked')
            git('-C', base, 'commit', '--quiet', '-m', 'fixture')
            script = root / 'mcp.py'
            script.write_text(MCP)
            names = [*NAMES, 'CODEX_THREAD_ID', 'CODEX_SESSION_ID']
            (codex_home / 'config.toml').write_text(
                'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
                '[features]\ndaemon_auto_start=true\nhooks=' + str(arguments.hooks).lower() + '\nremote_plugin=false\n'
                '[model_providers.offline]\nname="offline"\n'
                f'base_url="http://127.0.0.1:{endpoint.server_port}/v1"\n'
                'wire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n'
                '[projects.' + json.dumps(str(base)) + ']\ntrust_level="trusted"\n'
                '[mcp_servers.fixture]\ncommand=' + json.dumps(sys.executable) + '\n'
                'args=' + json.dumps([str(script), *names]) + '\nenv_vars=' + json.dumps(names) + '\n'
                'required=true\nstartup_timeout_sec=10\ntool_timeout_sec=5\n')
            hook_results = root / 'hook-results'
            if arguments.hooks:
                hook_results.mkdir()
                hook_script = root / 'hook.py'
                hook_script.write_text(HOOK)
                command = shlex.join([sys.executable, str(hook_script),
                    str(arguments.fleet_root / 'bin/fleet_launch.py'), str(hook_results),
                    str(arguments.fleet_root / 'bin/fleet-codex-rpc.py') if arguments.fork_seed else '', *lifecycle_names])
                with (codex_home / 'config.toml').open('a') as configuration:
                    configuration.write('[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\n'
                                        'type="command"\ncommand=' + json.dumps(command) + '\n')
            backend_values = {name: 'fixture-backend-' + name.lower() for name in lifecycle_names}
            version = subprocess.check_output([binary, '--version'], env=environment, text=True,
                                              stderr=subprocess.PIPE, timeout=10).strip()
            with (root / 'backend.log').open('w') as logfile:
                backend = subprocess.Popen([binary, 'app-server', '--listen', 'unix://'], cwd=base,
                    env=dict(environment, **backend_values), stdin=subprocess.DEVNULL, stdout=logfile,
                    stderr=logfile, start_new_session=True)
                children, descriptors, identifiers, seeds = [], [], [], []
                rpc = None
                try:
                    socket = codex_home / 'app-server-control/app-server-control.sock'
                    deadline = time.monotonic() + 15
                    while not socket.exists() and backend.poll() is None and time.monotonic() < deadline:
                        time.sleep(.05)
                    check(socket.exists() and backend.poll() is None, 'owned native backend starts')
                    rpc = client_type('unix://' + str(socket), timeout=15, peer_pid=backend.pid)
                    check(rpc.call('thread/loaded/list', {})['data'] == [], 'backend starts without loaded threads')
                    if arguments.hooks:
                        entries = rpc.call('hooks/list', {'cwds': [str(base)]})['data']
                        hooks = [hook for entry in entries for hook in entry['hooks']]
                        check(len(hooks) == 1 and hooks[0]['trustStatus'] == 'untrusted',
                              'only the inert fixture hook is present and initially untrusted')
                        hook = hooks[0]
                        rpc.call('config/value/write', {'keyPath': 'hooks.state', 'mergeStrategy': 'upsert',
                            'value': {hook['key']: {'trusted_hash': hook['currentHash']}}})
                        entries = rpc.call('hooks/list', {'cwds': [str(base)]})['data']
                        hooks = [hook for entry in entries for hook in entry['hooks']]
                        check(len(hooks) == 1 and hooks[0]['trustStatus'] == 'trusted',
                              'exact reviewed fixture hash has native trust without bypass')
                        rpc.close()
                        rpc = None
                        stop(backend)
                        check(backend.poll() is not None, 'idle fixture backend stops before loading reviewed hook trust')
                        backend = subprocess.Popen([binary, 'app-server', '--listen', 'unix://'], cwd=base,
                            env=dict(environment, **backend_values), stdin=subprocess.DEVNULL, stdout=logfile,
                            stderr=logfile, start_new_session=True)
                        deadline = time.monotonic() + 15
                        while backend.poll() is None and time.monotonic() < deadline:
                            try:
                                rpc = client_type('unix://' + str(socket), timeout=2, peer_pid=backend.pid)
                                break
                            except (OSError, ValueError, EOFError):
                                time.sleep(.05)
                        check(rpc is not None and rpc.call('thread/loaded/list', {})['data'] == [],
                              'reviewed fixture restarts on the exact idle native backend')
                    for label in ('first', 'second'):
                        seed_id = ''
                        if arguments.fork_seed:
                            seed = rpc.call('thread/start', {'cwd': str(base)})['thread']
                            seed_id = seed['id']
                            seeds.append(seed_id)
                            rpc.call('thread/name/set', {'threadId': seed_id, 'name': 'fixture-' + label})
                            check(Path(seed['path']).is_file(), label + ': native naming persists the empty fork source')
                            seed_inspection = rpc.call('mcpServer/tool/call', {'threadId': seed_id,
                                'server': 'fixture', 'tool': 'inspect', 'arguments': {}})
                            check(not seed_inspection.get('isError'), label + ': empty source also starts configured MCP')
                            seed_observations.append({'label': label, 'thread': seed_id,
                                **json.loads(seed_inspection['content'][0]['text'])})
                        values = {name: 'fixture-' + label + '-' + name.lower() for name in lifecycle_names}
                        child, descriptor, metadata = launch(binary, base, codex_home,
                            dict(environment, **values), [*identifiers, *seeds], stop,
                            lambda identifier: any(request['cache_key'] == identifier for request in requests),
                            supervised=arguments.hooks, fork_from=seed_id)
                        children.append(child)
                        descriptors.append(descriptor)
                        identifiers.append(metadata['id'])
                        check(sum(request['cache_key'] == metadata['id'] for request in requests) == 1,
                              label + ': one loopback request for the exact native root')
                        loaded = rpc.call('thread/loaded/list', {})['data']
                        check(all(identifier in loaded for identifier in identifiers), label + ': all opened TUI threads belong to backend')
                        check(all(process.poll() is None for process in children), label + ': both TUI lifetimes overlap')
                        native = rpc.call('thread/read', {'threadId': metadata['id'], 'includeTurns': False})['thread']
                        if arguments.fork_seed:
                            check(native['forkedFromId'] == seed_id and native['id'] != seed_id,
                                  label + ': native fork retains its exact preallocated source')
                        check(Path(native['cwd']).resolve().is_relative_to(codex_home / 'worktrees'),
                              label + ': native worktree remains outside base')
                        result = rpc.call('mcpServer/tool/call', {'threadId': metadata['id'],
                            'server': 'fixture', 'tool': 'inspect', 'arguments': {}})
                        check(not result.get('isError'), label + ': native MCP inspection succeeds')
                        observed = json.loads(result['content'][0]['text'])
                        check(all(observed['environment'][name] == backend_values[name] for name in NAMES),
                              label + ': MCP inherits backend values rather than TUI session values')
                        check(observed['metadata']['threadId'] == metadata['id'],
                              label + ': native MCP metadata identifies its requested thread')
                        check(observed['environment']['CODEX_THREAD_ID'] is None
                              and observed['environment']['CODEX_SESSION_ID'] is None,
                              label + ': native thread identity is not injected into inspected MCP environment')
                        check(Path(observed['cwd']).resolve() == Path(native['cwd']).resolve(),
                              label + ': MCP working directory matches native worktree')
                        observations.append({'label': label, 'thread': metadata['id'], **observed})
                        if arguments.hooks:
                            result_path = hook_results / (metadata['id'] + '.json')
                            if not result_path.is_file():
                                raise AssertionError(label + ': missing hook result: ' + json.dumps({
                                    'files': {path.name: path.read_text() for path in hook_results.iterdir()},
                                    'requests': requests, 'thread': native,
                                    'hooks': rpc.call('hooks/list', {'cwds': [native['cwd']]})}))
                            hook_result = json.loads(result_path.read_text())
                            check('native' in hook_result and not hook_result.get('error'), label + ': reviewed SessionStart executes: '
                                  + str(hook_result.get('error', 'ok')))
                            payload, native = hook_result['payload'], hook_result['native']
                            check(payload['hook_event_name'] == 'SessionStart'
                                  and payload['source'] == ('fork' if arguments.fork_seed else 'startup')
                                  and payload['session_id'] == metadata['id'],
                                  label + ': native SessionStart carries the exact root')
                            check(Path(payload['cwd']).resolve() == Path(observed['cwd']).resolve(),
                                  label + ': hook cwd matches its native worktree')
                            check(hook_result['environment'] == backend_values,
                                  label + ': lifecycle environment comes from backend rather than TUI')
                            check(native['pid'] == backend.pid and native['actual_provider'] == 'codex'
                                  and Path(native['executable']).resolve() == Path(binary),
                                  label + ': existing native-parent verifier identifies the backend')
                            check(launch_api['same_process'](native), label + ': hook native process identity still holds')
                            check(not launch_api['root_native'](native, child.pid),
                                  label + ': shared backend fails the existing per-launch supervisor ancestry check')
                            hook_observations.append({'label': label, 'thread': metadata['id'],
                                                      'supervisor': child.pid, **hook_result})
                            if arguments.fork_seed:
                                check(hook_result['thread']['id'] == metadata['id']
                                      and hook_result['thread']['forkedFromId'] == seed_id,
                                      label + ': synchronous hook can read its exact native fork source')
                                check(observed['pid'] != seed_observations[-1]['pid'],
                                      label + ': empty source and user fork have separate MCP processes')
                    check(len(set(identifiers)) == 2, 'distinct native roots share the backend')
                    check(observations[0]['pid'] != observations[1]['pid'], 'each thread has a distinct MCP process')
                    if arguments.fork_seed:
                        check(len(set(seeds)) == 2, 'each fixture launch has a distinct named source')
                        check(all(hook['thread']['forkedFromId'] == seed for hook, seed in zip(hook_observations, seeds)),
                              'concurrent fork relationships do not cross source identities')
                        check(not any(request['cache_key'] in seeds for request in requests),
                              'source creation and naming do not start model requests')
                        duplicate = rpc.call('thread/fork', {'threadId': seeds[0], 'cwd': str(base)})['thread']
                        check(duplicate['forkedFromId'] == seeds[0] and duplicate['id'] not in identifiers,
                              'native permits another fork of the same source; source identity is not one-use authorization')
                        duplicate_inspection = rpc.call('mcpServer/tool/call', {'threadId': duplicate['id'],
                            'server': 'fixture', 'tool': 'inspect', 'arguments': {}})
                        check(not duplicate_inspection.get('isError'), 'duplicate fixture fork also owns a native MCP process')
                        seed_observations.append({'label': 'duplicate', 'thread': duplicate['id'],
                            **json.loads(duplicate_inspection['content'][0]['text'])})
                        for source_id in [*seeds, duplicate['id']]:
                            rpc.call('thread/archive', {'threadId': source_id})
                        deadline = time.monotonic() + 5
                        while any(process_exists(item['pid']) for item in seed_observations) and time.monotonic() < deadline:
                            time.sleep(.05)
                        check(not any(process_exists(item['pid']) for item in seed_observations),
                              'native archive retires all source and duplicate MCP processes')
                        loaded = rpc.call('thread/loaded/list', {})['data']
                        check(not any(source_id in loaded for source_id in [*seeds, duplicate['id']])
                              and all(identifier in loaded for identifier in identifiers),
                              'source retirement leaves both intended user forks loaded')
                        for source_id in [*seeds, duplicate['id']]:
                            rpc.call('thread/delete', {'threadId': source_id})
                        check(all(rpc.call('thread/read', {'threadId': identifier, 'includeTurns': False})['thread']['forkedFromId'] == seed
                                  for identifier, seed in zip(identifiers, seeds)),
                              'native deletion of owned empty sources preserves both fork identities')
                    forged = rpc.call('mcpServer/tool/call', {'threadId': identifiers[0],
                        'server': 'fixture', 'tool': 'inspect', 'arguments': {},
                        '_meta': {'threadId': identifiers[1], 'fixtureMarker': 'caller-supplied'}})
                    forged_result = json.loads(forged['content'][0]['text'])
                    check(not forged.get('isError') and forged_result['metadata']['threadId'] == identifiers[0],
                          'native thread routing overrides a forged metadata threadId')
                    check(forged_result['metadata']['fixtureMarker'] == 'caller-supplied',
                          'other caller metadata is not an authorization credential')
                    check(forged_result['pid'] == observations[0]['pid'],
                          'a repeated first-thread call does not reuse the second thread process')
                    observations.append({'label': 'forged-metadata', 'thread': identifiers[0], **forged_result})
                    stop(children[0])
                    remaining = rpc.call('mcpServer/tool/call', {'threadId': identifiers[1],
                        'server': 'fixture', 'tool': 'inspect', 'arguments': {}})
                    remaining_result = json.loads(remaining['content'][0]['text'])
                    check(children[1].poll() is None and not remaining.get('isError')
                          and remaining_result['pid'] == observations[1]['pid']
                          and remaining_result['metadata']['threadId'] == identifiers[1],
                          'stopping the first TUI does not change second-thread tool ownership')
                    if arguments.fork_seed:
                        worktrees = git('-C', base, 'worktree', 'list', '--porcelain')
                        prior_requests = sum(request['cache_key'] == identifiers[0] for request in requests)
                        child, descriptor, metadata = launch(binary, base, codex_home, environment, [], stop,
                            lambda identifier: sum(request['cache_key'] == identifier for request in requests) > prior_requests,
                            supervised=True, resume_from=identifiers[0])
                        children.append(child)
                        descriptors.append(descriptor)
                        check(metadata['id'] == identifiers[0], 'native TUI resume keeps the exact fork after source deletion')
                        resumed = rpc.call('mcpServer/tool/call', {'threadId': identifiers[0],
                            'server': 'fixture', 'tool': 'inspect', 'arguments': {}})
                        resumed_observation = json.loads(resumed['content'][0]['text'])
                        check(not resumed.get('isError') and resumed_observation['metadata']['threadId'] == identifiers[0]
                              and resumed_observation['cwd'] == observations[0]['cwd'],
                              'resumed fork tools retain the exact root and worktree')
                        check(git('-C', base, 'worktree', 'list', '--porcelain') == worktrees,
                              'native TUI resume creates no extra worktree')
                        check(children[1].poll() is None, 'resuming the first fork leaves the second TUI alive')
                        observations.append({'label': 'resumed', 'thread': identifiers[0], **resumed_observation})
                    check(all(not request['authorization'] and request['path'] == '/v1/responses' for request in requests),
                          'all inference is rejected locally without credentials')
                    check((base / 'tracked').read_text() == 'unchanged\n' and not git('-C', base, 'status', '--porcelain'),
                          'base checkout remains unchanged')
                finally:
                    for child in children:
                        stop(child)
                    for descriptor in descriptors:
                        os.close(descriptor)
                    if rpc is not None:
                        rpc.close()
                    stop(backend)
            deadline = time.monotonic() + 5
            while any(process_exists(observed['pid']) for observed in [*observations, *seed_observations]) and time.monotonic() < deadline:
                time.sleep(.05)
            check(not any(process_exists(observed['pid']) for observed in [*observations, *seed_observations]), 'owned MCP processes exit with backend cleanup')
            print(json.dumps({'version': version, 'checks': checks, 'observations': observations,
                              'hooks': hook_observations,
                              'seeds': seed_observations,
                              'scope': 'fixture values only; not live credential or tool authorization acceptance'}, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
