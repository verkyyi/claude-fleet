#!/usr/bin/env python3
"""fleet-children.py — the child-report LEDGER (issue #937): the write half and the
merge-with-live-state read half. Driven by bin/fleet-children-lib.sh
(`children_append`) and bin/fleet-children.sh (the query command); not meant to be
called by hand.

  append  --file <ledger.ndjson>            (event JSON on stdin)
  show    --dir <children-dir> --parent <key> [--json] [--since <seq>]
          [--prmap-dir <dir>] [--prmap <file>]   (live window rows on stdin)

The ledger is one NDJSON file per PARENT KEY (`issue-N` / `scratch-N` /
`<slug>:issue-N` — fleet_origin_canon's spelling, never a window id), so a parent
that is migrated or restored onto a new window id finds its children's record
unchanged. One line per event:

  {"seq": 3, "ts": "2026-09-22T10:00:00Z", "child": "issue-101", "state": "MERGED",
   "pr": "950", "verdict": "", "summary": "…", "title": "…"}

That shape, `children_append`, and `fleet-children.sh`'s text + `--json` output are
a stable interface (C4/C5/C6/R1 of EPIC #935 build on it): add fields, never rename.
"""
import argparse
import datetime
import fcntl
import json
import os
import sys
import time

STATES = ('MERGED', 'BLOCKED', 'FAILED', 'STOPPED', 'REAPED', 'WAITING', 'IDLE')
FIELDS = ('child', 'state', 'pr', 'verdict', 'summary', 'title', 'tier')
# report_tier's three bands (issue #938, fleet-children-lib.sh); '' = a pre-#938 event.
TIERS = ('loud', 'quiet', 'silent')
KEY_OK = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-')

# The dash's state → rank table (tmux-dashboard-rows.sh state_v), verbatim: rank 0
# is the loud `!`, rank 1 counts as done. Kept identical so `fleet-children.sh`'s
# summary and the dash parent row's `3/5 ✓ · 1!` badge can never disagree.
RANK = {'needs': 0, 'failed': 0, 'sleeping': 1, 'preparing': 1, 'waking': 1,
        'done': 1, 'working': 2, 'looping': 3}
PANELS = ('dash', 'plan', 'backlog')
HOPS = 4                       # chain_v's bound — a grandchild past it is an orphan


def clean(s, lines=3, width=200):
    """Same scrub as the envelope (#574): no `<>"`, ≤3 lines of ≤200 chars."""
    s = ''.join(ch for ch in str(s or '') if ch not in '<>"')
    return '\n'.join(l[:width] for l in s.splitlines()[:lines])


def read_events(path):
    out = []
    try:
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue            # a torn line never poisons the rest
                if isinstance(ev, dict) and ev.get('child'):
                    out.append(ev)
    except OSError:
        pass
    return out


def cmd_append(a):
    try:
        ev = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        print('fleet-children: event is not JSON', file=sys.stderr)
        return 2
    if not isinstance(ev, dict):
        return 2
    ev = {k: ev.get(k, '') for k in FIELDS}
    ev['child'] = ''.join(ch for ch in str(ev['child']) if ch in KEY_OK)[:128]
    ev['state'] = str(ev['state']).upper()
    ev['pr'] = ''.join(ch for ch in str(ev['pr']) if ch.isdigit())
    ev['verdict'] = clean(ev['verdict'], 1, 64)
    ev['summary'] = clean(ev['summary'])
    ev['title'] = clean(ev['title'], 1)
    ev['tier'] = str(ev['tier']).lower() if str(ev['tier']).lower() in TIERS else ''
    if not ev['child'] or ev['state'] not in STATES:
        print('fleet-children: need child + state (%s)' % '|'.join(STATES), file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(a.file) or '.', exist_ok=True)
    # a+ and an exclusive flock: two children reporting in the same second get
    # distinct seqs, and the read-then-append below is one critical section.
    with open(a.file, 'a+', encoding='utf-8') as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.seek(0)
        seq, last = 0, None
        for line in fh:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            try:
                seq = max(seq, int(e.get('seq') or 0))
            except (TypeError, ValueError):
                pass
            if e.get('child') == ev['child']:
                last = e
        # Dedup against the child's LATEST event, not the whole file: a reaper
        # repeating the ship path's report is a no-op, while a real transition
        # back (WAITING → IDLE → WAITING) still lands and keeps "latest" true.
        if last and last.get('state') == ev['state'] and str(last.get('pr') or '') == ev['pr']:
            print('dup seq=%s' % last.get('seq'))
            return 0
        ev = dict(seq=seq + 1,
                  ts=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                  **ev)
        fh.seek(0, os.SEEK_END)
        fh.write(json.dumps(ev, ensure_ascii=False) + '\n')
        fh.flush()
    print('seq=%d' % ev['seq'])
    return 0


