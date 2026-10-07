#!/bin/bash
# fleet-switch-selftest.sh — switching sessions from the keyboard (issue #1903,
# EPIC #1906 C10): ⌘↓ ⌘↑ ⌘[ ⌘] ⌘J ⌘↩ ⌘P, which iTerm2's `fleet` profile sends as
# private codes ESC [ 92x ~ (bin/dash-keymap.sh --panel switch).
#
#   A  ranking (bin/fleet-quickopen.py) on the prototype's session table: 「cod」
#      puts the codex row first, a machine or a state finds its rows, the letters
#      in order find a name (「crr」), an empty query is most-recent-first with the
#      row in view last; the history steps like a browser's and skips a closed row.
#   B  for real, on a private tmux socket with the client's conf
#      (conf/tmux-shell.conf) and a terminal (a pty) the bytes are written to — so
#      tmux's user-keys, the binds, the list's @sidebar_do queue and its jump() all
#      run: every code moves the session in view as it should, two codes in one
#      write are two steps, ⌘J lands on the row waiting on you, ⌘↩ zooms (and ⌘↓
#      still steps from there, the list hidden), and ⌘P
#      opens the popup where 「thr」 ↵ switches to «three» — and finds a session
#      folded under its parent, which ⌘[ steps back onto too; ⌘. (issue #2167)
#      opens and shuts the parent in view, and on its child shuts the parent.
#   D  commands (issue #1952): ONE table, fleet-quickopen.py COMMANDS — every
#      action of the row menu's letter table is in it and nothing else; `>` lists
#      the menu's own items for the row in view in the table's order, filters
#      them (`>pin`), and for real ⌘P `>pin` ↵ pins the row in view, the way the
#      menu's 置顶 does; ⌘/ with no stage opens the page in a popup, q closes it.
#   C  no iTerm2: the profile writer writes nothing, and fleet-shell.sh's attach is
#      the bare `exec tmux … attach` it always was, byte for byte; in iTerm2 with
#      the profile there, the window wears `fleet` only around the attach.
#
# Drives: bin/fleet-quickopen.py, bin/fleet-sidebar.py, conf/tmux-shell.conf,
# bin/fleet-sidebar-menu.sh, bin/fleet-keys.sh, bin/fleet-ui-lang.sh,
# bin/fleet-iterm-profile.py, bin/fleet-shell.sh, bin/dash-keymap.sh.
set -uo pipefail
export FLEET_SIDEBAR_NODE=1   # the drawer's selftest seam (fleet-sidebar.sh)
BIN="$(cd "$(dirname "$0")" && pwd)"

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("q", os.path.join(sys.argv[1], "fleet-quickopen.py"))
q = importlib.util.module_from_spec(spec); spec.loader.exec_module(q)
W = [("@1", "working", "Nodes can't kill workers · issue-1840", "m5"),
     ("@2", "needs", "Config migration keeps settings · issue-1887", "m5"),
     ("@3", "working", "Operator scratch · scratch-5", "m5"),
     ("@4", "done", "Offline list stays put · issue-1882", "m5"),
     ("@5", "working", "Mini-program UI/UX", "m4"),
     ("@6", "done", "Hub disk watch · issue-11641", "m4"),
     ("@7", "working", "Codex: reap rules · issue-1832", "m4"),
     ("@8", "done", "Daily report draft · scratch-7", "")]
rows = [{"key": k, "state": s, "glyph": "", "name": n, "node": m, "group": "", "badge": ""} for k, s, n, m in W]
def top(query, mru=(), current=""):
    return [r["key"] for r, _ in q.rank(rows, query, list(mru), current)]
errs = []
def eq(what, got, want):
    if got != want:
        errs.append("%s: %r, want %r" % (what, got, want))
