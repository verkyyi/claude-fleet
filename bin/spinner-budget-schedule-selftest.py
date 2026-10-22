#!/usr/bin/env python3
"""Structural supplement, NOT real 60-second observation or a rate measurement.

Run the production Spinner.run, maintenance bodies, control transport, lease
reader and fresh ps oracle on a private socket. Only the scheduler/wall clock
and Observer.wait are controlled. Exercise the omitted 45/50s points, the first
[S,S+60) endpoint, the next period, the 65s lease fallback and elapsed work.
"""
import collections
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import types
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(BIN))


class Finished(Exception):
    pass


def scenario(fixture, delayed=False):
    with tempfile.TemporaryDirectory(prefix='spinschedule.', dir='/tmp') as tmp:
        root = Path(tmp)
        for name in ('bin', 'logs', 'home', 'conf/fleets/test', 'tmp'):
            (root / name).mkdir(parents=True)
        (root / 'conf/fleets/test/conf').touch()
        (root / 'bin/fleet-client-where.sh').write_text('#!/bin/sh\nprintf \'{"state":"none"}\\n\'\n')
        # Make the real daemon_watch presence test true; absence of evidence is
        # what must prevent launch. Any unexpected launch fails the process log.
        (root / 'bin/fleet-daemon-watch.sh').write_text('#!/bin/sh\nexit 99\n')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FLEET_', 'CCQUOTA_', 'CLAUDE_', 'SPIN_', 'STUCK_'))
               and k not in ('TMUX', 'TMUX_PANE')}
        env.update(HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'),
                   TMUX_TMPDIR=tmp, TMPDIR=str(root / 'tmp'))
        with patch.dict(os.environ, env, clear=True):
            spec = importlib.util.spec_from_file_location('schedule_spinner', BIN / 'tmux-spinner.py')
            spinner_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(spinner_module)
            spinner_module.BIN = root / 'bin'
            watch = spinner_module.watch
            watch.BIN = root / 'bin'
            tmux = shutil.which('tmux')

            def tm(*args):
                return subprocess.check_output([tmux, '-L', 'test', *args], text=True,
                                               stderr=subprocess.DEVNULL, timeout=5).strip()

            spinner = None
            try:
                tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-n', 'work', 'sleep 180')
                if fixture == 'maintenance':
                    tm('set-window-option', '-t', 'test:work', '@claude_state', 'working')
                    tm('new-window', '-d', '-t', 'test', '-n', 'needs', 'sleep 180')
                    tm('set-window-option', '-t', 'test:needs', '@claude_state', 'needs',
                       ';', 'set-window-option', '-t', 'test:needs', '@claude_needs', 'perm',
                       ';', 'set-window-option', '-t', 'test:needs', '@claude_state_ts',
                       str(int(time.time()) - 600))
                # S precedes initialization D, as in the real process fixture.
                start, initialized = 100.0, 100.5
                now = [initialized]
                epoch = time.time() - initialized
                spinner_module.clock = watch.monotonic = lambda: now[0]
                spinner_module.time = types.SimpleNamespace(time=lambda: epoch + now[0], strftime=time.strftime)
                calls, processes, checkpoints, overdue = collections.defaultdict(list), [], {}, []
                real_popen = subprocess.Popen

                def recorded_popen(args, *a, **kw):
                    proc = real_popen(args, *a, **kw)
                    processes.append((now[0] - initialized, proc.pid, list(args)))
                    return proc

                with patch.object(subprocess, 'Popen', recorded_popen):
                    spinner = spinner_module.Spinner()
                    assert spinner.periods == dict(stuck_check=10, needs_check=20, degen_check=15,
                                                   hb_stamp=20, daemon_watch=30, park_timers=5)
                    for name in spinner.periods:
                        original = getattr(spinner, name)

                        def checked(name=name, original=original):
                            calls[name].append(now[0] - initialized)
                            original()  # real body, including fresh control reads and ps
                            if delayed and name == 'needs_check' and len(calls[name]) == 1:
                                now[0] += 25  # work consumes time; missed ticks must not burst
                        setattr(spinner, name, checked)

                    # All samples below are controlled-clock boundary checks.
                    boundaries = [start + 59.999, start + 60, start + 60.001,
                                  initialized + 59.999, initialized + 60, initialized + 60.001,
                                  initialized + 64.999, initialized + 65, initialized + 65.001]

                    def wait(controls, deadline):
                        # Complete the real offline lease read at this clock point,
                        # so its original 65s cache starts at D, not a test guess.
                        if spinner.observer.query:
                            spinner.observer.query.wait(timeout=3)
                            for _ in range(3):
                                spinner.observer.refresh()
                                if not spinner.observer.query:
                                    break
                            assert not spinner.observer.query
                        if deadline <= now[0]:
                            # Work can overrun a check already visited in this
                            # loop. The real observer returns immediately, then
                            # run performs that check once and advances its due.
                            overdue.append((now[0], deadline))
                            assert delayed and len(overdue) == 1, ('catch-up storm', overdue)
                            return
                        for point in boundaries:
                            if now[0] == point:
                                checkpoints[point] = (len(calls['needs_check']), len(processes))
                        if now[0] >= boundaries[-1]:
                            raise Finished
                        now[0] = min([deadline] + [p for p in boundaries if p > now[0]])

                    spinner.observer.wait = wait
                    try:
                        spinner.run()
                    except Finished:
                        pass
                    spinner.close()
                    spinner = None
                counts = collections.Counter(Path(row[2][0]).name for row in processes)
                if delayed:
                    assert overdue == [(initialized + 45, initialized + 30)], overdue
                    assert calls['needs_check'] == [20, 60], calls
                    assert calls['stuck_check'] == [10, 20, 45, 50, 60], calls
                    assert calls['degen_check'] == [15, 45, 60], calls
                    expected_ps = 2
                else:
                    assert calls['stuck_check'] == [10, 20, 30, 40, 50, 60], calls
                    assert calls['degen_check'] == [15, 30, 45, 60], calls
                    assert calls['needs_check'] == [20, 40, 60], calls
                    assert calls['hb_stamp'] == [20, 40, 60], calls
                    assert calls['daemon_watch'] == [30, 60], calls
                    # S+60 is before D+60; no third observation was removed.
                    for point in boundaries[:4]:
                        assert checkpoints[point][0] == 2, (point, checkpoints)
                    assert checkpoints[initialized + 60][0] == 3, checkpoints
                    assert checkpoints[initialized + 60.001][0] == 3, checkpoints
                    expected_ps = 3 if fixture == 'maintenance' else 0
                assert counts == {'tmux': 1, 'bash': 2, **({'ps': expected_ps} if expected_ps else {})}, processes
                assert [r[0] for r in processes if Path(r[2][0]).name == 'bash'] == [0, 65], processes
                assert all(Path(r[2][1]).name == 'fleet-client-where.sh' for r in processes if Path(r[2][0]).name == 'bash')
                assert [r[0] for r in processes if Path(r[2][0]).name == 'ps'] == (
                    ([20, 60] if delayed else [20, 40, 60]) if expected_ps else []), processes
                assert tm('list-clients') == '', 'structural fixture leaked its control'
                if fixture == 'maintenance':
                    assert tm('display-message', '-p', '-t', 'test:needs', '#{@claude_state}') == 'needs'
                    assert tm('display-message', '-p', '-t', 'test:work', '#{@claude_state}') == 'working'
                print('PASS STRUCTURAL %s delayed=%s: actual run/check/ps paths; checks=%s; external=%s; '
                      '45/50, first [S,S+60), D+60 next observation, lease65; NOT real 60s/rate' %
                      (fixture, delayed, dict(calls), counts), flush=True)
            finally:
                if spinner:
                    spinner.close()
                subprocess.run([tmux, '-L', 'test', 'kill-server'], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5)


for fixture_name in ('idle', 'maintenance'):
    scenario(fixture_name)
scenario('maintenance', delayed=True)
