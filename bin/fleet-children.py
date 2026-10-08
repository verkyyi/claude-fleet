#!/usr/bin/env python3
"""fleet-children.py — the child-report LEDGER (issue #937): the write half and the
merge-with-live-state read half. Driven by bin/fleet-children-lib.sh
(`children_append`) and bin/fleet-children.sh (the query command); not meant to be
called by hand.

  append  --file <ledger.ndjson>            (event JSON on stdin)
  show    --dir <children-dir> --parent <key> [--json] [--since <seq>]
          [--prmap-dir <dir>] [--prmap <file>]   (live window rows on stdin)
  scan    --dir <children-dir>                   (keys with undelivered news)
  digest  --dir <children-dir> --parent <key> [--batch-secs N] [--parent-state S]
          [--force]              (`fleet-children.sh --json` of that parent on stdin)
  wake    --file <ledger.ndjson>            (wake JSON on stdin: child, level, action, outcome)
  wake-state --file <ledger.ndjson> --child <key>   → `<level> <epoch>` to resume from

The ledger is one NDJSON file per PARENT KEY (`issue-N` / `scratch-N` /
`<slug>:issue-N` — fleet_origin_canon's spelling, never a window id), so a parent
that is migrated or restored onto a new window id finds its children's record
unchanged. One line per event:

  {"seq": 3, "ts": "2026-09-22T10:00:00Z", "child": "issue-101", "state": "MERGED",
   "pr": "950", "verdict": "", "summary": "…", "title": "…"}

That shape, `children_append`, and `fleet-children.sh`'s text + `--json` output are
a stable interface (C4/C5/C6/R1 of EPIC #935 build on it): add fields, never rename.

The DIGEST (issue #939, FLEET_CHILD_REPORT=batch) reads the same file against a
cursor beside it — `<parent-key>.cursor`, the highest seq already delivered — and
decides whether this is the moment to wake the parent (see cmd_digest).

A second row TYPE shares the file (issue #1268): the stall ladder of
`fleet-await.sh` records every rung it climbs as

  {"seq": 4, "ts": "…", "type": "wake", "child": "issue-101", "level": 2,
   "action": "nudge", "outcome": "sent"}

level 1-2 nudge · 3 brief · 4 parent · 5 alert; level 0 / outcome "reset" = the
child made progress and the ladder starts over. A wake row is NOT a report:
read_events() skips it, so show/scan/digest/dedup never see one — it only shares
the seq counter (so "a report after this wake" is one comparison) and surfaces in
`show --json` as the top-level `wakes` list.

A placement the hub sent to ANOTHER machine (issue #1586) is written beside the
ledger, never in it — `<parent-key>.dispatch`, a file no `*.ndjson` reader globs:

  {"seq": 1, "ts": "…", "child": "issue-101", "node": "m4", "op": "<uuid>",
   "state": "done", "window": "@42", "exit": 0, "line": ""}

state done (a window opened there) · accepted (an --async spawn: the operation id
is the handle) · unknown (no final state in time) · refused (that machine's spawn
said no: exit + line). `show --json` carries the last row per child as the
top-level `dispatches` list, and the text view lists one under the children —
neither changes a count. One send may write several rows (issue #1610): each
machine that declined before the hub tried the next one is a refused row of its
own, the answer's row last. A child whose last row is accepted / unknown, older
than FLEET_STALE_CLAIM_SECS (600), with no window, no report and no session in a
fresh hub table carries `"claim": "stale"` (text: `stale-claim`) — a claim with
no session behind it, which the next send gets past without --force.
"""
import argparse
import datetime
import fcntl
import json
import os
import sys
import time

STATES = ('MERGED', 'BLOCKED', 'FAILED', 'STOPPED', 'REAPED', 'WAITING', 'IDLE', 'DEGENERATE')
FIELDS = ('child', 'state', 'pr', 'verdict', 'summary', 'title', 'tier')
# report_tier's three bands (issue #938, fleet-children-lib.sh); '' = a pre-#938 event.
TIERS = ('loud', 'quiet', 'silent')
KEY_OK = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-')
NODE_OK = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-')
RID_OK = KEY_OK | set('/#')

# The dash's state → rank table (tmux-dashboard-rows.sh state_v), verbatim: rank 0
# is the loud `!`, rank 1 counts as done. Kept identical so `fleet-children.sh`'s
# summary and the dash parent row's `3/5 ✓ · 1!` badge can never disagree.
RANK = {'needs': 0, 'failed': 0, 'sleeping': 1, 'preparing': 1, 'waking': 1,
        'done': 1, 'working': 2, 'looping': 3}
PANELS = ('dash', 'plan', 'backlog', 'home')
HOPS = 4                       # chain_v's bound — a grandchild past it is an orphan


def clean(s, lines=3, width=200):
    """Same scrub as the envelope (#574): no `<>"`, ≤3 lines of ≤200 chars."""
    s = ''.join(ch for ch in str(s or '') if ch not in '<>"')
    return '\n'.join(l[:width] for l in s.splitlines()[:lines])


def book_prefix(path):
    """`<slug>:` of the book's own key (`<slug>:scratch-5.ndjson`, `.dispatch`,
    `.ndjson.<gen>`), '' for a bare key — a one-repo fleet's every book."""
    bn = os.path.basename(path)
    return bn.split(':', 1)[0] + ':' if ':' in bn else ''


