#!/usr/bin/env python3
# Slow capture/transfer, ordering, cancellation and lifetime on isolated PTYs.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Isolated PTYs and bounded stand-ins; never a live Fleet socket."""
import importlib.util
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parent


class Pump(unittest.TestCase):
    def test_slow_clipboard_keeps_output_and_cancel(self):
        self.slow('capture')

    def test_stalled_transfer_keeps_output_and_cancel(self):
        self.slow('transfer')

    def slow(self, phase):
        with tempfile.TemporaryDirectory(prefix="thin-upload-test.") as d:
            d = Path(d)
            clip = d / "clip.py"
            clip.write_text("import time, pathlib, os\npathlib.Path(__file__).with_suffix('.started').write_text(str(os.getpid()))\ntime.sleep(30)\n")
            remote = d / "remote.py"
            remote.write_text("""import os, select, tty, signal
tty.setraw(0)
signal.signal(signal.SIGWINCH, lambda *_: os.write(1, b'RESIZED'))
os.write(1, b'\\x1b]7502;cur;token=test;m=-;l=-;w=fu/fid;g=one\\x07READY')
while True:
    r, _, _ = select.select([0], [], [], .02)
    os.write(1, b'.')
    if r:
        data = os.read(0, 65536)
        with open(__file__ + '.input', 'ab') as f: f.write(data)
        os.write(1, b'RESUMED' if b'resumed' in data else b'INTERRUPTED')
""")
            driver = d / "driver.py"
            driver.write_text("""import importlib.util, sys, signal
s = importlib.util.spec_from_file_location('thin', sys.argv[1] + '/fleet-thin.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
t = m.Thin('', '', 'test', local=True)
t.base = {'local': True}; t.home = 'local'
for sig in (signal.SIGTERM, signal.SIGHUP): signal.signal(sig, t.hangup)
signal.signal(signal.SIGWINCH, t.resize)
t.pump([sys.executable, sys.argv[2]], 'test')
""")
            master, slave = os.openpty()
            env = dict(os.environ, HOME=str(d), FLEET_ITERM_PROFILE="0", FLEET_ITERM_KEYS="0",
                       FLEET_CLIENT_CLIP_CMD=f"{sys.executable} {clip}")
            endpoint = d / 'endpoint'; endpoint.mkdir()
            (endpoint / 'fleet-client-upload.py').symlink_to(BIN / 'fleet-thin-upload-fixture.py')
            env['FLEET_REMOTE_BIN'] = str(endpoint)
            marker = clip.with_suffix('.started')
            gesture = b'\x16'
            if phase == 'transfer':
                src = d / 'slow.bin'; src.write_bytes(b'x' * 262144)
                gesture = b'\x1b[200~' + str(src).encode() + b'\x1b[201~'
                marker = d / 'transfer.pid'
                env.update(FLEET_UPLOAD_FIXTURE_DELAY='30', FLEET_UPLOAD_FIXTURE_MARKER=str(marker))
            p = subprocess.Popen([sys.executable, str(driver), str(BIN), str(remote)],
                                 stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
            os.close(slave)
            def read_until(word, timeout=3):
                out = b""; end = time.monotonic() + timeout
                while word not in out and time.monotonic() < end:
                    if select.select([master], [], [], .02)[0]: out += os.read(master, 65536)
                self.assertIn(word, out)
            try:
                read_until(b"READY")
                os.write(master, gesture)
                end = time.monotonic() + 3
                while not marker.exists() and time.monotonic() < end: time.sleep(.02)
                self.assertTrue(marker.exists(), phase + ' never started')
                read_until(b"..", .75)
                import fcntl, struct, termios
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
                os.kill(p.pid, signal.SIGWINCH)
                read_until(b'RESIZED', .75)
                start = time.monotonic()
                os.write(master, b"held command\r\x03")
                read_until('附件已取消'.encode(), .75)
                read_until('输入已恢复'.encode(), .75)
                end = time.monotonic() + .75
                child = int(marker.read_text())
                while time.monotonic() < end:
                    state = subprocess.run(['ps', '-o', 'stat=', '-p', str(child)], capture_output=True).stdout.strip()
                    if not state or state.startswith(b'Z'): break
                    time.sleep(.01)
                self.assertTrue(not state or state.startswith(b'Z'), phase + ' not reaped')
                os.write(master, b'resumed\r')
                read_until(b'RESUMED', .75)
                self.assertEqual(Path(str(remote) + '.input').read_bytes(), b'resumed\r')
                elapsed = time.monotonic() - start
                self.assertLess(elapsed, .75)
                print("pump %s cancel/reap/resume latency %.3fs" % (phase, elapsed), flush=True)
            finally:
                p.terminate()
                try: p.wait(timeout=2)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
                os.close(master)
                if marker.exists():
                    try: os.kill(int(marker.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass


def module(name):
    spec = importlib.util.spec_from_file_location(name, BIN / name)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


class Transactions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="thin-transactions.")
        self.root = Path(self.tmp.name)
        self.old = dict(os.environ)
        os.environ['HOME'] = str(self.root)
        os.environ.pop('FLEET_UPLOAD_FIXTURE_FAIL', None)
        os.environ.pop('FLEET_UPLOAD_FIXTURE_DELAY', None)
        self.remote = self.root / 'remote'; self.remote.mkdir()
        (self.remote / 'fleet-client-upload.py').symlink_to(BIN / 'fleet-thin-upload-fixture.py')
        self.mod = module('fleet-thin-upload.py')
        self.req = dict(base={'local': True}, cur=['-', '-', 'fu/fid'], token='test',
                        generation='one', view='v', rbin=str(self.remote), selection=1)
        self.notices = []
        self.tx = self.mod.Input(lambda: dict(self.req), self.notices.append)

    def tearDown(self):
        self.tx.close()
        os.environ.clear(); os.environ.update(self.old)
        self.tmp.cleanup()

    def settle(self, timeout=8):
        out = b''; end = time.monotonic() + timeout
        while self.tx.busy and time.monotonic() < end:
            out += self.tx.poll(); time.sleep(.01)
        self.assertFalse(self.tx.busy, 'transaction did not settle')
        return out

    def drop(self, *names):
        import shlex
        paths = []
        for name in names:
            p = self.root / name; p.write_bytes(name.encode()); paths.append(str(p))
        return self.mod.START + (' '.join(shlex.quote(p) for p in paths) + ' ').encode() + self.mod.END

    def test_files_insert_once_and_paused_enter_is_discarded(self):
        os.environ['FLEET_UPLOAD_FIXTURE_HOME'] = str(self.root / "remote home's")
        data = self.drop('中文 file.txt', "quote'file.png")
        self.assertEqual(self.tx.feed(data + b'caption\r'), b'')
        out = self.settle()
        self.assertTrue(out.startswith(self.mod.START))
        self.assertTrue(out.endswith(self.mod.END))
        self.assertNotIn(b'caption', out)
        import shlex
        paths = shlex.split(out[len(self.mod.START):-len(self.mod.END)].decode())
        self.assertEqual(len(paths), 2)
        self.assertEqual([Path(p).read_bytes() for p in paths], ['中文 file.txt'.encode(), b"quote'file.png"])
        self.assertEqual(self.tx.poll(), b'')

    def test_two_uploads_do_not_overlap_or_overtake(self):
        a, b = self.drop('first.txt'), self.drop('second.txt')
        self.assertEqual(self.tx.feed(a + b'first caption' + b + b'\r'), b'')
        out = self.settle()
        self.assertEqual(out.count(self.mod.START), 1)
        self.assertNotIn(b'first caption', out)
        self.assertNotIn(b'second.txt', out)
        self.assertTrue(out.endswith(self.mod.END))
        self.assertEqual(self.tx.feed(b'fresh\r'), b'fresh\r')

    def test_paused_flood_and_split_paste_never_replay(self):
        os.environ['FLEET_UPLOAD_FIXTURE_DELAY'] = '.3'
        self.tx.feed(self.drop('first.txt'))
        self.tx.feed(b'x' * (2 * self.mod.CAP) + b'\r')
        self.assertFalse(self.tx.buf)
        self.tx.feed(self.mod.START[:3])
        self.tx.feed(self.mod.START[3:] + b'/do/not/execute')
        out = self.settle()
        self.assertTrue(out.endswith(self.mod.END))
        self.assertEqual(self.tx.feed(b' tail\r' + self.mod.END[:4]), b'')
        self.assertEqual(self.tx.feed(self.mod.END[4:] + b'fresh\r'), b'fresh\r')

    def test_real_progress_aggregate_phases_and_image(self):
        import json
        os.environ['FLEET_UPLOAD_FIXTURE_CHUNK_DELAY'] = '.02'
        a, b = self.root / 'one.bin', self.root / 'two.bin'
        a.write_bytes(b'a' * 262144); b.write_bytes(b'b' * 131072)
        self.tx.feed(self.mod.START + (str(a) + ' ' + str(b)).encode() + self.mod.END)
        self.assertTrue(self.settle(timeout=15).endswith(self.mod.END))
        events = [json.loads(line) for line in (self.root / 'progress.ndjson').read_text().splitlines()]
        self.assertEqual(events[0]['phase'], 'preparing')
        self.assertEqual(events[-1]['phase'], 'uploaded')
        transfer = [e for e in events if e['phase'] in ('uploading', 'confirming')]
        self.assertTrue(any(0 < e['done'] < 262144 for e in transfer), transfer)
        self.assertEqual({e['total'] for e in transfer}, {393216})
        self.assertEqual([e['done'] for e in transfer], sorted(e['done'] for e in transfer))
        self.assertEqual({e['index'] for e in transfer}, {1, 2})
        self.assertEqual(events[-1]['done'], 393216)
        # Actual image gesture, same auto-insert framing and no manufactured Enter.
        clip = self.root / 'image.py'
        clip.write_text("import sys,pathlib\npathlib.Path(sys.argv[1]).write_bytes(b'PNG bytes')\n")
        os.environ['FLEET_CLIENT_CLIP_CMD'] = '%s %s' % (sys.executable, clip)
        self.tx.feed(b'\x16')
        result = self.settle()
        self.assertIn(b'clip.png', result)
        self.assertTrue(result.startswith(self.mod.START) and result.endswith(self.mod.END))

    def test_failed_second_commit_never_inserts_partial_paths(self):
        os.environ['FLEET_UPLOAD_FIXTURE_FAIL_NAME'] = 'second.txt'
        self.tx.feed(self.drop('first.txt', 'second.txt'))
        self.assertEqual(self.settle(), b'')
        completed = list((self.root / '.cache/claude-fleet/inbox').rglob('*first.txt'))
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0].read_bytes(), b'first.txt')
        self.assertFalse(list(self.root.rglob('*.part')))

    def test_text_cjk_and_every_frame_boundary(self):
        data = self.mod.START + '你好 ordinary text'.encode() + self.mod.END + b'\r'
        for cut in range(len(data) + 1):
            tx = self.mod.Input(lambda: self.req, self.notices.append)
            self.assertEqual(tx.feed(data[:cut]) + tx.feed(data[cut:]), data)
            tx.close()
        os.environ['FLEET_CLIENT_CLIP_CMD'] = '/usr/bin/false'
        os.environ['FLEET_UPLOAD_FIXTURE_PROBE_DELAY'] = '30'
        # Startup may be slower on a shared Mac; still far below the stalled
        # 30-second target probe, which must never delay ordinary Ctrl+V.
        self.assertEqual(self.tx.feed(b'\x16') + self.settle(timeout=5), b'\x16')
        self.assertTrue(all('输入已暂停' in n for n in self.notices), self.notices)
        os.environ.pop('FLEET_UPLOAD_FIXTURE_PROBE_DELAY', None)
        large = self.mod.START + b'/' + b'x' * 60000 + self.mod.END
        self.assertEqual(self.tx.feed(large) + self.settle(), large)

    def test_stalled_status_connection_explains_pause_and_cancels(self):
        os.environ['FLEET_UPLOAD_FIXTURE_PROBE_DELAY'] = '30'
        self.tx.feed(self.drop('status-stall.txt'))
        # Establish the deliberately stalled stream before cancelling it. A
        # local pause notice can precede process startup on a loaded machine.
        marker = self.root / 'status-started'
        end = time.monotonic() + 5
        while (not marker.exists() or not self.notices) and time.monotonic() < end:
            self.tx.poll(); time.sleep(.01)
        self.assertTrue(marker.exists(), 'status stream never established')
        self.assertTrue(any('输入已暂停' in n and 'Ctrl+C' in n for n in self.notices))
        self.assertEqual(self.tx.feed(b'not queued\r\x03'), b'')
        self.assertEqual(self.settle(timeout=2), b'')
        self.assertEqual(self.tx.feed(b'fresh\r'), b'fresh\r')

    def test_failure_and_unknown_target_discard_enter(self):
        os.environ['FLEET_UPLOAD_FIXTURE_FAIL'] = '1'
        self.tx.feed(self.drop('fail.txt') + b'do not execute\r')
        self.assertEqual(self.settle(), b''); self.assertTrue(self.notices)
        self.req['generation'] = ''
        self.tx.feed(self.drop('unknown.txt') + b'\r')
        self.assertEqual(self.settle(), b'')

    def test_cancel_overflow_and_target_change(self):
        for reason in ('interrupt', 'same-read', 'switch', 'reconnect'):
            with self.subTest(reason=reason):
                os.environ['FLEET_UPLOAD_FIXTURE_DELAY'] = '.5'
                data = self.drop(reason + '.txt')
                if reason == 'same-read':
                    self.assertEqual(self.tx.feed(data + b'discard\r\x03'), b'')
                else:
                    self.tx.feed(data + b'discard\r')
                    if reason == 'interrupt': self.assertEqual(self.tx.feed(b'\x03'), b'')
                    elif reason == 'switch': self.req['selection'] += 1
                    else: self.req['token'] += 'new'
                self.assertEqual(self.settle(), b'')
                self.assertTrue(self.notices)

    def test_capture_and_transfer_children_are_reaped(self):
        for phase in ('capture', 'transfer'):
            with self.subTest(phase=phase):
                marker = self.root / (phase + '.pid')
                if phase == 'capture':
                    clip = self.root / 'clip.py'
                    clip.write_text('import os,time,pathlib\npathlib.Path(%r).write_text(str(os.getpid()))\ntime.sleep(30)\n' % str(marker))
                    os.environ['FLEET_CLIENT_CLIP_CMD'] = '%s %s' % (sys.executable, clip)
                    self.tx.feed(b'\x16')
                else:
                    os.environ['FLEET_UPLOAD_FIXTURE_MARKER'] = str(marker)
                    os.environ['FLEET_UPLOAD_FIXTURE_DELAY'] = '30'
                    self.tx.feed(self.drop('slow.txt'))
                end = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < end:
                    self.tx.poll(); time.sleep(.01)
                self.assertTrue(marker.exists())
                pid = int(marker.read_text())
                self.assertEqual(self.tx.feed(b'\x03'), b'')
                self.assertEqual(self.settle(), b'')
                status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True).stdout.strip()
                self.assertTrue(not status or status.startswith(b'Z'), status)
                if phase == 'transfer':
                    import json
                    events = [json.loads(s) for s in (self.root / 'progress.ndjson').read_text().splitlines()]
                    self.assertEqual(events[-1]['phase'], 'cancelled')
                    for event in events:
                        if 'pid' in event:
                            live = subprocess.run(['ps', '-o', 'stat=', '-p', str(event['pid'])], capture_output=True).stdout.strip()
                            self.assertTrue(not live or live.startswith(b'Z'), 'status child orphaned')

    def test_hash_timeout_and_shutdown_race(self):
        # Instrument the expensive hash call in a private worker copy. The pump
        # and supervisor stay real; no production bypass or live filesystem.
        copied = self.root / 'worker'; copied.mkdir()
        worker = copied / 'fleet-thin-upload.py'
        original = (BIN / 'fleet-thin-upload.py').read_text()
        (copied / 'fleet-client-upload.py').symlink_to(BIN / 'fleet-client-upload.py')
        marker = self.root / 'hash.pid'
        instrumented = original.replace('dest.write(b); digest.update(b)',
            "dest.write(b); Path(%r).write_text(str(os.getpid())); time.sleep(30); digest.update(b)" % str(marker))
        worker.write_text(instrumented)
        self.mod.__file__ = str(worker)
        self.tx.feed(self.drop('hash.txt') + b'discard\r')
        end = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < end:
            self.tx.poll(); time.sleep(.01)
        self.assertTrue(marker.exists())
        self.tx.feed(b'\x03'); self.assertEqual(self.settle(), b'')
        status = subprocess.run(['ps', '-o', 'stat=', '-p', marker.read_text()], capture_output=True).stdout.strip()
        self.assertTrue(not status or status.startswith(b'Z'))
        worker.write_text(instrumented.replace('TIMEOUT = 120', 'TIMEOUT = .3'))
        self.tx.feed(self.drop('timeout.txt') + b'discard\r')
        self.assertEqual(self.settle(), b'')
        self.assertTrue(self.notices)
        worker.write_text(original)
        self.tx.feed(self.drop('finished.txt') + b'never release\r')
        # Send the request, but do not consume a completed result before close.
        while self.tx.request:
            self.tx.poll(); time.sleep(.01)
        time.sleep(.3)
        self.tx.close()
        self.assertEqual(self.tx.poll(), b'')
        self.assertFalse(self.tx.buf)

    def test_parent_sigkill_reaps_capture_and_private_directory(self):
        import json
        marker = self.root / 'capture.json'
        clip = self.root / 'capture.py'
        clip.write_text('import os,time,json,sys,pathlib\npathlib.Path(%r).write_text(json.dumps([os.getpid(),sys.argv[1]]))\ntime.sleep(30)\n' % str(marker))
        env = dict(os.environ, FLEET_CLIENT_CLIP_CMD='%s %s' % (sys.executable, clip))
        code = """import importlib.util,json,sys,time
s=importlib.util.spec_from_file_location('uploads',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
t=m.Input(lambda:json.loads(sys.argv[2]),lambda _:None);t.feed(b'\\x16')
while True: t.poll();time.sleep(.01)
"""
        p = subprocess.Popen([sys.executable, '-c', code, str(BIN / 'fleet-thin-upload.py'), json.dumps(self.req)], env=env)
        try:
            end = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < end: time.sleep(.02)
            self.assertTrue(marker.exists())
            child, png = json.loads(marker.read_text())
            p.kill(); p.wait()
            end = time.monotonic() + 3
            while Path(png).parent.exists() and time.monotonic() < end: time.sleep(.02)
            self.assertFalse(Path(png).parent.exists(), 'supervisor left its private directory')
            status = subprocess.run(['ps', '-o', 'stat=', '-p', str(child)], capture_output=True).stdout.strip()
            self.assertTrue(not status or status.startswith(b'Z'))
        finally:
            if p.poll() is None: p.kill(); p.wait()


