#!/usr/bin/env python3
"""Real spinner, private HOME/socket, count external commands (not ps samples).

The default 30s budget is the shared renderer wait with no deadline due.
Its integer command allowance is floor(5 * observed_seconds / 60), retaining
the original five-per-minute rate (the existing 4s BREAK-IT smoke allows zero).
The real spinner keeps ALL maintenance enabled; its deadlines/cost are measured
separately by --maintenance. A default spinner has heartbeat/self-heal due within
60s, so its whole-process count is deliberately not labelled pure render idle.
"""
import os
import pathlib
import pty
import runpy
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
        for name in ('tmux-spinner.sh', 'fleet-degenerate.awk', 'tmux-spinner.py', 'fleet-render-watch.py', 'fleet_pending_tool.py', 'fleet_native_proc.py', 'fleet_agent_argv.py', 'fleet-codex-rpc.py', 'fleet-codex-session.py'):
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
                   CCQUOTA_FLEET='0', SPIN_TRACE='1')
        env.pop('TMUX', None)
        env.pop('TMUX_PANE', None)

        def tm(*args):
            return subprocess.check_output([TMUX, '-L', 'test', *args], env=env,
                                           stderr=subprocess.DEVNULL, text=True).strip()

        def spin():
            return tm('display-message', '-p', '-t', 'test:0', '#{@spin}')

        marks = []

        def publish_state(value):
            marks.append('publish %.6f %s' % (time.monotonic(), value))
            tm('set-window-option', '-t', 'test:0', '@claude_state', value)
            # Match set-claude-state.sh: invalidate before broadcasting. A
            # tmux format subscription can coalesce a fast state round trip;
            # the producer's dirty marker preserves that edge for the spinner.
            pathlib.Path(socket + '.dirty').touch()
            tm('wait-for', '-S', 'fleet-state-changed')

        def until(fn, limit):
            start = time.monotonic()
            while time.monotonic() - start < limit:
                if fn():
                    return time.monotonic() - start
                time.sleep(.02)
            # The spinner's own SPIN_TRACE (its waits and table reads, on the
            # same monotonic clock) says where a late frame went.
            log = root / 'daemon.log'
            tail = log.read_text().splitlines()[-60:] if log.exists() else []
            raise AssertionError('condition timed out after %ss (now %.6f)\n%s' % (
                limit, time.monotonic(), '\n'.join(marks + tail)))

        daemon = client = waiter = None
        master = None
        try:
            tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', 'sleep 180')
            socket = tm('display-message', '-p', '#{socket_path}')
            if '--deadline-events' in sys.argv:
                deadline_events(root, env, tm, until, calls)
                return
            if '--maintenance' in sys.argv:
                # the deadline-edge signals run beside it: their own root, HOME,
                # conf dir and tmux server (a second spinner here would add probes
                # and heartbeats to this one's counts) — read back at the end
                edges = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), '--deadline-events'])
                try:
                    maintenance(root, env, tm, until, calls)
                except BaseException:
                    edges.kill()
                    edges.wait()
                    raise
                assert edges.wait(timeout=60) == 0, 'the deadline-event signals failed (see above)'
                return
            # No due work is a contract of this CALL, not disabled maintenance
            # in the daemon. Startup stays outside this existing pure-wait
            # count; the runner still times fixture setup and cleanup in full.
            waiter = subprocess.Popen([sys.executable, str(root / 'bin/fleet-render-watch.py'),
                                       '.12', socket], env=env, stdout=subprocess.PIPE, text=True)
            until(lambda: 'wait-for' in calls.read_text(), 3)
            time.sleep(.3)
            start = len(calls.read_text().splitlines())
            seconds = 4 if '--quick' in sys.argv else 30
            command_limit = 5 * seconds // 60
            t0 = time.monotonic()
            while time.monotonic() - t0 < seconds:
                time.sleep(.2)
                count = len(calls.read_text().splitlines()) - start
                assert waiter.poll() is None, 'no-deadline wait ended before %ss' % seconds
                assert count <= command_limit, 'idle renderer spawned %s commands in %.1fs (limit %s/%ss)' % (
                    count, time.monotonic()-t0, command_limit, seconds)
            print('PASS renderer wait, no deadline due: %s external commands / %ss (integer limit %s)' % (
                count, seconds, command_limit), flush=True)
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
            publish_state('done')
            elapsed = until(lambda: spin() == '✓', 2)
            print('PASS state event → done: %.3fs' % elapsed, flush=True)
            publish_state('working')
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
    cmd = [sys.executable, str(root / 'bin/fleet-render-watch.py'),
           '--max-frames', '4', '--since-frame', '0', '.05', socket]
    first = subprocess.check_output(cmd, env=env, text=True).split()
    time.sleep(.3)  # maintenance consumes the next deadline before we wait again
    start = len(calls.read_text().splitlines())
    cmd[-3] = first[2]
    second = subprocess.check_output(cmd, env=env, text=True).split()
    assert int(second[0]) >= 6, 'work between waits was lost from the clock'
    assert len(calls.read_text().splitlines()) == start, 'overdue work started wait/lease clients'
    print('PASS maintenance time counts toward next deadline; overdue work never waits', flush=True)


