#!/usr/bin/env python3
"""Real spinner, private HOME/socket, count external commands (not ps samples).

The 60s budget is the shared renderer wait with no maintenance deadline due.
The real spinner keeps ALL maintenance enabled; its deadlines/cost are measured
separately by --maintenance. A default spinner has heartbeat/self-heal due within
60s, so its whole-process count is deliberately not labelled pure render idle.
"""
import os
import pathlib
import pty
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

BIN = pathlib.Path(__file__).resolve().parent
TMUX = shutil.which('tmux')


def main():
    if not TMUX:
        print('SKIP tmux absent')
        return
    with tempfile.TemporaryDirectory(prefix='spinwait.', dir='/tmp') as tmp:
        root = pathlib.Path(tmp)
        for d in ('bin', 'logs', 'shim', 'conf/fleets/test', 'tmp', 'home'):
            (root / d).mkdir(parents=True)
        (root / 'conf/fleets/test/conf').touch()
        for name in ('tmux-spinner.sh', 'fleet-render-watch.py', 'fleet-degenerate.awk'):
            if (BIN / name).exists():
                shutil.copy(BIN / name, root / 'bin' / name)
        # Shared-reader seam: never ask a live hub/lease in a drill.
        (root / 'bin/fleet-client-where.sh').write_text(
            '#!/bin/sh\ncat "' + tmp + '/lease"\n')
        (root / 'lease').write_text('{"state":"none"}\n')
        calls = root / 'calls'
        calls.touch()
        for name in ('tmux', 'sleep', 'awk', 'date', 'mv', 'rm', 'python3',
                     'bash', 'cat', 'tail', 'mkdir', 'dirname', 'id', 'cksum'):
            script = root / 'shim' / name
            script.write_text('#!/bin/sh\nprintf "%s\\t%s\\t%s\\n" "$$" ' + shlex.quote(name) + ' "$*"'
                              + ' >> ' + shlex.quote(str(calls)) + '\nexec '
                              + shlex.quote(shutil.which(name)) + ' "$@"\n')
            script.chmod(0o755)
        env = dict(os.environ, HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'),
                   TMUX_TMPDIR=tmp, TMPDIR=str(root / 'tmp'),
                   PATH=str(root / 'shim') + ':' + os.environ['PATH'],
                   CCQUOTA_FLEET='0')
        env.pop('TMUX', None)
        env.pop('TMUX_PANE', None)

        def tm(*args):
            return subprocess.check_output([TMUX, '-L', 'test', *args], env=env,
                                           stderr=subprocess.DEVNULL, text=True).strip()

        def spin():
            return tm('display-message', '-p', '-t', 'test:0', '#{@spin}')

        def until(fn, limit):
            start = time.monotonic()
            while time.monotonic() - start < limit:
                if fn():
                    return time.monotonic() - start
                time.sleep(.02)
            raise AssertionError('condition timed out after %ss' % limit)

        daemon = client = waiter = None
        master = None
        try:
            tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', 'sleep 180')
            socket = tm('display-message', '-p', '#{socket_path}')
            if '--maintenance' in sys.argv:
                maintenance(root, env, tm, until, calls)
                return
            # No due work is a contract of this CALL, not disabled maintenance
            # in the daemon. Exercise the shared wait itself for a full 60s.
            waiter = subprocess.Popen([sys.executable, str(root / 'bin/fleet-render-watch.py'),
                                       '.12', socket], env=env, stdout=subprocess.PIPE, text=True)
            until(lambda: 'wait-for' in calls.read_text(), 3)
            time.sleep(.3)
            start = len(calls.read_text().splitlines())
            seconds = 4 if '--quick' in sys.argv else 60
            t0 = time.monotonic()
            while time.monotonic() - t0 < seconds:
                time.sleep(.2)
                count = len(calls.read_text().splitlines()) - start
                assert waiter.poll() is None, 'no-deadline wait ended before 60s'
                assert count <= 5, 'idle renderer spawned %s commands in %.1fs' % (count, time.monotonic()-t0)
            print('PASS renderer wait, no deadline due: %s external commands / %ss' % (count, seconds), flush=True)
            tm('wait-for', '-S', 'fleet-state-changed')
            waiter.communicate(timeout=2)
            waiter = None
            wait_cleanup(root, env, socket, until, calls)
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'working')
            with (root / 'daemon.log').open('w') as log:
                daemon = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')],
                                          env=env, stdout=log, stderr=log, start_new_session=True)
            until(lambda: bool(spin()), 5)
            time.sleep(1)
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'done',
               ';', 'wait-for', '-S', 'fleet-state-changed')
            elapsed = until(lambda: spin() == '✓', 2)
            print('PASS state event → done: %.3fs' % elapsed, flush=True)
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'working',
               ';', 'wait-for', '-S', 'fleet-state-changed')
            until(lambda: spin() != '✓', 2)
            frozen = spin()
            time.sleep(.35)
            assert spin() == frozen, 'unwatched animation moved'
            master, slave = pty.openpty()
            client = subprocess.Popen([TMUX, '-L', 'test', 'attach', '-t', 'test'],
                                      env=dict(env, TERM='xterm'), stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            elapsed = until(lambda: spin() != frozen, 1)
            print('PASS attach → animation: %.3fs' % elapsed, flush=True)
            client.terminate()
            client.wait(timeout=3)
            client = None
            time.sleep(.6)
            frozen = spin()
            time.sleep(.35)
            assert spin() == frozen, 'detach did not stop animation'
            # Online lease alone is a watcher. Force a fresh shared-reader
            # answer, then broadcast as a lease consumer (#4357) may do.
            (root / 'lease').write_text('{"state":"active"}\n')
            cache = root / 'conf/global/render-watch.json'
            cache.unlink(missing_ok=True)
            tm('wait-for', '-S', 'fleet-state-changed')
            until(lambda: spin() != frozen, 2)
            print('PASS lease only → animation; detach → frozen', flush=True)
            assert daemon.poll() is None
        finally:
            if waiter:
                waiter.terminate()
                waiter.communicate(timeout=3)
            if client:
                client.terminate()
                client.wait(timeout=3)
            if master is not None:
                os.close(master)
            if daemon:
                os.killpg(daemon.pid, signal.SIGTERM)
                daemon.wait(timeout=3)
            subprocess.run([TMUX, '-L', 'test', 'kill-server'], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_cleanup(root, env, socket, until, calls):
    """A slow lease query obeys the deadline too; timeout/TERM/dead owner reap."""
    reader = root / 'bin/fleet-client-where.sh'
    original = reader.read_text()
    reader.write_text('#!/bin/sh\nprintf \'{"state":\'\nexec sleep 120\n')
    cache = root / 'conf/global/render-watch.json'
    cache.unlink(missing_ok=True)
    cmd = [sys.executable, str(root / 'bin/fleet-render-watch.py'),
           '--max-frames', '4', '.05', socket]

    def gone(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    try:
        for how in ('timeout', 'term', 'owner'):
            start = len(calls.read_text().splitlines())
            t0 = time.monotonic()
            # owner leg loses the shell it is waiting for; the waiter's children
            # have their own process groups, so killing ours cannot hide a leak.
            args = (['sh', '-c', shlex.join(cmd[:-4] + ['--max-frames', '1200', '.05', socket]) + ' & wait']
                    if how == 'owner' else cmd)
            proc = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, text=True)
            try:
                until(lambda: '\tsleep\t120' in '\n'.join(calls.read_text().splitlines()[start:]), 2)
                if how != 'timeout':
                    proc.terminate()
                out, _ = proc.communicate(timeout=2)
                elapsed = time.monotonic() - t0
                if how == 'timeout':
                    frames = int(out.split()[0])
                    assert frames >= 4 and elapsed < 2, (out, elapsed)
                children = {int(line.split('\t')[0]) for line in calls.read_text().splitlines()[start:]}
                until(lambda: all(gone(pid) for pid in children), 2)
                print('PASS wait %s: %.3fs; wait/lease children reaped' % (how, elapsed), flush=True)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate(timeout=3)
    finally:
        reader.write_text(original)


def maintenance(root, env, tm, until, calls):
    """Real loops/scans/strikes; only transcript and outward actions are seams."""
    for name, body in {
        'fleet-pending-tool.sh': 'printf "probe\\n" >> "' + str(root / 'probes') + '"\nexit 1\n',
        'classify-sessions.sh': 'exit 0\n',
        'fleet-daemon-watch.sh': 'printf "watch\\n" >> "' + str(root / 'watch') + '"\n',
        'fleet-degenerate.sh': 'printf "degen\\n" >> "' + str(root / 'degen') + '"\n',
    }.items():
        script = root / 'bin' / name
        script.write_text('#!/bin/sh\n' + body)
        script.chmod(0o755)
    tm('rename-window', '-t', 'test:0', 'stuck')
    tm('set-window-option', '-t', 'test:stuck', '@claude_state', 'working')
    tm('new-window', '-d', '-t', 'test', '-n', 'needs', 'sleep 180')
    tm('set-window-option', '-t', 'test:needs', '@claude_state', 'needs',
       ';', 'set-window-option', '-t', 'test:needs', '@claude_needs', 'perm',
       ';', 'set-window-option', '-t', 'test:needs', '@claude_state_ts', str(int(time.time()) - 600))
    tm('new-window', '-d', '-t', 'test', '-n', 'degen',
       "printf '%s' " + shlex.quote('<br>\n' * 20) + '; sleep 180')
    tm('set-window-option', '-t', 'test:degen', '@claude_state', 'working',
       ';', 'set-window-option', '-t', 'test:degen', '@agent_status_ts', str(int(time.time())))
    # needs at 1s reproduces CI 38827005758 without changing its 30s assertion.
    # stuck's CHECK interval (10s), degen (15s), heartbeat (20s), watch (30s)
    # keep their defaults. Only the stuck AGE threshold is reduced for the rig.
    env = dict(env, FLEET_NEEDS_RECONCILE_SECS='1', FLEET_NEEDS_TRACE='1',
               FLEET_STUCK_WORKING_SECS='1')
    times = {}
    start = len(calls.read_text().splitlines())
    t0 = time.monotonic()
    with (root / 'daemon.log').open('w') as log:
        daemon = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')], env=env,
                                  stdout=log, stderr=log, start_new_session=True)
    try:
        hb = root / 'logs/spinner.heartbeat'
        until(lambda: hb.exists(), 3)
        first_hb = hb.read_text().split()[0]
        while len(times) < 5 and time.monotonic() - t0 < 35:
            elapsed = time.monotonic() - t0
            states = tm('list-windows', '-t', 'test', '-F', '#{window_name}=#{@claude_state}')
            for key, ok in (
                ('needs', 'needs=done' in states),
                ('stuck', 'stuck=done' in states),
                ('degenerate', (root / 'degen').exists()),
                ('daemon-watch', (root / 'watch').exists()),
                ('heartbeat', hb.read_text().split()[0] != first_hb),
            ):
                if ok:
                    times.setdefault(key, elapsed)
            assert daemon.poll() is None, (root / 'daemon.log').read_text()
            time.sleep(.05)
        for key, bound in (('needs', 6), ('stuck', 24), ('degenerate', 35),
                           ('heartbeat', 24), ('daemon-watch', 35)):
            assert key in times and times[key] <= bound, (key, times, (root / 'daemon.log').read_text())
            print('PASS unwatched %s: %.3fs <= %ss' % (key, times[key], bound), flush=True)
        assert len((root / 'probes').read_text().splitlines()) == 2, 'needs must arm, then act'
        count = len(calls.read_text().splitlines()) - start
        print('MEASURE maintenance enabled (needs=1s): %s external commands / %.1fs; not pure render idle'
              % (count, time.monotonic() - t0), flush=True)
    finally:
        os.killpg(daemon.pid, signal.SIGTERM)
        daemon.wait(timeout=3)


if __name__ == '__main__':
    main()
