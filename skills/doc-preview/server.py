#!/usr/bin/env python3
"""Static file server for doc-preview + a tiny tailnet-only control API.

Serves ONLY what a link names — never a directory, never a page whose code the
request does not carry (issue #1153):

    GET  /d/<code>/[file]          one shared doc; <code> is 128 random bits
    GET  /i/<index code>/          this login's index (its own code, $ROOT/index.token)
    GET  /_pub/<public code>/      one PUBLISHED doc, header stripped (the Funnel target)
    GET  /_ctl/status?id=<code>    -> {"public": bool, "url": str|null}
    POST /_ctl/publish   {id}      -> {"public": true,  "url": str}
    POST /_ctl/unpublish {id}      -> {"public": false, "url": null}

Everything else — `/`, `/d/`, a wrong code, an expired doc — is 404. A doc
expires at its entry's `expires` (share.sh --ttl, default 7 days; 0 = never); a
public link at its `pub_expires`. The rule is enforced HERE, on every request, so
an expired doc is gone even if nothing ever pruned it. A pre-#1153 doc (id
`<YYYYmmdd-HHMMSS>-<n>`, no `expires`) keeps working until 7 days after its id's
timestamp, then 404s like the rest.

The control routes shell out to share.sh (--pubstatus/--publish/--unpublish),
which manages the per-doc Tailscale Funnel path mount. The public Funnel only
mounts individual `/p/<public code>/` paths onto `/_pub/<public code>/`, never
`/_ctl`, so a public viewer cannot reach the control API; the public code is not
the doc's code, so a public link reveals nothing about the tailnet one.

Usage: server.py <port> <serve_dir> <skill_dir> [bind_addr] [public]
       server.py --tool <cmd> <root> [args…]   share.sh's helpers (see tool())

bind_addr defaults to 127.0.0.1 (the `tailscale serve` HTTPS mode, which proxies
to loopback). share.sh passes this login's tailscale IPv4 in its http-direct
fallback — a login that is not tailscale's operator cannot `tailscale serve`, so
the server listens on the tailnet address itself (issue #1093). Either way
another login reaching the port gets 404 without a code.

`public` is share.sh's tunnel mode (issue #1151): a cloudflared quick tunnel fronts
this loopback server on a public https://*.trycloudflare.com URL, so EVERY request
is a public one. The control API is then 404 (there is no private origin to toggle
from), every doc page is served with its header stripped exactly like `/_pub/`,
and the index drops each row's source path — no internal metadata leaves the box.
"""
import hmac
import json
import os
import re
import socketserver
import subprocess
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")
LEGACY_RE = re.compile(r"^([0-9]{8}-[0-9]{6})-[0-9]+$")
LEGACY_TTL = 7 * 86400


def valid_id(doc_id):
    return bool(doc_id) and bool(TOKEN_RE.match(doc_id) or LEGACY_RE.match(doc_id))


