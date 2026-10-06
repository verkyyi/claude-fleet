#!/bin/bash
# fleet-client-layout-selftest.sh — the client on a phone, and the session's top
# line (issue #1904, EPIC #1906 C11).
#
#   A  pure: bin/fleet-topbar.py lays the line out at 150 / 100 / 60 / 44 columns
#      in the design's drop order (repo → PR → the state's word → the title
#      clipped; ‹ i/n ›, the key and the machine always kept), red only while the
#      session asks you, grey only while its machine is lost or reconnecting;
#      fleet-sidebar.py bar_record reads the line's record off the list's own rows
#      (place, key, PR, repo only in a fleet of several); fleet-quickopen.py's
#      full-screen switcher groups 在等你的 · 最近 (1–9) · 全部; single_layout.
#   B  for real, on private tmux sockets with the client's two confs
#      (conf/tmux-shell.conf, conf/tmux-shell-stage.conf) and a terminal (a pty):
#      at 160 columns the list beside the session, F1–F4 reach the session as
#      before; at 60 the one-pane layout (@fleet_single, the session zoomed, the
#      list still running behind it), F3 no longer reaches the session, ⌘↩ / F9
#      keep the zoom, F1 opens the full-screen switcher; the stage's top line is
#      drawn from the record and a TAP on its title opens the switcher too (the
#      tap crosses the nested client exactly as on a phone); back at 160 the list
#      is back and nothing else changed; FLEET_CLIENT_LAYOUT=split at 60 is the old
#      rule, byte for byte (no layout of its own).
#
# Drives: bin/fleet-topbar.py, bin/fleet-sidebar.py, bin/fleet-sidebar.sh,
# bin/fleet-quickopen.py, conf/tmux-shell.conf, conf/tmux-shell-stage.conf.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import importlib.util, json, os, sys, tempfile
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(sys.argv[1], path))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
tb = load("tb", "fleet-topbar.py")
q = load("q", "fleet-quickopen.py")
errs, n = [], [0]
def eq(what, got, want):
    n[0] += 1
    if got != want:
        errs.append("%s: %r, want %r" % (what, got, want))
def has(what, text, part, yes=True):
    n[0] += 1
    if (part in text) != yes:
        errs.append("%s: %r %s %r" % (what, text, "lacks" if yes else "has", part))
rec = {"i": 3, "n": 8, "state": "working", "kind": "", "key": "#1894",
       "title": "机器上一直有会话在忙，也照样更新", "pr": "#1885●", "repo": "claude-fleet",
       "slug": "verkyyi/claude-fleet", "node": "m5", "lost": False, "direct": False, "ask": 1}
w = {}
for cols in (150, 100, 60, 44):
    text, bg = tb.fit(rec, cols, now=0)
    w[cols] = text
    eq("%d: the line is exactly the width" % cols, tb.cells(text), cols)
    eq("%d: no colour while all is well" % cols, bg, None)
    for part in ("‹ 3/8 ›", "#1894", "@m5", "●"):
        has("%d: never dropped" % cols, text, part)
has("150: everything", w[150], "PR #1885●"); has("150: the repo", w[150], "claude-fleet")
has("150: the state's word", w[150], "● working")
has("100: the repo goes first", w[100], "claude-fleet", False); has("100: then the PR", w[100], "PR #", False)
has("100: the word stays", w[100], "● working"); has("100: the title whole", w[100], rec["title"])
has("60: the word goes", w[60], "working", False)
has("44: the title clipped", w[44], "…"); has("44: still the start of the title", w[44], "机器上")
ask = dict(rec, state="needs", kind="ask")
t, bg = tb.fit(ask, 100, now=0); eq("asking: red", bg, tb.BG_ASK); has("asking: says so", t, "? asking you")
t, bg = tb.fit(dict(rec, state="needs", kind="perm"), 100, now=0)
eq("needs OK: not red", bg, None); has("needs OK: ⊘", t, "⊘ needs OK")
t, bg = tb.fit(dict(rec, lost=True, node="m4"), 100, now=0)
eq("lost: grey", bg, tb.BG_DOWN); has("lost: offline", t, "@m4 offline")
t, bg = tb.fit(rec, 100, down="1000", now=1004)
eq("reconnecting: grey", bg, tb.BG_DOWN); has("reconnecting: ⟳ 4s", t, "@m5 ⟳ 4s")
t, _ = tb.fit(rec, 100, route="relay", now=0); has("relay: 中转", t, "@m5 · 中转")
t, _ = tb.fit(dict(ask, lost=True), 100, now=0)
eq("lost wins over asking: grey", tb.fit(dict(ask, lost=True), 100, now=0)[1], tb.BG_DOWN)
t, _ = tb.fit(dict(rec, key="", title="scratch-5"), 60, now=0); has("no key: the title", t, "scratch-5")
eq("loop / done / idle glyphs", [tb.state_of({"state": s})[0] for s in ("looping", "done", "", "failed")],
   ["↻", "✓", "○", "✖"])
