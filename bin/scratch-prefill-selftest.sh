#!/bin/bash
# No live tmux or agent: drive readiness, input protection and exact paste bytes.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN/scratch-prefill.py" <<'PY'
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prefill', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def drive(draft, frames, warm=False, timeout=30, fail_paste=False, probe_failure=None):
    now = [0.0]
    calls = []
    last = [None]

    def run(argv, **kwargs):
        assert argv[:3] == ['tmux', '-L', 'test-fleet'], argv
        args = argv[3:]
        calls.append((now[0], args))
        if probe_failure:
            probe_failure(now[0], argv)
        frame = frames(now[0])
        if args[0] == 'display-message' and '-p' in args:
            assert args[3] == '%42', args
            last[0] = frame
            return SimpleNamespace(stdout=frame[0].encode())
        if args[0] == 'capture-pane':
            assert args[-1] == '%42', args
            return SimpleNamespace(stdout=last[0][1].encode())
        if args[0] == 'paste-buffer' and fail_paste:
            raise subprocess.CalledProcessError(1, argv)
        return SimpleNamespace(stdout=b'')

    def sleep(seconds):
        now[0] += seconds

    with patch.object(mod.subprocess, 'run', run), \
         patch.object(mod.time, 'monotonic', lambda: now[0]), \
         patch.object(mod.time, 'sleep', sleep), patch.object(mod, 'TIMEOUT', timeout):
        with tempfile.TemporaryDirectory() as temp:
            name = Path(temp) / 'name'
            name.write_text(draft)
            with patch.object(sys, 'argv', ['prefill', 'test-fleet', '%42', str(name), str(int(warm))]), \
                 patch.object(sys, 'stderr', io.StringIO()):
                rc = mod.main()
            assert not name.exists(), 'temporary draft file leaked'
    assert not any(c[0] == 'send-keys' for _, c in calls), calls
    return calls, rc


def frame(screen='❯ \x1b[2;90mTry a task\x1b[0m\n', command='claude', cx=2, state='', cy=0, mode=0, dead=0):
    return f'{dead}\t{command}\t{cx}\t{cy}\t{state}\t{mode}\n', screen


def pastes(calls):
    return [(t, c) for t, c in calls if c[0] == 'paste-buffer']


text = '修复 Scratch 首行预填：完整名称 #tag "$(touch nope)" `literal`'
calls, rc = drive(text, lambda t: frame(), warm=True)
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 0
assert any(c[0] == 'set-buffer' and c[-2:] == ['--', text] for _, c in calls)
assert pastes(calls)[0][1][-2:] == ['-t', '%42']
assert '-p' in pastes(calls)[0][1] and '-d' in pastes(calls)[0][1]
assert any(args[0] == 'set-option' and args[-1] == 'delivered unsent' for _, args in calls)
print('ok warm: exact full Unicode draft, literal shell syntax, one paste and no Enter')

# Prompt first appears while mounting, then the screen changes at t=9. Neither
# appearance alone nor a fixed launch sleep is enough: wait until t=13.
calls, rc = drive(text, lambda t: frame(screen='❯ \n' if t < 9 else '❯ \nfooter ready\n'))
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 13, calls
print('ok cold: prompt age and screen stability both gate delivery')

calls, rc = drive(text, lambda t: frame('› \n', command='codex', cx=0 if t < 1 else 2))
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 11, calls
calls, rc = drive(text, lambda t: frame('› \n', command='codex', cy=1 if t < 1 else 0))
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 11, calls
calls, rc = drive(text, lambda t: frame('› existing draft\n', command='codex', cx=0))
assert not pastes(calls)
print('ok cold cursor paint: wait for the empty prompt cursor, but never overwrite real text')

for operation in ('display-message', 'capture-pane'):
    def fail_probe(now, argv):
        if 2 <= now < 3 and argv[3] == operation and (operation != 'display-message' or '-p' in argv):
            raise subprocess.TimeoutExpired(argv, 5)
    calls, rc = drive(text, lambda t: frame(), probe_failure=fail_probe)
    assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 13, calls
print('ok transient read failure: restart the full cold settling interval before one unsent paste')

ownership_calls = [0]
def interrupted_ownership(*args):
    ownership_calls[0] += 1
    if ownership_calls[0] == 1:
        raise subprocess.CalledProcessError(1, ['ps'])
    return True
with patch.object(mod, 'codex_owns_input', side_effect=interrupted_ownership):
    calls, rc = drive(text, lambda t: frame('› \n', command='zsh'))
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 10.5, calls
print('ok disappearing ownership process: re-prove ancestry and settle before delivery')

def fail_all_probes(now, argv):
    if argv[3] == 'display-message' and '-p' in argv:
        raise subprocess.CalledProcessError(1, argv)
