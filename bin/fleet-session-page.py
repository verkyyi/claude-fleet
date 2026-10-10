#!/usr/bin/env python3
"""The line a session stops on when its agent exits (issue #1784, #2743).

fleet-session-wrap.sh runs this in the pane the agent just left. Like a local
`claude` that exits, the conversation's last screen STAYS where it is — nothing
is cleared — and under it comes ONE line: what happened and the keys,

    会话已结束 · ↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口

(「会话意外退出」 when the agent did not end on its own — a crash, a kill). The
exit status, the conversation id and the failed agent's last line are not on the
screen: the wrapper writes them to logs/session-exit.log. It exits with the
operator's choice:

    10  ↵  resume the same conversation
    11  r  start a new one in this window
    12  q  recycle the window (the old close-on-exit, now on purpose)
    13  p  the same conversation WITHOUT the personal layer (issue #1862) —
           offered only when this login has one (--personal on)

A line goes ABOVE it only for something the person must know before choosing
(issue #1842): commits on the branch that are on no remote (「未推送：N 个提交
（分支 issue-N）」 — q keeps them), personal hooks that kept failing and were
switched off (#1862), a window already running without the personal layer. A
relaunch from this line that died within the fast-fail window (the conversation
is gone, the login lapsed) and a launch the launcher refused (#2404) say so IN
the line, in place of 「会话已结束」 — and the agent's own error stays visible
above it, since nothing is cleared.

Every other byte is discarded, so nothing typed here reaches the next agent. On
the way out the lines it drew are erased again (and only those). `render` is
pure — facts + width in, the lines out — so the selftest checks it without a
terminal.
"""
import argparse
import os
import re
import select
import signal
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fleet_sleep_park import BOLD, DIM, RED, RESET, YELLOW, SGR_MOUSE, clip, ui_lang, width  # noqa: E402

RESUME, NEW, QUIT, PERSONAL = 10, 11, 12, 13

TEXT = {
    'zh': {'ended': '会话已结束', 'crashed': '会话意外退出',
           'unpushed': '未推送：{n} 个提交（分支 {b}）', 'unpushed_nob': '未推送：{n} 个提交',
           'failed_resume': '续上原对话失败', 'failed_new': '新开会话失败', 'failed_launch': '会话没能启动',
           'why_conversation': '找不到这个对话', 'why_auth': '认证失效，需要重新登录',
           'why_cred': '凭据代理没给出会话凭据', 'why_cred_unknown': '入口不认这个会话（没有登记）· ↵ 补登记并重试', 'why_account': '指定的订阅账号不可用',
           'hooks_off': '个人自动规则 {n} 条这次连续失败、已停用：{w}',
           'personal_off': '这个窗口已不带个人配置（FLEET_PERSONAL=0）；长期退回：fleet config restore N',
           'resume': '重开', 'resume_new': '新开对话', 'retry': '重试启动', 'list': '回列表',
           'new': '新对话', 'quit': '关窗口', 'personal': '不带个人配置重开'},
    'en': {'ended': 'Session ended', 'crashed': 'Session exited unexpectedly',
           'unpushed': 'Unpushed: {n} commits (branch {b})', 'unpushed_nob': 'Unpushed: {n} commits',
           'failed_resume': 'Resuming the conversation failed', 'failed_new': 'Starting a new session failed',
           'failed_launch': 'The session could not start',
           'why_conversation': 'conversation not found', 'why_auth': 'authentication expired — log in again',
           'why_cred': 'the credential proxy gave no session credential', 'why_cred_unknown': 'the hub does not know this session (not registered) · ↵ re-registers and retries', 'why_account': 'the pinned subscription is unavailable',
           'hooks_off': '{n} personal hook(s) kept failing and were switched off: {w}',
           'personal_off': 'This window runs without the personal layer (FLEET_PERSONAL=0); to roll it back: fleet config restore N',
           'resume': 'reopen', 'resume_new': 'new conversation', 'retry': 'retry the launch', 'list': 'list',
           'new': 'new chat', 'quit': 'close window', 'personal': 'reopen without personal config'},
}


