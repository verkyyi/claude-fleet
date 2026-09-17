#!/bin/bash
# Private Codex endpoint lifecycle, including SIGKILL of the supervising parent.
# All child processes are bounded fake agents; never a real Codex/model request.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import base64, hashlib, importlib.util, json, os, pathlib, signal, socket, struct, subprocess, sys, tempfile, threading, time, unittest

BIN = pathlib.Path(sys.argv[1])
RUNTIME = BIN / 'fleet-codex-runtime.py'
spec = importlib.util.spec_from_file_location('runtime', RUNTIME)
runtime = importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
spec = importlib.util.spec_from_file_location('rpc', BIN / 'fleet-codex-rpc.py')
rpc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rpc)

FAKE = r'''
import json,os,pathlib,socket,sys,time
args=sys.argv[1:]; root=pathlib.Path(os.environ['RUNTIME_TEST'])
server='app-server' in args
remote=args[args.index('--listen' if server else '--remote')+1]
path=remote.removeprefix('unix://') if hasattr(str,'removeprefix') else remote[7:]
with (root/('server.json' if server else 'client.json')).open('w') as f:
 json.dump(dict(argv=args,remote=os.environ.get('FLEET_CODEX_REMOTE'),pid=os.getpid(),path=path),f)
if server:
 if os.environ.get('FAIL_START'): sys.exit(9)
 s=socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
 end=time.monotonic()+30
 while time.monotonic()<end: time.sleep(.05)
else:
 if '--hold' in args:
  end=time.monotonic()+20
  while pathlib.Path(path).parent.exists() and time.monotonic()<end: time.sleep(.05)
 sys.exit(int(os.environ.get('CLIENT_RC','0')))
'''

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='codex-runtime-test-')
        self.root=pathlib.Path(self.tmp.name)
        fake=self.root/'codex'; fake.write_text('#!'+sys.executable+'\n'+FAKE);fake.chmod(0o755)
        self.env=dict(os.environ,PATH=str(self.root)+':'+os.environ['PATH'],RUNTIME_TEST=str(self.root))

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self,*args,**env):
        return subprocess.run([sys.executable,str(RUNTIME),'--',*args],env=dict(self.env,**env),capture_output=True,text=True,timeout=20)

    def metadata(self,kind):
        return json.loads((self.root/(kind+'.json')).read_text())

    def test_config_and_endpoint_same_on_both_sides(self):
        result=self.run_cli('-c','hooks.Stop=[]','--enable','hooks','-m','fixture','hello')
        self.assertEqual(result.returncode,0,result.stderr)
        server,client=self.metadata('server'),self.metadata('client')
        self.assertEqual(server['remote'],client['remote'])
        self.assertEqual(client['argv'][:2],['--remote',server['remote']])
        self.assertEqual(client['argv'][-1],'hello')
        self.assertEqual(server['argv'][:4],['-c','hooks.Stop=[]','--enable','hooks'])
        self.assertNotIn('-m',server['argv'])
        self.assertFalse(pathlib.Path(server['path']).parent.exists())

    def test_failed_client_preserves_exit(self):
        result=self.run_cli('hello',CLIENT_RC='42')
        self.assertEqual(result.returncode,42,result.stderr)
        self.assertFalse(pathlib.Path(self.metadata('server')['path']).parent.exists())

    def test_startup_failure_does_not_launch_client(self):
        result=self.run_cli('hello',FAIL_START='1')
        self.assertEqual(result.returncode,1)
        self.assertFalse((self.root/'client.json').exists())
        self.assertFalse(pathlib.Path(self.metadata('server')['path']).parent.exists())

    def test_killed_supervisor_cannot_leak_server(self):
        process=subprocess.Popen([sys.executable,str(RUNTIME),'--','--hold'],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            end=time.monotonic()+8
            while not (self.root/'client.json').exists() and time.monotonic()<end:
                self.assertIsNone(process.poll());time.sleep(.05)
            self.assertTrue((self.root/'client.json').exists())
            server=self.metadata('server')
            process.kill();process.wait(timeout=3)
            end=time.monotonic()+8
            while pathlib.Path(server['path']).parent.exists() and time.monotonic()<end:time.sleep(.05)
            self.assertFalse(pathlib.Path(server['path']).parent.exists(),'guardian must remove its owned endpoint on pipe EOF')
            with self.assertRaises(ProcessLookupError):os.kill(server['pid'],0)
        finally:
            if process.poll() is None:process.terminate();process.wait(timeout=10)

    def test_signal_exit_is_not_a_normal_close(self):
        process=subprocess.Popen([sys.executable,str(RUNTIME),'--','--hold'],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            end=time.monotonic()+8
            while not (self.root/'client.json').exists() and time.monotonic()<end:time.sleep(.05)
            self.assertTrue((self.root/'client.json').exists())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10),143)
            self.assertFalse(pathlib.Path(self.metadata('server')['path']).parent.exists())
        finally:
            if process.poll() is None:process.kill();process.wait()

    def test_profile_and_cli_precedence(self):
        try:import tomllib
        except ImportError:self.skipTest('profile parser requires Python 3.11')
        (self.root/'work.config.toml').write_text('model="profile-model"\n[mcp_servers.fixture]\ncommand="fixture-command"\n')
        result=self.run_cli('-p','work','-c','model="override-model"','hello',CODEX_HOME=str(self.root))
        self.assertEqual(result.returncode,0,result.stderr)
        args=self.metadata('server')['argv']
        self.assertLess(args.index('"model"="profile-model"'),args.index('model="override-model"'))
        self.assertTrue(any('fixture-command' in a for a in args))

    def test_rpc_unix_websocket_frames_and_errors(self):
        path=str(self.root/'rpc.sock')
        listener=socket.socket(socket.AF_UNIX);listener.bind(path);listener.listen(1);listener.settimeout(3)
        errors=[]
        def serve():
            try:
                conn,_=listener.accept();conn.settimeout(3)
                def read(n):
                    b=b''
                    while len(b)<n:
                        part=conn.recv(n-len(b))
                        if not part:raise EOFError()
                        b+=part
                    return b
                headers=b''
                while not headers.endswith(b'\r\n\r\n'):headers+=read(1)
                key=[line.split(b': ',1)[1] for line in headers.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:')][0]
                accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
                def receive():
                    first,second=read(2);n=second&127
                    if n==126:n=struct.unpack('!H',read(2))[0]
                    elif n==127:n=struct.unpack('!Q',read(8))[0]
                    self.assertTrue(second&128,'client messages must be masked')
                    mask=read(4);body=read(n);body=bytes(x^mask[i%4] for i,x in enumerate(body))
                    return first&15,body
                def frame(body,op=129):
                    head=bytes([op,len(body)]) if len(body)<126 else bytes([op,126])+struct.pack('!H',len(body))
                    conn.sendall(head+body)
                _,body=receive();req=json.loads(body)
                self.assertEqual(req['method'],'initialize')
                frame(json.dumps({'id':req['id'],'result':{}}).encode())
                receive() # initialized
                _,body=receive();req=json.loads(body)
                self.assertEqual(len(req['params']['text']),70000) # 64-bit client frame
                frame(b'ping',137)
                frame(b'{"method":"notice","params":{}}')
                body=json.dumps({'id':req['id'],'result':{'text':'reply'*1000}}).encode()
                frame(body[:200],1);frame(body[200:],128) # fragmented text
                op,_=receive();self.assertEqual(op,10) # pong
                _,body=receive();req=json.loads(body)
                frame(json.dumps({'id':req['id'],'error':{'message':'fixture refusal'}}).encode())
                conn.close()
            except Exception as exc:errors.append(exc)
        thread=threading.Thread(target=serve,daemon=True);thread.start()
        client=None
        try:
            client=rpc.Client('unix://'+path,timeout=3)
            self.assertEqual(client.call('echo',{'text':'x'*70000})['text'],'reply'*1000)
            with self.assertRaisesRegex(ValueError,'fixture refusal'):client.call('error',{})
        finally:
            if client:client.close()
            listener.close();thread.join(4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors,[])

unittest.main(argv=['codex-runtime'],verbosity=2)
PY
