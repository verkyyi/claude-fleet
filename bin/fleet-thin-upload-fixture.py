#!/usr/bin/env python3
"""Fake bounded upload endpoint for isolated thin-client selftests ONLY."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

h = json.loads(sys.stdin.buffer.readline(16385))
assert h.get('token') and h.get('generation') and 'evil' not in h['cur']
identity = {'home': 'fixture', 'destination': 'fixture'}
if sys.argv[1] == 'status':
    (Path.home() / 'status-started').write_text(str(os.getpid()))
    time.sleep(float(os.environ.get('FLEET_UPLOAD_FIXTURE_PROBE_DELAY', '0')))
    print(json.dumps({'identity': identity}), flush=True)
    log = Path.home() / 'progress.ndjson'
    def record(event):
        with log.open('a') as f: f.write(json.dumps(event) + '\n')
    record({'phase': 'preparing', 'pid': os.getpid()})
    terminal = False
    for line in sys.stdin.buffer:
        event = json.loads(line); record(event)
        if event['phase'] in ('uploaded', 'failed', 'cancelled', 'clear'):
            terminal = True; break
    if not terminal: record({'phase': 'cancelled'})
elif sys.argv[1] == 'target':
    time.sleep(float(os.environ.get('FLEET_UPLOAD_FIXTURE_PROBE_DELAY', '0')))
    print(json.dumps(identity))
else:
    root = Path(os.environ.get('FLEET_UPLOAD_FIXTURE_HOME', str(Path.home()))) / '.cache/claude-fleet/inbox' / h['cur'][2].split('/')[-1]
    root.mkdir(parents=True, exist_ok=True)
    (root.parent / '.target').write_text(json.dumps(h['cur']))
    Path(os.environ.get('FLEET_UPLOAD_FIXTURE_MARKER', str(root.parent / '.started'))).write_text(str(os.getpid()))
    time.sleep(float(os.environ.get('FLEET_UPLOAD_FIXTURE_DELAY', '0')))
    data = bytearray()
    while True:
        chunk = sys.stdin.buffer.read(8192)
        if not chunk: break
        data.extend(chunk)
        assert len(data) <= 100 << 20
        if h.get('progress'): print(json.dumps({'received': len(data)}), flush=True)
        time.sleep(float(os.environ.get('FLEET_UPLOAD_FIXTURE_CHUNK_DELAY', '0')))
    if h.get('progress') and not data: print(json.dumps({'received': 0}), flush=True)
    assert not os.environ.get('FLEET_UPLOAD_FIXTURE_FAIL')
    assert h['name'] != os.environ.get('FLEET_UPLOAD_FIXTURE_FAIL_NAME')
    assert len(data) == h['size'] and hashlib.sha256(data).hexdigest() == h['sha256']
    name = re.sub('[^A-Za-z0-9._-]', '_', h['name'])
    path = root / (h['sha256'] + '-' + name)
    path.write_bytes(data)
    print(json.dumps(dict(path=str(path), size=len(data), sha256=h['sha256'])))
