#!/usr/bin/env python3
"""Shared observer/event wait for renderers (#4356, #4357).

Any supplied fleet socket with a client, OR fleet-client-where's active lease,
means watched. The lease has one reader; never infer a device/lease here.
wait-for broadcasts to all CURRENT waiters, and latches one signal with none.
Register before checking visibility/dirty markers to close the read→wait race.
An unobserved renderer blocks until an event, its caller's maintenance deadline,
or the 65s discovery fallback. Dead servers return once for rediscovery. All wait
clients are bounded and reaped; a lease lookup cannot overrun maintenance.

CLI: [--max-frames N] [--since-frame N] <frame seconds> <socket path>...
     → <elapsed frames> <lease frames left>.
With --since-frame, also return the monotonic frame at wake; pass it back on the
next call so time spent doing maintenance counts toward the next deadline too.
Omitting --max-frames keeps the original 65s wait (#4357's shared interface).
A socket u+x bit alone is not visibility while a resident control transport is
registered: attached() excludes exactly those client/server generations. Human
control clients still count. Resident callers use Observer and reuse Control.
"""
import argparse
import collections
import json
import math
import os
import re
from pathlib import Path
import selectors
import select
import signal
import stat
import subprocess
import sys
import time

FALLBACK = 65
CHANNEL = 'fleet-state-changed'
BIN = Path(__file__).absolute().parent


def monotonic():
    # Python <3.10 on macOS makes time.monotonic() relative to EACH process's
    # start. Deadlines and the shared lease cache need the same kernel clock
    # across helper invocations, on both macOS and Linux.
    return time.clock_gettime(time.CLOCK_MONOTONIC)


CLIENT_FORMAT = '#{client_pid}\t#{client_created}\t#{client_flags}'


def internal_clients(path):
    """Exact server/client generations, shared by CLI and resident observers.

    A human control client remains a watcher. A stale marker cannot hide a new
    client reusing its PID or a server replacing the socket.
    """
    found = set()
    try:
        sock = os.stat(path)
        for marker in Path(path).parent.glob(Path(path).name + '.render-*'):
            try:
                r = json.loads(marker.read_text())
                if [sock.st_dev, sock.st_ino] == r['socket']:
                    found.add((str(r['pid']), str(r['created'])))
            except (OSError, ValueError, KeyError, TypeError):
                pass
    except OSError:
        pass
    return found


def attached(sockets, read_clients=None, deadline=None):
    for path in sockets:
        try:
            mode = os.stat(path).st_mode
            if stat.S_ISSOCK(mode) and mode & stat.S_IXUSR:
                internal = internal_clients(path)
                if not internal:
                    return True
                try:
                    if deadline is not None and monotonic() >= deadline:
                        return True
                    budget = min(1, max(.001, deadline-monotonic())) if deadline is not None else 1
                    rows = (read_clients(path) if read_clients else subprocess.check_output(
                        ['tmux', '-S', path, 'list-clients', '-F', CLIENT_FORMAT],
                        text=True, stderr=subprocess.DEVNULL, timeout=budget))
                    for row in rows.splitlines():
                        pid, created, flags = row.split('\t', 2)
                        if (pid, created) not in internal or 'control-mode' not in flags.split(','):
                            return True
                except (OSError, ValueError, subprocess.SubprocessError):
                    return True  # unknown visibility must not suppress a human
        except OSError:
            pass
    return False


def stop(proc):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    proc.wait()
    if proc.stdout:
        proc.stdout.close()


