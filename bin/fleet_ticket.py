#!/usr/bin/env python3
"""fleet_ticket.py — the ticket door's python half (issue #3595, EPIC #3570 C2).

The same verbs as bin/fleet-ticket.sh, for python callers (the steward, parking,
the decision sheet) — and the ONE place the hub backend lives: every verb on a
`hub:<owner/name>#<N>` ticket (or a repo whose FLEET_TICKETS=hub) is a REST call
to the hub's /v1/fleet/tickets (C1, tokenledger/internal/api/fleet_tickets.go).
A `gh:` ticket is handed to the shell door unchanged, so GitHub stays behind
fleet-ticket.sh and its one write throttle.

    fleet_ticket.py home <repo>                         → hub | github
    fleet_ticket.py id <repo> <N>                       → hub:<repo>#<N> | gh:<repo>#<N>
    fleet_ticket.py parse <id>                          → <repo>\\t<N>
    fleet_ticket.py read <id> [--json f,g]              → gh-shaped JSON (+ _source)
    fleet_ticket.py comment <id> [fleet-comment.sh opts] → the marker + footer road
    fleet_ticket.py post <id> (--body T | --body-file F) → a raw comment, its URL
    fleet_ticket.py edit <id> (--body T | --body-file F|-)
    fleet_ticket.py state <id> open|closed [--reason completed|not_planned]
    fleet_ticket.py close <id>                          → closed, nothing printed
    fleet_ticket.py children <id>                       → <id>\\t<state> per child
    fleet_ticket.py list --repo R [--label L] [--state open|closed|all] [--since D] [--limit N]
    fleet_ticket.py new --repo R --title T [--body B | --body-file F] [--label L]…
                        [--priority pN] [--parent N] [--origin K] [--filed]
    fleet_ticket.py claim <id> [--by WHO] [--release]   → claimed\\t<who> | released
    fleet_ticket.py label add|rm <id> <label>…          → the labels, comma-joined
    fleet_ticket.py priority <id> p0|p1|p2|p3|none
    fleet_ticket.py link <parent-id> <child-id> [--remove]
    fleet_ticket.py find --repo R --marker S            → <id>\\t<url> of an open ticket carrying S
    fleet_ticket.py cache --repo R --dir D              → the collector's issues / labels / parents

Exit: 0 ok · 1 the backend failed · 2 usage · 3 claim conflict · 4 the hub is not
reachable (no answer, or no node token).

The node token is read the way every hub caller reads it (`_fleet_hub_env`, issue
#1491): the shell door runs us inside the subshell that loaded it; run bare, we
ask that same function over a pipe — never an argv, a file or our own env export.
`--backend hub` is the shell door's handoff ("the home is decided, do not ask
back"), so a hub verb never loops through the shell again.

Module use: `import fleet_ticket; fleet_ticket.run(["read", "hub:o/n#3", "--json", "title"])`
returns (rc, stdout); `fleet_ticket.call(...)` returns the parsed JSON of a hub verb.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

BIN = os.path.dirname(os.path.abspath(__file__))
ID_RE = re.compile(r'^(hub|gh):([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$')
REPO_RE = re.compile(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')
TIMEOUT = float(os.environ.get('FLEET_HUB_TIMEOUT') or 10)


class Fail(Exception):
    def __init__(self, rc, msg):
        super().__init__(msg)
        self.rc, self.msg = rc, msg


def norm_repo(r):
    r = (r or '').strip()
    r = re.sub(r'^(https?://github\.com/|git@github\.com:)', '', r)
    r = re.sub(r'\.git$', '', r).strip('/')
    return r.lower() if REPO_RE.match(r) else ''


def parse(tid):
    m = ID_RE.match(tid or '')
    if not m:
        raise Fail(2, f'{tid or "(empty)"} is not a ticket id — write hub:<owner/name>#<N> or gh:<owner/name>#<N>')
    return m.group(1), m.group(2), int(m.group(3))


def shell(args, capture=False, stdin=None):
    """The shell door (fleet-ticket.sh) — GitHub's side, and the home reader."""
    p = subprocess.run(['bash', os.path.join(BIN, 'fleet-ticket.sh')] + list(args),
                       stdout=subprocess.PIPE if capture else None, input=stdin,
                       text=True)
    return p.returncode, (p.stdout or '') if capture else ''


