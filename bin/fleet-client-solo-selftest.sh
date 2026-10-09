#!/bin/bash
# fleet-client-solo-selftest.sh — the newcomer's one-session view (issue #2265,
# EPIC #2259 C6): FLEET_CLIENT_LAYOUT=solo.
#
#   A  pure: fleet-sidebar.py single_layout (solo is one pane; `@fleet_layout`
#      wins over the environment); solo_ended detaches only on a change to
#      `exited` SEEN on the row in view, only in solo, and leaves the machine in
#      the `solo-ended` file; fleet-topbar.py goodbye says 「在后台继续（m5）·
#      下次输入 fleet 回来」, or — that file present — 「会话已结束 · fleet 可以恢复」
#      and takes the file.
#   B  for real, on private tmux sockets with the client's two confs and a
#      «terminal» (an outer tmux whose pane runs the attach, as fleet-shell.sh's
#      attach_client does: the attach, then `fleet-topbar.py goodbye`):
#      `fleet-shell.sh layout solo` (layout_apply) → the whole screen is the
#      session and ONE bottom line — no list, no border, no stage top line, no
#      key row; the list keeps running behind; ⌃D detaches the client, the
#      session never sees it (its `cat` would end on it) and the terminal says
#      where it is; attached again, the stage shows the same session; `layout
#      multi` → the screen is byte for byte the screen of `auto`.
#   C  fleet-shell.sh solo_resume (lifted out of the script, tmux stubbed): a
#      fresh start opens the row it left when the list's first read has it, a
#      new HOME session when it does not, and nothing before the read — nor
#      ever for a client `fleet claude|codex` started (FLEET_SHELL_NO_FIRST,
#      issue #2403: a `fleet codex` got a Claude beside it).
#   D  `fleet claude`'s OWN view (issue #2349, fleet-shell.sh `solo <m> <wid>`),
#      for real on private sockets, the client up in its saved `multi` layout:
#      D1 the terminal is that one session and one bottom line 「⌃D 放到后台 ·
#      /exit 结束会话 … m5」 — no list, no top line, a tmux server of its own —
#      and the client's `@fleet_layout` / fleet.conf are neither read nor
#      written; D2 the row going `exited` (seen while watched) ends the view: the
#      terminal is back at its prompt with 「会话已结束（m5）。」 and the view's
#      server gone; D3 a row already exited when opened ends nothing, ⌃D leaves
#      with 「会话在后台继续（m5）。`fleet` 可以找回。」, the session never saw the
#      ⌃D, the client and its layout untouched; D4 the person's own multi-session
#      client attached beside it: `fleet claude` → /exit leaves its screen, its
#      client, its server options (layout, bar), its lease, its where, its
#      switch history and fleet.conf byte for byte.
#      D5 ⌃\ (issue #2566) → a shell on this computer, this login in $HOME with
#      the fleet's commands on its PATH; ⌃\ again → the same session pane, its
#      proxy never saw the key; prefix \ the same; ⌃D from the shell → the
#      background. B does the same in the client's `solo` layout.
#      D6 接回 (issue #2564, EPIC #2563 C1): `fleet claude` with a current home
#      session — the hub's `RESUME m5 F/w1` (fleet-shell.sh home-session stubbed:
#      the line, its result file with also_open) — opens THAT session in its own
#      view, nothing new asked (no --new), the bar says 「另一台也开着：MacBook」,
#      and the terminal keeps 「回到你上一次的会话（m5）」 above it; `fleet claude
#      --new` asks with --new.
#
# Drives: bin/fleet-shell.sh, bin/fleet-home-session.sh, bin/fleet-sidebar.py, bin/fleet-sidebar.sh,
# bin/fleet-topbar.py, bin/fleet-ui-lang.sh, conf/tmux-shell.conf,
# conf/tmux-shell-stage.conf.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' || exit 1
import importlib.util, io, os, sys, tempfile, contextlib
from pathlib import Path
state = tempfile.mkdtemp(prefix='fcs.')
os.environ.update(FLEET_SWITCH_STATE=state, FLEET_UI_LANG='zh', FLEET_SHELL='1')
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(sys.argv[1], path))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
sb = load("sb", "fleet-sidebar.py")
tb = load("tb", "fleet-topbar.py")
errs, n = [], [0]
def eq(what, got, want):
    n[0] += 1
    if got != want:
        errs.append("%s: %r, want %r" % (what, got, want))
os.environ.pop("FLEET_CLIENT_LAYOUT", None)
eq("solo is one pane at 160", sb.single_layout(True, "160", 30, "solo"), True)
eq("solo never on a fleet window", sb.single_layout(False, "160", 30, "solo"), False)
os.environ["FLEET_CLIENT_LAYOUT"] = "solo"
eq("solo from the environment", sb.single_layout(True, "160", 30), True)
eq("@fleet_layout wins over the environment", sb.single_layout(True, "160", 30, "multi"), False)
os.environ.pop("FLEET_CLIENT_LAYOUT")
eq("multi = auto's rule", sb.single_layout(True, "160", 30, "multi"), False)

