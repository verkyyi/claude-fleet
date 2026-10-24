#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet preview dev (bin/fleet-preview.py): a dev server's TCP listener behind the
preview's Unix socket — forwarded only while the command's own processes hold it.

A stub stands in for `fleet-mcp.py --call preview` (FLEET_PREVIEW_CALL) and logs
every call; HOME is a short temp dir (a Unix socket path has ~104 bytes). Real
processes, real sockets, real ownership reads (lsof on macOS, /proc on Linux).
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

BIN = Path(__file__).resolve().parent
TOOL = BIN / 'fleet-preview.py'
WATCH = 0.2

STUB = r'''
import json, os, sys
a = json.loads(sys.argv[-1])
with open(os.environ['STUB_LOG'], 'a') as f:
    f.write(json.dumps(a) + '\n')
if a['action'] == 'register':
    print(json.dumps({'id': 'p1', 'url': 'https://p1.preview.test', 'expires': 0, 'socket': a['socket']}))
elif a['action'] == 'list':
    print(os.environ.get('STUB_LIST') or json.dumps({'previews': []}))
else:
    print(json.dumps({'ok': True}))
'''

# The dev servers: each writes what it was handed, then does its one thing.
SERVERS = {
    'echo': '''
        import json, os, socket, threading
        open(os.environ['OUT'] + '/env', 'w').write(json.dumps({k: v for k, v in os.environ.items()
            if k.startswith(('FLEET_PREVIEW', 'PORT', 'HOST', '__VITE'))}))
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', int(os.environ['PORT']))); s.listen(8)
        def one(c):
            while True:
                d = c.recv(65536)
                if not d: break
                c.sendall(d)
            c.close()
        while True:
            c, _ = s.accept(); threading.Thread(target=one, args=(c,), daemon=True).start()
    ''',
    'idle': '''
        import os, time
        open(os.environ['OUT'] + '/port', 'w').write(os.environ['PORT'])
        while True: time.sleep(1)
    ''',
    'dropper': '''
        import os, socket, time
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', int(os.environ['PORT']))); s.listen(8)
        open(os.environ['OUT'] + '/port', 'w').write(os.environ['PORT'])
        while not os.path.exists(os.environ['OUT'] + '/drop'):
            s.settimeout(0.05)
            try:
                c, _ = s.accept(); c.sendall(b'MINE'); c.close()
            except OSError:
                pass
        s.close(); open(os.environ['OUT'] + '/dropped', 'w').write('1')
        while True: time.sleep(1)
    ''',
    'unix': '''
        import os, socket
        p = os.environ['FLEET_PREVIEW_SOCKET']
        s = socket.socket(socket.AF_UNIX); os.umask(0); s.bind(p); s.listen(8)   # 0666, as uvicorn does
        while True:
            c, _ = s.accept(); c.sendall(b'UNIX'); c.close()
    ''',
}


class Run:
    """One `fleet preview dev` under test."""

    def __init__(self, case, server, *opts, env=None):
        self.case, self.home = case, case.home
        self.out = case.d / 'out'
        script = case.d / (server + '.py')
        script.write_text(textwrap.dedent(SERVERS[server]))
        e = dict(os.environ, HOME=str(self.home), OUT=str(case.d), STUB_LOG=str(case.log),
                 FLEET_PREVIEW_CALL='%s %s' % (sys.executable, case.stub), FLEET_PREVIEW_WATCH_SECS=str(WATCH),
                 FLEET_PREVIEW_HINT_SECS='60', PYTHONUNBUFFERED='1')
        e.update(env or {})
        with self.out.open('w') as fh:   # the child keeps its own copy
            self.p = subprocess.Popen([sys.executable, str(TOOL), 'dev', '--name', 't', *opts, '--',
                                       sys.executable, str(script)], env=e, stdin=subprocess.DEVNULL,
                                      stdout=fh, stderr=subprocess.STDOUT)
        self.sock = self.home / '.fleet-preview' / 't.sock'

    def text(self):
        return self.out.read_text()

    def wait_for(self, what, secs=15):
        end = time.time() + secs
        while time.time() < end:
            if what in self.text():
                return
            if self.p.poll() is not None:
                break
            time.sleep(0.05)
        self.case.fail('no %r in:\n%s' % (what, self.text()))

    def ask(self, data=b'', secs=5):
        c = socket.socket(socket.AF_UNIX)
        c.settimeout(secs)
        c.connect(str(self.sock))
        if data:
            c.sendall(data)
        c.shutdown(socket.SHUT_WR)
        got = b''
        while True:
            d = c.recv(65536)
            if not d:
                break
            got += d
        c.close()
        return got

    def stop(self, sig=signal.SIGTERM):
        if self.p.poll() is None:
            self.p.send_signal(sig)
        return self.p.wait(15)


def wait_file(p, secs=10):
    end = time.time() + secs
    while time.time() < end:
        if p.exists() and p.read_text():
            return p.read_text()
        time.sleep(0.05)
    raise AssertionError('%s never appeared' % p)


