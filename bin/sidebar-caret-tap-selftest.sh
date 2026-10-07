#!/bin/bash
# A tap on a parent's ▸ opens its sub-tasks (issue #2167), on the real mouse path:
# a private tmux socket with the client's binds (conf/tmux-shell.conf), a real
# client attached to a pty that SGR mouse bytes are written to — so tmux's
# MouseDown1Pane / DoubleClick1Pane, the list's curses and dash-fold-toggle.sh all
# run — on the client's rows: another machine's (`wid:`), whose fold bit is this
# machine's global/remote_fold_<sess> (issue #1749).
#
#   A  a tap ON ▸ opens the block (the bit written, the child painted) and the
#      session in view stays.
#   B  a tap on the gap right of ▸ — the cell before the name — folds too. Before
#      #2167 only ▸ and the cell left of it did; this one switched to the row.
#   C  a tap on the state glyph, left of the tree, folds too: the whole prefix
#      left of the name is the caret's.
#   D  a double-click on ▸ is ONE fold, however it arrives: in one write ncurses
#      hands the list a single BUTTON1_DOUBLE_CLICKED, which it used to drop; at a
#      hand's pace (press, release, press, release apart) the list sees separate
#      presses — DoubleClick1Pane forwards one more — and the second used to fold
#      the block straight back.
#   E  a tap on the name still switches to the row (and folds nothing).
set -uo pipefail
export FLEET_SIDEBAR_NODE=1   # the drawer's selftest seam (fleet-sidebar.sh)
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'selftest SKIP: tmux missing'; exit 0; }
python3 - "$BIN" <<'PY'
import fcntl
import importlib.util
import os
import pty
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
work = Path(tempfile.mkdtemp(prefix='sbct.', dir='/tmp'))
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
sock = str(work / 'ft')
shim = work / 'path'
shim.mkdir()
(shim / 'tmux').write_text('#!/bin/sh\nexec %s -S %s "$@"\n' % (shlex.quote(real_tmux), shlex.quote(sock)))
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
conf = work / 'conf/fleets/ft/conf'
conf.parent.mkdir(parents=True)
conf.write_text('FLEET_SIDEBAR=1\nCCQUOTA_FLEET=1\n')
# The hub's rows: a parent on m4 with one child, and a row with none.
G = work / '.claude-dash/global'
G.mkdir(parents=True)
F = '11111111-2222-3333-4444-555555555555'
PARENT = '%s/acme-app:scratch-5' % F
now = int(time.time())


def remote(key, issue, state, name, origin):
    return '\x1f'.join(['wid:%s/%s' % (F, key), 'm4', 'online', issue, 'acme/app', state,
                        'claude', name, origin, '', '', '', 'hub']) + '\n'


(G / 'remote_ft').write_text('#ts\x1f%d\n#me\x1fm5\n#node\x1fm4\x1fonline\x1f3\x1f%d\n' % (now, now)
                             + remote('acme-app:scratch-5', '', 'looping', 'PARENTX', '')
                             + remote('acme-app:issue-10', '10', 'working', 'KIDX', PARENT)
                             + remote('acme-app:issue-20', '20', 'done', 'LONER', ''))
