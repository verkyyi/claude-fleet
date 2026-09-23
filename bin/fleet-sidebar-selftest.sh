#!/bin/bash
# Real tmux on a private socket: layout/focus, input, narrow screens, lifecycle,
# fleet isolation, shared row order, and the spinner's sidebar activity guard.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'selftest SKIP: tmux missing'; exit 0; }
python3 - "$BIN" <<'PY'
import importlib.util
import fcntl
import os
from pathlib import Path
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

real_bin = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('sidebar', real_bin / 'fleet-sidebar.py')
sidebar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sidebar)
assert sidebar.clip('修复仪表盘', 5) == '修复'
assert sidebar.clip('e\u0301\x1b[31m', 1) == 'e\u0301'
assert not sidebar.visible(['0', '0', '1', ''], 100)
assert not sidebar.visible(['1', '1', '1', ''], 100)
assert not sidebar.visible(['1', '0', '0', ''], 100)
assert not sidebar.visible(['1', '0', '1', '99'], 100)
assert sidebar.visible(['1', '0', '1', '1'], 100)
assert sidebar.tail('abc修复', 5) == 'c修复' and sidebar.tail('abc', 9) == 'abc'
assert sidebar.typed('q') and sidebar.typed('修') and sidebar.typed(' ')
assert not sidebar.typed('\x0e') and not sidebar.typed('\x7f')

real_tmux = shutil.which('tmux')
work = Path(tempfile.mkdtemp(prefix='sidebar-selftest.'))
# A sandbox install root (issue #896): the input line spawns through the REAL
# dash-raw-session.sh, so every script is the shipped one except the agent
# launcher, which only holds its window open. Its fleet.conf lifts the machine-
# wide session cap — the operator's own live sessions must not refuse this test.
root = work / 'root'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    if source.name != 'fleet-claude.sh':
        (bin_dir / source.name).symlink_to(source)
(bin_dir / 'fleet-claude.sh').write_text('#!/bin/sh\nexec sleep 600\n')
(bin_dir / 'fleet-claude.sh').chmod(0o755)
(root / 'conf').symlink_to(real_bin.parent / 'conf')
(root / 'fleet.conf').write_text('FLEET_GLOBAL_MAX_SESSIONS=0\n')
main = work / 'main'
main.mkdir()
for git in (['init', '-q'], ['config', 'user.email', 't@t'], ['config', 'user.name', 't'],
            ['commit', '-q', '--allow-empty', '-m', 'seed']):
    subprocess.run(['git', '-C', str(main), *git], check=True, timeout=15,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
base = subprocess.run(['git', '-C', str(main), 'branch', '--show-current'], text=True,
                      capture_output=True, timeout=15).stdout.strip()
fleet_conf = 'FLEET_SIDEBAR=1\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=%s\n' % (main, base)
sock = str(work / 'fleet-test')
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'),
           FLEET_HUB_VISITS_LOGDIR=str(work / 'logs'), TERM='xterm-256color')
shim = work / 'path'
shim.mkdir()
(shim / 'tmux').write_text('#!/bin/sh\nexec ' + shlex.quote(real_tmux) +
                          ' -S ' + shlex.quote(sock) + ' "$@"\n')
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
conf = work / 'conf/fleets/fleet-test/conf'
conf.parent.mkdir(parents=True)
conf.write_text(fleet_conf)
client = None
terminal = None
checks = 0

def command(args, **kwargs):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=15, **kwargs)

def tm(*args):
    result = command([real_tmux, '-S', sock, *args])
    if result.returncode:
        raise AssertionError((args, result.stderr))
    return result.stdout.rstrip('\n').replace('\\037', '\x1f')

def check(condition, message):
    global checks
    assert condition, message
    checks += 1

def wait_for(predicate, message):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    snapshots = [tm('display-message', '-p', '-t', p[0],
                    '#{pane_id} top=#{pane_top} height=#{pane_height} window=#{window_height} client=#{client_height}') +
                 '\n' + tm('capture-pane', '-p', '-t', p[0]) for p in views()]
    raise AssertionError(message + '\n' + '\n'.join(snapshots))

def views():
    return [line.split() for line in tm('list-panes', '-a', '-F',
            '#{pane_id} #{window_id} #{@sidebar}').splitlines()
            if line.endswith(' 1')]

def call(verb='sync', *args):
    result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), verb, 'fleet-test', *args])
    check(result.returncode == 0, result.stderr)

def view_on(window):
    return [p[0] for p in views() if p[1] == window]

