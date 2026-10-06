#!/usr/bin/env python3
"""The recovery page a session stops on when its agent exits (issue #1784).

fleet-session-wrap.sh runs this in the pane the agent just left. It draws one
screenful — what happened, that the window and the conversation are still here,
and the three keys — and exits with the operator's choice:

    10  ↵  resume the same conversation
    11  r  start a new one in this window
    12  q  recycle the window (the old close-on-exit, now on purpose)

Every other byte is discarded, so nothing typed here reaches the next agent. It
is the sleeping page's frame (bin/fleet_sleep_park.py: the same clip / width /
rules / colours), not a second look: a title line, a rule, the body, a rule, the
keys. `render` is pure — facts + size in, one screenful out — so the selftest
checks the page without a terminal.
"""
import argparse
import os
import re
import select
import signal
import sys
import termios

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_sleep_park import BOLD, DIM, RED, RESET, YELLOW, SGR_MOUSE, clip, ui_lang, width  # noqa: E402

RESUME, NEW, QUIT = 10, 11, 12

TEXT = {
    'zh': {'exited': '会话已退出', 'ctrl_c': '（按了 Ctrl+C）', 'signal': '会话被结束（信号 {n}）',
           'failed': '会话异常退出（退出码 {n}）', 'kept': '这个窗口不会关，原来的对话还在。',
           'no_sid': '没有记下对话 id：回车接着这个目录里最近的一次对话。',
           'resume': '接着原对话', 'new': '新开', 'quit': '回收这个窗口'},
    'en': {'exited': 'Session exited', 'ctrl_c': ' (Ctrl+C)', 'signal': 'Session ended (signal {n})',
           'failed': 'Session exited abnormally (code {n})', 'kept': 'This window stays open; the conversation is still here.',
           'no_sid': 'No conversation id recorded: Enter resumes the latest one in this directory.',
           'resume': 'resume the conversation', 'new': 'new session', 'quit': 'recycle this window'},
}


def headline(rc, words):
    """What happened, from the agent's exit status: 0 / 130 are the operator's own
    exit, >128 a signal (137 = kill -9), anything else a failure."""
    if rc == 0: return words['exited'], YELLOW
    if rc == 130: return words['exited'] + words['ctrl_c'], YELLOW
    if rc > 128: return words['signal'].format(n=rc - 128), RED
    return words['failed'].format(n=rc), RED


def keys_line(words):
    return (BOLD + '↵' + RESET + ' ' + words['resume'] + '   ' + BOLD + 'r' + RESET + ' ' + words['new']
            + '   ' + BOLD + 'q' + RESET + ' ' + words['quit'])


def render(facts, cols, rows):
    """One screenful: headline (+ the window's title), a rule, what is kept, a
    rule, the keys. The keys sit on the LAST row, which a click also presses."""
    cols, rows = max(int(cols), 10), max(int(rows), 3)
    words = TEXT[facts.get('lang') or ui_lang()]
    fit = lambda text: clip(text, cols - 1)
    head, color = headline(int(facts.get('rc', 0)), words)
    title = facts.get('title') or ''
    first = color + BOLD + head + RESET + (DIM + ' · ' + title + RESET if title else '')
    body = [words['kept']]
    sid = facts.get('sid') or ''
    body.append(DIM + (facts.get('agent') or 'claude') + ' ' + sid[:8] + '…' + RESET if sid else DIM + words['no_sid'] + RESET)
    rule = DIM + '─' * (cols - 1) + RESET
    lines = [fit(first), rule, ''] + [fit(l) for l in body]
    lines = lines[:max(rows - 2, 1)]
    lines += [''] * max(rows - len(lines) - 2, 0) + [rule, fit(keys_line(words))]
    return '\n'.join(lines[:rows])


def choice(chunk, key_row):
    """The first press a read holds: ↵ (or a left click on the keys row) resumes,
    r starts new, q recycles. None = nothing on this page's keys (discarded)."""
    text = chunk.decode('utf-8', 'replace') if isinstance(chunk, bytes) else chunk
    for m in SGR_MOUSE.finditer(text):
        button, row = int(m.group(1)), int(m.group(3))
        if m.group(4) == 'M' and button & ~(4 | 8 | 16) == 0 and row == key_row: return RESUME
    text = SGR_MOUSE.sub('', text)
    text = re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|O.|[@-Z\\-_])', '', text)
    for ch in text:
        if ch in '\r\n': return RESUME
        if ch in 'rR': return NEW
        if ch in 'qQ': return QUIT
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rc', type=int, default=0)
    p.add_argument('--agent', default='claude')
    p.add_argument('--sid', default='')
    p.add_argument('--title', default='')
    p.add_argument('--print', action='store_true', help='draw once at 80x24 and exit 0 (selftest)')
    a = p.parse_args()
    facts = {'rc': a.rc, 'agent': a.agent, 'sid': a.sid, 'title': a.title}
    if a.print:
        sys.stdout.write(render(facts, 80, 24) + '\n')
        return 0
    rd, wr = os.pipe()
    for fd in (rd, wr): os.set_blocking(fd, False)
    signal.set_wakeup_fd(wr)
    signal.signal(signal.SIGWINCH, lambda *_: None)
    for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP): signal.signal(sig, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(1))
    saved = None
    if os.isatty(0):
        saved = termios.tcgetattr(0); mode = termios.tcgetattr(0)
        mode[0] &= ~(termios.IXON | termios.ICRNL)
        mode[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN)
        mode[6][termios.VMIN], mode[6][termios.VTIME] = 1, 0
        termios.tcsetattr(0, termios.TCSANOW, mode)
    mouse = lambda on: sys.stdout.write('\033[?1000' + ('h' if on else 'l') + '\033[?1006' + ('h' if on else 'l'))
    try:
        mouse(True)
        redraw = True
        while True:
            if redraw:
                try: cols, rows = os.get_terminal_size(sys.stdout.fileno())
                except OSError: cols, rows = 80, 24
                sys.stdout.write('\033[?25l\033[2J\033[H' + render(facts, cols, rows)); sys.stdout.flush()
                redraw = False
            try: ready = select.select([rd, 0], [], [])[0]
            except InterruptedError: ready = [rd]
            if rd in ready:
                try:
                    while os.read(rd, 64): pass
                except BlockingIOError: pass
                redraw = True
            if 0 in ready:
                chunk = os.read(0, 4096)
                if not chunk: return 1          # the pane's input went away
                pick = choice(chunk, rows)
                if pick: return pick
    finally:
        try:
            mouse(False); sys.stdout.write('\033[?25h\033[2J\033[H'); sys.stdout.flush()
            if saved is not None: termios.tcsetattr(0, termios.TCSANOW, saved)
        except (OSError, ValueError): pass


if __name__ == '__main__':
    sys.exit(main())
