#!/usr/bin/env python3
"""The recovery page a session stops on when its agent exits (issue #1784).

fleet-session-wrap.sh runs this in the pane the agent just left. It draws one
screenful — what happened, that the window and the conversation are still here,
and the three keys — and exits with the operator's choice:

    10  ↵  resume the same conversation
    11  r  start a new one in this window
    12  q  recycle the window (the old close-on-exit, now on purpose)
    13  p  the same conversation WITHOUT the personal layer (issue #1862) —
           offered only when this login has one (--personal on)

Two more facts it can carry (issue #1842): commits on the branch that are on no
remote (「未推送：N 个提交（分支 issue-N）」 — q keeps them, but the operator
should know they exist), and a relaunch from this page that died within the
fast-fail window (the conversation is gone, the login lapsed): the headline then
says what failed and why, instead of the window closing.

And the personal layer written badly (issue #1862): personal hooks that kept
failing in the run that just ended and were switched off are named, and `p`
reopens this window without the layer. No personal layer → not a byte of it.

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

RESUME, NEW, QUIT, PERSONAL = 10, 11, 12, 13

TEXT = {
    'zh': {'exited': '会话已退出', 'ctrl_c': '（按了 Ctrl+C）', 'signal': '会话被结束（信号 {n}）',
           'failed': '会话异常退出（退出码 {n}）', 'kept': '这个窗口不会关，原来的对话还在。', 'kept_win': '这个窗口不会关。',
           'no_sid': '没有记下对话 id：回车接着这个目录里最近的一次对话。',
           'no_sid_new': '没有记下这个窗口的对话 id：回车新开一次对话（不会接到别的会话上）。',
           'unpushed': '未推送：{n} 个提交（分支 {b}）', 'unpushed_nob': '未推送：{n} 个提交',
           'failed_resume': '续上原对话失败', 'failed_new': '新开会话失败',
           'why_conversation': '找不到这个对话', 'why_auth': '认证失效，需要重新登录',
           'fail_rc': '（{s} 秒内退出，退出码 {n}）',
           'hooks_off': '个人自动规则 {n} 条这次连续失败、已停用：{w}',
           'personal_off': '这个窗口已不带个人配置（FLEET_PERSONAL=0）；长期退回：fleet config restore N',
           'resume': '接着原对话', 'new': '新开', 'quit': '回收这个窗口', 'personal': '不带个人配置重开'},
    'en': {'exited': 'Session exited', 'ctrl_c': ' (Ctrl+C)', 'signal': 'Session ended (signal {n})',
           'failed': 'Session exited abnormally (code {n})', 'kept': 'This window stays open; the conversation is still here.', 'kept_win': 'This window stays open.',
           'no_sid': 'No conversation id recorded: Enter resumes the latest one in this directory.',
           'no_sid_new': 'No conversation id recorded for this window: Enter starts a new one (never another session\'s).',
           'unpushed': 'Unpushed: {n} commits (branch {b})', 'unpushed_nob': 'Unpushed: {n} commits',
           'failed_resume': 'Resuming the conversation failed', 'failed_new': 'Starting a new session failed',
           'why_conversation': 'conversation not found', 'why_auth': 'authentication expired — log in again',
           'fail_rc': ' (exited within {s}s, code {n})',
           'hooks_off': '{n} personal hook(s) kept failing and were switched off: {w}',
           'personal_off': 'This window runs without the personal layer (FLEET_PERSONAL=0); to roll it back: fleet config restore N',
           'resume': 'resume the conversation', 'new': 'new session', 'quit': 'recycle this window',
           'personal': 'reopen without personal config'},
}


def headline(rc, words, failed='', why='', secs=0):
    """What happened, from the agent's exit status: 0 / 130 are the operator's own
    exit, >128 a signal (137 = kill -9), anything else a failure. A relaunch from
    this page that died at once (failed = resume | new) names that instead."""
    if failed in ('resume', 'new'):
        head = words['failed_' + failed]
        if why in ('conversation', 'auth'): head += ('：' if words is TEXT['zh'] else ': ') + words['why_' + why]
        return head + words['fail_rc'].format(s=secs, n=rc), RED
    if rc == 0: return words['exited'], YELLOW
    if rc == 130: return words['exited'] + words['ctrl_c'], YELLOW
    if rc > 128: return words['signal'].format(n=rc - 128), RED
    return words['failed'].format(n=rc), RED


def keys_line(words, personal=''):
    line = (BOLD + '↵' + RESET + ' ' + words['resume'] + '   ' + BOLD + 'r' + RESET + ' ' + words['new']
            + '   ' + BOLD + 'q' + RESET + ' ' + words['quit'])
    if personal == 'on': line += '   ' + BOLD + 'p' + RESET + ' ' + words['personal']
    return line


def render(facts, cols, rows):
    """One screenful: headline (+ the window's title), a rule, what is kept, a
    rule, the keys. The keys sit on the LAST row, which a click also presses."""
    cols, rows = max(int(cols), 10), max(int(rows), 3)
    words = TEXT[facts.get('lang') or ui_lang()]
    fit = lambda text: clip(text, cols - 1)
    head, color = headline(int(facts.get('rc', 0)), words, facts.get('failed') or '',
                           facts.get('why') or '', facts.get('secs') or 0)
    title = facts.get('title') or ''
    first = color + BOLD + head + RESET + (DIM + ' · ' + title + RESET if title else '')
    body = [words['kept_win' if facts.get('failed') else 'kept']]
    sid = facts.get('sid') or ''
    no_sid = words['no_sid_new' if facts.get('agent') == 'codex' else 'no_sid']
    body.append(DIM + (facts.get('agent') or 'claude') + ' ' + sid[:8] + '…' + RESET if sid else DIM + no_sid + RESET)
    if facts.get('detail'): body.append(DIM + facts['detail'] + RESET)
    n = int(facts.get('unpushed') or 0)
    if n > 0:
        b = facts.get('branch') or ''
        body.append(YELLOW + (words['unpushed'].format(n=n, b=b) if b else words['unpushed_nob'].format(n=n)) + RESET)
    off = int(facts.get('hooks_off') or 0)
    if off > 0: body.append(YELLOW + words['hooks_off'].format(n=off, w=facts.get('hooks_off_what') or '') + RESET)
    if facts.get('personal') == 'off': body.append(DIM + words['personal_off'] + RESET)
    rule = DIM + '─' * (cols - 1) + RESET
    lines = [fit(first), rule, ''] + [fit(l) for l in body]
    lines = lines[:max(rows - 2, 1)]
    lines += [''] * max(rows - len(lines) - 2, 0) + [rule, fit(keys_line(words, facts.get('personal') or ''))]
    return '\n'.join(lines[:rows])


def choice(chunk, key_row, personal=False):
    """The first press a read holds: ↵ (or a left click on the keys row) resumes,
    r starts new, q recycles, p (only when offered) reopens without the personal
    layer. None = nothing on this page's keys (discarded)."""
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
        if personal and ch in 'pP': return PERSONAL
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rc', type=int, default=0)
    p.add_argument('--agent', default='claude')
    p.add_argument('--sid', default='')
    p.add_argument('--title', default='')
    p.add_argument('--unpushed', type=int, default=0, help='commits on no remote (issue #1842)')
    p.add_argument('--branch', default='')
    p.add_argument('--failed', default='', choices=['', 'resume', 'new'], help='a relaunch from this page died at once')
    p.add_argument('--why', default='', help='conversation | auth | (unknown)')
    p.add_argument('--detail', default='', help="the failed agent's last line")
    p.add_argument('--secs', type=int, default=0)
    p.add_argument('--personal', default='', choices=['', 'on', 'off'],
                   help='this login has a personal layer: on = offer p, off = this window already runs without it (#1862)')
    p.add_argument('--hooks-off', type=int, default=0, help='personal hooks switched off in the run that ended')
    p.add_argument('--hooks-off-what', default='')
    p.add_argument('--print', action='store_true', help='draw once at 80x24 and exit 0 (selftest)')
    a = p.parse_args()
    facts = {'rc': a.rc, 'agent': a.agent, 'sid': a.sid, 'title': a.title, 'unpushed': a.unpushed,
             'branch': a.branch, 'failed': a.failed, 'why': a.why, 'detail': a.detail, 'secs': a.secs,
             'personal': a.personal, 'hooks_off': a.hooks_off, 'hooks_off_what': a.hooks_off_what}
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
                pick = choice(chunk, rows, a.personal == 'on')
                if pick: return pick
    finally:
        try:
            mouse(False); sys.stdout.write('\033[?25h\033[2J\033[H'); sys.stdout.flush()
            if saved is not None: termios.tcsetattr(0, termios.TCSANOW, saved)
        except (OSError, ValueError): pass


if __name__ == '__main__':
    sys.exit(main())