def home(repo):
    if os.environ.get('_FLEET_TICKET_HOME'):
        return os.environ['_FLEET_TICKET_HOME']
    rc, out = shell(['home', repo], capture=True)
    return 'hub' if out.strip() == 'hub' else 'github'


def ticket_id(backend, repo, n):
    return f'{"hub" if backend == "hub" else "gh"}:{repo}#{n}'


# ---- the hub's REST --------------------------------------------------------

_CREDS = None


def creds():
    global _CREDS
    if _CREDS:
        return _CREDS
    url, tok = os.environ.get('CCQUOTA_HUB_URL', ''), os.environ.get('CCQUOTA_TOKEN', '')
    if not (url and tok):
        p = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh" >/dev/null 2>&1; _fleet_hub_env; '
                            'printf "%s\\t%s" "${CCQUOTA_HUB_URL:-}" "${CCQUOTA_TOKEN:-}"', '_', BIN],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        u, _, t = (p.stdout or '').partition('\t')
        url, tok = url or u, tok or t
    if not url or not tok:
        raise Fail(4, '入口不通 — no node token here (node.env / CCQUOTA_TOKEN); '
                      'fix: `fleet-hub-node.sh env --write`')
    _CREDS = (url.rstrip('/'), tok)
    return _CREDS


def api(method, path, body=None, query=None):
    url, tok = creds()
    full = url + '/v1/fleet/tickets' + path
    if query:
        full += '?' + urllib.parse.urlencode({k: v for k, v in query.items() if v not in (None, '')})
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(full, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + tok)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read() or b''
        try:
            doc = json.loads(raw)
        except ValueError:
            doc = {}
        why = doc.get('error') or raw.decode('utf-8', 'replace').strip()[:200]
        if e.code == 409 and path.endswith('/claim'):
            f = Fail(3, f'claimed by {doc.get("assignee") or "someone"} — {why}')
            f.holder = doc.get('assignee') or ''
            raise f
        raise Fail(2 if e.code == 400 else 1, f'the hub refused: HTTP {e.code} — {why}')
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Fail(4, f'入口不通 — {url}: {getattr(e, "reason", e)}')
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        raise Fail(1, 'the hub answered something that is not JSON')


def tpath(repo, n, sub=''):
    return f'/{repo}/{n}' + (f'/{sub}' if sub else '')


def turl(repo, n):
    return f'{creds()[0]}/v1/fleet/tickets/{repo}/{n}'


def gh_shape(t, comments):
    """A hub ticket in gh issue view's field names, so a reader needs no branch."""
    labels = list(t.get('labels') or [])
    if t.get('priority'):
        labels.append('priority:' + t['priority'])
    return {
        'number': t.get('number'), 'title': t.get('title', ''), 'body': t.get('body', ''),
        'state': (t.get('state') or 'open').upper(), 'stateReason': (t.get('state_reason') or '').upper(),
        'labels': [{'name': x} for x in labels],
        'assignees': [{'login': t['assignee']}] if t.get('assignee') else [],
        'author': {'login': t.get('owner', '')},
        'comments': [{'author': {'login': c.get('author', '')}, 'body': c.get('body', ''),
                      'createdAt': c.get('created_at', ''), 'id': c.get('id')} for c in comments or []],
        'url': turl(t.get('repo', ''), t.get('number')), 'createdAt': t.get('created_at', ''),
        'updatedAt': t.get('updated_at', ''), 'closedAt': None, 'milestone': None,
        'id': t.get('id', ''), 'parent': t.get('parent', ''), 'priority': t.get('priority', ''),
        '_source': 'hub',
    }


# ---- argument helpers ------------------------------------------------------

def opts(args, flags, multi=(), bools=()):
    """--k v / --k=v options; returns (dict, positional)."""
    out = {k: [] for k in multi}
    pos = []
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith('--'):
            k, eq, v = a[2:].partition('=')
            if k in bools:
                out[k] = True
                i += 1
                continue
            if k not in flags and k not in multi:
                raise Fail(2, f'unknown argument {a}')
            if not eq:
                if i + 1 >= len(args):
                    raise Fail(2, f'{a} needs a value')
                v = args[i + 1]
                i += 1
            if k in multi:
                out[k].append(v)
            else:
                out[k] = v
        else:
            pos.append(a)
        i += 1
    return out, pos


