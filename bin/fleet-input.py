#!/usr/bin/env python3
"""Read Claude/Codex prompt state without sending keys.

Shared cursor + SGR-faint semantics from the issue bridge (#191/#199). Delivery
may fail open on an unknown screen; destructive cutover must wait instead.
Only a fully visible, single-line draft at its end is exportable.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import unicodedata


def styled(line):
    cells, dim, i = [], False, 0
    for part in re.split(r'(\x1b\[[0-9;]*m)', line):
        if part.startswith('\x1b['):
            params = [int(x or 0) for x in part[2:-1].split(';')]
            i = 0
            while i < len(params):
                p = params[i]
                if p in (38, 48, 58):
                    i += 3 if params[i+1:i+2] == [5] else 5 if params[i+1:i+2] == [2] else 1
                    continue
                if p in (0, 22): dim = False
                elif p == 2: dim = True
                i += 1
        else:
            cells.extend((c, dim) for c in part)
    return cells


def width(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def analyze(screen, cursor_x=None, cursor_y=None, columns=0):
    rows = [styled(line) for line in screen.splitlines()]
    prompts = []
    for y, row in enumerate(rows):
        plain = ''.join(c for c, _ in row)
        match = re.match(r'^\s*(?:│\s*)?[❯›>][ \u00a0]?', plain)
        if match:
            prompts.append((y, row, match.end()))
    if not prompts:
        return {'state': 'unknown', 'busy': False, 'reason': 'no recognized prompt'}
    y, row, start = prompts[-1]
    body = row[start:]
    plain = re.sub(r'│\s*$', '', ''.join(c for c, _ in body)).rstrip()
    real = re.sub(r'│\s*$', '', ''.join(c for c, faint in body if not faint)).rstrip()
    start_col = width(''.join(c for c, _ in row[:start]))
    # capture-pane trims trailing blanks, including the space after an empty
    # prompt glyph. The cursor proves that one missing separator cell.
    if not body and cursor_y == y and cursor_x == start_col + 1:
        start_col += 1
    left = (cursor_x or 0) - start_col if cursor_y == y else 0
    busy = bool(real.strip() or (left > 0 and plain.strip()))
    result = {'state': 'unknown', 'busy': busy, 'reason': 'cursor/input boundary is not proven'}
    if cursor_y != y or cursor_x is None or columns <= 0:
        return result
    if not busy and cursor_x == start_col:
        if y+1 < len(rows):
            following = ''.join(c for c, _ in rows[y+1]).strip()
            if following and not re.fullmatch(r'[─━╰╯└┘│\s]+', following):
                return result  # multiline draft/attachment below the first row
        return {'state': 'empty', 'busy': False, 'text': ''}
    if (busy and real == plain and cursor_x == start_col + width(plain)
            and cursor_x < columns - 2 and not any(c in plain for c in ('…', '\x1b', '\u200d'))
            and not re.search(r'\[(?:Pasted|Image|Attachment)\b', plain, re.I)):
        # A wrapped/multiline continuation is not a recoverable logical buffer.
        if y+1 < len(rows):
            following = ''.join(c for c, _ in rows[y+1]).strip()
            if following and not re.fullmatch(r'[─━╰╯└┘│\s]+', following):
                return result
        return {'state': 'draft', 'busy': True, 'text': plain}
    return result


def snapshot(socket, pane):
    base = ['tmux'] + (['-L', socket] if socket else [])
    def tm(*args):
        return subprocess.check_output(base + list(args), timeout=5, stderr=subprocess.PIPE, text=True).rstrip('\n')
    screen = tm('capture-pane', '-e', '-p', '-t', pane)
    cursor = tm('display-message', '-p', '-t', pane, '#{cursor_x} #{cursor_y} #{pane_width}').split()
    values = [int(x) for x in cursor] if len(cursor) in (2, 3) and all(x.isdigit() for x in cursor) else [None, None, 0]
    if len(values) == 2:
        values.append(0)  # Old probes still support the bridge's busy-only test.
    result = analyze(screen, *values)
    # Only prompt content, not changing status/footer or the source conversation.
    result['digest'] = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', default=''); parser.add_argument('--pane', required=True)
    parser.add_argument('--busy', action='store_true')
    args = parser.parse_args()
    try:
        result = snapshot(args.socket, args.pane)
    except (OSError, ValueError, subprocess.SubprocessError):
        result = {'state': 'unknown', 'busy': False, 'reason': 'prompt read failed'}
    if args.busy:
        sys.exit(0 if result['busy'] else 1)
    print(json.dumps(result, ensure_ascii=False))