class Topbar(unittest.TestCase):
    def test_width_progress_and_restoration(self):
        import base64, json
        bar = module('fleet-topbar.py')
        state = dict(id='g-123', generation='g', window='@1', until=time.time() + 10, phase='uploading',
                     name='long screenshot name.png', done=3400000, total=8100000, index=2, count=3)
        full = bar.upload_line(state, 120)
        self.assertIn('41%', full)
        self.assertIn('3.4 / 8.1 MB', full)
        self.assertIn('2/3', full)
        self.assertIn('Input paused', full)
        for cols in (20, 32, 45, 80, 120):
            line = bar.upload_line(state, cols)
            self.assertLessEqual(bar.cells(line), cols)
            self.assertIn('cancel', line)
            self.assertIn('41%', line)
        for phase in ('preparing', 'confirming', 'uploaded', 'failed', 'cancelled'):
            line = bar.upload_line(dict(state, phase=phase), 120)
            self.assertIn(phase.title(), line)
            if phase == 'preparing': self.assertNotIn('%', line)
        kv = dict(w='@1', up=base64.b64encode(json.dumps(state).encode()).decode())
        self.assertIn('@view_upload_id', bar.render_upload(kv, 80))
        self.assertIsNone(bar.render_upload(dict(kv, w='@2'), 80))
        state['until'] = 0
        kv['up'] = base64.b64encode(json.dumps(state).encode()).decode()
        self.assertIsNone(bar.render_upload(kv, 80))


