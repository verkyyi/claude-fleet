#!/usr/bin/env python3
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
    def test_slow_clipboard_keeps_output_and_interrupt(self):
        with tempfile.TemporaryDirectory(prefix="thin-upload-test.") as d:
            d = Path(d)
            clip = d / "clip.py"
            clip.write_text("import time, pathlib, os\npathlib.Path(__file__).with_suffix('.started').write_text(str(os.getpid()))\ntime.sleep(30)\n")
            remote = d / "remote.py"
            remote.write_text("""import os, select, tty
tty.setraw(0)
os.write(1, b'\\x1b]7502;cur;token=test;m=-;l=-;w=fu/fid\\x07READY')
while True:
    r, _, _ = select.select([0], [], [], .02)
    os.write(1, b'.')
    if r and b'\\x03' in os.read(0, 65536): os.write(1, b'INTERRUPTED')
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
                os.write(master, b"\x16")
                end = time.monotonic() + 3
                while not clip.with_suffix('.started').exists() and time.monotonic() < end: time.sleep(.02)
                self.assertTrue(clip.with_suffix('.started').exists(), "capture never started")
                read_until(b"..", .75)
                start = time.monotonic()
                os.write(master, b"held command\r\x03")
                read_until(b"INTERRUPTED", .75)
                print("pump interrupt latency %.3fs" % (time.monotonic() - start), flush=True)
            finally:
                p.terminate()
                try: p.wait(timeout=2)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
                os.close(master)
                if clip.with_suffix('.started').exists():
                    try: os.kill(int(clip.with_suffix('.started').read_text()), signal.SIGKILL)
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

    def test_files_and_immediate_enter_are_ordered_once(self):
        data = self.drop('中文 file.txt', "quote'file.png")
        self.assertEqual(self.tx.feed(data + b'caption\r'), b'')
        out = self.settle()
        self.assertTrue(out.startswith(self.mod.START))
        self.assertTrue(out.endswith(self.mod.END + b'caption\r'))
        import shlex
        paths = shlex.split(out[len(self.mod.START):-len(self.mod.END + b'caption\r')].decode())
        self.assertEqual(len(paths), 2)
        self.assertEqual([Path(p).read_bytes() for p in paths], ['中文 file.txt'.encode(), b"quote'file.png"])
        self.assertEqual(self.tx.poll(), b'')

    def test_two_uploads_do_not_overlap_or_overtake(self):
        a, b = self.drop('first.txt'), self.drop('second.txt')
        self.assertEqual(self.tx.feed(a + b'first caption' + b + b'\r'), b'')
        out = self.settle()
        self.assertEqual(out.count(self.mod.START), 2)
        self.assertLess(out.index(b'first.txt'), out.index(b'first caption'))
        self.assertLess(out.index(b'first caption'), out.index(b'second.txt'))
        self.assertTrue(out.endswith(b'\r'))

    def test_text_cjk_and_every_frame_boundary(self):
        data = self.mod.START + '你好 ordinary text'.encode() + self.mod.END + b'\r'
        for cut in range(len(data) + 1):
            tx = self.mod.Input(lambda: self.req, self.notices.append)
            self.assertEqual(tx.feed(data[:cut]) + tx.feed(data[cut:]), data)
            tx.close()
        os.environ['FLEET_CLIENT_CLIP_CMD'] = '/usr/bin/false'
        self.assertEqual(self.tx.feed(b'\x16after\r') + self.settle(), b'\x16after\r')
        self.assertFalse(self.notices)

    def test_failure_and_unknown_target_discard_enter(self):
        os.environ['FLEET_UPLOAD_FIXTURE_FAIL'] = '1'
        self.tx.feed(self.drop('fail.txt') + b'do not execute\r')
        self.assertEqual(self.settle(), b''); self.assertTrue(self.notices)
        self.req['generation'] = ''
        self.tx.feed(self.drop('unknown.txt') + b'\r')
        self.assertEqual(self.settle(), b'')

    def test_cancel_overflow_and_target_change(self):
        for reason in ('interrupt', 'same-read', 'overflow', 'switch', 'reconnect'):
            with self.subTest(reason=reason):
                os.environ['FLEET_UPLOAD_FIXTURE_DELAY'] = '.5'
                data = self.drop(reason + '.txt')
                if reason == 'same-read':
                    self.assertEqual(self.tx.feed(data + b'discard\r\x03'), b'\x03')
                else:
                    self.tx.feed(data + b'discard\r')
                    if reason == 'interrupt': self.assertEqual(self.tx.feed(b'\x03'), b'\x03')
                    elif reason == 'overflow': self.tx.feed(b'x' * self.mod.CAP)
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
                self.assertEqual(self.tx.feed(b'\x03'), b'\x03')
                self.assertEqual(self.settle(), b'')
                status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True).stdout.strip()
                self.assertTrue(not status or status.startswith(b'Z'), status)


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


if __name__ == "__main__":
    unittest.main()
