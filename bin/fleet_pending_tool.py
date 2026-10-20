#!/usr/bin/env python3
"""The pending-tool oracle and pane→Claude walk, shared by CLI and batch reads.

observe(reader, expected=None) reads one batch, never changes fleet state. reader
must synchronously return live rows in PANE_FIELDS order (read_panes is the CLI
transport). A caller with a tmux control connection can reuse it without forking.
An observation owns one process table and transcript parse cache, then discards
both. A second safety check MUST call observe again with the earlier identities.
No result is a runtime-idle, delivery, Stop or reclaim permission.
"""
from collections import defaultdict, deque
import calendar
import glob
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

import fleet_launch as launch
from fleet_agent_argv import process_argv
from fleet_runtime import TTL

PANE_FIELDS = ('socket', 'server_pid', 'window', 'pane', 'pane_pid', 'worker', 'agent', 'sid')
PANE_FORMAT = '\t'.join('#{' + k + '}' for k in
    ('socket_path', 'pid', 'window_id', 'pane_id', 'pane_pid', '@fleet_id', '@cc_agent', '@cc_session_id')) + '\t.'
ERRORS = (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.SubprocessError)


class Unknown(ValueError):
    pass


class Processes:
    """ONE canonical BFS, formerly fleet_pane_claude_pids's awk program."""
    def __init__(self, text):
        self.rows = {}
        self.kids = defaultdict(list)
        self.args = {}
        self.proofs = {}
        for line in text.splitlines():
            p, parent, state, rest = line.split(None, 3)
            started, comm = rest[:24], rest[24:].strip()
            if not p.isdigit() or not parent.isdigit() or len(started) != 24 or not comm:
                raise Unknown('invalid_process_table')
            self.rows[int(p)] = dict(ppid=int(parent), state=state, start=started, comm=comm)
            if 'Z' not in state:
                self.kids[int(parent)].append(int(p))

    @classmethod
    def collect(cls):
        text = subprocess.run(['ps', '-axo', 'pid=,ppid=,stat=,lstart=,comm='],
            capture_output=True, text=True, errors='replace', timeout=3, check=True,
            env=dict(os.environ, LC_ALL='C')).stdout
        if not text.strip(): raise Unknown('empty_process_table')
        return cls(text)

    def argv(self, pid):
        if pid not in self.args:
            self.args[pid] = ' ' + ' '.join(process_argv(pid)) + ' '
        return self.args[pid]

    def claude(self, root):
        queue, seen = deque([int(root)]), set()
        while queue:
            pid = queue.popleft()
            if pid in seen: continue
            seen.add(pid)
            row = self.rows.get(pid)
            if not row or 'Z' in row['state']: continue
            base = Path(row['comm']).name
            if base == 'claude': return pid
            if base == 'bun' or re.fullmatch(r'node[0-9]*', base):
                cmd = self.argv(pid)
                if 'claude-code/cli.js' in cmd or '/claude ' in cmd: return pid
            elif base in ('bash', 'sh', 'zsh', 'dash'):
                fake = os.environ.get('FLEET_CLAUDE_COMM', '')
                if fake and fake in self.argv(pid): return pid
            queue.extend(self.kids[pid])
        return None

    def proof(self, pid, fresh=False):
        pid = int(pid)
        row = self.rows[pid]
        if 'Z' in row['state']: raise Unknown('process_exited')
        if fresh or pid not in self.proofs:
            proof = launch.process(pid, ps_row=(str(row['ppid']), row['start']))
            if fresh: return proof
            self.proofs[pid] = proof
        return self.proofs[pid]

    def ancestry(self, pid, root):
        chain, seen = [], set()
        while pid not in seen:
            seen.add(pid)
            chain.append(self.proof(pid))
            if pid == int(root): return chain
            pid = self.rows[pid]['ppid']
        raise Unknown('process_outside_pane')