class Receiver(unittest.TestCase):
    def setUp(self):
        self.mod = module('fleet-upload-receive.py')
        self.up = module('fleet-client-upload.py')

    def test_target_auth_generation_and_replacement(self):
        import types
        from unittest.mock import patch
        wid = '00000000-0000-0000-0000-000000000001/00000000-0000-0000-0000-000000000002'
        snap = '@1|' + wid.split('/')[1] + '||%1|42|43|session||python|0'
        h = dict(view='v', token='secret', generation='g', cur=['-', '-', wid])
        row = dict(sess='isolated', view='v', token='secret', upload_gen='g',
                   upload_target=snap, fuid=wid.split('/')[0])
        book = {}; attached = [True]
        lease = types.SimpleNamespace(rows=lambda: {'v': row}, attached=lambda r: attached[0],
                                      load_book=lambda: book, tmux_bin=lambda: 'tmux')
        with patch.object(self.mod, 'load', return_value=lease), patch.object(self.mod, 'run', return_value=snap), patch.object(self.mod, 'identity', return_value=snap):
            good = self.mod.target(self.up, h)
            self.assertEqual(good['destination'], snap)
            for key, value in [('token', 'wrong'), ('generation', 'new'), ('cur', ['-', '-', 'bad']), ('identity', {'destination': 'replaced'})]:
                with self.assertRaises(ValueError): self.mod.target(self.up, dict(h, **{key: value}))
            attached[0] = False
            with self.assertRaises(ValueError): self.mod.target(self.up, h)
            attached[0] = True
            book['views'] = {'v': {'taken': 'taken'}}
            with self.assertRaises(ValueError): self.mod.target(self.up, h)
            book.clear(); row['upload_target'] = 'replacement'
            with self.assertRaises(ValueError): self.mod.target(self.up, h)

    def test_integrity_atomic_commit_and_no_rollback_of_completed_file(self):
        import hashlib, io
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(prefix='upload-recv.') as root:
            data = b'complete bytes'; sha = hashlib.sha256(data).hexdigest()
            h = dict(cur=['-', '-', 'fu/00000000-0000-0000-0000-000000000002'],
                     identity={'destination': 'same'}, name='file.txt', size=len(data), sha256=sha)
            with patch.object(self.up, 'inbox_root', return_value=root), patch.object(self.mod, 'identity', return_value='same'):
                first = self.mod.commit(self.up, h, io.BytesIO(data))
                self.assertEqual(Path(first['path']).read_bytes(), data)
                self.assertEqual(self.mod.commit(self.up, h, io.BytesIO(data)), first)
                with self.assertRaises(ValueError): self.mod.commit(self.up, h, io.BytesIO(b'partial'))
                self.assertEqual(Path(first['path']).read_bytes(), data)
                self.assertFalse(list(Path(root).rglob('*.part')))