eq("cod first", top("cod")[:1], ["@7"])
eq("Cod (case) first", top("Cod")[:1], ["@7"])
eq("crr finds Codex: reap rules first", top("crr")[:1], ["@7"])
eq("m4 lists the m4 rows", sorted(top("m4")[:3]), ["@5", "@6", "@7"])
eq("needs finds the row waiting", top("needs")[:1], ["@2"])
eq("issue-1882", top("1882"), ["@4"])
eq("two words, both must match", top("hub disk"), ["@6"])
eq("no match, no row", top("zzzq"), [])
eq("empty: recent first, the one in view last", top("", ["@3", "@7", "@1"], "@3"), ["@7", "@1", "@2", "@4", "@5", "@6", "@8", "@3"])
eq("a tie goes to the recent one", top("m5", ["@4"])[:1], ["@4"])
_, marks = q.rank(rows, "cod", [])[0]
eq("cod marks", marks, [0, 1, 2])
# the history
os.environ["FLEET_SWITCH_STATE"] = tempfile.mkdtemp()
h = q.load()
for k in ("@1", "@2", "@3", "@2"):
    q.visit(h, k)
eq("stack", h["stack"], ["@1", "@2", "@3", "@2"])
eq("mru", h["mru"], ["@2", "@3", "@1"])
live = {"@1", "@2", "@3"}
eq("back", q.step(h, live, -1), "@3")
q.visit(h, "@3")  # the list sees the row it stepped onto: no new entry
eq("a step adds no entry", h["stack"], ["@1", "@2", "@3", "@2"])
eq("back skips a closed row", q.step(h, {"@1", "@3"}, -1), "@1")
eq("back at the start", q.step(h, live, -1), "")
eq("fwd", q.step(h, live, 1), "@2")
q.visit(h, "@4")  # a new switch drops what was ahead
eq("a switch after back truncates", h["stack"], ["@1", "@2", "@4"])
q.save(h)
eq("save/load", q.load(), h)
for i in range(80):
    q.visit(h, "@x%d" % i)
eq("stack cap", len(h["stack"]), q.STACK_MAX)
eq("at stays on the top", h["stack"][h["at"]], "@x79")
# rows_text: the list's rows → switch-rows.tsv, headings folded into a group
text = q.rows_text([["hdr", "verkyyi/claude-fleet", "", "verkyyi/claude-fleet", ""],
                    ["@9", "needs", "!", " nine", "", "b", "0", "", "m4", "", "", "", ""]])
eq("rows_text", text, "@9\tneeds\t!\tnine\tm4\tverkyyi/claude-fleet\tb\n")
# D (the table half): COMMANDS ⇔ the menu's letter table, action for action
table = [a for a, _ in q.COMMANDS]
eq("COMMANDS has no action twice", len(table), len(set(table)))
keyed = sorted({a for a, _ in q.menu_keys().values()})
eq("COMMANDS ⇔ menu_keys", sorted(table), keyed)
eq("COMMANDS groups", sorted({g for _, g in q.COMMANDS}), ["control", "enter", "message", "other"])
eq("the digits are newto's", q.menu_keys().get("5", ("",))[0], "newto")
items = [("rename", "改名…", "在会话下面一行改", "c1"), ("pin", "置顶", "置顶 / 取消置顶", "c2"),
         ("reap", "回收…", "先确认 y/n", "c3"), ("info", "-详情列", "issue · PR · ctx%", "")]
eq("> lists every command for an empty query", [i[0] for i in q.rank_cmds(items, "")], ["rename", "pin", "reap", "info"])
eq(">pin finds pin by its action", [i[0] for i in q.rank_cmds(items, "pin")], ["pin"])
eq(">改 finds rename by its name", [i[0] for i in q.rank_cmds(items, "改")][:1], ["rename"])
eq(">详情 finds a greyed one too", [i[0] for i in q.rank_cmds(items, "详情")], ["info"])
eq("a target the menu has no row for is row-less", (q.target_of("new"), q.target_of("@3"), q.target_of("wid:f/issue-1")),
   ("-", "@3", "wid:f/issue-1"))
if errs:
    print("FAIL A:\n  " + "\n  ".join(errs)); sys.exit(1)
print("A: ranking + history + the command table: %d checks" % 31)
PY