calls, layout = [], ["solo"]
def fake_tmux(*args):
    calls.append(args)
    return layout[0] if args[:2] == ("show-options", "-gqv") else ""
sb.tmux = fake_tmux
ended = Path(state) / "solo-ended"
rec = lambda st: {"state": st, "node": "m5"}
def detached():
    return [c for c in calls if c[0] == "detach-client"]
eq("first sight of a row: nothing", sb.solo_ended("wid:a", rec(""), "$1"), False)
eq("a row opened already exited: nothing", sb.solo_ended("wid:b", rec("exited"), "$1"), False)
eq("still exited: nothing", sb.solo_ended("wid:b", rec("exited"), "$1"), False)
sb.solo_ended("wid:a", rec("working"), "$1")
eq("working → exited on the row in view: detached", sb.solo_ended("wid:a", rec("exited"), "$1"), True)
eq("…the client of THIS session", detached(), [("detach-client", "-s", "$1")])
eq("…the machine left for goodbye", ended.read_text(), "m5\n")
ended.unlink(); calls.clear()
sb.solo_ended("wid:c", rec("done"), "$1")
eq("a switch onto an exited row is no exit", sb.solo_ended("wid:d", rec("exited"), "$1"), False)
layout[0] = "multi"
sb.solo_ended("wid:e", rec(""), "$1")
eq("not solo: never detached", sb.solo_ended("wid:e", rec("exited"), "$1"), False)
eq("…and no file", (ended.exists(), detached()), (False, []))
eq("no record (the row left the list): nothing", sb.solo_ended("wid:e", None, "$1"), False)

def bye():
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        tb.goodbye()
    return out.getvalue()
(Path(state) / "switch-bar.json").write_text('{"node": "m5", "state": "working"}\n')
eq("goodbye: left in the background", bye(), "会话在后台继续（m5）。\n下次输入 fleet 回来。\n")
ended.write_text("m4\n")
eq("goodbye: the session ended", bye(), "会话已结束（m4）。\nfleet 可以恢复。\n")
eq("goodbye: the file taken", ended.exists(), False)
eq("goodbye: once", bye(), "会话在后台继续（m5）。\n下次输入 fleet 回来。\n")
if errs:
    print("FAIL A:\n  " + "\n  ".join(errs)); sys.exit(1)
print("A: layout rule + solo_ended + goodbye: %d checks" % n[0])
PY

# --- B ---------------------------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then echo 'B SKIP: tmux missing'; else
python3 - "$BIN" <<'PY' || exit 1
import json, os, shlex, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

real_bin = Path(sys.argv[1])
# the real tmux — never the fleet's tmux-shim (a session's PATH starts with it):
# it finds `tmux` on PATH again, which is the private-socket shim below → a loop
real_tmux = next((os.path.join(d, 'tmux') for d in os.environ.get('PATH', '').split(os.pathsep)
                  if not d.endswith('/tmux-shim') and os.access(os.path.join(d, 'tmux'), os.X_OK)), None)
work = Path(tempfile.mkdtemp(prefix='fcs.', dir='/tmp'))   # AF_UNIX paths stop at 104 bytes
bin_dir = work / 'root' / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    (bin_dir / source.name).symlink_to(source)
(work / 'root' / 'conf').symlink_to(real_bin.parent / 'conf')
state = work / 'state'
state.mkdir()
(work / 's').mkdir()
sock, stage, term = (str(work / 's' / x) for x in ('fc', 'fc-stage', 'term'))
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'), HOME=str(work),
           TERM='xterm-256color', FLEET_UI_LANG='zh', FLEET_SWITCH_STATE=str(state), FLEET_SHELL='1',
           FLEET_SHELL_CACHE=str(work / 'cache'))
for k in ('TMUX', 'TMUX_PANE', 'FLEET_CLIENT_LAYOUT', 'FLEET_SHELL_STAGE'):
    env.pop(k, None)
shim = work / 'path'
shim.mkdir()
# `-L fc` / `-L fc-stage` (fleet-shell.sh's T / TS) → the two socket files; bare
# `tmux` (the hooks, the list) → the client's server
(shim / 'tmux').write_text(
    '#!/bin/sh\nif [ "$1" = -L ] && [ "$2" = fc ]; then shift 2; fi\n'
    'if [ "$1" = -L ] && [ "$2" = fc-stage ]; then shift 2; exec %s -S %s "$@"; fi\n'
    'case "$1" in -S) exec %s "$@" ;; esac\nexec %s -S %s "$@"\n'
    % (shlex.quote(real_tmux), shlex.quote(stage), shlex.quote(real_tmux), shlex.quote(real_tmux), shlex.quote(sock)))
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
checks = 0


def tm(*args, s=None):
    return subprocess.run([real_tmux, '-S', s or sock, *args], env=env, capture_output=True,
                          text=True, timeout=15).stdout.rstrip('\n')


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def wait(predicate, secs=8):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.1)
    return False