def pending(path, strict=False):
    """Newest unreturned tool_use, preserving the shell CLI's path rule.

    Strict observations refuse malformed/empty transcripts. Legacy path calls
    still skip malformed JSON and fold read failures to 1 in cli().
    """
    uses, done, order, records = {}, set(), [], 0
    try:
        with open(path, encoding='utf-8', errors='replace') as stream:
            for line in stream:
                if not strict and '"tool_use"' not in line and 'tool_result' not in line: continue
                try: obj = json.loads(line)
                except ValueError:
                    if strict: return 4, ''
                    continue
                if not isinstance(obj, dict):
                    if strict: return 4, ''
                    continue
                records += 1
                message = obj.get('message')
                if not isinstance(message, dict): continue
                content = message.get('content')
                if not isinstance(content, list): continue
                for c in content:
                    if not isinstance(c, dict): continue
                    if c.get('type') == 'tool_use':
                        uses[c.get('id')] = c.get('name') or '?'
                        order.append(c.get('id'))
                    elif c.get('type') == 'tool_result': done.add(c.get('tool_use_id'))
    except (OSError, ValueError, TypeError): return 4, ''
    if strict and not records: return 4, ''
    tuid = next((i for i in reversed(order) if i not in done and i is not None), None)
    return (1, '') if tuid is None else (0, uses[tuid])