def body_of(o):
    if o.get('body-file'):
        f = o['body-file']
        if f == '-':
            return sys.stdin.read()
        try:
            with open(f, encoding='utf-8') as fh:
                return fh.read()
        except OSError:
            raise Fail(2, f'cannot read {f}')
    return o.get('body')


# ---- the hub verbs -----------------------------------------------------------

def hub_verb(verb, args):
    if verb == 'read':
        o, pos = opts(args, ('json', 'max-age'))
        _, repo, n = parse(pos[0] if pos else '')
        d = api('GET', tpath(repo, n))
        doc = gh_shape(d.get('ticket') or {}, d.get('comments'))
        if o.get('json'):
            keep = [f.strip() for f in o['json'].split(',') if f.strip()]
            doc = {k: doc.get(k) for k in keep + ['_source']}
        return json.dumps(doc, ensure_ascii=False)

    if verb == 'post':
        o, pos = opts(args, ('body', 'body-file'))
        _, repo, n = parse(pos[0] if pos else '')
        b = body_of(o)
        if not (b or '').strip():
            raise Fail(2, 'post: empty body')
        c = api('POST', tpath(repo, n, 'comments'), {'body': b, 'source': 'fleet'})
        return f'{turl(repo, n)}#comment-{c.get("id", "")}'

    if verb == 'edit':
        o, pos = opts(args, ('body', 'body-file'))
        _, repo, n = parse(pos[0] if pos else '')
        b = body_of(o)
        if b is None or b == '':
            raise Fail(2, 'edit: say --body or --body-file')
        api('PATCH', tpath(repo, n), {'body': b if o.get('body-file') else b + '\n'})
        return 'edited'

    if verb in ('state', 'close'):
        o, pos = opts(args, ('reason',))
        _, repo, n = parse(pos[0] if pos else '')
        want = 'closed' if verb == 'close' else (pos[1] if len(pos) > 1 else '')
        if want not in ('open', 'closed'):
            raise Fail(2, 'state: say open or closed')
        reason = o.get('reason', '')
        if reason not in ('', 'completed', 'not_planned'):
            raise Fail(2, 'state: --reason is completed or not_planned')
        p = {'state': want}
        if reason:
            p['state_reason'] = reason
        api('PATCH', tpath(repo, n), p)
        return '' if verb == 'close' else want

    if verb == 'children':
        _, repo, n = parse(args[0] if args else '')
        d = api('GET', tpath(repo, n, 'children'))
        rows = []
        for c in d.get('children') or d.get('tickets') or []:
            if isinstance(c, dict):
                rows.append(f'{ticket_id(c.get("backend", "hub"), c.get("repo", repo), c.get("number"))}\t{c.get("state", "open")}')
        return '\n'.join(rows)

    if verb == 'list':
        o, _ = opts(args, ('repo', 'label', 'state', 'since', 'limit'))
        repo = norm_repo(o.get('repo', ''))
        if not repo:
            raise Fail(2, 'list: --repo is required')
        st = o.get('state', 'open')
        if st not in ('open', 'closed', 'all'):
            raise Fail(2, 'list: --state is open, closed or all')
        since = o.get('since', '')
        if since and not re.match(r'^\d{4}-\d{2}-\d{2}$', since):
            raise Fail(2, 'list: --since is YYYY-MM-DD')
        d = api('GET', '', query={'repo': repo, 'label': o.get('label', ''),
                                  'state': '' if st == 'all' else st,
                                  'since': since + 'T00:00:00Z' if since else '',
                                  'limit': o.get('limit', '100')})
        return '\n'.join(f'{ticket_id(t.get("backend", "hub"), t.get("repo", repo), t.get("number"))}\t{t.get("state", "open")}'
                         for t in d.get('tickets') or [])

    if verb == 'new':
        o, _ = opts(args, ('repo', 'title', 'body', 'body-file', 'priority', 'parent', 'origin', 'milestone'),
                    multi=('label',), bools=('filed', 'no-breakage'))
        repo = norm_repo(o.get('repo', ''))
        title = (o.get('title') or '').strip()
        if not repo:
            raise Fail(2, 'new: --repo is required')
        if not title:
            raise Fail(2, 'new: --title is required')
        labels, prio = [], o.get('priority', '')
        for l in o.get('label') or []:
            m = re.match(r'^priority:(p[0-3])$', l)
            if m:
                prio = prio or m.group(1)
            elif l:
                labels.append(l)
        req = {'repo': repo, 'title': title, 'body': body_of(o) or '', 'labels': labels,
               'priority': prio, 'origin': o.get('origin', '')}
        if o.get('parent'):
            req['parent'] = f'{repo}#{o["parent"]}' if o['parent'].isdigit() else o['parent']
        t = api('POST', '', req)
        url = turl(repo, t.get('number'))
        return url if o.get('filed') else f'{ticket_id("hub", repo, t.get("number"))}\t{url}'

    if verb == 'claim':
        o, pos = opts(args, ('by',), bools=('release',))
        _, repo, n = parse(pos[0] if pos else '')
        req = {'by': o.get('by', '')}
        if o.get('release'):
            req['release'] = True
        t = api('POST', tpath(repo, n, 'claim'), req)
        return 'released' if o.get('release') else f'claimed\t{t.get("assignee", "")}'

    if verb == 'label':
        if len(args) < 3 or args[0] not in ('add', 'rm'):
            raise Fail(2, 'label: say add|rm <id> <label>…')
        _, repo, n = parse(args[1])
        cur = list((api('GET', tpath(repo, n)).get('ticket') or {}).get('labels') or [])
        for l in args[2:]:
            if args[0] == 'add' and l not in cur:
                cur.append(l)
            elif args[0] == 'rm' and l in cur:
                cur.remove(l)
        t = api('PATCH', tpath(repo, n), {'labels': cur})
        return ','.join(t.get('labels') or [])

    if verb == 'priority':
        if len(args) != 2 or args[1] not in ('p0', 'p1', 'p2', 'p3', 'none'):
            raise Fail(2, 'priority: say <id> p0|p1|p2|p3|none')
        _, repo, n = parse(args[0])
        t = api('PATCH', tpath(repo, n), {'priority': '' if args[1] == 'none' else args[1]})
        return t.get('priority') or 'none'

    if verb == 'link':
        o, pos = opts(args, (), bools=('remove',))
        if len(pos) != 2:
            raise Fail(2, 'link: say <parent-id> <child-id>')
        _, prepo, pn = parse(pos[0])
        _, crepo, cn = parse(pos[1])
        req = {'child': f'{crepo}#{cn}'}
        if o.get('remove'):
            req['remove'] = True
        api('POST', tpath(prepo, pn, 'children'), req)
        return 'unlinked' if o.get('remove') else 'linked'

    if verb == 'find':
        o, _ = opts(args, ('repo', 'marker'))
        repo = norm_repo(o.get('repo', ''))
        if not repo or not o.get('marker'):
            raise Fail(2, 'find: --repo and --marker are required')
        d = api('GET', '', query={'repo': repo, 'state': 'open', 'limit': '500'})
        for t in d.get('tickets') or []:
            if o['marker'] in (t.get('body') or ''):
                return f'{ticket_id("hub", repo, t.get("number"))}\t{turl(repo, t.get("number"))}'
        raise Fail(1, '')

    if verb == 'cache':
        o, _ = opts(args, ('repo', 'dir'))
        repo, d = norm_repo(o.get('repo', '')), o.get('dir', '')
        if not repo or not d:
            raise Fail(2, 'cache: --repo and --dir are required')
        return write_cache(repo, d)

    raise Fail(2, f'unknown verb {verb}')


