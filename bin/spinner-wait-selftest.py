#!/usr/bin/env python3
"""Real spinner, private HOME/socket, count external commands (not ps samples)."""
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
        for name in ('tmux-spinner.sh', 'fleet-render-watch.py'):
            if (BIN / name).exists():
                shutil.copy(BIN / name, root / 'bin' / name)
        # Shared-reader seam: never ask a live hub/lease in a drill.
        (root / 'bin/fleet-client-where.sh').write_text(
            '#!/bin/sh\ncat "' + tmp + '/lease"\n')
        (root / 'lease').write_text('{"state":"none"}\n')
        calls = root / 'calls'
        calls.touch()
        for name in ('tmux', 'sleep', 'awk', 'date', 'mv', 'rm', 'python3'):
            script = root / 'shim' / name
            script.write_text('#!/bin/sh\nprintf "%s\\n" ' + shlex.quote(name)
                              + ' >> ' + shlex.quote(str(calls)) + '\nexec '
                              + shlex.quote(shutil.which(name)) + ' "$@"\n')
            script.chmod(0o755)
        env = dict(os.environ, HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'),
                   TMUX_TMPDIR=tmp, TMPDIR=str(root / 'tmp'),
                   PATH=str(root / 'shim') + ':' + os.environ['PATH'],
                   FLEET_STUCK_WORKING_SECS='0', FLEET_DEGENERATE_SECS='0',
                   FLEET_NEEDS_RECONCILE_SECS='0', CCQUOTA_FLEET='0')
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

        daemon = client = None
        master = None
        try:
            tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', 'sleep 180')
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'working')
            with (root / 'daemon.log').open('w') as log:
                daemon = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')],
                                          env=env, stdout=log, stderr=log, start_new_session=True)
            until(lambda: bool(spin()), 5)
            time.sleep(1)
            start = len(calls.read_text().splitlines())
            seconds = 4 if '--quick' in sys.argv else 60
            t0 = time.monotonic()
            while time.monotonic() - t0 < seconds:
                time.sleep(.2)
                count = len(calls.read_text().splitlines()) - start
                assert count <= 5, 'unwatched spawned %s commands in %.1fs (budget 5/60s)' % (count, time.monotonic()-t0)
            print('PASS no observers: %s external commands / %ss' % (count, seconds), flush=True)
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


if __name__ == '__main__':
    main()
