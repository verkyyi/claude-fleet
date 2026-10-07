#!/usr/bin/env python3
"""fleet-cred-proxy.py — this login's credential proxy (issue #1970, EPIC #1967 C3).

A session never holds a subscription credential: it holds a SESSION credential
and talks to this proxy on loopback; the proxy picks a ROUTE and sends the
request on, with the real credential put in on the way out (or none, centrally).

    serve   [--state DIR] [--port N] [--max-seconds N] [--parent-watch]
    route   [--provider claude|codex] [--refresh] [--json]   → {route, reason, …}
    mint    --account LABEL [--sid NAME] [--ttl SECS]       → fcp1.<…> on stdout
    rebind  --sid NAME --account LABEL                      (next request, no restart)
    revoke  --sid NAME
    attach  --sid NAME          (a hub session credential, fcp-h1.…, on STDIN —
                                 what the central route forwards for this sid)
    status  [--json]

`serve` binds 127.0.0.1 (the port in <state>/port) and a control socket
<state>/ctl.sock (0600); every other subcommand is a client of that socket.
<state> is $FLEET_CONF_DIR/cred-proxy. bin/fleet-cred-proxy.sh is the launcher
(launchd / systemd run it; it reads fleet.conf and honours FLEET_CRED_PROXY).

ROUTES (EPIC #1967 共同约定 1) — decided ONLY by the hub's record of this
machine's trust × the last probe (bin/fleet-node-probe.sh → node-probe.json):

    direct   trusted + reachable    real credential, straight to the provider
    relay    trusted + unreachable  real credential, via the Singapore relay
                                    (FLEET_CRED_RELAY_URL + X-Fleet-Relay)
    central  untrusted              NO credential file is read: the session's
                                    hub credential (fcp-h1.) goes to the
                                    cluster's credential proxy

A region refusal (Anthropic 403 / OpenAI unsupported_country_region_territory)
or a connection that never opens moves THAT session to the next route and
retries the same request; the move is logged `route_switch`.

Rails (共同约定 4/5): loopback + unix socket only; only Authorization is
rewritten (Claude: x-api-key dropped; Codex: chatgpt-account-id overwritten),
the body passes byte for byte, responses stream chunk by chunk; a refusal reads
the request body first; a permanent failure (no credential for the account,
an untrusted machine with no hub credential) answers 403, which neither Claude
Code nor Codex retries; every credential-shaped header is logged as
<redacted:len>.
"""
import argparse, base64, fcntl, hashlib, hmac, http.client, json, os, secrets
import resource, signal, socket, ssl, sys, threading, time, urllib.request
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET_HEADERS = {"authorization", "x-api-key", "cookie", "set-cookie",
                  "chatgpt-account-id", "proxy-authorization", "x-fleet-relay"}
HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding",
       "te", "trailer", "upgrade", "host", "content-length"}
PUBLIC = {"/api/hello"}
OAUTH_BETA = "oauth-2025-04-20"
LOCAL_TAG, HUB_TAG = "fcp1", "fcp-h1"
REGION_MARKS = ("unsupported_country_region_territory", "unsupported_country",
                "unsupported_region", "request not allowed",
                "not available in your country", "not available in your region")
# The upstream's codes for refusing a Codex ACCESS token — the same list as
# tokenledger/internal/codex rpc.go accessRejectCodes (claude-fleet#1920).
ACCESS_REJECT = ("token_revoked", "token_invalidated", "token_expired", "invalid_token", "account_deactivated")
BIN = os.path.dirname(os.path.abspath(__file__))


def env(k, d=""):
    v = os.environ.get(k, "")
    return v if v else d


