#!/usr/bin/env python3
"""Explicit offline native usage subscription probe; not real-model or panel acceptance."""
import argparse
import http.server
import json
import os
from pathlib import Path
import runpy
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

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append({'authorization': bool(self.headers.get('Authorization')),
                             'thread_id': self.headers.get('thread-id')})
            item = {'type': 'message', 'id': 'msg_fixture', 'role': 'assistant', 'status': 'completed',
                    'content': [{'type': 'output_text', 'text': 'offline fixture complete', 'annotations': []}]}
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
                    if event.get('method', '').startswith(('thread/', 'turn/')):
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
                    check(not any(request['authorization'] for request in requests), 'no credentials sent')
                    check(len(controller.call('thread/list', {'limit': 100})['data']) == 1, 'no second native thread created')
                    report = {'version': version, 'scope': 'offline subscription semantics, not production telemetry or panel acceptance',
                              'checks': checks, 'phases': phases}
                finally:
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
