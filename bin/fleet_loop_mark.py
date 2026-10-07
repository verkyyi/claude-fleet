#!/usr/bin/env python3
"""`@loop` — the deterministic "this window has a Loop pending" mark (issue #1331).

Usage: fleet_loop_mark.py hook                         (PostToolUse, stdin JSON)
       fleet_loop_mark.py window <target> [--socket-name S]
       fleet_loop_mark.py status --value V [--manifest M] [--now N]
       fleet_loop_mark.py due --value V [--manifest M] --within S [--now N]
       fleet_loop_mark.py backfill <target> [--transcript P] [--socket-name S]
                                             [--max-bytes N] [--now N]
       fleet_loop_mark.py sweep [--socket-name S]      (every window of one fleet)
       fleet_loop_mark.py rearm --transcript P [--now N]

A worker that ran `/loop` ends every turn with a ScheduleWakeup (or holds a
CronCreate job), so the Stop hook used to stamp it `done` — and the dash counted it
finished, and the merged-PR reapers closed the window with the Loop inside it. The
screen classifier could re-read it as LOOPING, but only when installed, only when
its call succeeded, only when the screen changed. This is the signal that does not
depend on any of that: the PostToolUse hook (matcher
`ScheduleWakeup|CronCreate|CronDelete`) records what the agent itself scheduled.

The value is ONE line of space-separated `k=v` fields:

    kind=wakeup,cron next=<epoch> ttl=<s> id=<job>@<until>,<job>@<until>
         at=<job>@<fire> cron=<job>@<m_h_dom_mon_dow>

  kind   which of the two halves are present (`wakeup`, `cron`, or both)
  next   the epoch the pending ScheduleWakeup fires; ttl its (clamped) delay
  id     CronCreate job ids, each with the epoch past which it is gone on its own
         (a recurring job auto-expires after 7 days; a pinned one-shot after it fires)
  at     one token per pinned one-shot job: the epoch it fires (issue #1690)
  cron   one token per recurring job: its 5-field spec, spaces written `_`

`at` / `cron` say WHEN a job fires next, which `id` alone cannot (a recurring
job's `until` is its expiry). `due` reads them: a Loop whose every known round is
more than S seconds away is PARKED — an idle session between rounds, not a running
one (fleet-install-sync.sh applies under it). A job with neither (a mark written
before #1690), an unreadable spec or a live ledger is always `due`: unknown is busy.

EXPIRY IS THE READER'S (no resident process): a wakeup whose `next + max(600, ttl/2)`
has passed with no newer ScheduleWakeup was not renewed — the loop stopped; a cron
id past its `until` has expired. So a stopped Loop reads `none` with no writer.

BACKFILL (issue #1370): the hook only sees calls made after it was installed, so a
session that scheduled its wakeup before the sync carries no `@loop` until it calls
ScheduleWakeup again — and reads `done` meanwhile. `backfill` replays the tail of
the window's Claude transcript through the same apply() (each successful
ScheduleWakeup / CronCreate / CronDelete, at its result's timestamp) and writes the
result ONLY when the window has no `@loop` and the replay is still active now. It
never clears: expiry stays the reader's. Run by the Stop hook (a window with neither
`@loop` nor a mod heartbeat) and by fleet-install-apply.sh's `loopmark` step.

REARM (issue #1846): the Loop itself lives in the agent PROCESS — a window that is
killed (or a fleet brought back after a crash or `fleet down`) is reopened with
`claude --resume`, which brings the conversation back but not the ScheduleWakeup /
CronCreate it had pending. `rearm` replays the transcript the same way backfill
does and, when a Loop is still pending, prints the ONE line the reopened session
should take as its first turn: `/loop <the input it was scheduled with>` (a
recurring job's spec as `/loop <N>m|h|d …`; the autonomous sentinel as a bare
`/loop`). Nothing pending → nothing printed, exit 1. fleet-restore.sh hands the
line to the resume of a window it snapshotted `looping`.

The fleet-loop.py ledger (`<manifest dir>/loop/state.json`, a transferred Codex /
Claude loop) counts as a Loop too while its status is one that will still deliver.
`window` answers both in one place; every reader (the Stop hook, the classifier,
fleet-reap-live.py, the dash counters, the EPIC backstop/report) asks it rather than
re-deriving. A window with no `@loop` and no ledger answers exactly as before.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fleet_iso  # noqa: E402  the one ISO reader (issue #2024)

GRACE_MIN = 600                    # a wakeup may fire this late before we call it stopped
CRON_LIFE = 7 * 86400 + 900        # recurring CronCreate auto-expires after 7 days (+ jitter)
WAKE_MIN, WAKE_MAX = 60, 3600      # ScheduleWakeup's own clamp
LEDGER_LIVE = ('active', 'waiting-quota', 'hibernating', 'delivering')
ID_OK = re.compile(r'[A-Za-z0-9_.:-]{1,64}')
SPEC_OK = re.compile(r'[0-9*,/-]+(?:_[0-9*,/-]+){4}')
CRON_JITTER = 900                  # a recurring job may fire up to 15 min after its minute


def parse(value):
    """`k=v k=v` → dict of the fields we know; anything malformed is dropped."""
    out = {'next': 0, 'ttl': 0, 'ids': [], 'at': {}, 'cron': {}}
    for tok in (value or '').split():
        k, _, v = tok.partition('=')
        if k in ('next', 'ttl') and v.isdigit():
            out[k] = int(v)
        elif k == 'id':
            for ent in v.split(','):
                job, _, until = ent.partition('@')
                if ID_OK.fullmatch(job) and until.isdigit():
                    out['ids'].append((job, int(until)))
        elif k in ('at', 'cron'):
            job, _, w = v.partition('@')
            if ID_OK.fullmatch(job) and (w.isdigit() if k == 'at' else SPEC_OK.fullmatch(w)):
                out[k][job] = int(w) if k == 'at' else w
    return out


def fmt(d):
    kinds, parts = [], []
    if d.get('next'):
        kinds.append('wakeup')
        parts += ['next=%d' % d['next'], 'ttl=%d' % d.get('ttl', 0)]
    if d.get('ids'):
        kinds.append('cron')
        parts.append('id=' + ','.join('%s@%d' % e for e in d['ids']))
        for job, _ in d['ids']:
            if job in d.get('at', {}):
                parts.append('at=%s@%d' % (job, d['at'][job]))
            elif job in d.get('cron', {}):
                parts.append('cron=%s@%s' % (job, d['cron'][job]))
    return ' '.join(['kind=' + ','.join(kinds)] + parts) if kinds else ''


def wake_until(d):
    return d['next'] + max(GRACE_MIN, d.get('ttl', 0) // 2) if d.get('next') else 0


def prune(d, now):
    """Drop the halves that have already lapsed on their own."""
    if d.get('next') and wake_until(d) < now:
        d['next'] = d['ttl'] = 0
    d['ids'] = [e for e in d.get('ids', []) if e[1] >= now]
    live = {e[0] for e in d['ids']}
    for k in ('at', 'cron'):
        d[k] = {j: w for j, w in d.get(k, {}).items() if j in live}
    return d


def oneshot_fire(cron, now):
    """Epoch of a pinned one-shot `M H DoM Mon *` (local time), else None."""
    f = (cron or '').split()
    if len(f) != 5 or not all(x.isdigit() for x in f[:4]):
        return None
    mi, hr, dom, mon = (int(x) for x in f[:4])
    year = time.localtime(now).tm_year
    for y in (year, year + 1):
        try:
            t = time.mktime(datetime.datetime(y, mon, dom, hr, mi).timetuple())
        except (ValueError, OverflowError):
            return None
        if t + GRACE_MIN >= now:
            return int(t)
    return None


def cron_id(resp):
    if isinstance(resp, dict):
        for k in ('id', 'jobId', 'job_id'):
            v = resp.get(k)
            if isinstance(v, str) and ID_OK.fullmatch(v):
                return v
        resp = json.dumps(resp)
    if isinstance(resp, list):
        resp = json.dumps(resp)
    m = re.search(r'\b(?:task|job)\s+([A-Za-z0-9_.:-]{4,64})', str(resp or ''))
    return m.group(1) if m else None


def apply(value, payload, now=None):
    """The `@loop` after one PostToolUse event ('' = clear)."""
    now = int(time.time()) if now is None else int(now)
    d = prune(parse(value), now)
    name = payload.get('tool_name', '')
    inp = payload.get('tool_input') or {}
    if not isinstance(inp, dict):
        inp = {}
    if name == 'ScheduleWakeup':
        if inp.get('stop') is True:
            d['next'] = d['ttl'] = 0
        else:
            try:
                delay = int(inp.get('delaySeconds'))
            except (TypeError, ValueError):
                delay = WAKE_MIN
            delay = min(max(delay, WAKE_MIN), WAKE_MAX)
            d['next'], d['ttl'] = now + delay, delay
    elif name == 'CronCreate':
        job = cron_id(payload.get('tool_response'))
        if job:
            until = now + CRON_LIFE
            d['at'].pop(job, None)
            d['cron'].pop(job, None)
            spec = '_'.join(str(inp.get('cron') or '').split())
            if inp.get('recurring') is False:
                fire = oneshot_fire(inp.get('cron'), now)
                if fire is not None:
                    until = fire + GRACE_MIN
                    d['at'][job] = fire
            elif SPEC_OK.fullmatch(spec):
                d['cron'][job] = spec
            d['ids'] = [e for e in d['ids'] if e[0] != job] + [(job, until)]
    elif name == 'CronDelete':
        job = str(inp.get('id') or '')
        d['ids'] = [e for e in d['ids'] if e[0] != job]
        d['at'].pop(job, None)
        d['cron'].pop(job, None)
    return fmt(d)


def _epoch(ts):
    try:
        return int(fleet_iso.parse(ts).timestamp())
    except (TypeError, ValueError):
        return None


def claude_tool_results(lines, names, strict=False):
    """Each SUCCESSFUL main-thread call of a tool in <names>, in transcript order:
    (name, input, response, use_ts, result_ts). A sidechain (subagent) call is not
    the session's; an is_error result never happened. strict=False skips a torn
    line — a tail read starts mid-line. fleet-loop.py from_claude shares this."""
    calls = {}
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            if strict:
                raise
            continue
        if not isinstance(row, dict) or row.get('isSidechain'):
            continue
        msg = row.get('message')
        content = msg.get('content', []) if isinstance(msg, dict) else []
        for b in content if isinstance(content, list) else []:
            if not isinstance(b, dict):
                continue
            if b.get('type') == 'tool_use' and b.get('name') in names and 'id' in b:
                inp = b.get('input')
                calls[b['id']] = (b['name'], inp if isinstance(inp, dict) else {}, row.get('timestamp'))
            elif (b.get('type') == 'tool_result' and b.get('tool_use_id') in calls
                  and not b.get('is_error')):
                name, inp, use_ts = calls.pop(b['tool_use_id'])
                resp = row.get('toolUseResult')
                if resp is None:
                    resp = b.get('content')
                    if isinstance(resp, list):
                        resp = ' '.join(x.get('text', '') for x in resp if isinstance(x, dict))
                yield name, inp, resp, use_ts, row.get('timestamp') or use_ts


def replay(lines, now=None):
    """The `@loop` the PostToolUse hook would hold now, had it seen every call."""
    now = int(time.time()) if now is None else int(now)
    value = ''
    for name, inp, resp, use_ts, res_ts in claude_tool_results(
            lines, ('ScheduleWakeup', 'CronCreate', 'CronDelete')):
        at = _epoch(res_ts) or _epoch(use_ts)
        if at is None:
            continue
        value = apply(value, {'tool_name': name, 'tool_input': inp, 'tool_response': resp}, at)
    return fmt(prune(parse(value), now))



def loop_input(prompt):
    """The `/loop …` line that re-enters a Loop scheduled with <prompt>."""
    prompt = ' '.join(str(prompt or '').split())
    if not prompt or prompt.startswith('<<autonomous-loop'):
        return '/loop'
    return prompt if prompt == '/loop' or prompt.startswith('/loop ') else '/loop ' + prompt


def cron_every(spec):
    """A recurring cron spec → `/loop`'s interval word (`5m`, `2h`, `1d`), else None."""
    f = (spec or '').split()
    if len(f) != 5 or f[2:] != ['*', '*', '*']:
        return None
    mi, hr = f[0], f[1]
    if hr == '*' and mi == '*':
        return '1m'
    if hr == '*' and re.fullmatch(r'\*/\d+', mi):
        return mi[2:] + 'm'
    if mi.isdigit() and re.fullmatch(r'\*/\d+', hr):
        return hr[2:] + 'h'
    if mi.isdigit() and hr == '*':
        return '1h'
    if mi.isdigit() and hr.isdigit():
        return '1d'
    return None