calls, rc = drive(text, lambda t: frame(), timeout=2, probe_failure=fail_all_probes)
assert rc == 0 and not pastes(calls)
assert any(args[0] == 'display-message' and '-p' not in args for _, args in calls)
print('ok persistent probe failure: bounded timeout, no paste and explicit notice')

def initial_failure(now, argv):
    if now == 0 and argv[3] == 'display-message' and '-p' in argv:
        raise OSError('transient read failure')
for current in (frame('› existing draft\n', cx=2), frame(state='working'), frame(mode=1)):
    calls, rc = drive(text, lambda t: current, probe_failure=initial_failure)
    assert rc == 0 and not pastes(calls)
print('ok retry preserves existing-input, active-turn and copy-mode guards')

def fail_record(now, argv):
    if argv[3] == 'set-option':
        raise subprocess.CalledProcessError(1, argv)
calls, rc = drive(text, lambda t: frame(), warm=True, probe_failure=fail_record)
assert rc == 0 and len(pastes(calls)) == 1
print('ok diagnostic status is best-effort and cannot prevent delivery')

calls, rc = drive(text, lambda t: frame('› \x1b[2mAsk Codex\x1b[22m\n', command='codex'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
calls, rc = drive(text, lambda t: frame('❯\u00a0\x1b[38;2;2;90;0m\x1b[2m建议\x1b[0m\n', command='2.1.274'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
calls, rc = drive(text, lambda t: frame('›\n', command='codex'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
print('ok Claude/Codex: both prompt glyphs, versioned process and styled ghosts')

with patch.object(mod, 'codex_owns_input', return_value=True):
    calls, rc = drive(text, lambda t: frame('› \n', command='zsh'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
for identity, processes, expected in (
    ('codex|20|10', '10 1 zsh\n20 10 fleet-codex.sh\n30 20 codex\n', True),
    ('codex|20|10', '10 1 zsh\n20 1 fleet-codex.sh\n30 20 codex\n', False),
    ('codex|20|10', '10 1 zsh\n20 10 fleet-codex.sh\n30 20 bash\n', False),
    ('codex|20|10', '10 1 zsh\n30 10 codex\n', False),
    ('claude|20|10', '10 1 zsh\n20 10 codex\n', False),
):
    with patch.object(mod.subprocess, 'check_output', return_value=processes.encode()):
        assert mod.codex_owns_input(lambda *args: identity.encode(), '%42') is expected
print('ok shell-named Codex: live pane ancestry required; stale or foreign launchers refused')
with patch.object(mod.subprocess, 'check_output', side_effect=[
        b'10 1 zsh\n20 10 fleet-codex.sh\n30 20 codex\n', b'codex app-server --listen unix:///tmp/example\n']):
    assert not mod.codex_owns_input(lambda *args: b'codex|20|10', '%42')
print('ok backend alone: an app-server without its TUI cannot receive a draft')

for screen in ('❯\u00a0Try "write a test for conf/fleet.conf.reference"\n', '› Ask Codex to do anything\n'):
    calls, rc = drive(text, lambda t: frame(screen), warm=True)
    assert rc == 0 and len(pastes(calls)) == 1
print('ok NO_COLOR: standard startup placeholders still denote empty input')

for current in (
    frame('❯ 用户已有的草稿\n', cx=2),  # Home at the start still holds real text.
    frame('❯ Try writing a test\n', cx=2),
    frame('❯ Try "my own draft"\n', cx=22),
    frame('❯ \n', cx=4),
    frame('❯ \n', cy=1),
    frame(state='working'),
    frame(state='needs'),
    frame(mode=1),
    frame(dead=1),
):
    calls, rc = drive(text, lambda t: current, warm=True)
    assert not pastes(calls), (current, calls)
calls, rc = drive(text, lambda t: frame() if t < 2 else frame('❯ my draft\n', cx=10))
assert not pastes(calls)
print('ok existing input, early typing, active turns, copy mode and dead panes are untouched')

for current in (frame(command='zsh'), frame('Starting up...\n')):
    calls, rc = drive(text, lambda t: current, timeout=2)
    assert not pastes(calls)
    assert any(c[0] == 'display-message' and '-p' not in c for _, c in calls)
print('ok timeout: shell/stale prompt and missing input never receive the draft')

calls, rc = drive('\r\n\x1b\x7f\t中文 #tag', lambda t: frame(), warm=True)
assert any(c[0] == 'set-buffer' and c[-1] == '中文 #tag' for _, c in calls)
calls, rc = drive(' \t\n', lambda t: frame(), warm=True)
assert not calls
calls, rc = drive(text, lambda t: frame(), warm=True, fail_paste=True)
assert rc == 1 and len(pastes(calls)) == 1
assert any(args[0] == 'set-option' and args[-1] == 'paste failed; not retried' for _, args in calls)
assert any(c[0] == 'delete-buffer' for _, c in calls)
print('ok control characters cannot submit; empty drafts and failure cleanup are safe')
PY