FID_OK = set('0123456789abcdef-')


def is_fid(f):
    """fleet_is_fid's shape (issue #1646): a lower-case 8-4-4-4-12 UUID."""
    f = str(f or '')
    return len(f) == 36 and set(f) <= FID_OK and [len(x) for x in f.split('-')] == [8, 4, 4, 4, 12]


def canon_child(child, pre, ev=None):
    """The ONE spelling of a child key (issue #1351): a ledger row written before
    the report carried its repo says bare `issue-N` where the live window and the
    placement say `<slug>:issue-N`, and the two were counted as two children. A
    bare key in a repo-qualified book takes its own `child_key` when that names the
    same key, else the book's prefix — the parent's repo, the repo the spawn ran
    in. A qualified key, a non-key, and every key in a bare book (a one-repo
    fleet) are returned as they are."""
    if not pre or ':' in child or not is_key(child):
        return child
    ck = str((ev or {}).get('child_key') or '')
    if ck.endswith(':' + child):
        return ck
    return pre + child


def read_rows(path, pre=None):
    """Every JSON object in the ledger, reports and wake rows alike — each `child`
    in its canonical spelling (canon_child); the file itself is never rewritten.
    <pre> overrides the book's own prefix: a bare ALIAS book read as a qualified
    key's (issue #1939) canonicalizes its children with that key's repo."""
    out = []
    if pre is None:
        pre = book_prefix(path)
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
                    ev['child'] = canon_child(str(ev['child']), pre, ev)
                    out.append(ev)
    except OSError:
        pass
    return out


def is_wake(e):
    return e.get('type') == 'wake'


def read_events(path, pre=None):
    """The child REPORTS — wake rows (issue #1268) are not events."""
    return [e for e in read_rows(path, pre) if not is_wake(e)]


def alias_of(key, one_slug):  # compat-1v: 下一批删
    """The bare key a qualified <key> was spelled as before issue #1939 — only
    while its repo is the fleet's ONE repo (<one_slug>, fleet_key_alias's rule);
    '' otherwise. Its book is the same parent's, read for one version."""
    if one_slug and key.startswith(one_slug + ':') and is_key(key):
        return key[len(one_slug) + 1:]
    return ''


def book_events(d, key, one_slug):
    """<key>'s reports, its bare alias's book merged in (issue #1939, #982)."""
    evs = read_events(os.path.join(d, key + '.ndjson'))
    al = alias_of(key, one_slug)
    if al:                              # its own seq counter: older than every row above
        for e in read_events(os.path.join(d, al + '.ndjson'), key.split(':', 1)[0] + ':'):
            e['_alias'] = 1
            evs.append(e)
    return evs


def ev_order(e):
    """Sort key: an alias book's rows (written before issue #1939) come first."""
    return (0 if e.get('_alias') else 1, int(e.get('seq') or 0))


def read_wakes(path):
    return [e for e in read_rows(path) if is_wake(e)]


def cmd_append(a):
    try:
        ev = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        print('fleet-children: event is not JSON', file=sys.stderr)
        return 2
    if not isinstance(ev, dict):
        return 2
    rc, out = append_row(a.file, ev)
    if out:
        print(out, file=sys.stderr if rc else sys.stdout)
    return rc