# --- B ---------------------------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then echo 'B SKIP: tmux missing'; else
python3 - "$BIN" <<'PY' || exit 1
import fcntl, os, pty, shlex, shutil, signal, struct, subprocess, sys, tempfile, termios, threading, time
from pathlib import Path

real_bin = Path(sys.argv[1])
real_tmux = shutil.which('tmux')
work = Path(tempfile.mkdtemp(prefix='fsw.', dir='/tmp'))   # AF_UNIX paths stop at 104 bytes
root = work / 'root'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    (bin_dir / source.name).symlink_to(source)
(root / 'conf').symlink_to(real_bin.parent / 'conf')
(root / 'fleet.conf').write_text('FLEET_GLOBAL_MAX_SESSIONS=0\n')
state = work / 'state'
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'), HOME=str(work),
           TERM='xterm-256color', FLEET_UI_LANG='zh', FLEET_SWITCH_STATE=str(state))
env.pop('TMUX', None)
env.pop('TMUX_PANE', None)
shim = work / 'path'
shim.mkdir()
(work / 's').mkdir()
sock = str(work / 's' / 'ft')
(shim / 'tmux').write_text('#!/bin/sh\nexec %s -S %s "$@"\n' % (shlex.quote(real_tmux), shlex.quote(sock)))
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
conf = work / 'conf/fleets/ft/conf'
conf.parent.mkdir(parents=True)
conf.write_text('FLEET_SIDEBAR=1\n')
client = None
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
    return [line.split() for line in tm('list-panes', '-a', '-F', '#{pane_id} #{window_id} #{@sidebar}').splitlines()
            if line.endswith(' 1')]


def current():
    return tm('display-message', '-p', '#{window_id}')


