#!/usr/bin/env python3
# selftest-entry
"""Drive fleet_session_gate.py, fleet-cleanup-idle.sh / .py, fleet-session-wrap.sh and
fleet-status-7501.py and fleet-park-page.py on an isolated tmux socket: one window / fid / conversation,
real process exit, every origin, drafts / watched / jobs / legacy wrapper held.
The native prompt proof is replaced only for the fake assistant (no model).
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import hashlib
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, BIN / file)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


import fleet_session_gate as gate
reap = module('park_reap', 'fleet-cleanup-idle.py')


@unittest.skipUnless(shutil.which('tmux'), 'tmux absent')
class Park(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='fleet-park-'))
        # kill-server returns before the old listener has fully gone away. Each
        # case needs its own socket so the next start cannot race that shutdown.
        self.label = 'park-' + str(os.getpid()) + '-' + self.root.name[-8:]
        self.env = dict(os.environ, FLEET_CONF_DIR=str(self.root / 'conf'),
                        FLEET_GATE_WAKE_SECS='3', FLEET_GATE_PARK_SECS='3',
                        FLEET_GATE_BG_CMD='false', FLEET_PARK_MEM_FREE='50',
                        FLEET_ID_PUSH='0', FLEET_SKIP_GLOBAL_CONF='1')
        self.env.pop('CCQUOTA_FLEET', None)
        self.env.pop('TMUX', None)
        self.env.pop('TMUX_PANE', None)
        self.tm('new-session', '-d', '-s', 'test', 'sleep 120')
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.tm('kill-server', check=False)
        shutil.rmtree(self.root, ignore_errors=True)

    def tm(self, *args, check=True):
        return subprocess.run(['tmux', '-L', self.label, *args], env=self.env,
                              capture_output=True, text=True, timeout=10, check=check).stdout.strip()

    def set(self, key, value):
        self.tm('set-option', '-w', '-t', self.win, key, value)

    def opt(self, key):
        return self.tm('display-message', '-p', '-t', self.win, '#{' + key + '}')

    def fake(self, agent='claude'):
        self.fid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        self.sid = '11111111-2222-4333-8444-555555555555'
        fake = self.root / 'fake.py'
        fake.write_text(r'''import os,sys,tty,json
from pathlib import Path
agent=sys.argv[1]
Path(sys.argv[2]).write_text(json.dumps(sys.argv[3:]))
print('\x1b[2J\x1b[Hlast answer: preserved\r\nsecond line: 中文',flush=True)
print('fake ready\x1b]7501;state=idle:app='+agent+'\x1b\\',flush=True)
tty.setraw(0)
os.write(1,b'\r\n\xe2\x80\xba ')
b=b''
while True:
 c=os.read(0,4096)
 if not c: break
 b+=c
 if (b'\x1b[200~/exit\x1b[201~\r' if agent=='codex' else b'/exit\r') in b:
  print('\x1b[2J\x1b[Hagent exit screen',flush=True)
  break
 os.write(1,c)
''')
        record = self.root / 'record.py'
        record.write_text('import json,sys\nfrom pathlib import Path\n'
                          'with Path(__file__).with_name("argv").open("a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
        launch = self.root / 'launch'
        launch.write_text('#!/bin/bash\n' +
                          'printf "%s\\n" "$@" >> ' + str(self.root / 'launch-args') + '\n' +
                          'tmux set-option -w -t "$TMUX_PANE" @claude_state done\n' +
                          'tmux set-option -w -t "$TMUX_PANE" @cc_agent ' + agent + '\n' +
                          'tmux set-option -w -t "$TMUX_PANE" ' + ('@codex_session_id' if agent == 'codex' else '@cc_session_id') + ' ' + self.sid + '\n' +
                          'python3 ' + str(record) + ' "$@"\n' +
                          '[ ! -f ' + str(self.root / 'fail') + ' ] || { echo resume-failed; exit 1; }\n' +
                          'exec python3 ' + str(BIN / 'fleet-status-7501.py') + ' relay -- python3 ' + str(fake) + ' ' + agent + ' ' + str(self.root / 'argv.json') + ' "$@"\n')
        launch.chmod(0o755)
        self.env['FLEET_WRAP_LAUNCH'] = str(launch)
        loc = self.root / 'locate'
        loc.write_text('#!/bin/sh\ntmux display-message -p -t "$TMUX_PANE" "' + self.label + '\t#{window_id}"\n')
        loc.chmod(0o755)
        self.env['FLEET_GATE_WIN_CMD'] = str(loc)
        # new-window inherits its server environment; pass only fixture settings.
        import shlex
        cmd = 'env ' + ' '.join(shlex.quote(k + '=' + v) for k, v in self.env.items()
                               if k.startswith('FLEET_') and 'CRED' not in k and 'ASSERT' not in k) + ' bash ' + shlex.quote(str(BIN / 'fleet-session-wrap.sh'))
        self.win = self.tm('new-window', '-d', '-P', '-F', '#{window_id}', '-t', 'test', cmd)
        self.set('@fleet_id', self.fid)
        self.set('@fleet_role', 'worker')
        loc = self.root / 'locate'
        loc.write_text('#!/bin/sh\nprintf "' + self.label + '\\t' + self.win + '\\n"\n')
        loc.chmod(0o755)
        self.env['FLEET_GATE_WIN_CMD'] = str(loc)
        probe = self.root / 'proof'
        probe.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
        probe.chmod(0o755)
        self.env['FLEET_GATE_PARK_PROBE_CMD'] = str(probe)
        self.wait(lambda: self.opt('@park_relay') and self.opt('@codex_session_id' if agent == 'codex' else '@cc_session_id'))
        if agent == 'codex':
            native = self.root / 'native.py'
            native.write_text('''import json
from pathlib import Path
def identity(pane, socket):
 return dict(session_id=%r, remote='unix:///fake-codex.sock')
class client:
 def __init__(self, remote): pass
 def close(self): pass
 def call(self, method, params):
  if method=='thread/read': return dict(thread=dict(id=%r,status=dict(type='idle')))
  if method=='thread/queue/list': return dict(data=[])
  raise ValueError(method)
''' % (self.sid, self.sid))
            self.env['FLEET_GATE_CODEX'] = str(native)
            self.env.pop('FLEET_GATE_PARK_PROBE_CMD')
            self.wait(lambda: '›' in self.tm('capture-pane', '-p', '-t', self.win))

    def test_codex_same_thread_and_paste_exit(self):
        self.fake('codex')
        before = self.opt('pane_pid')
        with patch.dict(os.environ, self.env):
            result = gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertTrue(self.opt('@park_held'))
        self.assertFalse(self.opt('@park_relay'))
        self.assertEqual(self.opt('@codex_session_id'), self.sid)
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        self.assertEqual(self.opt('pane_pid'), before)
        seed = self.root / 'seed'
        seed.write_text('continue this conversation')
        with patch.dict(os.environ, self.env):
            result = gate.wake(self.fid, seed_file=str(seed), why='message')
        self.assertTrue(result.get('ok'), result)
        self.wait(lambda: self.opt('@park_relay'))
        self.assertEqual(self.opt('@codex_session_id'), self.sid)
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        argv = json.loads((self.root / 'argv.json').read_text())
        self.assertEqual(argv, ['--agent', 'codex', 'resume', self.sid, 'continue this conversation'])

    def test_codex_old_relay_holds_without_typing(self):
        self.fake('codex')
        with patch.dict(os.environ, self.env), patch.object(gate, 'relay_request', return_value=dict(ok=True, generation=0)):
            self.assertEqual(gate.park(self.fid).get('why'), 'old_relay')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))

    def test_codex_prompt_and_native_queue_hold(self):
        self.fake('codex')
        with patch.dict(os.environ, self.env):
            w = gate.window(self.fid)
            self.assertTrue(gate.park_proof(w).get('ok'))
            native = Path(self.env['FLEET_GATE_CODEX'])
            original = native.read_text()
            for old, new in (("type='idle'", "type='active'"),
                             ('data=[]', "data=[{'id':'queued'}]"),
                             ("session_id=" + repr(self.sid), "session_id='different'")):
                native.write_text(original.replace(old, new))
                self.assertFalse(gate.park_proof(w).get('ok'), new)
            native.write_text(original)
            self.tm('send-keys', '-t', self.win, '-l', 'unfinished draft')
            self.wait(lambda: 'unfinished draft' in self.tm('capture-pane', '-p', '-t', self.win))
            self.assertEqual(gate.park_proof(w).get('why'), 'draft')
            self.assertFalse(self.opt('@parked'))

    def parked(self):
        self.fake()
        self.set('@fleet_role', 'worker')
        self.set('@worktree', str(self.root))
        with patch.dict(os.environ, self.env):
            self.assertTrue(gate.park(self.fid).get('ok'))

    def test_parked_peer_first_turn(self):
        # Drive fleet-peer-send.sh -> fleet_agent_deliver -> fleet_park_wake,
        # fleet_session_gate.py and the real fleet-session-wrap.sh.
        self.parked()
        p = subprocess.run(['bash', str(BIN / 'fleet-peer-send.sh'), '-L', self.label,
                            self.win, 'wake peer: first sentence'], env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('sent →', p.stdout)
        self.assertIn('wake peer: first sentence', (self.root / 'launch-args').read_text())
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual(rows[-1]['why'], '消息')

    def test_parked_report_queue_drain(self):
        # Drive fleet-peer-queue.sh drain -> children_send -> the same gate.
        self.parked()
        queue = ['bash', str(BIN / 'fleet-peer-queue.sh')]
        p = subprocess.run(queue + ['put', '-L', self.label, '--kind', 'report',
                            '--rid', 'fixture:report', '--to-fid', self.fid],
                           input='child result: complete', env=self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        p = subprocess.run(queue + ['drain', '-L', self.label], env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('delivered 1', p.stdout)
        self.assertIn('child result: complete', (self.root / 'launch-args').read_text())
        book = self.root / 'conf/fleets' / self.label / 'delivery.ndjson'
        self.assertEqual(json.loads(book.read_text().splitlines()[-1])['state'], 'DELIVERED')
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual(rows[-1]['why'], '回报')

    def test_question_is_never_parked(self):
        self.fake()
        self.set('@claude_state', 'needs')
        self.set('@claude_needs', 'ask')
        self.set('@claude_state_ts', str(int(time.time()) - 3600))
        with patch.dict(os.environ, self.env):
            result = gate.park(self.fid)
        self.assertFalse(result['ok'], result)
        self.assertEqual(result['why'], 'asking')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))

    def test_local_child_report_wakes_parent(self):
        # fleet-report-parent.sh must reach the gate before its missing-PID
        # fallback. This drives the report producer, not only queue replay.
        self.parked()
        self.tm('rename-session', '-t', 'test', self.label)
        self.set('@issue', '42')
        child = self.tm('new-window', '-d', '-P', '-F', '#{window_id}', 'sleep 60')
        for k, v in (('@issue', '43'), ('@origin', 'issue-42'), ('@origin_fid', self.fid)):
            self.tm('set-option', '-w', '-t', child, k, v)
        p = subprocess.run(['bash', str(BIN / 'fleet-report-parent.sh'), '-L', self.label,
                            '--win', child, '--state', 'blocked', '--summary', 'fixture child result'],
                           env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('reported →', p.stdout)
        self.assertIn('fixture child result', (self.root / 'launch-args').read_text())
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual(rows[-1]['why'], '回报')

    def test_late_wake_receipt_is_not_a_second_turn(self):
        # A wrapper has taken the seed, but its native ready report arrives
        # after the sender's wait. The queue retries the SAME delivery id.
        self.fake()
        delivery = 'fixture:late-report'
        with patch.dict(os.environ, self.env):
            seed = gate.wake_path(self.fid, 'peer-' + hashlib.sha256(delivery.encode()).hexdigest())
            Path(str(seed) + '.taken').write_text('late report')
            with patch.object(gate.time, 'sleep', side_effect=lambda _: Path(str(seed) + '.launched').touch()):
                result = gate.wake(self.fid, why='回报', delivery=delivery)
            self.assertTrue(result['ok'], result)
            self.assertFalse(result.get('already'), 'awake is not a delivery receipt')
            self.assertTrue(gate.wake(self.fid, why='回报', delivery=delivery)['ok'])
        self.assertFalse(self.opt('@park_wake'))
        self.assertNotIn('late report', (self.root / 'launch-args').read_text())

    def wait(self, predicate):
        until = time.monotonic() + 6
        while time.monotonic() < until:
            if predicate(): return
            time.sleep(.05)
        self.fail('fixture never settled: ' + self.tm('capture-pane', '-p', '-t', self.win))

    def test_process_gone_identity_retained_and_same_conversation_wakes(self):
        self.fake()
        before = self.opt('pane_pid')
        with patch.dict(os.environ, self.env):
            processes = gate.relay_request(gate.window(self.fid), {'op':'status'})
            result = gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertTrue(self.opt('@park_held'))
        self.assertFalse(self.opt('@park_state'))
        self.assertEqual(self.opt('@park_since'), self.opt('@parked'))
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.assertEqual(self.opt('pane_pid'), before)
        self.assertFalse(self.opt('@park_relay'), 'the relay / assistant tree survived parking')
        for pid in (processes['relay_pid'], processes['agent_pid']):
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        self.assertGreater(float(self.opt('@park_saved_mb')), 0)
        self.assertEqual(self.opt('@park_why'), 'idle')
        from fleet_park_metrics import census
        with patch.dict(os.environ, self.env):
            observed = census(self.label, 'test', self.root / 'conf/global')[self.win]
        self.assertEqual(observed['state'], 'parked')
        self.assertEqual(observed['saved_mb'], float(self.opt('@park_saved_mb')))
        self.assertEqual(observed['why'], 'idle')
        with patch.dict(os.environ, self.env):
            result = gate.wake(self.fid, why='消息')
        self.assertTrue(result.get('ok'), result)
        self.wait(lambda: self.opt('@park_relay'))
        self.assertFalse(self.opt('@parked'))
        self.assertFalse(self.opt('@park_held'))
        self.assertFalse(self.opt('@park_since'), 'wake retained a stale parked timestamp')
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertEqual([r['act'] for r in rows], ['park', 'wake'])
        self.assertEqual(rows[0]['fid'], self.fid)
        self.assertEqual(rows[0]['rss_mb'], observed['saved_mb'])

    def test_park_screen_and_keyboard_sentence(self):
        self.fake()
        self.wait(lambda: 'last answer: preserved' in self.tm('capture-pane', '-p', '-t', self.win))
        before = self.tm('capture-pane', '-p', '-t', self.win).split('\n')
        with patch.dict(os.environ, self.env):
            self.assertTrue(gate.park(self.fid)['ok'])
        after = self.tm('capture-pane', '-p', '-t', self.win).split('\n')
        self.assertEqual(after[:-1], (before + [''] * len(after))[:len(after)-1])
        self.assertIn('已停放', after[-1])
        # A real terminal client (not control mode): merely selecting must not wake.
        import pty
        master, slave = pty.openpty()
        client = subprocess.Popen(['tmux', '-L', self.label, 'attach-session', '-t', 'test'],
                                  stdin=slave, stdout=slave, stderr=slave,
                                  env=dict(self.env, TERM='xterm-256color'))
        self.addCleanup(lambda: client.wait(timeout=5))
        self.addCleanup(client.terminate)
        self.addCleanup(lambda: os.close(master))
        self.addCleanup(lambda: os.close(slave))
        self.tm('select-window', '-t', self.win)
        time.sleep(1.2)
        self.assertTrue(self.opt('@park_held'), 'viewing resumed the parked agent')
        self.tm('send-keys', '-t', self.win, '-l', '接着解释 café')
        time.sleep(.4)
        self.assertTrue(self.opt('@park_held'), 'typing resumed before Enter')
        self.assertGreater(int(self.opt('@park_presence')), 0)
        with patch.dict(os.environ, self.env):
            self.assertEqual(gate.wake(self.fid, why='消息', request_only=True).get('why'), 'draft')
        self.tm('send-keys', '-t', self.win, 'Enter')
        self.wait(lambda: self.opt('@park_relay') and not self.opt('@park_held'))
        args = json.loads((self.root / 'argv').read_text().splitlines()[-1])
        self.assertEqual(args[-1], '接着解释 café')
        self.assertIn(self.sid, args)

    def test_wake_failure_keeps_sentence_for_new_chat(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            self.assertTrue(gate.park(self.fid)['ok'])
        (self.root / 'fail').touch()
        self.tm('send-keys', '-t', self.win, '-l', 'keep this sentence')
        self.tm('send-keys', '-t', self.win, 'Enter')
        self.wait(lambda: '接回失败' in self.tm('capture-pane', '-p', '-t', self.win))
        self.assertIn('keep this sentence', self.tm('capture-pane', '-p', '-t', self.win))
        (self.root / 'fail').unlink()
        self.tm('send-keys', '-t', self.win, 'n')
        self.wait(lambda: self.opt('@park_relay') and not self.opt('@park_held'))
        args = json.loads((self.root / 'argv').read_text().splitlines()[-1])
        self.assertEqual(args[-1], 'keep this sentence')
        self.assertNotIn('--resume', args)
        self.assertEqual(self.opt('@fleet_id'), self.fid)

    def narrow_hint(self, language, hint):
        self.env['FLEET_UI_LANG'] = language
        self.fake()
        self.tm('set-option', '-w', '-t', self.win, 'window-size', 'manual')
        self.tm('resize-window', '-t', self.win, '-x', '39', '-y', '24')
        with patch.dict(os.environ, self.env):
            self.assertTrue(gate.park(self.fid)['ok'])
        rows = self.tm('capture-pane', '-p', '-N', '-t', self.win).splitlines()
        # -N keeps the space before a wrapped wide character, plus tmux's
        # physical-cell padding; compare the visible words with that padding folded.
        self.assertEqual(' '.join(''.join(rows[-2:]).split()), hint)

    def test_narrow_english_hint_wraps(self):
        self.narrow_hint('en', '· parked · just type — Enter resumes it (~2 s)')

    def test_narrow_chinese_hint_wraps(self):
        self.narrow_hint('zh', '· 已停放 · 直接打字，回车即接回（约 2 秒）')

    def test_keyboard_retry_preserves_paste_and_literal_keys(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            self.assertTrue(gate.park(self.fid)['ok'])
        (self.root / 'fail').touch()
        sentence = 'new question: r n q 中文\nsecond line\n'
        self.tm('send-keys', '-t', self.win, '-l', '\x1b[200~' + sentence + '\x1b[201~')
        self.tm('send-keys', '-t', self.win, 'Enter')
        self.wait(lambda: '接回失败' in self.tm('capture-pane', '-p', '-t', self.win))
        (self.root / 'fail').unlink()
        self.tm('send-keys', '-t', self.win, 'Enter')
        self.wait(lambda: self.opt('@park_relay') and not self.opt('@park_held'))
        args = json.loads((self.root / 'argv').read_text().splitlines()[-1])
        self.assertEqual(args[-1], sentence)
        self.assertIn(self.sid, args)

    def test_unknown_rss_clears_previous_sample_and_census_stays_unknown(self):
        import fleet_park_metrics as metrics
        census, summarize = metrics.census, metrics.summarize
        self.fake()
        self.set('@park_saved_mb', '999')
        with patch.dict(os.environ, self.env), patch.object(gate, 'park_saved_mb', return_value=None):
            result = gate.park(self.fid)
        self.assertTrue(result.get('ok'), result)
        self.assertFalse(self.opt('@park_saved_mb'), 'old RSS was presented as this park sample')
        rows = [json.loads(l) for l in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertIsNone(rows[-1]['rss_mb'])
        self.assertFalse(self.opt('@park_state'))
        # Replay the <=3.4 command boundary as well as this host's native one.
        command = metrics.command
        def escaped_rows(args):
            raw = command(args)
            return raw.replace('\x1f', r'\037') if 'list-windows' in args else raw
        for reader in (command, escaped_rows):
            with patch.dict(os.environ, self.env), patch.object(metrics, 'command', reader):
                readings = census(self.label, 'test', self.root / 'conf/global')
            self.assertIn(self.win, readings, readings)
            observed = readings[self.win]
            self.assertEqual(observed['state'], 'parked')
            self.assertIsNone(observed['saved_mb'])
            self.assertIsNone(summarize([{'state':'done', 'park':observed}])['parked_saved_mb'])

    def test_draft_and_background_and_legacy_hold(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            proof = Path(self.env['FLEET_GATE_PARK_PROBE_CMD'])
            proof.write_text('#!/bin/sh\necho \'{"ok":false,"why":"draft"}\'\n')
            self.assertEqual(gate.park(self.fid).get('why'), 'draft')
            proof.write_text('#!/bin/sh\necho \'{"ok":true}\'\n')
            with patch.dict(os.environ, FLEET_GATE_BG_CMD='true'):
                self.assertEqual(gate.park(self.fid).get('why'), 'bg')
            self.tm('set-option', '-wu', '-t', self.win, '@park_wrap_ver')
            self.assertEqual(gate.park(self.fid).get('why'), 'old_wrapper')
        self.assertFalse(self.opt('@parked'))
        self.assertTrue(self.opt('@park_relay'))

    def test_driver_parks_when_no_repo_is_hosted(self):
        self.fake()
        # Source is written before the timestamp in set-claude-state.sh. Wait
        # for the final stamp before aging it, or Linux can overwrite our clock.
        self.wait(lambda: self.opt('@claude_state_src') == '7501'
                  and self.opt('@claude_state_ts').isdigit())
        self.set('@claude_state_ts', str(int(time.time()) - 600))
        self.set('@norepo', '1')
        driver = self.root / 'driver'
        driver.mkdir()
        for file in BIN.iterdir():
            if file.is_file() and file.name != 'fleet-lib.sh':
                (driver / file.name).symlink_to(file)
        (driver / 'fleet-lib.sh').write_text(
            'fleet_load_conf() { :; }\n'
            'fleet_socket() { printf %s "' + self.label + '"; }\n'
            'fleet_repos() { :; }\n'
            'fleet_window_repo() { return 1; }\n')
        p = subprocess.run(['bash', str(driver / 'fleet-cleanup-idle.sh'), 'test'],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.opt('@park_held'), 'zero-repo fleet omitted parking: ' + p.stdout + p.stderr + ' state=' + self.opt('@claude_state') + ' ts=' + self.opt('@claude_state_ts') + ' why=' + self.opt('@reap_why'))

    def test_keyboard_bytes_after_proof_cancel_exit(self):
        self.fake()
        with patch.dict(os.environ, self.env):
            w = gate.window(self.fid)
            before = gate.relay_request(w, {'op':'status'})
            self.tm('send-keys', '-t', self.win, '-l', 'unsubmitted draft')
            self.wait(lambda: gate.relay_request(w, {'op':'status'}).get('generation') != before.get('generation'))
            result = gate.relay_request(w, {'op':'exit', 'generation':before['generation']})
        self.assertFalse(result['ok'], result)
        self.assertTrue(self.opt('@park_relay'), 'stale prompt proof stopped the assistant')
        self.assertFalse(self.opt('@parked'))

    def test_all_origins_and_memory_oldest_eligible(self):
        # The reaper's real decision, independent of its close / GitHub roads.
        from types import SimpleNamespace
        args = SimpleNamespace(socket_name=self.label, session='test', window_repo=False, repo='', dry_run=False)
        r = reap.Cleaner(args)
        r.now = 1000
        snap = {'@park_wrap_ver':'1', '@parked':'', '@wrap_gone':'', 'pane_dead':'',
                '@claude_state':'done', '@agent_status':'', '@claude_state_ts':'900',
                '@fleet_id':'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', '@loop':''}
        with patch.dict(os.environ, self.env | {'FLEET_SESSION_PARK_IDLE_UNATTENDED':'1m'}), \
                patch.object(r, 'busy', return_value=False), \
                patch.object(gate, 'presence', return_value=False), \
                patch.object(reap, 'run', return_value='{"ok":true}'):
            for origin in ('person','dispatched','member','driver','orchestrator','probe','web'):
                self.assertTrue(r.web_park('@1', snap | {'@session_origin':origin}), origin)


class NativeReady(unittest.TestCase):
    def test_codex_wake_without_new_session_clock(self):
        from types import SimpleNamespace
        runtime = module('park_runtime', 'fleet-codex-runtime.py')
        with patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(stdout='\t\tmeta\n')):
            self.assertFalse(runtime.input_ready('%1'))
        with patch.object(runtime.subprocess, 'run', return_value=SimpleNamespace(stdout='\tthread-id\tmeta\n')), \
                patch.object(gate, 'wake_ready') as ready:
            self.assertTrue(runtime.input_ready('%1'))
            ready.assert_called_once_with('%1')


if __name__ == '__main__':
    unittest.main()