def headline(rc, words, failed='', why=''):
    """What happened, in a few words: 0 / 130 are the agent ending on its own (the
    person's /exit, Ctrl+D, Ctrl+C twice), anything else — a failure, a signal
    (137 = kill -9) — is 「意外退出」. A relaunch from this line that died at once
    (failed = resume | new) names that instead, and so does a launch the
    launcher itself refused (failed = launch, issue #2404)."""
    if failed in ('resume', 'new', 'launch'):
        head = words['failed_' + failed]
        if why in ('conversation', 'auth', 'cred', 'cred_unknown', 'account'):
            head += ('：' if words is TEXT['zh'] else ': ') + words['why_' + why]
        return head, RED
    if rc in (0, 130): return words['ended'], YELLOW
    return words['crashed'], RED


def keys_line(words, personal='', retry=False, enter_new=False):
    """The keys, the two the person needs first: ↵ and ⌘P (the client's switch);
    r / q / p after them, dimmer."""
    enter = words['retry' if retry else 'resume_new' if enter_new else 'resume']
    line = BOLD + '↵' + RESET + ' ' + enter + ' · ' + BOLD + '⌘P' + RESET + ' ' + words['list']
    tail = 'r ' + words['new'] + ' · q ' + words['quit']
    if personal == 'on': tail += ' · p ' + words['personal']
    return line + DIM + '   ' + tail + RESET


def render(facts, cols, rows=None):
    """The lines, top to bottom: anything the person must know first (rare), then
    the one line — what happened · the keys. Each fits `cols` - 1 cells."""
    cols = max(int(cols), 10)
    words = TEXT[facts.get('lang') or ui_lang()]
    head, color = headline(int(facts.get('rc', 0)), words, facts.get('failed') or '', facts.get('why') or '')
    above = []
    n = int(facts.get('unpushed') or 0)
    if n > 0:
        b = facts.get('branch') or ''
        above.append((YELLOW, words['unpushed'].format(n=n, b=b) if b else words['unpushed_nob'].format(n=n)))
    off = int(facts.get('hooks_off') or 0)
    if off > 0: above.append((YELLOW, words['hooks_off'].format(n=off, w=facts.get('hooks_off_what') or '')))
    if facts.get('personal') == 'off': above.append((DIM, words['personal_off']))
    lines = [color + clip(text, cols - 1) + RESET for color, text in above]
    enter_new = facts.get('agent') == 'codex' and not facts.get('sid')
    keys = keys_line(words, facts.get('personal') or '', bool(facts.get('retry')), enter_new)
    line = color + BOLD + head + RESET + ' · ' + keys
    if width(line) > cols - 1:                  # narrow: the dim tail goes first
        line = color + BOLD + head + RESET + ' · ' + keys.split(DIM)[0]
    if width(line) > cols - 1:
        line = color + BOLD + clip(head, cols - 1) + RESET
    return '\n'.join(lines + [line])


def choice(chunk, key_row, personal=False):
    """The first press a read holds: ↵ (or a left click on the keys row) resumes,
    r starts new, q recycles, p (only when offered) reopens without the personal
    layer. None = nothing on this page's keys (discarded)."""
    text = chunk.decode('utf-8', 'replace') if isinstance(chunk, bytes) else chunk
    for m in SGR_MOUSE.finditer(text):
        button, row = int(m.group(1)), int(m.group(3))
        if m.group(4) == 'M' and button & ~(4 | 8 | 16) == 0 and key_row and row == key_row: return RESUME
    text = SGR_MOUSE.sub('', text)
    text = re.sub(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|O.|[@-Z\\-_])', '', text)
    for ch in text:
        if ch in '\r\n': return RESUME
        if ch in 'rR': return NEW
        if ch in 'qQ': return QUIT
        if personal and ch in 'pP': return PERSONAL
    return None


CPR = re.compile(r'\x1b\[(\d+);(\d+)R')


