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
if sys.argv[1] == 'target':
    print(json.dumps(identity))
else:
    root = Path.home() / '.cache/claude-fleet/inbox' / h['cur'][2].split('/')[-1]
    root.mkdir(parents=True, exist_ok=True)
    (root.parent / '.target').write_text(json.dumps(h['cur']))
    Path(os.environ.get('FLEET_UPLOAD_FIXTURE_MARKER', str(root.parent / '.started'))).write_text(str(os.getpid()))
    time.sleep(float(os.environ.get('FLEET_UPLOAD_FIXTURE_DELAY', '0')))
    data = sys.stdin.buffer.read((100 << 20) + 1)
    assert not os.environ.get('FLEET_UPLOAD_FIXTURE_FAIL')
    assert len(data) == h['size'] and hashlib.sha256(data).hexdigest() == h['sha256']
    name = re.sub('[^A-Za-z0-9._-]', '_', h['name'])
    path = root / (h['sha256'] + '-' + name)
    path.write_bytes(data)
    print(json.dumps(dict(path=str(path), size=len(data), sha256=h['sha256'])))
