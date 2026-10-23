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


def paint(screen, words, failed=False, pos=None, waking=False):
    width, height = shutil.get_terminal_size()
    en = os.environ.get('FLEET_UI_LANG') == 'en'
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
    if waking:
        hint = '· resuming…' if en else '· 接回中…'
    footer = lines(hint, width)
    if words:
        footer += lines('> ' + words, width)
    footer = footer[-height:]
    # CUP each captured physical row, autowrap off: no LF at the bottom and no
    # accidental scroll when a captured line fills the final column exactly.
    out = ['\x1b[?7l\x1b[0m\x1b[H']
    original = screen.splitlines()
    for i in range(height - len(footer)):
        out.append(f'\x1b[{i+1};1H\x1b[0m\x1b[2K' + (original[i] if i < len(original) else ''))
    for i, row in enumerate(footer, height - len(footer) + 1):
        out.append(f'\x1b[{i};1H\x1b[0m\x1b[2K\x1b[90m' + row)
    if words and pos is not None:
        prefix = lines('> ' + words[:pos], width)
        row = height - len(lines('> ' + words, width)) + len(prefix)
        col = min(width, sum(cells(c) for c in prefix[-1]) + 1)
        out.append(f'\x1b[{max(1, row)};{col}H')
    out.append('\x1b[0m\x1b[?7h')
    sys.stdout.write(''.join(out))
    sys.stdout.flush()


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
    # Zero is a valid monotonic origin (macOS Python 3.9), not a prior input.
    last_presence = None
    size = None
    try:
        tty.setraw(0, termios.TCSANOW)
        sys.stdout.write('\x1b[?2004h')
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
            if not words and time.monotonic() - last_poll >= .25:
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
