#!/usr/bin/env python3
"""Explicit offline native background-terminal lifecycle probe; no live Fleet access."""
import argparse
import http.server
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time


def fixture_host_pid(argv, namespace_pid, proc_root=Path('/proc')):
    matches = []
    expected = [os.fsencode(argument) for argument in argv]
    for process in proc_root.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            if (process / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0') != expected:
                continue
            namespaces = [line.split()[1:] for line in (process / 'status').read_text().splitlines()
                          if line.startswith('NSpid:')]
            if len(namespaces) == 1 and namespaces[0] and int(namespaces[0][-1]) == namespace_pid:
                matches.append(int(process.name))
        except (OSError, ValueError):
            continue
    if len(matches) != 1:
        raise AssertionError('expected one owned fixture process with exact argv and namespace PID: ' + repr(matches))
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    executable = shutil.which(arguments.codex)
    if not executable:
        parser.error('native Codex binary is required')
    binary = str(Path(executable).resolve())
    client_type = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-codex-rpc.py'))['Client']
    stop = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-native-local-runtime-selftest.py'))['stop']
    checks, requests, observations, commands, tool_outputs = [], [], {}, {}, {}
    failures = []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    def wait_for(predicate, message, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                check(True, message)
                return
            time.sleep(.05)
        raise AssertionError(message)

    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def process_states(terminals):
        if sys.platform != 'linux':
            return {}
        result = {}
        for terminal in terminals:
            process = Path('/proc') / str(terminal['fixturePid'])
            try:
                result[process.name] = {
                    'status': [line for line in (process / 'status').read_text().splitlines()
                               if line.split(':', 1)[0] in ('Name', 'State', 'PPid', 'Uid', 'NSpid')],
                    'stat': (process / 'stat').read_text(),
                    'argv': (process / 'cmdline').read_bytes().decode(errors='replace').split('\0')}
            except FileNotFoundError:
                result[process.name] = {'absent': True}
        return result

    def record_exit(predicate, message, terminals):
        try:
            wait_for(predicate, message)
        except AssertionError:
            failures.append(message)
            observations[message] = process_states(terminals)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
            identifier = payload.get('prompt_cache_key')
            requests.append({'thread': identifier, 'path': self.path,
                             'authorization': bool(self.headers.get('Authorization'))})
            command = commands.get(identifier)
            tool_outputs[identifier] = [item.get('output') for item in payload.get('input', [])
                                        if item.get('type') == 'function_call_output']
            if command is None:
                body = b'{"error":{"message":"offline fixture: unknown thread"}}'
                self.send_response(400)
                content_type = 'application/json'
            else:
                sequence = sum(request['thread'] == identifier for request in requests)
                if sequence == 1:
                    item = {'type': 'function_call', 'id': 'fc_fixture', 'call_id': 'call_fixture',
                            'name': 'exec_command', 'arguments': json.dumps({
                                'cmd': command, 'yield_time_ms': 250, 'max_output_tokens': 100})}
                else:
                    item = {'type': 'message', 'id': 'msg_fixture', 'role': 'assistant', 'status': 'completed',
                            'content': [{'type': 'output_text', 'text': 'fixture complete', 'annotations': []}]}
                response = {'id': 'resp_fixture_' + str(sequence), 'object': 'response', 'status': 'completed',
                            'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}
                events = [{'type': 'response.created', 'response': dict(response, status='in_progress', output=[])},
                          {'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                          {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                          {'type': 'response.completed', 'response': response}]
                body = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n'
                               for event in events).encode()
                self.send_response(200)
                content_type = 'text/event-stream'
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    endpoint = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    serving = threading.Thread(target=endpoint.serve_forever, daemon=True)
    serving.start()
    try:
        with tempfile.TemporaryDirectory(prefix='fleet-native-stop-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home = root / 'home'
            codex_home = home / '.codex'
            codex_home.mkdir(parents=True)
            environment = {'HOME': str(home), 'CODEX_HOME': str(codex_home), 'PATH': os.environ['PATH'],
                           'TMPDIR': str(root), 'XDG_CONFIG_HOME': str(home / '.config'),
                           'XDG_CACHE_HOME': str(home / '.cache'), 'GIT_CONFIG_NOSYSTEM': '1',
                           'GIT_CONFIG_GLOBAL': os.devnull}
            (codex_home / 'config.toml').write_text(
                'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
                '[features]\nremote_plugin=false\n'
                '[model_providers.offline]\nname="offline"\n'
                f'base_url="http://127.0.0.1:{endpoint.server_port}/v1"\n'
                'wire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n')
            version = subprocess.check_output([binary, '--version'], env=environment, text=True,
                                              stderr=subprocess.PIPE, timeout=10).strip()
            with (root / 'backend.log').open('w') as logfile:
                backend = subprocess.Popen([binary, 'app-server', '--listen', 'unix://'], cwd=root,
                    env=environment, stdin=subprocess.DEVNULL, stdout=logfile, stderr=logfile, start_new_session=True)
                rpc, observer = None, None
                identifiers, terminals = [], []
                try:
                    socket = codex_home / 'app-server-control/app-server-control.sock'
                    wait_for(lambda: socket.exists() and backend.poll() is None, 'owned native backend starts')
                    remote = 'unix://' + str(socket)
                    rpc = client_type(remote, timeout=10, peer_pid=backend.pid)
                    observer = client_type(remote, timeout=10, peer_pid=backend.pid)
                    check(rpc.call('thread/loaded/list', {})['data'] == [], 'empty backend has no user threads')

                    def background(identifier):
                        result = observer.call('thread/backgroundTerminals/list', {'threadId': identifier})
                        check(not result.get('nextCursor'), 'fixture terminal list is complete')
                        return result['data']

                    def completed(identifier, turn_id):
                        thread = observer.call('thread/read', {'threadId': identifier, 'includeTurns': True})['thread']
                        return any(turn['id'] == turn_id and turn['status'] == 'completed' for turn in thread['turns'])

                    for label in ('first', 'second', 'clean'):
                        thread = rpc.call('thread/start', {'cwd': str(root)})['thread']
                        identifier = thread['id']
                        identifiers.append(identifier)
                        rpc.call('thread/name/set', {'threadId': identifier, 'name': 'fixture-' + label})
                        command_argv = [sys.executable, '-c',
                            'import os,time; print("fixture-pid=" + str(os.getpid()), flush=True); time.sleep(90)',
                            str(root / ('command-' + label))]
                        commands[identifier] = shlex.join(command_argv)
                        turn = rpc.call('turn/start', {'threadId': identifier, 'input': [
                            {'type': 'text', 'text': 'Run the inert fixture command.', 'text_elements': []}]})['turn']
                        wait_for(lambda: completed(identifier, turn['id']), label + ': native turn completes')
                        listed = background(identifier)
                        observations[label] = {'thread': identifier, 'turn': turn['id'], 'terminals': listed}
                        outputs = tool_outputs[identifier]
                        pids = [int(value) for value in re.findall(r'fixture-pid=(\d+)', json.dumps(outputs))]
                        if len(pids) != 1:
                            raise AssertionError('missing fixture PID in native tool output: ' + repr(outputs))
                        check(True, label + ': native command output identifies its namespace PID')
                        host_pid = fixture_host_pid(command_argv, pids[0]) if sys.platform == 'linux' else pids[0]
                        check(len(listed) == 1 and alive(host_pid),
                              label + ': completed turn retains a live native background command')
                        terminals.append(dict(listed[0], fixturePid=host_pid))
                        observations[label].update(fixturePid=host_pid, namespacePid=pids[0])
                    check(len({terminal['fixturePid'] for terminal in terminals}) == 3
                          and len({terminal['processId'] for terminal in terminals}) == 3,
                          'threads have distinct native command processes and handles')
                    for identifier in identifiers:
                        unsubscribed = rpc.call('thread/unsubscribe', {'threadId': identifier})
                        check(unsubscribed['status'] == 'unsubscribed', 'native acknowledges removal of the owning subscription')
                    rpc.close()
                    rpc = None
                    check(all(alive(terminal['fixturePid']) for terminal in terminals),
                          'closing the launch RPC connection does not stop background commands')
                    try:
                        observer.call('turn/interrupt', {'threadId': identifiers[0], 'turnId': observations['first']['turn']})
                    except ValueError as error:
                        check(str(error) == 'no active turn to interrupt', 'native interrupt refuses a completed turn')
                    else:
                        raise AssertionError('completed turn unexpectedly accepted interrupt')
                    check(alive(terminals[0]['fixturePid']), 'interrupting an already completed turn does not stop its background command')
                    wrong = observer.call('thread/backgroundTerminals/terminate', {
                        'threadId': identifiers[1], 'processId': terminals[0]['processId']})
                    check(wrong['terminated'] is False and all(alive(terminal['fixturePid']) for terminal in terminals),
                          'native terminal termination rejects a process routed through the wrong thread')
                    result = observer.call('thread/backgroundTerminals/terminate', {
                        'threadId': identifiers[0], 'processId': terminals[0]['processId']})
                    observations['termination'] = {'response': result, 'remaining': observer.call(
                        'thread/backgroundTerminals/list', {'threadId': identifiers[0]})}
                    check(result['terminated'] is True, 'native exact-thread terminal termination succeeds')
                    record_exit(lambda: not alive(terminals[0]['fixturePid']), 'terminated first command exits', terminals)
                    check(alive(terminals[1]['fixturePid']) and backend.poll() is None,
                          'exact-thread termination leaves the sibling command and backend alive')
                    observations['clean_response'] = {'response': observer.call('thread/backgroundTerminals/clean',
                        {'threadId': identifiers[2]})}
                    record_exit(lambda: not alive(terminals[2]['fixturePid']),
                                'native clean stops the exact third-thread command', terminals)
                    check(background(identifiers[2]) == [] and alive(terminals[1]['fixturePid']),
                          'native clean leaves no target terminals and preserves the sibling command')
                    observations['archive'] = {'response': observer.call('thread/archive', {'threadId': identifiers[1]})}
                    record_exit(lambda: not alive(terminals[1]['fixturePid']),
                                'native archive stops the second thread background command', terminals)
                    check(backend.poll() is None, 'archiving one thread does not stop the shared backend')
                    check(identifiers[1] not in observer.call('thread/loaded/list', {})['data'],
                          'archived target is no longer loaded')
                    check(all(identifier in observer.call('thread/loaded/list', {})['data']
                              for identifier in (identifiers[0], identifiers[2])),
                          'archiving the target leaves both other threads loaded')
                    try:
                        observer.call('thread/resume', {'threadId': identifiers[1]})
                    except ValueError as error:
                        check('is archived' in str(error), 'native resume refuses an archived thread until explicit unarchive')
                    else:
                        raise AssertionError('archived thread unexpectedly resumed')
                    observer.call('thread/unarchive', {'threadId': identifiers[1]})
                    restored = observer.call('thread/resume', {'threadId': identifiers[1]})['thread']
                    check(restored['id'] == identifiers[1] and background(identifiers[1]) == [],
                          'native resume retains thread identity with an empty terminal registry')
                    check(all(not request['authorization'] and request['path'] == '/v1/responses' for request in requests),
                          'all model traffic stays on the credential-free loopback fixture')
                except BaseException:
                    print(json.dumps({'checks': checks, 'observations': observations, 'requests': requests,
                                      'process_states': process_states(terminals),
                                      'backend_log': (root / 'backend.log').read_text()[-6000:]}), file=sys.stderr)
                    raise
                finally:
                    if rpc is not None:
                        rpc.close()
                    if observer is not None:
                        observer.close()
                    stop(backend)
                    record_exit(lambda: not any(alive(terminal['fixturePid']) for terminal in terminals),
                                'all observed fixture commands exit during cleanup', terminals)
            print(json.dumps({'version': version, 'checks': checks, 'failures': failures, 'observations': observations,
                              'scope': 'native RPC and inert commands only; not subagent, TUI, admission or full-MCP acceptance'}, indent=2))
            return 1 if failures else 0
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