def cleanup():
    for s in (term, sock, stage):
        subprocess.run([real_tmux, '-S', s, 'kill-server'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


def fill(name):
    text = (real_bin.parent / 'conf' / name).read_text()
    return text.replace('__BIN__', str(bin_dir)).replace('__PREFIX__', 'C-b') \
               .replace('__STAGE__', 'fc-stage').replace('__SESS__', 'fc')


def shell(*args):
    return subprocess.run(['bash', str(bin_dir / 'fleet-shell.sh'), '--test-identity', *args],
                          env=env, capture_output=True, text=True, timeout=30)


def screen():
    return tm('capture-pane', '-p', '-t', 'term:', s=term)


def attach():
    """The «terminal»: the attach, then what attach_client prints after it."""
    t = '%s -S %s' % (shlex.quote(real_tmux), shlex.quote(sock))
    cmd = 'env -u TMUX %s attach -t fc; python3 %s goodbye "node=$(%s show-options -gqv @fleet_view_node)"; exec sleep 600' % (
        t, shlex.quote(str(bin_dir / 'fleet-topbar.py')), t)
    subprocess.run([real_tmux, '-S', term, '-f', '/dev/null', 'new-session', '-d', '-s', 'term',
                    '-x', '120', '-y', '31', cmd], env={k: v for k, v in env.items() if k != 'TMUX'})
    tm('set-option', '-g', 'status', 'off', s=term)


def clients():
    return tm('list-clients', '-F', '#{client_name}')


try:
    # the stage: one window standing for the session (`cat`: a ⌃D reaching it ends it)
    (work / 'stage.conf').write_text(fill('tmux-shell-stage.conf'))
    tm('-f', str(work / 'stage.conf'), 'new-session', '-d', '-s', 'fc-stage', '-x', '120', '-y', '30',
       '-n', 'm5 ~', "printf 'CLAUDE-SESSION\\n'; exec cat", s=stage)
    tm('set-window-option', '-t', 'fc-stage:', '@remote', 'm5:fleet/abc', s=stage)
    (state / 'switch-bar.json').write_text(json.dumps({"state": "working", "node": "m5", "title": "~"}))
    viewer = 'env -u TMUX %s -S %s attach -t fc-stage' % (shlex.quote(real_tmux), shlex.quote(stage))
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fc', '-x', '120', '-y', '30', '-n', 'home', viewer)
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    # the list's own state dir: with no rows here it would write an empty record
    # over the one the stage's top line reads (the real list writes the row in view)
    (work / 'liststate').mkdir()
    for k, v in (('FLEET_SHELL', '1'), ('FLEET_SWITCH_STATE', str(work / 'liststate')), ('PATH', env['PATH']),
                 ('FLEET_SHELL_STAGE', 'fc-stage'), ('TMPDIR', str(work)), ('FLEET_UI_LANG', 'zh')):
        tm('set-environment', '-g', k, v)
    tm('set-option', '-w', '-t', 'fc:home', '@shell_frame', '1')
    (work / 's.conf').write_text(fill('tmux-shell.conf'))
    tm('source-file', str(work / 's.conf'))
    env.pop('TMUX')

    # auto, as today: the list beside the session — the screen multi must equal
    attach()
    # the bar says 新任务 too: wait for the list itself (issue #2627)
    check(wait(lambda: '暂无会话' in screen() and 'CLAUDE-SESSION' in screen(), 10), 'auto: no list: %r' % screen())
    time.sleep(1.5)
    auto = screen()
    tm('kill-server', s=term)

    # solo
    r = shell('layout', 'solo', 'fc')
    check(r.returncode == 0, 'layout solo: rc %d %s' % (r.returncode, r.stderr))
    check(tm('show-options', '-gqv', '@fleet_layout') == 'solo', 'no @fleet_layout solo')
    check(tm('show-options', '-gqv', 'status', s=stage) == 'off', 'solo: the stage top line is still on')
    tm('set-option', '-g', '@fleet_view_node', 'm5')   # what the list writes off the row in view
    attach()
    def solo_drawn():
        rows = screen().split('\n')
        return 'CLAUDE-SESSION' in rows[0] and '⌃D 放到后台' in rows[-1]
    check(wait(solo_drawn, 10), 'solo: not the one-session screen:\n%s' % screen())
    time.sleep(1)
    rows = screen().split('\n')
    solo = '\n'.join(rows)
    check(rows[0].startswith('CLAUDE-SESSION'), 'solo: the session is not the first line: %r' % rows[0])
    above = '\n'.join(rows[:-1])
    check('新任务' not in above and '│' not in above and '─' not in above,
          'solo: a list or a border on screen:\n%s' % solo)
    # the bar is the same three things as any layout's (issue #2365): who is
    # signed in, the ⟳ slot, the keys — ⌃D 放到后台 in ⌘↑↓'s place, no machine
    check('⌘P 会话与动作' in rows[-1] and '⌃D 放到后台' in rows[-1] and '⌘↑↓' not in rows[-1],
          'solo: the bar: %r' % rows[-1])
    panes = tm('list-panes', '-t', 'fc:home', '-F', '#{@sidebar}')
    check('1' in panes.split('\n'), 'solo: the list stopped running behind the session')
    check(tm('display-message', '-p', '-t', 'fc:home', '#{window_zoomed_flag}') == '1', 'solo: not zoomed')
    print('B: solo — the session and one line:\n    %r' % rows[-1].strip())

    # ⌃\ (issue #2566): to a shell on this computer — a window of the client's
    # own, as this login in $HOME — and ⌃\ again back to the session: its pane,
    # its stage window and its `cat` exactly where they were (a ⌃\ reaching it
    # would SIGQUIT it); prefix \ the same
    stage_at = tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{pane_id} #{pane_pid}', s=stage)
    home_pane = tm('display-message', '-p', '-t', 'fc:home', '#{pane_id}')

    def here():
        return tm('display-message', '-p', '-t', 'fc:', '#{window_name}|#{@solo_shell}|#{pane_id}|#{pane_current_path}')
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-\\'])
    check(wait(lambda: here().split('|')[1] == '1'), 'solo ⌃\\: not on a shell window: %r' % here())
    name, _, sh_pane, cwd = here().split('|')
    check(name == '本机shell' and os.path.realpath(cwd) == os.path.realpath(str(work)),
          'solo ⌃\\: the shell is not this login\'s, in $HOME: %r' % here())
    check(wait(lambda: '⌃\\ 回到会话' in screen().split('\n')[-1]), 'solo ⌃\\: the bar: %r' % screen().split('\n')[-1])
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-\\'])
    check(wait(lambda: here().split('|')[0] == 'home'), 'solo ⌃\\ again: not back on the session: %r' % here())
    check(here().split('|')[2] == home_pane, 'solo ⌃\\: the session pane changed')
    check(wait(lambda: solo_drawn() and '⌃\\ 本机 shell' in screen().split('\n')[-1]),
          'solo ⌃\\ back: the screen:\n%s' % screen())
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-b', '\\'])
    check(wait(lambda: here().split('|')[2] == sh_pane), 'solo prefix \\: not the same shell again: %r' % here())
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-b', '\\'])
    check(wait(lambda: here().split('|')[0] == 'home'), 'solo prefix \\ again: not back: %r' % here())
    check(tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{pane_id} #{pane_pid}', s=stage) == stage_at,
          'solo ⌃\\: the session moved or saw the key')
    print('B: ⌃\\ → the shell (%s) → ⌃\\ → the session, its pane untouched; prefix \\ the same' % cwd)

    # ⌃D: the client goes, the session stays and never saw it
    before = tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{@remote}', s=stage)
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-d'])
    check(wait(lambda: clients() == ''), 'solo: ⌃D did not detach (clients %r)' % clients())
    check(wait(lambda: '下次输入 fleet 回来。' in screen()), 'solo: no goodbye after ⌃D:\n%s' % screen())
    bye = [l for l in screen().split('\n') if l.strip()]
    check('会话在后台继续（m5）。' in bye, 'solo: the goodbye lines: %r' % bye)
    time.sleep(.5)
    check(tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{@remote}', s=stage) == before,
          'solo: ⌃D reached the session (its cat ended)')
    check(tm('has-session', '-t', 'fc') == '' and subprocess.run(
        [real_tmux, '-S', sock, 'has-session', '-t', 'fc'], env=env).returncode == 0, 'solo: the client server went')
    print('B: ⌃D — detached, the session untouched, the terminal says: %s' % ' '.join(bye[-2:]))
    tm('kill-server', s=term)
    attach()
    check(wait(solo_drawn, 10), 'solo: attached again, not the session:\n%s' % screen())
    check(tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{@remote}', s=stage) == before,
          'solo: attached again, another session')
    print('B: attached again — the same session (%s)' % before)
    tm('kill-server', s=term)

    # multi: today's screen, byte for byte
    r = shell('layout', 'multi', 'fc')
    check(r.returncode == 0, 'layout multi: rc %d %s' % (r.returncode, r.stderr))
    check(tm('show-options', '-gqv', 'status', s=stage) == 'on', 'multi: the stage top line stayed off')
    attach()
    check(wait(lambda: '暂无会话' in screen(), 10), 'multi: no list:\n%s' % screen())
    # a slow runner draws the list a beat late (issue #2627): give it time to settle
    wait(lambda: screen() == auto, 10)
    multi = screen()
    check(multi == auto, 'multi: not today\'s screen:\n--- auto\n%s\n--- multi\n%s' % (auto, multi))
    subprocess.run([real_tmux, '-S', term, 'send-keys', '-t', 'term:', 'C-d'])
    check(wait(lambda: tm('display-message', '-p', '-t', 'fc-stage:', '#{window_id} #{@remote}', s=stage) != before),
          'multi: ⌃D did not reach the session (its cat is still there)')
    print('B: multi — the screen of auto, byte for byte; ⌃D goes to the session')
    print('B: %d checks' % checks)
except AssertionError as e:
    print('FAIL B: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
fi

# --- C ---------------------------------------------------------------------------
W=$(mktemp -d /tmp/fcs-c.XXXXXX)
trap 'rm -rf "$W"' EXIT
{
  sed -n '/^solo_resume() {/,/^}/p' "$BIN/fleet-shell.sh"
  cat <<'SH'
T() { :; }
SH
} > "$W/lib.sh"
grep -q '^solo_resume() {' "$W/lib.sh" || { echo 'FAIL C: no solo_resume in fleet-shell.sh'; exit 1; }
fails=0
# run_case <name> <key> <rows file content | -> <want>
run_case() {
  local name="$1" key="$2" rows="$3" want="$4" nofirst="${5:-0}" got
  rm -rf "$W/c" && mkdir -p "$W/c/tmp/.claude-dash/global" "$W/c/conf" "$W/c/cache"
  : > "$W/c/conf/home-session.first"
  [ "$rows" = - ] || printf '%s\n' "$rows" > "$W/c/tmp/.claude-dash/global/remote_fc"
  (
    # shellcheck disable=SC2034  # read by solo_resume, sourced below
    FLEET_CLIENT_LAYOUT=solo CONF_DIR="$W/c/conf" CACHE="$W/c/cache" SESS=fc TMPDIR="$W/c/tmp" HOME="$W/c"
    # shellcheck disable=SC2034
    FLEET_HOME_OPEN_WAIT=1 FLEET_HOME_OPEN_CMD="echo open" FLEET_SOLO_NEW_CMD="echo new"
    # shellcheck disable=SC2034
    FLEET_SHELL_NO_FIRST=$nofirst
    . "$W/lib.sh"
    solo_resume "$key" "$(( $(date +%s) - 5 ))"
    wait
  )
  got=$(cat "$W/c/cache/solo-resume.log" 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "C: $name → ${want:-nothing}"; else echo "FAIL C: $name: got '$got', want '$want'"; fails=1; fi
}
run_case 'the row it left is on the list' wid:fleet/abc $'wid:fleet/abc\037x' 'open wid:fleet/abc'
run_case 'the row it left is gone' wid:fleet/abc $'wid:fleet/zzz\037x' 'new'
run_case 'no row left at all' '' $'wid:fleet/zzz\037x' 'new'
run_case 'no read in time' wid:fleet/abc - ''
# `fleet codex` started the client for its own ask (issue #2403): no second
# session beside it — neither the row it left nor a new (Claude) HOME one
run_case 'fleet claude|codex started it' '' $'wid:fleet/zzz\037x' '' 1
run_case 'fleet claude|codex started it, a row left' wid:fleet/abc $'wid:fleet/abc\037x' '' 1
[ "$fails" = 0 ] || exit 1

# --- D ---------------------------------------------------------------------------
# the real tmux — never the fleet's tmux-shim (a session's PATH starts with it)
REAL_TMUX_D=''
_ifs=$IFS; IFS=:
for d in $PATH; do
  case "$d" in */tmux-shim) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX_D="$d/tmux"; break; }
done
IFS=$_ifs
if [ -z "$REAL_TMUX_D" ]; then
  echo 'D: no tmux — skipped'
else
python3 - "$BIN" "$REAL_TMUX_D" <<'PY' || exit 1
import os, shlex, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

real_bin, real_tmux = Path(sys.argv[1]), sys.argv[2]
work = Path(tempfile.mkdtemp(prefix='fcd.', dir='/tmp'))   # AF_UNIX paths stop at 104 bytes
socks = work / 's'
socks.mkdir()
bin_dir = work / 'root' / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    (bin_dir / source.name).symlink_to(source)
(work / 'root' / 'conf').symlink_to(real_bin.parent / 'conf')
cache = work / 'cache'
(cache / 'bin').mkdir(parents=True)
for source in real_bin.iterdir():
    if source.name != 'fleet-remote-view.sh':
        (cache / 'bin' / source.name).symlink_to(source)
# the session on its machine: a proxy that says which one it shows, then reads its
# keys (a ⌃D reaching it would end the `cat` and leave the eof file)
eof = work / 'eof'
(cache / 'bin' / 'fleet-remote-view.sh').write_text(
    '#!/bin/bash\nprintf "REMOTE-SESSION %%s %%s\\n" "$3" "$4"\ncat >/dev/null\necho eof > %s\n' % shlex.quote(str(eof)))
(cache / 'bin' / 'fleet-remote-view.sh').chmod(0o755)
stage_conf = (real_bin.parent / 'conf' / 'tmux-shell-stage.conf').read_text() \
    .replace('__BIN__', str(cache / 'bin')).replace('__SESS__', 'fc').replace('__STAGE__', 'fc-stage')
(cache / 'tmux-stage.conf').write_text(stage_conf)
rows = cache / 'tmp' / '.claude-dash' / 'global' / 'remote_fc'
rows.parent.mkdir(parents=True)
conf_dir = work / 'conf'
conf_dir.mkdir()
saved = '[client]\nexport FLEET_CLIENT_LAYOUT=multi\n'
(conf_dir / 'fleet.conf').write_text(saved)
sock, term = str(socks / 'fc'), str(socks / 'term')
shim = work / 'path'
shim.mkdir()
# `-L fc` (the client's server) and `-L fc-solo-<pid>` (the view's own) → socket files
(shim / 'tmux').write_text(
    '#!/bin/sh\nif [ "$1" = -L ]; then l=$2; shift 2; exec %s -S %s/"$l" "$@"; fi\nexec %s "$@"\n'
    % (shlex.quote(real_tmux), shlex.quote(str(socks)), shlex.quote(real_tmux)))
(shim / 'tmux').chmod(0o755)
env = dict(os.environ, HOME=str(work), TERM='xterm-256color', FLEET_UI_LANG='zh', FLEET_CONF_DIR=str(conf_dir), SHELL='/bin/sh',
           FLEET_SHELL_CACHE=str(cache), FLEET_SOLO_WATCH_EVERY='0.2', PATH=str(shim) + os.pathsep + os.environ['PATH'])
for k in ('TMUX', 'TMUX_PANE', 'FLEET_CLIENT_LAYOUT', 'FLEET_SHELL_SESSION'):
    env.pop(k, None)
checks = 0


def tm(*args, s=sock):
    return subprocess.run([real_tmux, '-S', s, *args], env=env, capture_output=True, text=True, timeout=15)


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def wait(predicate, secs=8):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.1)
    return False


def solos():
    return [p for p in socks.iterdir() if p.name.startswith('fc-solo-') and tm('has-session', s=str(p)).returncode == 0]


def cleanup():
    for p in socks.iterdir():
        tm('kill-server', s=str(p))
    shutil.rmtree(work, ignore_errors=True)


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


def screen():
    return tm('capture-pane', '-p', '-t', 'term:', s=term).stdout.rstrip('\n')


def terminal():
    """The «terminal»: `fleet claude`'s step 3 in it, then the prompt."""
    tm('kill-server', s=term)
    if eof.exists():
        eof.unlink()
    cmd = 'bash %s solo m5 F/w1 fc; echo PROMPT; exec sleep 600' % shlex.quote(str(bin_dir / 'fleet-shell.sh'))
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'term', '-x', '100', '-y', '24', cmd, s=term)
    tm('set-option', '-g', 'status', 'off', s=term)


