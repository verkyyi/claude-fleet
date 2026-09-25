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
os.environ['FLEET_UI_LANG'] = 'zh'
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
# The input line's editor (issue #1097): a cursor, readline's moves and kills.
Line = sidebar.Line
line = Line('ab'); line.left(); line.insert('c')
assert (line.text, line.pos) == ('acb', 2)
line.home(); assert line.pos == 0; line.end(); assert line.pos == 3
line.home(); line.backspace(); assert line.text == 'acb'  # nothing before the cursor
line.delete(); assert (line.text, line.pos) == ('cb', 0)
line = Line('foo bar  baz'); line.word_left(); assert line.pos == 9
line.word_left(); assert line.pos == 4
line.word_right(); assert line.pos == 7
line.kill_eol(); assert line.text == 'foo bar'
line.kill_word(); assert (line.text, line.pos) == ('foo ', 4)
line = Line('新会话 测试'); line.word_left(); line.insert('x')
assert line.text == '新会话 x测试' and line.view(30) == '新会话 x▏测试'
# CJK takes two cells: the cursor keeps its place in a view too narrow for all.
line = Line('修复仪表盘侧栏'); line.pos = 3
assert line.view(7) == '复仪▏表', line.view(7)
line.end(); assert line.view(7) == '盘侧栏▏'; line.home(); assert line.view(7) == '▏修复仪'
assert Line('abc').view(9) == 'abc▏' and Line().view(5) == '▏'
# The keys' double meaning: ←→ Home End edit only a NON-empty line — on an empty
# one they are the list's fold / first-last row. ↑↓ never edit; ⌃ keys always do.
import curses
for key in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_HOME, curses.KEY_END):
    assert sidebar.edit_of(key, '') == '' and sidebar.edit_of(key, 'x'), key
assert sidebar.edit_of(curses.KEY_UP, 'x') == '' and sidebar.edit_of(curses.KEY_DOWN, 'x') == ''
assert [sidebar.edit_of(k, '') for k in (1, 5, 23, 11, 21)] == \
    ['home', 'end', 'kill_word', 'kill_eol', 'clear']
assert sidebar.edit_of(sidebar.WORD_LEFT, '') == 'word_left' and sidebar.edit_of(ord('a'), 'x') == ''

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
           FLEET_HUB_VISITS_LOGDIR=str(work / 'logs'), TERM='xterm-256color',
           FLEET_UI_LANG='zh')
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

# Focus on a pane's top line is COLOUR ONLY (issue #999): the focused style is
# the bg, and the words never change with focus — so no label jumps in or out.
WORKER_FOCUS = 'bg=#7aa2f7'
TASKS_FOCUS = 'bg=#e0af68'

def border(pane):
    return tm('display-message', '-p', '-t', pane, '#{E:pane-border-format}')

def border_text(pane):
    return re.sub(r'#\[[^]]*\]', '', border(pane))

def windows():
    return tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines()

def server_version():
    found = re.search(r'(\d+)\.(\d+)', tm('display-message', '-p', '#{version}'))
    return tuple(map(int, found.groups())) if found else (0, 0)

