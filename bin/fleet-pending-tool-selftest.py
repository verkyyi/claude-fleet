#!/usr/bin/env python3
"""Pending oracle compatibility, observation fencing and full-path fork cost.

Private HOME + tmux socket only. --cost keeps the two checks 20 seconds apart;
it counts executed commands, not sampled processes or the entire spinner.
"""
import copy
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import select
import unittest
from unittest.mock import patch

import fleet_pending_tool as oracle

BIN = Path(__file__).resolve().parent


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pending.', dir='/tmp')
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        for d in ('home', 'registry', 'projects/p', 'conf', 'tmux'):
            (self.root / d).mkdir(parents=True)
        self.env = patch.dict(os.environ, dict(HOME=str(self.root / 'home'),
            FLEET_CC_SESSIONS_DIR=str(self.root / 'registry'),
            CLAUDE_PROJECTS_DIR=str(self.root / 'projects'),
            FLEET_CONF_DIR=str(self.root / 'conf'), TMUX_TMPDIR=str(self.root / 'tmux'),
            FLEET_CLAUDE_COMM='P4474_FAKE_CLAUDE'))
        self.env.start(); self.addCleanup(self.env.stop)
        os.environ.pop('TMUX', None); os.environ.pop('TMUX_PANE', None)
        self.tmux = shutil.which('tmux')
        if not self.tmux: self.skipTest('tmux unavailable')
        self.tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-n', 'one',
                ': P4474_FAKE_CLAUDE; sleep 180; :')
        self.addCleanup(lambda: self.tm('kill-server'))
        self.tm('new-window', '-d', '-n', 'two', ': P4474_FAKE_CLAUDE; sleep 180; :')
        for i, name in enumerate(('one', 'two')):
            target = 'test:' + name
            pid = self.tm('display-message', '-p', '-t', target, '#{pane_pid}')
            sid = 'sid-' + name
            self.tm('set-option', '-w', '-t', target, '@fleet_id', '00000000-0000-4000-8000-%012d' % (i+1))
            self.tm('set-option', '-w', '-t', target, '@cc_session_id', sid)
            self.tm('set-option', '-w', '-t', target, '@cc_agent', 'claude')
            birth = oracle.proc.process(int(pid))['birth'][:24]
            started = int(time.mktime(time.strptime(birth, '%a %b %d %H:%M:%S %Y')) * 1000)
            (self.root / 'registry' / (pid + '.json')).write_text(json.dumps(
                {'pid': int(pid), 'sessionId': sid, 'startedAt': started}))
            self.transcript(name, pending=not i)
        self.socket = self.tm('display-message', '-p', '#{socket_path}')

    def tm(self, *args):
        return subprocess.check_output([self.tmux, '-L', 'test', *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def transcript(self, name, pending=False):
        path = self.root / 'projects/p' / ('sid-' + name + '.jsonl')
        rows = [{'message': {'content': [{'type': 'tool_use', 'id': 'first', 'name': 'Bash'},
                                        {'type': 'tool_use', 'id': 'last', 'name': 'AskUserQuestion'}]}}]
        rows.append({'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'last'}]}})
        if not pending: rows.append({'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'first'}]}})
        path.write_text(''.join(json.dumps(x) + '\n' for x in rows))
        return path

    def reader(self):
        return oracle.read_panes('test')

    def observe(self, **kw):
        return oracle.observe(self.reader, **kw)


class Observation(Fixture):
    def test_batch_single_cli_and_parse_once(self):
        with patch.object(oracle, 'pending', wraps=oracle.pending) as parse:
            results = self.observe()
            self.assertEqual(parse.call_count, 2)
        self.assertEqual([r['code'] for r in results], [0, 1])
        self.assertEqual(results[0]['tool'], 'Bash')
        row = self.reader()[0]
        with patch.object(oracle, 'pending', wraps=oracle.pending) as parse:
            duplicate = oracle.observe(lambda: [row, row])
            self.assertEqual(parse.call_count, 1)
            self.assertEqual(duplicate[0], duplicate[1])
        for row, result in zip(self.reader(), results):
            one = oracle.observe(lambda: [row])[0]
            self.assertEqual((one['code'], one['identity']), (result['code'], result['identity']))
            cli = subprocess.run(['sh', str(BIN / 'fleet-pending-tool.sh'), '-L', 'test', row['pane']],
                                 text=True, capture_output=True)
            self.assertEqual(cli.returncode, result['code'])
            self.assertEqual(cli.stdout.strip(), result['tool'])

    def test_independent_checks_reparse_tools_and_recollect(self):
        with patch.object(oracle.Processes, 'collect', wraps=oracle.Processes.collect) as collect:
            first = self.observe()
            self.transcript('one', pending=False)
            second = self.observe(expected={r['pane']: r['identity'] for r in first})
            self.assertEqual(collect.call_count, 2)
        self.assertEqual((first[0]['code'], second[0]['code']), (0, 1))
        self.transcript('one', pending=True)
        self.assertEqual(self.observe()[0]['code'], 0)

    def test_identity_refusals(self):
        first = self.observe()
        expected = {r['pane']: r['identity'] for r in first}
        for key, value in [('worker', 'replacement'), ('sid', 'replacement'), ('agent', 'codex'),
                           ('pane_pid', '1'), ('server_pid', '1'), ('socket', '/missing')]:
            def wrong():
                rows = self.reader(); rows[0][key] = value; return rows
            self.assertEqual(oracle.observe(wrong, expected=expected)[0]['code'], 4, key)
        for key in ('worker', 'sid'):
            def missing():
                rows = self.reader(); rows[0][key] = ''; return rows
            self.assertEqual(oracle.observe(missing)[0]['code'], 4, key)
        for key in ('birth', 'executable', 'pid'):
            old = copy.deepcopy(expected)
            old[first[0]['pane']]['native'][key] = 'reused'
            self.assertEqual(self.observe(expected=old)[0]['code'], 4, key)

    def test_changed_during_read_expired_and_failed_probe(self):
        reads = [self.reader(), self.reader()]
        reads[1][0]['worker'] = 'recycled'
        self.assertEqual(oracle.observe(lambda: reads.pop(0))[0]['code'], 4)
        with patch.object(oracle.time, 'monotonic', side_effect=[10, 30]):
            self.assertTrue(all(r['code'] == 4 for r in self.observe()))
        with patch.object(oracle.Processes, 'collect', side_effect=OSError('ps failed')):
            self.assertTrue(all(r['code'] == 4 for r in self.observe()))
        with patch.object(oracle.proc, 'process', side_effect=ValueError('exited')):
            self.assertTrue(all(r['code'] == 4 for r in self.observe()))

    def test_transcript_changed_during_read_is_not_empty(self):
        reads = 0
        def reader():
            nonlocal reads
            reads += 1
            if reads == 2: self.transcript('two', pending=True)
            return self.reader()
        result = oracle.observe(reader)[1]
        self.assertEqual((result['code'], result['reason']), (4, 'transcript_changed'))

    def test_registry_birth_and_server_birth_are_fenced(self):
        row = self.reader()[0]
        path = self.root / 'registry' / (row['pane_pid'] + '.json')
        r = json.loads(path.read_text()); original = r['startedAt']
        r['startedAt'] = '1000'; path.write_text(json.dumps(r))
        self.assertEqual(self.observe()[0]['reason'], 'registry_birth_changed')
        del r['startedAt']; path.write_text(json.dumps(r))
        self.assertEqual(self.observe()[0]['reason'], 'missing_registry_birth')
        r['startedAt'] = original; path.write_text(json.dumps(r))
        first = self.observe(); old = {r['pane']: r['identity'] for r in first}
        old[first[0]['pane']]['server']['birth'] += ':old'
        self.assertEqual(self.observe(expected=old)[0]['code'], 4)

    def test_cross_socket_same_pane_cannot_reuse_proof(self):
        first = self.observe(); old = {r['pane']: r['identity'] for r in first}
        self.tmux2 = [self.tmux, '-L', 'other']
        def other(*args):
            return subprocess.check_output(self.tmux2 + list(args), text=True).strip()
        other('-f', '/dev/null', 'new-session', '-d', '-s', 'test', ': P4474_FAKE_CLAUDE; sleep 120; :')
        try:
            rows = oracle.read_panes('other')
            rows[0].update(worker=first[0]['identity']['worker'], sid='sid-one', agent='claude')
            birth = oracle.proc.process(int(rows[0]['pane_pid']))['birth'][:24]
            (self.root / 'registry' / (rows[0]['pane_pid'] + '.json')).write_text(
                json.dumps({'pid': int(rows[0]['pane_pid']), 'sessionId': 'sid-one',
                    'startedAt': int(time.mktime(time.strptime(birth, '%a %b %d %H:%M:%S %Y')) * 1000)}))
            result = oracle.observe(lambda: rows, expected=old)
            self.assertEqual(result[0]['code'], 4)
        finally: other('kill-server')

    def test_bad_transcript_and_registry_are_unknown(self):
        path = self.transcript('one')
        for text in ('{bad tool_result\n', 'null\n', ''):
            path.write_text(text)
            self.assertEqual(self.observe()[0]['code'], 4)
        self.transcript('one')
        row = self.reader()[0]
        registry = self.root / 'registry' / (str(row['pane_pid']) + '.json')
        for value in ({'sessionId': '../escape'}, {'sessionId': 'wrong'}, []):
            registry.write_text(json.dumps(value))
            self.assertEqual(self.observe()[0]['code'], 4)

    def test_exit_and_window_reuse_never_reuse_previous_identity(self):
        first = self.observe(); old = {r['pane']: r['identity'] for r in first}
        self.tm('respawn-pane', '-k', '-t', 'test:one', 'sleep 120')
        second = self.observe(expected=old)
        self.assertEqual(second[0]['code'], 4)


class PathCompatibility(Fixture):
    def cli(self, *args):
        return subprocess.run(['sh', str(BIN / 'fleet-pending-tool.sh'), *args], capture_output=True, text=True)

    def test_path_modes_and_target_unknown(self):
        self.assertEqual(self.cli().returncode, 2)
        self.assertEqual(self.cli('/missing/path').returncode, 1)
        self.assertEqual(self.cli('--wrong').returncode, 2)
        path = self.transcript('one', True)
        self.assertEqual((self.cli(str(path)).returncode, self.cli(str(path)).stdout), (0, 'Bash\n'))
        path.write_text('{bad tool_result\n')
        self.assertEqual(self.cli(str(path)).returncode, 1)
        self.tm('set-option', '-w', '-t', 'test:one', '@cc_agent', 'codex')
        self.assertEqual(self.cli('-L', 'test', 'test:one').returncode, 4)
        self.assertEqual(self.cli('-L', 'test', 'missing').returncode, 3)


class Walk(unittest.TestCase):
    def test_canonical_walk_zombies_npm_bun_shells_and_invalid_bytes(self):
        rows = '\n'.join('%d %d %s Fri Oct 16 02:00:00 2026 %s' % row for row in [
            (900, 1, 'Ss', 'zsh'), (901, 900, 'Z', 'claude'),
            (910, 1, 'Ss', 'zsh'), (911, 910, 'S', 'claude'),
            (920, 1, 'Ss', 'node20'), (930, 1, 'Ss', 'bun'),
            (940, 1, 'Ss', 'bash'), (950, 1, 'S', 'python3 \ufffd')])
        with patch.dict(os.environ, FLEET_CLAUDE_COMM='FAKE'), patch.object(oracle, 'process_argv',
            side_effect=lambda pid: {920: ['node', 'claude-code/cli.js'], 930: ['bun', '/a/claude'],
                                     940: ['bash', '-c', 'FAKE']}.get(pid, [])):
            processes = oracle.Processes(rows)
            self.assertEqual([processes.claude(p) for p in (900, 910, 920, 930, 940)],
                             [None, 911, 920, 930, 940])

    def test_optional_ps_row_rejects_stale_pid_without_forking(self):
        p = oracle.Processes.collect()
        proof = p.proof(os.getpid())
        self.assertEqual(proof, oracle.proc.process(os.getpid()))
        p.rows[os.getpid()]['ppid'] += 1
        with self.assertRaises(ValueError): p.proof(os.getpid(), fresh=True)


class Control:
    """A test consumer's existing control connection; no production adapter."""
    def __init__(self):
        self.p = subprocess.Popen(['tmux', '-L', 'test', '-C', 'attach-session', '-t', 'test'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''
        self.reply()

    def reply(self):
        lines, begun = [], False
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if b'\n' not in self.buffer:
                if not select.select([self.p.stdout], [], [], max(0, deadline-time.monotonic()))[0]: break
                data = os.read(self.p.stdout.fileno(), 65536)
                if not data: break
                self.buffer += data
            while b'\n' in self.buffer:
                raw, self.buffer = self.buffer.split(b'\n', 1)
                line = raw.decode().rstrip('\r')
                if line.startswith('%begin '): begun = True; continue
                if line.startswith('%error '): raise AssertionError(line)
                if begun and line.startswith('%end '): return '\n'.join(lines)
                if begun: lines.append(line)
        raise AssertionError('control response timed out')

    def reader(self):
        self.p.stdin.write(('list-panes -a -F ' + shlex.quote(oracle.PANE_FORMAT) + '\n').encode())
        self.p.stdin.flush()
        return oracle.parse_panes(self.reply())

    def close(self):
        self.p.stdin.write(b'detach-client\n'); self.p.stdin.flush()
        self.p.communicate(timeout=5)


def cost():
    f = Fixture(); f.setUp()
    try:
        shim = f.root / 'shim'; shim.mkdir()
        trace = f.root / 'trace'; trace.touch()
        # Every possible subprocess in this path is traced through exec wrappers.
        # PID dedup avoids counting a wrapper's exec twice. Harness/setup/teardown
        # are outside the interval; the control connection's startup is INCLUDED.
        for name in ('ps', 'tmux', 'sh', 'bash', 'python3', 'awk', 'sed', 'head', 'dirname'):
            script = shim / name
            script.write_text('#!/bin/sh\nprintf "%s\\t%s\\t%s\\n" "$$" ' + shlex.quote(name) +
                ' "$*" >> ' + shlex.quote(str(trace)) + '\nexec ' + shlex.quote(shutil.which(name)) + ' "$@"\n')
            script.chmod(0o755)
        with patch.dict(os.environ, PATH=str(shim) + ':' + os.environ['PATH']):
            control = Control()
            try:
                start = time.monotonic()
                first = oracle.observe(control.reader)
                assert [r['code'] for r in first] == [0, 1], first
                time.sleep(20)
                second = oracle.observe(control.reader, expected={r['pane']: r['identity'] for r in first})
                assert [r['code'] for r in second] == [0, 1], second
                elapsed = time.monotonic() - start
            finally: control.close()
        raw = trace.read_text(); rows = [line.split('\t', 2) for line in raw.splitlines()]
        from collections import Counter
        summary = dict(platform=sys.platform, seconds=elapsed, exec_events=len(rows),
            unique_pids=len({r[0] for r in rows}), commands=dict(Counter(r[1] for r in rows)))
        assert summary['commands'] == {'tmux': 1, 'ps': 2}, summary
        if os.environ.get('PENDING_EVIDENCE_DIR'):
            d = Path(os.environ['PENDING_EVIDENCE_DIR']); d.mkdir(parents=True, exist_ok=True)
            (d / 'after.trace').write_text(raw)
            (d / 'after.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary), flush=True)
        print(raw, end='', flush=True)
    finally: f.doCleanups()


class Cost(unittest.TestCase):
    def test_two_fresh_checks_full_path(self):
        cost()


if __name__ == '__main__':
    if '--cost' in sys.argv: cost()
    else: unittest.main()
