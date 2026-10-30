#!/usr/bin/env python3
"""Parked terminal editor for fleet-session-wrap.sh (G1YC C2).

The gate owns wake delivery. This page only paints the saved screen and keeps
unsent keyboard words on disk. Exit 10 submits, 11 chooses a new conversation,
12 lets the wrapper claim an external wake, 1 means the terminal closed.
"""
import argparse
import codecs
import os
from pathlib import Path
import re
import select
import shutil
import sys
import termios
import time
import tty
import unicodedata


def cells(char):
    return 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1


def lines(text, width):
    rows = ['']
    col = 0
    for char in text:
        size = cells(char)
        if char == '\n' or col + size > width:
            rows.append('')
            col = 0
        if char != '\n':
            rows[-1] += char
            col += size
    return rows


def read(path):
    try:
        return path.read_text()
    except OSError:
        return ''


def save(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(value)
    tmp.replace(path)


ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
PROMPT = re.compile(r'^\s*[│|]?\s*[>❯›]\s?')


def prompt_row(original):
    """The saved screen's own input row (task EQBE): the last row that reads
    `> …` / `❯ …` (inside the agent's box or not), as (index, column of the
    words); None when the screen has none (a shell, a page)."""
    for i in range(len(original) - 1, -1, -1):
        text = ANSI.sub('', original[i])
        m = PROMPT.match(text)
        if m:
            return i, sum(cells(c) for c in text[:m.end()])
    return None


def paint(screen, words, failed=False, pos=None, waking=False):
    """The saved screen as it stood, every row (task EQBE: no 「已停放」 row of its
    own — the 看台's top line says parked / resuming, off @parked · @park_waking).
    Typed words go into the screen's own input row; a failed wake still says so
    on the last row, since nothing else would. FLEET_PARK_HINT=1: the old footer."""
    width, height = shutil.get_terminal_size()
    en = os.environ.get('FLEET_UI_LANG') == 'en'
    hint = ''
    if os.environ.get('FLEET_PARK_HINT') == '1':
        hint = ('· parked · just type — Enter resumes it (~2 s)' if en else
                '· 已停放 · 直接打字，回车即接回（约 2 秒）')
    if failed:
        hint = ('Resume failed · Enter/r retry · n new chat' if en else
                '接回失败 · 回车/r 重试 · n 新会话')
    if failed:
        reason = os.environ.get('FLEET_PARK_ERROR', '')
        labels = {
            'wake_timeout': ('接回超时', 'Resume timed out'),
            'wake_queue_timeout': ('接回排队超时，请重试', 'Wake queue timed out; retry'),
            'version_mismatch': ('版本不兼容，按 n 带原话新开对话', 'Incompatible version; n starts a new chat with your words'),
            'wake_guard': ('接回名额不可用', 'Wake slots unavailable'),
        }
        if reason in labels:
            hint = labels[reason][int(en)] + ' · ' + hint
    if waking and hint:
        hint = '· resuming…' if en else '· 接回中…'
    original = screen.splitlines()
    at = prompt_row(original[:height]) if words and not hint else None
    footer = lines(hint, width) if hint else []
    if words and at is None:
        footer += lines('> ' + words, width)
    footer = footer[-height:]
    # CUP each captured physical row, autowrap off: no LF at the bottom and no
    # accidental scroll when a captured line fills the final column exactly.
    out = ['\x1b[?7l\x1b[0m\x1b[H']
    for i in range(height - len(footer)):
        out.append(f'\x1b[{i+1};1H\x1b[0m\x1b[2K' + (original[i] if i < len(original) else ''))
    for i, row in enumerate(footer, height - len(footer) + 1):
        out.append(f'\x1b[{i};1H\x1b[0m\x1b[2K\x1b[90m' + row)
    if at is not None:
        # the words in the agent's own input row, wrapped below it as typed
        row0, col0 = at
        room = max(1, width - col0)
        typed = lines(words, room)
        for k, part in enumerate(typed):
            r = row0 + 1 + k
            if r > height:
                break
            out.append(f'\x1b[{r};{col0 + 1}H\x1b[0m\x1b[K' + part)
        if pos is not None:
            prefix = lines(words[:pos], room)
            r = min(height, row0 + len(prefix))
            out.append(f'\x1b[{r};{min(width, col0 + 1 + sum(cells(c) for c in prefix[-1]))}H')
    elif words and pos is not None:
        prefix = lines('> ' + words[:pos], width)
        row = height - len(lines('> ' + words, width)) + len(prefix)
        col = min(width, sum(cells(c) for c in prefix[-1]) + 1)
        out.append(f'\x1b[{max(1, row)};{col}H')
    elif not words and not hint:
        # the cursor where the agent's own was: its input row, else the last row
        empty = prompt_row(original[:height])
        if empty is not None:
            out.append(f'\x1b[{empty[0] + 1};{min(width, empty[1] + 1)}H')
    out.append('\x1b[0m\x1b[?7h')
    sys.stdout.write(''.join(out))
    sys.stdout.flush()


def env_secs(name, default):
    try:
        return max(.25, float(os.environ.get(name, default)))
    except ValueError:
        return default


def dir_stamp(path):
    """The directory's mtime (ns), None when it is missing: moves on every file
    created, renamed or removed in it."""
    try:
        return os.stat(path).st_mtime_ns if path else None
    except OSError:
        return None


def waking_mark(pane, on):
    """@park_waking while a sentence is on its way (the top line's 「接回中…」)."""
    import fleet_session_gate as gate
    if on:
        gate.tmux('', 'set-option', '-w', '-t', pane, '@park_waking', '1')
    else:
        gate.tmux('', 'set-option', '-wu', '-t', pane, '@park_waking')


def editor(screen, draft, failed):
    import fleet_session_gate as gate
    words = read(draft)
    # Older editors persisted DEL on Backspace at column zero. Only that
    # control-only artifact is empty; whitespace, Unicode and text containing
    # DEL remain the person's unsent draft and keep the external-wake guard.
    if words and not words.strip('\x7f'):
        words = ''
        save(draft, words)
    pos = len(words)
    decoder = codecs.getincrementaldecoder('utf-8')('replace')
    esc = ''
    pasted = False
    pane = os.environ['TMUX_PANE']
    old = termios.tcgetattr(0)
    last_poll = 0
    # The wake poll forks a tmux client: every .25 s that was 4 forks a second per
    # parked window, idle or not (47 parked windows ≈ 190 forks/s on one mini). A
    # wake always writes its seed + .meta into the draft's own fid directory before
    # it stamps @park_wake (gate.wake_request), so the directory's mtime — a stat,
    # no fork — says when to look: fast for a few seconds after it moves (the stamp
    # lands just after the write), otherwise one slow poll as the safety net.
    watch = draft.parent if draft else None
    slow = env_secs('FLEET_PARK_WAKE_POLL_SECS', 5)
    seen = dir_stamp(watch)
    hot_until = time.monotonic() + 3  # a wake stamped just before the page started
    # Zero is a valid monotonic origin (macOS Python 3.9), not a prior input.
    last_presence = None
    size = None
    # BREAK-IT park-page-copy-mode: a page started while its pane sits in tmux
    # copy-mode (the wheel scrolled the agent's screen) would never see a key, Enter
    # included. Only at the start: copy-mode entered later, while the person looks
    # at the parked window, is them reading the saved screen — left alone.
    gate.tmux('', 'if-shell', '-F', '-t', pane, '#{pane_in_mode}', 'send-keys -t %s -X cancel' % pane)
    try:
        tty.setraw(0, termios.TCSANOW)
        sys.stdout.write('\x1b[?2004h')
        waking_mark(pane, False)
        paint(screen, words, failed, pos)
        gate.tmux('', 'set-option', '-w', '-t', pane, '@park_held', str(int(time.time())))
        while True:
            current = shutil.get_terminal_size()
            if size != current:
                size = current
                paint(screen, words, failed, pos)
            # Looking at the window is deliberately no wake. An external seed
            # can wake only with an empty editor: a draft must never be submitted
            # behind the person's back or swallowed by a peer's message.
            if not words:
                now = time.monotonic()
                stamp = dir_stamp(watch)
                if stamp != seen:
                    seen = stamp
                    hot_until = now + 3
            if not words and time.monotonic() - last_poll >= (.25 if time.monotonic() < hot_until else slow):
                last_poll = time.monotonic()
                wake = gate.tmux('', 'display-message', '-p', '-t', pane, '#{@park_wake}')
                if wake and wake.strip():
                    return 12
            if not select.select([0], [], [], .1)[0]:
                continue
            raw = os.read(0, 1)
            if not raw:
                return 1
            char = decoder.decode(raw)
            if not char:
                continue
            if char == '\x1b' or esc:
                esc += char
                if esc in ('\x1b', '\x1b['):
                    continue
                if esc.startswith('\x1b[') and not ('@' <= char <= '~'):
                    continue
                if esc == '\x1b[200~': pasted = True
                elif esc == '\x1b[201~': pasted = False
                elif esc == '\x1b[D': pos = max(0, pos - 1)
                elif esc == '\x1b[C': pos = min(len(words), pos + 1)
                elif esc in ('\x1b[H', '\x1b[1~'): pos = 0
                elif esc in ('\x1b[F', '\x1b[4~'): pos = len(words)
                elif esc == '\x1b[3~': words = words[:pos] + words[pos+1:]
                esc = ''
                save(draft, words)
                paint(screen, words, failed, pos)
                continue
            if last_presence is None or time.monotonic() - last_presence >= 30:
                last_presence = time.monotonic()
                gate.tmux('', 'set-option', '-w', '-t', pane, '@park_presence', str(int(time.time())))
            if not pasted and (char in ('\r', '\n') or (failed and char in ('r', 'n'))):
                save(draft, words)
                waking_mark(pane, True)
                paint(screen, words, pos=pos, waking=True)
                return 11 if failed and char == 'n' else 10
            if char in ('\x7f', '\b'):
                if pos:
                    words = words[:pos-1] + words[pos:]
                    pos -= 1
            elif char in ('\x03', '\x15'):
                words = ''; pos = 0
            elif char == '\x01': pos = 0
            elif char == '\x05': pos = len(words)
            elif char >= ' ' or (pasted and char in ('\r', '\n', '\t')):
                words = words[:pos] + ('\n' if char == '\r' else char) + words[pos:]
                pos += 1
            save(draft, words)
            paint(screen, words, failed, pos)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, old)
        sys.stdout.write('\x1b[?2004l\x1b[0m\x1b[?7h')
        sys.stdout.flush()