def type_keys(text):
    """Type into the attached terminal as a burst: ONE write, as an IME commit
    (「你好世界」 in one go) or a paste-speed typist sends it. Every key must
    land in the sidebar on every supported tmux (issue #1098) — see
    ARCHITECTURE.md for the two mechanisms that make that hold on < 3.7."""
    os.write(terminal, text.encode())

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
    # Movement keys never fork (issue #1033): each goes straight to the view at
    # `{top-left}` behind the same @sidebar gate as `Any`, and all six bodies are
    # one body with the key swapped — so a fix to one cannot miss the others.
    moves = ('Up', 'Down', 'Home', 'End', 'Left', 'Right')
    move_body = {}
    for line in shipped.splitlines():
        parts = line.split(' ', 4)
        if line.startswith('bind -T fleet-sidebar ') and len(parts) == 5 and parts[3] in moves:
            move_body[parts[3]] = parts[4].replace(' ' + parts[3] + ' }', ' KEY }')
    check(sorted(move_body) == sorted(moves), 'a sidebar movement bind is missing: %r' % sorted(move_body))
    check(len(set(move_body.values())) == 1, 'sidebar movement binds drifted apart: %r' % move_body)
    check(all('run-shell' not in body and "send-keys -t '{top-left}' KEY" in body
              for body in move_body.values()),
          'a sidebar movement bind forks a shell again: %r' % move_body.get('Up'))
    swc = next(line for line in shipped.splitlines()
               if line.startswith('set-hook -g session-window-changed[71] '))
    swc_skip = swc.split("if -F '", 1)[1].split("'", 1)[0] if "if -F '" in swc else ''
    check(swc_skip.startswith('#{?') and 'fleet-sidebar.sh sync' in swc,
          'session-window-changed sync lost its already-there fast path')
    selected = [line for line in shipped.splitlines() if not line.startswith('#') and
                'MouseDown1Status' not in line and
                ('fleet-sidebar' in line or 'after-select-pane[71]' in line or 'client-detached' in line or
                 'MouseDown1Pane' in line or 'MouseDown1Border' in line or 'DoubleClick1Pane' in line or
                 line.startswith('bind -n F9 ') or line.startswith('bind -n C-M-S-F12 ') or
                 line.startswith('bind z ') or line.startswith('bind [ ') or
                 line.startswith('set -g pane-border') or line.startswith('set -g default-terminal') or
                 line.startswith('set -g assume-paste-time ') or
                 line == 'set -g mouse on')]
    fixture = work / 'sidebar.conf'
    # `run-shell "sh …hub-zoom.sh"` (the F9 binds): production /bin/sh is bash in
    # POSIX mode, but CI's is dash, which has no `set -o pipefail` and aborts the
    # script — drive it the way hub-zoom-home-selftest.sh does (issue #414).
    fixture.write_text('\n'.join(selected).replace('~/.claude/fleet', str(bin_dir.parent))
                       .replace('run-shell "sh ', 'run-shell "bash --posix ') + '\n')
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
    # A tmux menu is a client overlay that capture-pane never shows, so keep
    # what the attached terminal was sent (issue #898): `painted()` reads it.
    screen_out = bytearray()
    def drain():
        try:
            while True:
                chunk = os.read(terminal, 65536)
                if not chunk:
                    return
                screen_out.extend(chunk)
                if len(screen_out) > 1 << 20:
                    del screen_out[:1 << 19]
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
    check(WORKER_FOCUS in border(p1),
          'active worker border must identify input focus')
    check('INPUT' not in border_text(p1) + border_text(side), 'a border still names its focus')
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
    # The 置顶 group (issue #1170): its heading, then the pinned row — bare, no
    # `* ` — then ONE inert rule the view clips to its width.
    pinned = row_data()
    check(pinned[0][:2] == ['hdr', 'pin'] and pinned[0][3] == '置顶 (1)', 'no 置顶 heading above the pin')
    check(pinned[1][0] == w1, 'sidebar ignored hub pin')
    check(not pinned[1][3].startswith('* '), 'a pinned row still wears the old `* ` mark')
    check(pinned[2][:2] == ['hdr', ''] and set(pinned[2][3]) == {'─'}, 'no rule closes the 置顶 group')
    check(sum(1 for r in pinned if r[0] == 'hdr' and r[3].startswith('─')) == 1, 'more than one rule')
    check(sidebar.key_of(pinned[0]) == 'hdr:pin' and sidebar.key_of(pinned[2]) == 'hdr',
          'the 置顶 heading must be a fold stop and the rule never a cursor stop')
    check(sidebar.tap('hdr:pin', 'hdr:pin') == 'select' and sidebar.placeholder('hdr:pin') == sidebar.PLACEHOLDER,
          'the 置顶 heading names no repo: a tap only selects it')
    tm('set-option', '-uw', '-t', w1, '@pin')
    check(not any(r[0] == 'hdr' for r in row_data()), 'the 置顶 frame outlived the pin')
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
    check(WORKER_FOCUS not in border(p1),
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
    check(WORKER_FOCUS not in border(p1),
          'worker still advertises input focus after a sidebar click')
    check(TASKS_FOCUS in border(side),
          'sidebar border did not advertise keyboard focus')
    nav_text = [border_text(p1), border_text(side)]
    # ↑↓ follow (issue #822): an arrow through the key table switches to the
    # highlighted worker once the highlight settles, keeps the client in the
    # sidebar key table and keeps the worker pane active; a burst that ends on
    # the current row never switches. Enter/Esc still hand input back (below).
    tm('set-option', '-g', '@switches', '')
    tm('set-hook', '-g', 'session-window-changed[73]', "set-option -gaF @switches '#{window_id} '")
    switches = lambda: tm('show-options', '-gv', '@switches').split()
    worker_before = tm('capture-pane', '-p', '-t', p1)
    started = time.monotonic()
    os.write(terminal, b'\x1b[B')
    wait_for(lambda: bool(view_on(w2)), 'Down after a click did not follow to the highlighted worker')
    # Informational (issue #1033): the arrow → switched latency on this box.
    print('sidebar timing: Down → view on the next worker in %.2fs' % (time.monotonic() - started))
    check(tm('capture-pane', '-p', '-t', p1) == worker_before, 'sidebar arrow leaked into worker input')
    check(view_on(w2) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'follow recreated the sidebar instead of moving its populated grid')
    wait_for(navigation, 'follow did not keep the client in the sidebar key table')
    wait_for(lambda: tasks_cue(side), 'follow lost the navigation cue')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'follow did not keep the worker pane active')
    check(WORKER_FOCUS not in border(p2),
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

    # The window-changed fast path (issue #1033): a window that already holds a
    # live view naming its worker skips the sync fork; one without a view syncs.
    check(tm('display-message', '-p', '-t', w1, swc_skip) == '',
          'the hook would re-sync a window the jump already moved the view into')
    check(tm('display-message', '-p', '-t', w2, swc_skip) == '1',
          'the hook would skip the sync for a window with no view')

    # The row producer runs BESIDE the UI loop (issue #1033): with it stalled,
    # an arrow still moves the highlight, the follow still switches, and the
    # moved view repaints `▶` on its new row from the rows it already has.
    stall = work / 'rows-stall'
    rows_bin = bin_dir / 'tmux-dashboard-rows.sh'
    (bin_dir / 'tmux-dashboard-rows-real.sh').symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    staged = work / 'rows-wrapper'
    staged.write_text('#!/bin/bash\nn=0\nwhile [ -f %s ] && [ $n -lt 300 ]; do sleep .1; n=$((n+1)); done\n'
                      'exec bash %s "$@"\n' % (shlex.quote(str(stall)),
                                               shlex.quote(str(bin_dir / 'tmux-dashboard-rows-real.sh'))))
    stall.write_text('')
    os.replace(staged, rows_bin)
    time.sleep(1.5)  # the view's next refresh is now stuck in the producer
    started = time.monotonic()
    os.write(terminal, b'\x1b[B')
    wait_for(lambda: bool(view_on(w2)), 'a stalled producer blocked the arrow follow')
    moved = time.monotonic() - started
    wait_for(lambda: any(l.startswith('▶') and '修复侧栏' in l
                         for l in tm('capture-pane', '-p', '-t', side).splitlines()),
             'the moved view did not repaint ▶ from its cached rows')
    repainted = time.monotonic() - started
    check(stall.exists(), 'the producer stall ended before the repaint was checked')
    check(repainted < 3, 'input waited on the row producer: follow %.2fs, repaint %.2fs' % (moved, repainted))
    stall.unlink()
    rows_bin.unlink()
    rows_bin.symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    (bin_dir / 'tmux-dashboard-rows-real.sh').unlink()
    os.write(terminal, b'\x1b[A')
    wait_for(lambda: bool(view_on(w1)), 'Up did not follow back after the stalled-producer leg')
    wait_for(navigation, 'the stalled-producer leg left the sidebar key table')

    # Degenerate case (a one-repo fleet, no repos/ overlay): the async producer
    # paints exactly what the painter always has — `marker glyph tree label`,
    # one row per producer row, `▶` on the window in view.
    def painted_rows():
        want = []
        for wid, state, glyph, label, tree in row_data(current=w1):
            text = label if wid == 'hdr' else (
                ('▶' if wid == w1 else ' ') + ' ' + glyph + ' ' + (tree or ' ') + ' ' + label)
            want.append(sidebar.clip(text, 29).rstrip())
        return want
    # A working row's glyph is the spinner, which animates between the two reads:
    # compare every cell but that one.
    spin = lambda l: l[:2] + '*' + l[3:] if l[:1] in ('▶', ' ') and len(l) > 3 else l
    def same_frame():
        lines = [spin(l.rstrip()) for l in tm('capture-pane', '-p', '-t', side).splitlines()]
        want = [spin(l) for l in painted_rows()]
        return lines[:len(want)] == want and not any(l.strip() for l in lines[len(want):-2])
    wait_for(same_frame, 'a one-repo sidebar frame differs from its rows: %r' % painted_rows())

    # The right pane was already tmux-active: clicking it must still leave the
    # navigation table. Actual typing then reaches that pane, not the sidebar.
    click(p1, row=3)
    wait_for(lambda: not navigation(), 'clicking the already-active worker did not leave navigation')
    wait_for(lambda: worker_cue(side),
             'worker click left the sidebar highlighted')
    check(WORKER_FOCUS in border(p1),
          'worker click did not restore its input badge')
    check([border_text(p1), border_text(side)] == nav_text,
          'border text changed with focus: %r != %r' % ([border_text(p1), border_text(side)], nav_text))
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
    # The sidebar/worker divider is the sidebar's border, so its double-click
    # runs through navigation — and must still zoom the worker (issue #823).
    divider = int(tm('display-message', '-p', '-t', side, '#{pane_width}'))
    click(side, row=5, column=divider, count=2)
    wait_for(lambda: zoomed(w1) == '1', 'double-click on the divider did not zoom the worker')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'double-click on the divider zoomed the sidebar, not the worker')
    check(not navigation(), 'double-click on the divider left sidebar navigation on')
    tm('resize-pane', '-Z', '-t', p1)
    wait_for(lambda: view_on(w1) == [side] and
             tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
             'unzoom after a divider double-click lost the sidebar view')

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
    check(WORKER_FOCUS in border(p1),
          'Escape left the worker border dimmed')

    # A pointer MOVE keeps navigation (issue #925). Claude Code asks for
    # any-motion tracking, so every nudge of the mouse arrives as a motion
    # report — tmux has no bindable name for it, so it lands on `Any`. The
    # worker requests 1003+SGR here (written to its pty as if it printed it).
    def worker_tracking(on):
        with open(tm('display-message', '-p', '-t', p1, '#{pane_tty}'), 'w') as tty:
            tty.write('\x1b[?1003%s\x1b[?1006%s' % ((on and 'h') or 'l', (on and 'h') or 'l'))
    worker_tracking(True)
    wait_for(lambda: tm('display-message', '-p', '-t', p1, '#{mouse_all_flag}') == '1',
             'the worker never turned on any-motion tracking')
    os.write(terminal, b'\x02E')
    wait_for(navigation, 'prefix E did not enter navigation before the mouse move')
    # The key table flips at once; the view paints its cue on its own clock. Wait
    # for the cue BEFORE the move, or a slow paint reads as the move dropping it.
    wait_for(lambda: tasks_cue(side), 'prefix E did not paint the task highlight before the mouse move')
    mx = int(tm('display-message', '-p', '-t', p1, '#{pane_left}')) + 10
    for my in (3, 4, 5):
        os.write(terminal, ('\x1b[<35;%d;%dM' % (mx, my)).encode())
    time.sleep(.5)
    check(navigation(), 'a mouse move over the worker dropped sidebar navigation')
    check(tasks_cue(side), 'a mouse move over the worker dropped the task highlight')
    # A right-click on the worker still hands the keyboard back.
    os.write(terminal, ('\x1b[<2;%d;4M\x1b[<2;%d;4m' % (mx, mx)).encode())
    wait_for(lambda: not navigation(), 'a right-click on the worker did not leave navigation')
    wait_for(lambda: worker_cue(side), 'a right-click on the worker left the sidebar highlighted')
    worker_tracking(False)

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
    # ⌃o (`restore`, issue #901) opens the restore picker the same way; its fzf
    # is the same stub. A bare ⌃o is VDISCARD to a macOS tty — only a view that
    # switched it off ever sees the byte, which is what this pins.
    for chord, label in ((b'\x0e', 'ctrl-n'), (b'\x1bn', 'alt-n (the prefix fallback)'),
                         (b'\x0f', 'ctrl-o'), (b'\x1bo', 'alt-o (the prefix fallback)')):
        os.write(terminal, chord)
        wait_for(ran.exists, label + ' did not open its popup')
        check(popup_open() and bool(view_on(w1)), label + ' popup hid the sidebar or skipped @popup_open')
        tm('display-popup', '-C', '-c', attached)
        wait_for(lambda: not popup_open(), 'closing the ' + label + ' popup left @popup_open raised')
        ran.unlink()
        wait_for(lambda: tasks_cue(side), 'the input line did not repaint after the ' + label + ' popup')
        check(input_line(side) == '› 新会话名…', label + ' leaked into the input line')
    (shim / 'fzf').unlink()
    (shim / 'gh').unlink()
    conf.write_text(fleet_conf)

    # The `? 快捷键` row (issue #948) sits right above the input line. A tap on
    # it, or `?` on an EMPTY input line, opens the sidebar's own key sheet
    # (fleet-keys.sh --context sidebar) in a popup that raises @popup_open; q
    # closes it, clears the flag, and the keyboard is still on the sidebar.
    lines = tm('capture-pane', '-p', '-t', side).splitlines()
    check(len(lines) >= 2 and lines[-2].strip() == '? 快捷键',
          'the row above the input line is not the ? row: %r' % lines[-2:])
    # A Chinese IME's full-width ？ is the same key (issue #965).
    for how in ('a tap on the ? row', '? on an empty input line', '？ on an empty input line'):
        del screen_out[:]
        if how.startswith('a tap'):
            click(side, row=height - 2)
        else:
            os.write(terminal, how.split()[0].encode())
        wait_for(popup_open, how + ' did not open a popup')
        wait_for(lambda: '任务栏快捷键' in bytes(screen_out).decode('utf-8', 'replace'),
                 how + ' did not show the sidebar key sheet')
        check(bool(view_on(w1)), how + ' hid the sidebar')
        os.write(terminal, b'q')
        wait_for(lambda: not popup_open(), 'q on the sidebar key sheet left @popup_open raised')
        wait_for(lambda: navigation() and tasks_cue(side),
                 'after ' + how + ' the keyboard did not return to the sidebar')
        check(input_line(side) == '› 新会话名…', how + ' typed into the input line')
    # Inside a name `?` is a character: it types, and nothing opens.
    type_keys('ab?')
    wait_for(lambda: input_line(side) == '› ab?▏', '? inside a name did not type: %r' % input_line(side))
    time.sleep(.5)
    check(not popup_open(), '? inside a name opened the key sheet')
    os.write(terminal, b'\x1b')
    wait_for(lambda: tasks_cue(side), 'Esc did not clear the ab? name')

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
    # A cursor on the input line (issue #1097): ←→ Home End ⌥←→ ⌃a ⌃e ⌃w ⌃k
    # edit in place, as on Claude's prompt — and the worker sees none of them.
    worker_before = tm('capture-pane', '-p', '-t', p1)
    def line_is(want, why):
        wait_for(lambda: input_line(side) == ('› ' + want).rstrip(),
                 why + ': %r' % input_line(side))
    for keys, want, why in (
            (b'ab', 'ab▏', 'a b did not type'),
            (b'\x1b[D', 'a▏b', '← on a typed name did not move the cursor'),
            (b'c', 'ac▏b', 'a key typed after ← did not insert at the cursor'),
            (b'\x1b[H', '▏acb', 'Home on a typed name did not go to the line start'),
            (b'\x1b[F', 'acb▏', 'End on a typed name did not go to the line end'),
            (b'\x01', '▏acb', '⌃a did not go to the line start'),
            (b'\x1b[C', 'a▏cb', '→ on a typed name did not move the cursor'),
            (b'\x05', 'acb▏', '⌃e did not go to the line end'),
            (b'\x15foo bar baz', 'foo bar baz▏', '⌃u + typing did not refill the line'),
            (b'\x17', 'foo bar ▏', '⌃w did not delete the word before the cursor'),
            (b'\x1bb', 'foo ▏bar ', '⌥← (ESC b) did not move a word left'),
            (b'\x1b[1;3D', '▏foo bar ', '⌥← (ESC[1;3D) did not move a word left'),
            (b'\x1bf', 'foo▏ bar ', '⌥→ (ESC f) did not move a word right'),
            (b'\x1b[1;3C', 'foo bar▏ ', '⌥→ (ESC[1;3C) did not move a word right'),
            (b'\x1bb\x0b', 'foo ▏', '⌃k did not delete to the line end')):
        os.write(terminal, keys)
        line_is(want, why)
    check(navigation(), 'the editing keys gave the keyboard back')
    check(tm('capture-pane', '-p', '-t', p1) == worker_before, 'an editing key leaked into the worker')
    # CJK: the cursor lands between the right characters — the go-live evidence.
    os.write(terminal, b'\x15')
    type_keys('新会话 测试')
    os.write(terminal, b'\x1bb')
    line_is('新会话 ▏测试', '⌥← did not move over a CJK word')
    type_keys('x')
    line_is('新会话 x▏测试', 'a key typed mid-CJK landed in the wrong place')
    if os.environ.get('FLEET_SIDEBAR_EVIDENCE'):
        Path(os.environ['FLEET_SIDEBAR_EVIDENCE'], 'cursor.txt').write_text(
            tm('capture-pane', '-p', '-t', side) + '\n')
    os.write(terminal, b'\x15')
    wait_for(lambda: tasks_cue(side), '⌃u did not clear the edited line')
    # An IME commit (issue #1098): 「你好世界」 in ONE write lands whole on the
    # input line and not a character of it on the worker — on tmux < 3.7 too,
    # where only assume-paste-time 0 + the root `Any` keep the later keys here.
    worker_before = tm('capture-pane', '-p', '-t', p1)
    type_keys('你好世界')
    wait_for(lambda: input_line(side) == '› 你好世界▏',
             'an IME commit did not land whole on the input line: %r' % input_line(side))
    time.sleep(.3)
    worker_now = tm('capture-pane', '-p', '-t', p1)
    # FLEET_SIDEBAR_EVIDENCE=<dir>: keep both panes as they stand (fleet-evidence.sh).
    if os.environ.get('FLEET_SIDEBAR_EVIDENCE'):
        for name, pane in (('sidebar', side), ('worker', p1)):
            Path(os.environ['FLEET_SIDEBAR_EVIDENCE'], name + '.txt').write_text(
                tm('capture-pane', '-p', '-t', pane) + '\n')
    check(worker_now == worker_before and not any(c in worker_now for c in '你好世界'),
          'an IME commit leaked into the worker: %r' % worker_now.splitlines()[-3:])
    # Handed back (Esc clears, Esc again returns the keyboard), the root `Any`
    # lets go: the same burst reaches the worker, and the input line stays empty.
    os.write(terminal, b'\x1b')
    wait_for(lambda: tasks_cue(side), 'Esc did not clear the IME commit')
    os.write(terminal, b'\x1b')
    wait_for(lambda: not navigation(), 'Esc on an empty input line kept the keyboard')
    type_keys('你好世界')
    wait_for(lambda: '你好世界' in tm('capture-pane', '-p', '-t', p1),
             'after the hand-back an IME commit did not reach the worker')
    # The view repaints its cue on a 1s poll of the key table — wait it out.
    wait_for(lambda: worker_cue(side), 'the input line did not return to the worker cue: %r' % input_line(side))
    check(not navigation() and not any(c in input_line(side) for c in '你好世界'),
          'after the hand-back the root Any pulled a key into the sidebar: %r' % input_line(side))
    tm('send-keys', '-t', p1, 'C-u')
    click(side, row=height - 3)
    wait_for(navigation, 'clicking sidebar blank space did not re-enter navigation')

    # A terminal paste (issue #1105). Bracketed (ESC[200~ … ESC[201~), tmux
    # forwards it to the CLIENT's pane before any key table — the two `Any`
    # binds above never see it. While the keyboard is here the client's OWN pane
    # is the view (`refresh-client -f active-pane` + a client-level select-pane,
    # set by every take), so the paste lands on the input line; the WINDOW's
    # active pane — what every background script resolves — stays the worker.
    def paste(text):
        os.write(terminal, b'\x1b[200~' + text.encode() + b'\x1b[201~')
    def pinned():
        return 'active-pane' in tm('list-clients', '-F', '#{client_flags}')
    with open(tm('display-message', '-p', '-t', p1, '#{pane_tty}'), 'w') as tty:
        tty.write('\x1b[?2004h')   # the worker asks for bracketed paste, as Claude does
    wait_for(pinned, 'taking the keyboard did not pin the client to the view')
    worker_before = tm('capture-pane', '-p', '-t', p1)
    paste('issue 12 修登录')
    wait_for(lambda: input_line(side) == '› issue 12 修登录▏',
             'a paste did not land on the input line: %r' % input_line(side))
    time.sleep(.3)
    worker_now = tm('capture-pane', '-p', '-t', p1)
    if os.environ.get('FLEET_SIDEBAR_EVIDENCE'):
        for name, pane_ in (('paste-sidebar', side), ('paste-worker', p1)):
            Path(os.environ['FLEET_SIDEBAR_EVIDENCE'], name + '.txt').write_text(
                tm('capture-pane', '-p', '-t', pane_) + '\n')
    check(worker_now == worker_before and 'issue 12' not in worker_now,
          'a paste leaked into the worker: %r' % worker_now.splitlines()[-3:])
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'routing the paste to the view changed the window\'s active pane')
    check(navigation(), 'a paste gave the keyboard back')
    # A pasted paragraph is ONE name: line breaks become spaces and nothing is
    # submitted at them; the paste's own trailing newline is dropped.
    os.write(terminal, b'\x15')
    wait_for(lambda: tasks_cue(side), '⌃u did not clear the pasted line')
    before = set(windows())
    paste('issue 12\n修登录\n')
    wait_for(lambda: input_line(side) == '› issue 12 修登录▏',
             'a multi-line paste did not land as one line: %r' % input_line(side))
    time.sleep(.3)
    check(set(windows()) == before, 'a multi-line paste submitted the line')
    # Handed back (⌃u, Esc), the pin goes with the keyboard: the same paste
    # reaches the worker — still bracketed — and the input line stays empty.
    os.write(terminal, b'\x15')
    wait_for(lambda: tasks_cue(side), '⌃u did not clear the multi-line paste')
    os.write(terminal, b'\x1b')
    wait_for(lambda: not navigation(), 'Esc on an empty input line kept the keyboard (paste leg)')
    wait_for(lambda: not pinned(), 'handing the keyboard back left the client pinned to the view')
    paste('issue 12 修登录')
    wait_for(lambda: 'issue 12 修登录' in tm('capture-pane', '-p', '-t', p1),
             'after the hand-back a paste did not reach the worker')
    check('200~' in tm('capture-pane', '-p', '-t', p1), 'the worker\'s paste lost its brackets')
    wait_for(lambda: worker_cue(side), 'the input line did not return to the worker cue after the paste hand-back')
    check('issue 12' not in input_line(side), 'after the hand-back a paste was pulled into the sidebar')
    tm('send-keys', '-t', p1, 'C-u')
    # A follow moves the view with join-pane, and tmux forgets a moved pane's
    # client entries: the view re-pins itself after the jump, so a paste right
    # after ↓ lands on it in the NEW window, not on that window's worker.
    click(side, row=height - 3)
    wait_for(navigation, 'clicking sidebar blank space did not re-enter navigation (follow paste leg)')
    wait_for(pinned, 'a click on the sidebar did not pin the client to the view')
    os.write(terminal, b'\x1b[B')
    wait_for(lambda: bool(view_on(w2)), 'Down did not follow to the second worker (follow paste leg)')
    wait_for(navigation, 'the follow left the sidebar key table (follow paste leg)')
    time.sleep(.3)
    paste('issue 12 修登录')
    wait_for(lambda: input_line(side) == '› issue 12 修登录▏',
             'after a follow the paste did not land on the moved view: %r' % input_line(side))
    time.sleep(.3)
    check('issue 12' not in tm('capture-pane', '-p', '-t', p2), 'after a follow the paste leaked into the new worker')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'the re-pin changed the new window\'s active pane')
    os.write(terminal, b'\x15')
    wait_for(lambda: tasks_cue(side), '⌃u did not clear the pasted line (follow paste leg)')
    os.write(terminal, b'\x1b[A')
    wait_for(lambda: bool(view_on(w1)), 'Up did not follow back (follow paste leg)')
    wait_for(navigation, 'Up follow left the sidebar key table (follow paste leg)')
    # prefix z from the sidebar zooms the WORKER and hands the keyboard back —
    # tmux's stock resize-pane -Z would zoom the pinned view and, worse, make it
    # the window's active pane. prefix [ is bound the same way.
    os.write(terminal, b'\x02z')
    wait_for(lambda: zoomed(w1) == '1', 'prefix z from the sidebar did not zoom')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'prefix z from the sidebar zoomed the view, not the worker')
    wait_for(lambda: not navigation() and not pinned(), 'prefix z left the keyboard (or the pin) on the sidebar')
    os.write(terminal, b'\x02z')
    wait_for(lambda: zoomed(w1) == '0', 'prefix z did not unzoom')
    wait_for(lambda: view_on(w1) == [side], 'unzoom after prefix z lost the sidebar view')
    # A prefix command with no hand-back of its own (prefix i, display-message)
    # leaves the table pinned; the view's 1s reconcile drops the pin, and the
    # root `Any` drops it on the first key regardless — typing reaches the worker.
    click(side, row=height - 3)
    wait_for(navigation, 'clicking sidebar blank space did not re-enter navigation (prefix i leg)')
    wait_for(pinned, 'a click on the sidebar did not pin the client (prefix i leg)')
    os.write(terminal, b'\x02i')
    wait_for(lambda: not navigation(), 'prefix i did not leave the sidebar key table')
    wait_for(lambda: not pinned(), 'the reconcile did not drop the pin after prefix i')
    type_keys('after-prefix-i')
    wait_for(lambda: 'after-prefix-i' in tm('capture-pane', '-p', '-t', p1),
             'after prefix i typing did not reach the worker')
    check('after-prefix-i' not in input_line(side), 'after prefix i typing was pulled into the sidebar')
    tm('send-keys', '-t', p1, 'C-u')
    with open(tm('display-message', '-p', '-t', p1, '#{pane_tty}'), 'w') as tty:
        tty.write('\x1b[?2004l')
    click(side, row=height - 3)
    wait_for(navigation, 'clicking sidebar blank space did not re-enter navigation (after the paste legs)')

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

    # The row menu (issue #898): `.` on an EMPTY input line, or a tap on the
    # highlighted row (the second tap on a row the first one switched to), opens
    # a tmux display-menu of the hub's per-row actions — each the hub's own
    # script, handed the row's @id.
    def painted(*texts):
        seen = bytes(screen_out).decode('utf-8', 'replace')
        return all(t in seen for t in texts)
    def menu_open():
        return painted('改名', '置顶', '回收')
    def menu_items(wid):
        result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', wid, '--print'])
        check(result.returncode == 0, result.stderr)
        return {line.split('\t')[0]: line.split('\t')[1]
                for line in result.stdout.splitlines() if line.count('\t') == 2}
    def menu_commands(wid):
        result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', wid, '--print'])
        return {line.split('\t')[0]: line.split('\t')[2]
                for line in result.stdout.splitlines() if line.count('\t') == 2}
    def current():
        return tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}')
    tm('set-option', '-g', 'status-keys', 'emacs')
    tm('set-option', '-w', '-t', w1, '@claude_state', 'working')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'needs')
    items = menu_items(w1)
    check(set('rtpavxno') <= set(items), 'the row menu lacks an action: %r' % items)
    check(items['o'] == '恢复已收工…' and 'fleet-restore-pick.sh' in menu_commands(w1)['o'],
          'the row menu\'s last item is not the restore picker (#901): %r' % items)
    check(items['p'].startswith('-') and items['a'].startswith('-'),
          'a row with no PR / no pending question must grey those items: %r' % items)
    check(not items['r'].startswith('-') and not items['x'].startswith('-'), 'rename/reap greyed: %r' % items)
    check(not menu_items(w2)['a'].startswith('-'), 'a needs row greyed its answer item')
    # A PR for the branch the worktree is on (the dash's prmap) enables the item.
    conf.write_text(fleet_conf + 'FLEET_REPO=example/repo\n')
    prmap = Path(command(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_cache prmap fleet-test',
                          '_', str(bin_dir)]).stdout.strip())
    prmap.parent.mkdir(parents=True, exist_ok=True)
    prmap.write_text(base + '\t#42\tOPEN\t✓\tready\t\n')
    tm('set-option', '-w', '-t', w1, '@worktree', str(main))
    # --print shows names as tmux gets them: a format, where ## is a literal #.
    check(menu_items(w1)['p'] == '打开 PR ##42', 'a row with a PR did not offer it: %r' % menu_items(w1))
    tm('set-option', '-uw', '-t', w1, '@worktree')
    prmap.unlink()
    conf.write_text(fleet_conf)

    os.write(terminal, b'\x02E')
    wait_for(lambda: navigation() and tasks_cue(side), 'prefix E did not focus the sidebar for the menu')
    type_keys('a.b')
    wait_for(lambda: input_line(side) == '› a.b▏', '`.` inside a name did not type: %r' % input_line(side))
    os.write(terminal, b'\x1b')
    wait_for(lambda: tasks_cue(side), 'Esc did not clear the dotted name')
    # A Chinese IME sends 。 (or ．) for the `.` key (issue #965): inside a
    # name it types as itself; on an empty line it is the menu, like `.`.
    type_keys('ab。')
    wait_for(lambda: input_line(side) == '› ab。▏', '。 inside a name did not type: %r' % input_line(side))
    time.sleep(.5)
    check(not menu_open(), '。 inside a name opened the row menu')
    os.write(terminal, b'\x1b')
    wait_for(lambda: tasks_cue(side), 'Esc did not clear the ab。 name')
    del screen_out[:]
    os.write(terminal, b'.')
    wait_for(menu_open, '`.` on an empty input line did not open the row menu')
    check(tasks_cue(side), '`.` on an empty line typed a dot instead of opening the menu')
    os.write(terminal, b't')
    wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@pin') == '1', 'the menu\'s pin did not pin the row')
    check(current() == w1, 'pinning from the menu switched windows')
    check(menu_items(w1)['t'] == '取消置顶', 'a pinned row does not offer unpin')
    for wide, pin in (('。', ''), ('．', '1')):
        del screen_out[:]
        os.write(terminal, wide.encode())
        wait_for(menu_open, '%s on an empty input line did not open the row menu' % wide)
        check(tasks_cue(side), '%s on an empty line typed instead of opening the menu' % wide)
        print('ok: %s on an empty input line opened the row menu' % wide)
        os.write(terminal, b't')
        wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@pin') == pin,
                 'the menu %s opened did not toggle the pin' % wide)
    del screen_out[:]
    os.write(terminal, b'.')
    wait_for(menu_open, 'a second `.` did not reopen the menu')
    os.write(terminal, b't')
    wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@pin') == '', 'the menu\'s unpin did not unpin')
    # Rename: the input line becomes the name editor, pre-filled; Enter hands
    # the name to dash-rename.sh --wid as argv — quotes, $, # and ; survive.
    odd = "名'$HOME\"#;x"
    del screen_out[:]
    os.write(terminal, b'.')
    wait_for(menu_open, 'the menu did not open for rename')
    os.write(terminal, b'r')
    wait_for(lambda: input_line(side) == '改名› worker-one▏',
             'rename did not pre-fill the input line: %r' % input_line(side))
    check(navigation(), 'rename did not keep the keyboard on the sidebar')
    # The rename line edits like the typed one (issue #1097).
    os.write(terminal, b'\x1b[D')
    wait_for(lambda: input_line(side) == '改名› worker-on▏e', '← did not move the rename cursor: %r' % input_line(side))
    os.write(terminal, b'\x1bb')
    wait_for(lambda: input_line(side) == '改名› worker-▏one', '⌥← did not move the rename cursor a word: %r' % input_line(side))
    os.write(terminal, b'\x15')  # C-u: clear the pre-filled current name
    wait_for(lambda: input_line(side) == '改名› ▏', '⌃u did not clear the rename line')
    type_keys(odd)
    wait_for(lambda: input_line(side) == '改名› ' + odd + '▏', 'the odd name did not type: %r' % input_line(side))
    os.write(terminal, b'\r')
    # tmux <=3.4 vis-escapes a window name, and again in format output (`$`
    # reads back backslashed; the hub's own rename included). `odd` has no
    # backslash, so dropping them compares the name itself — $HOME unexpanded.
    renamed = lambda: tm('display-message', '-p', '-t', w1, '#{window_name}')
    wait_for(lambda: renamed() == odd or (server_version() < (3, 5) and renamed().replace('\\', '') == odd),
             'the menu rename did not apply')
    check(current() == w1 and tm('show-options', '-pqv', '-t', side, '@sidebar_rename') == '',
          'rename switched windows or left its parked id behind')
    wait_for(lambda: tasks_cue(side), 'the input line did not return to the placeholder after rename')
    tm('rename-window', '-t', w1, 'worker-one')
    os.write(terminal, b'\x1b')
    wait_for(lambda: not navigation(), 'Esc after the menu did not hand input back')

    # Touch: a tap on another row only switches (no menu); a second tap on that
    # row, now highlighted, opens its menu and switches nothing.
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'rows not painted for the tap test')
    row2 = next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', side).splitlines())
                if '修复侧栏' in line)
    del screen_out[:]
    click(side, row=row2)
    wait_for(lambda: current() == w2 and view_on(w2) == [side], 'a tap on a row did not switch to it')
    time.sleep(.8)
    check(not menu_open(), 'a single tap on another row opened the menu')
    click(side, row=row2)
    wait_for(menu_open, 'the second tap on the highlighted row did not open its menu')
    check(current() == w2, 'the second tap switched windows')
    check(painted('回答它的提问'), 'the tapped row\'s menu is not that row\'s')
    os.write(terminal, b'\x1b')
    time.sleep(.8)
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view did not return to the first worker')

    # Reap: confirm-before first (n keeps the window), then dash-reap.sh --yes;
    # a refusal is toasted from its result token, never silent (#869).
    w3 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'reap-me', 'sleep 600')
    tm('set-option', '-w', '-t', w3, '@raw', '1')
    tm('set-option', '-w', '-t', w3, '@claude_state', 'done')
    for answer in (b'n', b'y'):
        del screen_out[:]
        # display-menu holds its caller until the menu closes — the view never
        # waits on it (open_menu), and neither may this test.
        opener = subprocess.Popen(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', w3],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(menu_open, 'the reap test menu did not open')
        os.write(terminal, b'x')
        wait_for(lambda: painted('回收「reap-me」'), 'reap did not ask for confirmation')
        os.write(terminal, answer)
        opener.wait(timeout=10)
        if answer == b'n':
            time.sleep(1)
            check(w3 in windows(), 'declining the reap confirm still reaped the window')
    wait_for(lambda: w3 not in windows(), 'a confirmed menu reap did not close the window')
    wait_for(lambda: painted('fleet: 已回收'), 'a confirmed reap did not toast its outcome')
    check(current() == w1 and w1 in windows(), 'the reap touched the window in view')
    del screen_out[:]
    call('reap', hub)
    wait_for(lambda: painted('未回收'), 'a refused reap was silent')
    check(hub in windows(), 'the menu reap disposed of the hub')

    # A no-repo session in $HOME (issue #996) carries `@norepo 1` and none of
    # @issue / @raw / @worktree — it still gets the view, and prefix e hides and
    # brings it back there. A plain window with none of the four marks: none.
    before = set(windows())
    spawned = command(['bash', str(bin_dir / 'dash-raw-session.sh'), '--no-repo',
                       '--name', 'home-work', 'fleet-test'], stdin=subprocess.DEVNULL)
    check(spawned.returncode == 0, 'the no-repo spawn failed: ' + spawned.stderr)
    wait_for(lambda: set(windows()) - before, 'dash-raw-session.sh --no-repo made no window')
    home = (set(windows()) - before).pop()
    check(tm('show-options', '-wqv', '-t', home, '@norepo') == '1' and
          tm('display-message', '-p', '-t', home, '#{@issue}#{@raw}#{@worktree}') == '',
          'the no-repo fixture carries a repo mark')
    tm('select-window', '-t', home)
    snap = os.environ.get('FLEET_SIDEBAR_SNAPSHOT')  # evidence only: the window as seen
    if snap:
        time.sleep(2)
        Path(snap).write_text(''.join(
            '[%s]\n%s\n' % (pane, tm('capture-pane', '-p', '-t', pane.split()[0]))
            for pane in tm('list-panes', '-t', home, '-F',
                           '#{pane_id} left=#{pane_left} width=#{pane_width} sidebar=#{@sidebar}').splitlines()))
    wait_for(lambda: view_on(home) == [side], 'a no-repo ($HOME) session got no task bar')
    os.write(terminal, b'\x02e')
    wait_for(lambda: not views(), 'prefix e did not hide the task bar in a no-repo session')
    os.write(terminal, b'\x02e')
    wait_for(lambda: bool(view_on(home)),
             'prefix e did not bring the task bar back in a no-repo session')
    side = view_on(home)[0]
    plain = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'plain', 'sleep 600')
    tm('select-window', '-t', plain)
    call()
    wait_for(lambda: not view_on(plain), 'a window with no @issue/@raw/@worktree/@norepo got a task bar')
    tm('kill-window', '-t', plain)
    tm('kill-window', '-t', home)
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the view did not return after the no-repo leg')
    side = view_on(w1)[0]

    # Hide is prefix e — from the sidebar's own key table too — never a click and
    # never a letter.
    os.write(terminal, b'\x02E')
    wait_for(navigation, 'prefix E before hiding did not enter sidebar navigation')
    os.write(terminal, b'\x02e')
    wait_for(lambda: not views(), 'prefix e while navigating left a view')
    check(not navigation(), 'hiding retained sidebar keyboard focus')
    check('FLEET_SIDEBAR=0' in conf.read_text(), 'collapse was not saved')
    # A hook sync that loaded the conf BEFORE the hide (enabled=1 on its argv)
    # and got the lock AFTER it must not recreate the view (issue #826).
    stale = command(['python3', str(bin_dir / 'fleet-sidebar.py'), 'sync', 'fleet-test',
                     str(conf) + '.sidebar.lock', '1', '30', '', str(conf)])
    check(stale.returncode == 0, stale.stderr)
    check(not views(), 'a sync holding a pre-hide conf read recreated the sidebar')
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