(G / 'hub_ok').write_text('%d\n' % now)
spec = importlib.util.spec_from_file_location('sidebar', str(real_bin / 'fleet-sidebar.py'))
sidebar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sidebar)
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
    subprocess.run([real_tmux, '-S', sock, 'kill-server'], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


def views():
    return [line.split()[0] for line in tm('list-panes', '-a', '-F', '#{pane_id} #{@sidebar}').splitlines()
            if line.endswith(' 1')]


def opened():
    p = G / 'remote_fold_ft'
    return PARENT in (p.read_text().split() if p.exists() else [])


def painted():
    return tm('capture-pane', '-p', '-t', side)


def kid_shown():
    return 'KIDX' in painted()


def parent_at():
    """(y, the cell ▸/▾ is painted in, the cell its name starts in)."""
    lines = painted().splitlines()
    y = next(i for i, line in enumerate(lines) if 'PARENTX' in line)
    line = lines[y]
    caret = next(i for i, c in enumerate(line) if c in '▸▾')
    return y, sidebar.width_of(line[:caret]), sidebar.width_of(line[:line.index('PARENTX')])


def tap(column, y, count=1, gap=0):
    # Apart from tmux's double-click interval, unless count asks for one: the
    # press/release pairs then go out in ONE write, or `gap` seconds apart each.
    time.sleep(.6)
    x = int(tm('display-message', '-p', '-t', side, '#{pane_left}')) + column + 1
    y = int(tm('display-message', '-p', '-t', side, '#{pane_top}')) + y + 1
    if not gap:
        os.write(terminal, ('\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x, y, x, y)).encode() * count)
        return
    for n in range(count):
        os.write(terminal, ('\x1b[<0;%d;%dM' % (x, y)).encode())
        time.sleep(gap)
        os.write(terminal, ('\x1b[<0;%d;%dm' % (x, y)).encode())
        time.sleep(gap)


def toggled(was, why):
    """One tap folded or opened the block: the bit flipped, the list agrees,
    and it still does once the write and a fresh frame have landed."""
    check(wait(lambda: opened() != was, 10), '%s: the fold bit did not flip (open=%s)' % (why, was))
    check(wait(lambda: kid_shown() == (not was), 4), '%s: the list does not paint the fold: %r' % (why, painted()))
    time.sleep(1.5)
    check(opened() != was and kid_shown() == (not was),
          '%s: the fold came undone (open=%s, child painted=%s)' % (why, opened(), kid_shown()))
    check(tm('display-message', '-p', '#{window_id}') == home, '%s: the tap switched the session in view' % why)


try:
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'ft', '-x', '160', '-y', '30', '-n', 'one', 'cat')
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    tm('set-option', '-w', '@issue', '1')
    home = tm('display-message', '-p', '#{window_id}')
    # The client's binds and hooks as fleet-shell.sh renders them, minus the bar.
    shell_conf = ((real_bin.parent / 'conf/tmux-shell.conf').read_text()
                  .replace('__BIN__', str(bin_dir)).replace('__PREFIX__', 'C-b'))
    lines = [l for l in shell_conf.splitlines() if not l.startswith('#') and not l.startswith('set -g status')]
    (work / 's.conf').write_text('\n'.join(lines) + '\n')
    tm('source-file', str(work / 's.conf'))
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
    client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'ft'],
                              env={k: v for k, v in env.items() if k != 'TMUX'},
                              stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    terminal = master

    def drain():
        try:
            while os.read(master, 65536):
                pass
        except OSError:
            pass
    threading.Thread(target=drain, daemon=True).start()
    check(wait(lambda: bool(views()), 10), 'the attach hook did not draw the list')
    side = views()[0]
    check(wait(lambda: 'PARENTX' in painted(), 10), 'the list has no remote rows: %r' % tm('capture-pane', '-p'))
    check(not opened() and not kid_shown(), 'the remote parent does not start folded')
    y, caret, name = parent_at()
    check(name == caret + 2, 'the name is not two cells right of ▸: %d / %d' % (caret, name))

    tap(caret, y)
    toggled(False, 'A: a tap on ▸')
    print('A: a tap on ▸ opens the block; the session in view stays')

    tap(caret + 1, y)
    toggled(True, 'B: a tap on the gap right of ▸')
    print('B: a tap on the gap right of ▸ folds too')

    tap(2, y)
    toggled(False, 'C: a tap on the state glyph')
    print('C: a tap on the state glyph (the prefix left of the name) folds too')

    tap(caret, y, count=2)
    toggled(True, 'D: a double-click on ▸ (one write)')
    tap(caret, y, count=2, gap=.06)
    toggled(False, 'D: a double-click on ▸ (at a hand\'s pace)')
    print('D: a double-click on ▸ is one fold, in one write or at a hand\'s pace')

    tap(name + 1, y)
    check(wait(lambda: tm('display-message', '-p', '#{window_name}').startswith('PARENTX'), 6),
          'E: a tap on the name did not switch to the row: %s' % tm('display-message', '-p', '#{window_name}'))
    check(opened(), 'E: a tap on the name folded the block')
    print('E: a tap on the name still switches to the row')
    print('sidebar-caret-tap selftest: %d checks passed' % checks)
except AssertionError as e:
    print('FAIL: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
