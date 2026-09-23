"""The sleeping page: what a parked worker was doing, drawn to the CURRENT pane.

`render_park` is pure — record + facts + size in, one screenful out — so the
park process redraws it on every SIGWINCH and the wake-confirm work (issue #1050)
passes its own button lines as `footer_lines`. Every fact is optional: a field
the record or window lacks is left off the card, never guessed (issue #1049).
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unicodedata

HINT = 'Enter this worker to resume the saved conversation.'
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])')
BOLD, DIM, RED, YELLOW, RESET = '\x1b[1m', '\x1b[2m', '\x1b[31m', '\x1b[33m', '\x1b[0m'
PRCI = {'✓': 'checks green', '✗': 'checks failing', '✓↑': 'green, behind base',
        '✓!': 'green, merge conflict', '✓·': 'green, blocked by protection',
        '✓d': 'green, draft', '✓?': 'green, mergeability unknown'}


def cell(ch):
    if unicodedata.combining(ch) or ch in '\u200b\u200d\ufe0f': return 0
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1


def width(text):
    return sum(cell(c) for c in ANSI.sub('', text))


def clip(text, cols):
    """Plain text cut to `cols` display cells, '…' marking the cut."""
    text = text.replace('\t', '    ')
    if width(text) <= cols: return text
    out, used = '', 0
    for c in text:
        if used + cell(c) > cols - 1: break
        out += c; used += cell(c)
    return out + '…' if cols > 0 else ''


def wrap(text, cols):
    """Word-wrap by display cells: a run of narrow characters is a word, each
    wide (CJK) character breaks anywhere, and an over-long word hard-breaks."""
    rows = []
    for para in text.splitlines() or ['']:
        line, used = '', 0
        for token in re.findall(r'\s+|[^\s\u1100-\uffff]+|.', para.replace('\t', '    ').rstrip()):
            w = width(token)
            if used + w <= cols:
                line += token; used += w
                continue
            if token.isspace() or w > cols or not line.strip():
                # Pour the token in cell by cell; a space overflow just breaks.
                for c in ('' if token.isspace() else token):
                    if used + cell(c) > cols: rows.append(line.rstrip()); line, used = '', 0
                    line += c; used += cell(c)
                if token.isspace(): rows.append(line.rstrip()); line, used = '', 0
                continue
            rows.append(line.rstrip()); line, used = token, w
        rows.append(line.rstrip())
    return rows


def ago(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60: return f'{seconds}s'
    m = seconds // 60
    if m < 60: return f'{m}m'
    h, m = divmod(m, 60)
    if h < 24: return f'{h}h {m:02d}m'
    d, h = divmod(h, 24)
    return f'{d}d {h}h'


def last_reply(transcript, limit=8 << 20):
    """Text of the LAST assistant entry that has any, from a Claude JSONL.
    Reads backwards in chunks; None when unreadable or nothing is found."""
    try:
        with open(transcript, 'rb') as f:
            f.seek(0, 2); end = f.tell(); pos = end; tail = b''
            while pos > 0 and end - pos < limit:
                step = min(1 << 18, pos); pos -= step
                f.seek(pos); tail = f.read(step) + tail
                lines = tail.split(b'\n')
                if pos > 0: lines = lines[1:]   # the first is a partial line
                for raw in reversed(lines):
                    if b'"assistant"' not in raw: continue
                    try: entry = json.loads(raw)
                    except ValueError: continue
                    if entry.get('type') != 'assistant': continue
                    content = (entry.get('message') or {}).get('content')
                    if isinstance(content, str): text = content
                    else: text = '\n\n'.join(b.get('text', '') for b in content or []
                                             if isinstance(b, dict) and b.get('type') == 'text')
                    if text.strip(): return text.strip()
    except OSError:
        return None
    return None


def git_state(worktree):
    """{'branch', 'dirty', 'unpushed'} — each key only when git answered."""
    out = {}
    def git(*args):
        return subprocess.run(['git', '-C', str(worktree), *args], text=True, capture_output=True,
                              timeout=5, stdin=subprocess.DEVNULL, check=True).stdout
    for key, args, parse in (
            ('branch', ('rev-parse', '--abbrev-ref', 'HEAD'), str.strip),
            ('dirty', ('status', '--porcelain'), lambda s: len(s.splitlines())),
            # Commits on no remote at all: covers a branch with no upstream too.
            ('unpushed', ('rev-list', '--count', 'HEAD', '--not', '--remotes'), lambda s: int(s.strip()))):
        try: out[key] = parse(git(*args))
        except (OSError, ValueError, subprocess.SubprocessError): pass
    return out


def wake_reasons(data):
    loop = (data.get('source') or {}).get('sleep_loop') or {}
    record = loop.get('record') or {}
    reasons = []
    if record.get('status') == 'active':
        at = (record.get('schedule') or {}).get('next_run_at')
        if isinstance(at, (int, float)): reasons.append('loop due ' + time.strftime('%H:%M', time.localtime(at)))
    elif record.get('status') == 'waiting-quota':
        reasons.append('when quota returns')
    reasons.append('incoming message')
    return reasons


def trim_screen(screen):
    """The saved screen minus the agent's own input box and status lines."""
    lines = [ANSI.sub('', l).rstrip() for l in (screen or '').splitlines()]
    prompt = max((i for i, l in enumerate(lines) if l.lstrip()[:1] in ('❯', '›')), default=None)
    if prompt is not None:
        cut = prompt
        if cut > 0 and lines[cut - 1].strip() and set(lines[cut - 1].strip()) <= set('─━—-'): cut -= 1
        lines = lines[:cut]
    while lines and not lines[-1].strip(): lines.pop()
    return lines