def append_row(path, raw):
    """One report into the book at <path> → (rc, 'seq=N' | 'dup seq=N' | why)."""
    ev = {k: raw.get(k, '') for k in FIELDS}
    ev['child'] = ''.join(ch for ch in str(ev['child']) if ch in KEY_OK)[:128]
    pre = book_prefix(path)
    ev['state'] = str(ev['state']).upper()
    ev['pr'] = ''.join(ch for ch in str(ev['pr']) if ch.isdigit())
    ev['verdict'] = clean(ev['verdict'], 1, 64)
    ev['summary'] = clean(ev['summary'])
    ev['title'] = clean(ev['title'], 1)
    ev['tier'] = str(ev['tier']).lower() if str(ev['tier']).lower() in TIERS else ''
    # relayed_from (issue #1352): a report forwarded to the nearest live ancestor
    # because its own parent was reaped — kept only when set, so every other row
    # is byte for byte what it was. fleet_origin_map skips it: not a parent link.
    rf = ''.join(ch for ch in str(raw.get('relayed_from') or '') if ch in KEY_OK)[:128]
    # node / rid (issue #1421): a report from a child on ANOTHER machine, pushed
    # here by the hub — node is that machine, rid the relay's id (`<child
    # worker_id>#<seq>`). Kept only when set: a local report (no node — "this
    # machine") is byte for byte what it was. A rid already in the file is a
    # redelivery, never a second row.
    node = ''.join(ch for ch in str(raw.get('node') or '') if ch in NODE_OK)[:64]
    rid = ''.join(ch for ch in str(raw.get('rid') or '') if ch in RID_OK)[:256]
    # gen / child_gen / child_key (issue #1538): the parent generation the report
    # was filed under, and the child's own — a recycled scratch number is told
    # from the one before it (fleet_origin_map). Kept only when set: a generation-0
    # row is byte for byte what it was.
    gens = {f: ''.join(ch for ch in str(raw.get(f) or '') if ch in (KEY_OK if f == 'child_key' else '0123456789.'))[:128]
            for f in ('gen', 'child_gen', 'child_key')}
    # lines / sample (issue #1557): a DEGENERATE row — how many screen rows were
    # one repeated unit, and the unit (`<br>` kept legible as `‹br›` — the scrub
    # drops `<>`). Kept only when set, like the fields above.
    # fid (issue #1351): the child's @fleet_id (#1646) — its identity, so a row is
    # joined to its window even after the key it reported under has moved. Kept
    # only when set.
    fid = str(raw.get('fid') or '').lower()
    fid = fid if is_fid(fid) else ''
    # pfid (issue #1955): the PARENT's @fleet_id (the child's @origin_fid) — which
    # session this book's generation was, so fleet-history.sh drafts can leave
    # out the ones the writing area opened. Kept only when set.
    pfid = str(raw.get('pfid') or '').lower()
    pfid = pfid if is_fid(pfid) else ''
    deg = {'lines': ''.join(ch for ch in str(raw.get('lines') or '') if ch.isdigit())[:8],
           'sample': clean(str(raw.get('sample') or '').replace('<', '‹').replace('>', '›'), 1, 64)}
    if not ev['child'] or ev['state'] not in STATES:
        return 2, 'fleet-children: need child + state (%s)' % '|'.join(STATES)
    ev['child'] = canon_child(ev['child'], pre, gens)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    # a+ and an exclusive flock: two children reporting in the same second get
    # distinct seqs, and the read-then-append below is one critical section.
    with open(path, 'a+', encoding='utf-8') as fh:
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
            if e.get('child') and canon_child(str(e['child']), pre, e) == ev['child'] \
                    and not is_wake(e):
                last = e
            if rid and e.get('rid') == rid:
                return 0, 'dup seq=%s' % e.get('seq')
        # Dedup against the child's LATEST event, not the whole file: a reaper
        # repeating the ship path's report is a no-op, while a real transition
        # back (WAITING → IDLE → WAITING) still lands and keeps "latest" true.
        if last and last.get('state') == ev['state'] and str(last.get('pr') or '') == ev['pr']:
            return 0, 'dup seq=%s' % last.get('seq')
        ev = dict(seq=seq + 1,
                  ts=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                  **ev)
        if rf:
            ev['relayed_from'] = rf
        if node:
            ev['node'] = node
        if rid:
            ev['rid'] = rid
        if fid:
            ev['fid'] = fid
        if pfid:
            ev['pfid'] = pfid
        ev.update((f, v) for f, v in gens.items() if v)
        ev.update((f, v) for f, v in deg.items() if v)
        fh.seek(0, os.SEEK_END)
        fh.write(json.dumps(ev, ensure_ascii=False) + '\n')
        fh.flush()
    return 0, 'seq=%d' % ev['seq']


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
    """Rows: window_id|state|needs|key|origin|fleet_id|window_name (the shell
    resolved the key). The fleet_id column (issue #1351) is optional: a row of six
    is the older shape, its last field the name."""
    wins = {}
    for line in stream:
        line = line.rstrip('\n')
        if not line:
            continue
        parts = line.split('|', 6)
        if len(parts) < 6:
            continue
        fid = ''
        if len(parts) == 7 and (parts[5] == '' or is_fid(parts[5])):
            fid = parts.pop(5)
        else:
            parts = parts[:5] + ['|'.join(parts[5:])]
        wid, state, needs, key, origin, name = parts
        if not key or key in wins:
            continue                    # a display grouping; ADDRESSING is fleet_win_for_key's (#1537)
        wins[key] = dict(wid=wid, state=state, needs=needs, origin=origin, name=name, fid=fid)
        # A child on another machine (issue #1421) rides as `<node>|remote|…`:
        # its window id is that machine's name, and it is never a local window.
        if state in ('remote', 'lost'):
            wins[key]['node'] = wid
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


# A turn-boundary / housekeeping report never un-lands a child (issue #1648): the
# Stop fallback files STOPPED seconds after the ship path's MERGED, and the book's
# latest row then read «ended unlanded» for a PR GitHub calls merged.
QUIET_AFTER = ('STOPPED', 'IDLE', 'WAITING', 'REAPED', 'DEGENERATE')


def settled(evs, prs=''):
    """The event that says where the child stands: the latest, unless a MERGED
    came before it and only QUIET_AFTER rows since — then that MERGED. A child
    whose latest row is QUIET_AFTER and whose PR the dash's cache (GitHub, no gh
    call here) calls MERGED reads as a MERGED of that PR."""
    if not evs:
        return None
    last = evs[-1]
    for e in reversed(evs):
        if e.get('state') == 'MERGED':
            return e
        if e.get('state') not in QUIET_AFTER:
            break
    if last.get('state') in QUIET_AFTER and str(prs).upper() == 'MERGED':
        return dict(last, state='MERGED')
    return last


