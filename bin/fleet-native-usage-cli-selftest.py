#!/usr/bin/env python3
"""Explicit offline native usage subscription probe; not real-model or panel acceptance."""
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
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default='codex')
    parser.add_argument('--fleet-root', type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    executable = shutil.which(arguments.codex)
    if not executable:
        parser.error('native Codex binary required')
    binary = str(Path(executable).resolve())
    client_type = runpy.run_path(str(arguments.fleet_root / 'bin/fleet-codex-rpc.py'))['Client']
    requests, checks = [], []
    scenario = {'mode': 'text', 'issued': False, 'started': threading.Event(), 'release': threading.Event()}

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append({'authorization': bool(self.headers.get('Authorization')),
                             'thread_id': self.headers.get('thread-id')})
            if scenario['mode'] == 'held':
                scenario['started'].set()
                if not scenario['release'].wait(40):
                    self.send_error(500, 'offline fixture release timed out')
                    return
            item = {'type': 'message', 'id': 'msg_fixture', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'offline fixture complete', 'annotations': []}]}
            if scenario['mode'] == 'approval' and not scenario['issued']:
                offered = request.get('tools', []) + [tool for entry in request.get('input', [])
                          if entry.get('type') == 'additional_tools' for tool in entry.get('tools', [])]
                scenario['offered'] = any(tool.get('name') == 'functions'
                                          and any(child.get('name') == 'exec' and 'exec_command(' in child.get('description', '')
                                                  for child in tool.get('tools', [])) for tool in offered)
                scenario['issued'] = True
                command = {'cmd': 'printf denied-canary > ' + shlex.quote(str(scenario['marker'])),
                           'sandbox_permissions': 'require_escalated', 'justification': 'Offline fixture: always decline'}
                item = {'type': 'custom_tool_call', 'id': 'fc_fixture', 'call_id': 'call_fixture', 'name': 'exec',
                        'input': 'text(await tools.exec_command(' + json.dumps(command) + '));'}
            response = {'id': 'resp_fixture', 'object': 'response', 'status': 'completed', 'output': [item],
                        'usage': {'input_tokens': 1234, 'output_tokens': 66, 'total_tokens': 1300}}
            events = [{'type': 'response.created', 'response': dict(response, status='in_progress', output=[])},
                      {'type': 'response.output_item.added', 'output_index': 0, 'item': item},
                      {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                      {'type': 'response.completed', 'response': response}]
            body = ''.join('event: ' + event['type'] + '\ndata: ' + json.dumps(event) + '\n\n' for event in events).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    def collect(clients):
        captured = {name: [] for name in clients}
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            for name, client in clients.items():
                client.deadline = time.monotonic() + .2
                for _ in range(256):
                    event = client.events.pop(0) if client.events else client.receive(nonblocking=True)
                    if event is None:
                        break
                    if event.get('method', '').startswith(('thread/', 'turn/', 'serverRequest/')) or 'id' in event:
                        captured[name].append(event)
                else:
                    raise AssertionError('native event backlog exceeded fixture budget')
            time.sleep(.02)
        return captured

    def usage(events, identifier, total, label):
        selected = [event['params'] for event in events if event.get('method') == 'thread/tokenUsage/updated']
        check(bool(selected), label + ': native usage received')
        check(all(event['threadId'] == identifier for event in selected), label + ': exact root thread')
        value = selected[-1]['tokenUsage']
        check(value['last']['totalTokens'] == 1300 and value['last']['inputTokens'] == 1234
              and value['last']['outputTokens'] == 66, label + ': last response is live context, not cumulative usage')
        check(value['total']['totalTokens'] == total, label + ': cumulative usage remains separate')
        check(isinstance(value['modelContextWindow'], int) and value['modelContextWindow'] > 0,
              label + ': context denominator comes from native event')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        with tempfile.TemporaryDirectory(prefix='fleet-usage-', dir='/tmp') as temporary:
            root = Path(temporary).resolve()
            home = root / 'home'
            home.mkdir()
            environment = {'PATH': os.environ['PATH'], 'HOME': str(home), 'CODEX_HOME': str(home),
                           'XDG_CONFIG_HOME': str(home / '.config'), 'XDG_CACHE_HOME': str(home / '.cache')}
            (home / 'config.toml').write_text(
                'model="gpt-6.1-sol"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
                '[features]\ndaemon_auto_start=false\nremote_plugin=false\n'
                '[model_providers.offline]\nname="offline"\n'
                f'base_url="http://127.0.0.1:{server.server_port}/v1"\n'
                'wire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n')
            version = subprocess.check_output([binary, '--version'], env=environment, text=True, timeout=10).strip()
            endpoint = root / 'socket'
            with (root / 'server.log').open('w') as log:
                backend = subprocess.Popen([binary, 'app-server', '--listen', 'unix://' + str(endpoint)],
                                           env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=log, start_new_session=True)
                clients = {}
                try:
                    deadline = time.monotonic() + 10
                    while not endpoint.exists() and backend.poll() is None and time.monotonic() < deadline:
                        time.sleep(.05)
                    check(endpoint.exists() and backend.poll() is None, 'owned native backend ready')
                    for name in ('passive', 'read_only', 'controller'):
                        clients[name] = client_type('unix://' + str(endpoint), timeout=5)
                    controller = clients['controller']
                    initial = controller.call('thread/start', {'cwd': str(root), 'model': 'gpt-6.1-sol',
                                                               'approvalPolicy': 'never', 'sandbox': 'read-only'})
                    identifier = initial['thread']['id']
                    clients['read_only'].call('thread/read', {'threadId': identifier, 'includeTurns': False})
                    phases = []
                    for index, label in enumerate(('unsubscribed', 'resumed', 'unsubscribed-again'), 1):
                        if label == 'resumed':
                            resumed = clients['read_only'].call('thread/resume', {'threadId': identifier, 'excludeTurns': True})
                            check(resumed['thread']['id'] == identifier, 'resume retains exact thread')
                            for key in ('model', 'approvalPolicy', 'sandbox'):
                                check(resumed[key] == initial[key], 'resume preserves native ' + key)
                        elif label == 'unsubscribed-again':
                            clients['read_only'].call('thread/unsubscribe', {'threadId': identifier})
                        collect(clients)
                        check(len(requests) == index - 1, label + ': observation starts no inference')
                        controller.call('turn/start', {'threadId': identifier, 'input': [
                            {'type': 'text', 'text': 'Offline fixture. Do not run tools.'}]})
                        events = collect(clients)
                        usage(events['controller'], identifier, index * 1300, label + ' controller')
                        for name in ('passive', 'read_only'):
                            found = [event for event in events[name] if event.get('method') == 'thread/tokenUsage/updated']
                            if name == 'read_only' and label == 'resumed':
                                usage(events[name], identifier, index * 1300, label + ' observer')
                            else:
                                check(not found, label + ' ' + name + ': no unproven usage broadcast')
                        check(any(event.get('method') == 'thread/status/changed'
                                  and event['params']['threadId'] == identifier for event in events['passive']),
                              label + ': status broadcast is independent of usage subscription')
                        snapshot = controller.call('thread/read', {'threadId': identifier, 'includeTurns': True})['thread']
                        check(len(snapshot['turns']) == index and all(turn['status'] == 'completed' for turn in snapshot['turns']),
                              label + ': only explicitly started turns completed')
                        check(snapshot['id'] == identifier and snapshot['cwd'] == str(root), label + ': binding unchanged')
                        phases.append({'phase': label, 'usage_receivers': [name for name, received in events.items()
                                       if any(event.get('method') == 'thread/tokenUsage/updated' for event in received)]})
                    check(len(requests) == 3 and all(request['thread_id'] == identifier for request in requests),
                          'exactly three explicit root requests, no extra inference')

                    scenario['mode'] = 'held'
                    active = controller.call('turn/start', {'threadId': identifier, 'input': [
                        {'type': 'text', 'text': 'Hold the offline response until the fixture releases it.'}]})['turn']['id']
                    check(scenario['started'].wait(5), 'active turn reached the held local endpoint')
                    resumed = clients['read_only'].call('thread/resume', {'threadId': identifier, 'excludeTurns': True})
                    check(resumed['thread']['id'] == identifier and resumed['thread']['status']['type'] == 'active',
                          'observer can subscribe during the exact active turn')
                    clients.pop('read_only').close()
                    clients['read_only'] = client_type('unix://' + str(endpoint), timeout=5)
                    resumed = clients['read_only'].call('thread/resume', {'threadId': identifier, 'excludeTurns': True})
                    check(resumed['thread']['id'] == identifier and resumed['thread']['status']['type'] == 'active',
                          'observer reconnect does not cancel or replace active turn')
                    check(len(requests) == 4, 'active observation does not start another inference')
                    scenario['release'].set()
                    events = collect(clients)
                    for name in ('controller', 'read_only'):
                        usage(events[name], identifier, 5200, 'active reconnect ' + name)
                        check(any(event.get('method') == 'turn/completed' and event['params']['turn']['id'] == active
                                  and event['params']['turn']['status'] == 'completed' for event in events[name]),
                              name + ': original active turn completes after observer reconnect')
                    phases.append({'phase': 'active-reconnect', 'usage_receivers': ['controller', 'read_only']})

                    scenario.update(mode='approval', issued=False, marker=root / 'must-not-execute')
                    pending_turn = controller.call('turn/start', {'threadId': identifier, 'approvalPolicy': 'on-request',
                        'input': [{'type': 'text', 'text': 'The fixture tool request must be declined by its controller.'}]})['turn']['id']
                    pending = collect(clients)

                    def approval(events, label):
                        matches = [event for event in events if event.get('method') == 'item/commandExecution/requestApproval']
                        check(len(matches) == 1, label + ': exactly one native approval request')
                        event = matches[0]
                        check(event['params']['threadId'] == identifier and event['params']['turnId'] == pending_turn,
                              label + ': approval belongs to the original root and turn')
                        return event

                    original = approval(pending['controller'], 'controller')
                    approval(pending['read_only'], 'subscribed observer')
                    check(scenario.get('offered'), 'native code mode offers the actual command tool')
                    clients.pop('read_only').close()
                    snapshot = controller.call('thread/read', {'threadId': identifier, 'includeTurns': True})['thread']
                    check('waitingOnApproval' in snapshot['status'].get('activeFlags', []),
                          'observer disconnect does not resolve or cancel approval')
                    clients['read_only'] = client_type('unix://' + str(endpoint), timeout=5)
                    resumed = clients['read_only'].call('thread/resume', {'threadId': identifier, 'excludeTurns': True})
                    check(resumed['approvalPolicy'] == 'on-request' and resumed['sandbox'] == initial['sandbox'],
                          'observer reconnect preserves changed turn policy and sandbox')
                    replayed = approval(collect(clients)['read_only'], 'reconnected observer')
                    check(replayed['params'] == original['params'], 'replayed approval payload is unchanged')
                    check(len(requests) == 5 and not scenario['marker'].exists(),
                          'observer never approves, executes or advances pending tool')
                    controller.send({'id': original['id'], 'result': {'decision': 'decline'}})
                    completed = collect(clients)
                    for name, request in (('controller', original), ('read_only', replayed)):
                        check(any(event.get('method') == 'serverRequest/resolved'
                                  and event['params']['requestId'] == request['id']
                                  and event['params']['threadId'] == identifier for event in completed[name]),
                              name + ': native resolution confirms controller denial')
                        usage(completed[name], identifier, 7800, 'approval denial ' + name)
                    check(not scenario['marker'].exists(), 'declined native command never executes')
                    check(len(requests) == 6 and all(request['thread_id'] == identifier for request in requests),
                          'five explicit turns use six expected responses, no observer inference')
                    snapshot = controller.call('thread/read', {'threadId': identifier, 'includeTurns': True})['thread']
                    check(len(snapshot['turns']) == 5 and snapshot['turns'][-1]['id'] == pending_turn
                          and all(turn['status'] == 'completed' for turn in snapshot['turns']),
                          'original controller completes all turns without cancellation or replacement')
                    phases.append({'phase': 'approval-reconnect-deny', 'usage_receivers': ['controller', 'read_only']})
                    check(not any(request['authorization'] for request in requests), 'no credentials sent')
                    check(len(controller.call('thread/list', {'limit': 100})['data']) == 1, 'no second native thread created')
                    report = {'version': version, 'scope': 'offline subscription semantics, not production telemetry or panel acceptance',
                              'checks': checks, 'phases': phases}
                finally:
                    scenario['release'].set()
                    for client in clients.values():
                        client.close()
                    if backend.poll() is None:
                        os.killpg(backend.pid, signal.SIGTERM)
                    try:
                        backend.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(backend.pid, signal.SIGKILL)
                        backend.wait(timeout=5)
            print(json.dumps(report, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        serving.join(timeout=5)


if __name__ == '__main__':
    main()