def rearm(lines, now=None):
    """The first turn that puts a reopened session's pending Loop back, or ''."""
    now = int(time.time()) if now is None else int(now)
    value, wake, jobs = '', None, {}
    for name, inp, resp, use_ts, res_ts in claude_tool_results(
            lines, ('ScheduleWakeup', 'CronCreate', 'CronDelete')):
        at = _epoch(res_ts) or _epoch(use_ts)
        if at is None:
            continue
        value = apply(value, {'tool_name': name, 'tool_input': inp, 'tool_response': resp}, at)
        if name == 'ScheduleWakeup':
            wake = None if inp.get('stop') is True else inp.get('prompt')
        elif name == 'CronCreate':
            job = cron_id(resp)
            if job:
                jobs[job] = inp
        elif name == 'CronDelete':
            jobs.pop(str(inp.get('id') or ''), None)
    d = prune(parse(value), now)
    if d['next'] and isinstance(wake, str):
        return loop_input(wake)
    for job, _ in reversed(d['ids']):
        inp = jobs.get(job) or {}
        if inp.get('recurring') is False or not isinstance(inp.get('prompt'), str):
            continue                   # a one-shot reminder is not a Loop
        every = cron_every(inp.get('cron'))
        line = loop_input(inp['prompt'])
        if every:
            line = '/loop %s%s' % (every, line[5:])
        return line
    return ''


