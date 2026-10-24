#!/usr/bin/env python3
"""fleet preview register app.sock | list | renew ID | close ID
fleet preview dev [--name web] [--port N] [--unix] [--keep] -- <command> …

register/list/renew/close use the same verified-worker MCP handler; no separate
identity or proxy road.

dev runs a development server and gives it a private preview for as long as it
runs. The preview only reaches a Unix socket, so dev opens ~/.fleet-preview/<name>.sock
itself and forwards each connection, byte for byte (HTTP, SSE and WebSocket HMR
alike), to the TCP listener the command opens on loopback. Ports are shared by
every login on the machine, so a listener is used only while it belongs to a
process of the command's own tree (lsof / /proc), checked again every 2 s and
its process again on every connection; nothing else is ever forwarded to.

  PORT / HOST=127.0.0.1           handed to the command (most dev servers read PORT)
  {port} {host} {socket}          in the command's words, replaced before it starts
                                  (quote them in zsh: '{socket}' before a > is an fd name)
  FLEET_PREVIEW_URL / _HOST / _ID the registered preview, for host checks
  --port N                        the command listens on N (it ignores PORT)
  --unix                          the command listens on $FLEET_PREVIEW_SOCKET itself
  --keep                          leave the preview registered at exit: the next run
                                  with the same --name gets the same URL back

The lease is renewed while the command runs; on exit the preview is closed and
the socket removed. FLEET_PREVIEW_CALL replaces `fleet-mcp.py --call preview`
(the selftest's seam).
"""
import argparse
import errno
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

NAME_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,34}$')   # + ".sock" = the hub's 40
WATCH_S = float(os.environ.get('FLEET_PREVIEW_WATCH_SECS', '2'))
# How long one ownership check vouches for the next connections: /proc is cheap, lsof ~40 ms.
TRUST_S = float(os.environ.get('FLEET_PREVIEW_TRUST_SECS', '0' if os.path.isdir('/proc/self/fd') else '0.5'))
HINT_S = float(os.environ.get('FLEET_PREVIEW_HINT_SECS', '90'))
WILDCARD = ('*', '0.0.0.0', '::', '[::]')
STARTING = (b'HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain; charset=utf-8\r\n'
            b'Retry-After: 2\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n'
            b'fleet preview: the dev server is not listening yet (or it stopped). Retry in a moment.\n')


def say(msg):
    print('fleet preview: ' + msg, flush=True)


class Refuse(Exception):
    pass