def failure(meta_path):
    import fleet_session_gate as gate
    # The first native report and this failure race for the same metadata.
    # If it was acknowledged, never offer to send an already accepted turn.
    path = Path(meta_path)
    try:
        path.rename(str(path) + '.failed')
    except FileNotFoundError:
        return 1
    meta = gate.read_json(str(path) + '.failed') or {}
    pane = os.environ['TMUX_PANE']
    for option, value in (('@parked', str(int(time.time()))), ('@park_since', str(int(time.time())))):
        gate.tmux('', 'set-option', '-w', '-t', pane, option, value)
    gate.tmux('', 'set-option', '-wu', '-t', pane, '@park_start')
    seed = meta.get('seed', '')
    if meta.get('deferred'):
        # No process was launched. Timers keep their original delivery and retry
        # after the deferral; no error page, no failure streak, no stolen draft.
        Path(seed + '.taken').unlink(missing_ok=True)
        gate.tmux('', 'set-option', '-w', '-t', pane, '@park_error', meta['deferred'])
        return 0 if meta.get('why') == '键盘' else 3
    error = gate.read_json(seed + '.error') or {}
    reason = error.get('reason', 'launch_failed')
    import re
    from fleet_agent_adapter import ADAPTERS, DEFAULT
    agent = (gate.tmux('', 'display-message', '-p', '-t', pane, '#{@cc_agent}') or '').strip()
    pattern = ADAPTERS.get(agent or DEFAULT, {}).get('park_incompatible')
    screen = gate.tmux('', 'capture-pane', '-p', '-t', pane, '-S', '-40') or ''
    if pattern and re.search(pattern, screen, re.I):
        reason = 'version_mismatch'
    meta['failure'] = reason
    gate.write_json(str(path) + '.failed', meta)
    gate.tmux('', 'set-option', '-w', '-t', pane, '@park_error', reason)
    fid = meta.get('fid', '')
    if fid:
        with gate.lock(fid):
            health_path = gate.fid_dir(fid) / 'park-health.json'
            health = gate.read_json(health_path) or {}
            health['failures'] = health.get('failures', 0) + 1
            health['disabled'] = health.get('disabled', False) or health['failures'] >= 2
            gate.write_json(health_path, health)
        draft = gate.fid_dir(fid) / 'park-input.txt'
        if not draft.exists() or not draft.stat().st_size:
            words = read(Path(seed + '.taken')) or read(Path(seed))
            save(draft, words)
    gate.park_log(fid, 'fail', meta.get('why', ''),
                  max(0, time.time() - meta.get('started', time.time())), reason)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--screen', type=Path)
    p.add_argument('--draft', type=Path)
    p.add_argument('--failed', action='store_true')
    p.add_argument('--fail-meta')
    a = p.parse_args()
    if a.fail_meta:
        return failure(a.fail_meta)
    return editor(read(a.screen), a.draft, a.failed)


if __name__ == '__main__':
    try:
        result = main()
    except (OSError, ValueError, termios.error) as error:
        print(str(error), file=sys.stderr)
        result = 2
    sys.exit(result)
