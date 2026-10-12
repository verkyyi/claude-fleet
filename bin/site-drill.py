#!/usr/bin/env python3
"""site-drill.py — the live drill's run, as the website's seconds (issue #3589,
EPIC #3569 C19).

    site-drill.py <run dir> [--out <file>] [--date YYYY-MM-DD] [--rename OLD=NEW]…

<run dir> is what `fleet-onboard-drill.sh --hub prod --runs 3 --out <dir>`
(bin/fleet-onboard-clock.sh) left behind — read, never changed:

    clock.tsv                       run t_enter t_installed t_browser t_cert
                                    t_machine t_ready t_key (ms since t_enter)
    screens/run<n>-NNN-<ms>ms.txt   every screen, as it changed
    screens/run<n>-last.txt         the last one
    report.md                       its heading carries the drill's date

It writes the drill file bin/site-build.sh reads (default site/drill.json):

    {"date": "YYYY-MM-DD", "source": "fleet-onboard-clock",
     "runs": [{"run": 1, "total": 46.2,
               "steps": {"login": 8.1, "machine": 6.0, "first": 32.1},
               "screens": {"login": "…", "machine": "…", "first": "…"}}, …]}

The page's three steps are the drill's own marks: 1 点试用，登录 = the pasted
line to the certificate (t_cert) · 2 领到你的机器 = t_cert → the first session
placed (t_machine) · 3 说第一句话 = t_machine → the first key the agent took
(t_key); total = t_key. Each step's screen is the first one captured at or after
its mark, of the SAME run as its seconds — the build shows the slowest run's.

A run that never reached the first key is no measurement: the file is not
written (exit 1) — the slowest of three is the one shown, and a run that never
finished is slower than any number.

The screens are the public page's pictures, so every name in them is made
neutral: the drill's login (drill…) → alice, the sandbox's computer
(newcomer-…) → laptop, any hub address → hub.example.com, and every match of
conf/oss-scan.rules → its placeholder. --rename OLD=NEW (repeatable) takes a
session name or anything else to a neutral example task.

Exit: 0 written · 1 not a usable drill (says why) · 2 usage.
"""
import datetime
import glob
import json
import os
import re
import sys

STEPS = (('login', 't_cert'), ('machine', 't_machine'), ('first', 't_key'))
LINES, COLS = 10, 56
HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(HERE)


def die(msg, rc=1):
    print('site-drill: ' + msg, file=sys.stderr)
    sys.exit(rc)