def registry(pid):
    directory = Path(os.environ.get('FLEET_CC_SESSIONS_DIR', str(Path.home() / '.claude/sessions')))
    r = json.loads((directory / ('%s.json' % pid)).read_text())
    sid = r['sessionId']
    if (not isinstance(sid, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', sid)
            or str(r.get('pid', pid)) != str(pid)):
        raise Unknown('invalid_registry_identity')
    return r


def transcript(sid):
    directory = os.environ.get('CLAUDE_PROJECTS_DIR', str(Path.home() / '.claude/projects'))
    paths = sorted(glob.glob(glob.escape(directory) + '/*/' + glob.escape(sid) + '.jsonl'))
    return next(p for p in paths if Path(p).is_file())


def read_panes(socket=''):
    """Default transport: one tmux exec. Existing control clients use PANE_FORMAT.

    list-panes -a includes grouped-session duplicates; dedup by socket + pane,
    never by a bare window number or a session name.
    """
    out = launch.tmux('list-panes', '-a', '-F', PANE_FORMAT, socket=socket)
    return parse_panes(out)


def parse_panes(text):
    rows = {}
    for line in text.splitlines():
        values = line.split('\t')
        if len(values) != len(PANE_FIELDS) + 1 or values[-1] != '.': raise Unknown('invalid_pane_row')
        row = dict(zip(PANE_FIELDS, values[:-1]))
        key = row['socket'], row['pane']
        if key in rows and rows[key] != row: raise Unknown('ambiguous_pane')
        rows[key] = row
    return list(rows.values())


def socket_identity(path):
    s = os.stat(path)
    if not stat.S_ISSOCK(s.st_mode): raise Unknown('not_a_socket')
    return dict(path=os.path.realpath(path), device=s.st_dev, inode=s.st_ino)


def file_identity(path):
    s = os.stat(path)
    return s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns


def registry_birth(record, native):
    if not any(k in record for k in ('startedAt', 'procStart')): raise Unknown('missing_registry_birth')
    started = time.mktime(time.strptime(native['birth'][:24], '%a %b %d %H:%M:%S %Y'))
    if 'startedAt' in record and int(float(record['startedAt']) / 1000) != int(started):
        raise Unknown('registry_birth_changed')
    if 'procStart' in record and calendar.timegm(time.strptime(record['procStart'], '%a %b %d %H:%M:%S %Y')) != int(started):
        raise Unknown('registry_birth_changed')


def binding(row, processes):
    if row['agent'] not in ('', 'claude'): raise Unknown('unsupported_agent')
    if not launch.valid_uuid(row['worker']) or not row['sid']: raise Unknown('missing_identity')
    if not re.fullmatch(r'@[0-9]+', row['window']) or not re.fullmatch(r'%[0-9]+', row['pane']):
        raise Unknown('invalid_pane_identity')
    pid = processes.claude(row['pane_pid'])
    if not pid: raise Unknown('no_native_identity')
    r = registry(pid)
    if r['sessionId'] != row['sid']: raise Unknown('native_session_changed')
    chain = processes.ancestry(pid, row['pane_pid'])
    # Native registry versions which publish a birth must agree with the
    # kernel-backed process row; a recycled PID cannot inherit their old SID.
    registry_birth(r, chain[0])
    server = processes.proof(row['server_pid'])
    if chain[-1]['ppid'] != server['pid']: raise Unknown('pane_outside_server')
    return dict(socket=socket_identity(row['socket']), server=server,
        window=row['window'], pane=row['pane'], worker=row['worker'],
        native=chain[0], sid=r['sessionId'], ancestry=chain)


def observe(reader, expected=None):
    """Return [{pane, code, tool, reason, identity, observed_at, expires_at}].

    code 0=pending; 1=read with no open tool; 4=unknown/retain. Absence is never
    idle here (legacy CLI alone retains code 3). expected maps pane IDs to full
    prior identities; it is scoped to ONE socket, checked including its inode,
    server birth, worker, native PID/birth/executable/SID and pane ancestry.
    reader is invoked twice and must not return a cached view. No process, argv
    or transcript cache survives this call; results cannot be refreshed in place.
    """
    start, at = time.monotonic(), time.time()
    rows = reader()  # transport failure raises; callers retain ALL candidates
    results = [dict(version=1, pane=r['pane'], code=4, tool='', reason='unobserved', identity=None,
                    observed_at=at, expires_at=at + TTL) for r in rows]
    if len({r['socket'] for r in rows}) > 1:
        return [dict(r, reason='mixed_sockets') for r in results]
    try: processes = Processes.collect()
    except ERRORS: return [dict(r, reason='process_read_failed') for r in results]
    cache, paths = {}, {}
    for row, result in zip(rows, results):
        try:
            identity = binding(row, processes)
            result['identity'] = identity
            if expected is not None and expected.get(row['pane']) != identity:
                raise Unknown('identity_changed')
            path = transcript(identity['sid'])
            if path not in cache:
                stamp = file_identity(path)
                parsed = pending(path, strict=True)
                if file_identity(path) != stamp: raise Unknown('transcript_changed')
                cache[path] = stamp, parsed
            paths[row['pane']] = path
            result['code'], result['tool'] = cache[path][1]
            result['reason'] = {0: 'pending', 1: 'no_pending', 4: 'transcript_unreadable'}[result['code']]
        except (*ERRORS, StopIteration) as exc:
            result['reason'] = str(exc) if isinstance(exc, Unknown) else 'identity_unavailable'
    try:
        after = reader()
        live = {(r['socket'], r['pane']): r for r in after}
        proofs = {}
        for row, result in zip(rows, results):
            if result['code'] == 4: continue
            try:
                if live.get((row['socket'], row['pane'])) != row: raise Unknown('binding_changed')
                i = result['identity']
                if socket_identity(row['socket']) != i['socket']: raise Unknown('server_changed')
                path = paths[row['pane']]
                if file_identity(path) != cache[path][0]: raise Unknown('transcript_changed')
                for p in [i['server']] + i['ancestry']:
                    if p['pid'] not in proofs: proofs[p['pid']] = processes.proof(p['pid'], fresh=True)
                    if proofs[p['pid']] != p: raise Unknown('process_changed')
                record = registry(i['native']['pid'])
                if record['sessionId'] != i['sid']: raise Unknown('native_session_changed')
                registry_birth(record, i['native'])
            except ERRORS as exc:
                result.update(code=4, tool='', reason=str(exc) if isinstance(exc, Unknown) else 'identity_lost')
    except ERRORS:
        return [dict(r, code=4, tool='', reason='binding_read_failed') for r in results]
    if not 0 <= time.monotonic() - start < TTL:
        return [dict(r, code=4, tool='', reason='expired') for r in results]
    return results


def cli(args):
    if args[:1] == ['--pids']:
        if len(args) == 1: return 0
        try:
            processes = Processes.collect()
            for root in args[1:]:
                pid = processes.claude(root)
                if pid: print(root, pid)
            return 0
        except ERRORS: return 1
    socket = ''
    if args[:1] in (['-L'], ['--socket']):
        if len(args) < 3 or not args[1]: return 2
        socket, args = args[1], args[2:]
    if not args or not args[0] or args[0].startswith('-'): return 2
    target = args[0]
    path_mode = os.path.isfile(target) or '/' in target
    if path_mode:
        code, name = pending(target)
        if name: print(name)
        return 1 if code == 4 else code
    try:
        # Compatibility: old target forms accept tmux names/positions and do not
        # require FID/SID window stamps. They still use the same walk/parser.
        agent = launch.tmux('display-message', '-p', '-t', target, '#{@cc_agent}', socket=socket)
        if agent not in ('', 'claude'): return 4
        try: root = launch.tmux('display-message', '-p', '-t', target, '#{pane_pid}', socket=socket)
        except subprocess.CalledProcessError: return 3
        if not root: return 3
        pid = Processes.collect().claude(root)
        if not pid: return 3
        code, name = pending(transcript(registry(pid)['sessionId']), strict=True)
        if name: print(name)
        return code
    except (*ERRORS, StopIteration): return 4


if __name__ == '__main__':
    sys.exit(cli(sys.argv[1:]))