try:
    names = ('one', 'two', 'three', 'four')
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'ft', '-x', '160', '-y', '30', '-n', 'one', 'cat')
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    W = {'one': current()}
    for n in names[1:]:
        W[n] = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', n, 'cat')
    for i, n in enumerate(names, 1):
        tm('set-option', '-w', '-t', W[n], '@issue', str(i))
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

    def drain():
        try:
            while os.read(master, 65536):
                pass
        except OSError:
            pass
    threading.Thread(target=drain, daemon=True).start()
    check(wait(lambda: bool(views())), 'the attach hook did not draw the list')
    side = views()[0][0]
    check(wait(lambda: 'four' in tm('capture-pane', '-p', '-t', side)), 'the list has no rows')
    check(current() == W['one'], 'the client did not start on «one»')

    def press(code, want, why, secs=4):
        os.write(master, ('\x1b[%d~' % code).encode())
        check(wait(lambda: current() == W[want], secs),
              '%s: ESC[%d~ left the client on %s, want «%s»' % (why, code, current(), want))

    press(920, 'two', '⌘↓ next')
    press(920, 'three', '⌘↓ next')
    press(921, 'two', '⌘↑ prev')
    press(922, 'three', '⌘[ back')
    press(922, 'two', '⌘[ back')
    press(922, 'one', '⌘[ back')
    press(923, 'two', '⌘] fwd')
    press(921, 'one', '⌘↑ prev')
    os.write(master, b'\x1b[921~')   # at the top: stays (no wrap)
    time.sleep(1)
    check(current() == W['one'], '⌘↑ on the first row moved to %s' % current())
    print('B: ⌘↓ ⌘↑ ⌘[ ⌘] move the session in view, and the history steps back and forward')
    # two codes in one write: two steps, none lost
    os.write(master, b'\x1b[920~\x1b[920~')
    check(wait(lambda: current() == W['three'], 4), 'two ⌘↓ in one write did not step twice: on %s' % current())
    print('B: two codes in one write are two steps')
    # ⌘J: the row waiting on you
    tm('set-option', '-w', '-t', W['one'], '@claude_state', 'needs')
    tm('set-option', '-w', '-t', W['one'], '@claude_needs', 'ask')
    time.sleep(1.5)  # the list's next read carries the needs row
    press(924, 'one', '⌘J needs')
    # ⌘↩: zoom the right pane, and back
    os.write(master, b'\x1b[925~')
    check(wait(lambda: tm('display-message', '-p', '#{window_zoomed_flag}') == '1', 3), '⌘↩ did not zoom')
    os.write(master, b'\x1b[925~')
    check(wait(lambda: tm('display-message', '-p', '#{window_zoomed_flag}') == '0', 3), 'a second ⌘↩ did not unzoom')
    # ⌘↓ with the session zoomed (the list hidden): still a step
    os.write(master, b'\x1b[925~')
    check(wait(lambda: tm('display-message', '-p', '#{window_zoomed_flag}') == '1', 3), '⌘↩ did not zoom (2)')
    press(920, 'two', '⌘↓ while zoomed')
    print('B: ⌘J lands on the row waiting on you; ⌘↩ zooms and restores; ⌘↓ from a zoomed session unzooms and steps')
    # the rows ⌘P reads, and the popup itself: 「thr」 ↵
    rows = state / 'switch-rows.tsv'
    check(wait(lambda: rows.exists() and 'three' in rows.read_text(), 3), 'the list wrote no switch-rows.tsv')
    ranked = subprocess.run(['python3', str(bin_dir / 'fleet-quickopen.py'), 'rank', 'thr'], env=env,
                            capture_output=True, text=True).stdout.split('\n')[0]
    check(ranked.split('\t')[0] == W['three'], 'rank thr: %r' % ranked)
    os.write(master, b'\x1b[927~')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') not in ('', '0'), 4), '⌘P opened no popup')
    time.sleep(.6)
    os.write(master, 'thr'.encode())
    time.sleep(.3)
    os.write(master, b'\r')
    check(wait(lambda: current() == W['three'], 4), '⌘P thr ↵ did not switch to «three»: on %s' % current())
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') in ('', '0'), 4), 'the popup did not close after ↵')
    print('B: ⌘P 「thr」 ↵ switches to «three»')
    # a child folded under its parent: not painted, yet ⌘P finds it, and ⌘[ comes back to it
    W['five'] = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'five', 'cat')
    tm('set-option', '-w', '-t', W['five'], '@issue', '5')
    tm('set-option', '-w', '-t', W['five'], '@origin', 'issue-3')
    check(wait(lambda: '▸' in tm('capture-pane', '-p', '-t', side), 4), 'the parent «three» shows no folded caret')
    check('five' not in tm('capture-pane', '-p', '-t', side), '«five» is painted — it should be folded under «three»')
    os.write(master, b'\x1b[927~')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') not in ('', '0'), 4), '⌘P opened no popup (2)')
    time.sleep(1.5)  # the popup's full read (every session, folded ones too)
    os.write(master, 'fiv'.encode())
    time.sleep(.3)
    os.write(master, b'\r')
    check(wait(lambda: current() == W['five'], 4), '⌘P fiv ↵ did not reach the folded «five»: on %s' % current())
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') in ('', '0'), 4), 'the popup did not close (2)')
    check(wait(lambda: 'five' in tm('capture-pane', '-p', '-t', side), 4), 'the list does not paint the child in view')
    press(921, 'three', '⌘↑ from the child')   # the row above it: its parent
    check(wait(lambda: 'five' not in tm('capture-pane', '-p', '-t', side), 4), '«five» did not fold away again')
    press(922, 'five', '⌘[ back onto a folded row')
    print('B: a folded child: ⌘P finds it, ⌘[ comes back to it (%d checks)' % checks)
    # ⌘. (issue #2167): the parent in view opens and shuts its block; on the
    # child, it shuts the parent, which then holds the highlight
    expand = lambda: tm('show-options', '-wqv', '-t', W['three'], '@expand')
    painted = lambda: tm('capture-pane', '-p', '-t', side)
    check(wait(lambda: 'five' in painted(), 4), 'the list does not paint the child it came back to')
    press(921, 'three', '⌘↑ from the child (2)')
    check(wait(lambda: 'five' not in painted(), 4), '«five» is painted under a folded «three»')
    check(expand() == '', '«three» starts open: @expand=%r' % expand())
    os.write(master, b'\x1b[929~')
    check(wait(lambda: 'five' in painted(), 4), '⌘. on the folded parent did not paint its child')
    check(wait(lambda: expand() == '1', 10), '⌘. on the folded parent did not write @expand=1')
    os.write(master, b'\x1b[929~')
    check(wait(lambda: 'five' not in painted(), 4), '⌘. on the open parent did not fold its child away')
    check(wait(lambda: expand() == '', 10), '⌘. on the open parent did not clear @expand')
    os.write(master, b'\x1b[929~')
    check(wait(lambda: expand() == '1', 10), '⌘. did not open «three» again')
    press(920, 'five', '⌘↓ onto the open child')
    os.write(master, b'\x1b[929~')
    check(wait(lambda: expand() == '', 10), '⌘. on the child did not shut its parent')
    check(wait(lambda: any(l.startswith('›') and 'three' in l for l in painted().splitlines()), 4),
          '⌘. on the child did not leave the highlight on its parent: %r' % painted())
    check(current() == W['five'], '⌘. switched windows: on %s' % current())
    # leave the list as the next leg expects it: «three» open, the highlight
    # back on the row in view
    press(921, 'three', '⌘↑ back to the parent')
    os.write(master, b'\x1b[929~')
    check(wait(lambda: expand() == '1', 10), '⌘. did not reopen «three»')
    check(wait(lambda: 'five' in painted(), 4), 'the reopened «three» does not paint «five»')
    press(920, 'five', '⌘↓ back onto the child')
    print('B: ⌘. opens and shuts the parent in view; on its child it shuts the parent (%d checks)' % checks)
    # D: `>` — the row menu's items for the row in view, in the table's order
    qo = lambda *a: subprocess.run(['python3', str(bin_dir / 'fleet-quickopen.py'), *a], env=dict(env, FLEET_SESSION='ft'),
                                   capture_output=True, text=True, timeout=20).stdout
    listed = [l.split('\t') for l in qo('cmds').splitlines()]
    acts = [l[0] for l in listed]
    check({'rename', 'pin', 'reap', 'restore', 'info'} <= set(acts), '> lacks a command: %r' % acts)
    order = [a for a in qo('commands').split() if a in acts]
    check(acts == [a for a in order if a in acts], '> is not in the table order: %r' % acts)
    names = {l[0]: l[1] for l in listed}
    check(names['rename'].lstrip('-') == '改名…' and names['pin'] == '置顶', '> names are not the menu\'s: %r' % names)
    menu = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'ft', W['five'], '--print'], env=env,
                          capture_output=True, text=True, timeout=20).stdout
    check(all(('\t' + n + '\t') in menu for n in names.values()), '> lists an item the menu does not draw: %r' % menu)
    check([l[0] for l in (x.split('\t') for x in qo('cmds', 'pin').splitlines())][:1] == ['pin'], '>pin does not put pin first')
    check(tm('show-options', '-wqv', '-t', W['five'], '@pin') != '1', 'five is pinned before the test')
    os.write(master, b'\x1b[927~')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') not in ('', '0'), 4), '⌘P opened no popup (3)')
    time.sleep(.6)
    os.write(master, b'>pin')
    time.sleep(2)   # the menu's items, read once on the first `>`
    os.write(master, b'\r')
    check(wait(lambda: tm('show-options', '-wqv', '-t', W['five'], '@pin') == '1', 6),
          '⌘P >pin ↵ did not pin the row in view')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') in ('', '0'), 4), 'the popup did not close (3)')
    check(current() == W['five'], '>pin switched windows: on %s' % current())
    print('B: ⌘P > lists the row menu\'s items in the table order; >pin ↵ pins the row in view')
    # ⌘/ with no stage (not the shell): the page in the popup, q closes it
    os.write(master, b'\x1b[926~')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') not in ('', '0'), 6), '⌘/ opened nothing')
    time.sleep(.6)
    os.write(master, b'q')
    check(wait(lambda: tm('show-options', '-gqv', '@popup_open') in ('', '0'), 4), 'q did not close the keys page')
    print('B: ⌘/ with no stage: the page in a popup, q closes it (%d checks)' % checks)
