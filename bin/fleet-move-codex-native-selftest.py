#!/usr/bin/env python3
"""Opt-in native Codex MCP environment and imported UUID probe; no inference."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import time

BIN = Path(__file__).resolve().parent
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
MCP = runpy.run_path(str(BIN / 'fleet-native-session-env-selftest.py'))['MCP']


def main():
    if os.environ.get('FLEET_NATIVE_CODEX_MOVE_TEST') != '1':
        print('SKIP native Codex move probe (set FLEET_NATIVE_CODEX_MOVE_TEST=1)')
        return
    binary = shutil.which('codex')
    if not binary:
        raise RuntimeError('native Codex required')
    version = subprocess.check_output([binary, '--version'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='fm-native-', dir='/tmp') as td:
        root = Path(td).resolve()
        home = root / 'home'; home.mkdir()
        cx = home / '.codex'; cx.mkdir()
        marker = root / 'hook-ran'
        hook = root / 'bash-env'; hook.write_text('touch '+str(marker)+'\n')
        observed = home / 'observed.json'
        probe = home / 'probe.py'
        probe.write_text('import json,os\nopen('+repr(str(observed))+',"w").write(json.dumps(dict(os.environ)))\n'+MCP)
        server = {'command': 'bash', 'args': ['-c', 'exec python3 "$HOME/probe.py"'],
                  'env_vars': ['FLEET_MOVE_FORWARDED']}
        # TOML inline map, with JSON strings for the command/arguments.
        config = 'mcp_servers.probe={command="bash",args='+json.dumps(server['args'])+',env_vars=["FLEET_MOVE_FORWARDED"]}'
        remote = 'unix://' + str(root / 'rpc.sock')
        env = {'HOME':str(home),'CODEX_HOME':str(cx),'PATH':os.environ['PATH'],
               'BASH_ENV':str(hook),'ENV':str(hook),'SSH_CLIENT':'sentinel',
               'FLEET_MOVE_FORWARDED':'yes','FLEET_MOVE_UNLISTED':'no',
               'TMPDIR':str(root),'LANG':'en_US.UTF-8'}
        with (root / 'server.log').open('w') as log:
            p = subprocess.Popen([binary, 'app-server', '--listen', remote, '-c', config],
                                 env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if (root/'rpc.sock').exists(): break
                    if p.poll() is not None: raise RuntimeError('native server exited')
                    time.sleep(.1)
                c = RPC(remote, timeout=15)
                try:
                    c.call('thread/start', {'cwd':str(root)})
                    for _ in range(100):
                        if observed.exists(): break
                        time.sleep(.1)
                    data = json.loads(observed.read_text())
                    assert data['HOME'] == str(home)
                    assert data['FLEET_MOVE_FORWARDED'] == 'yes'
                    assert not any(k in data for k in ('BASH_ENV','ENV','SSH_CLIENT','FLEET_MOVE_UNLISTED'))
                    assert not marker.exists(), 'parent shell hook reached MCP child'
                    sid = '01a1625a-6695-7bd0-ab61-ab43e70180cc'
                    dest=cx/'sessions/2000/01/01'/('rollout-2000-01-01T00-00-00-'+sid+'.jsonl')
                    dest.parent.mkdir(parents=True)
                    dest.write_text(json.dumps({'timestamp':'2026-10-22T00:00:00Z','type':'session_meta','payload':{
                        'id':sid,'timestamp':'2026-10-22T00:00:00Z','cwd':str(root),'originator':'codex_cli_rs',
                        'cli_version':'0.163.0','source':'cli','model_provider':'openai'}})+'\n')
                    thread=c.call('thread/resume',{'threadId':sid,'cwd':str(root)})['thread']
                    assert thread['id']==sid and Path(thread['cwd']).resolve()==root
                    print(version+': native MCP filtering/forwarding and imported UUID resume PASS (no inference)')
                finally: c.close()
            finally:
                p.terminate()
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: p.kill(); p.wait()


if __name__=='__main__': main()
