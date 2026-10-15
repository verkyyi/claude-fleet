#!/usr/bin/env python3
"""Private native RPC/TUI double shared by loop and transfer selftests."""
import base64,hashlib,json,os,pathlib,socket,struct,subprocess,sys,threading,time
root=pathlib.Path(os.environ['LOOP_TEST_ROOT']);args=sys.argv[1:]
if os.environ.get('TRANSFER_TEST_ROOT'):
 root.resolve().relative_to(pathlib.Path(os.environ['TRANSFER_TEST_ROOT']).resolve())
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
   while not header.endswith(b'\r\n\r\n'):header+=take(1)
   key=next(x.split(b':',1)[1].strip() for x in header.split(b'\r\n') if x.lower().startswith(b'sec-websocket-key:'))
   accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
   c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
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
     (root/'delivered.json').write_text(json.dumps(q['params']))
     with open(root/'delivered.log','a') as log:log.write(json.dumps(q['params'])+'\n')  # every turn, in order
     result={'turn':{'id':'native-turn'}}
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
 if os.environ.get('TRANSFER_TEST_ROOT'):
  identity=dict(owner=str(os.getpid()),session_id=os.environ['CODEX_THREAD_ID'],home=os.environ['HOME']+'/.codex',cwd=str(root),remote=os.environ['FLEET_CODEX_REMOTE'])
  subprocess.run(['tmux','set-option','-w','-t',os.environ['TMUX_PANE'],'@cc_launcher_pid',str(os.getpid())],check=True)
  subprocess.run(['tmux','set-option','-w','-t',os.environ['TMUX_PANE'],'@codex_identity',json.dumps(identity)],check=True)
  subprocess.run(['tmux','set-option','-w','-t',os.environ['TMUX_PANE'],'@claude_state','done'],check=True)
 subprocess.run([sys.executable,os.environ['LOOP_TEST_SCRIPT'],'bind'],check=True,stdout=subprocess.DEVNULL)
 if os.environ.get('TRANSFER_TEST_ROOT'):
  print('Codex ready\n› ',end='',flush=True)
  for line in sys.stdin:pass
  sys.exit(0)
 end=time.monotonic()+10
 while not (root/'delivered.json').exists() and time.monotonic()<end:time.sleep(.1)
 assert (root/'delivered.json').exists()