def foreign(port, word=b'FOREIGN'):
    """A listener this test owns — outside the command's process tree."""
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    end = time.time() + 5
    while True:   # the port's last connections may still be closing (Linux)
        try:
            s.bind(('127.0.0.1', port))
            break
        except OSError:
            if time.time() > end:
                raise
            time.sleep(0.05)
    s.listen(8)

    def serve():
        while True:
            try:
                c, _ = s.accept()
            except OSError:
                return
            c.sendall(word)
            c.close()
    threading.Thread(target=serve, daemon=True).start()
    return s


class Base(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp(prefix='pvd', dir='/tmp'))
        self.home = self.d / 'h'
        self.home.mkdir()
        self.stub = self.d / 'stub.py'
        self.stub.write_text(STUB)
        self.log = self.d / 'calls'
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            if r.p.poll() is None:
                r.p.kill()
                r.p.wait()
        shutil.rmtree(self.d, ignore_errors=True)

    def run_dev(self, *a, **k):
        r = Run(self, *a, **k)
        self.runs.append(r)
        return r

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []


class Forward(Base):
    def test_bytes_both_ways_env_and_cleanup(self):
        r = self.run_dev('echo')
        r.wait_for('ready:')
        self.assertEqual(r.ask(b'GET / HTTP/1.1\r\n\r\n' + b'x' * 200000), b'GET / HTTP/1.1\r\n\r\n' + b'x' * 200000)
        st = os.lstat(r.sock)
        self.assertEqual(st.st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.home / '.fleet-preview').st_mode & 0o777, 0o700)
        env = json.loads(wait_file(self.d / 'env'))
        self.assertEqual(env['FLEET_PREVIEW_HOST'], 'p1.preview.test')
        self.assertEqual(env['FLEET_PREVIEW_URL'], 'https://p1.preview.test')
        self.assertEqual(env['__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS'], 'p1.preview.test')
        self.assertEqual(env['HOST'], '127.0.0.1')
        self.assertIn('127.0.0.1:%s' % env['PORT'], r.text())
        r.stop()
        self.assertFalse(os.path.lexists(r.sock), 'socket left behind')
        self.assertEqual([c['action'] for c in self.calls()], ['list', 'register', 'close'])
        self.assertIn('preview closed · socket removed', r.text())

    def test_starting_answers_503(self):
        r = self.run_dev('idle')
        r.wait_for('registered')
        self.assertTrue(r.ask(b'GET / HTTP/1.1\r\n\r\n').startswith(b'HTTP/1.1 503'))


class ForeignPort(Base):
    """BREAK-IT preview-bridge-foreign-port: ports are every login's."""

    def test_never_forwards_to_a_listener_outside_the_command(self):
        r = self.run_dev('idle')
        port = int(wait_file(self.d / 'port'))
        s = foreign(port)
        try:
            time.sleep(WATCH * 4)
            for _ in range(3):
                got = r.ask(b'GET / HTTP/1.1\r\n\r\n')
                self.assertNotIn(b'FOREIGN', got)
                self.assertTrue(got.startswith(b'HTTP/1.1 503'), got[:80])
            self.assertNotIn('ready:', r.text())
        finally:
            s.close()

    def test_port_let_go_and_taken_is_not_followed(self):
        r = self.run_dev('dropper', env={'FLEET_PREVIEW_TRUST_SECS': '0'})
        port = int(wait_file(self.d / 'port'))
        r.wait_for('ready:')
        self.assertEqual(r.ask(), b'MINE')
        (self.d / 'drop').write_text('1')
        wait_file(self.d / 'dropped')
        s = foreign(port)
        try:
            got = r.ask(b'GET / HTTP/1.1\r\n\r\n')   # at once: before the watcher's next look
            self.assertNotIn(b'FOREIGN', got)
            self.assertTrue(got.startswith(b'HTTP/1.1 503'), got[:80])
            r.wait_for('stopped listening')
        finally:
            s.close()

    def test_explicit_port_already_held_refuses(self):
        s = foreign(0)
        port = s.getsockname()[1]
        try:
            r = self.run_dev('echo', '--port', str(port))
            self.assertEqual(r.p.wait(15), 1)
            self.assertIn('already held by another process', r.text())
            self.assertEqual(self.calls(), [])
            self.assertFalse(os.path.lexists(r.sock))
        finally:
            s.close()


