#!/bin/bash
# task-pick-selftest.sh — the popup task picker for a window with no task bar
# (issue #902, EPIC #894 R2), driven end to end on a PRIVATE tmux socket with a
# real client on a pty — never the operator's live server.
#
#   * at 90 columns the task bar is not there (fleet-sidebar.sh sync hides it);
#   * `prefix Space` opens the picker as a popup, @popup_open raised while it is up;
#   * the list is the task bar's — tasks only, no hub/backlog panel windows;
#   * picking the 2nd row makes that task the current window, @popup_open back to 0;
#   * a typed name + the dash's scratch key hands the name to dash-raw-session.sh;
#   * ⌂ / F9 in a task with no bar open the picker instead of going to the hub
#     (logged `f9-pick`), F9 inside it goes on to the hub, and
#     FLEET_HOME_SIDEBAR_FIRST=0 restores the direct jump.
#
# fzf is a STUB unless a real one is installed (CI has none): it records its stdin
# and argv, then waits for one line on its terminal — the row number to pick, `q`
# to cancel — so the keystrokes still travel client → popup → picker. With a real
# fzf the pick leg also runs through it (↓ ↵).
# tmux absent → SKIP (exit 0).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'selftest SKIP: tmux missing'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'selftest SKIP: python3 missing'; exit 0; }
python3 - "$BIN" <<'PY'
import fcntl, json, os, pty, shlex, shutil, signal, struct, subprocess, sys, tempfile, termios, threading, time
from pathlib import Path

real_bin = Path(sys.argv[1])
real_tmux = shutil.which('tmux')
real_fzf = shutil.which('fzf')
work = Path(tempfile.mkdtemp(prefix='task-pick-selftest.'))
root = work / 'root'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
STUBBED = ('dash-raw-session.sh',)
for source in real_bin.iterdir():
    if source.name not in STUBBED:
        (bin_dir / source.name).symlink_to(source)
# The spawn itself is dash-raw-session.sh's own selftests' business; here it only
# has to be the script the picker hands the name to.
(bin_dir / 'dash-raw-session.sh').write_text(
    '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TASK_PICK_SPAWNS"\n')
(bin_dir / 'dash-raw-session.sh').chmod(0o755)
(root / 'conf').symlink_to(real_bin.parent / 'conf')

sock = str(work / 'fleet-test')
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'),
           FLEET_HUB_VISITS_LOGDIR=str(work / 'logs'), TERM='xterm-256color',
           TASK_PICK_SPAWNS=str(work / 'spawns'), FAKE_FZF_LOG=str(work / 'fzf-in'),
           FAKE_FZF_ARGV=str(work / 'fzf-argv'))
shim = work / 'path'
shim.mkdir()
(shim / 'tmux').write_text('#!/bin/sh\ncase "$1" in -L|-S) shift 2 ;; esac\nexec ' +
                          shlex.quote(real_tmux) + ' -S ' + shlex.quote(sock) + ' "$@"\n')
(shim / 'tmux').chmod(0o755)
fake = work / 'fakefzf'
fake.mkdir()
(fake / 'fzf').write_text('''#!/usr/bin/env python3
import json, os, sys
rows = sys.stdin.read().splitlines()
open(os.environ["FAKE_FZF_LOG"], "w").write("\\n".join(rows) + "\\n")
open(os.environ["FAKE_FZF_ARGV"], "w").write(json.dumps(sys.argv[1:]))
fd = os.open("/dev/tty", os.O_RDWR)
os.write(fd, ("FAKE-FZF " + str(len(rows)) + " rows\\r\\n").encode())
buf = b""
while not buf.endswith((b"\\r", b"\\n")):
    buf += os.read(fd, 1)
line = buf.decode().strip()
if line.isdigit() and 0 < int(line) <= len(rows):
    print(""); print(rows[int(line) - 1]); sys.exit(0)
print(line[1:] if line.startswith("/") else ""); sys.exit(1)
''')
(fake / 'fzf').chmod(0o755)
conf = work / 'conf/fleets/fleet-test/conf'
conf.parent.mkdir(parents=True)
conf.write_text('FLEET_SIDEBAR=1\n')
checks = 0
client = None
terminal = None

def use_fzf(real):
    path = [str(shim)] + ([] if real else [str(fake)]) + os.environ['PATH'].split(os.pathsep)
    env['PATH'] = os.pathsep.join(path)
    tm('set-environment', '-g', 'PATH', env['PATH'])

def command(args, **kw):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=20, **kw)

def tm(*args):
    r = command([real_tmux, '-S', sock, *args])
    if r.returncode:
        raise AssertionError((args, r.stderr))
    return r.stdout.rstrip('\n')

def check(cond, msg):
    global checks
    assert cond, msg
    checks += 1

def wait_for(pred, msg, secs=8):
    deadline = time.monotonic() + secs
    while time.monotonic() < deadline:
        if pred():
            return
        time.sleep(.05)
    raise AssertionError(msg + '\n--- screen tail ---\n' + bytes(screen[-2000:]).decode('utf-8', 'replace'))