except AssertionError as e:
    print('FAIL B: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
fi

# --- C ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import os, pty, subprocess, sys, tempfile
from pathlib import Path
bin_dir = Path(sys.argv[1])
work = Path(tempfile.mkdtemp())
errs = []
# no iTerm2 here (a HOME without ~/Library/Application Support/iTerm2): nothing written
env = dict(os.environ, HOME=str(work))
for k in ("FLEET_ITERM_DIR", "ITERM_PROFILE", "TERM_PROGRAM", "LC_TERMINAL"):
    env.pop(k, None)
r = subprocess.run(["python3", str(bin_dir / "fleet-iterm-profile.py"), "write"], env=env)
if r.returncode != 0 or any(work.rglob("*")):
    errs.append("no iTerm2: write wrote %s (rc %d)" % ([str(p) for p in work.rglob("*")], r.returncode))
st = subprocess.run(["python3", str(bin_dir / "fleet-iterm-profile.py"), "status"], env=env, capture_output=True, text=True)
if st.stdout.strip() != "no-iterm" or st.returncode != 2:
    errs.append("no iTerm2: status %r rc %d" % (st.stdout, st.returncode))
# fleet-shell.sh's attach, cut out and run against a tmux that prints its argv
src = (bin_dir / "fleet-shell.sh").read_text()
fn = src[src.index("attach_client() {"):]
fn = fn[:fn.index("\n}\n") + 3]
fake = work / "path"
fake.mkdir()
(fake / "tmux").write_text("#!/bin/sh\nprintf 'TMUX:%s\\n' \"$*\"\n")
(fake / "tmux").chmod(0o755)
prof = work / "dyn"
prof.mkdir()
(prof / "fleet.json").write_text("{}")
script = fn + 'SESS=ft\nattach_client\n'
def run(extra):
    e = dict(env, PATH=str(fake) + os.pathsep + env["PATH"], FLEET_ITERM_DIR=str(prof), **extra)
    pid, fd = pty.fork()
    if pid == 0:
        os.execve("/bin/bash", ["bash", "-c", script], e)
    out = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    _, status = os.waitpid(pid, 0)
    return out.replace(b"\r\n", b"\n"), os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status >> 8
bare = b"TMUX:-L ft attach-session -t =ft\n"
for name, extra in (("no terminal named", {}),
                    ("Terminal.app", {"TERM_PROGRAM": "Apple_Terminal"}),
                    ("iTerm2, no ITERM_PROFILE (over ssh)", {"LC_TERMINAL": "iTerm2"}),
                    ("iTerm2, FLEET_ITERM_KEYS=0", {"TERM_PROGRAM": "iTerm.app", "ITERM_PROFILE": "Default", "FLEET_ITERM_KEYS": "0"})):
    out, rc = run(extra)
    if out != bare or rc != 0:
        errs.append("%s: the attach printed %r (rc %d), want exactly the bare exec %r" % (name, out, rc, bare))
out, rc = run({"TERM_PROGRAM": "iTerm.app", "ITERM_PROFILE": "Default"})
want = b"\x1b]1337;SetProfile=fleet\x07" + bare + b"\x1b]1337;SetProfile=Default\x07"
if out != want:
    errs.append("iTerm2 with the profile: %r, want %r" % (out, want))
(prof / "fleet.json").unlink()
out, rc = run({"TERM_PROGRAM": "iTerm.app", "ITERM_PROFILE": "Default"})
if out != bare:
    errs.append("iTerm2 without the profile: %r, want the bare exec" % out)
if errs:
    print("FAIL C:\n  " + "\n  ".join(errs)); sys.exit(1)
print("C: no iTerm2 = the bare attach, byte for byte; iTerm2 + profile = SetProfile around it")
PY
echo "fleet-switch selftest: OK"