TAIL_BYTES = 262144                # the Stop hook's read budget: a few hundred turns


def tail_lines(path, max_bytes=TAIL_BYTES):
    with open(path, 'rb') as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - max_bytes))
        data = fh.read()
    lines = data.decode('utf-8', 'replace').splitlines()
    return lines[1:] if size > max_bytes else lines


def transcript_for(opt):
    """A window's own Claude transcript: @cc_session_id (Stop/SessionStart stamp it,
    issue #1296), else the pane's Claude pid's session registry. None = unknown."""
    sid = opt('@cc_session_id')
    if not sid:
        try:
            lib = str(Path(__file__).with_name('fleet-lib.sh'))
            pid = subprocess.check_output(
                ['bash', '-c', '. "$1"; fleet_pane_claude_pid "$2" "$3"', 'loopmark', lib,
                 opt('window_id'), opt('_socket')], text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
            reg = Path(os.environ.get('FLEET_CC_SESSIONS_DIR', str(Path.home() / '.claude/sessions'))) / (pid + '.json')
            sid = json.loads(reg.read_text()).get('sessionId') if pid.isdigit() else ''
        except (OSError, ValueError, subprocess.SubprocessError, AttributeError):
            sid = ''
    if not isinstance(sid, str) or not re.fullmatch(r'[0-9a-fA-F-]{36}', sid):
        return None
    projects = Path(os.environ.get('FLEET_CC_PROJECTS_DIR',
                                   os.environ.get('CLAUDE_PROJECTS_DIR', str(Path.home() / '.claude/projects'))))
    hits = list(projects.glob('*/' + sid + '.jsonl'))
    return hits[0] if len(hits) == 1 else None


def backfill(target, transcript=None, socket_name=None, max_bytes=TAIL_BYTES, now=None):
    """('marked', value) | ('skip', why). Writes @loop only where none is set."""
    tm = ['tmux'] + (['-L', socket_name] if socket_name else [])

    def opt(name):
        if name == '_socket':
            return socket_name or ''
        return subprocess.check_output(tm + ['display-message', '-p', '-t', target, '#{%s}' % name],
                                       text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
    if opt('@loop'):
        return 'skip', 'has-loop'
    if opt('@cc_agent') == 'codex':
        return 'skip', 'codex'
    path = Path(transcript) if transcript else transcript_for(opt)
    if path is None or not path.is_file():
        return 'skip', 'no-transcript'
    value = replay(tail_lines(path, max_bytes), now)
    if not value:
        return 'skip', 'none'
    subprocess.call(tm + ['set-window-option', '-t', target, '@loop', value],
                    stderr=subprocess.DEVNULL, timeout=5)
    return 'marked', value


PANELS = ('dash', 'plan', 'backlog')


def sweep(socket_name=None, max_bytes=TAIL_BYTES, now=None):
    """backfill() over every agent window of one fleet's server → (marked, seen).
    fleet-install-apply.sh's `loopmark` step runs it once per fleet socket, so a
    session that scheduled its Loop before this version was synced is marked
    without waiting for its next Stop."""
    tm = ['tmux'] + (['-L', socket_name] if socket_name else [])
    rows = subprocess.check_output(tm + ['list-windows', '-a', '-F', '#{window_id}\t#{window_name}'],
                                   text=True, stderr=subprocess.DEVNULL, timeout=10).splitlines()
    marked = seen = 0
    for row in rows:
        wid, _, name = row.partition('\t')
        if not re.fullmatch(r'@\d+', wid) or name in PANELS:
            continue
        try:
            st, why = backfill(wid, None, socket_name, max_bytes, now)
        except (OSError, subprocess.SubprocessError):
            st, why = 'skip', 'unreadable'
        if why in ('codex', 'no-transcript'):
            continue                   # not a Claude window this login can read
        seen += 1
        marked += st == 'marked'
    return marked, seen


def ledger_status(manifest):
    if not manifest:
        return ''
    try:
        r = json.loads((Path(manifest).parent / 'loop' / 'state.json').read_text())
    except (OSError, ValueError):
        return ''
    s = r.get('status') if isinstance(r, dict) else None
    return s if s in LEDGER_LIVE else ''


def status(value, manifest='', now=None):
    """('active'|'none', reason)."""
    now = int(time.time()) if now is None else int(now)
    d = prune(parse(value), now)
    if d['next']:
        return 'active', 'wakeup:next=%d' % d['next']
    if d['ids']:
        return 'active', 'cron:' + ','.join(e[0] for e in d['ids'])
    led = ledger_status(manifest)
    if led:
        return 'active', 'ledger:' + led
    return 'none', ('expired' if (value or '').strip() else 'unset')


def _cron_field(f, lo, hi):
    """One cron field → the set of values it allows; None when unreadable."""
    vals = set()
    for part in f.split(','):
        rng, _, step = part.partition('/')
        if step and not step.isdigit():
            return None
        step = int(step) if step else 1
        if rng == '*':
            a, b = lo, hi
        elif '-' in rng:
            a, _, b = rng.partition('-')
            if not (a.isdigit() and b.isdigit()):
                return None
            a, b = int(a), int(b)
        elif rng.isdigit():
            a = int(rng)
            b = hi if step > 1 else a
        else:
            return None
        if step < 1 or a < lo or b > hi or a > b:
            return None
        vals.update(range(a, b + 1, step))
    return vals


def cron_fires(spec, start, end):
    """True when the `_`-joined 5-field spec has a minute in [start, end] (local
    time, standard cron: DoM and DoW are OR'd when both are restricted); None when
    the spec is unreadable."""
    f = spec.split('_')
    if len(f) != 5:
        return None
    sets = [_cron_field(f[0], 0, 59), _cron_field(f[1], 0, 23), _cron_field(f[2], 1, 31),
            _cron_field(f[3], 1, 12), _cron_field(f[4], 0, 7)]
    if any(x is None for x in sets):
        return None
    mi, hr, dom, mon, dow = sets
    if 7 in dow:
        dow.add(0)
    dom_any, dow_any = f[2].startswith('*'), f[4].startswith('*')
    t = start - start % 60
    end = min(end, start + 8 * 86400)
    while t <= end:
        lt = time.localtime(t)
        day = ((lt.tm_mday in dom) or (lt.tm_wday + 1) % 7 in dow) \
            if not (dom_any or dow_any) else \
            ((lt.tm_mday in dom) and ((lt.tm_wday + 1) % 7 in dow))
        if lt.tm_min in mi and lt.tm_hour in hr and lt.tm_mon in mon and day:
            return True
        t += 60
    return False


def due(value, manifest='', within=600, now=None):
    """('due'|'parked'|'none', reason) — may a round of this Loop start within
    <within> seconds? Unknown is `due`; `parked` only when every pending round is
    known to be further away (issue #1690)."""
    now = int(time.time()) if now is None else int(now)
    d = prune(parse(value), now)
    if ledger_status(manifest):
        return 'due', 'ledger'
    if not d['next'] and not d['ids']:
        return 'none', ('expired' if (value or '').strip() else 'unset')
    if d['next'] and d['next'] - now <= within:
        return 'due', 'wakeup:next=%d' % d['next']
    for job, _ in d['ids']:
        if job in d['at']:
            if d['at'][job] - now <= within:
                return 'due', 'cron:%s@%d' % (job, d['at'][job])
        elif job in d['cron']:
            hit = cron_fires(d['cron'][job], now - CRON_JITTER, now + within)
            if hit is not False:
                return 'due', 'cron:%s:%s' % (job, 'spec?' if hit is None else 'fires')
        else:
            return 'due', 'cron:%s:unknown' % job
    parts = (['wakeup:next=%d' % d['next']] if d['next'] else []) + \
        ['cron:%s@%d' % (j, d['at'][j]) if j in d['at'] else 'cron:%s' % j for j, _ in d['ids']]
    return 'parked', ','.join(parts)


def window(target, socket_name=None, now=None):
    tm = ['tmux'] + (['-L', socket_name] if socket_name else [])
    raw = subprocess.check_output(
        tm + ['display-message', '-p', '-t', target, '#{@loop}\t#{@handoff_manifest}'],
        text=True, stderr=subprocess.DEVNULL, timeout=5).rstrip('\n')
    value, _, manifest = raw.partition('\t')
    return status(value, manifest, now)


def hook():
    # Only the interactive TUI owns the pane (issue #571): a headless `claude -p`
    # inherits TMUX_PANE and the global hooks, and its schedule is not this pane's.
    if os.environ.get('CLAUDE_CODE_ENTRYPOINT', 'cli') != 'cli':
        return 0
    pane = os.environ.get('TMUX_PANE', '')
    if not os.environ.get('TMUX') or not pane:
        return 0
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get('tool_name') not in (
            'ScheduleWakeup', 'CronCreate', 'CronDelete'):
        return 0
    try:
        cur = subprocess.check_output(['tmux', 'display-message', '-p', '-t', pane, '#{@loop}'],
                                      text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
        new = apply(cur, payload)
        if new:
            subprocess.call(['tmux', 'set-window-option', '-t', pane, '@loop', new],
                            stderr=subprocess.DEVNULL, timeout=5)
        elif cur:
            subprocess.call(['tmux', 'set-window-option', '-u', '-t', pane, '@loop'],
                            stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('hook')
    w = sub.add_parser('window')
    w.add_argument('target')
    w.add_argument('--socket-name')
    w.add_argument('--now', type=int)
    b = sub.add_parser('backfill')
    b.add_argument('target')
    b.add_argument('--transcript')
    b.add_argument('--socket-name')
    b.add_argument('--max-bytes', type=int, default=TAIL_BYTES)
    b.add_argument('--now', type=int)
    w2 = sub.add_parser('sweep')
    w2.add_argument('--socket-name')
    s = sub.add_parser('status')
    s.add_argument('--value', default='')
    s.add_argument('--manifest', default='')
    s.add_argument('--now', type=int)
    u = sub.add_parser('due')
    u.add_argument('--value', default='')
    u.add_argument('--manifest', default='')
    u.add_argument('--within', type=int, default=600)
    u.add_argument('--now', type=int)
    r = sub.add_parser('rearm')
    r.add_argument('--transcript', required=True)
    r.add_argument('--max-bytes', type=int, default=TAIL_BYTES)
    r.add_argument('--now', type=int)
    a = p.parse_args()
    if a.cmd == 'rearm':
        try:
            line = rearm(tail_lines(a.transcript, a.max_bytes), a.now)
        except OSError:
            return 1
        if line:
            print(line)
        return 0 if line else 1
    if a.cmd == 'hook':
        return hook()
    if a.cmd == 'sweep':
        try:
            marked, seen = sweep(a.socket_name)
        except (OSError, subprocess.SubprocessError):
            print('marked=0 windows=0 unreadable')
            return 1
        print('marked=%d windows=%d' % (marked, seen))
        return 0
    if a.cmd == 'backfill':
        try:
            st, why = backfill(a.target, a.transcript, a.socket_name, a.max_bytes, a.now)
        except (OSError, subprocess.SubprocessError):
            st, why = 'skip', 'unreadable'
        print(st, why)
        return 0 if st == 'marked' else 1
    if a.cmd == 'due':
        st, why = due(a.value, a.manifest, a.within, a.now)
        print(st, why)
        return 0 if st == 'due' else 1
    if a.cmd == 'window':
        try:
            st, why = window(a.target, a.socket_name, a.now)
        except (OSError, subprocess.SubprocessError):
            st, why = 'none', 'unreadable'
    else:
        st, why = status(a.value, a.manifest, a.now)
    print(st, why)
    return 0 if st == 'active' else 1


if __name__ == '__main__':
    sys.exit(main())