def gather(data, opts):
    """Facts computed per draw from the worktree + transcript (optional keys)."""
    facts = dict(opts)
    source = data.get('source') or {}
    if source.get('worktree') and Path(source['worktree']).is_dir():
        facts['git'] = git_state(source['worktree'])
    if source.get('agent', 'claude') == 'claude' and source.get('transcript'):
        facts['reply'] = last_reply(source['transcript'])
    return facts


def render_park(data, opts, width_, height, footer_lines=None, now=None):
    cols, rows = max(int(width_), 10), max(int(height), 3)
    now = time.time() if now is None else now
    source = data.get('source') or {}
    fit = lambda text: clip(text, cols - 1)
    header = []

    state = data.get('state') or 'sleeping'
    task = ' '.join(x for x in (('#' + opts['issue']) if opts.get('issue') else '', opts.get('title', '')) if x)
    word, color = {'waking': ('Waking…', YELLOW), 'failed': ('Wake failed', RED)}.get(state, ('Sleeping', ''))
    first = fit(word + (' · ' + task if task else ''))
    header.append(color + BOLD + first[:len(word)] + RESET + first[len(word):])
    if state == 'failed' and data.get('error'):
        header += [RED + l + RESET for l in wrap('error: ' + data['error'], cols - 1)[:3]]

    parts = []
    if opts.get('repo'): parts.append(opts['repo'])
    if isinstance(data.get('created'), (int, float)): parts.append('asleep ' + ago(now - data['created']))
    at = (data.get('evidence') or {}).get('at')
    if isinstance(at, (int, float)): parts.append('idle ' + ago(now - at))
    if parts: header.append(fit(' · '.join(parts)))

    who = [x for x in (source.get('agent'), data.get('model'), source.get('label')) if x]
    before, parked = data.get('rss_before_kb'), data.get('rss_parked_kb')
    if isinstance(before, int) and isinstance(parked, int) and before > parked:
        who.append(f'{(before - parked) // 1024} MB freed')
    if who: header.append(DIM + fit(' · '.join(who)) + RESET)

    git = opts.get('git') or {}
    work = []
    if 'dirty' in git: work.append(f"{git['dirty']} uncommitted" if git['dirty'] else 'clean')
    if 'unpushed' in git: work.append(f"{git['unpushed']} unpushed" if git['unpushed'] else 'all pushed')
    if work:
        line = 'work: ' + ', '.join(work) + (f" on {git['branch']}" if git.get('branch') else '')
        header.append((YELLOW if git.get('dirty') or git.get('unpushed') else '') + fit(line) + RESET)

    pr = opts.get('prci', '')
    merged = re.match(r'merged:(\d+):', opts.get('reap_key', ''))
    if pr: header.append(fit('PR: ' + pr + ' ' + PRCI.get(pr, '')))
    elif merged: header.append(fit(f'PR #{merged.group(1)} merged'))
    else: header.append(DIM + fit('PR: none open') + RESET)

    footer = [DIM + fit('wakes on its own: ' + ' · '.join(wake_reasons(data))) + RESET]
    footer += [fit(l) if width(l) > cols - 1 else l for l in (footer_lines if footer_lines is not None else [HINT])]

    rule = DIM + '─' * (cols - 1) + RESET
    free = rows - len(header) - len(footer) - 2
    reply = opts.get('reply')
    if reply:
        body = [BOLD + 'Last reply' + RESET] + wrap(reply, cols - 1)
        tail = body[1:][-max(free - 1, 0):] if free > 1 else []
        if len(body) - 1 > len(tail) and tail: tail[0] = DIM + '…' + RESET
        body = body[:1] + tail if free > 0 else []
    else:
        saved = [DIM + clip(l, cols - 1) + RESET for l in trim_screen(data.get('screen'))]
        label = DIM + fit('saved screen (old, not live)') + RESET
        body = ([label] + saved[-(free - 1):]) if free > 1 else []

    lines = header + [rule] + body
    lines = lines[:max(rows - len(footer) - 1, 1)]
    lines += [''] * max(rows - len(lines) - len(footer) - 1, 0) + [rule] + footer
    return '\n'.join(lines[:rows])
