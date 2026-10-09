#!/bin/bash
# The list's FIRST tap and its cursor (issue #1756), on a private tmux socket with
# the client's binds (conf/tmux-shell.conf) and a real terminal (a pty) sending
# SGR mouse bytes, so every layer between the click and fleet-sidebar.py runs.
#
#   A  the session on the right holds the keyboard — a shell asking for every
#      mouse motion (1003, as Claude does) or a nested tmux client — and one tap
#      on another row switches to it: the first tap, not the second.
#   B  the window was switched from the session side (prefix q, the bar, a
#      spawn) a moment ago, before the list's 1s read caught up: one tap on the
#      row just left still switches back. Before #1756 it read as the SECOND tap
#      on the row the list still thought current (the menu), or fell in the
#      hidden branch and was dropped.
#   C  the list never takes the keyboard (issue #1950 — its input line and the
#      cursor on it, #1756, went): after a tap on a row the client stays in the
#      root table, unpinned, the list shows no cursor, and typing reaches the
#      session. (#1761: nothing here rests on the `active-pane` client flag
#      tmux 3.8 removes.)
set -uo pipefail
# Every session its own row (issue #2675): the batch view folds a flat list into
# 「单独的活」 — sidebar-batch-view-selftest.sh pins it; these rows are the old ones.
export FLEET_SIDEBAR_FOLD=off
export FLEET_SIDEBAR_NODE=1   # the drawer's selftest seam (fleet-sidebar.sh)
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'selftest SKIP: tmux missing'; exit 0; }
python3 - "$BIN" <<'PY'
import fcntl
import os
import pty
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from pathlib import Path

real_bin = Path(sys.argv[1])
real_tmux = shutil.which('tmux')
# Sockets live under a short dir: AF_UNIX paths stop at 104 bytes.
work = Path(tempfile.mkdtemp(prefix='sbfc.', dir='/tmp'))
root = work / 'root'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    (bin_dir / source.name).symlink_to(source)
(root / 'conf').symlink_to(real_bin.parent / 'conf')
(root / 'fleet.conf').write_text('FLEET_GLOBAL_MAX_SESSIONS=0\n')
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'),
           TERM='xterm-256color', FLEET_UI_LANG='zh')
env.pop('TMUX', None)
env.pop('TMUX_PANE', None)
shim = work / 'path'
shim.mkdir()
socks = []


def fresh_socket(n):
    # One server per round (issue #1767): `kill-server` returns before the old
    # server is gone, and a new-session on the same path can land on the dying
    # one and go down with it — every time on a 1-CPU box, on CI's ubuntu runner.
    # The file keeps the name `ft`: a socket's label is its fleet's name.
    global sock
    (work / ('s%d' % n)).mkdir()
    sock = str(work / ('s%d' % n) / 'ft')
    socks.append(sock)
    (shim / 'tmux').write_text('#!/bin/sh\nexec %s -S %s "$@"\n' % (shlex.quote(real_tmux), shlex.quote(sock)))
    (shim / 'tmux').chmod(0o755)


env['PATH'] = str(shim) + os.pathsep + env['PATH']
conf = work / 'conf/fleets/ft/conf'
conf.parent.mkdir(parents=True)
conf.write_text('FLEET_SIDEBAR=1\n')
inner_socks = []
client = terminal = None
checks = 0


def tm(*args):
    return subprocess.run([real_tmux, '-S', sock, *args], env=env, capture_output=True,
                          text=True, timeout=15).stdout.rstrip('\n')


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def wait(predicate, secs=6):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.05)
    return False


