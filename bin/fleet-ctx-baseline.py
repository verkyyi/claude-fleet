#!/usr/bin/env python3
"""Local machine/model first-turn medians; only called at boundaries or first measure."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import statistics
import sys
import tempfile


def baseline(model, sample=None):
    if not model:
        return ''
    root = Path(os.environ.get('FLEET_CONF_DIR') or Path.home() / '.config/claude-fleet') / 'ctx-baselines'
    root.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256((socket.gethostname() + '\0' + model).encode()).hexdigest()
    path = root / (key + '.json')
    with (root / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            values = json.loads(path.read_text())
        except (OSError, ValueError):
            values = []
        values = [v for v in values if type(v) is int and 0 <= v <= 100][-5:] if isinstance(values, list) else []
        if sample is not None and 0 <= sample <= 100:
            values = (values + [sample])[-5:]
            fd, tmp = tempfile.mkstemp(dir=root)
            try:
                with os.fdopen(fd, 'w') as out:
                    json.dump(values, out)
                os.replace(tmp, path)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
        return str(round(statistics.median(values))) if values else ''


if __name__ == '__main__':
    try:
        print(baseline(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else None))
    except (OSError, ValueError):
        print('')  # Losing history must never keep an old context on the bus.