def cursor(wait=0.3):
    """The cursor's (row, col), asked of the terminal (DSR 6) — None when it does
    not answer in time. Bytes that arrive meanwhile are handed back too."""
    sys.stdout.write('\x1b[6n'); sys.stdout.flush()
    got, end = b'', time.time() + wait
    while time.time() < end:
        if not select.select([0], [], [], max(end - time.time(), 0))[0]: break
        chunk = os.read(0, 256)
        if not chunk: break
        got += chunk
        m = CPR.search(got.decode('utf-8', 'replace'))
        if m: return (int(m.group(1)), int(m.group(2))), CPR.sub('', got.decode('utf-8', 'replace'), count=1)
    return None, got.decode('utf-8', 'replace')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rc', type=int, default=0)
    p.add_argument('--agent', default='claude')
    p.add_argument('--sid', default='')
    p.add_argument('--title', default='', help='the window (kept for callers; not drawn)')
    p.add_argument('--unpushed', type=int, default=0, help='commits on no remote (issue #1842)')
    p.add_argument('--branch', default='')
    p.add_argument('--failed', default='', choices=['', 'resume', 'new', 'launch'],
                   help='a relaunch from this page died at once, or the launcher refused to start (launch)')
    p.add_argument('--why', default='', help='conversation | auth | cred | account | (unknown)')
    p.add_argument('--retry', action='store_true', help='↵ retries the same launch (the agent never ran, #2404)')
    p.add_argument('--detail', default='', help="the failed agent's last line (kept for callers; logged by the wrapper)")
    p.add_argument('--secs', type=int, default=0)
    p.add_argument('--personal', default='', choices=['', 'on', 'off'],
                   help='this login has a personal layer: on = offer p, off = this window already runs without it (#1862)')
    p.add_argument('--hooks-off', type=int, default=0, help='personal hooks switched off in the run that ended')
    p.add_argument('--hooks-off-what', default='')
    p.add_argument('--print', action='store_true', help='draw once at 80 columns and exit 0 (selftest)')
    a = p.parse_args()
    facts = {'rc': a.rc, 'agent': a.agent, 'sid': a.sid, 'unpushed': a.unpushed,
             'branch': a.branch, 'failed': a.failed, 'why': a.why,
             'retry': a.retry, 'personal': a.personal, 'hooks_off': a.hooks_off, 'hooks_off_what': a.hooks_off_what}
    if a.print:
        sys.stdout.write(render(facts, 80) + '\n')
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
    size = lambda: os.get_terminal_size(sys.stdout.fileno()) if os.isatty(sys.stdout.fileno()) else (80, 24)
    drawn = 0
    try:
        # under what the agent left, on a line of its own — never over it
        pos, early = cursor() if saved is not None else (None, '')
        if pos is None or pos[1] > 1: sys.stdout.write('\r\n')
        cols = size()[0]
        text = render(facts, cols)
        drawn = text.count('\n')
        sys.stdout.write('\033[?25l' + text.replace('\n', '\r\n')); sys.stdout.flush()
        key_row = None
        if saved is not None:
            pos, more = cursor()
            early += more
            if pos: key_row = pos[0]
        mouse(True); sys.stdout.flush()
        pick = choice(early, key_row, a.personal == 'on') if early else None
        if pick: return pick
        while True:
            try: ready = select.select([rd, 0], [], [])[0]
            except InterruptedError: ready = [rd]
            if rd in ready:
                try:
                    while os.read(rd, 64): pass
                except BlockingIOError: pass
                cols = size()[0]               # a resize: the one line again, fitted
                sys.stdout.write('\r\033[K' + render(facts, cols).split('\n')[-1]); sys.stdout.flush()
            if 0 in ready:
                chunk = os.read(0, 4096)
                if not chunk: return 1          # the pane's input went away
                pick = choice(chunk, key_row, a.personal == 'on')
                if pick: return pick
    finally:
        try:
            mouse(False)
            # erase what this drew, and only that: the conversation above stays
            sys.stdout.write('\r' + ('\033[%dA' % drawn if drawn else '') + '\033[J\033[?25h'); sys.stdout.flush()
            if saved is not None: termios.tcsetattr(0, termios.TCSANOW, saved)
        except (OSError, ValueError): pass


if __name__ == '__main__':
    sys.exit(main())