def write_cache(repo, d):
    """The collector's three caches for a hub repo, in GitHub's exact shape
    (共同约定 6): issues `milestone\\t#n\\tassignee\\ttitle`, labels `n\\tlabels`,
    parents `child\\tparent`. Written only after a full answer — a hub that is
    down leaves the last good copy where it was."""
    resp = api('GET', '', query={'repo': repo, 'state': 'open', 'limit': '300'})
    issues, labels, parents = [], [], []
    for t in resp.get('tickets') or []:
        n = t.get('number')
        ls = list(t.get('labels') or [])
        if t.get('priority'):
            ls.append('priority:' + t['priority'])
        who = (t.get('assignee') or '')[:10] or '·'
        title = (t.get('title') or '').replace('\t', ' ').replace('\n', ' ')
        issues.append(f'· no milestone\t#{n}\t{who}\t{title}')
        labels.append(f'{n}\t{",".join(ls)}')
        par = t.get('parent') or ''
        m = re.match(r'^(.+)#([0-9]+)$', par)
        if m and norm_repo(m.group(1)) == repo:
            parents.append(f'{n}\t{m.group(2)}')
    os.makedirs(d, exist_ok=True)
    for name, rows in (('issues', issues), ('labels', labels), ('parents', parents)):
        tmp = os.path.join(d, f'{name}.{os.getpid()}')
        with open(tmp, 'w', encoding='utf-8') as fh:
            fh.write(''.join(r + '\n' for r in rows))
        os.replace(tmp, os.path.join(d, name))
    return ''


