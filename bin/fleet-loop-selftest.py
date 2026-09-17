#!/usr/bin/env python3
"""State/identity/delivery failures and the complete private-server lifecycle."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

loader = importlib.util.spec_from_file_location('fleet_loop', Path(__file__).with_name('fleet-loop.py'))
loop = importlib.util.module_from_spec(loader)
loader.loader.exec_module(loop)
SID = '12345678-1234-1234-1234-123456789abc'


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fleet-loop-test-')
        self.root = Path(self.temp.name)
        self.path = self.root / 'state.json'
        self.r = {'id': 'loop-test', 'status': 'active', 'thread_id': SID,
                  'socket': str(self.root / 'api.sock'), 'worktree': str(self.root),
                  'pane_pid': 42, 'manifest': str(self.root / 'manifest.json'),
                  'fleet': {'session': 'isolated', 'window_id': '@2', 'pane_id': '%2'},
                  'deliveries': 0,
                  'schedule': {'prompt': '继续原任务', 'interval_seconds': 3600, 'next_run_at': 0}}
        loop.save(self.path, self.r)
        self.messages = []
        self.runtime_state = 'idle'
        self.fail_send = False
        self.state = 'done'
        self.clients = ''
        self.transfer = ''
        self.handoff = ''
        self.real_current = loop.current
        owner = self

        class FakeRpc:
            def __init__(self, _): pass
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def call(self, method, params):
                if method == 'thread/read':
                    return {'thread': {'id': SID, 'cwd': str(owner.root),
                                       'status': {'type': owner.runtime_state}}}
                if method == 'turn/start':
                    owner.messages.append(params)
                    if owner.fail_send:
                        raise TimeoutError('unknown whether accepted')
                    return {'turn': {'id': 'accepted-turn-1'}}
                raise AssertionError(method)

        self.patches = [patch.object(loop, 'Rpc', FakeRpc),
                        patch.object(loop, 'current'),
                        patch.object(loop, 'pane', side_effect=lambda _, fmt: self.state if fmt == '#{@claude_state}' else self.transfer if fmt == '#{@agent_transfer_request}' else self.handoff),
                        patch.object(loop, 'tm', side_effect=lambda *_: self.clients)]
        for p in self.patches: p.start()
        self.addCleanup(lambda: [p.stop() for p in reversed(self.patches)])
        self.addCleanup(self.temp.cleanup)

    def read(self): return json.loads(self.path.read_text())

    def test_exact_thread_delivery_and_no_catchup_burst(self):
        loop.dispatch(self.path, now=10000)
        self.assertEqual(len(self.messages), 1)
        self.assertEqual(self.messages[0]['threadId'], SID)
        self.assertIn('继续原任务', self.messages[0]['input'][0]['text'])
        self.assertEqual(self.read()['last_turn_id'], 'accepted-turn-1')
        self.assertEqual(self.read()['schedule']['next_run_at'], 13600)
        loop.dispatch(self.path, now=10001)
        self.assertEqual(len(self.messages), 1)

    def test_busy_and_native_active_defer(self):
        self.state = 'working'
        loop.dispatch(self.path, now=10000)
        self.state = 'done'; self.runtime_state = 'active'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])
        self.assertEqual(self.read()['status'], 'active')

    def test_context_cycle_and_transfer_defer_wakeup(self):
        self.transfer = '/private/request'
        loop.dispatch(self.path, now=10000)
        self.transfer = ''; self.handoff = '1'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])
        self.assertEqual(self.read()['status'], 'active')

    def test_recent_operator_input_defers(self):
        self.clients = '9990|@2'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_replaced_pane_pauses(self):
        loop.current.side_effect = ValueError('replaced pane')
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_new_tui_thread_invalidates_old_loaded_thread(self):
        expected = '|'.join(['isolated', '@2', '42', 'codex', self.r['manifest'], str(self.root)])
        with patch.object(loop, 'pane', side_effect=[expected, '0', json.dumps({'session_id': 'new-thread'})]):
            with self.assertRaisesRegex(ValueError, 'TUI switched'):
                self.real_current(self.r)

    def test_unloaded_thread_never_resumed(self):
        self.runtime_state = 'notLoaded'
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_ambiguous_delivery_is_not_retried(self):
        self.fail_send = True
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        loop.dispatch(self.path, now=20000)
        self.assertEqual(len(self.messages), 1)

    def test_crash_after_persisting_delivering_is_not_retried(self):
        r = self.read(); r['status'] = 'delivering'; loop.save(self.path, r)
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_competing_controller_is_excluded(self):
        with loop.locked(self.path):
            loop.dispatch(self.path, now=10000)
        self.assertEqual(self.messages, [])

    def test_only_owner_can_change_or_stop_loop(self):
        with patch.dict(os.environ, FLEET_LOOP_RECORD=str(self.path), CODEX_THREAD_ID=SID):
            loop.command(argparse.Namespace(command='defer', seconds=600, prompt_file=None))
            self.assertEqual(self.read()['schedule']['interval_seconds'], 600)
            loop.command(argparse.Namespace(command='stop'))
            self.assertEqual(self.read()['status'], 'stopped')
            with self.assertRaises(ValueError): loop.command(argparse.Namespace(command='bind'))
        with patch.dict(os.environ, FLEET_LOOP_RECORD=str(self.path), CODEX_THREAD_ID='f'*36):
            with self.assertRaises(ValueError): loop.command(argparse.Namespace(command='stop'))

    def test_bad_spec_and_wrong_thread_are_rejected(self):
        for value in [{}, {'prompt': 'x', 'interval_seconds': 0},
                      {'prompt': 'x', 'interval_seconds': True},
                      {'prompt': '', 'interval_seconds': 60},
                      {'prompt': 'x', 'interval_seconds': 60, 'next_run_at': float('inf')}]:
            with self.assertRaises(ValueError): loop.spec(value)
        r = self.read(); r['thread_id'] = 'different'; loop.save(self.path, r)
        loop.dispatch(self.path, now=10000)
        self.assertEqual(self.read()['status'], 'paused')
        self.assertEqual(self.messages, [])

    def test_import_successful_wakeup_and_respect_stop(self):
        transcript = self.root / 'source.jsonl'; out = self.root / 'loop.json'
        rows = [{'timestamp': '2026-01-01T00:00:00Z', 'message': {'content': [{'type': 'tool_use', 'id': 'wake', 'name': 'ScheduleWakeup',
                                         'input': {'prompt': '检查 CI', 'delaySeconds': 3600}}]}},
                {'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'wake', 'content': 'ok'}]}}]
        transcript.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        a = argparse.Namespace(transcript=str(transcript), output=str(out))
        loop.from_claude(a)
        self.assertEqual(json.loads(out.read_text())['prompt'], '检查 CI')
        self.assertEqual(json.loads(out.read_text())['next_run_at'], 1767229200)
        rows[0]['message']['content'][0]['input'] = {'stop': True}
        transcript.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        with self.assertRaises(ValueError): loop.from_claude(a)


class BridgeTest(unittest.TestCase):
    def test_private_server_tui_bind_delivery_and_exit(self):
        with tempfile.TemporaryDirectory(prefix='fleet-loop-bridge-') as tmp:
            root = Path(tmp).resolve(); fake = root / 'bin'; fake.mkdir()
            manifest = root / 'manifest.json'; schedule = root / 'loop-spec.json'
            source = subprocess.Popen(['sh', '-c', 'exit 0']); source.wait()
            data = {'source': {'pid': source.pid}, 'fleet': {'session': 'isolated', 'window_id': '@2', 'pane_id': '%2'},
                    'workspace': {'path': str(root)}, 'loop_spec_path': str(schedule)}
            manifest.write_text(json.dumps(data))
            schedule.write_text(json.dumps({'prompt': '检查 CI', 'interval_seconds': 3600, 'next_run_at': 0}))
            codex = fake / 'codex'
            codex.write_text('''#!/usr/bin/env python3
import base64,hashlib,json,os,pathlib,socket,struct,subprocess,sys,threading,time
root=pathlib.Path(os.environ['LOOP_TEST_ROOT']);args=sys.argv[1:]
if 'app-server' in args:
 assert os.environ['FLEET_CODEX_REMOTE']==args[args.index('--listen')+1]
 (root/'server-argv.json').write_text(json.dumps(args));(root/'server-pid').write_text(str(os.getpid()))
 sock=socket.socket(socket.AF_UNIX);sock.bind(args[args.index('--listen')+1].removeprefix('unix://'));sock.listen()
 def connection(c):
  def take(n):
   b=b''
   while len(b)<n:
    x=c.recv(n-len(b))
    if not x:raise EOFError()
    b+=x
   return b
  try:
   header=b''
   while not header.endswith(b'\\r\\n\\r\\n'):header+=take(1)
   key=next(x.split(b':',1)[1].strip() for x in header.split(b'\\r\\n') if x.lower().startswith(b'sec-websocket-key:'))
   accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
   c.sendall(b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\nSec-WebSocket-Accept: '+accept+b'\\r\\n\\r\\n')
   while True:
    a,b=take(2);n=b&127
    assert b&128
    if n==126:n=struct.unpack('!H',take(2))[0]
    elif n==127:n=struct.unpack('!Q',take(8))[0]
    mask=take(4);body=take(n);q=json.loads(bytes(v^mask[i%4] for i,v in enumerate(body)))
    method=q['method']
    if 'id' not in q:continue
    if method=='initialize':result={}
    elif method=='thread/read':result={'thread':{'id':'12345678-1234-1234-1234-123456789abc','cwd':str(root),'status':{'type':'idle'}}}
    elif method=='turn/start':
     (root/'delivered.json').write_text(json.dumps(q['params']));result={'turn':{'id':'native-turn'}}
    else:raise RuntimeError(method)
    payload=json.dumps({'id':q['id'],'result':result}).encode();n=len(payload)
    c.sendall(bytes([129,n]) + payload if n<126 else bytes([129,126])+struct.pack('!H',n)+payload)
  except (EOFError,ConnectionError):pass
  finally:c.close()
 while True:
  c,_=sock.accept();threading.Thread(target=connection,args=(c,),daemon=True).start()
else:
 assert args[:1]==['--remote']
 assert args[1]==os.environ['FLEET_CODEX_REMOTE']
 os.environ['CODEX_THREAD_ID']='12345678-1234-1234-1234-123456789abc'
 subprocess.run([sys.executable,os.environ['LOOP_TEST_SCRIPT'],'bind'],check=True)
 end=time.monotonic()+10
 while not (root/'delivered.json').exists() and time.monotonic()<end:time.sleep(.1)
 assert (root/'delivered.json').exists()
''')
            tmux = fake / 'tmux'
            tmux.write_text('''#!/usr/bin/env python3
import json,os,sys
a=sys.argv[1:];r=os.environ['LOOP_TEST_ROOT']
if a[2:3]==['display-message']:
 f=a[-1]
 if f=='#{pane_pid}':print('42')
 elif f=='#{pane_dead}':print('0')
 elif f=='#{@claude_state}':print('done')
 elif f in ('#{@agent_transfer_request}','#{@handoff_armed}','#{@quota_failover}','#{@agent_transfer_until}'):print('')
 elif f=='#{cursor_x} #{cursor_y} #{pane_width}':print('2 0 80')
 elif f=='#{@codex_identity}':print(json.dumps({'session_id':'12345678-1234-1234-1234-123456789abc'}))
 else:print('isolated|@2|42|codex|'+r+'/manifest.json|'+r)
elif 'capture-pane' in a:print('› ')
''')
            for f in (codex, tmux): f.chmod(0o755)
            script = str(Path(__file__).with_name('fleet-loop.py'))
            env = dict(os.environ, PATH=str(fake)+':'+os.environ['PATH'],
                       FLEET_HANDOFF_MANIFEST=str(manifest), FLEET_LOOP_SPEC=str(schedule),
                       LOOP_TEST_ROOT=str(root), LOOP_TEST_SCRIPT=script)
            cp = subprocess.run(['python3', script, 'bridge', '--', '-c', 'hooks.Stop=[]', 'pickup'],
                                env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(cp.returncode, 0, cp.stdout+cp.stderr)
            r = json.loads((root/'loop/state.json').read_text())
            self.assertEqual(r['status'], 'stopped')
            self.assertEqual(r['deliveries'], 1)
            self.assertEqual(r['last_turn_id'], 'native-turn')
            self.assertEqual(json.loads((root/'delivered.json').read_text())['threadId'], SID)
            self.assertIn('hooks.Stop=[]', json.loads((root/'server-argv.json').read_text()))
            with self.assertRaises(ProcessLookupError): os.kill(int((root/'server-pid').read_text()), 0)
            self.assertFalse(Path(r['socket']).exists())


if __name__ == '__main__':
    unittest.main()