def win_key(iss, wt, path, pre):
    """okey_v / fleet_win_for_key: @issue, else a strict scratch-<digits> basename
    off @worktree then the pane cwd."""
    if iss:
        return pre + 'issue-' + iss
    for cand in (wt, path):
        bn = cand.rstrip('/').rsplit('/', 1)[-1]
        if bn.startswith('scratch-'):
            sn = bn[len('scratch-'):]
        elif '-scratch-' in bn:
            sn = bn.rsplit('-scratch-', 1)[1]
        else:
            continue
        if sn.isdigit():
            return pre + 'scratch-' + sn
    return ''


def is_key(k):
    b = k.split(':', 1)[1] if ':' in k else k
    return b.startswith('issue-') or b.startswith('scratch-')


def read_windows(stream):
    """Rows: window_id|state|needs|key|origin|window_name (the shell resolved the key)."""
    wins = {}
    for line in stream:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('|', 5)
        if len(parts) < 6:
            continue
        wid, state, needs, key, origin, name = parts
        if not key or key in wins:
            continue                    # first match wins, as fleet_win_for_key
        wins[key] = dict(wid=wid, state=state, needs=needs, origin=origin, name=name)
    return wins


def descends(origin, parent, wins):
    """chain_v's walk: climb @origin through live windows, ≤4 hops. True iff
    <parent> is met on the way — for a ROOT parent this is exactly the dash's
    'this window counts toward that row' (the walk stops at a non-key origin, and
    a chain that leaves the dash is an orphan)."""
    cur = origin
    for _ in range(HOPS):
        if cur == parent:
            return True
        w = wins.get(cur)
        if w is None or not is_key(w['origin']):
            return False
        cur = w['origin']
    return False


def prmap_lookup(key, a, cache={}):
    """(num, state) of the child's branch from the dash's PR cache — no gh call."""
    pre, bare = (key.split(':', 1) if ':' in key else ('', key))
    f = os.path.join(a.prmap_dir, pre, 'prmap') if pre and a.prmap_dir else a.prmap
    if not f:
        return '', ''
    if f not in cache:
        m = {}
        try:
            with open(f, encoding='utf-8') as fh:
                for line in fh:
                    p = line.rstrip('\n').split('\t')
                    if len(p) >= 3 and p[0] not in m:
                        m[p[0]] = (p[1].lstrip('#'), p[2])
        except OSError:
            pass
        cache[f] = m
    return cache[f].get(bare, ('', ''))


def bucket(live, last):
    """✓ done · ⏳ waiting on checks · ! needs a human · ▸ working · – ended unlanded."""
    lst = (last or {}).get('state', '')
    if live is not None:
        rk = RANK.get(live['state'], 4)
        if rk == 0:
            return '!'
        # WAITING splits the dash's ✓: the turn ended (done) but the PR is still
        # in flight. Only when the live window agrees the turn is over.
        if rk == 1 and lst == 'WAITING':
            return '⏳'
        return '✓' if rk == 1 else '▸'
    if lst == 'MERGED' or (lst == 'REAPED' and (last.get('verdict') or '').startswith('merged')):
        return '✓'
    if lst in ('BLOCKED', 'FAILED'):
        return '!'
    if lst == 'WAITING':
        return '⏳'
    return '–'