# the record, off the list's rows (fleet-sidebar.py bar_record)
os.environ["FLEET_SHELL"] = "1"
sb = load("sb", "fleet-sidebar.py")
rows = [["hdr", "verkyyi/claude-fleet", "", "claude-fleet", ""],
        ["@1", "working", "●", "one", "", "", "0", "", "m5", "#1", "—", "", ""],
        ["@2", "needs", "!", "two", "", "", "0", sb.tr("needs_perm"), "m4!", "#2", "#9✓", "", ""],
        ["hdr", "verkyyi/other", "", "other", ""],
        ["@3", "done", "✓", "three", "", "", "0", "", "", "—", "", "", ""]]
r = sb.bar_record(rows, "@2")
eq("record: place", (r["i"], r["n"]), (2, 3)); eq("record: perm", r["kind"], "perm")
eq("record: key / pr", (r["key"], r["pr"]), ("#2", "#9✓")); eq("record: lost", r["lost"], True)
eq("record: machine", r["node"], "m4"); eq("record: repo in a fleet of two", r["repo"], "claude-fleet")
eq("record: slug", r["slug"], "verkyyi/claude-fleet"); eq("record: waiting rows", r["ask"], 1)
eq("record: none for a row not listed", sb.bar_record(rows, "@9"), None)
eq("record: a one-repo fleet names no repo", sb.bar_record(rows[:3], "@1")["repo"], "")
eq("record: no PR → empty", sb.bar_record(rows, "@1")["pr"], "")
eq("record: a title field (14th) wins over the name", sb.bar_record(
   [rows[1][:13] + ["The real title"]], "@1")["title"], "The real title")
# single_layout: only the client's frame, by width or by setting
for frame, cols, lay, want in ((True, "60", "auto", True), (True, "160", "auto", False),
                               (True, "110", "auto", True), (True, "111", "auto", False),
                               (False, "60", "auto", False), (True, "160", "single", True),
                               (True, "60", "split", False)):
    os.environ["FLEET_CLIENT_LAYOUT"] = lay
    eq("single_layout(frame=%s, %s, %s)" % (frame, cols, lay), sb.single_layout(frame, cols, 30), want)
os.environ.pop("FLEET_CLIENT_LAYOUT")
# the full-screen switcher's groups
R = [{"key": k, "state": s, "glyph": "", "name": nm, "node": "", "group": "", "badge": ""}
     for k, s, nm in (("@1", "working", "one"), ("@2", "needs", "two"), ("@3", "done", "three"),
                      ("@4", "working", "four"))]
items = q.full_items(R, "", ["@3", "@1", "@4"], "@3")
eq("full: the sections", [t for k, t, _, _ in items if k == "sec"], ["在等你的", "最近", "全部"])
eq("full: 最近 numbered, the one in view left out",
   [(r["key"], num) for k, _, r, num in items if k == "row" and num], [("@1", 1), ("@4", 2)])
eq("full: 全部 is every row", [r["key"] for k, _, r, num in items if k == "row"][-4:], ["@1", "@2", "@3", "@4"])
eq("full: `?` → the waiting rows only", [r["key"] for k, _, r, _ in q.full_items(R, "?", [], "") if k == "row"], ["@2"])
eq("full: a query ranks", [r["key"] for k, _, r, _ in q.full_items(R, "thr", [], "")], ["@3"])
if errs:
    print("FAIL A:\n  " + "\n  ".join(errs)); sys.exit(1)
print("A: top line + record + layout rule + switcher groups: %d checks" % n[0])
PY

# --- B ---------------------------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then echo 'B SKIP: tmux missing'; exit 0; fi
python3 - "$BIN" <<'PY' || exit 1
import fcntl, json, os, pty, shlex, shutil, signal, struct, subprocess, sys, tempfile, termios, threading, time
from pathlib import Path