def drawn():
    lines = screen().split('\n')
    return 'REMOTE-SESSION m5 F/w1' in lines[0] and '⌃D 放到后台 · /exit 结束会话' in lines[-1]


try:
    # the client, in its saved multi-session layout
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fc', '-x', '120', '-y', '30', 'sleep 600')
    tm('set-option', '-g', '@fleet_layout', 'multi')

    # D1. the whole terminal is that session and one bottom line — no list, no
    # top line — and the client's layout is neither read nor written
    rows.write_text('#node\x1fm5\n')
    terminal()
    check(wait(drawn, 10), 'D1: not the one-session screen:\n%s' % screen())
    lines = screen().split('\n')
    check(lines[-1].rstrip().endswith('m5'), 'D1: no machine on the bar: %r' % lines[-1])
    check('新任务' not in screen() and '│' not in screen() and '⌘N' not in screen(), 'D1: a list or a key row:\n%s' % screen())
    check(len(solos()) == 1, 'D1: not one view server of its own: %r' % solos())
    check(tm('show-options', '-gqv', '@fleet_layout').stdout.strip() == 'multi', 'D1: the client\'s layout moved')
    print('D1: one session, one line: %r' % lines[-1].strip())

    # D2. the session ending (`exited`, seen while watched) → the view goes, the
    # terminal is back at its prompt with one line
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fworking\n')
    time.sleep(1)
    check(drawn(), 'D2: the view went before the session ended:\n%s' % screen())
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fexited\n')
    check(wait(lambda: 'PROMPT' in screen()), 'D2: /exit did not end the view:\n%s' % screen())
    check('会话已结束（m5）。' in screen(), 'D2: the last line: %r' % screen())
    check(solos() == [], 'D2: the view\'s server stayed: %r' % solos())
    print('D2: /exit → %r, back at the prompt' % [l for l in screen().split('\n') if l.strip()][-2])

    # D3. ⌃D → to the background: the session never sees it (its cat runs on until
    # the view drops the connection), the terminal says where it is
    terminal()
    check(wait(drawn, 10), 'D3: not the one-session screen:\n%s' % screen())
    time.sleep(.6)
    check(drawn(), 'D3: a session already exited when opened ended the view:\n%s' % screen())
    tm('send-keys', '-t', 'term:', 'C-d', s=term)
    check(wait(lambda: 'PROMPT' in screen()), 'D3: ⌃D did not leave the view:\n%s' % screen())
    check('会话在后台继续（m5）。`fleet` 可以找回。' in screen(), 'D3: the last line: %r' % screen())
    check(not eof.exists(), 'D3: ⌃D reached the session')
    check(solos() == [], 'D3: the view\'s server stayed: %r' % solos())
    check(tm('has-session', '-t', 'fc').returncode == 0, 'D3: the client went with the view')
    check(tm('show-options', '-gqv', '@fleet_layout').stdout.strip() == 'multi', 'D3: the client\'s layout moved')
    check((conf_dir / 'fleet.conf').read_text() == saved, 'D3: fleet.conf was written')
    print('D3: ⌃D → %r; the client and its layout untouched' % [l for l in screen().split('\n') if l.strip()][-2])

    # D4. the person's own multi-session client attached beside it (the issue's
    # acceptance leg): `fleet claude` → /exit leaves its screen, its client, its
    # lease, its where, its layout and its switch history byte for byte
    reg = str(socks / 'reg')
    tm('send-keys', '-t', 'fc:', 'clear; printf "REGULAR-CLIENT list|session\\n"', 'Enter')
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'reg', '-x', '110', '-y', '26',
       'env -u TMUX %s -S %s attach -t fc' % (shlex.quote(real_tmux), shlex.quote(sock)), s=reg)
    check(wait(lambda: tm('list-clients', '-F', '#{client_name}').stdout.strip() != ''), 'D4: the regular client did not attach')
    cl = cache / 'tmp'
    (cl / 'client.lease').write_text('L9\n')
    (cl / 'client.where.json').write_text('{"device": "MacBook"}\n')
    sw_state = work / 'switch'
    sw_state.mkdir()
    (sw_state / 'switch.json').write_text('{"mru": ["wid:F/w7"]}\n')
    tm('set-environment', '-g', 'FLEET_SWITCH_STATE', str(sw_state))
    time.sleep(.5)

    def regular():
        return (tm('capture-pane', '-p', '-t', 'reg:', s=reg).stdout,
                tm('list-clients', '-F', '#{client_name} #{client_session}').stdout,
                tm('show-options', '-g').stdout,
                (cl / 'client.lease').read_text(), (cl / 'client.where.json').read_text(),
                sorted((p.name, p.read_text()) for p in sw_state.iterdir()),
                (conf_dir / 'fleet.conf').read_text())
    before = regular()
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fworking\n')
    terminal()
    check(wait(drawn, 10), 'D4: not the one-session screen:\n%s' % screen())
    time.sleep(.6)
    check(regular() == before, 'D4: the view moved the regular client while open')
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fexited\n')
    check(wait(lambda: 'PROMPT' in screen()), 'D4: /exit did not end the view:\n%s' % screen())
    check('会话已结束（m5）。' in screen(), 'D4: the last line: %r' % screen())
    time.sleep(.5)
    after = regular()
    for i, what in enumerate(('screen', 'clients', 'options (layout, bar)', 'lease', 'where', 'switch history', 'fleet.conf')):
        check(after[i] == before[i], 'D4: /exit changed the regular client\'s %s:\n%r\n→ %r' % (what, before[i], after[i]))
    tm('kill-server', s=reg)
    print('D4: a regular client beside it — screen, client, lease, where, layout, switch history untouched')

    # D5. ⌃\ (issue #2566): to a shell on THIS computer — the view's second
    # window, this login in $HOME with the fleet's commands on its PATH — and ⌃\
    # again back: the session's window and pane where they were, its proxy never
    # saw the key (a ⌃\ reaching it would SIGQUIT the view away); prefix \ the
    # same; ⌃D from the shell still leaves the view to the background
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fworking\n')
    terminal()
    check(wait(drawn, 10), 'D5: not the one-session screen:\n%s' % screen())
    check('⌃\\ 本机 shell' in screen().split('\n')[-1], 'D5: no ⌃\\ on the bar: %r' % screen().split('\n')[-1])
    view = str(solos()[0])
    vname = os.path.basename(view)

    def at():
        return tm('display-message', '-p', '-t', '=%s:' % vname,
                  '#{window_id}|#{@solo_shell}|#{pane_id}|#{pane_current_path}', s=view).stdout.strip()
    sess_win, _, sess_pane, _ = at().split('|')
    tm('send-keys', '-t', 'term:', 'C-\\', s=term)
    check(wait(lambda: at().split('|')[1] == '1'), 'D5: ⌃\\ did not open the shell: %r' % at())
    sh_win, _, sh_pane, cwd = at().split('|')
    check(os.path.realpath(cwd) == os.path.realpath(str(work)), 'D5: the shell is not in $HOME: %r' % cwd)
    tm('send-keys', '-t', sh_pane, '-l', 'echo "$PATH" > %s' % shlex.quote(str(work / 'shell-path')), s=view)
    tm('send-keys', '-t', sh_pane, 'Enter', s=view)
    check(wait(lambda: (work / 'shell-path').exists() and (work / 'shell-path').read_text().strip() != ''),
          'D5: the shell did not run a command')
    spath = (work / 'shell-path').read_text()
    check(str(work / '.local' / 'bin') in spath and str(cache / 'bin') in spath,
          'D5: no fleet on the shell\'s PATH: %r' % spath)
    check(wait(lambda: '⌃\\ 回到会话' in screen().split('\n')[-1]), 'D5: the shell\'s bar: %r' % screen().split('\n')[-1])
    tm('send-keys', '-t', 'term:', 'C-\\', s=term)
    check(wait(lambda: at().split('|')[0] == sess_win), 'D5: ⌃\\ again did not come back: %r' % at())
    check(at().split('|')[2] == sess_pane and wait(drawn), 'D5: the session pane changed:\n%s' % screen())
    tm('send-keys', '-t', 'term:', 'C-b', '\\', s=term)
    check(wait(lambda: at().split('|')[2] == sh_pane), 'D5: prefix \\ is not the same shell: %r' % at())
    tm('send-keys', '-t', 'term:', 'C-b', '\\', s=term)
    check(wait(lambda: at().split('|')[2] == sess_pane), 'D5: prefix \\ again did not come back: %r' % at())
    check(not eof.exists(), 'D5: ⌃\\ reached the session')
    tm('send-keys', '-t', 'term:', 'C-\\', s=term)
    check(wait(lambda: at().split('|')[1] == '1'), 'D5: not on the shell for ⌃D')
    tm('send-keys', '-t', 'term:', 'C-d', s=term)
    check(wait(lambda: 'PROMPT' in screen()), 'D5: ⌃D from the shell did not leave the view:\n%s' % screen())
    check('会话在后台继续（m5）。`fleet` 可以找回。' in screen() and not eof.exists(), 'D5: the last line: %r' % screen())
    print('D5: ⌃\\ → a shell in %s → ⌃\\ → the same session pane; prefix \\ the same; ⌃D → the background' % cwd)

    # D6. 接回 (issue #2564): the hub says the person's current home session is
    # F/w1 on m5 — `fleet claude` goes back to it in its own view
    calls = work / 'home-calls'
    stub = work / 'home-shell.sh'
    stub.write_text('''#!/bin/bash
printf '%%s\\n' "$*" >> %(calls)s
case "$1" in
  running) exit 0 ;;
  home-session)
    [ -n "${FLEET_PLACE_RESULT:-}" ] && printf '{"worker_id": "F/w1", "machine": "m5", "resume": true, "also_open": ["MacBook"]}' > "$FLEET_PLACE_RESULT"
    printf '回到你上一次的会话（m5）\\n' >&2
    printf 'RESUME m5 F/w1\\t回到你上一次的会话（m5）\\n' ;;
  solo) exec bash %(shell)s solo "$2" "$3" fc ;;
esac
''' % {'calls': shlex.quote(str(calls)), 'shell': shlex.quote(str(bin_dir / 'fleet-shell.sh'))})
    stub.chmod(0o755)
    tm('kill-server', s=term)
    if eof.exists():
        eof.unlink()
    rows.write_text('wid:F/w1\x1fm5\x1f\x1f\x1f\x1fidle\n')
    cmd = 'FLEET_HOME_SHELL=%s bash %s claude; echo PROMPT; exec sleep 600' % (
        shlex.quote(str(stub)), shlex.quote(str(bin_dir / 'fleet-home-session.sh')))
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'term', '-x', '100', '-y', '24', cmd, s=term)
    tm('set-option', '-g', 'status', 'off', s=term)
    check(wait(drawn, 10), 'D6: not the one-session screen of F/w1:\n%s' % screen())
    bar = screen().split('\n')[-1]
    check('另一台也开着：MacBook' in bar and bar.rstrip().endswith('m5'), 'D6: the bar: %r' % bar)
    asked = calls.read_text().splitlines()
    check(any(a.startswith('home-session claude') and '--new' not in a for a in asked), 'D6: the ask: %r' % asked)
    check(any(a == 'solo m5 F/w1' for a in asked), 'D6: not the view of F/w1: %r' % asked)
    tm('send-keys', '-t', 'term:', 'C-d', s=term)
    check(wait(lambda: 'PROMPT' in screen()), 'D6: ⌃D did not leave the view:\n%s' % screen())
    check('回到你上一次的会话（m5）' in screen(), 'D6: the terminal never said it went back:\n%s' % screen())
    check(not eof.exists(), 'D6: ⌃D reached the session')
    calls.write_text('')
    tm('kill-server', s=term)
    cmd = 'FLEET_HOME_SHELL=%s bash %s claude --new; echo PROMPT; exec sleep 600' % (
        shlex.quote(str(stub)), shlex.quote(str(bin_dir / 'fleet-home-session.sh')))
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'term', '-x', '100', '-y', '24', cmd, s=term)
    check(wait(lambda: any(a.startswith('home-session claude') for a in (calls.read_text().splitlines() if calls.exists() else []))),
          'D6: --new asked nothing')
    check(any('--new' in a for a in calls.read_text().splitlines() if a.startswith('home-session')), 'D6: --new not passed: %r' % calls.read_text())
    tm('send-keys', '-t', 'term:', 'C-d', s=term)
    wait(lambda: 'PROMPT' in screen())
    print('D6: 接回 — RESUME → the view of F/w1, 「另一台也开着」 on its bar; --new asks for a new one')
    print('D: %d checks' % checks)
except AssertionError as e:
    print('FAIL D: %s' % e)
    cleanup()
    sys.exit(1)
cleanup()
PY
fi
echo 'fleet-client-solo selftest: PASS'