def maintenance(root, env, tm, until, calls):
    """Real loops/scans/strikes; only transcript and outward actions are seams."""
    for name, body in {
        'fleet-daemon-watch.sh': 'printf "watch\\n" >> "' + str(root / 'watch') + '"\n',
        'fleet-degenerate.sh': 'printf "degen\\n" >> "' + str(root / 'degen') + '"\n',
    }.items():
        script = root / 'bin' / name
        script.write_text('#!/bin/sh\n' + body)
        script.chmod(0o755)
    # Inject the oracle boundary, not a retired CLI fallback. Production still
    # runs the actual tmux scan, two observations, identity/stamp checks and writes.
    (root / 'bin/fleet_pending_tool.py').write_text("""
import os, time
from pathlib import Path
PANE_FORMAT = '#{pane_id}'
def parse_panes(text): return [dict(pane=p) for p in text.splitlines()]
def observe(reader, expected=None):
    rows = reader()
    with (Path(os.environ['HOME']).parent / 'probes').open('a') as f: f.write('probe\\n')
    reader()
    return [dict(pane=r['pane'], code=1, tool='', identity={'pane':r['pane']}, expires_at=time.time()+10) for r in rows]
""")
    # The absence-only daemon fast path must delegate when evidence exists.
    evidence = root / 'tmp/.claude-dash/global'
    evidence.mkdir(parents=True)
    (evidence / 'collect.heartbeat').write_text('phase_ts=1\n')
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
    # stuck's CHECK interval (10s), degen (15s), watch (30s) keep their defaults.
    # Pin the accelerated 3s heartbeat separately from the default render-rate
    # budget (spinner-rate-selftest.sh); only the stuck AGE threshold is reduced.
    env = dict(env, FLEET_NEEDS_RECONCILE_SECS='1', FLEET_NEEDS_TRACE='1',
               FLEET_STUCK_WORKING_SECS='1', SPIN_HB_SECS='3')
    times = {}
    start = len(calls.read_text().splitlines())
    t0 = time.monotonic()
    with (root / 'daemon.log').open('w') as log:
        daemon = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')], env=env,
                                  stdout=log, stderr=log, start_new_session=True)
    try:
        hb = root / 'conf/logs/spinner.heartbeat'   # the login's records (#4668)
        until(lambda: hb.exists(), 3)
        first_hb = hb.read_text().split()[0]
        last_hb = first_hb
        heartbeat_times = []
        while len(times) < 5 and time.monotonic() - t0 < 35:
            elapsed = time.monotonic() - t0
            current_hb = hb.read_text().split()[0]
            if current_hb != last_hb:
                heartbeat_times.append(elapsed)
                last_hb = current_hb
            states = tm('list-windows', '-t', 'test', '-F', '#{window_name}=#{@claude_state}')
            for key, ok in (
                ('needs', 'needs=done' in states),
                ('stuck', 'stuck=done' in states),
                ('degenerate', (root / 'degen').exists()),
                ('daemon-watch', (root / 'watch').exists()),
                ('heartbeat', current_hb != first_hb),
            ):
                if ok:
                    times.setdefault(key, elapsed)
            assert daemon.poll() is None, (root / 'daemon.log').read_text()
            time.sleep(.05)
        for key, bound in (('needs', 6), ('stuck', 24), ('degenerate', 35),
                           ('heartbeat', 5), ('daemon-watch', 35)):
            assert key in times and times[key] <= bound, (key, times, (root / 'daemon.log').read_text())
            print('PASS unwatched %s: %.3fs <= %ss' % (key, times[key], bound), flush=True)
        assert len((root / 'probes').read_text().splitlines()) == 2, 'needs must arm, then act'
        assert len(heartbeat_times) >= 3, heartbeat_times
        for n, actual in enumerate(heartbeat_times, 1):
            assert n * 3 - 1 <= actual <= n * 3 + 2, ('heartbeat deadline', n * 3, actual)
        print('PASS heartbeat deadlines 3/6/9/...s: ' +
              '/'.join('%.3f' % t for t in heartbeat_times), flush=True)
        count = len(calls.read_text().splitlines()) - start
        print('MEASURE maintenance enabled (needs=1s, heartbeat=3s): %s external commands / %.1fs; not pure render idle'
              % (count, time.monotonic() - t0), flush=True)
    finally:
        os.killpg(daemon.pid, signal.SIGTERM)
        daemon.wait(timeout=3)