def progress_of(live, st, disp):
    """One word for how far the child has come (issue #1648) — accepted → running
    → pr → merged / reaped, or failed / blocked / refused: the report when it
    says, else the live window, else the placement's last state."""
    lst = (st or {}).get('state', '')
    if lst == 'MERGED':
        return 'merged'
    if lst in ('BLOCKED', 'FAILED'):
        return lst.lower()
    if lst == 'REAPED':
        return 'merged' if (st.get('verdict') or '').startswith('merged') else 'reaped'
    if lst == 'WAITING' and (st.get('pr') or st.get('verdict') == 'pr-open'):
        return 'pr'
    if live is not None:
        return 'running'
    if disp and not st:
        return {'done': 'running', 'running': 'starting'}.get(disp.get('state'), disp.get('state') or '')
    return lst.lower() or 'gone'


HUB_BUSY = ('working', 'looping', 'waking', 'bg')


def hub_states(path):
    """The hub's session table (global/remote_<sess>, fleet-hub-sessions.sh) as
    {(issue, repo): [(state, node), …]} — issue #1607. A row's word is the node's
    `busy` column when it has one (a /loop round, a Bash-tool job: what only that
    machine sees), else `lost` on a machine the hub lost, else its state. Empty
    when there is no cache, or the hub has been silent past
    FLEET_HUB_RETAIN_SECS (600): an old answer is no answer."""
    out = {}
    lines = hub_lines(path)
    if lines is None:
        return out
    for ln in lines:
        p = ln.split('\x1f')
        if not p[0].startswith('wid:') or len(p) < 6 or not p[3]:
            continue
        st = p[5] or 'idle'
        if len(p) > 13 and p[13] in ('looping', 'bg'):
            st = p[13]
        elif st not in HUB_BUSY and p[2] == 'lost':
            st = 'lost'
        out.setdefault((p[3], p[4]), []).append((st, p[1]))
    return out


