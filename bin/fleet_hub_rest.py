#!/usr/bin/env python3
"""fleet_hub_rest.py — the python client of the hub's /v1/fleet REST (a module).

It is what was left of the ticket store's client when the ticket layer went (issue #4898,
EPIC #4895 批 1): the node-token credential pair, one REST call, and the
`gh:` reference grammar a repo authority's accepted start still names (the hub's
own `hub:` tickets left with T477).
bin/fleet_repo_authority.py is its caller.

The node token is read the way every hub caller reads it (`_fleet_hub_env`, issue
#1491): asked of that function over a pipe — never an argv, a file or our own env
export. Exit-code style errors: Fail(rc, msg) — 1 the hub refused · 2 a bad request
or reference · 4 the hub is not reachable (no answer, or no node token).
"""
import io
import json
import os
import re
import socket
import subprocess
import urllib.parse
# http.client / urllib.request / urllib.error are imported where a request is
# made (T716): they pull in email, ssl and http — ~1 s on a busy disk — and a
# caller that never asks the hub (fleet_repo_authority.py --supervise, a
# --match-ticket-ref) paid it on every start.

BIN = os.path.dirname(os.path.abspath(__file__))
ID_RE = re.compile(r'^(gh):([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$')
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
        raise Fail(2, f'{tid or "(empty)"} is not a ticket id — write gh:<owner/name>#<N>')
    return m.group(1), m.group(2), int(m.group(3))


# ---- the hub's REST --------------------------------------------------------

_CREDS = None


def creds():
    global _CREDS
    if _CREDS:
        return _CREDS
    url, tok = os.environ.get('CCQUOTA_HUB_URL', ''), os.environ.get('CCQUOTA_TOKEN', '')
    if tok and not url:
        raise Fail(4, '入口不通 — CCQUOTA_TOKEN requires its own CCQUOTA_HUB_URL; '
                      'refusing to choose an endpoint for an explicit identity')
    if not (url and tok):
        # A URL alone is not an authentication source. Ask the existing reader
        # for ONE complete pair, without letting it fill an inherited half from
        # node.env. In particular, never attach its broker token to a public URL.
        env = {k: v for k, v in os.environ.items()
               if k not in ('CCQUOTA_HUB_URL', 'CCQUOTA_TOKEN')}
        p = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh" >/dev/null 2>&1 && _fleet_hub_env || exit 1; '
                            'printf "%s\\t%s" "${CCQUOTA_HUB_URL:-}" "${CCQUOTA_TOKEN:-}"', '_', BIN],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        url, _, tok = (p.stdout or '').partition('\t') if p.returncode == 0 else ('', '', '')
    if not url or not tok:
        raise Fail(4, '入口不通 — no node token here (node.env / CCQUOTA_TOKEN); '
                      'fix: `fleet-hub-node.sh env --write`')
    _CREDS = (url.rstrip('/'), tok)
    return _CREDS


def hub_sock():
    """The running agent's local forwarder to the hub (issue T672,
    tokenledger/shared/hubfwd; fleet_hub_sock in fleet-client-core.sh): the
    first socket of $CCQUOTA_HUB_SOCK ("off" = none), ~/.ccquota/hub.sock,
    /var/db/fleet-node/hub.sock — or None."""
    env = os.environ.get('CCQUOTA_HUB_SOCK', '')
    if env == 'off':
        return None
    cands = [env] if env else [os.path.expanduser('~/.ccquota/hub.sock'), '/var/db/fleet-node/hub.sock']
    for p in cands:
        try:
            if p and os.path.exists(p) and (os.stat(p).st_mode & 0o170000) == 0o140000:
                return p
        except OSError:
            pass
    return None


def _UnixConn(path, timeout):
    import http.client

    class UnixConn(http.client.HTTPConnection):
        def connect(self):
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(self.timeout)
            self.sock.connect(path)

    return UnixConn('localhost', timeout=timeout)


def _via_sock(sock, req, hub):
    """One request on the agent's warm road: (status, body), or None when nobody
    answered there or the forwarder refused before forwarding — the caller then
    goes direct. A request that may have been sent is never sent twice."""
    u = urllib.parse.urlsplit(req.full_url)
    conn = _UnixConn(sock, TIMEOUT)
    try:
        conn.connect()
    except OSError:
        return None
    try:
        hdrs = dict(req.header_items())
        hdrs['Host'] = u.netloc
        hdrs['X-Fleet-Hub'] = hub
        conn.request(req.get_method(), u.path + ('?' + u.query if u.query else ''), body=req.data, headers=hdrs)
        r = conn.getresponse()
        raw = r.read()
        if r.getheader('X-Fleet-Hubfwd') == 'refused':
            return None
        if r.getheader('X-Fleet-Hubfwd') == 'unreachable':
            raise OSError(raw.decode('utf-8', 'replace').replace('hubfwd: ', '', 1).strip())
        return r.status, raw
    finally:
        conn.close()


def api(method, path, body=None, query=None, root='/v1/fleet', headers=None):
    import urllib.error
    import urllib.request
    url, tok = creds()
    # A task authority is a person's (issue #4901): /authority[/start] is
    # the hub's /v1/fleet/authority road (#4896); a repo= on it only names the
    # start or narrows the lists.
    # root='/v1/node' is the node road (fleet-repo-follow.py's /v1/node/repos).
    full = url + root + path
    if query:
        full += '?' + urllib.parse.urlencode({k: v for k, v in query.items() if v not in (None, '')})
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(full, data=data, method=method)
    req.add_header('Authorization', 'Bearer ' + tok)
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        # only a remote https hub: a login's own broker is already local
        got = _via_sock(hub_sock(), req, url) if url.startswith('https://') and hub_sock() else None
        if got is not None:
            st, raw = got
            if st >= 400:
                raise urllib.error.HTTPError(full, st, '', {}, io.BytesIO(raw))
        else:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read() or b''
        try:
            doc = json.loads(raw)
        except ValueError:
            doc = {}
        why = doc.get('error') or raw.decode('utf-8', 'replace').strip()[:200]
        raise Fail(2 if e.code == 400 else 1, f'the hub refused: HTTP {e.code} — {why}')
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Fail(4, f'入口不通 — {url}: {getattr(e, "reason", e)}')
    try:
        return json.loads(raw) if raw else {}
    except ValueError:
        raise Fail(1, 'the hub answered something that is not JSON')
