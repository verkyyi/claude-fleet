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


def drive(draft, frames, warm=False, timeout=30, fail_paste=False):
    now = [0.0]
    calls = []
    last = [None]

    def run(argv, **kwargs):
        assert argv[:3] == ['tmux', '-L', 'test-fleet'], argv
        args = argv[3:]
        calls.append((now[0], args))
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
print('ok warm: exact full Unicode draft, literal shell syntax, one paste and no Enter')

# Prompt first appears while mounting, then the screen changes at t=9. Neither
# appearance alone nor a fixed launch sleep is enough: wait until t=13.
calls, rc = drive(text, lambda t: frame(screen='❯ \n' if t < 9 else '❯ \nfooter ready\n'))
assert rc == 0 and len(pastes(calls)) == 1 and pastes(calls)[0][0] == 13, calls
print('ok cold: prompt age and screen stability both gate delivery')

calls, rc = drive(text, lambda t: frame('› \x1b[2mAsk Codex\x1b[22m\n', command='codex'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
calls, rc = drive(text, lambda t: frame('❯\u00a0\x1b[38;2;2;90;0m\x1b[2m建议\x1b[0m\n', command='2.1.274'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
calls, rc = drive(text, lambda t: frame('›\n', command='codex'), warm=True)
assert rc == 0 and len(pastes(calls)) == 1
print('ok Claude/Codex: both prompt glyphs, versioned process and styled ghosts')

for screen in ('❯\u00a0Try "write a test for fleet.conf.example"\n', '› Ask Codex to do anything\n'):
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
assert any(c[0] == 'delete-buffer' for _, c in calls)
print('ok control characters cannot submit; empty drafts and failure cleanup are safe')
PY