def hub_lines(path):
    """The hub cache's lines while it is a fresh answer (hub_states' rule), else
    None — so "the hub shows no session" is told from "the hub said nothing"."""
    if not path:
        return None
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    ts = 0
    try:
        with open(os.path.join(os.path.dirname(path), 'hub_ok'), encoding='utf-8') as f:
            ts = int(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        for ln in lines:
            p = ln.split('\x1f')
            if p[0] == '#ts' and len(p) > 1 and p[1].isdigit():
                ts = int(p[1])
    try:
        ttl = int(os.environ.get('FLEET_HUB_RETAIN_SECS') or 600)
    except ValueError:
        ttl = 600
    if time.time() - ts > ttl:
        return None
    return lines


def stale_claim(live, last, disp, hub_said, hs, now=None):
    """A claim with no session behind it (issue #1610): a placement that was
    sent (accepted) or never heard back from (unknown) longer than
    FLEET_STALE_CLAIM_SECS (600) ago, with no window here, no report, and a
    fresh hub table showing no session for it anywhere. The GitHub claim such
    a send keeps (a late open stays held off) is then nobody's — the next send
    must not need --force to get past it. A hub that said nothing proves
    nothing: never stale then."""
    if live is not None or last or not disp or not hub_said or hs:
        return False
    if disp.get('state') not in ('accepted', 'unknown'):
        return False
    try:
        secs = int(os.environ.get('FLEET_STALE_CLAIM_SECS') or 600)
    except ValueError:
        secs = 600
    try:
        t = datetime.datetime.strptime(disp.get('ts') or '', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return False
    return (now or time.time()) - t.timestamp() >= secs


def slugify(repo):
    """fleet_slug: owner/name → owner-name, anything else outside [alnum._-] dropped."""
    return ''.join(ch for ch in repo.replace('/', '-') if ch.isalnum() or ch in '._-')


def hub_state_of(child, hub):
    """`(state, node)` the hub shows for <child> (`issue-N` / `<slug>:issue-N`),
    matched by (repo, issue) like the epic backstop; a busy row beats a lost one
    beats an idle twin. None when the hub has no row."""
    slug, _, bare = child.rpartition(':')
    if not bare.startswith('issue-') or not hub:
        return None
    n = bare[len('issue-'):]
    rows = [r for (i, repo), rs in hub.items() if i == n and (not slug or slugify(repo) == slug or repo.split('/')[-1] == slug)
            for r in rs]
    for want in (HUB_BUSY, ('lost',)):
        for r in rows:
            if r[0] in want:
                return r
    return rows[0] if rows else None


def bucket(live, last, disp=None):
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
        # Quiet is not finished (issue #1331): a sleeper, a preparing/waking worker
        # and a `looping` one sort quiet on the dash, but only `done` is a ✓.
        return '✓' if live['state'] == 'done' else '▸'
    if lst == 'MERGED' or (lst == 'REAPED' and (last.get('verdict') or '').startswith('merged')):
        return '✓'
    if lst in ('BLOCKED', 'FAILED'):
        return '!'
    if lst == 'WAITING':
        return '⏳'
    # A placement with no report yet (issue #1648): on its way or opened there is
    # working; refused / failed / never heard of is for a human.
    if not last and disp:
        return '▸' if disp.get('state') in ('accepted', 'running', 'done') else '!'
    return '–'


def age(ts):
    try:
        t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except (TypeError, ValueError):
        return ''
    s = max(0, int(time.time() - t.timestamp()))
    return '%ds' % s if s < 60 else '%dm' % (s // 60) if s < 3600 else \
        '%dh' % (s // 3600) if s < 86400 else '%dd' % (s // 86400)


STALE_SECS = 86400             # undelivered news older than this is history, not news
GLYPHS = '!⏳▸✓–'
IDLE_STATES = ('done', 'idle')


def seq_of(e):
    try:
        return int(e.get('seq') or 0)
    except (TypeError, ValueError):
        return 0


def ts_of(e):
    try:
        return datetime.datetime.strptime(e.get('ts') or '', '%Y-%m-%dT%H:%M:%SZ') \
            .replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return 0.0


def read_cursor(d, key):
    try:
        with open(os.path.join(d, key + '.cursor'), encoding='utf-8') as fh:
            return int(fh.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def news_of(d, key):
    """(pending, news): events after the cursor, and the ones a digest delivers —
    everything but tier silent (a turn boundary rides along, never wakes)."""
    cur = read_cursor(d, key)
    pend = sorted((e for e in read_events(os.path.join(d, key + '.ndjson')) if seq_of(e) > cur),
                  key=seq_of)
    return pend, [e for e in pend if e.get('tier') != 'silent']


def cmd_scan(a):
    """Parent keys whose ledger holds deliverable news younger than STALE_SECS — the
    tick's cheap pre-filter, so a parent with nothing to say costs no tmux read."""
    now = time.time()
    try:
        names = sorted(os.listdir(a.dir))
    except OSError:
        return 0
    for n in names:
        if not n.endswith('.ndjson'):
            continue
        key = n[:-len('.ndjson')]
        _, news = news_of(a.dir, key)
        if news and now - min(ts_of(e) for e in news) <= STALE_SECS:
            print(key)
    return 0


def label_of(key):
    pre, bare = (key.split(':', 1) if ':' in key else ('', key))
    if bare.startswith('issue-'):
        lab = 'issue #' + bare[len('issue-'):]
    elif bare.startswith('scratch-'):
        lab = 'scratch ~' + bare[len('scratch-'):]
    else:
        lab = bare
    return (pre + ' ' + lab) if pre else lab


def cmd_digest(a):
    """Decide + render one [children-digest] for <parent>. Prints ONE JSON object
    {flush, seq, pending, text}: flush is the reason to send now ('' = hold), seq is
    what the cursor advances to once it is delivered, text the envelope minus its
    `no reply needed` line (the shell adds that, with the language notice).

    Flush when there is deliverable news AND one of (issue #939):
      force    the caller insists (a loud report handing over)
      loud     a loud event is pending — someone must act, and it carries the
               quiet news queued ahead of it
      barrier  every child under the parent is in a terminal bucket (✓ ! –):
               the batch is over, wake it once
      age      the oldest undelivered news has waited FLEET_CHILD_REPORT_BATCH_SECS
      idle     the parent itself is idle (done) — nothing to interrupt
    News older than a day is history: never flushed (and so a reaped parent's
    file, or a pre-batch ledger, never turns into a surprise digest)."""
    try:
        show = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        show = {}
    if not isinstance(show, dict):
        show = {}
    pend, news = news_of(a.dir, a.parent)
    out = dict(flush='', seq=max([seq_of(e) for e in pend] or [read_cursor(a.dir, a.parent)]),
               pending=len(news), text='')
    now = time.time()
    if not news or now - min(ts_of(e) for e in news) > STALE_SECS:
        print(json.dumps(out))
        return 0
    kids = {k.get('child'): k for k in show.get('children') or [] if isinstance(k, dict)}
    buckets = [k.get('bucket') for k in kids.values()]
    if a.force:
        out['flush'] = 'force'
    # '' = a pre-#938 event with no band: fail toward delivery, as report_tier does.
    elif any(e.get('tier') in ('loud', '') for e in news):
        out['flush'] = 'loud'
    elif buckets and all(b in ('✓', '!', '–') for b in buckets):
        out['flush'] = 'barrier'
    elif now - min(ts_of(e) for e in news) >= a.batch_secs:
        out['flush'] = 'age'
    elif a.parent_state in IDLE_STATES:
        out['flush'] = 'idle'

    sm = show.get('summary') or {}
    total = int(sm.get('total') or len(kids))
    head = '[children-digest] %d/%d ✓' % (int(sm.get('done') or 0), total)
    if sm.get('waiting'):
        head += ' · %d ⏳' % int(sm['waiting'])
    if sm.get('needs'):
        head += ' · %d !' % int(sm['needs'])
    # One line per child that CHANGED since the cursor, its latest event only.
    latest = {}
    for e in pend:
        latest[e['child']] = e
    rows = []
    for child, e in latest.items():
        g = (kids.get(child) or {}).get('bucket') or bucket(None, e)
        st = e.get('state', '')
        if e.get('pr'):
            st += ' (PR #%s)' % e['pr']
        elif e.get('verdict'):
            st += ' (%s)' % e['verdict']
        title = clean(e.get('title') or (kids.get(child) or {}).get('title', ''), 1, 60)
        line = '  %s %s%s %s' % (g, label_of(child), ' "%s"' % title if title else '', st)
        sm1 = clean(e.get('summary'), 1, 120)
        if sm1:
            line += ' — ' + sm1
        rows.append((GLYPHS.index(g) if g in GLYPHS else len(GLYPHS), seq_of(e), line))
    rows.sort()
    lines = [r[2] for r in rows[:6]]
    if len(rows) > 6:
        lines.append('  … %d more — fleet-children.sh' % (len(rows) - 6))
    out['text'] = '\n'.join([head] + lines)
    print(json.dumps(out, ensure_ascii=False))
    return 0


def locked_append(path, row):
    """Stamp seq + ts under the ledger's flock and append — the same critical
    section cmd_append uses, so a wake row and a report never share a seq. A row
    carrying a `rid` already in the file is not appended: None (issue #1648)."""
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'a+', encoding='utf-8') as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.seek(0)
        seq = 0
        for line in fh:
            try:
                e = json.loads(line)
                seq = max(seq, int(e.get('seq') or 0))
            except (ValueError, TypeError, AttributeError):
                continue
            if row.get('rid') and e.get('rid') == row['rid']:
                return None
        row = dict(seq=seq + 1,
                   ts=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                   **row)
        fh.seek(0, os.SEEK_END)
        fh.write(json.dumps(row, ensure_ascii=False) + '\n')
        fh.flush()
    return row['seq']


def cmd_wake(a):
    """Append one stall-ladder row (issue #1268)."""
    try:
        w = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        return 2
    if not isinstance(w, dict):
        return 2
    child = ''.join(ch for ch in str(w.get('child') or '') if ch in KEY_OK)[:128]
    child = canon_child(child, book_prefix(a.file))
    try:
        level = int(w.get('level'))
    except (TypeError, ValueError):
        level = -1
    if not child or not 0 <= level <= 5:
        print('fleet-children: wake needs child + level 0-5', file=sys.stderr)
        return 2
    print('seq=%d' % locked_append(a.file, dict(
        type='wake', child=child, level=level,
        action=clean(w.get('action'), 1, 16), outcome=clean(w.get('outcome'), 1, 120))))
    return 0


def cmd_wake_state(a):
    """`<level> <epoch>`: the rung <child>'s ladder stands on and when it was
    climbed — so a restarted wait goes on from there. 0 when there is no wake
    row, the last one is a reset, or the child REPORTED after it (progress the
    previous waiter never saw)."""
    child = canon_child(a.child, book_prefix(a.file))
    rows = [e for e in read_rows(a.file) if e.get('child') == child]
    wakes = [e for e in rows if is_wake(e)]
    if not wakes:
        print('0 0')
        return 0
    w = max(wakes, key=seq_of)
    try:
        level = int(w.get('level') or 0)
    except (TypeError, ValueError):
        level = 0
    if any(not is_wake(e) and seq_of(e) > seq_of(w) for e in rows):
        level = 0
    print('%d %d' % (level, int(ts_of(w)) if level else 0))
    return 0


# A placement's states (issues #1586, #1648): what the spawn heard, then what the
# hub's progress stream says the operation became. OPEN ones are still in flight.
DISPATCH_STATES = ('accepted', 'running', 'done', 'refused', 'failed', 'unknown')
DISPATCH_OPEN = ('accepted', 'running', 'unknown')


def dispatch_row(path, child, state, node='', op='', window='', line='', exit='', rid=''):
    """One placement row into <path> → its seq, None for a rid already there, or
    -1 when the row is not one."""
    child = canon_child(''.join(ch for ch in str(child) if ch in KEY_OK)[:128], book_prefix(path))
    if not child or state not in DISPATCH_STATES:
        return -1
    row = dict(child=child, node=clean(node, 1, 64), op=clean(op, 1, 64), state=state,
               window=clean(window, 1, 32), line=clean(line, 1, 200))
    if str(exit) != '':
        try:
            row['exit'] = int(exit)
        except ValueError:
            pass
    rid = ''.join(ch for ch in str(rid or '') if ch in RID_OK)[:256]
    if rid:                             # only then: a spawn's own row is unchanged
        row['rid'] = rid
    return locked_append(path, row)


def cmd_dispatch(a):
    """Append one cross-machine placement row (issue #1586)."""
    seq = dispatch_row(a.file, a.child, a.state, a.node, a.op, a.window, a.line, a.exit, a.rid)
    if seq == -1:
        print('fleet-children: dispatch needs child + state %s' % '|'.join(DISPATCH_STATES), file=sys.stderr)
        return 2
    print('dup' if seq is None else 'seq=%d' % seq)
    return 0


def cmd_open_ops(a):
    """The operation ids of the placements still open (DISPATCH_OPEN) in the
    `.dispatch` books named one per line on stdin — each child's LAST row, ≤50,
    comma-joined: what a progress pull asks the hub about (issue #1648)."""
    ops = set()
    for path in sys.stdin.read().split('\n'):
        if path:
            ops.update(e.get('op') for e in last_per_child(path) if e.get('state') in DISPATCH_OPEN)
    print(','.join(sorted(o for o in ops if o and set(o) <= FID_OK)[:50]))
    return 0


def cmd_merge(a):
    """Merge a hub progress answer (stdin, GET /v1/node/progress) into the book
    of ONE parent (issue #1648): its reports into <file>, its placements into
    <file>'s `.dispatch` — both deduped on the event's rid, so an event the relay
    push already brought, or a pull that is run twice, adds nothing. Prints how
    many rows were new. `--parents` instead lists the parents the answer names."""
    try:
        d = json.load(sys.stdin)
    except ValueError:
        return 2
    evs = [e for e in (d.get('events') or []) if isinstance(e, dict)]
    if a.parents:
        seen = []
        for e in evs:
            p = str(e.get('parent') or '')
            if p and p not in seen:
                seen.append(p)
        print('\n'.join(seen))
        return 0
    if not a.file or not a.parent:
        return 2
    dfile = a.file[:-len('.ndjson')] + '.dispatch' if a.file.endswith('.ndjson') else a.file + '.dispatch'
    new = 0
    for e in evs:
        if e.get('parent') != a.parent or not isinstance(e.get('event'), dict):
            continue
        ev, rid = e['event'], str(e.get('rid') or '')
        if e.get('kind') == 'report':
            row = dict(ev, rid=rid, node=ev.get('node') or '?')
            rc, out = append_row(a.file, row)
            new += rc == 0 and out.startswith('seq=')
        elif e.get('kind') == 'dispatch':
            iss = ''.join(ch for ch in str(ev.get('issue') or '') if ch.isdigit())
            if not iss:
                continue                # a scratch start names no child key here
            child = 'issue-' + iss
            if ev.get('repo'):           # every fleet's key carries its repo (issue #1939)
                child = ''.join(ch for ch in str(ev['repo']).replace('/', '-') if ch in NODE_OK) + ':' + child
            seq = dispatch_row(dfile, child, str(ev.get('state') or ''), ev.get('node', ''), ev.get('op', ''),
                               ev.get('window', ''), ev.get('line', ''), ev.get('exit', ''), rid)
            new += isinstance(seq, int) and seq > 0
    print(new)
    return 0


def last_per_child(path, pre=None, rows=None):
    """The last row per child of one book, in seq order."""
    last = {}
    for e in (rows if rows is not None else read_rows(path, pre)):
        if e.get('child'):
            last[e['child']] = e
    return sorted(last.values(), key=seq_of)


def read_dispatches(d, parent, one_slug=''):
    """The last placement row per child (issue #1586), in seq order — the bare
    alias's book first, so the qualified book's later rows win (issue #1939)."""
    rows = []
    al = alias_of(parent, one_slug)
    if al:
        rows = read_rows(os.path.join(d, al + '.dispatch'), parent.split(':', 1)[0] + ':')
    rows += read_rows(os.path.join(d, parent + '.dispatch'))
    return last_per_child('', rows=rows)


def cmd_show(a):
    wins = read_windows(sys.stdin)
    parent = a.parent
    if a.one_slug:                      # a bare @origin is the one repo's (issue #1939)
        for w in wins.values():
            if is_key(w['origin']) and ':' not in w['origin']:
                w['origin'] = a.one_slug + ':' + w['origin']
    # A child on another machine as ITS machine spells it — bare from one that
    # predates issue #1939 — is the same child its reports are booked as in this
    # qualified book (canon_child): one key, one row.
    ppre = book_prefix(parent + '.ndjson')
    for k in [k for k, w in wins.items() if w.get('node') and ppre and ':' not in k and is_key(k)]:
        if ppre + k not in wins:
            wins[ppre + k] = wins.pop(k)
    # ledger side: the parent's own file, plus each descendant's (≤4 levels), so a
    # grandchild whose window is gone is still counted under the root — the same
    # "ultimate parent" attribution the live side gets from descends().
    # Identity first (issue #1351): a row carrying a live window's @fleet_id is
    # that window's, whatever key it was filed under — a scratch since bound to an
    # issue answers to its new key, and its earlier reports join it there.
    byfid = {w['fid']: k for k, w in wins.items() if w.get('fid')}
    events, seen, frontier = {}, set(), [parent]
    for _ in range(HOPS):
        nxt = []
        for p in frontier:
            if p in seen:
                continue
            seen.add(p)
            for ev in book_events(a.dir, p, a.one_slug):
                ev['child'] = byfid.get(ev.get('fid') or '', ev['child'])
                events.setdefault(ev['child'], []).append(ev)
                nxt.append(ev['child'])
        frontier = nxt
    for k, w in wins.items():
        if k != parent and descends(w['origin'], parent, wins):
            events.setdefault(k, [])
    events.pop(parent, None)

    # A placement on another machine (issue #1586) is the same child's third
    # source: it rides that child's row (`dispatch`) — and one naming a child with
    # no report or window yet IS that child's row (issue #1648), counted like any
    # other, its state the placement's until the first report says more.
    hub = hub_states(a.hub_cache)
    hub_said = hub_lines(a.hub_cache) is not None
    dispatches = read_dispatches(a.dir, parent, a.one_slug)
    dmap = {d['child']: d for d in dispatches}
    for d in dispatches:
        if d['child'] != parent:
            events.setdefault(d['child'], [])

    kids = []
    for child, evs in events.items():
        evs.sort(key=ev_order)
        last = evs[-1] if evs else None
        live = wins.get(child)
        # A LIVE window that no longer descends from this parent (re-parented, or a
        # reused key) belongs to someone else's row now: the ledger alone speaks.
        if live is not None and not descends(live['origin'], parent, wins):
            live = None
        prn, prs = prmap_lookup(child, a)
        st = settled(evs, prs)
        disp = dmap.get(child)
        # The machine a child runs on (issue #1421): a live remote row's, else the
        # one its last report came from, else the one it was placed on. '' = here.
        node = (live or {}).get('node') or (last or {}).get('node', '') or (disp or {}).get('node', '')
        kids.append(dict(
            child=child, bucket=bucket(live, st, disp),
            live=live is not None, window=live['wid'] if live else '',
            state=(live['state'] or 'idle') if live else 'gone',
            needs=live['needs'] if live else '',
            title=(live['name'] if live else '') or (last or {}).get('title', ''),
            pr=(last or {}).get('pr') or prn, pr_state=prs,
            last=last,
            since=[e for e in evs if int(e.get('seq') or 0) > a.since and not e.get('_alias')]))
        if node:                        # only then: a one-machine answer is unchanged
            kids[-1]['node'] = node
            # …and what it is doing there now (issue #1607), off the hub's table
            hs = hub_state_of(child, hub)
            if hs:
                kids[-1]['remote_state'], kids[-1]['remote_node'] = hs
        if disp:
            kids[-1]['dispatch'] = disp
        kids[-1]['progress'] = progress_of(live, st, disp)
        if stale_claim(live, last, disp, hub_said, hub_state_of(child, hub)):
            # an added field, only then: every other row is unchanged (issue #1610)
            kids[-1]['claim'] = 'stale'

        if st is not last:              # a MERGED a later quiet row would have hidden
            kids[-1]['settled'] = st
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
    seqmax = max([int(e.get('seq') or 0) for evs in events.values() for e in evs if not e.get('_alias')] or [0])
    if a.since:
        kids = [k for k in kids if k['since']]

    if a.json:
        out = dict(parent=parent, session=a.session, seq=seqmax, summary=summary,
                   children=[{k: v for k, v in kid.items() if k != 'since'} for kid in kids],
                   wakes=sorted((w for w in read_wakes(os.path.join(a.dir, parent + '.ndjson'))
                                 if w.get('child') in events and seq_of(w) > a.since),
                                key=seq_of))
        if dispatches:                  # only then: an answer without one is unchanged
            out['dispatches'] = dispatches
        if a.since:
            out['events'] = sorted((e for kid in kids for e in kid['since']),
                                   key=lambda e: int(e.get('seq') or 0))
        print(json.dumps(out, ensure_ascii=False))
        return 0
    print('children of %s%s' % (parent, ' · ' + a.session if a.session else ''))
    for k in kids:
        last = k.get('settled') or k['last'] or {}
        d = k.get('dispatch')
        rep = last.get('state', '-')
        if last.get('pr'):
            rep += ' #' + last['pr']
        elif k['pr']:
            rep += ' (PR #%s %s)' % (k['pr'], k['pr_state'].lower()) if k['pr_state'] else ''
        if last.get('ts'):
            rep += ' ' + age(last['ts'])
        elif d:                         # placed, nothing reported yet (issue #1648)
            rep = d.get('state', '')
            if d.get('window'):
                rep += ' ' + d['window']
            if d.get('state') in ('refused', 'failed'):
                rep += ' exit %s %s' % (d.get('exit', '?'), d.get('line', ''))
            if k.get('claim') == 'stale':
                rep = 'stale-claim (%s, no session anywhere)' % rep
            if d.get('ts'):
                rep += ' ' + age(d['ts'])
        live = '%s %s' % (k['window'], k['state']) if k['live'] else 'gone'
        if k.get('remote_state'):       # the machine's own word, not `remote` / `gone · m4` (#1607)
            live = '%s %s' % (k['remote_node'], k['remote_state'])
        elif k.get('node') and not k['live']:
            live += (' ↗' if d else ' · ') + k['node']
        print('  %s %-16s %-18s %-22s %s' % (k['bucket'], k['child'], live, rep.strip(), k['title']))
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
    p.add_argument('--hub-cache', default='')
    p.add_argument('--one-slug', default='')   # the fleet's ONE repo's slug: bare books alias it
    p = sub.add_parser('scan')
    p.add_argument('--dir', required=True)
    p = sub.add_parser('digest')
    p.add_argument('--dir', required=True)
    p.add_argument('--parent', required=True)
    p.add_argument('--batch-secs', type=int, default=300)
    p.add_argument('--parent-state', default='')
    p.add_argument('--force', action='store_true')
    p = sub.add_parser('wake')
    p.add_argument('--file', required=True)
    p = sub.add_parser('dispatch')
    p.add_argument('--file', required=True)
    p.add_argument('--child', required=True)
    p.add_argument('--state', required=True)
    p.add_argument('--node', default='')
    p.add_argument('--op', default='')
    p.add_argument('--window', default='')
    p.add_argument('--exit', default='')
    p.add_argument('--line', default='')
    p.add_argument('--rid', default='')
    p = sub.add_parser('merge')
    p.add_argument('--file', default='')
    p.add_argument('--parent', default='')
    p.add_argument('--multi', default='')   # ignored since issue #1939: every key carries its repo
    p.add_argument('--parents', action='store_true')
    sub.add_parser('open-ops')
    p = sub.add_parser('wake-state')
    p.add_argument('--file', required=True)
    p.add_argument('--child', required=True)
    a = ap.parse_args()
    return dict(append=cmd_append, show=cmd_show, scan=cmd_scan, digest=cmd_digest,
                wake=cmd_wake, dispatch=cmd_dispatch, merge=cmd_merge,
                **{'wake-state': cmd_wake_state, 'open-ops': cmd_open_ops})[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