def age(ts):
    try:
        t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return ''
    s = max(0, int(time.time() - t.timestamp()))
    return '%ds' % s if s < 60 else '%dm' % (s // 60) if s < 3600 else \
        '%dh' % (s // 3600) if s < 86400 else '%dd' % (s // 86400)


def cmd_show(a):
    wins = read_windows(sys.stdin)
    parent = a.parent
    # ledger side: the parent's own file, plus each descendant's (≤4 levels), so a
    # grandchild whose window is gone is still counted under the root — the same
    # "ultimate parent" attribution the live side gets from descends().
    events, seen, frontier = {}, set(), [parent]
    for _ in range(HOPS):
        nxt = []
        for p in frontier:
            if p in seen:
                continue
            seen.add(p)
            for ev in read_events(os.path.join(a.dir, p + '.ndjson')):
                events.setdefault(ev['child'], []).append(ev)
                nxt.append(ev['child'])
        frontier = nxt
    for k, w in wins.items():
        if k != parent and descends(w['origin'], parent, wins):
            events.setdefault(k, [])
    events.pop(parent, None)

    kids = []
    for child, evs in events.items():
        evs.sort(key=lambda e: int(e.get('seq') or 0))
        last = evs[-1] if evs else None
        live = wins.get(child)
        # A LIVE window that no longer descends from this parent (re-parented, or a
        # reused key) belongs to someone else's row now: the ledger alone speaks.
        if live is not None and not descends(live['origin'], parent, wins):
            live = None
        prn, prs = prmap_lookup(child, a)
        kids.append(dict(
            child=child, bucket=bucket(live, last),
            live=live is not None, window=live['wid'] if live else '',
            state=(live['state'] or 'idle') if live else 'gone',
            needs=live['needs'] if live else '',
            title=(live['name'] if live else '') or (last or {}).get('title', ''),
            pr=(last or {}).get('pr') or prn, pr_state=prs,
            last=last,
            since=[e for e in evs if int(e.get('seq') or 0) > a.since]))
    kids.sort(key=lambda k: ('!⏳▸✓–'.index(k['bucket']), k['child']))
    n = {b: sum(1 for k in kids if k['bucket'] == b) for b in '✓⏳!▸–'}
    total = len(kids)
    # Same spelling as the dash badge (`3/5 ✓ · 1!`); ⏳ sits between, both quiet
    # parts drop out at zero so a no-WAITING subtree reads byte-for-byte as the dash.
    text = '%d/%d ✓' % (n['✓'], total) if total else '0 children'
    if n['⏳']:
        text += ' · %d⏳' % n['⏳']
    if n['!']:
        text += ' · %d!' % n['!']
    summary = dict(total=total, done=n['✓'], waiting=n['⏳'], needs=n['!'],
                   working=n['▸'], ended=n['–'], text=text)
    seqmax = max([int(e.get('seq') or 0) for evs in events.values() for e in evs] or [0])
    if a.since:
        kids = [k for k in kids if k['since']]

    if a.json:
        out = dict(parent=parent, session=a.session, seq=seqmax, summary=summary,
                   children=[{k: v for k, v in kid.items() if k != 'since'} for kid in kids])
        if a.since:
            out['events'] = sorted((e for kid in kids for e in kid['since']),
                                   key=lambda e: int(e.get('seq') or 0))
        print(json.dumps(out, ensure_ascii=False))
        return 0
    print('children of %s%s' % (parent, ' · ' + a.session if a.session else ''))
    for k in kids:
        last = k['last'] or {}
        rep = last.get('state', '-')
        if last.get('pr'):
            rep += ' #' + last['pr']
        elif k['pr']:
            rep += ' (PR #%s %s)' % (k['pr'], k['pr_state'].lower()) if k['pr_state'] else ''
        if last.get('ts'):
            rep += ' ' + age(last['ts'])
        live = '%s %s' % (k['window'], k['state']) if k['live'] else 'gone'
        print('  %s %-16s %-18s %-22s %s' % (k['bucket'], k['child'], live, rep, k['title']))
    print(text)
    return 0


def main():
    ap = argparse.ArgumentParser(prog='fleet-children.py')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('append')
    p.add_argument('--file', required=True)
    p = sub.add_parser('show')
    p.add_argument('--dir', required=True)
    p.add_argument('--parent', required=True)
    p.add_argument('--session', default='')
    p.add_argument('--json', action='store_true')
    p.add_argument('--since', type=int, default=0)
    p.add_argument('--prmap', default='')
    p.add_argument('--prmap-dir', default='')
    a = ap.parse_args()
    return cmd_append(a) if a.cmd == 'append' else cmd_show(a)


if __name__ == '__main__':
    sys.exit(main())
