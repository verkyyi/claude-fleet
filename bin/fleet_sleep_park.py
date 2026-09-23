"""The sleeping page: what a parked worker was doing, drawn to the CURRENT pane.

`render_park` is pure — record + facts + size in, one screenful out — so the
park process redraws it on every SIGWINCH and the wake-confirm work (issue #1050)
passes its own button lines as `footer_lines`. Every fact is optional: a field
the record or window lacks is left off the card, never guessed (issue #1049).

`WakeButton` + `presses` are the page's one control (issue #1050): ⏎ or a tap
arms it, a second one ≥`BOUNCE` s later and within the arm window wakes. Pure
too — the park loop feeds them bytes and a clock.
"""
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import unicodedata

HINT = 'Enter this worker to resume the saved conversation.'
ANSI = re.compile(r'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])')
BOLD, DIM, RED, YELLOW, RESET = '\x1b[1m', '\x1b[2m', '\x1b[31m', '\x1b[33m', '\x1b[0m'
REVERSE = '\x1b[7m'
SGR_MOUSE = re.compile(r'\x1b\[<(\d+);(\d+);(\d+)([Mm])')
BOUNCE = 0.3
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


def reply_text(entry, agent='claude'):
    """Assistant text of one transcript row, or None when the row is not one.
    Claude: a `type: assistant` entry. Codex rollout: a `response_item` whose
    payload is an assistant `message` of `output_text` blocks (issue #1052)."""
    if agent == 'codex':
        if entry.get('type') != 'response_item': return None
        message = entry.get('payload') or {}
        if message.get('type') != 'message' or message.get('role') != 'assistant': return None
        kinds = ('output_text', 'text')
    else:
        if entry.get('type') != 'assistant': return None
        message = entry.get('message') or {}
        kinds = ('text',)
    content = message.get('content')
    if isinstance(content, str): return content
    return '\n\n'.join(b.get('text', '') for b in content or []
                        if isinstance(b, dict) and b.get('type') in kinds)


def last_reply(transcript, agent='claude', limit=8 << 20):
    """Text of the LAST assistant entry that has any, from a Claude JSONL or a
    Codex rollout. Reads backwards in chunks; None when unreadable or nothing
    is found."""
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
                    if not isinstance(entry, dict): continue
                    text = reply_text(entry, agent)
                    if text and text.strip(): return text.strip()
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
    agent = source.get('agent', 'claude')
    if agent in ('claude', 'codex') and source.get('transcript'):
        facts['reply'] = last_reply(source['transcript'], agent)
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


class WakeButton:
    """rest → armed → waking. A press while armed counts only ≥BOUNCE s after
    the arming one (a key bounce or a double-sent tap is not two presses) and
    within `arm` s; past the window the arm lapses silently and the next press
    arms again. Nothing leaves `waking`: the wake respawns this pane."""

    def __init__(self, arm=3.0):
        self.arm, self.state, self.armed_at = float(arm), 'rest', 0.0

    def press(self, now):
        """Feed one press; True exactly when it should start the wake."""
        self.expire(now)
        if self.state == 'waking': return False
        if self.state == 'armed':
            if now - self.armed_at < BOUNCE: return False
            self.state = 'waking'
            return True
        self.state, self.armed_at = 'armed', now
        return False

    def expire(self, now):
        """Lapse an arm whose window has passed; True when that changed the state."""
        if self.state == 'armed' and now - self.armed_at > self.arm:
            self.state = 'rest'
            return True
        return False

    def timeout(self, now):
        """Seconds until the page must redraw by itself — the next countdown
        digit, or the lapse — or None: at rest nothing is timed (EPIC #1048 rule 4)."""
        if self.state != 'armed': return None
        left = self.arm - (now - self.armed_at)
        if left <= 0: return 0
        return left - (math.ceil(left) - 1) + 0.01

    def lines(self, now):
        if self.state == 'waking':
            return [YELLOW + REVERSE + ' ↻ waking… ' + RESET]
        if self.state == 'armed':
            left = max(math.ceil(self.arm - (now - self.armed_at)), 1)
            return [YELLOW + REVERSE + f' ⏎ again to wake · {left}… ' + RESET]
        return [REVERSE + ' ⏎ Wake ' + RESET + DIM + '  press ⏎ (or tap) twice to resume' + RESET]


def cap_line(n, m):
    """The armed page's over-limit warning (issue #1058): the second press still
    wakes — the operator's own wake always goes — so this informs, never blocks."""
    return YELLOW + f' fleet full {n}/{m} — waking makes {n + 1} ' + RESET


def wake_cost(data, records):
    """The armed page's cost line (issue #1053): what a wake restarts and how long
    one usually takes — "resumes claude + 2 tools (~5s)". The time is the median
    `wake_seconds` of this worker's past naps (same worktree), else of the whole
    fleet's; with no recorded wake anywhere the line is omitted (None), never guessed."""
    def seconds(rows):
        return sorted(r['wake_seconds'] for r in rows
                      if isinstance(r.get('wake_seconds'), (int, float)) and r['wake_seconds'] > 0)
    source = data.get('source') or {}
    mine = [r for r in records if source.get('worktree')
            and (r.get('source') or {}).get('worktree') == source['worktree']]
    samples = seconds(mine) or seconds(records)
    if not samples: return None
    n = len(samples)
    median = samples[n // 2] if n % 2 else (samples[n // 2 - 1] + samples[n // 2]) / 2
    tools = len(source.get('sleep_mcp') or {})
    what = source.get('agent') or 'claude'
    if tools: what += f" + {tools} tool{'s' if tools != 1 else ''}"
    return f'resumes {what} (~{max(round(median), 1)}s)'


def presses(chunk, button_rows):
    """How many presses one read of the pane's input holds: ⏎ keys, and left
    clicks (SGR press) on `button_rows` (1-based). Everything else — letters,
    other escape sequences, clicks elsewhere, releases — is discarded here and
    never reaches anything (EPIC #1048 rule 3)."""
    text = chunk.decode('utf-8', 'replace') if isinstance(chunk, bytes) else chunk
    n = 0
    for m in SGR_MOUSE.finditer(text):
        button, row = int(m.group(1)), int(m.group(3))
        if m.group(4) == 'M' and button & ~(4 | 8 | 16) == 0 and row in button_rows: n += 1
    rest = ANSI.sub('', SGR_MOUSE.sub('', text)).replace('\r\n', '\r')
    return n + rest.count('\r') + rest.count('\n')