def conf_dir():
    return env("FLEET_CONF_DIR", os.path.join(env("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "claude-fleet"))


def default_state():
    return os.path.join(conf_dir(), "cred-proxy")


def b64e(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def b64d(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def red(k, v):
    return "<redacted:%d>" % len(v) if k.lower() in SECRET_HEADERS else v


def loopback_ok(url):
    """An upstream URL: https anywhere, plain http only on loopback (the selftest)."""
    u = urlsplit(url)
    return u.scheme == "https" or (u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost", "::1"))


def node_env():
    """$FLEET_CONF_DIR/node.env as a dict — read here, never exported (issue #1491)."""
    out = {}
    try:
        for line in open(os.path.join(conf_dir(), "node.env")):
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


# ---- session credentials (fcp1.<claims>.<HMAC>) ----------------------------
class Keys:
    def __init__(self, state):
        self.state = state
        p = os.path.join(state, "key")
        if not os.path.exists(p):
            try:
                fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                os.write(fd, secrets.token_bytes(32)); os.close(fd)
            except FileExistsError:
                pass
        self.key = open(p, "rb").read()

    def mint(self, account, sid, ttl):
        payload = json.dumps({"sid": sid, "acct": account, "exp": int(time.time()) + ttl,
                              "n": secrets.token_hex(4)}, separators=(",", ":")).encode()
        return LOCAL_TAG + "." + b64e(payload) + "." + b64e(hmac.new(self.key, payload, hashlib.sha256).digest())

    def verify(self, tok):
        """-> (claims, None) or (None, reason)."""
        try:
            tag, p, s = tok.split(".")
            if tag != LOCAL_TAG:
                return None, "not a session credential"
            payload = b64d(p)
            if not hmac.compare_digest(hmac.new(self.key, payload, hashlib.sha256).digest(), b64d(s)):
                return None, "bad signature"
            c = json.loads(payload)
        except Exception:
            return None, "malformed session credential"
        if c.get("exp", 0) < time.time():
            return None, "session credential expired"
        if c.get("sid") in read_lines(os.path.join(self.state, "revoked")):
            return None, "session credential revoked"
        return c, None


def read_lines(p):
    try:
        return set(open(p).read().split())
    except OSError:
        return set()


def write_json(p, d):
    tmp = "%s.%d.tmp" % (p, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(d, f)
    os.replace(tmp, p)


def read_json(p, dflt):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return dflt


# ---- the route decision ----------------------------------------------------
class Router:
    """trust (the hub's word, cached) × probe (node-probe.json) → candidate routes."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.cache = os.path.join(cfg.state, "trust.json")
        c = read_json(self.cache, {})
        self.trust, self.trust_why, self.trust_ts = c.get("trust", ""), c.get("why", ""), c.get("ts", 0)

    # trust ------------------------------------------------------------------
    def refresh(self, log=None):
        """Ask the hub (GET /v1/node/self with the node token). No hub at all =
        a standalone login = trusted. A hub that does not answer keeps the cached
        word; with none cached the machine is `unknown`, which routes as untrusted
        (fail closed: a machine's own say-so never counts)."""
        ne = node_env()
        hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        tok = ne.get("CCQUOTA_TOKEN", "")
        if not hub:
            t, why = "trusted", "no hub: a standalone login"
        elif not tok:
            t, why = "untrusted", "no node token: a client-only computer"
        else:
            try:
                req = urllib.request.Request(hub + "/v1/node/self", headers={"Authorization": "Bearer " + tok})
                with urllib.request.urlopen(req, timeout=10) as r:
                    body = json.loads(r.read() or b"{}")
                raw = body.get("trust")
                if raw is None and isinstance(body.get("trusted"), bool):
                    raw = "trusted" if body["trusted"] else "untrusted"
                if raw is None:
                    t, why = "trusted", "hub keeps no trust record (before #1968): every activated machine is trusted"
                else:
                    t = "trusted" if str(raw).lower() in ("trusted", "true", "1") else "untrusted"
                    why = "hub: %s" % raw
            except Exception as e:
                with self.lock:
                    if self.trust:
                        return self.trust
                    self.trust, self.trust_why = "unknown", "hub unreachable, nothing cached (%s)" % type(e).__name__
                    return self.trust
        with self.lock:
            changed = t != self.trust
            self.trust, self.trust_why, self.trust_ts = t, why, int(time.time())
        write_json(self.cache, {"trust": t, "why": why, "ts": self.trust_ts})
        if changed and log:
            log(ev="trust", trust=t, why=why)
        return t

    # probe ------------------------------------------------------------------
    def probe(self, provider):
        """reachable | unreachable | unsupported_region | none (never probed)."""
        if env("FLEET_PROBE_FORCE_UNREACHABLE") == "1":
            return "unreachable"
        d = read_json(os.path.join(conf_dir(), "node-probe.json"), None)
        if not isinstance(d, dict):
            return "none"
        return str(d.get("anthropic" if provider == "claude" else "openai", "none")) or "none"

    def candidates(self, provider, has_hub_cred):
        """-> ([route, …] best first, reason)."""
        with self.lock:
            trust, twhy = self.trust or "unknown", self.trust_why
        relay = bool(self.cfg.relay_url)
        if trust != "trusted":
            return ["central"], "%s (%s) → central, no credential file is read" % (trust, twhy)
        p = self.probe(provider)
        if p in ("reachable", "none"):
            order, why = ["direct", "relay"], "trusted + %s" % ("reachable" if p == "reachable" else "never probed")
        else:
            order, why = ["relay", "direct"], "trusted + %s" % p
        if not relay:
            order.remove("relay")
            if order[0] == "direct" and p not in ("reachable", "none"):
                why += ", no relay configured (FLEET_CRED_RELAY_URL)"
        if has_hub_cred:
            order.append("central")
        return order, why


# ---- the proxy ---------------------------------------------------------------
class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = keys = router = None
    lock = threading.Lock()
    skip = {}       # sid -> {route: until}: a route that refused this session
    hubcreds = {}   # sid -> fcp-h1.… handed in over ctl `attach` (memory only)

    def log_message(self, fmt, *a):
        pass

    @classmethod
    def log(cls, **kv):
        kv = dict(t=round(time.time(), 3), **kv)
        line = json.dumps(kv, ensure_ascii=False)
        with cls.lock:
            if cls.cfg.log:
                try:
                    fd = os.open(cls.cfg.log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                    with os.fdopen(fd, "a") as f:
                        f.write(line + "\n")
                except OSError:
                    pass
            if cls.cfg.verbose:
                sys.stderr.write(line + "\n"); sys.stderr.flush()

    def fail(self, code, msg, typ="authentication_error"):
        body = json.dumps({"type": "error", "error": {"type": typ, "message": "cred-proxy: " + msg}}).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_CONNECT(self):
        self.log(ev="deny", path="CONNECT " + self.path.split(":")[0], why="CONNECT disabled")
        self.fail(403, "CONNECT disabled", "permission_error")

    def do_GET(self): self.forward()
    def do_POST(self): self.forward()
    def do_PUT(self): self.forward()
    def do_DELETE(self): self.forward()
    def do_PATCH(self): self.forward()
    def do_HEAD(self): self.forward()

    def forward(self):
        t0 = time.time()
        inbound = {k.lower(): v for k, v in self.headers.items()}
        # Read the body FIRST: a refusal that leaves it unread on a keep-alive
        # connection gets it parsed as the next request (issue #1912).
        n = int(inbound.get("content-length") or 0)
        body = self.rfile.read(n) if n else None
        path = self.path
        if path.startswith("http://") or path.startswith("https://"):
            self.log(ev="deny", path=path.split("?")[0], why="absolute-URI proxying disabled")
            return self.fail(403, "absolute-URI proxying disabled", "permission_error")
        provider = "codex" if path.startswith("/codex/") else "claude"
        seen = sorted("%s=%s" % (k, red(k, v)) for k, v in inbound.items())
        tok = ""
        if inbound.get("authorization", "").lower().startswith("bearer "):
            tok = inbound["authorization"][7:].strip()
        tok = tok or inbound.get("x-api-key", "")
        if not tok and path.split("?")[0] in PUBLIC:
            return self.send(["direct"], provider, path, body, None, "-", "-", seen, t0, public=True)
        if tok.startswith(HUB_TAG + "."):
            # a hub-issued session credential: only the cluster can check it
            sid = "h-" + hashlib.sha256(tok.encode()).hexdigest()[:10]
            return self.send(["central"], provider, path, body, tok, sid, "-", seen, t0)
        claims, why = self.keys.verify(tok)
        if not claims:
            self.log(ev="deny", path=path.split("?")[0], why=why, hdrs=seen)
            return self.fail(401, why)
        sid = claims["sid"]
        acct = read_json(os.path.join(self.cfg.state, "bind.json"), {}).get(sid, claims["acct"])
        hubcred = self.hubcreds.get(sid)
        order, _ = self.router.candidates(provider, bool(hubcred))
        self.send(order, provider, path, body, hubcred, sid, acct, seen, t0)

    def plan(self, order, sid):
        """Drop the routes that refused this session recently; all of them = try again."""
        now = time.time()
        with self.lock:
            sk = {r: u for r, u in self.skip.get(sid, {}).items() if u > now}
            self.skip[sid] = sk
        left = [r for r in order if r not in sk]
        return left or order

    def target(self, route, provider, path, acct, hubcred, public=False):
        """-> (base url, path, headers to set, headers to drop, cred source)."""
        c = self.cfg
        if provider == "codex":
            suffix = path[len("/codex/"):]
            base = {"direct": c.codex_url, "relay": c.relay_url + "/chatgpt/codex",
                    "central": c.central_url + "/v1/proxy/codex"}[route]
            upath = urlsplit(base).path.rstrip("/") + "/" + suffix
        else:
            base = {"direct": c.anthropic_url, "relay": c.relay_url + "/anthropic",
                    "central": c.central_url + "/v1/proxy/anthropic"}[route]
            upath = urlsplit(base).path.rstrip("/") + path
        put, drop = {}, {"authorization", "x-api-key"}
        if route == "relay":
            put["X-Fleet-Relay"] = c.relay_token
        if public:
            return base, upath, put, set(), "none"
        if route == "central":
            # never a credential file: the hub credential is the whole auth
            put["Authorization"] = "Bearer " + hubcred
            return base, upath, put, drop, "none"
        if provider == "codex":
            path = codex_auth_path(c, acct)
            at, aid, fp = codex_tokens(path)
            self.codex_seen = (os.path.dirname(path), fp)
            put["Authorization"] = "Bearer " + at
            drop.add("chatgpt-account-id")
            if aid:   # ALWAYS the bound account's: a session never picks its workspace (#1912)
                put["chatgpt-account-id"] = aid
        else:
            put["Authorization"] = "Bearer " + claude_token(c.accounts, acct)
        return base, upath, put, drop, "file"

    def send(self, order, provider, path, body, hubcred, sid, acct, seen, t0, public=False):
        order = [r for r in self.plan(order, sid)
                 if (r != "relay" or self.cfg.relay_url) and (r != "central" or (self.cfg.central_url and hubcred))]
        if not order:
            # permanent: 403, which neither client retries (never a 503)
            self.log(ev="deny", sid=sid, path=path.split("?")[0], why="no usable route")
            return self.fail(403, "this machine routes central (untrusted) and this session has no "
                             "hub session credential (or no central proxy is configured)", "permission_error")
        last = None
        for i, route in enumerate(order):
            try:
                base, upath, put, drop, cred = self.target(route, provider, path, acct, hubcred, public)
            except (OSError, KeyError, ValueError, TypeError) as e:
                self.log(ev="nocred", sid=sid, acct=acct, route=route, err=type(e).__name__)
                last = (403, "no upstream credential for account %s" % acct, "permission_error")
                continue
            out = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() not in drop}
            if provider == "claude" and cred == "file":
                betas = [b.strip() for k, v in out.items() if k.lower() == "anthropic-beta"
                         for b in v.split(",") if b.strip()]
                out = {k: v for k, v in out.items() if k.lower() != "anthropic-beta"}
                if OAUTH_BETA not in betas:
                    betas.append(OAUTH_BETA)
                out["anthropic-beta"] = ",".join(betas)
            out.update(put)
            nxt = order[i + 1] if i + 1 < len(order) else None
            res = self.upstream(base, upath, out, body, route, sid, acct, cred, seen, t0, provider,
                                can_switch=nxt is not None)
            if res is None:
                return
            # a region refusal / a connection that never opened: next route, same request
            with self.lock:
                self.skip.setdefault(sid, {})[route] = time.time() + self.cfg.switch_ttl
            self.log(ev="route_switch", sid=sid, acct=acct, provider=provider, frm=route, to=nxt, why=res)
        code, msg, typ = last or (502, "no route answered", "api_error")
        self.fail(code, msg, typ)

    def upstream(self, base, upath, out, body, route, sid, acct, cred, seen, t0, provider, can_switch):
        """Send one request. None = answered (the response went to the client);
        a reason string = switch routes (only when can_switch)."""
        u = urlsplit(base)
        out["Host"] = u.netloc
        if u.scheme == "http":
            conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=self.cfg.timeout)
        else:
            conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=self.cfg.timeout,
                                               context=ssl.create_default_context())
        try:
            conn.connect()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, route=route, phase="connect", err=type(e).__name__)
            if can_switch:
                return "connect failed (%s)" % type(e).__name__
            self.fail(502, "upstream %s unreachable: %s" % (route, type(e).__name__), "api_error")
            return None
        try:
            conn.request(self.command, upath, body=body, headers=out)
            r = conn.getresponse()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, route=route, phase="request", err=type(e).__name__)
            self.fail(502, "upstream %s: %s" % (route, type(e).__name__), "api_error")
            return None
        ttfb = time.time() - t0
        first = b""
        if r.status == 403:
            first = r.read(65536)
            if can_switch and any(m in first.decode("utf-8", "replace").lower() for m in REGION_MARKS):
                conn.close()
                return "region refusal (403)"
        if provider == "codex" and cred == "file":
            if r.status == 401:
                first = r.read(65536)
            codex_verdict(getattr(self, "codex_seen", None), route, r.status, first)
        self.send_response_only(r.status, r.reason)
        rh = [(k, v) for k, v in r.getheaders() if k.lower() not in HOP]
        for k, v in rh:
            self.send_header(k, v)
        chunked = self.command != "HEAD" and r.status not in (204, 304)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        size = 0
        try:
            if chunked:
                d = first
                while True:
                    if d:
                        size += len(d)
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush()
                    d = r.read1(65536)
                    if not d:
                        break
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except OSError:
            pass
        conn.close()
        self.log(ev="fwd", sid=sid, acct=acct, route=route, cred=cred, provider=provider,
                 m=self.command, path=self.path.split("?")[0], up=u.netloc, status=r.status,
                 ttfb_ms=int(ttfb * 1000), total_ms=int((time.time() - t0) * 1000), bytes=size,
                 hdrs_in=seen, sent=sorted(k.lower() for k in out))
        return None


def claude_token(accounts, label):
    with open(os.path.join(accounts, label + ".hub", ".credentials.json")) as f:
        return json.load(f)["claudeAiOauth"]["accessToken"]


def codex_auth_path(cfg, label):
    """`default` = ~/.codex/auth.json, any other label = <codex homes>/<label>/auth.json
    (the node agent's mapping, tokenledger agent/node_creds.go codexHomeFor)."""
    if label == "default":
        return cfg.codex_auth
    return os.path.join(cfg.codex_homes, label, "auth.json")


def codex_tokens(path):
    """-> (access token, account id, credential fingerprint). The fingerprint is
    ccquota's credential_version (sha256 of access NUL refresh), so a verdict
    names the exact credential it was given on and nothing more."""
    with open(path) as f:
        t = json.load(f)["tokens"]
    fp = hashlib.sha256((t["access_token"] + "\0" + (t.get("refresh_token") or "")).encode()).hexdigest()
    return t["access_token"], t.get("account_id"), fp


def codex_verdict(seen, route, status, body):
    """Leave the upstream's word on a Codex home's access token where
    `ccquota codex list` reads it (<home>/.ccquota-upstream.json,
    claude-fleet#1920): a 401 is a refusal of THIS credential — its code when
    the body names one, else "401" (direct only: a relay's own 401 is about
    X-Fleet-Relay, so there only a named code counts). A 2xx clears a refusal on
    record for the same credential; otherwise nothing is written per request.
    Never a token, never the upstream's message. Best effort: never fails a
    request."""
    if not seen or not (status == 401 or 200 <= status < 300):
        return
    home, fp = seen
    path = os.path.join(home, ".ccquota-upstream.json")
    old = read_json(path, {})
    if not isinstance(old, dict):
        old = {}
    if status == 401:
        text = (body or b"").decode("utf-8", "replace").lower()
        code = next((c for c in ACCESS_REJECT if c in text.replace("refresh_" + c, "")), "")
        if not code and route != "direct":
            return
        v = {"credential_version": fp, "state": "rejected", "error": code or "401"}
    else:
        if old.get("credential_version") != fp or old.get("state") != "rejected":
            return
        v = {"credential_version": fp, "state": "accepted"}
    if old.get("credential_version") == fp and old.get("state") == v["state"] \
            and old.get("error", "") == v.get("error", ""):
        return
    v["at"], v["by"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "proxy"
    try:
        write_json(path, v)
    except OSError:
        pass


# ---- the control socket ------------------------------------------------------
def ctl_handle(req, cfg):
    op = req.get("op")
    if op == "route":
        if req.get("refresh"):
            Proxy.router.refresh(Proxy.log)
        prov = req.get("provider") or "claude"
        order, why = Proxy.router.candidates(prov, False)
        return {"ok": True, "route": order[0], "reason": why, "candidates": order,
                "trust": Proxy.router.trust or "unknown", "probe": Proxy.router.probe(prov),
                "provider": prov}
    if op == "mint":
        acct = req.get("account") or ""
        if not acct or "/" in acct or acct.startswith("."):
            return {"ok": False, "err": "mint: --account LABEL"}
        sid = req.get("sid") or "s-" + secrets.token_hex(4)
        tok = Proxy.keys.mint(acct, sid, int(req.get("ttl") or cfg.ttl))
        Proxy.log(ev="mint", sid=sid, acct=acct)
        return {"ok": True, "token": tok, "sid": sid}
    if op == "rebind":
        sid, acct = req.get("sid") or "", req.get("account") or ""
        if not sid or not acct:
            return {"ok": False, "err": "rebind: --sid and --account"}
        p = os.path.join(cfg.state, "bind.json")
        with Proxy.lock:
            d = read_json(p, {}); d[sid] = acct; write_json(p, d)
        Proxy.log(ev="rebind", sid=sid, acct=acct)
        return {"ok": True}
    if op == "revoke":
        sid = req.get("sid") or ""
        if not sid:
            return {"ok": False, "err": "revoke: --sid"}
        with Proxy.lock:
            fd = os.open(os.path.join(cfg.state, "revoked"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.write(fd, (sid + "\n").encode()); os.close(fd)
            Proxy.hubcreds.pop(sid, None)
        Proxy.log(ev="revoke", sid=sid)
        return {"ok": True}
    if op == "attach":
        sid, hc = req.get("sid") or "", (req.get("cred") or "").strip()
        if not sid or not hc.startswith(HUB_TAG + "."):
            return {"ok": False, "err": "attach: --sid and a %s. credential on stdin" % HUB_TAG}
        with Proxy.lock:
            Proxy.hubcreds[sid] = hc
        Proxy.log(ev="attach", sid=sid)
        return {"ok": True}
    if op == "status":
        return {"ok": True, "pid": os.getpid(), "port": cfg.bound_port,
                "trust": Proxy.router.trust or "unknown", "trust_why": Proxy.router.trust_why,
                "relay": bool(cfg.relay_url), "central": cfg.central_url or ""}
    return {"ok": False, "err": "unknown op %r" % op}


def ctl_serve(sock, cfg):
    while True:
        try:
            c, _ = sock.accept()
        except OSError:
            return
        threading.Thread(target=ctl_conn, args=(c, cfg), daemon=True).start()


def ctl_conn(c, cfg):
    try:
        c.settimeout(10)
        buf = b""
        while b"\n" not in buf and len(buf) < 65536:
            d = c.recv(65536)
            if not d:
                break
            buf += d
        try:
            res = ctl_handle(json.loads(buf.split(b"\n", 1)[0] or b"{}"), cfg)
        except Exception as e:
            res = {"ok": False, "err": "%s: %s" % (type(e).__name__, e)}
        c.sendall((json.dumps(res) + "\n").encode())
    except OSError:
        pass
    finally:
        c.close()


def ctl_call(state, req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    try:
        s.connect(os.path.join(state, "ctl.sock"))
    except OSError as e:
        sys.stderr.write("fleet-cred-proxy: not running (%s: %s)\n" % (os.path.join(state, "ctl.sock"), e.strerror))
        sys.exit(3)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        d = s.recv(65536)
        if not d:
            break
        buf += d
    s.close()
    res = json.loads(buf or b"{}")
    if not res.get("ok"):
        sys.stderr.write("fleet-cred-proxy: %s\n" % res.get("err", "failed"))
        sys.exit(1)
    return res


# ---- serve ---------------------------------------------------------------------
def serve(a):
    cfg = a
    st = a.state
    os.makedirs(st, mode=0o700, exist_ok=True)
    lockf = open(os.path.join(st, "lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.stderr.write("fleet-cred-proxy: already running (%s/lock)\n" % st)
        sys.exit(0)
    cfg.anthropic_url = env("FLEET_CRED_ANTHROPIC_URL", "https://api.anthropic.com").rstrip("/")
    cfg.codex_url = env("FLEET_CRED_CODEX_URL", "https://chatgpt.com/backend-api/codex").rstrip("/")
    cfg.relay_url = env("FLEET_CRED_RELAY_URL").rstrip("/")
    cfg.relay_token = env("FLEET_CRED_RELAY_TOKEN")
    ne = node_env()
    cfg.central_url = env("FLEET_CRED_CENTRAL_URL", ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
    cfg.accounts = env("FLEET_CRED_ACCOUNTS", os.path.join(conf_dir(), "accounts"))
    cfg.codex_auth = env("FLEET_CRED_CODEX_AUTH", os.path.expanduser("~/.codex/auth.json"))
    cfg.codex_homes = env("FLEET_CRED_CODEX_HOMES", os.path.expanduser("~/.codex-accounts"))
    cfg.ttl = int(env("FLEET_CRED_PROXY_TTL", "86400"))
    cfg.switch_ttl = int(env("FLEET_CRED_PROXY_SWITCH_SECS", "1800"))
    cfg.timeout = int(env("FLEET_CRED_PROXY_TIMEOUT", "600"))
    for name in ("anthropic_url", "codex_url", "relay_url", "central_url"):
        v = getattr(cfg, name)
        if v and not loopback_ok(v):
            sys.exit("fleet-cred-proxy: %s=%s: https, or plain http on loopback only" % (name, v))
    if cfg.relay_url and not cfg.relay_token:
        sys.exit("fleet-cred-proxy: FLEET_CRED_RELAY_URL set without FLEET_CRED_RELAY_TOKEN")
    if not cfg.log:
        cfg.log = env("FLEET_CRED_PROXY_LOG", os.path.join(os.path.dirname(BIN), "logs", "cred-proxy.log"))
    try:
        os.makedirs(os.path.dirname(cfg.log), exist_ok=True)
    except OSError:
        pass
    Proxy.cfg, Proxy.keys, Proxy.router = cfg, Keys(st), Router(cfg)

    # the port: --port, else the last one used (live sessions carry it in
    # ANTHROPIC_BASE_URL — a restart must not move it), else any free one
    portf = os.path.join(st, "port")
    want = [a.port] if a.port else []
    try:
        prev = int(open(portf).read().strip())
        if not a.port:
            want.append(prev)
    except (OSError, ValueError):
        pass
    srv = None
    for p in want + [0]:
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", p), Proxy)
            break
        except OSError:
            if a.port and p == a.port:
                sys.exit("fleet-cred-proxy: 127.0.0.1:%d is taken" % p)
    srv.daemon_threads = True
    cfg.bound_port = srv.server_address[1]

    sockp, pidf = os.path.join(st, "ctl.sock"), os.path.join(st, "pid")
    try:
        os.unlink(sockp)
    except OSError:
        pass
    ctl = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        ctl.bind(sockp)
    finally:
        os.umask(old)
    os.chmod(sockp, 0o600)
    ctl.listen(16)

    def bye(*_):
        for p in (sockp, pidf):
            try:
                os.unlink(p)
            except OSError:
                pass
        os._exit(0)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    if a.max_seconds:
        signal.signal(signal.SIGALRM, bye); signal.alarm(a.max_seconds)

    Proxy.router.refresh(Proxy.log)
    with open(portf + ".tmp", "w") as f:
        f.write("%d\n" % cfg.bound_port)
    os.replace(portf + ".tmp", portf)
    with open(pidf, "w") as f:
        f.write("%d\n" % os.getpid())

    parent = os.getppid()

    def tick():
        every = max(5, int(env("FLEET_CRED_PROXY_TRUST_SECS", "300")))
        last = time.time()
        while True:
            time.sleep(1)
            if a.parent_watch and os.getppid() != parent:
                bye()       # the launcher died: never outlive it as an orphan
            if time.time() - last >= every:
                last = time.time()
                try:
                    Proxy.router.refresh(Proxy.log)
                except Exception:
                    pass
    threading.Thread(target=tick, daemon=True).start()
    threading.Thread(target=ctl_serve, args=(ctl, cfg), daemon=True).start()
    order, why = Proxy.router.candidates("claude", False)
    nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    Proxy.log(ev="start", pid=os.getpid(), port=cfg.bound_port, route=order[0], reason=why, nofile=nofile)
    sys.stderr.write("fleet-cred-proxy: 127.0.0.1:%d · route %s (%s) · nofile=%d\n" % (cfg.bound_port, order[0], why, nofile))
    srv.serve_forever()


def main():
    ap = argparse.ArgumentParser(prog="fleet-cred-proxy.py")
    ap.add_argument("--state", default="")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=int(env("FLEET_CRED_PROXY_PORT", "0")))
    s.add_argument("--max-seconds", type=int, default=0)
    s.add_argument("--log", default="")
    s.add_argument("--parent-watch", action="store_true")
    s.add_argument("--verbose", action="store_true")
    r = sub.add_parser("route")
    r.add_argument("--provider", default="claude", choices=("claude", "codex"))
    r.add_argument("--refresh", action="store_true")
    r.add_argument("--json", action="store_true")
    m = sub.add_parser("mint")
    m.add_argument("--account", required=True); m.add_argument("--sid", default="")
    m.add_argument("--ttl", type=int, default=0)
    b = sub.add_parser("rebind")
    b.add_argument("--sid", required=True); b.add_argument("--account", required=True)
    v = sub.add_parser("revoke")
    v.add_argument("--sid", required=True)
    t = sub.add_parser("attach")
    t.add_argument("--sid", required=True)
    u = sub.add_parser("status")
    u.add_argument("--json", action="store_true")
    a = ap.parse_args()
    a.state = a.state or default_state()
    if a.cmd == "serve":
        return serve(a)
    if a.cmd == "route":
        res = ctl_call(a.state, {"op": "route", "provider": a.provider, "refresh": a.refresh})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False) if a.json else "%s\t%s" % (res["route"], res["reason"]))
    elif a.cmd == "mint":
        print(ctl_call(a.state, {"op": "mint", "account": a.account, "sid": a.sid, "ttl": a.ttl})["token"])
    elif a.cmd == "rebind":
        ctl_call(a.state, {"op": "rebind", "sid": a.sid, "account": a.account})
        print("rebound %s -> %s" % (a.sid, a.account))
    elif a.cmd == "revoke":
        ctl_call(a.state, {"op": "revoke", "sid": a.sid})
        print("revoked %s" % a.sid)
    elif a.cmd == "attach":
        ctl_call(a.state, {"op": "attach", "sid": a.sid, "cred": sys.stdin.readline()})
        print("attached %s" % a.sid)
    elif a.cmd == "status":
        res = ctl_call(a.state, {"op": "status"})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False) if a.json else
              "pid %s · 127.0.0.1:%s · trust %s (%s)" % (res["pid"], res["port"], res["trust"], res["trust_why"]))


if __name__ == "__main__":
    main()
