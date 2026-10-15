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
            remote.write_text("""import os, select, tty, signal
tty.setraw(0)
signal.signal(signal.SIGWINCH, lambda *_: os.write(1, b'RESIZED'))
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
                import fcntl, struct, termios
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
                os.kill(p.pid, signal.SIGWINCH)
                read_until(b'RESIZED', .75)
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
        os.environ['FLEET_UPLOAD_FIXTURE_PROBE_DELAY'] = '30'
        self.assertEqual(self.tx.feed(b'\x16after\r') + self.settle(timeout=2), b'\x16after\r')
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
                tm('set-option', '-w', '-t', sess + ':', '@cc_launcher_pid', '999')
                self.assertEqual(call('target', h).returncode, 1, 'replacement accepted')
                run(['bash', str(BIN / 'fleet-remote-view.sh'), 'cur', str(views), sock, sess + '@view-test'])
                self.assertEqual(call('target', h).returncode, 1, 'old generation accepted')
                client.terminate(); client.wait(timeout=3)
                self.assertEqual(call('target', h).returncode, 1, 'detached view accepted')
            finally:
                if client and client.poll() is None: client.terminate(); client.wait(timeout=3)
                for fd in (master, slave):
                    if fd is not None: os.close(fd)
                run([tmux, '-L', sess, 'kill-server'], check=False)


if __name__ == "__main__":
    unittest.main()