def current():
    return tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}')

def popup_open():
    return tm('show-options', '-gqv', '@popup_open')

def painted(text, since):
    return text.encode() in bytes(screen[since:])

def cleanup(*_):
    if client:
        client.terminate()
        try: client.wait(timeout=5)
        except subprocess.TimeoutExpired: client.kill()
    if terminal is not None:
        os.close(terminal)
    subprocess.run([real_tmux, '-S', sock, 'kill-server'], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))

screen = bytearray()
try:
    env['PATH'] = os.pathsep.join([str(shim), str(fake), os.environ['PATH']])
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fleet-test', '-x', '90', '-y', '30',
       '-n', 'plan', 'sleep 600')
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    tm('set-option', '-g', 'prefix', 'C-b')
    hub = tm('display-message', '-p', '#{window_id}')
    tm('set-option', '-p', '-t', tm('display-message', '-p', '#{pane_id}'), '@dash', '1')
    w1 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'task-one', 'sleep 600')
    tm('set-option', '-w', '-t', w1, '@issue', '1')
    tm('set-option', '-w', '-t', w1, '@wid', 'a1')
    tm('set-option', '-w', '-t', w1, '@claude_state', 'working')
    w2 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'task-two', 'sleep 600')
    tm('set-option', '-w', '-t', w2, '@raw', '1')
    tm('set-option', '-w', '-t', w2, '@wid', 'b1')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'idle')
    tm('new-window', '-d', '-n', 'backlog', 'sleep 600')

    # The shipped binds, pointed at the sandbox; `sh` → `bash --posix` as
    # hub-zoom-home-selftest.sh does (CI's /bin/sh is dash, issue #414).
    shipped = (bin_dir.parent / 'conf/tmux-attention.conf').read_text()
    wanted = [l for l in shipped.splitlines()
              if l.startswith(('bind Space ', 'bind E ', 'bind -n F9 ', 'bind -T fleet-sidebar F9 '))]
    check(len(wanted) == 4, 'conf lost one of: bind Space / bind E / bind -n F9 / fleet-sidebar F9')
    fixture = work / 'pick.conf'
    fixture.write_text('\n'.join(wanted).replace('~/.claude/fleet', str(root))
                       .replace('run-shell "sh ', 'run-shell "bash --posix ') + '\n')
    tm('source-file', str(fixture))

    terminal, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 90, 0, 0))
    cenv = {k: v for k, v in env.items() if k not in ('TMUX', 'TMUX_PANE')}
    client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'fleet-test'],
                              env=cenv, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    def drain():
        try:
            while True:
                chunk = os.read(terminal, 65536)
                if not chunk: return
                screen.extend(chunk)
        except OSError:
            pass
    threading.Thread(target=drain, daemon=True).start()
    wait_for(lambda: bool(tm('list-clients', '-F', '#{client_name}')), 'client did not attach')
    tm('select-window', '-t', w1)

    # --- 1. at 90 columns there is no task bar ----------------------------------
    r = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'sync', 'fleet-test'])
    check(r.returncode == 0, r.stderr)
    check(tm('display-message', '-p', '-t', w1, '#{window_width}') == '90', 'window is not 90 columns')
    check(tm('show-options', '-wqv', '-t', w1, '@sidebar_worker') == '',
          'a 90-column window must not show the task bar')

    def open_with(keys, why):
        mark = len(screen)
        os.write(terminal, keys)
        wait_for(lambda: painted('FAKE-FZF', mark), why + ': the picker popup did not open')
        check(popup_open() not in ('', '0'), why + ': @popup_open not raised while the popup is up')
        return mark

    def rows_shown():
        return Path(env['FAKE_FZF_LOG']).read_text().splitlines()

    # --- 2. prefix Space → popup; the list is tasks only -------------------------
    use_fzf(False)
    open_with(b'\x02 ', 'prefix Space')
    shown = rows_shown()
    check([r.split('\t')[0] for r in shown] == [w1, w2] or
          sorted(r.split('\t')[0] for r in shown) == sorted([w1, w2]),
          'picker must list exactly the two tasks, got %r' % shown)
    check(not any(x in '\n'.join(shown) for x in ('plan', 'backlog')),
          'a panel window (hub/backlog) leaked into the picker: %r' % shown)
    check(any(r.split('\t')[0] == w1 and '▶' in r for r in shown), 'the current task is not marked ▶')
    # --- 3. pick the 2nd row → that task is current, @popup_open back to 0 --------
    second = shown[1].split('\t')[0]
    os.write(terminal, b'2\r')
    wait_for(lambda: current() == second, 'picking row 2 did not switch to it')
    wait_for(lambda: popup_open() == '0', '@popup_open was not cleared after the pick')

    # --- 4. cancel changes nothing ------------------------------------------------
    before = current()
    open_with(b'\x02 ', 'prefix Space (cancel)')
    os.write(terminal, b'q\r')
    wait_for(lambda: popup_open() == '0', '@popup_open was not cleared after a cancel')
    time.sleep(.3)
    check(current() == before, 'a cancelled pick moved the client')

    # --- 5. ↵ on no match starts a named scratch session through the shared script
    open_with(b'\x02 ', 'prefix Space (scratch)')
    os.write(terminal, b'/probe-name\r')
    wait_for(lambda: Path(env['TASK_PICK_SPAWNS']).exists(), 'no scratch spawn after ↵ on a typed name')
    spawn = Path(env['TASK_PICK_SPAWNS']).read_text()
    check('--name probe-name' in spawn and '--origin hub' in spawn and 'fleet-test' in spawn,
          'scratch spawn args wrong: %r' % spawn)
    argv = ' '.join(json.loads(Path(env['FAKE_FZF_ARGV']).read_text()))
    check('ctrl-s:execute-silent' in argv and 'f9:execute-silent' in argv and '[⌂ hub]' in argv,
          'picker lost its ⌃s / F9 / [⌂ hub] binds: %s' % argv)

    # --- 6. F9 in a task with no bar opens the picker, not the hub ----------------
    tm('select-window', '-t', w1)
    open_with(b'\x1b[20~', 'F9 without a task bar')
    check(current() == w1, 'F9 without a bar left the task')
    os.write(terminal, b'q\r')
    wait_for(lambda: popup_open() == '0', '@popup_open was not cleared (F9 leg)')
    log = work / 'logs/hub-visits-fleet-test.log'
    wait_for(lambda: log.exists() and '\tf9-pick' in log.read_text(), 'F9 → picker was not logged as f9-pick')
    visits = command(['bash', str(bin_dir / 'fleet-hub-visits.sh'), '--session', 'fleet-test'])
    check('via the task picker' in visits.stdout and ': 0' in visits.stdout,
          'f9-pick must be listed apart and not counted: %r' % visits.stdout)

    # --- 7. the picker's own hub action goes on to the hub ------------------------
    tm('select-window', '-t', w1)
    r = command(['bash', '--posix', str(bin_dir / 'hub-zoom.sh'), '--nav'])
    check(current() == hub, '--nav (the picker hub action) must go on to the hub, got %s' % current())

    # --- 8. knob off → F9 is the direct jump again --------------------------------
    tm('select-window', '-t', w1)
    conf.write_text('FLEET_SIDEBAR=1\nFLEET_HOME_SIDEBAR_FIRST=0\n')
    os.write(terminal, b'\x1b[20~')
    wait_for(lambda: current() == hub, 'FLEET_HOME_SIDEBAR_FIRST=0: F9 must jump to the hub')
    conf.write_text('FLEET_SIDEBAR=1\n')

    # --- 9. a zoomed task keeps going home ----------------------------------------
    tm('select-window', '-t', w1)
    tm('split-window', '-d', '-t', w1, 'sleep 600')
    tm('resize-pane', '-Z', '-t', w1)
    os.write(terminal, b'\x1b[20~')
    wait_for(lambda: current() == hub, 'F9 in a zoomed task must still go to the hub')

    # --- 10. the real fzf, when there is one: ↓ ↵ picks the 2nd row ---------------
    if real_fzf:
        use_fzf(True)
        tm('select-window', '-t', w1)
        tm('resize-pane', '-Z', '-t', w1)
        mark = len(screen)
        os.write(terminal, b'\x02 ')
        wait_for(lambda: painted('task ▸', mark), 'real fzf picker did not render')
        time.sleep(.3)
        os.write(terminal, b'\x1b[B'); time.sleep(.2); os.write(terminal, b'\r')
        wait_for(lambda: current() != w1 and popup_open() == '0', 'real fzf: ↓ ↵ did not switch task')
        check(current() in (w1, w2), 'real fzf switched to a panel window')
        # F9 inside the picker is the second press: on to the hub.
        tm('select-window', '-t', w1)
        mark = len(screen)
        os.write(terminal, b'\x02 ')
        wait_for(lambda: painted('task ▸', mark), 'real fzf picker did not render (F9 leg)')
        time.sleep(.3)
        os.write(terminal, b'\x1b[20~')
        wait_for(lambda: current() == hub and popup_open() == '0', 'real fzf: F9 in the picker must go to the hub')
        # A typed name + ⌃s: the shared scratch script gets the name.
        tm('select-window', '-t', w1)
        Path(env['TASK_PICK_SPAWNS']).unlink()
        mark = len(screen)
        os.write(terminal, b'\x02 ')
        wait_for(lambda: painted('task ▸', mark), 'real fzf picker did not render (⌃s leg)')
        time.sleep(.3)
        os.write(terminal, 'zz新会话'.encode()); time.sleep(.3); os.write(terminal, b'\x13')
        wait_for(lambda: Path(env['TASK_PICK_SPAWNS']).exists(), 'real fzf: ⌃s did not start a scratch')
        check('--name zz新会话' in Path(env['TASK_PICK_SPAWNS']).read_text(), 'real fzf: ⌃s lost the typed name')
    else:
        print('selftest: no fzf installed — real-fzf leg SKIPPED')
    print('task-pick selftest OK (%d checks)' % checks)
finally:
    cleanup()
PY