class Sockets(Base):
    def test_stale_socket_cleared_live_one_refused(self):
        d = self.home / '.fleet-preview'
        d.mkdir(mode=0o700)
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(d / 't.sock'))
        stale.close()                      # bound, never listening: what a killed run leaves
        r = self.run_dev('echo')
        r.wait_for('ready:')
        r.stop()
        live = socket.socket(socket.AF_UNIX)
        live.bind(str(d / 't.sock'))
        live.listen(1)
        try:
            r2 = self.run_dev('echo')
            self.assertEqual(r2.p.wait(15), 1)
            self.assertIn('in use by another running preview', r2.text())
            self.assertTrue(os.path.lexists(d / 't.sock'), 'a live socket was removed')
        finally:
            live.close()

    def test_open_directory_refused(self):
        d = self.home / '.fleet-preview'
        d.mkdir()
        os.chmod(d, 0o755)
        r = self.run_dev('echo')
        self.assertEqual(r.p.wait(15), 1)
        self.assertIn('mode 0700', r.text())

    def test_unix_mode_tightens_the_socket(self):
        r = self.run_dev('unix', '--unix')
        r.wait_for('ready:')
        self.assertEqual(os.lstat(r.sock).st_mode & 0o777, 0o600)
        self.assertEqual(r.ask(), b'UNIX')
        r.stop()
        self.assertFalse(os.path.lexists(r.sock))


class Lease(Base):
    LEFT = json.dumps({'previews': [{'id': 'old', 'socket': 't.sock', 'closed': 0, 'url': 'https://old.preview.test'},
                                    {'id': 'other', 'socket': 'x.sock', 'closed': 0}]})

    def test_dead_runs_preview_is_closed_before_registering(self):
        r = self.run_dev('echo', env={'STUB_LIST': self.LEFT})
        r.wait_for('ready:')
        r.stop()
        self.assertEqual(self.calls(), [{'action': 'list'}, {'action': 'close', 'id': 'old'},
                                        {'action': 'register', 'socket': 't.sock'}, {'action': 'close', 'id': 'p1'}])

    def test_keep_takes_the_same_url_back_and_leaves_it(self):
        r = self.run_dev('echo', '--keep', env={'STUB_LIST': self.LEFT})
        r.wait_for('ready:')
        self.assertIn('reusing https://old.preview.test', r.text())
        env = json.loads(wait_file(self.d / 'env'))
        self.assertEqual(env['FLEET_PREVIEW_HOST'], 'old.preview.test')
        r.stop()
        self.assertEqual(self.calls(), [{'action': 'list'}, {'action': 'renew', 'id': 'old'}])

    def test_signal_reaches_the_command(self):
        r = self.run_dev('echo')
        r.wait_for('ready:')
        port = json.loads(wait_file(self.d / 'env'))['PORT']
        self.assertEqual(r.stop(signal.SIGHUP), 128 + signal.SIGHUP)
        s = socket.socket()
        try:
            s.bind(('127.0.0.1', int(port)))   # the server is gone with it
        finally:
            s.close()


class McpDev(Base):
    """The preview tool's dev / stop: the same run, started in the background."""

    def setUp(self):
        super().setUp()
        import importlib.util
        spec = importlib.util.spec_from_file_location('fleet_mcp', BIN / 'fleet-mcp.py')
        self.mcp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mcp)
        self.env = {'HOME': str(self.home), 'OUT': str(self.d), 'STUB_LOG': str(self.log),
                    'FLEET_CONF_DIR': str(self.d / 'conf'), 'FLEET_PREVIEW_WATCH_SECS': str(WATCH),
                    'FLEET_PREVIEW_CALL': '%s %s' % (sys.executable, self.stub)}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        (self.d / 'echo.py').write_text(textwrap.dedent(SERVERS['echo']))

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        try:
            self.mcp.preview_stop({'action': 'stop', 'name': 'web'})
        except Exception:
            pass
        super().tearDown()

    def test_dev_returns_the_url_and_stop_closes_it(self):
        got = self.mcp.preview_dev({'action': 'dev', 'name': 'web', 'cwd': str(self.d),
                                    'command': 'exec %s echo.py' % sys.executable})
        self.assertTrue(got['ready'] and got['running'], got)
        self.assertEqual((got['url'], got['id']), ('https://p1.preview.test', 'p1'))
        c = socket.socket(socket.AF_UNIX)
        c.connect(str(self.home / '.fleet-preview' / 'web.sock'))
        c.sendall(b'ping')
        self.assertEqual(c.recv(4), b'ping')
        c.close()
        with self.assertRaises(self.mcp.ToolFault):
            self.mcp.preview_dev({'action': 'dev', 'name': 'web', 'command': 'true'})
        out = self.mcp.preview_stop({'action': 'stop', 'name': 'web'})
        self.assertFalse(out['running'], out)
        self.assertIn('preview closed', out['output'])
        self.assertEqual([c['action'] for c in self.calls()], ['list', 'register', 'close'])
        self.assertFalse(os.path.lexists(self.home / '.fleet-preview' / 'web.sock'))

    def test_a_command_that_fails_says_so(self):
        got = self.mcp.preview_dev({'action': 'dev', 'name': 'web', 'cwd': str(self.d), 'command': 'exit 3'})
        self.assertFalse(got['running'])
        self.assertEqual(got['exit'], 3)
        self.assertIn('stopped (exit 3)', got['output'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
