#!/usr/bin/env python3
"""Real list loop, private HOME/socket: requests, broadcast, memo and cleanup.

selftest-part-of: fleet-hub-sessions.sh fleet-render-watch.py fleet_view.py tmux-spinner.py
Default idle observation is a real 32 seconds; --quick is the BREAK-IT drill.
The 60s deadline/lease/view boundaries are checked on production paths under a
controlled clock, explicitly STRUCTURAL, not claimed as a real-minute sample.
No network or live fleet, and no changes to spinner's maintenance deadlines.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
TMUX = shutil.which('tmux')
ENTRY_START = time.monotonic()


def until(fn, secs=2):
    start = time.monotonic()
    while time.monotonic() - start < secs:
        if fn():
            return time.monotonic() - start
        time.sleep(.02)
    raise AssertionError('condition missed %.1fs deadline' % secs)


def main():
    if not TMUX:
        print('SKIP tmux absent')
        return
    runpy.run_path(str(BIN / 'hub-sessions-watch-schedule-selftest.py'), run_name='__main__')
    with tempfile.TemporaryDirectory(prefix='hubsess-watch.', dir='/tmp') as tmp:
        root = Path(tmp)
        for d in ('bin', 'home', 'conf/fleets/test', 'conf/global', '.claude-dash/global', 'logs'):
            (root / d).mkdir(parents=True)
        for src in BIN.iterdir():
            if src.is_file():
                (root / 'bin' / src.name).symlink_to(src)
        for name, body in {
            'fleet-client-where.sh': '#!/bin/sh\nprintf \'{"state":"active"}\\n\'\n',
            'fleet-control-read.sh': '#!/bin/sh\nexit 0\n',
        }.items():
            p = root / 'bin' / name
            p.unlink()
            p.write_text(body)
            p.chmod(0o755)
        (root / 'conf/fleets/test/conf').write_text('CCQUOTA_FLEET=1\n')
        (root / 'conf/fleets/test/repos').mkdir()   # every repo is an overlay (#1937, #4806)
        (root / 'conf/fleets/test/repos/acme-app.conf').write_text('FLEET_REPO=acme/app\n')
        (root / 'conf/fleets/test/repos/.order').write_text('acme-app\n')
        data = {'machines': [], 'nodes': [], 'sessions': [{
            'worker_id': 'remote/issue-1', 'machine_name': 'other', 'os_user': 'test',
            'worker': {'state': 'done', 'issue': 1, 'repo': 'acme/app', 'name': 'one'},
        }]}
        source = root / 'sessions.json'
        source.write_text(json.dumps(data))
        fetch = root / 'fetch.py'
        fetch.write_text('import time,pathlib\np=pathlib.Path(__file__).parent\n'
                         'with (p/"fetches").open("a") as f: f.write(str(time.monotonic())+"\\n")\n'
                         'print((p/"sessions.json").read_text())\n')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FLEET_', 'CCQUOTA_', 'SPIN_')) and k not in ('TMUX', 'TMUX_PANE', 'CODEX_HOME')}
        env.update(HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'),
                   FLEET_SKIP_GLOBAL_CONF='1',
                   TMUX_TMPDIR=tmp, TMPDIR=tmp, CCQUOTA_FLEET='1',
                   FLEET_HUB_SESSIONS_CMD='%s %s' % (sys.executable, fetch),
                   FLEET_HUB_SESSIONS_USER='test', FLEET_HUB_SESSIONS_LOOP_SECS='100',
                   FLEET_HUB_SESSIONS_LONGPOLL='0')
        def tm(*args):
            return subprocess.check_output([TMUX, '-L', 'test', *args], env=env,
                                           text=True, stderr=subprocess.DEVNULL, timeout=3).strip()
        def fetches():
            try:
                return (root / 'fetches').read_text().splitlines()
            except OSError:
                return []
        procs = []
        log = (root / 'loop.log').open('w')
        try:
            tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', 'sleep 180')
            sock = tm('display-message', '-p', '#{socket_path}')
            # A real attached client, plus a permanently online lease. Neither
            # proves that the person has opened the session list.
            client = subprocess.Popen([TMUX, '-L', 'test', '-C', 'attach', '-t', 'test'],
                                      env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
            procs.append(client)
            until(lambda: tm('list-clients') != '')
            loop = subprocess.Popen(['bash', str(root / 'bin/fleet-hub-sessions.sh'), '--loop'],
                                    env=env, stdout=log, stderr=log, start_new_session=True)
            procs.append(loop)
            until(lambda: bool(fetches()), 5)
            initial = len(fetches())
            assert initial == 1, 'expected one startup fetch: %s' % initial
            seconds = 5 if '--quick' in sys.argv else 32
            observed_at = time.monotonic()
            time.sleep(seconds)
            observed = time.monotonic() - observed_at
            count = len(fetches())
            assert count == initial, 'no view: %d extra refreshes in %.3fs' % (count - initial, observed)
            print('PASS no-view real %.3fs: startup=%d subsequent=%d (attached + active lease); '
                  'not a measured 60s/rate or protocol/exec cost sample' %
                  (observed, initial, count - initial), flush=True)
            # Run the actual resident spinner alongside the list. Its existing
            # maintenance defaults stay enabled, independently of this loop.
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'working')
            spinner = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')],
                                       env=env, stdout=log, stderr=log)
            procs.append(spinner)
            spin = lambda: tm('display-message', '-p', '-t', 'test:0', '#{@spin}')
            until(lambda: bool(spin()), 5)
            # Both shared consumers register on the SAME channel. A signal is
            # broadcast; the list must not consume the spinner's wake or vice versa.
            wait = subprocess.Popen([sys.executable, str(root / 'bin/fleet-render-watch.py'),
                                     '--events-only', '1', sock], env=env, stdout=subprocess.PIPE, text=True)
            procs.append(wait)
            time.sleep(.2)
            data['sessions'][0]['worker']['state'] = 'needs'
            source.write_text(json.dumps(data))
            (root / 'conf/global/hub-nudge').touch()
            tm('set-window-option', '-t', 'test:0', '@claude_state', 'done',
               ';', 'wait-for', '-S', 'fleet-state-changed')
            cache = root / '.claude-dash/global/remote_test'
            latency = until(lambda: cache.exists() and '\x1fneeds\x1f' in cache.read_text())
            wait.communicate(timeout=2)
            until(lambda: spin() == '✓')
            print('PASS spinner + list + waiter broadcast/cache %.3fs' % latency, flush=True)
            view = root / '.claude-dash/global/hubsess.view'
            n = len(fetches())
            # Drive the real view producer, not a synthetic timestamp writer.
            request_code = ('import sys; sys.path.insert(0,sys.argv[1]); import fleet_view as v; '
                            'v.hub_view_request("test")')
            subprocess.run([sys.executable, '-c', request_code, str(root / 'bin')],
                           env=dict(env, TMUX=sock + ',0,0'), check=True)
            until(lambda: len(fetches()) > n)
            n = len(fetches())
            until(lambda: len(fetches()) > n, 2.5)
            memo = root / '.claude-dash/global/hubsess.map.json'
            before = memo.stat().st_mtime_ns
            n = len(fetches())
            until(lambda: len(fetches()) > n, 2.5)
            time.sleep(.2)
            assert memo.stat().st_mtime_ns == before, 'identical inputs recomputed'
            print('PASS real request keeps 2s pace; identical inputs reuse mapping', flush=True)
            # Stale/future requests cannot keep the loop fast, even with the
            # same attached client and shared lease still active.
            helper = [sys.executable, str(root / 'bin/fleet-render-watch.py')]
            for age in (31, -5):
                t = time.time() - age
                os.utime(view, (t, t))
                assert subprocess.run(helper + ['--view-active', str(view), '1', sock], env=env).returncode == 1
            # A signal already consumed by another consumer must not hide a
            # state change in the refresh → registration gap.
            stamp = root / 'round'
            stamp.touch()
            (root / 'conf/global/hub-nudge').touch()
            start = time.monotonic()
            answer = subprocess.check_output(helper + ['--events-only', '--since', str(stamp),
                '--changed', str(root / 'conf/global/hub-nudge'), '1', sock], env=env, text=True, timeout=2)
            assert answer.strip() == 'changed' and time.monotonic() - start <= 2
            print('PASS expired/future request and retained-input registration race', flush=True)
            # TERM the production loop by its published pid, without helping it
            # kill its waiter's process group; it must clean up those children.
            child = int((root / '.claude-dash/global/hubsess.pid').read_text())
            os.kill(child, signal.SIGTERM)
            loop.wait(timeout=3)
            assert not (root / '.claude-dash/global/hubsess.pid').exists()
            assert not list((root / '.claude-dash/global').glob('hubsess.wake.*'))
            print('PASS loop TERM cleans pid and waiter output', flush=True)
            # The exact internal spinner client is not a human, but the shared
            # reader's online lease still satisfies the other half of the rule.
            client.terminate()
            client.wait(timeout=3)
            view.touch()
            assert subprocess.run(helper + ['--view-active', str(view), '1', sock], env=env).returncode == 0
            # Mapping inputs include local state files, not just the hub body.
            parent_file = root / '.claude-dash/fleets/acme-app/parents'
            parent_file.parent.mkdir(parents=True)
            parent_file.write_text('1\t2\n')
            before = memo.stat().st_mtime_ns
            subprocess.run(['bash', str(root / 'bin/fleet-hub-sessions.sh'), '--refresh'],
                           env=env, stdout=log, stderr=log, check=True)
            assert memo.stat().st_mtime_ns != before, 'changed parent state reused old mapping'
            assert 'acme-app:issue-2' in cache.read_text(), 'changed parent missing from mapped row'
            cache.unlink()
            subprocess.run(['bash', str(root / 'bin/fleet-hub-sessions.sh'), '--refresh'],
                           env=env, stdout=log, stderr=log, check=True)
            assert '\x1fneeds\x1f' in cache.read_text(), 'missing output was not rebuilt'
            print('PASS lease-only view; changed state/missing output invalidate mapping', flush=True)
        except BaseException:
            log.flush()
            print((root / 'loop.log').read_text(), file=sys.stderr)
            raise
        finally:
            # A work alarm must not interrupt the bounded cleanup below.
            signal.alarm(0)
            # The lock wrapper gives its child a separate process group. Reap
            # that exact sandbox group as well, including a refresh in flight.
            try:
                child = int((root / '.claude-dash/global/hubsess.pid').read_text())
                os.killpg(child, signal.SIGTERM)
            except (OSError, ValueError):
                pass
            for p in reversed(procs):
                if p.poll() is None:
                    p.terminate()
                try:
                    p.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait(timeout=.5)
                if p.stdin:
                    p.stdin.close()
                if p.stdout:
                    p.stdout.close()
            tm('kill-server')  # only the private TMUX_TMPDIR/test server
            log.close()


if __name__ == '__main__':
    def deadline(signum, frame):
        raise TimeoutError('watch entry exceeded 50s work deadline; cleanup still required')
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(50)  # reserve time for finally; never stretch production periods
    try:
        main()
    finally:
        signal.alarm(0)
    elapsed = time.monotonic() - ENTRY_START
    assert elapsed < 58, 'watch entry including preparation/finally: %.3fs' % elapsed
    print('PASS complete watch entry including preparation/finally %.3fs <58s' % elapsed)