real_bin = Path(sys.argv[1])
real_tmux = shutil.which('tmux')
work = Path(tempfile.mkdtemp(prefix='fcl.', dir='/tmp'))   # AF_UNIX paths stop at 104 bytes
bin_dir = work / 'root' / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    (bin_dir / source.name).symlink_to(source)
(work / 'root' / 'conf').symlink_to(real_bin.parent / 'conf')
state = work / 'state'
state.mkdir()
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'), HOME=str(work),
           TERM='xterm-256color', FLEET_UI_LANG='zh', FLEET_SWITCH_STATE=str(state), FLEET_SHELL='1')
for k in ('TMUX', 'TMUX_PANE', 'FLEET_CLIENT_LAYOUT', 'FLEET_SHELL_STAGE'):
    env.pop(k, None)
(work / 's').mkdir()
sock, stage = str(work / 's' / 'fc'), str(work / 's' / 'fc-stage')
shim = work / 'path'
shim.mkdir()
# bare `tmux` (the hooks, the list) → the client's server; `-L fc` (fleet-topbar.py's
# click names the shell by its label) → the same socket file
(shim / 'tmux').write_text('#!/bin/sh\nif [ "$1" = -L ] && [ "$2" = fc ]; then shift 2; fi\n'
                           'case "$1" in -S) exec %s "$@" ;; esac\nexec %s -S %s "$@"\n'
                           % (shlex.quote(real_tmux), shlex.quote(real_tmux), shlex.quote(sock)))
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
client = None
checks = 0


