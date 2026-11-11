#!/usr/bin/env python3
"""Claude Code's native exit dialog for session-only timers: the ONE reader.

An `/exit` while a ScheduleWakeup / CronCreate timer is pending opens:

       Background work is running
       The following will stop when you exit:
       scheduled task · Runs once in 20m · <prompt, cut>…
       ❯ 1. Exit and stop tasks
         2. Move to background and exit
         3. Stay
       Enter to confirm · Esc to cancel

What Claude Code 2.1.322 really draws (T1385, measured on an isolated socket):
the prompt is its FIRST line, cut to ~48 columns and ended with `…`, whatever
the width; under ~60 columns the label is a column of its own (`scheduled` /
`task` on two rows) and the rest wraps beside it; at ~90 the prompt wraps under
`scheduled task · Runs once in 50d ·`. So a task is its start row plus the
deeper-indented rows under it, and a prompt is matched as SHOWN: whitespace may
fold into a wrap, a wrap may split a word (CJK has no spaces), and a cut prompt
is a prefix of at least MIN_PREFIX characters (or its whole first line).

`parse` only answers for the exact dialog: header, one row group per task,
the selected first choice and the footer as the screen's last rows. `matches`
pairs every expected job with exactly ONE shown task and every shown task with
exactly one job; a prefix two jobs share is ambiguous and refused.
"""
import re

HEADER = ['Background work is running', 'The following will stop when you exit:']
FOOTER = ['❯ 1. Exit and stop tasks', '2. Move to background and exit', '3. Stay',
          'Enter to confirm · Esc to cancel']
ELLIPSIS = '…'
# A cut prompt names its job only by what is left of it: at least this many
# non-space characters, unless what is shown is the prompt's whole first line.
MIN_PREFIX = 12

_START = re.compile(r'(scheduled|cron)(?: task)?(?=\s|$)')
_FIELDS = re.compile(r'·\s+(.*?)(?:\s+·\s+(.*))?', re.S)


def _rows(screen):
    return [(len(raw) - len(raw.lstrip()), raw.strip()) for raw in screen.splitlines() if raw.strip()]


def open_dialog(screen):
    """The dialog is the screen's bottom with its first choice selected —
    nothing more is claimed (used only to dismiss it with Esc)."""
    lines = [text for _, text in _rows(screen)]
    return lines[-4:] == FOOTER and any(lines[i:i + 2] == HEADER for i in range(len(lines) - 5))


def parse(screen):
    """[{kind, desc, prompt, cut}] for the exact dialog at the screen's bottom,
    else None. Any row between header and footer that is neither a task's start
    nor deeper than it refuses the whole dialog."""
    rows = _rows(screen)
    lines = [text for _, text in rows]
    if lines[-4:] != FOOTER:
        return None
    starts = [i for i in range(len(lines) - 5) if lines[i:i + 2] == HEADER]
    if not starts:
        return None
    body = rows[starts[-1] + 2:-4]
    items = []
    for indent, text in body:
        m = _START.match(text)
        if m and (not items or indent <= items[-1]['indent']):
            items.append(dict(indent=indent, kind=m[1], label=m[0] != m[1], cut=text.endswith(ELLIPSIS),
                              rows=[text[m.end():].strip()]))
            continue
        if not items or items[-1]['cut']:
            return None
        item = items[-1]
        if not item['label'] and len(item['rows']) == 1 and re.match(r'task(?=\s|$)', text):
            # Narrow: the label column's second row carries the rest beside it.
            item['label'] = True
            text = text[4:].strip()
        elif indent <= item['indent']:
            return None
        item['rows'].append(text)
        item['cut'] = text.endswith(ELLIPSIS)
    out = []
    for item in items:
        content = '\n'.join(r for r in item['rows'] if r)
        m = _FIELDS.fullmatch(content)
        if not item['label'] or not m:
            return None
        prompt = m[2] or ''
        cut = prompt.endswith(ELLIPSIS)
        out.append(dict(kind=item['kind'], desc=m[1], prompt=prompt[:-1].rstrip() if cut else prompt, cut=cut))
    return out


def _shown(label, shown):
    """How many characters of `label` the rendering `shown` covers, or None.
    A whitespace run in the label is one in the rendering (a row break counts);
    a row break may also split two non-space characters."""
    i = j = 0
    while j < len(shown):
        if i >= len(label):
            return None
        if label[i].isspace():
            if not shown[j].isspace():
                return None
            while i < len(label) and label[i].isspace():
                i += 1
            while j < len(shown) and shown[j].isspace():
                j += 1
            continue
        if shown[j] == '\n':
            j += 1
            if j >= len(shown):
                break
        if shown[j] != label[i]:
            return None
        i += 1
        j += 1
    return i


def prompt_shown(prompt, shown, cut):
    """Whether `shown` (a task row's prompt, its `…` removed when `cut`) is how
    the dialog draws `prompt`."""
    prompt = prompt.strip()
    if not prompt or not shown:
        return False
    if not cut:
        return _shown(prompt, shown) == len(prompt)
    first = prompt.splitlines()[0].strip()
    for label in dict.fromkeys([prompt, first]):
        n = _shown(label, shown)
        if n is not None and (n == len(label) or len(re.sub(r'\s', '', label[:n])) >= MIN_PREFIX):
            return True
    return False


def same(label, shown):
    """A whole field (an expression, an invocation), whitespace folding allowed."""
    label = label.strip()
    return bool(label) and _shown(label, shown) == len(label)


def matches(items, jobs, fits):
    """Every job pairs with exactly one shown task and every task with exactly
    one job (fits(job, item) -> bool)."""
    if items is None or not jobs or len(items) != len(jobs):
        return False
    pairs = [[fits(job, item) for item in items] for job in jobs]
    return (all(sum(row) == 1 for row in pairs)
            and all(sum(row[k] for row in pairs) == 1 for k in range(len(items))))


def job_fits(prompt, expr=''):
    """The usual pairing: the job's expression is the task's description, or
    its prompt is the task's prompt as drawn."""
    def fits(item):
        return bool((expr and same(expr, item['desc']))
                    or prompt_shown(prompt, item['prompt'], item['cut']))
    return fits