# ---- dispatch ----------------------------------------------------------------

# Which argument decides the backend: an id (its prefix) or --repo (its home).
_BY_ID = {'read': 0, 'comment': 0, 'post': 0, 'edit': 0, 'state': 0, 'close': 0, 'children': 0,
          'claim': 0, 'priority': 0, 'link': 0, 'evidence': 0}
_BY_REPO = ('list', 'new', 'find', 'cache')


def backend_of(verb, args, forced):
    if forced:
        return forced
    if verb == 'label':
        return parse(args[1] if len(args) > 1 else '')[0]
    if verb in _BY_ID:
        pos = [a for a in args if not a.startswith('--')]
        return parse(pos[0] if pos else '')[0]
    if verb in _BY_REPO:
        repo = ''
        for i, a in enumerate(args):
            if a == '--repo' and i + 1 < len(args):
                repo = args[i + 1]
            elif a.startswith('--repo='):
                repo = a[7:]
        return 'hub' if home(norm_repo(repo)) == 'hub' else 'gh'
    raise Fail(2, f'unknown verb {verb}')


def run(argv):
    """(rc, stdout) — the CLI without printing; errors on stderr."""
    forced = ''
    argv = list(argv)
    if argv[:2] == ['--backend', 'hub']:
        forced, argv = 'hub', argv[2:]
    if not argv or argv[0] in ('-h', '--help', 'help'):
        return 2, __doc__.split('\n\n')[1]
    verb, args = argv[0], argv[1:]
    try:
        if verb == 'home':
            return 0, home(norm_repo(args[0] if args else ''))
        if verb == 'parse':
            _, repo, n = parse(args[0] if args else '')
            return 0, f'{repo}\t{n}'
        if verb == 'id':
            repo = norm_repo(args[0] if args else '')
            if not repo or len(args) < 2 or not args[1].isdigit():
                raise Fail(2, 'id: say <owner/name> <N>')
            return 0, ticket_id(home(repo), repo, int(args[1]))
        b = backend_of(verb, args, forced)
        # A desk ticket (new without --filed) is filed through the filer, which
        # stamps the marker and checks the taxonomy, then comes back as --filed.
        if verb == 'new' and '--filed' not in args and not forced:
            b = 'gh'
        if b == 'hub' and verb not in ('comment', 'evidence'):
            return 0, hub_verb(verb, args)
        if verb == 'cache':
            raise Fail(2, 'cache: only a hub repo — a GitHub repo is the collector\'s own fetch')
        rc, out = shell([verb] + args, capture=True)
        return rc, out.rstrip('\n')
    except Fail as e:
        if e.msg:
            print(f'fleet-ticket: {e.msg}', file=sys.stderr)
        return e.rc, ''


def call(argv):
    """A hub verb's output for a python caller; raises Fail on a non-zero exit."""
    rc, out = run(argv)
    if rc:
        raise Fail(rc, f'{" ".join(argv[:2])} exited {rc}')
    return out


def main():
    rc, out = run(sys.argv[1:])
    if out:
        print(out)
    return rc


if __name__ == '__main__':
    sys.exit(main())