def tm(*args, s=None):
    return subprocess.run([real_tmux, '-S', s or sock, *args], env=env, capture_output=True,
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


def cleanup():
    if client is not None:
        client.kill()
    for s in (sock, stage):
        subprocess.run([real_tmux, '-S', s, 'kill-server'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


def fill(name):
    text = (real_bin.parent / 'conf' / name).read_text()
    return text.replace('__BIN__', str(bin_dir)).replace('__PREFIX__', 'C-b') \
               .replace('__STAGE__', 'fc-stage').replace('__SESS__', 'fc')


def views():
    return [l.split()[0] for l in tm('list-panes', '-a', '-F', '#{pane_id} #{@sidebar}').splitlines()
            if l.endswith(' 1')]


def wopt(name):
    return tm('show-options', '-wqv', '-t', 'fc:home', name)


def zoomed():
    return tm('display-message', '-p', '-t', 'fc:home', '#{window_zoomed_flag}')


def size(cols):
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 30, cols, 0, 0))
    client.send_signal(signal.SIGWINCH)


def popup_up():
    return tm('show-options', '-gqv', '@popup_open') not in ('', '0')


try:
    # the stage: one window standing for a machine's session, the record the list writes
    (work / 'stage.conf').write_text(fill('tmux-shell-stage.conf'))
    tm('-f', str(work / 'stage.conf'), 'new-session', '-d', '-s', 'fc-stage', '-x', '160', '-y', '29',
       '-n', 'm4 x', 'cat -v', s=stage)
    (state / 'switch-bar.json').write_text(json.dumps(
        {"i": 3, "n": 8, "state": "working", "kind": "", "key": "#1894", "title": "TitleOfTheSession",
         "pr": "", "repo": "", "slug": "", "node": "m4", "lost": False, "direct": False, "ask": 0}))
    tm('set-option', '-t', 'fc-stage', '@fleet_bar_gen', '1', s=stage)
    # the client: `home` = a frame, its right pane the stage's nested client
    viewer = 'env -u TMUX %s -S %s attach -t fc-stage' % (shlex.quote(real_tmux), shlex.quote(stage))
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fc', '-x', '160', '-y', '30', '-n', 'home', viewer)
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    tm('set-environment', '-g', 'FLEET_SHELL', '1')
    tm('set-environment', '-g', 'FLEET_SWITCH_STATE', str(state))
    tm('set-environment', '-g', 'PATH', env['PATH'])
    tm('set-option', '-w', '-t', 'fc:home', '@shell_frame', '1')
    lines = [l for l in fill('tmux-shell.conf').splitlines()
             if not l.startswith('#') and not l.startswith('set -g status')]
    (work / 's.conf').write_text('\n'.join(lines) + '\n')
    tm('source-file', str(work / 's.conf'))
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
    client_env = {k: v for k, v in env.items() if k != 'TMUX'}
    client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'fc'],
                              env=client_env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    threading.Thread(target=lambda: [os.read(master, 65536) for _ in iter(int, 1)], daemon=True).start()

    # 160 columns: the list beside the session, no layout of its own
    check(wait(lambda: bool(views())), '160: the list was not drawn')
    side = views()[0]
    right = [l.split()[0] for l in tm('list-panes', '-t', 'fc:home', '-F', '#{pane_id} #{@sidebar}').splitlines()
             if not l.endswith(' 1')][0]
    check(zoomed() == '0' and wopt('@fleet_single') == '', '160: zoomed or marked single')
    top = tm('capture-pane', '-p', '-t', right).split('\n')[0]
    check(wait(lambda: '@m4' in tm('capture-pane', '-p', '-t', right).split('\n')[0], 8),
          'the stage top line does not say the record: %r' % tm('capture-pane', '-p', '-t', right).split('\n')[0])
    top = tm('capture-pane', '-p', '-t', right).split('\n')[0]
    check('‹ 3/8 ›' in top and '#1894' in top and '@m4' in top, 'the top line: %r (stage cw=%s, pane %s)' % (top, tm('list-clients', '-F', '#{client_width}', s=stage), tm('display-message', '-p', '-t', right, '#{pane_width}')))
    print('B: 160 columns — the list beside the session; the top line: %s' % top.strip())
    os.write(master, b'\x1bOR')   # F3, xterm's
    check(wait(lambda: '^[OR' in tm('capture-pane', '-p', '-t', 'fc-stage:', s=stage), 4),
          '160: F3 did not reach the session')
    print('B: 160 columns — F3 reaches the session, as before')

    # 60 columns: one pane, the list behind it
    size(60)
    check(wait(lambda: wopt('@fleet_single') == '1' and zoomed() == '1', 6),
          '60: no one-pane layout (single=%r zoomed=%r)' % (wopt('@fleet_single'), zoomed()))
    check(side in views(), '60: the list is gone — it must keep running behind the session')
    tm('send-keys', '-t', 'fc-stage:', '-R', s=stage); tm('clear-history', '-t', 'fc-stage:', s=stage)
    os.write(master, b'\x1bOR')
    time.sleep(1)
    check('^[OR' not in tm('capture-pane', '-p', '-t', 'fc-stage:', s=stage), '60: F3 still reaches the session')
    os.write(master, b'\x1b[925~')   # ⌘↩
    time.sleep(.6)
    check(zoomed() == '1' and wopt('@fleet_single') == '1', '60: ⌘↩ undid the one-pane layout')
    os.write(master, b'\x1bOP')      # F1
    check(wait(popup_up, 5), '60: F1 opened no switcher')
    os.write(master, b'\x1b')
    check(wait(lambda: not popup_up(), 5), '60: Esc did not close the switcher')
    print('B: 60 columns — one pane (the list running behind), F3 no longer reaches the session, ⌘↩ keeps it, F1 opens the switcher')
    # a tap on the top line's title, through the nested client
    top = tm('capture-pane', '-p', '-t', right).split('\n')[0]
    check(wait(lambda: '@m4' in tm('capture-pane', '-p', '-t', right).split('\n')[0], 8),
          '60: the top line lost the title: %r' % top)
    top = tm('capture-pane', '-p', '-t', right).split('\n')[0]
    x = top.index('TitleOfTheSession') + 3
    py = int(tm('display-message', '-p', '-t', right, '#{pane_top}'))
    os.write(master, ('\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x + 1, py + 1, x + 1, py + 1)).encode())
    check(wait(popup_up, 6), '60: a tap on the title opened no switcher (top line %r)' % top)
    os.write(master, b'\x1b')
    check(wait(lambda: not popup_up(), 5), 'the tapped switcher did not close')
    print('B: 60 columns — a tap on the top line\'s title opens the switcher')

    # back to 160: the list again, nothing else changed
    size(160)
    check(wait(lambda: wopt('@fleet_single') == '' and zoomed() == '0', 6), '160 again: still one pane')
    check(views() == [side], '160 again: the list is not the same one: %r' % views())
    print('B: 160 again — the list is back, the same one')

    # split: the old rule at 60 — the list taken away, no layout of its own
    tm('set-environment', '-g', 'FLEET_CLIENT_LAYOUT', 'split')
    size(60)
    check(wait(lambda: not views(), 6), 'split at 60: the list stayed')
    time.sleep(.5)
    check(wopt('@fleet_single') == '' and zoomed() == '0', 'split at 60: a layout of its own')
    print('B: FLEET_CLIENT_LAYOUT=split at 60 columns — the old rule (no list, no zoom)')
    print('B: %d checks' % checks)
except AssertionError as e:
    print('FAIL B: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
echo 'fleet-client-layout selftest: PASS'
