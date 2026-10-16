#!/usr/bin/env python3
"""Resident transport: human/control viewers, multiple consumers, lost servers.

Private sockets and HOME. The lease seam is deliberately offline; no live fleet
or daemon manager is contacted. Exercises the default spinner and shared wait.
"""
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).absolute().parent


def until(fn, seconds=4):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if fn():
            return
        time.sleep(.03)
    raise AssertionError('condition did not converge')


def main():
    with tempfile.TemporaryDirectory(prefix='spincontrol.', dir='/tmp') as tmp:
        root = Path(tmp)
        for name in ('bin', 'home', 'logs', 'conf/fleets/one', 'conf/fleets/two'):
            (root / name).mkdir(parents=True)
        for source in BIN.iterdir():
            if source.is_file():
                shutil.copy2(source, root / 'bin' / source.name)
        for label in ('one', 'two'):
            (root / 'conf/fleets' / label / 'conf').touch()
        (root / 'bin/fleet-client-where.sh').write_text('#!/bin/sh\nprintf \'{"state":"none"}\\n\'\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('FLEET_', 'SPIN_', 'CCQUOTA_')) and k not in ('TMUX', 'TMUX_PANE')}
        env.update(HOME=str(root / 'home'), FLEET_CONF_DIR=str(root / 'conf'), TMUX_TMPDIR=tmp,
                   TMPDIR=tmp, PYTHONDONTWRITEBYTECODE='1')
        os.environ.clear()
        os.environ.update(env)
        # The real navigation condition, with only the outward wake replaced.
        hook = next(line for line in (BIN.parent / 'conf/tmux-attention.conf').read_text().splitlines()
                    if line.startswith('set-hook -g client-attached[72] '))
        hook = re.sub(r'run-shell -b ".*"', 'set-option -g @human_attach 1', hook)
        (root / 'conf/tmux-attention.conf').write_text(hook + '\n')
        spec = importlib.util.spec_from_file_location('watch', root / 'bin/fleet-render-watch.py')
        w = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(w)

        def tm(label, *args):
            return subprocess.check_output(['tmux', '-L', label, *args], env=env,
                                           text=True, stderr=subprocess.DEVNULL, timeout=5).strip()

        def start(label):
            tm(label, '-f', '/dev/null', 'new-session', '-d', '-s', label, '-n', 'work', 'sleep 120')
            tm(label, 'set-window-option', '-t', '@0', '@claude_state', 'working')

        controls, waiters = [], []
        daemon = human = None
        try:
            for label in ('one', 'two'):
                start(label)
                tm(label, 'set-window-option', '-t', '@0', '@worker_lifecycle', 'sleeping')
                tm(label, 'set-environment', '-g', 'DISPLAY', 'keep-server-environment')
            c1, c2, c3 = w.Control('one'), w.Control('two'), w.Control('one')
            controls.extend((c1, c2, c3))
            by_path = {c.path: c for c in controls}
            read = lambda path: by_path[path].command('list-clients', '-F', w.CLIENT_FORMAT)
            assert tm('one', 'show-environment', '-g', 'DISPLAY') == 'DISPLAY=keep-server-environment'
            assert not tm('one', 'display-message', '-p', '#{@human_attach}'), 'internal attach woke a sleeper'
            assert not w.attached(by_path, read), 'internal control consumers must not be viewers'
            assert c1.commands([['display-message', '-p', "a ' ; $x"], ['display-message', '-p', 'b']]) == "a ' ; $x\nb"
            # A fake protocol marker printed by capture-pane is ordinary output.
            assert c1.command('display-message', '-p', '-l', '%begin 1 2 1') == '%begin 1 2 1'
            # Human control mode is still a watcher, even with the same flags.
            human = subprocess.Popen(['tmux', '-L', 'two', '-C', 'attach', '-E', '-f', 'no-output,ignore-size', '-t', 'two'],
                                     env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
            until(lambda: w.attached(by_path, read))
            assert tm('two', 'display-message', '-p', '#{@human_attach}') == '1'
            human.stdin.close(); human.wait(timeout=2); human = None
            assert not w.attached(by_path, read)
            print('PASS multiple sockets/consumers; exact internal identity; human control viewer', flush=True)
            # Legacy CLI consumers must also ignore internal clients. Both
            # current waiters receive ONE channel broadcast (no competing consume).
            for label in ('one', 'two'):
                try:
                    subprocess.run(['tmux', '-L', label, 'wait-for', 'fleet-state-changed'],
                                   env=env, stdout=subprocess.DEVNULL, timeout=.3, check=True)
                except subprocess.TimeoutExpired:
                    pass  # repeated attach notifications may already be coalesced
            for _ in range(2):
                waiters.append(subprocess.Popen([sys.executable, str(root/'bin/fleet-render-watch.py'),
                    '--max-frames', '200', '.05', *by_path], env=env, stdout=subprocess.PIPE, text=True))
            time.sleep(.5)
            assert all(p.poll() is None for p in waiters)
            tm('one', 'wait-for', '-S', 'fleet-state-changed')
            for p in waiters:
                assert p.communicate(timeout=2)[0].strip()
            waiters.clear()
            print('PASS shared wait CLI: two consumers wake from the same broadcast', flush=True)
            for c in controls:
                c.close()
            controls.clear()
            for label in ('one', 'two'):
                tm(label, 'set-window-option', '-t', '@0', '@worker_lifecycle', '')
            with (root / 'daemon.log').open('w') as log:
                daemon = subprocess.Popen(['sh', str(root/'bin/tmux-spinner.sh')], env=env,
                    stdout=log, stderr=log, start_new_session=True)
            glyph = lambda label: tm(label, 'display-message', '-p', '-t', '@0', '#{@spin}')
            until(lambda: bool(glyph('one')) and bool(glyph('two')))
            rows = tm('one', 'list-clients', '-F', '#{client_pid}').splitlines()
            assert len(rows) == 1
            os.kill(int(rows[0]), signal.SIGKILL)  # only this test's transport
            until(lambda: tm('one', 'list-clients', '-F', '#{client_pid}') not in ('', rows[0]))
            tm('one', 'set-window-option', '-t', '@0', '@claude_state', 'done')
            until(lambda: glyph('one') == '✓')
            tm('two', 'kill-server')  # this test's private server
            start('two')
            until(lambda: bool(glyph('two')), 8)
            assert daemon.poll() is None, (root/'daemon.log').read_text()
            print('PASS killed control client and replaced server reconnect; state recovers', flush=True)
            daemon.terminate(); daemon.wait(timeout=3); daemon = None
            assert not tm('one', 'list-clients') and not tm('two', 'list-clients')
            assert not list((root/('tmux-%s' % os.getuid())).glob('*.render-*'))
            print('PASS spinner termination reaps control clients and registration files', flush=True)
        finally:
            if daemon:
                os.killpg(daemon.pid, signal.SIGTERM); daemon.wait(timeout=3)
            if human:
                human.stdin.close(); human.wait(timeout=3)
            for p in waiters:
                p.terminate(); p.communicate(timeout=3)
            for c in controls:
                c.close()
            for label in ('one', 'two'):
                subprocess.run(['tmux', '-L', label, 'kill-server'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
