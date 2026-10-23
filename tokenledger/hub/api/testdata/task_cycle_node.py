"""HTTP integration peer: real Python fence/processes, bounded fixture native.

The caller supplies a synthetic loopback Hub credential on stdin.
Only the isolated fixture HOME receives it for the real node credential reader.
This is not Claude/Codex runtime acceptance or tmux/relay transport coverage.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

data = json.load(sys.stdin)
root, bin_dir = Path(data['root']), Path(data['bin'])
sys.path.insert(0, str(bin_dir))
for name in list(os.environ):
    if name.startswith(('FLEET_', 'CCQUOTA_')) or name in ('TMUX', 'TMUX_PANE'):
        os.environ.pop(name)
os.environ.update(HOME=str(root), FLEET_CONF_DIR=str(root / 'conf'),
                  FLEET_SKIP_GLOBAL_CONF='1', CCQUOTA_HUB_SOCK='off',
                  CCQUOTA_HUB_URL=data['url'])
# Synthetic credential for this httptest server only, never a managed login's
# credential. Exercise the actual node.env reader in an isolated temporary HOME.
(root / 'conf').mkdir(exist_ok=True)
node_env = root / 'conf' / 'node.env'
node_env.touch(mode=0o600)
node_env.write_text('CCQUOTA_HUB_URL=' + data['url'] + '\nCCQUOTA_TOKEN=' + data['token'] + '\n')

from fleet_control import Control
from fleet_hub_common import canonical
import fleet_task_execution as execution


class Peer(Control):
    def environment(self):
        # The production reader normally obtains node credentials from its
        # managed login. Here they belong to a short-lived loopback test server.
        env = super().environment()
        env.update({k: os.environ[k] for k in ('CCQUOTA_HUB_URL',
                                              'CCQUOTA_HUB_SOCK', 'FLEET_SKIP_GLOBAL_CONF')})
        return env


peer = Peer(root / 'conf', bin_dir=bin_dir)
action = data['action']
if action in ('start', 'continue'):
    snapshot = data['snapshot']
    if action == 'continue':
        claimed = execution.continue_execution(snapshot, data['fleet'], data['exit'], conf_dir=peer.conf_dir)
    else:
        claimed = execution.claim_execution(snapshot, data['fleet'], conf_dir=peer.conf_dir)
    peer.execution.reserve_window(claimed)
    marker = root / ('alive-' + claimed['operation_id'])
    native = "from pathlib import Path; import time; Path(%r).touch(); time.sleep(30)" % str(marker)
    command = [sys.executable, str(bin_dir / 'fleet_task_execution.py'), 'run', '--snapshot', canonical(claimed), '--',
               sys.executable, str(bin_dir / 'fleet_task_execution.py'), 'native', '--component', 'agent', '--',
               sys.executable, '-c', native]
    with (root / 'fixture-native.log').open('a') as log:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                 env=dict(os.environ), start_new_session=True)
    deadline = time.monotonic() + 8
    while not marker.exists():
        if child.poll() is not None or time.monotonic() > deadline:
            execution.terminate_registered(peer.execution, claimed['task_ref'])
            raise RuntimeError('fixture native did not reach its registered exec boundary')
        time.sleep(.02)
    print(json.dumps(claimed))
elif action == 'stop':
    request = data['request']
    snapshot = execution.validate_request(request)
    with peer.store.connect() as db:
        db.execute('INSERT OR IGNORE INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                   (request['operation_id'], request['fleet_id'], 'worker_stop', canonical(request),
                    request['actor'], 'accepted', time.time(), time.time()))
    peer.execution.apply_stop(snapshot)
    execution.terminate_registered(peer.execution, snapshot['task_ref'])
    deadline = time.monotonic() + 8
    while not peer.submit_native_exit(request['operation_id']):
        if time.monotonic() > deadline:
            raise RuntimeError('Hub did not accept the actual registered process exit proof')
        time.sleep(.05)
    with peer.store.connect() as db:
        result = json.loads(db.execute('SELECT result FROM operations WHERE id=?',
                                       (request['operation_id'],)).fetchone()[0])
    print(json.dumps(result['native_exit_receipt']))
elif action == 'old':
    old = execution.read_session(data['fid'], conf_dir=peer.conf_dir)
    assert old['cancel_request'] == data['stop']
    print(json.dumps({'old_stopped': True}))
elif action == 'cleanup':
    for task in data.get('tasks', []):
        current = peer.execution.read(task)
        if current:
            peer.execution.request_stop(task, 'integration-cleanup', generation=current['generation'] + 1)
            execution.terminate_registered(peer.execution, task)
    print('{}')
else:
    raise ValueError('unknown test action')