def call(args):
    """One preview tool call; its JSON answer."""
    seam = os.environ.get('FLEET_PREVIEW_CALL')
    argv = shlex.split(seam) if seam else [sys.executable, str(Path(__file__).with_name('fleet-mcp.py')),
                                            '--call', 'preview']
    p = subprocess.run(argv + [json.dumps(args)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True, timeout=60)
    out = p.stdout.strip()
    if p.returncode:
        raise Refuse(out or p.stderr.strip() or 'preview %s failed' % args.get('action'))
    try:
        return json.loads(out)
    except ValueError:
        raise Refuse('preview %s: unreadable answer: %s' % (args.get('action'), out[:200]))


def private_dir():
    d = os.path.join(os.path.expanduser('~'), '.fleet-preview')
    try:
        os.mkdir(d, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise Refuse('%s must be your own directory with mode 0700 (chmod 700 %s)' % (d, d))
    return d


def clear_stale(path):
    """A socket left by a run that died is removed; one something still answers on is not."""
    if not os.path.lexists(path):
        return
    st = os.lstat(path)
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.getuid():
        raise Refuse('%s exists and is not your socket; nothing removed' % path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except (ConnectionRefusedError, FileNotFoundError):
        os.unlink(path)
        return
    finally:
        s.close()
    raise Refuse('%s is in use by another running preview; stop it or pick another --name' % path)


# ── which listeners belong to the command ─────────────────────────────────────

def tree(root):
    """root and every process under it."""
    out = subprocess.run(['ps', '-A', '-o', 'pid=,ppid='], stdout=subprocess.PIPE,
                         universal_newlines=True).stdout
    kids = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    seen, todo = {root}, [root]
    while todo:
        for k in kids.get(todo.pop(), ()):
            if k not in seen:
                seen.add(k)
                todo.append(k)
    return seen


def listeners_lsof(pids):
    p = subprocess.run(['lsof', '-nP', '-a', '-iTCP', '-sTCP:LISTEN', '-p', ','.join(map(str, sorted(pids))),
                        '-Fpn'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    rows, pid = [], None
    for line in p.stdout.splitlines():
        if line[:1] == 'p':
            pid = int(line[1:])
        elif line[:1] == 'n' and ':' in line:
            addr, port = line[1:].rsplit(':', 1)
            if port.isdigit():
                rows.append((addr.strip('[]'), int(port), pid))
    return rows


def _hexaddr(h):
    b = bytes.fromhex(h)
    if len(b) == 4:
        return socket.inet_ntop(socket.AF_INET, b[::-1])
    return socket.inet_ntop(socket.AF_INET6, b''.join(b[i:i + 4][::-1] for i in range(0, 16, 4)))


def listeners_proc(pids):
    inode = {}
    for pid in pids:
        try:
            fds = os.listdir('/proc/%d/fd' % pid)
        except OSError:
            continue
        for fd in fds:
            try:
                link = os.readlink('/proc/%d/fd/%s' % (pid, fd))
            except OSError:
                continue
            if link.startswith('socket:['):
                inode[int(link[8:-1])] = pid
    rows = []
    for table in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            lines = Path(table).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            f = line.split()
            if len(f) > 9 and f[3] == '0A' and int(f[9]) in inode:
                h, port = f[1].split(':')
                rows.append((_hexaddr(h), int(port, 16), inode[int(f[9])]))
    return rows


def owned(pids):
    return listeners_proc(pids) if os.path.isdir('/proc/self/fd') else listeners_lsof(pids)


def listeners(root):
    return owned(tree(root))


def dial_addr(addr):
    return '127.0.0.1' if addr in ('*', '0.0.0.0') else '::1' if addr in ('::', '[::]') else addr


def pick(rows, want):
    """(addr, port, pid) to forward to: the asked port, else the lowest one."""
    if want:
        rows = [r for r in rows if r[1] == want]
    rows = sorted(rows, key=lambda r: (r[1], r[0] not in ('127.0.0.1', '*', '0.0.0.0')))
    return rows[0] if rows else None


def port_taken(port):
    """Is a loopback port already held (before the command starts, so not by it)?"""
    for fam, addr in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
        s = socket.socket(fam, socket.SOCK_STREAM)
        try:
            s.bind((addr, port))
        except OSError as exc:
            if exc.errno == errno.EADDRINUSE:
                return True
        finally:
            s.close()
    return False


# ── the forwarder ─────────────────────────────────────────────────────────────

class Bridge:
    def __init__(self, path, want, strict):
        self.path, self.want, self.strict = path, want, strict
        self.target, self.seen, self.lock, self.vlock = None, 0.0, threading.Lock(), threading.Lock()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old = os.umask(0o177)
        try:
            self.srv.bind(path)
        finally:
            os.umask(old)
        os.chmod(path, 0o600)
        self.srv.listen(64)

    def serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def set(self, t):
        with self.lock:
            self.target, self.seen = t, time.time()

    def holds(self, t):
        """Does t's process still listen on t's address? (a port is anyone's once let go)"""
        return alive(t[2]) and any(r[:2] == t[:2] for r in owned({t[2]}))

    def current(self):
        with self.vlock:
            with self.lock:
                t, seen = self.target, self.seen
            if t and (time.time() - seen > TRUST_S or not alive(t[2])):
                t = t if self.holds(t) else None
                self.set(t)
            return t

    def handle(self, c):
        t, u = self.current(), None
        if t:
            try:
                u = socket.create_connection((dial_addr(t[0]), t[1]), timeout=5)
                u.settimeout(None)
            except OSError:
                u = None
        if u is not None and TRUST_S == 0 and not self.holds(t):
            u.close()   # it let go while we dialled: whoever answered is not the command
            u = None
        if u is None:
            refuse(c)
            return
        back = threading.Thread(target=pump, args=(u, c), daemon=True)
        back.start()
        pump(c, u)
        back.join()
        u.close()
        c.close()

    def close(self):
        try:
            self.srv.close()
        finally:
            try:
                os.unlink(self.path)
            except OSError:
                pass


def refuse(c):
    """503, then read the request out before closing: closing with unread bytes
    makes Linux reset the connection, and the reset can eat the 503."""
    try:
        c.sendall(STARTING)
        c.shutdown(socket.SHUT_WR)
        c.settimeout(2)
        while c.recv(65536):
            pass
    except OSError:
        pass
    finally:
        c.close()


def pump(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:   # another UID's pid: never ours
        return False


# ── dev ───────────────────────────────────────────────────────────────────────

def register(name, keep):
    """A preview of this task already on the socket is a dead run's (the socket was
    free): --keep takes it back, otherwise it is closed so it holds no slot."""
    sock = name + '.sock'
    try:
        old = [p for p in call({'action': 'list'}).get('previews') or []
               if p.get('socket') == sock and not p.get('closed') and p.get('id')]
    except Refuse:
        old = []
    for p in old:
        if keep:
            call({'action': 'renew', 'id': p['id']})
            return p, True
        try:
            call({'action': 'close', 'id': p['id']})
        except Refuse:
            pass
    return call({'action': 'register', 'socket': sock}), False


def renewer(pv_id, expires, stop):
    """Renew at half the remaining lease; a failure retries in 5 minutes."""
    while True:
        wait = max(60.0, (expires - time.time()) / 2) if expires else 3600.0
        if stop.wait(wait):
            return
        try:
            call({'action': 'renew', 'id': pv_id})
            expires = 0
            say('lease renewed')
        except Refuse as exc:
            say('note: renew failed (%s); retrying in 5 min' % exc)
            expires = time.time() + 600


def dev(argv):
    ap = argparse.ArgumentParser(prog='fleet preview dev',
                                 description='Run a dev server with a private preview (see fleet preview --help).')
    ap.add_argument('--name', default='dev', help='socket name: ~/.fleet-preview/<name>.sock (default dev)')
    ap.add_argument('--port', type=int, help='the port the command listens on, when it ignores PORT')
    ap.add_argument('--unix', action='store_true', help='the command listens on $FLEET_PREVIEW_SOCKET itself')
    ap.add_argument('--keep', action='store_true', help='keep the preview registered after exit (same URL next run)')
    ap.add_argument('cmd', nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd[:1] == ['--'] else a.cmd
    if not cmd:
        ap.error('give the dev command after --, e.g. fleet preview dev -- npm run dev')
    if not NAME_RE.match(a.name):
        ap.error('--name: letters, digits, - and _ (at most 35)')
    if a.unix and a.port:
        ap.error('--unix and --port do not go together')
    try:
        return run(a, cmd)
    except Refuse as exc:
        print('fleet preview: %s. Nothing started.' % exc, file=sys.stderr)
        return 1


def run(a, cmd):
    path = os.path.join(private_dir(), a.name + '.sock')
    if len(path.encode()) > 103:   # sun_path: 104 on macOS, 108 on Linux
        raise Refuse('%s is too long for a Unix socket; use a shorter --name' % path)
    clear_stale(path)
    port = a.port
    if not a.unix and not port:
        s = socket.socket()
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
        s.close()
    elif port and port_taken(port):
        raise Refuse('port %d is already held by another process, not by your command; '
                     'a preview never forwards to it' % port)
    bridge = None if a.unix else Bridge(path, port, strict=bool(a.port))
    try:
        pv, reused = register(a.name, a.keep)
    except Refuse:
        if bridge:
            bridge.close()
        raise
    url, pv_id = pv.get('url') or '', pv.get('id') or ''
    host = urlsplit(url).hostname or ''
    say('%s %s (%s) · %s' % ('reusing' if reused else 'registered', url or '(no URL from the hub)', pv_id,
                              'starting: ' + ' '.join(cmd)))
    env = dict(os.environ, FLEET_PREVIEW_URL=url, FLEET_PREVIEW_HOST=host, FLEET_PREVIEW_ID=pv_id,
               FLEET_PREVIEW_SOCKET=path)
    if host:
        env['__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS'] = host   # Vite's own host check (≥ 6.0.9)
    if port:
        env.update(PORT=str(port), HOST='127.0.0.1')
    words = [w.replace('{port}', str(port or '')).replace('{host}', host).replace('{socket}', path) for w in cmd]
    stop = threading.Event()
    try:
        child = subprocess.Popen(words, env=env)
    except OSError as exc:
        finish(bridge, path, pv_id, a.keep, None)
        raise Refuse('cannot start %s: %s' % (words[0], exc))
    # A terminal's Ctrl+C already reaches the command (same process group); a kill
    # aimed at this process alone is passed on.
    tty = sys.stdin.isatty()
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda s, f: None if (s == signal.SIGINT and tty) else forward(child, s))
    threading.Thread(target=renewer, args=(pv_id, pv.get('expires') or 0, stop), daemon=True).start()
    if bridge:
        threading.Thread(target=bridge.serve, daemon=True).start()
        threading.Thread(target=watch, args=(bridge, child, url, stop), daemon=True).start()
    else:
        threading.Thread(target=watch_unix, args=(path, child, url, stop), daemon=True).start()
    rc = child.wait()
    stop.set()
    finish(bridge, path, pv_id, a.keep, rc)
    return rc if rc >= 0 else 128 - rc


def forward(child, sig):
    try:
        child.send_signal(sig)
    except OSError:
        pass


def finish(bridge, path, pv_id, keep, rc):
    if bridge:
        bridge.close()
    elif os.path.lexists(path):
        try:
            os.unlink(path)
        except OSError:
            pass
    closed = 'kept (same URL on the next run with this --name)' if keep else 'closed'
    if not keep and pv_id:
        try:
            call({'action': 'close', 'id': pv_id})
        except Refuse as exc:
            closed = 'close failed (%s); it lapses with its lease' % exc
    how = '' if rc is None else ' (exit %d)' % rc if rc >= 0 else ' (signal %d)' % -rc
    say('stopped%s · preview %s · socket removed' % (how, closed))


def watch(bridge, child, url, stop):
    start, hinted, last = time.time(), False, None
    while not stop.is_set():
        rows = listeners(child.pid)
        t = pick(rows, bridge.want if bridge.strict or any(r[1] == bridge.want for r in rows) else None)
        bridge.set(t)
        if t and t[:2] != (last or (None, None))[:2]:
            say('ready: %s ← %s:%d (pid %d)' % (url, dial_addr(t[0]), t[1], t[2]))
            if t[0] in WILDCARD:
                say('note: it listens on every interface, so the LAN can reach it too; '
                    'bind it to 127.0.0.1 (e.g. --host 127.0.0.1)')
            if bridge.want and t[1] != bridge.want:
                say('note: it listens on %d, not on the PORT=%d it was handed; that works, '
                    'and --port %d pins it' % (t[1], bridge.want, t[1]))
            hinted = True
        elif not t and last:
            say('the dev server stopped listening; the preview answers 503 until it is back')
        last = t
        if not hinted and time.time() - start > HINT_S:
            hinted = True
            say('note: no TCP listener in the command\'s processes yet. If it listens on a fixed port, '
                'pass --port N (or put {port} in the command); on a Unix socket, use --unix')
        stop.wait(WATCH_S)


def watch_unix(path, child, url, stop):
    start, hinted = time.time(), False
    while not stop.is_set():
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            st = None
        if st and stat.S_ISSOCK(st.st_mode) and st.st_uid == os.getuid():
            if st.st_mode & 0o077:
                os.chmod(path, 0o600)   # uvicorn makes it 0666 over the umask
            say('ready: %s ← %s' % (url, path))
            return
        if not hinted and time.time() - start > HINT_S:
            hinted = True
            say('note: %s has not appeared; point the server at $FLEET_PREVIEW_SOCKET or {socket}' % path)
        stop.wait(0.5)


def main():
    if sys.argv[1:2] == ['dev']:
        sys.exit(dev(sys.argv[2:]))
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('action', choices=('register', 'list', 'renew', 'close', 'dev'))
    p.add_argument('value', nargs='?')
    a = p.parse_args()
    if (a.action == 'list') != (a.value is None):
        p.error('register needs a socket basename; renew/close need a preview ID; list takes no argument')
    args = {'action': a.action}
    if a.value:
        args['socket' if a.action == 'register' else 'id'] = a.value
    os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name('fleet-mcp.py')),
                             '--call', 'preview', json.dumps(args)])


if __name__ == '__main__':
    main()
