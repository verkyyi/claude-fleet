#!/usr/bin/env python3
"""Bounded attachment input transactions for fleet-thin (#4379).

The PTY owner only frames bytes. One short-lived supervisor owns one worker
process group, a private temporary directory and a parent-liveness pipe. Capture,
stat, hashing and SSH happen there. One bounded probe thread lives only inside
the worker; there is no daemon, retry or terminal write.
64 KiB framing / 16 files / 100 MiB total / 120 s per transaction. Input is
paused, never queued; Ctrl+C cancels only the attachment. Results
are accepted only on the original connection/selection generation.
"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

BIN = Path(__file__).resolve().parent
START, END = b"\x1b[200~", b"\x1b[201~"
CAP = 64 << 10
RESULT_CAP = 2 * CAP
MAX_FILES = 16
TIMEOUT = 120


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), BIN / name)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def packed(data):
    return base64.b64encode(data).decode('ascii')


def unpacked(data):
    return base64.b64decode(data, validate=True)


def paths(body):
    """Syntax only: no filesystem access on the PTY pump."""
    try:
        text = body.decode('utf-8')
        if not text.strip() or '\n' in text.strip():
            return None
        toks = shlex.split(text)
        return (text, toks) if toks and all(t.startswith('/') for t in toks) else None
    except (UnicodeDecodeError, ValueError):
        return None


class Input:
    def __init__(self, snapshot, say):
        self.snapshot, self.say = snapshot, say
        self.buf = b''
        self.pasting = False
        self.streaming = False
        self.since = 0.0
        self.job = None
        self.result = b''
        self.target = None
        self.started = 0.0
        self.cancelled = False
        self.notified = False
        self.request = b''
        self.discard_paste = False
        self.discard_mark = b''  # at most a framing marker, never user input

    @property
    def busy(self):
        return bool(self.job or self.buf)

    def cancel(self, why):
        had = self.busy
        self.buf = b''
        self.pasting = self.streaming = False
        if self.job:
            self.cancelled = True
            self.job.stdin.close()  # EOF: supervisor kills/reaps the entire group
        if had and why:
            self.say('fleet · ' + why + '；输入恢复后请重新输入')

    def start(self, kind, data):
        self.target = self.snapshot()
        req = dict(self.target or {}, kind=kind, data=packed(data), operation=time.monotonic_ns())
        self.result = b''
        self.cancelled = self.notified = False
        self.started = time.monotonic()
        try:
            self.job = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--supervise'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            self.buf = b''
            self.say('fleet · 附件处理未能启动；等待的输入已丢弃，请重新输入')
            return
        self.request = json.dumps(req).encode() + b'\n'
        os.set_blocking(self.job.stdin.fileno(), False)
        os.set_blocking(self.job.stdout.fileno(), False)

    def feed(self, data):
        if self.job:
            self.discard(data, True)
            if b'\x03' in data and not self.cancelled:
                self.cancel('附件已取消')
            # No printable input, Enter, repeated drop or control key is kept.
            # In particular the cancellation must never interrupt the remote job.
            return b''
        data = self.discard(data, False)
        self.buf += data
        out = bytearray()
        while self.buf and not self.job:
            if self.pasting or self.streaming:
                end = self.buf.find(END)
                if end < 0:
                    if len(self.buf) > CAP:
                        # A large ordinary paste is streamed without ever attempting
                        # to reinterpret its tail as a new attachment.
                        out.extend(self.buf[:-len(END)])
                        self.buf = self.buf[-len(END):]
                        self.pasting, self.streaming = False, True
                    break
                n = end + len(END)
                whole, self.buf = self.buf[:n], self.buf[n:]
                was_streaming = self.streaming
                self.pasting = self.streaming = False
                if not was_streaming and paths(whole[len(START):-len(END)]):
                    if len(whole) > CAP:
                        self.buf = b''
                        self.say('fleet · 附件路径超过 64 KiB；等待的输入已丢弃')
                    else:
                        self.start('drop', whole)
                else:
                    out.extend(whole)
                continue
            if self.buf.startswith(START):
                self.pasting = True
                self.since = time.monotonic()
                continue
            if self.buf.startswith(b'\x16'):
                self.buf = self.buf[1:]
                self.start('clip', b'\x16')
                continue
            # Hold a split bracket opener, but never delay a lone Escape.
            if len(self.buf) > 1 and START.startswith(self.buf):
                self.since = time.monotonic()
                break
            stops = [i for i in (self.buf.find(START), self.buf.find(b'\x16')) if i >= 0]
            n = min(stops) if stops else len(self.buf)
            if not stops:
                for k in range(min(len(START) - 1, len(self.buf)), 1, -1):
                    if START.startswith(self.buf[-k:]):
                        n -= k
                        self.since = time.monotonic()
                        break
            out.extend(self.buf[:n])
            self.buf = self.buf[n:]
        if self.job:
            rest, self.buf = self.buf, b''
            self.discard(rest, True)
            if b'\x03' in rest:
                self.cancel('附件已取消')
        return bytes(out)

    def discard(self, data, paused):
        # A repeated paste can straddle completion/cancellation. Keep only its
        # delimiter state so its tail can never become input after we resume.
        for i, byte in enumerate(data):
            if not paused and not self.discard_paste and not self.discard_mark:
                return data[i:]
            marker = END if self.discard_paste else START
            self.discard_mark += bytes((byte,))
            if self.discard_mark == marker:
                self.discard_paste = not self.discard_paste
                self.discard_mark = b''
            else:
                while self.discard_mark and not marker.startswith(self.discard_mark):
                    self.discard_mark = self.discard_mark[1:]
        return b''

    def poll(self):
        if not self.job:
            if self.buf and time.monotonic() - self.since > (2 if self.pasting else .05):
                out, self.buf = self.buf, b''
                self.pasting = self.streaming = False
                return out
            return b''
        if not self.cancelled and self.target != self.snapshot():
            self.cancel('会话目标已改变，附件未插入')
        if self.request and not self.cancelled:
            try:
                n = os.write(self.job.stdin.fileno(), self.request)
                self.request = self.request[n:]
            except BlockingIOError:
                pass
            except BrokenPipeError:
                self.request = b''
        try:
            data = self.job.stdout.read(RESULT_CAP + 1 - len(self.result))
            if data:
                self.result += data
        except BlockingIOError:
            pass
        if len(self.result) > RESULT_CAP:
            self.cancel('附件返回超过限额')
        if self.job.poll() is None:
            return b''
        # The final write can race the nonblocking read above. Once the process
        # exited, drain the remaining bounded bytes before decoding its result.
        tail = self.job.stdout.read(RESULT_CAP + 1 - len(self.result))
        if tail:
            self.result += tail
        self.job.stdin.close()
        self.job.stdout.close()
        self.job = None
        if self.cancelled:
            self.result = b''
            self.say('fleet · 输入已恢复')
            return b''
        try:
            result = json.loads(self.result)
            if not result.get('ok'):
                why = result.get('error') or '附件失败或超时，未插入'
                self.buf = b''
                self.say('fleet · ' + why + '；输入已恢复')
                return b''
            out = unpacked(result['data'])
        except (ValueError, KeyError, TypeError):
            self.buf = b''
            self.say('fleet · 附件失败或超时，未插入；输入已恢复')
            return b''
        self.result = b''
        return out

    def close(self):
        self.cancel('' if not self.busy else '连接结束，附件已取消')
        if self.job:
            # Only on exit, never on the live PTY pump. EOF is also the parent-
            # death cleanup road, including SIGKILL (no signal handler needed).
            try:
                self.job.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass  # supervisor's own deadline still owns its process group
            self.job.stdout.close()
            self.job = None


def kill_group(proc, sig):
    # Darwin can return EPERM for a zombie session leader's vanished group.
    # Reap it first, but still kill the group: a completed worker may have left
    # its (no-image) probe running. Never swallow denial for a live process.
    proc.poll()
    try: os.killpg(proc.pid, sig)
    except ProcessLookupError: pass
    except PermissionError:
        if proc.poll() is None: raise


def supervise():
    deadline = time.monotonic() + TIMEOUT
    # Even a parent that stays alive but stops writing the initial request may
    # not leave a permanent waiter. There are no children or temp files yet.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, TIMEOUT)
    req = json.loads(sys.stdin.buffer.readline(RESULT_CAP))
    signal.setitimer(signal.ITIMER_REAL, 0)
    with tempfile.TemporaryDirectory(prefix='fleet-upload.') as tmp:
        req['tmp'] = tmp
        status = None
        if req.get('cur') and req.get('generation') and req.get('base'):
            rbin = req.get('rbin') or '.claude/fleet/bin'
            status = subprocess.Popen(command(req, ['python3', rbin + '/fleet-client-upload.py', 'status']),
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, start_new_session=True)
            req['status_in'], req['status_out'] = status.stdin.fileno(), status.stdout.fileno()
        worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--work'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, start_new_session=True,
                                  pass_fds=(req['status_in'], req['status_out']) if status else ())
        if status: status.stdout.close()
        worker.stdin.write(json.dumps(req).encode() + b'\n')
        worker.stdin.close()
        out = bytearray()
        cancelled = False
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([0, worker.stdout], [], [], .05)
                # The parent closed, died, or cancelled. Prefer it to a completion.
                if 0 in ready:
                    cancelled = True
                    break
                if worker.stdout in ready:
                    b = os.read(worker.stdout.fileno(), 65536)
                    if not b:
                        break
                    out.extend(b)
                    if len(out) > RESULT_CAP:
                        out.clear()
                        break
                    if b'\n' in out:
                        break  # one framed result; do not wait for Python/thread teardown
            else:
                out.clear()
        finally:
            kill_group(worker, signal.SIGTERM)
            time.sleep(.05)
            kill_group(worker, signal.SIGKILL)
            worker.wait()
            worker.stdout.close()
            if status:
                # Keep the control connection alive long enough to restore its
                # view after killing transfer/capture, then reap it too. The
                # parent's pump keeps running throughout this bounded cleanup.
                try:
                    result = json.loads(out) if out else {}
                except ValueError:
                    result = {}
                try:
                    os.set_blocking(status.stdin.fileno(), False)
                    passthrough = result.get('ok') and result.get('data') == req.get('data')
                    if cancelled or not result.get('ok') or passthrough:
                        phase = 'cancelled' if cancelled else 'clear' if passthrough else 'failed'
                        os.write(status.stdin.fileno(), json.dumps({'phase': phase}).encode() + b'\n')
                    status.stdin.close()
                    status.wait(timeout=.4)
                except (OSError, subprocess.TimeoutExpired):
                    pass
                finally:
                    if status.poll() is None:
                        # Let the receiver unwind any target/peer subprocess
                        # groups it owns before the final hard deadline.
                        kill_group(status, signal.SIGTERM)
                        try: status.wait(timeout=.2)
                        except subprocess.TimeoutExpired: pass
                    kill_group(status, signal.SIGKILL)
                    status.wait()
                    status.stdin.close()
        if not cancelled:
            try: os.write(1, out or b'{"ok":false}')
            except BrokenPipeError: pass


def command(req, words):
    remote = ' '.join(shlex.quote(str(w)) for w in words)
    base = req['base']
    if base.get('local'):
        return ['sh', '-c', 'cd && exec sh -c "$1"', 'fleet-thin-upload', remote]
    a, h = list(base['argv']), int(base['host'])
    return a[:h] + ['-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                    '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=2'] + [a[h], remote]


def bounded_run(cmd, header, src=None, progress=None):
    """Bound both directions; connection tokens travel only through pipes.
    Descendants inherit the worker group owned by the supervisor."""
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    source = open(src, 'rb') if src else None
    out, err = bytearray(), bytearray()
    streams = {p.stdout: out, p.stderr: err}
    pending, sending = header, True
    os.set_blocking(p.stdin.fileno(), False)
    try:
        while streams or sending:
            ready, writable, _ = select.select(list(streams), [p.stdin] if sending else [], [], .1)
            for stream in ready:
                data = os.read(stream.fileno(), 8192)
                if not data:
                    del streams[stream]
                else:
                    streams[stream].extend(data)
                    if len(out) + len(err) > CAP:
                        raise ValueError('附件服务返回超过限额')
                    if stream is p.stdout and progress:
                        while b'\n' in out:
                            line, _, rest = out.partition(b'\n')
                            event = json.loads(line)
                            if 'received' not in event:
                                break  # final commit reply, kept for the caller
                            out[:] = rest
                            progress(event['received'])
            if writable:
                if not pending:
                    pending = source.read(CAP) if source else b''
                if not pending:
                    p.stdin.close()
                    sending = False
                else:
                    try:
                        n = os.write(p.stdin.fileno(), pending)
                        pending = pending[n:]
                    except BlockingIOError:
                        pass
        if p.wait():
            raise ValueError('附件服务未确认提交')
        return bytes(out)
    finally:
        if p.poll() is None:
            p.kill()
        p.wait()
        p.stdin.close(); p.stdout.close(); p.stderr.close()
        if source: source.close()


def remote_json(req, action, header, src=None, progress=None):
    rbin = req.get('rbin') or '.claude/fleet/bin'
    return json.loads(bounded_run(command(req, ['python3', rbin + '/fleet-client-upload.py', action]),
                                  json.dumps(header).encode() + b'\n', src, progress))


class Progress:
    """One transaction-owned control connection, never a per-chunk SSH.

    The probe thread opens it while clipboard capture proceeds. After its ready
    reply only the worker writes; bounded nonblocking snapshots cannot stall a
    transfer. EOF restores the owning view even after the supervisor kills us.
    """
    def __init__(self, req, target):
        self.req, self.target = req, target
        self.writer = None
        self.identity = None
        self.last = 0.0
        self.state = {'phase': 'preparing', 'name': 'clipboard' if req['kind'] == 'clip' else '',
                      'index': 0, 'count': 0, 'done': 0, 'total': 0}

    def connect(self):
        try:
            self.writer = os.fdopen(self.req['status_in'], 'wb', buffering=0)
            reader = os.fdopen(self.req['status_out'], 'rb')
            self.writer.write(json.dumps(dict(self.target, operation=self.req['operation'])).encode() + b'\n')
            answer = reader.readline(16384)
            reader.close()
            self.identity = json.loads(answer)['identity']
            os.set_blocking(self.writer.fileno(), False)
        except Exception:
            pass

    def emit(self, phase, force=False, **values):
        self.state.update(values, phase=phase)
        now = time.monotonic()
        if not self.identity or (not force and now - self.last < .2):
            return
        self.last = now
        try:
            # <= PIPE_BUF: a congested status stream drops this snapshot whole.
            os.write(self.writer.fileno(), json.dumps(self.state).encode() + b'\n')
        except BlockingIOError:
            pass
        except (OSError, ValueError):
            raise ValueError('上传进度连接中断，附件未插入')

    def finish(self, phase):
        if self.identity:
            try: self.emit(phase, force=True)
            except ValueError: pass


def work(req):
    up = load('fleet-client-upload.py')
    original = unpacked(req['data'])
    # Bind before capture/stat/hash can block. Probe failures still permit a
    # no-image Ctrl+V or ordinary text to pass through unchanged.
    target = probe_thread = progress = None
    if req.get('cur') and req.get('generation') and req.get('base'):
        target = {k: req[k] for k in ('view', 'token', 'cur', 'generation')}
        progress = Progress(req, target)
        # A no-image Ctrl+V must not wait for the network. The worker exits as
        # soon as capture says none; its supervisor reaps any unfinished probe.
        probe_thread = threading.Thread(target=progress.connect, daemon=True)
        probe_thread.start()
    import resource
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (up.FILE_MAX + CAP, hard))
    if req['kind'] == 'clip':
        resource.setrlimit(resource.RLIMIT_FSIZE, (up.IMAGE_MAX, hard))
        src = os.path.join(req['tmp'], 'clip.png')
        if not up.clip_png(src):
            if progress: progress.finish('clear')
            return original
        resource.setrlimit(resource.RLIMIT_FSIZE, (up.FILE_MAX + CAP, hard))
        toks, tail = [src], ''
    else:
        text, toks = paths(original[len(START):-len(END)])
        inbox = up.inbox_root() + os.sep
        if not all(os.path.isfile(t) and not t.startswith(inbox) for t in toks):
            if progress: progress.finish('clear')
            return original
        tail = text[len(text.rstrip()):]
    if len(toks) > MAX_FILES:
        raise ValueError('附件超过 16 个')
    if probe_thread:
        probe_thread.join()
    identity = progress.identity if progress else None
    if identity is None:
        raise ValueError('无法确认附件目标，请重连后再试')
    target['identity'] = identity
    got, total, files = [], 0, []
    # Snapshot each file while hashing: a changed source cannot silently become
    # another file between inspection and transmission; never open FIFOs/devices.
    import hashlib
    for i, src in enumerate(toks):
        name = up.safe('clip.png' if req['kind'] == 'clip' else src)
        display = os.path.basename(src) if req['kind'] != 'clip' else 'clip.png'
        display = ''.join(c for c in display if c.isprintable())[:160]
        progress.emit('preparing', force=True, name=display, index=i + 1, count=len(toks))
        copied = os.path.join(req['tmp'], 'file-%d' % i)
        digest, size = hashlib.sha256(), 0
        fd = os.open(src, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as f, open(copied, 'wb') as dest:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ValueError('附件不是普通文件')
            for b in iter(lambda: f.read(1 << 20), b''):
                size += len(b); total += len(b)
                if size > up.bound(name) or total > up.FILE_MAX:
                    raise ValueError('附件超过大小限额')
                dest.write(b); digest.update(b)
        header = dict(target, name=name, size=size, sha256=digest.hexdigest())
        files.append((header, copied, display))
    done = 0
    for i, (header, copied, display) in enumerate(files):
        size = header['size']
        progress.emit('uploading', force=True, name=display, index=i + 1, count=len(files), done=done, total=total)
        received = 0
        def ack(count):
            nonlocal received
            if type(count) is not int or not received <= count <= size:
                raise ValueError('附件进度无效')
            received = count
            progress.emit('confirming' if count == size else 'uploading',
                          force=count == size, done=done + count)
        reply = remote_json(req, 'recv-checked', dict(header, progress=True), copied, ack)
        path = reply.get('path', '')
        if reply.get('sha256') != header['sha256'] or reply.get('size') != size or not path.startswith('/'):
            raise ValueError('附件完整性未确认')
        # Preserve ordinary inbox paths, quoting only where a login's HOME needs it.
        got.append(shlex.quote(path))
        done += size
    if remote_json(req, 'target', target) != identity:
        raise ValueError('附件目标已经改变')
    progress.finish('uploaded')
    return START + (' '.join(got) + tail).encode() + END


if __name__ == '__main__':
    if sys.argv[1:] == ['--supervise']:
        supervise()
    elif sys.argv[1:] == ['--work']:
        try:
            data = work(json.loads(sys.stdin.buffer.readline(RESULT_CAP)))
            result = {'ok': True, 'data': packed(data)}
        except Exception as error:
            # Only our fixed ValueError messages are safe to display. OS and
            # decoder exceptions can contain a filename or received input.
            result = {'ok': False}
            if type(error) is ValueError:
                result['error'] = str(error)[:120]
        sys.stdout.write(json.dumps(result) + '\n')
        sys.stdout.flush()