def wait(sockets, interval, timeout=FALLBACK, since_frame=None,
         events_only=False, since=None, changed=()):
    start = monotonic()
    if since_frame is not None:
        since_frame = since_frame or math.floor(start / interval)
        timeout -= start - since_frame * interval
    timeout = min(FALLBACK, max(0, timeout))
    parent = os.getppid()
    cache = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'global/render-watch.json'
    lease_until = 0
    checked_until = 0
    reason = 'timeout'
    try:
        cached = json.loads(cache.read_text())
        checked_until = float(cached['until'])
        # Discard cache from another boot or a bad clock/partial write.
        if not start <= checked_until <= start + FALLBACK:
            checked_until = 0
        if cached['active']:
            lease_until = checked_until
    except (OSError, ValueError, KeyError, TypeError):
        pass

    def result():
        if events_only:
            return reason
        now = monotonic()
        lease = max(0, math.ceil((lease_until - now) / interval))
        if since_frame is not None:
            frame = math.floor(now / interval)
            return max(0, frame - since_frame), lease, frame
        return max(1, math.ceil((now - start) / interval)), lease

    if timeout <= 0:
        return result()  # work already used the budget; no wait clients needed
    children = []
    query = None
    lease_output = b''
    owner = None
    owner_fd = None
    with selectors.DefaultSelector() as sel:
        try:
            # Parent death is an event too: no 1s lifetime polling on macOS/Linux.
            if hasattr(os, 'pidfd_open'):
                owner_fd = os.pidfd_open(parent)
            elif hasattr(select, 'kqueue'):
                owner = select.kqueue()
                owner.control([select.kevent(parent, filter=select.KQ_FILTER_PROC,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                             fflags=select.KQ_NOTE_EXIT)], 0)
                owner_fd = owner.fileno()
            if owner_fd is not None:
                sel.register(owner_fd, selectors.EVENT_READ, 'owner')
            for path in sockets:
                # The ready line and registration run in one tmux command queue.
                # Check retained input stamps AFTER this acknowledgement: even if
                # another consumer took an earlier latched signal, it cannot hide
                # a change during the list's previous refresh/registration gap.
                command = (['display-message', '-p', 'fleet-wait-ready', ';'] if events_only else [])
                proc = subprocess.Popen(['tmux', '-S', path, *command, 'wait-for', CHANNEL],
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
                children.append(proc)
                sel.register(proc.stdout, selectors.EVENT_READ, proc if events_only else 'event')
            if not events_only and (attached(sockets, deadline=start+timeout) or lease_until > start):
                return result()
            if not events_only and any(Path(p + '.dirty').exists() for p in sockets):
                return result()
            if not events_only and checked_until <= start:
                query = subprocess.Popen(['bash', str(BIN / 'fleet-client-where.sh'), '--json'],
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                         start_new_session=True)
                children.append(query)
                sel.register(query.stdout, selectors.EVENT_READ, 'lease')
            while monotonic() - start < timeout:
                if os.getppid() != parent:
                    break
                deadline = min(3, timeout) if query else timeout
                events = sel.select(max(0, deadline - (monotonic() - start)))
                if any(key.data in ('event', 'owner') for key, _ in events):
                    reason = 'event'
                    break
                if events_only:
                    for key, _ in events:
                        proc = key.data
                        chunk = os.read(proc.stdout.fileno(), 65536)
                        if chunk:
                            try:
                                stamp = Path(since).stat().st_mtime_ns
                                if any(Path(p).exists() and Path(p).stat().st_mtime_ns > stamp for p in changed):
                                    reason = 'changed'
                                    return result()
                            except (OSError, TypeError):
                                pass
                        else:
                            sel.unregister(proc.stdout)
                            if proc.wait() == 0:
                                reason = 'event'
                                return result()
                    continue
                if query and any(key.data == 'lease' for key, _ in events):
                    # Readiness may be PARTIAL output, not process exit. Never
                    # communicate()/wait() here: a stalled lease reader must not
                    # hide state events or consume the maintenance deadline.
                    chunk = os.read(query.stdout.fileno(), 65536)
                    if chunk and len(lease_output) + len(chunk) <= 65536:
                        lease_output += chunk
                        continue
                    sel.unregister(query.stdout)
                    stop(query)
                    try:
                        active = not chunk and json.loads(lease_output).get('state') == 'active'
                    except (ValueError, AttributeError):
                        active = False
                    checked_until = monotonic() + FALLBACK
                    lease_until = checked_until if active else 0
                    try:
                        cache.parent.mkdir(parents=True, exist_ok=True)
                        tmp = cache.with_suffix('.%s.tmp' % os.getpid())
                        tmp.write_text(json.dumps({'until': checked_until, 'active': active}))
                        os.replace(tmp, cache)
                    except OSError:
                        pass  # a read-only cache must not prevent event wakeup
                    query = None
                    if active:
                        break
                if query and monotonic() - start >= 3:
                    sel.unregister(query.stdout)
                    stop(query)
                    query = None
            return result()
        finally:
            for child in children:
                stop(child)
            if owner:
                owner.close()
            elif owner_fd is not None:
                os.close(owner_fd)


class Control:
    """One bounded tmux control transport, owned by the existing renderer.

    Never queue wait-for here: it blocks subsequent maintenance commands. Native
    control notifications/subscriptions carry state changes; the shared wait CLI
    continues to use the broadcast channel for its short-lived consumers.
    """
    def __init__(self, label, env=None):
        args = ['tmux', '-L', label, '-C']
        initial = 1
        # Existing servers need the navigation guard before this first attach.
        # Read the installed hook verbatim: sleeping policy still has ONE owner.
        # A standalone fixture without that conf also has no fleet wake hook.
        try:
            for line in (BIN.parent / 'conf/tmux-attention.conf').read_text().splitlines():
                prefix = 'set-hook -g client-attached[72] '
                if line.startswith(prefix):
                    body = line[len(prefix):].strip()
                    if body.startswith('{') and body.endswith('}'):
                        body = body[1:-1].strip()
                    args += ['set-hook', '-g', 'client-attached[72]', body, ';']
                    initial += 1
                    break
        except OSError:
            pass
        # Also upgrade existing servers' broadcast hooks, as the shell loop did.
        for hook in ('client-attached[80]', 'client-detached[80]'):
            args += ['set-hook', '-g', hook, 'wait-for -S ' + CHANNEL, ';']
            initial += 1
        args += ['attach-session', '-E', '-f', 'no-output,ignore-size', '-t', '=' + label]
        self.proc = subprocess.Popen(args, env=dict(os.environ if env is None else env, TERM='fleet-render-internal'),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buffer = b''
        self.block = None
        self.block_id = None
        self.replies = collections.deque()
        self.changed = True
        self.marker = None
        self.path = None
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        try:
            for _ in range(initial):
                self.reply()  # configuration and attach command blocks
            self.path = self.command('display-message', '-p', '#{socket_path}').strip()
            row = self.command('display-message', '-p', CLIENT_FORMAT).strip().split('\t')
            sock = os.stat(self.path)
            self.marker = Path(self.path + '.render-' + str(self.proc.pid))
            self.marker.write_text(json.dumps(dict(pid=row[0], created=row[1],
                                                  socket=[sock.st_dev, sock.st_ino])))
            self.command('refresh-client', '-B', 'fleet-state:@*:#{@worker_lifecycle}|#{@claude_state}|#{@claude_needs}')
        except BaseException:
            self.close()
            raise

    @staticmethod
    def quote(value):
        # tmux's command parser is shell-like; quote every argument, including
        # formats, so window names/captured text cannot become commands.
        return "'" + str(value).replace("'", "'\\''") + "'"

    def pump(self, timeout=0):
        if not self.selector.select(max(0, timeout)):
            return
        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            raise OSError('tmux control closed')
        self.buffer += chunk
        lines = self.buffer.split(b'\n')
        self.buffer = lines.pop()
        for raw in lines:
            line = raw.decode('utf-8', 'replace')
            if self.block is None and re.fullmatch(r'%begin [0-9]+ [0-9]+ [01]', line):
                self.block = []
                self.block_id = line[7:]
            elif self.block is not None and line in ('%end ' + self.block_id, '%error ' + self.block_id):
                self.replies.append((line.startswith('%end '), '\n'.join(self.block)))
                self.block = None
            elif self.block is not None:
                self.block.append(line)
            elif line.startswith('%exit'):
                raise OSError('tmux control exited')
            else:
                self.changed = True

    def reply(self, timeout=2):
        deadline = monotonic() + timeout
        while not self.replies:
            remaining = deadline - monotonic()
            if remaining <= 0:
                raise TimeoutError('tmux control command timed out')
            self.pump(remaining)
        ok, out = self.replies.popleft()
        if not ok:
            raise ValueError(out)
        return out

    def commands(self, commands):
        if not commands:
            return ''
        line = ' ; '.join(' '.join(self.quote(arg) for arg in cmd) for cmd in commands)
        pending = memoryview((line + '\n').encode())
        fd = self.proc.stdin.fileno()
        os.set_blocking(fd, False)
        deadline = monotonic() + 2
        while pending:
            if not select.select([], [fd], [], max(0, deadline - monotonic()))[1]:
                raise TimeoutError('tmux control write timed out')
            try:
                pending = pending[os.write(fd, pending):]
            except BlockingIOError:
                continue
        # tmux emits a response block for EACH command in a command list.
        output = []
        error = None
        for _ in commands:
            try:
                output.append(self.reply())
            except ValueError as exc:
                error = exc
                break  # tmux aborts the remainder of an erroneous command list
        if error:
            raise error
        return '\n'.join(output)

    def command(self, *args):
        return self.commands([args])

    def close(self):
        if self.marker:
            self.marker.unlink(missing_ok=True)
        if self.proc.stdin:
            try:
                self.proc.stdin.close()  # EOF detaches; it never kills the server
            except OSError:
                pass
        try:
            self.proc.wait(timeout=.5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()
        self.selector.close()


class Observer:
    """Resident form of the SAME lease/client predicate as wait().

    No extra daemon or wait client. A 250ms filesystem/visibility check preserves
    the dirty-marker path and lease-cache invalidation (a broadcast without a
    tmux state change). State subscriptions also wake the selector. All waits
    stay bounded by the caller's absolute maintenance deadline.
    """
    def __init__(self):
        self.cache = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'global/render-watch.json'
        self.checked_until = self.lease_until = 0
        self.cache_present = False
        self.query = None
        self.output = b''
        self.query_deadline = 0

    def refresh(self):
        now = monotonic()
        try:
            cached = json.loads(self.cache.read_text())
            until = float(cached['until'])
            if now <= until <= now + FALLBACK:
                self.cache_present = True
                self.checked_until = until
                self.lease_until = until if cached['active'] else 0
            else:
                raise ValueError('invalid lease cache clock')
        except (OSError, ValueError, KeyError, TypeError):
            if self.cache_present:
                self.checked_until = self.lease_until = 0
            self.cache_present = False
        if self.query:
            chunk = b''
            try:
                chunk = os.read(self.query.stdout.fileno(), 65536)
            except BlockingIOError:
                chunk = None
            if chunk and len(self.output) + len(chunk) <= 65536 and now < self.query_deadline:
                self.output += chunk
            elif chunk == b'' or now >= self.query_deadline or chunk:
                active = False
                if chunk == b'':
                    try:
                        active = json.loads(self.output).get('state') == 'active'
                    except (ValueError, AttributeError):
                        pass
                stop(self.query)
                self.query = None
                self.checked_until = now + FALLBACK
                self.lease_until = self.checked_until if active else 0
                try:
                    self.cache.parent.mkdir(parents=True, exist_ok=True)
                    tmp = self.cache.with_suffix('.%s.tmp' % os.getpid())
                    tmp.write_text(json.dumps(dict(until=self.checked_until, active=active)))
                    os.replace(tmp, self.cache)
                    self.cache_present = True
                except OSError:
                    pass
        if not self.query and now >= self.checked_until:
            self.query = subprocess.Popen(['bash', str(BIN / 'fleet-client-where.sh'), '--json'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
            os.set_blocking(self.query.stdout.fileno(), False)
            self.output = b''
            self.query_deadline = now + 3

    def watched(self, controls):
        self.refresh()
        by_path = {c.path: c for c in controls}
        return self.lease_until > monotonic() or attached(by_path,
            lambda path: by_path[path].command('list-clients', '-F', CLIENT_FORMAT))

    def wait(self, controls, deadline):
        with selectors.DefaultSelector() as sel:
            for c in controls:
                sel.register(c.proc.stdout, selectors.EVENT_READ, c)
            if self.query:
                sel.register(self.query.stdout, selectors.EVENT_READ, None)
            for key, _ in sel.select(max(0, min(.25, deadline - monotonic()))):
                if key.data:
                    key.data.pump()

    def close(self):
        if self.query:
            stop(self.query)
            self.query = None


def view_active(request, sockets):
    """A real list read within 30s AND the shared client/lease predicate.

    A permanently attached terminal (or online lease) alone never polls lists.
    Use the same bounded lease reader/cache as the spinner, only when needed.
    """
    try:
        age = time.time() - Path(request).stat().st_mtime
        if not 0 <= age <= 30:
            return False
    except OSError:
        return False
    if attached(sockets):
        return True
    observer = Observer()
    try:
        observer.refresh()
        while observer.query:
            select.select([observer.query.stdout], [], [], max(0, observer.query_deadline - monotonic()))
            observer.refresh()
        return observer.lease_until > monotonic()
    finally:
        observer.close()


if __name__ == '__main__':
    # SIGTERM follows the same cleanup path as timeout/exception.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-frames', type=int)
    parser.add_argument('--since-frame', type=int)
    parser.add_argument('--events-only', action='store_true', help='wait for the shared broadcast, even with viewers')
    parser.add_argument('--since', help='refresh-start stamp; compare inputs after waiter registration')
    parser.add_argument('--changed', action='append', default=[])
    parser.add_argument('--view-active', help='exit 0 only with a recent list request and a shared watcher')
    parser.add_argument('interval', type=float)
    parser.add_argument('sockets', nargs='*')
    args = parser.parse_args()
    if not math.isfinite(args.interval) or args.interval <= 0 or (
            args.max_frames is not None and args.max_frames < 1) or (
            args.since_frame is not None and args.since_frame < 0):
        parser.error('interval/max-frames must be positive; since-frame nonnegative')
    if args.view_active:
        sys.exit(0 if view_active(args.view_active, args.sockets) else 1)
    answer = wait(args.sockets, args.interval,
                FALLBACK if args.max_frames is None else args.max_frames * args.interval,
                args.since_frame, args.events_only, args.since, args.changed)
    print(answer) if args.events_only else print(*answer)
