#!/usr/bin/env python3
"""Match a batch of verified Claude PIDs to pool labels without emitting tokens.

Input: window/pane/root-pid/optional-stamp rows, ---PROCESSES---, then root/Claude-pid rows.
The shell caller resolves the process trees once. Linux reads /proc in-process;
macOS uses a single ps invocation for all PIDs, rather than one pipeline per pane.
Unknown, unreadable, ambient, and ambiguous credentials produce no account row.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


def digest(token):
    return hashlib.sha256(token).digest()


def account_index(directory):
    labels = {}
    try:
        files = sorted(Path(directory).iterdir())
    except OSError:
        return labels
    for path in files:
        name = path.name
        if name.startswith('.') or name.endswith(('~', '.conf')) or any(c in name for c in '\t\r\n'):
            continue
        try:
            with path.open('rb') as stream:
                token = stream.readline().rstrip()
        except OSError:
            continue
        if token:
            key = digest(token)
            # Duplicate credentials cannot identify one pool label reliably.
            labels[key] = None if key in labels else name
    return labels


def run_probe(argv):
    try:
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=5, check=False)
        return result.stdout if result.returncode == 0 else b''
    except (OSError, subprocess.TimeoutExpired):
        return b''


def process_tokens(pids):
    probe = os.environ.get('FLEET_TOKEN_PROBE')
    if probe:  # Same hermetic seam as fleet_claude_token_sha; never used by default.
        return {pid: run_probe([probe, str(pid)]).split(b'\n', 1)[0] for pid in pids}
    if sys.platform == 'linux':
        tokens = {}
        for pid in pids:
            try:
                fields = Path('/proc', str(pid), 'environ').read_bytes().split(b'\0')
            except OSError:
                continue
            for field in fields:
                if field.startswith(b'CLAUDE_CODE_OAUTH_TOKEN='):
                    tokens[pid] = field.split(b'=', 1)[1]
                    break
        return tokens
    # ps prints a PID column ahead of argv+environment. Only return requested PIDs.
    raw = run_probe(['ps', '-E', '-ww', '-o', 'pid=,command=', '-p', ','.join(map(str, pids))])
    tokens = {}
    for line in raw.splitlines():
        fields = line.split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        pid = int(fields[0])
        match = re.search(rb'(?:^|\s)CLAUDE_CODE_OAUTH_TOKEN=([^\s]+)', fields[1])
        if pid in pids and match:
            tokens[pid] = match[1]
    return tokens


def resolve(text, directory):
    before, separator, after = text.partition('\n---PROCESSES---\n')
    if not separator:
        return []
    processes = {}
    for line in after.splitlines():
        fields = line.split()
        if len(fields) == 2 and all(f.isdigit() and int(f) > 0 for f in fields):
            processes[fields[0]] = int(fields[1])
    if not processes:
        return []
    labels = account_index(directory)
    if not labels:
        return []
    tokens = process_tokens(sorted(set(processes.values())))
    rows = []
    for line in before.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 3:
            continue
        wid, pane, root = fields[:3]
        stamp = fields[3] if len(fields) == 4 else ''
        if not re.fullmatch(r'@\d+', wid) or not re.fullmatch(r'%\d+', pane):
            continue
        token = tokens.get(processes.get(root))
        label = labels.get(digest(token)) if token else None
        if label:
            rows.append((wid, pane, label, "1" if stamp != label else "0"))
    return rows


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(2)
    for row in resolve(sys.stdin.read(), sys.argv[1]):
        print('\t'.join(row))