def load_entry(root, doc_id):
    if not valid_id(doc_id):
        return None
    try:
        with open(os.path.join(root, "entries", doc_id + ".json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def expires_at(entry, doc_id):
    """Epoch the doc stops being served; 0 = never. THE one expiry rule."""
    exp = entry.get("expires")
    if exp is not None:
        try:
            return int(exp)
        except (TypeError, ValueError):
            return 1   # unreadable → already expired, never "forever"
    m = LEGACY_RE.match(doc_id)
    if m:          # pre-#1153 doc: 7 days from the timestamp in its id
        try:
            return int(time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S"))) + LEGACY_TTL
        except ValueError:
            return 1
    return 0


def live(entry, doc_id, now=None):
    exp = expires_at(entry, doc_id)
    return exp == 0 or (now or time.time()) < exp


def pub_live(entry, now=None):
    exp = int(entry.get("pub_expires") or 0)
    return bool(entry.get("pub")) and (exp == 0 or (now or time.time()) < exp)


def entries(root):
    d = os.path.join(root, "entries")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return
    for n in names:
        if n.endswith(".json"):
            doc_id = n[:-5]
            e = load_entry(root, doc_id)
            if e is not None:
                yield doc_id, e


# ---------------------------------------------------------------------------
# share.sh's helpers: one implementation of the rule the server enforces.
# ---------------------------------------------------------------------------
def parse_ttl(s):
    """'7d' '12h' '30m' '90s' '3' (days) '0' (never) -> seconds, or raise."""
    m = re.match(r"^\s*([0-9]+)\s*([smhd]?)\s*$", s or "")
    if not m:
        raise ValueError("bad ttl %r (want N[smhd], 0 = never)" % s)
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 86400}[m.group(2)]


def human(secs):
    secs = int(secs)
    if secs >= 86400:
        return "%dd%dh" % (secs // 86400, secs % 86400 // 3600)
    if secs >= 3600:
        return "%dh%dm" % (secs // 3600, secs % 3600 // 60)
    return "%dm" % max(1, secs // 60)


def write_entry(root, doc_id, e):
    p = os.path.join(root, "entries", doc_id + ".json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(e, f, indent=2)
    os.replace(tmp, p)


def serve_routes(raw):
    """`tailscale serve status --json` → [(tailnet port, backend port)] for every route
    whose "/" proxies to a loopback port."""
    try:
        web = (json.loads(raw or "{}") or {}).get("Web") or {}
    except ValueError:
        return []
    out = []
    for hostport, cfg in web.items():
        prox = (((cfg or {}).get("Handlers") or {}).get("/") or {}).get("Proxy", "")
        m = re.match(r"^http://127\.0\.0\.1:([0-9]+)/?$", prox)
        if m:
            out.append((hostport.rsplit(":", 1)[1] if ":" in hostport else "443", int(m.group(1))))
    return sorted(out, key=lambda r: int(r[0]))


def owned_ports(path):
    try:
        with open(path, encoding="utf-8") as f:
            return {int(x) for x in f.read().split() if x.isdigit()}
    except OSError:
        return set()


def port_up(p):
    import socket
    s = socket.socket()
    s.settimeout(0.3)
    try:
        return s.connect_ex(("127.0.0.1", p)) == 0
    finally:
        s.close()


def tool(argv):
    cmd, root, args = argv[0], argv[1], argv[2:]
    now = int(time.time())
    if cmd == "ttl":                       # ttl <spec> -> seconds
        print(parse_ttl(args[0]))
    elif cmd == "expired":                 # ids whose doc is past its expiry
        for doc_id, e in entries(root):
            if not live(e, doc_id, now):
                print(doc_id)
    elif cmd == "pub-expired":             # live docs whose PUBLIC link is past its expiry
        for doc_id, e in entries(root):
            if e.get("pub") and live(e, doc_id, now) and not pub_live(e, now):
                print(doc_id)
    elif cmd == "get":                     # get <id> <field> -> value or nothing
        e = load_entry(root, args[0]) or {}
        v = e.get(args[1])
        if v not in (None, ""):
            print(v)
    elif cmd == "set":                     # set <id> k=v … (v '' deletes; ints stay ints)
        e = load_entry(root, args[0])
        if e is None:
            sys.exit(1)
        for kv in args[1:]:
            k, _, v = kv.partition("=")
            if v == "":
                e.pop(k, None)
            else:
                e[k] = int(v) if re.match(r"^-?[0-9]+$", v) else v
        write_entry(root, args[0], e)
    elif cmd == "left":                    # left <id> -> "6d23h" | "永久" | "已过期"
        e = load_entry(root, args[0]) or {}
        exp = expires_at(e, args[0])
        print("永久" if exp == 0 else ("已过期" if exp <= now else human(exp - now)))
    elif cmd == "routes":                  # routes <our port> <owned-ports file> < serve-status-json
        # kind: ours (→ this server) · dead / live (→ a port this login once served) · other
        ours, owned = int(args[0]), owned_ports(args[1])
        for port, backend in serve_routes(sys.stdin.read()):
            if backend == ours:
                kind = "ours"
            elif backend in owned:
                kind = "live" if port_up(backend) else "dead"
            else:
                kind = "other"
            print(port, backend, kind)
    elif cmd == "health":                  # health <owned-ports file> <our port> < serve-status-json
        routes = serve_routes(sys.stdin.read())
        backends = [b for _, b in routes]
        dup = len(backends) - len(set(backends))
        dead = sum(1 for b in backends if not port_up(b))
        pubs = [(doc_id, e) for doc_id, e in entries(root) if e.get("pub") and live(e, doc_id, now)]
        ages = [now - int(e.get("pub_since") or now) for _, e in pubs]
        print("public=%d oldest_public_secs=%d unexpiring_public=%d serve_routes=%d serve_dup=%d serve_dead=%d" % (
            len(pubs), max(ages or [0]), sum(1 for _, e in pubs if not int(e.get("pub_expires") or 0)),
            len(routes), dup, dead))
    else:
        sys.exit("server.py --tool: unknown command %r" % cmd)


if len(sys.argv) > 1 and sys.argv[1] == "--tool":
    try:
        tool(sys.argv[2:])
    except ValueError as err:
        sys.exit(str(err))
    sys.exit(0)


PORT = int(sys.argv[1])
SERVE_DIR = sys.argv[2]
SKILL_DIR = sys.argv[3]
BIND_ADDR = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else "127.0.0.1"
PUBLIC = len(sys.argv) > 5 and sys.argv[5] == "public"
ROOT = os.path.dirname(os.path.abspath(SERVE_DIR))
SHARE = os.path.join(SKILL_DIR, "share.sh")


def index_token():
    try:
        with open(os.path.join(ROOT, "index.token"), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def doc_ok(doc_id):
    if not valid_id(doc_id) or not os.path.isdir(os.path.join(SERVE_DIR, "d", doc_id)):
        return False
    e = load_entry(ROOT, doc_id)
    return e is not None and live(e, doc_id)


def pub_doc(code):
    """The doc id a live PUBLIC code points at, or None."""
    if not TOKEN_RE.match(code or ""):
        return None
    for doc_id, e in entries(ROOT):
        if hmac.compare_digest(str(e.get("pub") or ""), code):
            return doc_id if pub_live(e) and doc_ok(doc_id) else None
    return None


def run_share(action, doc_id):
    """Call share.sh <action> <id> --json; return parsed dict (or error dict)."""
    try:
        p = subprocess.run(
            [SHARE, action, doc_id, "--json"],
            capture_output=True, text=True, timeout=25,
        )
        out = (p.stdout or "").strip().splitlines()
        for line in reversed(out):  # last JSON line wins
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)
        return {"error": (p.stderr or p.stdout or "no output").strip()[:300]}
    except Exception as e:  # noqa: BLE001 - report any failure back as JSON
        return {"error": str(e)[:300]}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=SERVE_DIR, **kw)

    def log_message(self, *a):  # keep the console quiet
        pass

    def list_directory(self, path):  # never a listing — it would print every code
        self.send_error(404)
        return None

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_id(self):
        """Extract & validate a doc id from query (GET) or body (POST)."""
        parsed = urlparse(self.path)
        doc_id = (parse_qs(parsed.query).get("id") or [None])[0]
        if doc_id is None and self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            try:
                doc_id = json.loads(raw).get("id") if raw else None
            except Exception:  # noqa: BLE001 - fall back to form encoding
                doc_id = (parse_qs(raw).get("id") or [None])[0]
        return doc_id if doc_ok(doc_id) else None

    def _html(self, html):
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")  # the code is in the URL
        self.end_headers()
        return self.wfile.write(body)

    def _doc(self, doc_id, sub, strip):
        """Serve file <sub> of doc <doc_id>; index.html with its header stripped if asked."""
        if ".." in sub.split("/") or sub.startswith("/"):
            return self.send_error(404)
        if sub in ("", "index.html"):
            try:
                with open(os.path.join(SERVE_DIR, "d", doc_id, "index.html"), encoding="utf-8") as f:
                    html = f.read()
            except OSError:
                return self.send_error(404)
            if strip:
                html = re.sub(r'<div class="hdr">.*?</div>', "", html, count=1, flags=re.S)
            return self._html(html)
        # non-index assets (e.g. locally-referenced images): pass through, static.
        self.path = "/d/" + doc_id + "/" + sub
        return super().do_GET()

    def do_HEAD(self):
        self.send_error(405)

    def do_GET(self):
        route = urlparse(self.path).path
        parts = route.split("/", 3)          # ['', 'd', '<code>', 'rest…']
        top = parts[1] if len(parts) > 1 else ""
        code = parts[2] if len(parts) > 2 else ""
        sub = parts[3] if len(parts) > 3 else None
        if top == "d":                       # /d/<code>/…
            if not doc_ok(code):
                return self.send_error(404)
            if sub is None:                  # relative links need the slash
                self.send_response(301)
                self.send_header("Location", route + "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
            return self._doc(code, sub, PUBLIC)
        if top == "i" and sub in ("", "index.html"):
            tok = index_token()
            if not tok or not hmac.compare_digest(tok, code):
                return self.send_error(404)
            try:
                with open(os.path.join(SERVE_DIR, "index.html"), encoding="utf-8") as f:
                    html = f.read()
            except OSError:
                return self.send_error(404)
            if PUBLIC:
                html = re.sub(r'<div class="src"[^>]*>.*?</div>', "", html, flags=re.S)
            return self._html(html)
        if PUBLIC:
            return self.send_error(404)
        if route == "/_ctl/status":
            doc_id = self._read_id()
            if not doc_id:
                return self._json({"error": "bad id"}, 400)
            return self._json(run_share("--pubstatus", doc_id))
        if top == "_pub" and sub is not None:
            doc_id = pub_doc(code)
            if not doc_id:
                return self.send_error(404)
            return self._doc(doc_id, sub, True)
        return self.send_error(404)

    def do_POST(self):
        route = urlparse(self.path).path
        if PUBLIC:
            return self.send_error(404)
        if route in ("/_ctl/publish", "/_ctl/unpublish"):
            doc_id = self._read_id()
            if not doc_id:
                return self._json({"error": "bad id"}, 400)
            action = "--publish" if route.endswith("publish") and "unpub" not in route else "--unpublish"
            return self._json(run_share(action, doc_id))
        self.send_error(405)


class Server(ThreadingHTTPServer):
    """ThreadingHTTPServer minus the reverse-DNS lookup in HTTPServer.server_bind().

    http.server resolves socket.getfqdn(bind_addr) between bind() and listen(). On a
    GitHub macos-latest runner that lookup blocks for 30s+, so the port sat BOUND but
    never accepting, share.sh's readiness probe gave up on five ports in a row, and
    the doc-preview-share selftest was red on every macOS run (issue #1500). The
    name only feeds CGIHTTPRequestHandler, which this server never uses, so a server
    on a fixed address has nothing to look up: bind, record the address, listen.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


if __name__ == "__main__":
    srv = Server((BIND_ADDR, PORT), Handler)
    # One line to server.log once accepting — share.sh's failure path tails this file,
    # and an EMPTY log then means "never reached listen()", not "nothing happened".
    print("listening on http://%s:%d/%s" % (BIND_ADDR, PORT, " (public)" if PUBLIC else ""), flush=True)
    srv.serve_forever()