def scan_rules():
    """conf/oss-scan.rules as (regex, placeholder): the one table of internal names."""
    out, keep = [], []
    p = os.path.join(REPO, 'conf', 'oss-scan.rules')
    if not os.path.isfile(p):
        return out, keep
    holders = {'machine': 'mac-a', 'person': 'alice', 'gh-owner': 'alice',
               'ts-net': 'hub.example.com', 'tailnet': 'example'}
    for line in open(p, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('#@keep\t'):
            keep.append(line.split('\t', 1)[1])
        elif line and not line.startswith('#') and line.count('\t') >= 2:
            rid, rx = line.split('\t')[:2]
            try:
                out.append((re.compile(rx), holders.get(rid, '…')))
            except re.error:
                pass
    return out, keep


RULES, KEEP = scan_rules()


def neutral(text, renames):
    for old, new in renames:
        text = text.replace(old, new)
    text = re.sub(r'https?://[A-Za-z0-9.-]+(:[0-9]+)?', 'https://hub.example.com', text)
    text = re.sub(r'(?<![A-Za-z0-9_])drill[a-z]*[0-9][a-z0-9]*', 'alice', text)
    text = re.sub(r'newcomer-[0-9]+-[0-9]+', 'laptop', text)
    for rx, ph in RULES:
        def sub(m, ph=ph):
            s = m.group(0)
            if s.strip(' /:.,;()[]<>"\'') in KEEP:
                return s
            g = [x for x in m.groups() if x is not None] if m.re.groups else []
            # a rule spells its boundary as a group: keep the boundary characters
            lead = g[0] if g and s.startswith(g[0]) and len(g[0]) <= 1 else ''
            tail = g[-1] if len(g) > 1 and s.endswith(g[-1]) and len(g[-1]) <= 1 else ''
            return lead + ph + tail
        text = rx.sub(sub, text)
    return text


def trim(text):
    rows = [r.rstrip() for r in text.split('\n')]
    while rows and not rows[-1]:
        rows.pop()
    while rows and not rows[0]:
        rows.pop(0)
    return '\n'.join(r[:COLS] for r in rows[-LINES:])


def screen_at(shots, run, mark, last):
    """The first screen of <run> captured at or after <mark> ms, else its last."""
    for ms, path in shots.get(run, []):
        if ms >= mark:
            return path
    return last if os.path.isfile(last) else (shots[run][-1][1] if shots.get(run) else None)


def main(argv):
    rundir, out, day, renames = None, os.path.join(REPO, 'site', 'drill.json'), None, []
    a = list(argv)
    while a:
        x = a.pop(0)
        if x in ('-h', '--help'):
            print(__doc__.strip())
            return 0
        if x in ('--out', '--date', '--rename'):
            if not a:
                die(x + ' needs a value', 2)
            v = a.pop(0)
            if x == '--out':
                out = v
            elif x == '--date':
                day = v
            else:
                if '=' not in v:
                    die('--rename wants OLD=NEW', 2)
                renames.append(tuple(v.split('=', 1)))
        elif x.startswith('-') or rundir:
            die('unknown argument ' + x, 2)
        else:
            rundir = x
    if not rundir:
        die('usage: site-drill.py <run dir> [--out <file>] [--date YYYY-MM-DD] [--rename OLD=NEW]', 2)
    tsv = os.path.join(rundir, 'clock.tsv')
    if not os.path.isfile(tsv):
        die('%s has no clock.tsv — not a `fleet-onboard-drill.sh --runs N` run' % rundir)

    if day is None:
        rep = os.path.join(rundir, 'report.md')
        m = re.search(r'\d{4}-\d{2}-\d{2}', open(rep, encoding='utf-8').read()) if os.path.isfile(rep) else None
        day = m.group(0) if m else datetime.date.fromtimestamp(os.path.getmtime(tsv)).isoformat()
    try:
        datetime.datetime.strptime(day, '%Y-%m-%d')
    except ValueError:
        die('--date wants YYYY-MM-DD, not ' + day, 2)

    shots = {}
    for p in glob.glob(os.path.join(rundir, 'screens', 'run*-*-*ms.txt')):
        m = re.match(r'run(\d+)-\d+-(\d+)ms\.txt$', os.path.basename(p))
        if m:
            shots.setdefault(m.group(1), []).append((int(m.group(2)), p))
    for v in shots.values():
        v.sort()

    rows = [l.rstrip('\n').split('\t') for l in open(tsv, encoding='utf-8') if l.strip()]
    if len(rows) < 2:
        die('clock.tsv has no run')
    head = rows[0]
    runs = []
    for r in rows[1:]:
        rec = dict(zip(head, r))
        n = rec.get('run', '?')
        try:
            t = {k: int(rec[k]) for _, k in STEPS}
        except (KeyError, ValueError):
            missing = [k for _, k in STEPS if not rec.get(k, '').strip()]
            die('run %s never reached %s — not a measurement, so no seconds for the page'
                % (n, missing[0] if missing else 'its marks'))
        prev, steps, screens = 0, {}, {}
        for name, k in STEPS:
            steps[name] = round((t[k] - prev) / 1000.0, 1)
            prev = t[k]
            p = screen_at(shots, n, t[k], os.path.join(rundir, 'screens', 'run%s-last.txt' % n))
            if p:
                screens[name] = trim(neutral(open(p, encoding='utf-8', errors='replace').read(), renames))
        run = {'run': int(n) if n.isdigit() else n, 'total': round(t['t_key'] / 1000.0, 1), 'steps': steps}
        if len(screens) == len(STEPS):
            run['screens'] = screens
        runs.append(run)

    doc = {'date': day, 'source': 'fleet-onboard-clock', 'runs': runs}
    tmp = out + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
        fh.write('\n')
    os.replace(tmp, out)
    slow = max(runs, key=lambda r: r['total'])
    print('site-drill: %s → %s (%d runs, slowest %.1f s, %s)'
          % (rundir, out, len(runs), slow['total'], 'with screens' if 'screens' in slow else 'NO screens'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