class LiveTarget(unittest.TestCase):
    def test_checked_receiver_on_isolated_tmux(self):
        import hashlib, json, shutil, sqlite3, uuid
        tmux = shutil.which('tmux')
        if not tmux: self.skipTest('tmux unavailable')
        with tempfile.TemporaryDirectory(prefix='upload-target.') as root:
            root = Path(root); conf = root / 'conf'
            sess = 'upload-test-' + uuid.uuid4().hex[:12]
            (conf / 'fleets' / sess).mkdir(parents=True)
            (conf / 'fleets' / sess / 'conf').write_text('FLEET_REPO=example/test\n')
            (conf / 'control').mkdir()
            db = sqlite3.connect(conf / 'control/state.sqlite3')
            db.execute('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)')
            db.execute('INSERT INTO metadata VALUES (?, ?)', ('machine_id', str(uuid.uuid4())))
            db.commit(); db.close()
            env = dict(os.environ, HOME=str(root), FLEET_CONF_DIR=str(conf), TERM='xterm-256color')
            for k in ('TMUX', 'TMUX_PANE', 'FLEET_SESSION', 'CCQUOTA_FLEET'): env.pop(k, None)
            def run(args, data=None, check=True):
                return subprocess.run(args, input=data, env=env, capture_output=True, timeout=8, check=check)
            def tm(*args): return run([tmux, '-L', sess, *args]).stdout.decode().strip()
            client = None; master = slave = None
            statuses = []
            try:
                tm('-f', '/dev/null', 'new-session', '-d', '-s', sess, 'sleep 300')
                fid = str(uuid.uuid4())
                tm('set-option', '-w', '-t', sess + ':', '@fleet_id', fid)
                tm('new-session', '-d', '-t', sess, '-s', sess + '@view-test')
                fu = run(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_uuid "$2"', '_', str(BIN), sess]).stdout.decode().strip()
                wid = fu + '/' + fid
                master, slave = os.openpty()
                client = subprocess.Popen([tmux, '-L', sess, 'attach-session', '-t', sess + '@view-test'],
                                          stdin=slave, stdout=slave, stderr=slave, env=env)
                views = conf / 'remote-views'; views.mkdir()
                row = views / 'test'
                row.write_text('%s\t%s\tthin\t0\t%s\tcur=%s\ttoken=secret\tfuid=%s\n' %
                               (os.ttyname(slave), sess, client.pid, wid, fu))
                end = time.monotonic() + 3
                while not tm('list-clients', '-F', '#{client_tty}') and time.monotonic() < end: time.sleep(.02)
                sock = tm('display-message', '-p', '-t', sess + ':', '#{socket_path}')
                run(['bash', str(BIN / 'fleet-remote-view.sh'), 'cur', str(views), sock, sess + '@view-test'])
                cells = dict(x.split('=', 1) for x in row.read_text().split('\t')[5:] if '=' in x)
                h = dict(view='test', token='secret', cur=['-', '-', wid], generation=cells['upload_gen'].strip())
                def call(action, h, data=b''):
                    return run([sys.executable, str(BIN / 'fleet-client-upload.py'), action],
                               json.dumps(h).encode() + b'\n' + data, check=False)
                probe = call('target', h)
                self.assertEqual(probe.returncode, 0, probe.stderr)
                h['identity'] = json.loads(probe.stdout)
                data = b'complete uploaded file'
                h.update(name='file.txt', size=len(data), sha256=hashlib.sha256(data).hexdigest())
                sent = call('recv-checked', h, data)
                self.assertEqual(sent.returncode, 0, sent.stderr)
                path = Path(json.loads(sent.stdout)['path'])
                self.assertEqual(path.read_bytes(), data)
                self.assertEqual(call('recv-checked', h, data[:-1]).returncode, 1)
                self.assertEqual(path.read_bytes(), data)
                self.assertFalse(list(root.rglob('*.part')))
                # The real status endpoint and tmux option, on this isolated
                # attached view. Nothing is written to the worker pane.
                def status_start(operation):
                    p = subprocess.Popen([sys.executable, str(BIN / 'fleet-client-upload.py'), 'status'],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                    statuses.append(p)
                    p.stdin.write(json.dumps(dict(h, operation=operation)).encode() + b'\n'); p.stdin.flush()
                    self.assertTrue(select.select([p.stdout], [], [], 5)[0], 'status not ready')
                    self.assertIn('identity', json.loads(p.stdout.readline()))
                    return p
                def status_finish(p, phase):
                    p.stdin.write(json.dumps(dict(phase=phase)).encode() + b'\n'); p.stdin.flush()
                    p.stdin.close(); self.assertEqual(p.wait(timeout=5), 0, p.stderr.read())
                    p.stdout.close(); p.stderr.close()
                def state():
                    import base64
                    return json.loads(base64.b64decode(tm('show-option', '-qv', '-t', '=' + sess + '@view-test:', '@view_upload')))
                tm('set-option', '-t', '=' + sess + '@view-test:', '@view_flash', 'keep this flash')
                tm('set-option', '-t', '=' + sess + '@view-test:', '@view_flash_until', str(int(time.time()) + 60))
                older = status_start(1)
                self.assertEqual(state()['phase'], 'preparing')
                newer = status_start(2)
                older.stdin.close(); older.wait(timeout=5); older.stdout.close(); older.stderr.close()
                self.assertEqual(state()['operation'], 2, 'old EOF cleared the new upload')
                update = dict(phase='uploading', name='screen.png', done=42, total=100, index=1, count=1)
                newer.stdin.write(json.dumps(update).encode() + b'\n'); newer.stdin.flush()
                end = time.monotonic() + 3
                while state()['phase'] != 'uploading' and time.monotonic() < end: time.sleep(.05)
                self.assertEqual(state()['done'], 42)
                raw = tm('show-option', '-qv', '-t', '=' + sess + '@view-test:', '@view_upload')
                win = tm('display-message', '-p', '-t', '=' + sess + '@view-test:', '#{window_id}')
                bar = ("#(python3 '%s/fleet-topbar.py' render --node view=test s=%s reg='%s' g='%s/global' "
                       "sock=#{q:socket_path} cw=#{client_width} w=#{window_id} up=#{q:@view_upload} "
                       "fl=#{q:@view_flash} flu=#{@view_flash_until})") % (BIN, sess, views, conf)
                tm('set-option', '-t', '=' + sess + '@view-test:', 'status-position', 'top')
                tm('set-option', '-t', '=' + sess + '@view-test:', 'status-interval', '2')
                tm('set-option', '-t', '=' + sess + '@view-test:', 'status-format[0]', bar)
                for width in (45, 120):
                    line = run([sys.executable, str(BIN / 'fleet-topbar.py'), 'render', '--node',
                                'cw=' + str(width), 'up=' + raw, 'w=' + win]).stdout.decode().strip()
                    self.assertIn('42%', line)
                    self.assertIn('cancel', line)
                    import fcntl, struct, termios
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
                    os.kill(client.pid, signal.SIGWINCH)
                    tm('refresh-client', '-S', '-t', os.ttyname(slave))
                    seen = b''; end = time.monotonic() + 3
                    while b'42%' not in seen and time.monotonic() < end:
                        if select.select([master], [], [], .05)[0]: seen += os.read(master, 65536)
                    self.assertIn(b'42%', seen, 'status never reached the attached PTY')
                    self.assertNotIn(b'42%%', seen)
                self.assertNotIn('Input paused', tm('capture-pane', '-p', '-t', win))
                status_finish(newer, 'uploaded')
                self.assertEqual(state()['phase'], 'uploaded')
                self.assertLess(state()['until'] - time.time(), 2)
                self.assertEqual(tm('show-option', '-qv', '-t', '=' + sess + '@view-test:', '@view_flash'), 'keep this flash')
                seen = b''; end = time.monotonic() + 5
                while b'keep this flash' not in seen and time.monotonic() < end:
                    if select.select([master], [], [], .05)[0]: seen += os.read(master, 65536)
                self.assertIn(b'keep this flash', seen, 'normal view bar did not return')
                active = status_start(3)
                status_finish(active, 'cancelled')
                self.assertEqual(state()['phase'], 'cancelled')
                # Registry validation can race cur. The tmux-side generation
                # must reject the old publisher without changing the new slot.
                kept = state()['id']
                tm('set-option', '-t', '=' + sess + '@view-test:', '@view_upload_gen', 'replacement')
                self.assertEqual(call('status', dict(h, operation=4)).returncode, 1)
                self.assertEqual(state()['id'], kept)
                tm('set-option', '-t', '=' + sess + '@view-test:', '@view_upload_gen', h['generation'])
                old_gen = status_start(4)
                tm('set-option', '-w', '-t', sess + ':', '@cc_launcher_pid', '999')
                self.assertEqual(call('target', h).returncode, 1, 'replacement accepted')
                run(['bash', str(BIN / 'fleet-remote-view.sh'), 'cur', str(views), sock, sess + '@view-test'])
                old_gen.stdin.close(); old_gen.wait(timeout=5); old_gen.stdout.close(); old_gen.stderr.close()
                self.assertEqual(tm('show-option', '-qv', '-t', '=' + sess + '@view-test:', '@view_upload_id'), '')
                self.assertEqual(call('target', h).returncode, 1, 'old generation accepted')
                client.terminate(); client.wait(timeout=3)
                self.assertEqual(call('target', h).returncode, 1, 'detached view accepted')
            finally:
                for p in statuses:
                    if p.poll() is None:
                        p.terminate()
                        try: p.wait(timeout=2)
                        except subprocess.TimeoutExpired: p.kill(); p.wait()
                    p.stdin.close(); p.stdout.close(); p.stderr.close()
                if client and client.poll() is None: client.terminate(); client.wait(timeout=3)
                for fd in (master, slave):
                    if fd is not None: os.close(fd)
                run([tmux, '-L', sess, 'kill-server'], check=False)


if __name__ == "__main__":
    unittest.main()