def deadline_events(root, env, tm, until, calls):
    """Signal immediately before/at/after a real spinner maintenance deadline."""
    tm('new-window', '-d', '-t', 'test', '-n', 'edge', 'sleep 180')
    tm('set-window-option', '-t', 'test:edge', '@claude_state', 'done')
    env = dict(env, SPIN_HB_SECS='3', FLEET_NEEDS_RECONCILE_SECS='20',
               FLEET_STUCK_WORKING_SECS='120')
    control = runpy.run_path(str(root / 'bin/fleet-render-watch.py'))['Control']('test', env=env)
    start = len(calls.read_text().splitlines())
    with (root / 'edge.log').open('w') as log:
        daemon = subprocess.Popen(['sh', str(root / 'bin/tmux-spinner.sh')], env=env,
                                  stdout=log, stderr=log, start_new_session=True)
    try:
        previous = 0
        for offset, state in ((-.15, 'working'), (0, 'done'), (.15, 'working')):
            found = []

            def next_deadline():
                for line in reversed((root / 'edge.log').read_text().splitlines()):
                    if not line.startswith('spinner-wait '):
                        continue
                    deadline = float(line.split()[2])
                    if deadline > previous and deadline - time.clock_gettime(time.CLOCK_MONOTONIC) > 2.5:
                        found.append(deadline)
                        return True
                    return False
                return False

            until(next_deadline, 10)
            previous = found[0]
            time.sleep(max(0, previous + offset - time.clock_gettime(time.CLOCK_MONOTONIC)))
            control.commands([['set-window-option', '-t', 'test:edge', '@claude_state', state],
                              ['wait-for', '-S', 'fleet-state-changed']])
            signal_at = time.clock_gettime(time.CLOCK_MONOTONIC) - previous
            if offset < 0:
                assert signal_at < 0, ('before-deadline signal arrived late', signal_at)
            if offset > 0:
                assert signal_at > 0, ('after-deadline signal arrived early', signal_at)
            def painted():
                glyph = tm('display-message', '-p', '-t', 'test:edge', '#{@spin}')
                return glyph == '✓' if state == 'done' else glyph not in ('', '✓')
            elapsed = until(painted, 2)
            print('PASS deadline signal offset %+.3fs (target %+.2f): %s painted in %.3fs'
                  % (signal_at, offset, state, elapsed), flush=True)
        assert daemon.poll() is None
    finally:
        control.close()
        os.killpg(daemon.pid, signal.SIGTERM)
        daemon.wait(timeout=3)


if __name__ == '__main__':
    main()