def cleanup(*_):
    if client is not None:
        client.kill()
    for s in socks + inner_socks:
        subprocess.run([real_tmux, '-S', s, 'kill-server'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


def right_cmd(kind, n):
    if kind == 'tmux':
        isock = str(work / ('in%d' % n))
        inner_socks.append(isock)
        (work / 'i.conf').write_text('set -g mouse on\nset -g focus-events on\nset -g status off\n')
        return "tmux -S %s -f %s new -A -s in 'cat -v'" % (isock, work / 'i.conf')
    # Claude asks for every motion (1003) in SGR: the client's terminal follows it.
    return "sh -c 'printf \"\\033[?1003h\\033[?1006h\"; exec cat -v'"


def views():
    return [line.split() for line in tm('list-panes', '-a', '-F', '#{pane_id} #{window_id} #{@sidebar}').splitlines()
            if line.endswith(' 1')]


def current():
    return tm('display-message', '-p', '#{window_id}')


def table():
    return tm('list-clients', '-F', '#{client_key_table}')


def cell(pane, row, column=2):
    x = int(tm('display-message', '-p', '-t', pane, '#{pane_left}')) + column + 1
    y = int(tm('display-message', '-p', '-t', pane, '#{pane_top}')) + row + 1
    return x, y


def tap(x, y, settle=.6):
    # Apart from tmux's double-click interval, unless the case says otherwise.
    time.sleep(settle)
    os.write(terminal, ('\x1b[<0;%d;%dM' % (x, y)).encode())
    time.sleep(.05)
    os.write(terminal, ('\x1b[<0;%d;%dm' % (x, y)).encode())


def row_of(side, name):
    lines = tm('capture-pane', '-p', '-t', side).splitlines()
    # a row ends in its issue number (`#N`, issue #2545): the name sits before it
    return next(i for i, line in enumerate(lines)
                if re.sub(r'\s+#\d+$', '', line.rstrip()).endswith(name))


try:
    for n, kind in enumerate(('shell', 'tmux')):
        fresh_socket(n)
        tm('-f', '/dev/null', 'new-session', '-d', '-s', 'ft', '-x', '160', '-y', '30',
           '-n', 'one', right_cmd(kind, 1))
        env['TMUX'] = sock + ',1,0'
        tm('set-option', '-g', 'default-shell', '/bin/sh')
        w1 = current()
        tm('set-option', '-w', '-t', w1, '@issue', '1')
        w2 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'two', right_cmd(kind, 2))
        tm('set-option', '-w', '-t', w2, '@issue', '2')
        # The client's binds and hooks as fleet-shell.sh renders them, minus the bar.
        shell_conf = ((real_bin.parent / 'conf/tmux-shell.conf').read_text()
                      .replace('__BIN__', str(bin_dir)).replace('__PREFIX__', 'C-b'))
        lines = [l for l in shell_conf.splitlines()
                 if not l.startswith('#') and not l.startswith('set -g status')]
        (work / 's.conf').write_text('\n'.join(lines) + '\n')
        tm('source-file', str(work / 's.conf'))
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
        client_env = {k: v for k, v in env.items() if k != 'TMUX'}
        client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'ft'],
                                  env=client_env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        terminal = master

        def drain(fd=master):
            try:
                while os.read(fd, 65536):
                    pass
            except OSError:
                pass
        threading.Thread(target=drain, daemon=True).start()
        check(wait(lambda: bool(views())), kind + ': the attach hook did not draw the list')
        side = views()[0][0]
        check(wait(lambda: 'two' in tm('capture-pane', '-p', '-t', side)), kind + ': the list has no rows')

        # A: the keyboard on the session (a tap there), then one tap on the other row.
        for n in range(2):
            want = w2 if current() == w1 else w1
            name = 'two' if want == w2 else 'one'
            tap(*cell(tm('display-message', '-p', '#{pane_id}'), 5, 10))
            check(wait(lambda: table() == 'root', 3), kind + ': a tap on the session kept the keyboard on the list')
            tap(*cell(side, row_of(side, name)))
            check(wait(lambda: current() == want, 3),
                  'A %s: the first tap on «%s» did not switch to it (the keyboard was on the session)' % (kind, name))
        print('A %s: the first tap switches, with the session holding the keyboard' % kind)

        # B: switched from the session side; the list moves along; tap the row
        # just left before the list's next read.
        for n in range(3):
            left = current()
            other = w2 if left == w1 else w1
            tm('select-window', '-t', other)
            check(wait(lambda: any(v[1] == other for v in views()), 3), kind + ': the list did not follow the switch')
            name = 'one' if left == w1 else 'two'
            tap(*cell(side, row_of(side, name)), settle=.15)
            check(wait(lambda: current() == left, 3),
                  'B %s: one tap on «%s» right after a switch from the session side did not switch back' % (kind, name))
        print('B %s: the first tap after a switch from the session side switches' % kind)

        # C: a tap on the list leaves the keyboard on the session.
        def cursor(pane):
            return tm('display-message', '-p', '-t', pane, '#{cursor_flag} #{cursor_x} #{cursor_y} #{pane_height}').split()
        left = current()
        other = w2 if left == w1 else w1
        tap(*cell(side, row_of(side, 'two' if other == w2 else 'one')))
        check(wait(lambda: current() == other, 3), kind + ': a tap on a row did not switch to it')
        time.sleep(1.2)  # past the list's 1s read: nothing re-pins or re-takes the keyboard
        check(table() == 'root', 'C %s: a tap on the list moved the client into its key table: %r' % (kind, table()))
        check('active-pane' not in tm('list-clients', '-F', '#{client_flags}'),
              'C %s: a tap on the list pinned the client to it' % kind)
        check(cursor(side)[0] == '0', 'C %s: the list shows a cursor: %r' % (kind, cursor(side)))
        session = tm('display-message', '-p', '#{pane_id}')
        check(session != side, 'C %s: the list became the active pane' % kind)
        os.write(terminal, b'zq')
        check(wait(lambda: 'zq' in tm('capture-pane', '-p', '-t', session), 3),
              'C %s: typing after a tap on the list did not reach the session' % kind)
        check('zq' not in tm('capture-pane', '-p', '-t', side), 'C %s: typing reached the list' % kind)
        print('C %s: a tap on the list leaves the keyboard, and no cursor, with the session' % kind)

        client.kill()
        client.wait()
        client = None
        os.close(terminal)
        terminal = None
        tm('kill-server')
        env.pop('TMUX', None)
    print('sidebar-first-click selftest: %d checks passed' % checks)
except AssertionError as e:
    print('FAIL: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