def click(pane, row=0, column=2, repeat=False, count=1):
    # Separate ordinary single clicks from tmux's delayed double-click zoom.
    # The repeat-click regression below deliberately stays inside that interval.
    # count=2 is a deliberate double-click: both press/release pairs go out in
    # ONE write, so a loaded box cannot stretch them past tmux's click timeout.
    if not repeat:
        time.sleep(.6)
    x = int(tm('display-message', '-p', '-t', pane, '#{pane_left}')) + column + 1
    y = int(tm('display-message', '-p', '-t', pane, '#{pane_top}')) + row + 1
    os.write(terminal, ('\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x, y, x, y)).encode() * count)

def zoomed(window):
    return tm('display-message', '-p', '-t', window, '#{window_zoomed_flag}')

def copied():
    try:
        return tm('show-buffer')
    except AssertionError:
        return ''

def navigation():
    return 'fleet-sidebar' in tm('list-clients', '-F', '#{client_key_table}')

def input_line(pane):
    # The view's LAST row is the one input line (issue #896).
    lines = tm('capture-pane', '-p', '-t', pane).splitlines()
    return lines[-1].rstrip() if lines else ''

def worker_cue(pane):
    return input_line(pane) == '›'

def tasks_cue(pane):
    return input_line(pane).startswith('› 新会话名')

def windows():
    return tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines()

def server_version():
    found = re.search(r'(\d+)\.(\d+)', tm('display-message', '-p', '#{version}'))
    return tuple(map(int, found.groups())) if found else (0, 0)

def type_keys(text):
    """Type into the attached terminal as a burst (one write — an IME commit, a
    fast typist), which tmux 3.7+ keeps in the sidebar table key by key. Older
    tmux looks up a burst's later keys BEFORE the Any bind's queued switch-client
    re-enters the table, so they fall to the worker (documented in
    ARCHITECTURE.md); there the test types one character at a time."""
    if server_version() >= (3, 7):
        os.write(terminal, text.encode())
        return
    for char in text:
        os.write(terminal, char.encode())
        time.sleep(.15)

def row_data(current='', compact=True):
    row_env = dict(env, FLEET_SESSION='fleet-test', FLEET_SIDEBAR_CURRENT=current)
    result = subprocess.run(['bash', str(bin_dir / 'tmux-dashboard-rows.sh')] +
                            (['--sidebar'] if compact else []), env=row_env,
                            text=True, capture_output=True, timeout=15)
    check(result.returncode == 0, result.stderr)
    return [line.split('\x1f') for line in result.stdout.split('\n') if '\x1f' in line]

def cleanup(*_):
    if client:
        client.terminate()
        try:
            client.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.kill()
    if terminal is not None:
        os.close(terminal)
    subprocess.run([real_tmux, '-S', sock, 'kill-server'], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))

try:
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fleet-test', '-x', '160', '-y', '30',
       '-n', 'worker-one', 'sleep 600')
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    w1 = tm('display-message', '-p', '#{window_id}')
    # tmux 3.4 crashes creating a detached window when the GLOBAL size is manual.
    # Only this fixture needs a fixed size; leave new windows on tmux's default.
    tm('set-option', '-w', '-t', w1, 'window-size', 'manual')
    p1 = tm('display-message', '-p', '#{pane_id}')
    tm('set-option', '-w', '-t', w1, '@issue', '1')
    tm('set-option', '-w', '-t', w1, '@wid', 'a1')
    tm('set-option', '-w', '-t', w1, '@claude_state', 'working')
    w2 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', '修复侧栏', 'sleep 600')
    p2 = tm('display-message', '-p', '-t', w2, '#{pane_id}')
    tm('set-option', '-w', '-t', w2, '@raw', '1')
    tm('set-option', '-w', '-t', w2, '@worktree', str(work / 'repo-scratch-2'))
    tm('set-option', '-w', '-t', w2, '@wid', 'b1')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'needs')
    tm('set-option', '-w', '-t', w2, '@claude_needs', 'ask')
    hub = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'plan', 'sleep 600')
    hp = tm('display-message', '-p', '-t', hub, '#{pane_id}')
    tm('set-option', '-p', '-t', hp, '@dash', '1')

    # Load the shipped sidebar wiring, without unrelated status commands/daemons.
    shipped = (bin_dir.parent / 'conf/tmux-attention.conf').read_text()
    # The status-bar tap is bound twice, root and fleet-sidebar (issue #896: the
    # sidebar's `Any` would otherwise swallow it). Multi-line blocks, so they are
    # compared here instead of loaded: the two bodies must never drift apart.
    def status_block(head):
        start = shipped.index(head)
        return shipped[start + len(head):shipped.index('\n}\n', start)]
    # The one allowed difference: the ⌂ from the task bar is the SECOND press of
    # "task bar first" and says so with --nav (issue #899).
    check(status_block('bind -n MouseDown1Status ') ==
          status_block('bind -T fleet-sidebar MouseDown1Status ').replace(' --nav', '', 1),
          'the fleet-sidebar status-bar tap drifted from the root one')
    selected = [line for line in shipped.splitlines() if not line.startswith('#') and
                'MouseDown1Status' not in line and
                ('fleet-sidebar' in line or 'after-select-pane[71]' in line or 'client-detached' in line or
                 'MouseDown1Pane' in line or 'MouseDown1Border' in line or 'DoubleClick1Pane' in line or
                 line.startswith('bind -n F9 ') or
                 line.startswith('set -g pane-border') or line.startswith('set -g default-terminal') or
                 line == 'set -g mouse on')]
    fixture = work / 'sidebar.conf'
    fixture.write_text('\n'.join(selected).replace('~/.claude/fleet', str(bin_dir.parent)) + '\n')
    tm('source-file', str(fixture))
    tm('set-hook', '-g', 'session-window-changed[72]',
       "set-option -wF -t fleet-test: @sidebar_ready_on_select '#{@sidebar_worker}'")

    call()
    check(not views(), 'detached fleets must not create sidebar processes')
    terminal, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
    client_env = {k: v for k, v in env.items() if k not in ('TMUX', 'TMUX_PANE')}
    client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'fleet-test'],
                              env=client_env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    def drain():
        try:
            while os.read(terminal, 65536):
                pass
        except OSError:
            pass
    threading.Thread(target=drain, daemon=True).start()
    wait_for(lambda: bool(view_on(w1)), 'attach hook did not create sidebar')
    # Keep resize fixtures within the attached terminal minus its status bar.
    # A manual height of 30 would put the last pane row under the client's bar.
    window_height = '29'
    tm('resize-window', '-t', w1, '-y', window_height)
    side = view_on(w1)[0]
    side_pid = tm('display-message', '-p', '-t', side, '#{pane_pid}')
    check(Path(tm('display-message', '-p', '-t', side, '#{pane_current_path}')).resolve() == bin_dir.parent.resolve(),
          'a reusable sidebar must not anchor the departed worker worktree')
    check(tm('display-message', '-p', '-t', side, '#{pane_left}:#{pane_width}') == '0:30',
          'sidebar should occupy 30 cells at the left edge')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'split stole worker focus')
    call()
    check(len(views()) == 1, 'sync must be idempotent')
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'sidebar did not render tasks')
    wait_for(lambda: worker_cue(side), 'worker focus cue missing')
    check('worker-one' in tm('capture-pane', '-p', '-t', side).splitlines()[0] or
          '修复侧栏' in tm('capture-pane', '-p', '-t', side).splitlines()[0],
          'sidebar should start with a task, not an internal title row')
    check('WORKER · INPUT' in tm('display-message', '-p', '-t', p1, '#{E:pane-border-format}'),
          'active worker border must identify input focus')
    tm('select-pane', '-t', side)
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'sidebar must not become the agent identity for window-targeted tools')
    check(tm('display-message', '-p', '-t', side, '#{@dash}') == '', 'sidebar masquerades as hub')

    full = row_data(compact=False)
    compact = row_data()
    check(all('a1' not in r[3] and 'b1' not in r[3] for r in compact),
          'sidebar displays internal worker handles instead of task descriptions')
    check(all('a1' not in r[2] and 'b1' not in r[2] for r in full if r[0] != 'hdr'),
          'full hub list displays internal worker handles')
    check(tm('show-options', '-wqv', '-t', w1, '@wid') == 'a1', 'rendering changed the internal worker handle')
    check([r[1] for r in full if r[0] != 'hdr'] == [r[0] for r in compact],
          'sidebar order diverges from hub')
    check(compact[0][0] == w2 and compact[0][2] == '?', 'needs/question cue was lost')
    tm('set-option', '-w', '-t', w1, '@pin', '1')
    check(row_data()[0][0] == w1, 'sidebar ignored hub pin')
    tm('set-option', '-uw', '-t', w1, '@pin')
    tm('set-option', '-w', '-t', w2, '@origin', 'issue-1')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'done')
    check(w2 not in [r[0] for r in row_data()], 'folded child visible without current/needs exemption')
    check(w2 in [r[0] for r in row_data(current=w2)], 'fold hid the current worker')
    tm('set-option', '-w', '-t', w1, '@expand', '1')
    # The hierarchy glyph is its OWN field since #836 (field 5), not spliced into
    # the label — so a 30-column sidebar draws `marker glyph tree label` and every
    # name starts at the same column whatever its depth.
    kid = [r for r in row_data() if r[0] == w2]
    check(bool(kid) and kid[0][4] == '└', 'parent-child tree cell was lost')
    check(bool(kid) and kid[0][3].startswith('修复侧栏'),
          'the label still carries the tree glyph — it belongs in its own field')
    check(all(len(r) == 5 for r in row_data()), 'sidebar rows must carry 5 fields')
    root = [r for r in row_data() if r[0] == w1]
    check(bool(root) and root[0][4] in ('▾', '▸'), 'a holder row must carry its caret in the tree cell')
    cache = work / '.claude-dash/global'
    cache.mkdir(parents=True, exist_ok=True)
    (cache / 'dash_view_fleet-test').write_text('landed')
    check(w1 in [r[0] for r in row_data()], 'hub history toggle hid live sidebar')
    (cache / 'dash_view_fleet-test').unlink()

    # Keyboard input is sent only to the UI; Enter selects by stable window ID.
    wait_for(lambda: '└ 修复侧栏' in tm('capture-pane', '-p', '-t', side), 'fold update did not reach view')
    # `marker glyph tree label` — a root's name and a child's start at the same column.
    pane = [l for l in tm('capture-pane', '-p', '-t', side).split('\n') if '修复侧栏' in l]
    check(bool(pane) and pane[0].index('修复侧栏') == 6,
          'the sidebar name column moved: ' + repr(pane[:1]))
    os.write(terminal, b'\x02E')  # actual prefix E, then terminal arrow + Enter
    wait_for(lambda: 'fleet-sidebar' in tm('list-clients', '-F', '#{client_key_table}'), 'prefix E did not enter sidebar navigation')
    wait_for(lambda: tasks_cue(side),
             'keyboard navigation needs a persistent focus cue')
    check('INPUT' not in tm('display-message', '-p', '-t', p1, '#{E:pane-border-format}'),
          'worker header claims input focus while keys go to sidebar')
    os.write(terminal, b'\x1b[B\r')
    wait_for(lambda: bool(view_on(w2)), 'keyboard jump did not move to second worker')
    check(len(views()) == 1, 'background worker retained a sidebar process')
    check(view_on(w2) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'keyboard navigation recreated the sidebar instead of moving its populated grid')
    check(tm('show-options', '-wqv', '-t', w1, '@sidebar_worker') == '',
          'source window retained sidebar worker metadata after the move')
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_ready_on_select') == p2,
          'destination was selected before its sidebar layout was ready')
    wait_for(lambda: worker_cue(side),
             'Enter did not restore the worker focus cue')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'jump did not focus worker input')
    # A terminal mouse event exercises the shipped root-table forwarding bind.
    side2 = view_on(w2)[0]
    wait_for(lambda: 'worker-one' in tm('capture-pane', '-p', '-t', side2), 'new view not ready')
    tm('move-window', '-d', '-s', w1, '-t', 'fleet-test:9')
    click(side2)
    wait_for(lambda: bool(view_on(w1)), 'single-click did not jump to first row')
    check(view_on(w1) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'mouse navigation recreated the sidebar')
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_worker') == '',
          'mouse move left stale worker metadata')
    check(tm('show-options', '-wqv', '-t', w1, '@sidebar_ready_on_select') == p1,
          'mouse navigation showed a destination without its sidebar')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'click changed worker pane identity')
    wait_for(navigation, 'mouse press/release did not leave arrow keys with the sidebar')
    wait_for(lambda: tasks_cue(side),
             'click did not visibly focus the sidebar')
    check('INPUT' not in tm('display-message', '-p', '-t', p1, '#{E:pane-border-format}'),
          'worker still advertises input focus after a sidebar click')
    check('TASKS · INPUT' in tm('display-message', '-p', '-t', side, '#{E:pane-border-format}'),
          'sidebar border did not advertise keyboard focus')
    # ↑↓ follow (issue #822): an arrow through the key table switches to the
    # highlighted worker once the highlight settles, keeps the client in the
    # sidebar key table and keeps the worker pane active; a burst that ends on
    # the current row never switches. Enter/Esc still hand input back (below).
    tm('set-option', '-g', '@switches', '')
    tm('set-hook', '-g', 'session-window-changed[73]', "set-option -gaF @switches '#{window_id} '")
    switches = lambda: tm('show-options', '-gv', '@switches').split()
    worker_before = tm('capture-pane', '-p', '-t', p1)
    os.write(terminal, b'\x1b[B')
    wait_for(lambda: bool(view_on(w2)), 'Down after a click did not follow to the highlighted worker')
    check(tm('capture-pane', '-p', '-t', p1) == worker_before, 'sidebar arrow leaked into worker input')
    check(view_on(w2) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'follow recreated the sidebar instead of moving its populated grid')
    wait_for(navigation, 'follow did not keep the client in the sidebar key table')
    wait_for(lambda: tasks_cue(side), 'follow lost the navigation cue')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'follow did not keep the worker pane active')
    check('INPUT' not in tm('display-message', '-p', '-t', p2, '#{E:pane-border-format}'),
          'worker advertises input focus after a follow')
    check(switches() == [w2], 'one arrow made %r window switches' % switches())
    os.write(terminal, b'\x1b[A')
    wait_for(lambda: bool(view_on(w1)), 'Up did not follow back to the first worker')
    wait_for(navigation, 'Up follow left the sidebar key table')
    check(switches() == [w2, w1], 'Up follow made %r window switches' % switches())
    # One pty write lands both keys inside the debounce, ending on the current
    # row: a row only passed over is never switched to (nor woken — the wake
    # hook's dwell is the sleep selftest's). Long enough for a wrong follow to show.
    tm('send-keys', '-t', side, 'Down', 'Up')
    time.sleep(1)
    check(switches() == [w2, w1], 'passing over a row switched windows: %r' % switches())
    check(view_on(w1) == [side], 'a pass-over moved the sidebar')
    wait_for(navigation, 'a pass-over left the sidebar key table')
    tm('set-hook', '-gu', 'session-window-changed[73]')

    # The right pane was already tmux-active: clicking it must still leave the
    # navigation table. Actual typing then reaches that pane, not the sidebar.
    click(p1, row=3)
    wait_for(lambda: not navigation(), 'clicking the already-active worker did not leave navigation')
    wait_for(lambda: worker_cue(side),
             'worker click left the sidebar highlighted')
    check('WORKER · INPUT' in tm('display-message', '-p', '-t', p1, '#{E:pane-border-format}'),
          'worker click did not restore its input badge')
    os.write(terminal, b'worker-input-check')
    wait_for(lambda: 'worker-input-check' in tm('capture-pane', '-p', '-t', p1),
             'typing after a worker click did not reach the worker')

    # Double-click on the worker while its sidebar is on screen is the
    # select-word gesture (issue #820), never zoom: the view stays, the window
    # does not zoom, tmux's stock copy lands in a buffer, and copy mode ends.
    for name in tm('list-buffers', '-F', '#{buffer_name}').splitlines():
        tm('delete-buffer', '-b', name)
    text_row = next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', p1).splitlines())
                    if 'worker-input-check' in line)
    click(p1, row=text_row, column=2, count=2)
    wait_for(lambda: copied() and copied() in 'worker-input-check',
             'double-click on the worker did not select-word: buffer=%r' % copied())
    check(zoomed(w1) == '0', 'double-click zoomed the worker and hid its sidebar')
    check(view_on(w1) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'double-click on the worker lost the sidebar view')
    wait_for(lambda: tm('display-message', '-p', '-t', p1, '#{pane_in_mode}') == '0',
             'select-word left the worker in copy mode')
    check(not navigation(), 'double-click on the worker entered sidebar navigation')
    # Zoomed, the sidebar is off screen: the double-click stays the way back.
    tm('resize-pane', '-Z', '-t', p1)
    check(zoomed(w1) == '1', 'worker zoom broken with a sidebar present')
    click(p1, row=text_row, column=2, count=2)
    wait_for(lambda: zoomed(w1) == '0', 'double-click on a zoomed worker did not unzoom it')
    wait_for(lambda: view_on(w1) == [side], 'unzoom by double-click lost the sidebar view')
    check(tm('display-message', '-p', '-t', p1, '#{pane_in_mode}') == '0',
          'double-click on a zoomed worker entered copy mode')

    # Blank space and rapid repeat clicks are focus targets too. The
    # release/double-click events must not silently reset the custom key table.
    click(side, row=8)
    wait_for(navigation, 'clicking sidebar blank space did not enter navigation')
    click(side, row=8, repeat=True)
    click(side, row=8, repeat=True)
    wait_for(lambda: tasks_cue(side),
             'repeat/blank sidebar click lost the focus cue')
    wait_for(navigation, 'repeat/blank sidebar click lost keyboard navigation')
    os.write(terminal, b'\x1b[B\r')
    wait_for(lambda: bool(view_on(w2)), 'click then Down/Enter did not open the selected worker')
    wait_for(lambda: not navigation(), 'Enter after mouse navigation did not return input to worker')
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'sidebar did not follow return to first worker')

    os.write(terminal, b'\x02E')
    wait_for(lambda: tasks_cue(side), 'second navigation entry lost focus cue')
    os.write(terminal, b'\x1b')
    wait_for(lambda: worker_cue(side), 'Escape did not restore input focus')
    check('INPUT' in tm('display-message', '-p', '-t', p1, '#{E:pane-border-format}'),
          'Escape left the worker border dimmed')

    # tmux <=3.6a discards top pane-status clicks before key lookup (its mouse
    # hit test recognizes only right/bottom borders). 3.7+ exposes the top border.
    # Use the server version: it is the server that dispatches mouse events.
    version_text = tm('display-message', '-p', '#{version}')
    if server_version() >= (3, 7):
        click(side, row=-1)
        wait_for(navigation, 'clicking the top border did not enter sidebar navigation')
    else:
        print('selftest NOTE: tmux %s — top-border click unavailable; checking sidebar content click' %
              version_text, flush=True)
        click(side, row=8)
        wait_for(navigation, 'clicking the sidebar did not enter navigation before resize')
    tm('resize-window', '-t', w1, '-x', '100', '-y', window_height)
    wait_for(lambda: not views(), 'narrow screen did not hide sidebar')
    check(not navigation(), 'auto-hidden sidebar retained keyboard focus')
    check('FLEET_SIDEBAR=1' in conf.read_text(), 'auto-hide changed saved preference')
    tm('resize-window', '-t', w1, '-x', '160', '-y', window_height)
    wait_for(lambda: bool(view_on(w1)), 'wide screen did not restore sidebar')
    legacy = view_on(w1)[0]
    tm('set-option', '-p', '-t', legacy, '@sidebar_version', '2')
    call()
    check(view_on(w1) != [legacy] and len(view_on(w1)) == 1,
          'sync must replace a pre-upgrade renderer once before reusing panes')
    side = view_on(w1)[0]
    wait_for(lambda: input_line(side).startswith('›'), 'upgraded view not ready')
    screen = tm('capture-pane', '-p', '-t', side)
    check('Hide' not in screen and 'q hide' not in screen, 'sidebar still paints a click target for hide')
    check('new task' not in screen and 'Keyboard' not in screen and '↑↓' not in screen,
          'the footer hint rows survived: the list must end in ONE input line: ' + repr(screen))

    # ONE input line closes the list (issue #896). Away from the sidebar it is a
    # bare `›`; a tap on it only focuses (no popup, no hide) and shows the dim
    # placeholder.
    wait_for(lambda: worker_cue(side), 'away from the sidebar the input line must be a bare ›')
    height = int(tm('display-message', '-p', '-t', side, '#{pane_height}'))
    def popup_open():
        return tm('show-options', '-gqv', '@popup_open') not in ('', '0')
    click(side, row=height - 1)
    wait_for(navigation, 'tapping the input line did not put the keyboard on the sidebar')
    wait_for(lambda: tasks_cue(side), 'the focused, empty input line must show its placeholder')
    check(not popup_open() and bool(view_on(w1)) and 'FLEET_SIDEBAR=1' in conf.read_text(),
          'tapping the input line opened a popup, hid the view or changed the saved preference')

    # ⌃n (dash-keymap.sh --panel sidebar `new`, and its ⌥n fallback) opens the
    # hub's new-task popup from the sidebar pane (issue #821's action, moved off
    # the letter `n` because letters type now). The popup's title prompt is
    # stubbed — `fzf` on PATH drops a marker and waits — so it provably ran.
    ran = work / 'new-task-ran'
    (shim / 'fzf').write_text('#!/bin/sh\nprintf 1 > ' + shlex.quote(str(ran)) + '\nexec sleep 20\n')
    (shim / 'fzf').chmod(0o755)
    (shim / 'gh').write_text('#!/bin/sh\nexit 1\n')
    (shim / 'gh').chmod(0o755)
    conf.write_text(fleet_conf + 'FLEET_REPO=example/repo\n')
    attached = tm('list-clients', '-t', 'fleet-test', '-F', '#{client_name}').splitlines()[0]
    for chord, label in ((b'\x0e', 'ctrl-n'), (b'\x1bn', 'alt-n (the prefix fallback)')):
        os.write(terminal, chord)
        wait_for(ran.exists, label + ' did not open the new-task popup')
        check(popup_open() and bool(view_on(w1)), label + ' popup hid the sidebar or skipped @popup_open')
        tm('display-popup', '-C', '-c', attached)
        wait_for(lambda: not popup_open(), 'closing the ' + label + ' popup left @popup_open raised')
        ran.unlink()
        wait_for(lambda: tasks_cue(side), 'the input line did not repaint after the ' + label + ' popup')
        check(input_line(side) == '› 新会话名…', label + ' leaked into the input line')
    (shim / 'fzf').unlink()
    (shim / 'gh').unlink()
    conf.write_text(fleet_conf)

    # Typing (issue #896): a click on blank sidebar space, then plain keys, fill
    # the input line — the worker pane stays active and never sees them.
    click(side, row=height - 3)
    wait_for(navigation, 'clicking sidebar blank space did not enter navigation')
    worker_before = tm('capture-pane', '-p', '-t', p1)
    type_keys('demo')
    wait_for(lambda: input_line(side) == '› demo▏', 'typed d e m o did not reach the input line: %r' % input_line(side))
    check(tm('show-options', '-pqv', '-t', side, '@sidebar_input') == '1', 'a typed name did not set @sidebar_input')
    check(tm('capture-pane', '-p', '-t', p1) == worker_before, 'typing into the sidebar leaked into the worker')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'typing made the sidebar the active pane')
    # Esc clears a typed name and KEEPS the keyboard; letters that were commands
    # (q hide, n new task, j/k move) type; backspace deletes.
    os.write(terminal, b'\x1b')
    wait_for(lambda: tasks_cue(side), 'Esc did not clear the typed name')
    check(navigation(), 'Esc on a typed name gave the keyboard back instead of only clearing')
    check(tm('show-options', '-pqv', '-t', side, '@sidebar_input') == '', 'clearing left @sidebar_input set')
    type_keys('qnjk')
    wait_for(lambda: input_line(side) == '› qnjk▏', 'q/n/j/k did not type: %r' % input_line(side))
    check(bool(view_on(w1)) and 'FLEET_SIDEBAR=1' in conf.read_text() and not popup_open(),
          'a letter still acted as a command (q hid / n opened a popup)')
    type_keys('\x7f\x7f\x7f\x7f')
    wait_for(lambda: tasks_cue(side), 'backspace did not delete the typed name')

    # Enter on a name the fleet refuses (the per-fleet cap): the reason shows on
    # the input line, the name stays, nothing spawns, the keyboard stays.
    before = set(windows())
    conf.write_text(fleet_conf + 'FLEET_MAX_SESSIONS=1\n')
    type_keys('demo')
    wait_for(lambda: input_line(side) == '› demo▏', 'typing after the popup test failed')
    os.write(terminal, b'\r')
    wait_for(lambda: input_line(side).startswith('› ✗') and 'capacity' in input_line(side),
             'a refused spawn did not toast its reason: %r' % input_line(side))
    check(set(windows()) == before, 'a refused spawn created a window')
    check(navigation(), 'a refused spawn took the keyboard off the sidebar')
    wait_for(lambda: input_line(side) == '› demo▏', 'the typed name was lost after the refusal toast')
    conf.write_text(fleet_conf)

    # Enter on a name: a scratch session named after it, via the hub's own
    # dash-raw-session.sh — it becomes current, the view moves there, the input
    # line empties, and the NEW agent pane is active with the keyboard.
    os.write(terminal, b'\r')
    wait_for(lambda: set(windows()) - before, 'Enter on a typed name did not spawn a session')
    new = (set(windows()) - before).pop()
    wait_for(lambda: tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}') == new,
             'the spawned session did not become the current window')
    check('demo' in tm('display-message', '-p', '-t', new, '#{window_name}'), 'the new session is not named after the input')
    check(tm('show-options', '-wqv', '-t', new, '@raw') == '1', 'the input line spawned something other than a scratch')
    check(tm('show-options', '-wqv', '-t', new, '@origin') == '',
          'a sidebar spawn nested under the worker it was typed in (must be the hub ⌃s: no @origin)')
    wait_for(lambda: view_on(new) == [side], 'the view did not follow to the new session')
    wait_for(lambda: worker_cue(side), 'the input line did not empty and hand the keyboard back: %r' % input_line(side))
    agent = tm('display-message', '-p', '-t', new, '#{pane_id}')
    check(agent != side and tm('show-options', '-wqv', '-t', new, '@sidebar_worker') == agent,
          'the new session\'s agent pane is not the active one')
    check(not navigation(), 'the keyboard stayed on the sidebar after the spawn')
    check(tm('show-options', '-pqv', '-t', side, '@sidebar_input') == '', 'the spawn left @sidebar_input set')
    spawned = [new]

    # A CJK name arrives whole (UTF-8 bytes through the Any bind) and sits in
    # place: `› ` then the name, no cell drift.
    click(side, row=height - 3)
    wait_for(navigation, 'clicking the moved view did not enter navigation')
    before = set(windows())
    type_keys('修复 demo')
    wait_for(lambda: input_line(side) == '› 修复 demo▏', 'a CJK name was mangled: %r' % input_line(side))
    os.write(terminal, b'\r')
    wait_for(lambda: set(windows()) - before, 'Enter on a CJK name did not spawn a session')
    spawned += list(set(windows()) - before)
    wait_for(lambda: tm('display-message', '-p', '-t', 'fleet-test:', '#{window_name}') == '修复 demo',
             'the CJK session is not current or lost its name')
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view did not come back to the first worker')
    wait_for(lambda: not navigation(), 'the CJK spawn left the keyboard on the sidebar')
    for window in spawned:
        tm('kill-window', '-t', window)

    # Hide is prefix e — from the sidebar's own key table too — never a click and
    # never a letter.
    os.write(terminal, b'\x02E')
    wait_for(navigation, 'prefix E before hiding did not enter sidebar navigation')
    os.write(terminal, b'\x02e')
    wait_for(lambda: not views(), 'prefix e while navigating left a view')
    check(not navigation(), 'hiding retained sidebar keyboard focus')
    check('FLEET_SIDEBAR=0' in conf.read_text(), 'collapse was not saved')
    tm('select-window', '-t', w2)
    call()
    check(not views(), 'switching reopened a manually collapsed sidebar')
    call('toggle')
    wait_for(lambda: bool(view_on(w2)), 'toggle did not reopen sidebar')
    tm('resize-pane', '-Z', '-t', p2)
    check(tm('display-message', '-p', '-t', w2, '#{window_zoomed_flag}') == '1', 'worker zoom broken')
    tm('resize-pane', '-Z', '-t', p2)

    # Enabling while another pane is zoomed must wait, then appear on unzoom.
    call('hide')
    extra = tm('split-window', '-d', '-h', '-t', p2, '-P', '-F', '#{pane_id}', 'sleep 600')
    # Without a sidebar the double-click still zooms (the hub and dash rely on it).
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_worker') == '',
          'hidden sidebar left its worker metadata on the window')
    click(p2, row=3, count=2)
    wait_for(lambda: zoomed(w2) == '1', 'double-click without a sidebar did not zoom the worker')
    call('toggle')
    check(not views(), 'enabling sidebar interrupted a zoomed worker')
    tm('resize-pane', '-Z', '-t', p2)
    wait_for(lambda: bool(view_on(w2)), 'unzoom did not restore the enabled sidebar')
    tm('kill-pane', '-t', extra)

    # Hub/home resolution stays on the original @dash pane — and reaches it on the
    # SECOND press (issue #899): the first F9 in a task with a bar hands the bar
    # the keyboard and stays; the second, bound in the fleet-sidebar table, goes on.
    check(not navigation(), 'fixture should start with the worker holding input')
    os.write(terminal, b'\x1b[20~')  # F9
    wait_for(navigation, 'first F9 did not put the keyboard on the task bar')
    check(tm('display-message', '-p', '#{window_id}') == w2, 'first F9 left the task')
    os.write(terminal, b'\x1b[20~')  # F9 again, now in the fleet-sidebar table
    wait_for(lambda: not views(), 'hub should not have a worker sidebar')
    check(tm('display-message', '-p', '-t', 'fleet-test:', '#{pane_id}') == hp,
          'home went to a sidebar instead of hub')
    foreign = tm('new-session', '-d', '-s', 'adhoc', '-P', '-F', '#{window_id}', 'sleep 600')
    tm('set-option', '-w', '-t', foreign, '@issue', '99')
    check(foreign not in [r[0] for r in row_data()], 'another session leaked into sidebar')
    result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'toggle', 'adhoc'])
    check(not (work / 'conf/fleets/adhoc/conf').exists(), 'ad-hoc session was turned into a fleet')
    adhoc_conf = work / 'conf/fleets/adhoc/conf'
    adhoc_conf.parent.mkdir(parents=True)
    adhoc_conf.write_text('FLEET_SIDEBAR=1\n')
    command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'toggle', 'adhoc'])
    check(adhoc_conf.read_text() == 'FLEET_SIDEBAR=1\n', 'a matching conf on the wrong socket was treated as a fleet')

    # Drive the real stuck_check function with a deterministic clock and real
    # pane captures. Sidebar repaints keep window_activity fresh; only changes
    # to the worker's own screen may reset the stale-worker timer.
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'activity fixture needs a sidebar')
    spin_bin = work / 'spin-bin'
    spin_bin.mkdir()
    (spin_bin / 'classify-sessions.sh').write_text('#!/bin/sh\nexit 0\n')
    (spin_bin / 'classify-sessions.sh').chmod(0o755)
    source = (bin_dir / 'tmux-spinner.sh').read_text()
    body = source[source.index("STUCK_STRIKES='|'"):source.index('# --- stale-`needs` reconcile')]
    script = work / 'activity.sh'
    script.write_text("set -u\nNL='\n'\nSOCKETS=fleet-test\nSTUCK_SECS=5\n" +
        'BIN=' + shlex.quote(str(spin_bin)) + '\nSTUCK_LOG=' + shlex.quote(str(work / 'stuck.log')) + '\n' +
        'fake_now=100\ndate() { if [ "$1" = +%s ]; then echo "$fake_now"; else command date "$@"; fi; }\n' +
        body + '\n' + r'''
state() { tmux display-message -p -t "$worker_window" '#{@claude_state}'; }
stuck_check
[ "$(state)" = working ] || exit 10
fake_now=106; stuck_check
[ "$(state)" = working ] || exit 11
# A real worker screen change must cancel that first stale strike.
tmux respawn-pane -k -t "$worker_pane" 'printf fresh-worker-output; exec sleep 600'
i=0
while ! tmux capture-pane -p -t "$worker_pane" | grep -q fresh-worker-output; do
  i=$((i+1)); [ "$i" -lt 100 ] || exit 12; sleep 0.05
done
fake_now=107; stuck_check
[ "$(state)" = working ] || exit 13
fake_now=113; stuck_check
[ "$(state)" = working ] || exit 14
fake_now=114; stuck_check
[ "$(state)" = done ] || exit 15
''')
    result = subprocess.run(['sh', str(script)], env=dict(env, worker_window=w1, worker_pane=p1),
                            text=True, capture_output=True, timeout=15)
    check(result.returncode == 0, 'sidebar broke stale-worker detection: ' + result.stderr + str(result.returncode))

    # Close the agent while its sidebar is present: the view must not keep an
    # otherwise dead worker window alive (nor touch the neighbouring worker).
    tm('select-window', '-t', w2)
    wait_for(lambda: bool(view_on(w2)), 'sidebar did not follow worker selection')
    tm('kill-pane', '-t', p2)
    wait_for(lambda: w2 not in tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines(),
             'sidebar kept a closed worker window alive')
    check(w1 in tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines(),
          'sidebar cleanup closed an unrelated worker')

    tm('set-option', '-g', '@popup_open', str(int(time.time())))
    client.terminate()
    client.wait(timeout=5)
    wait_for(lambda: not views(), 'detach left sidebar refresh processes')
    check(tm('show-options', '-gv', '@popup_open') == '0', 'sidebar detach hook displaced popup cleanup')
    print('selftest PASS: sidebar (%d checks), isolated tmux layout/input/lifecycle and shared rows' % checks)
finally:
    cleanup()
PY
