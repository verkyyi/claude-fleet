#!/usr/bin/env python3
"""cred-proxy — a research prototype (issue #1872), NOT part of the install.

A session gets a short-lived, proxy-signed SESSION credential; the proxy swaps
it for the real subscription credential on the way out, so the real token never
enters the session's environment or files.

    cred_proxy.py serve  --port 8787 --state DIR [--accounts DIR] [--codex-auth FILE]
                         [--codex-homes DIR] [--codex-upstream URL] [--audit] [--max-seconds N]
    cred_proxy.py mint   --state DIR --account LABEL [--sid NAME] [--ttl SECS]
    cred_proxy.py rebind --state DIR --sid NAME --account LABEL

Routes (loopback only):
    /v1/...         -> https://api.anthropic.com/v1/...          (Claude Code)
    /codex/...      -> https://chatgpt.com/backend-api/codex/...  (Codex; --codex-upstream
                       moves it, e.g. to sim/fake_chatgpt.py on loopback — issue #1912)
    CONNECT host:p  -> logged + tunnelled (only with --audit; for HTTPS_PROXY
                       audits of what bypasses ANTHROPIC_BASE_URL)

Rails: binds 127.0.0.1 only; real tokens are read from the account files on
every request (in memory, never copied, never logged); every credential-shaped
header value is logged as <redacted:len>.
"""
import argparse, base64, hashlib, hmac, http.client, json, os, secrets, select
import signal, socket, ssl, sys, threading, time
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANTHROPIC = "api.anthropic.com"
CHATGPT = "chatgpt.com"
OAUTH_BETA = "oauth-2025-04-20"
SECRET_HEADERS = {"authorization", "x-api-key", "cookie", "set-cookie",
                  "chatgpt-account-id", "proxy-authorization"}
HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding",
       "te", "trailer", "upgrade", "host", "content-length"}
PUBLIC = {"/api/hello"}


def b64e(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def b64d(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def state_key(state):
    p = os.path.join(state, "key")
    if not os.path.exists(p):
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, secrets.token_bytes(32)); os.close(fd)
    return open(p, "rb").read()


def mint(state, account, sid, ttl):
    payload = json.dumps({"sid": sid, "acct": account,
                          "exp": int(time.time()) + ttl,
                          "n": secrets.token_hex(4)}, separators=(",", ":")).encode()
    sig = hmac.new(state_key(state), payload, hashlib.sha256).digest()
    return "fcp1." + b64e(payload) + "." + b64e(sig)


def verify(state, tok):
    """-> (claims, None) or (None, reason)."""
    try:
        tag, p, s = tok.split(".")
        if tag != "fcp1":
            return None, "not a session credential"
        payload = b64d(p)
        if not hmac.compare_digest(hmac.new(state_key(state), payload, hashlib.sha256).digest(), b64d(s)):
            return None, "bad signature"
        c = json.loads(payload)
    except Exception:
        return None, "malformed session credential"
    if c["exp"] < time.time():
        return None, "session credential expired"
    revoked = os.path.join(state, "revoked")
    if os.path.exists(revoked) and c["sid"] in open(revoked).read().split():
        return None, "session credential revoked"
    return c, None


def bound_account(state, claims):
    """A rebind (no-restart account switch) wins over the minted account."""
    p = os.path.join(state, "bind.json")
    try:
        return json.load(open(p)).get(claims["sid"], claims["acct"])
    except (OSError, ValueError):
        return claims["acct"]


def claude_token(accounts, label):
    with open(os.path.join(accounts, label + ".hub", ".credentials.json")) as f:
        return json.load(f)["claudeAiOauth"]["accessToken"]


def codex_auth_path(cfg, label):
    """The account's Codex home, the same mapping the node agent leases into
    (tokenledger agent/node_creds.go codexHomeFor): `default` = ~/.codex, any
    other label = <codex homes>/<label>."""
    if label == "default":
        return cfg.codex_auth
    return os.path.join(cfg.codex_homes, label, "auth.json")


def codex_tokens(path):
    with open(path) as f:
        t = json.load(f)["tokens"]
    return t["access_token"], t.get("account_id")


def red(k, v):
    return "<redacted:%d>" % len(v) if k.lower() in SECRET_HEADERS else v


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = None
    lock = threading.Lock()

    def log_message(self, fmt, *a):  # silence the default access log
        pass

    def log(self, **kv):
        kv["t"] = round(time.time(), 3)
        line = json.dumps(kv, ensure_ascii=False)
        with self.lock:
            sys.stderr.write(line + "\n"); sys.stderr.flush()
            if self.cfg.log:
                with open(self.cfg.log, "a") as f:
                    f.write(line + "\n")

    def fail(self, code, msg, typ="authentication_error"):
        body = json.dumps({"type": "error", "error": {"type": typ, "message": "cred-proxy: " + msg}}).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    # ---- CONNECT audit (HTTPS_PROXY): who bypasses the base URL ----
    def do_CONNECT(self):
        host, _, port = self.path.partition(":")
        self.log(ev="connect", host=host, port=port)
        if not self.cfg.audit:
            return self.fail(403, "CONNECT disabled", "forbidden")
        if self.cfg.sinkhole:
            return self.sinkhole(host)
        try:
            up = socket.create_connection((host, int(port or 443)), timeout=30)
        except OSError as e:
            return self.fail(502, "connect failed: %s" % e, "api_error")
        self.send_response(200, "Connection established"); self.end_headers()
        if self.cfg.mitm_cert:
            return self.sniff(host, up)
        socks = [self.connection, up]
        try:
            while True:
                r, _, _ = select.select(socks, [], [], 60)
                if not r:
                    break
                for s in r:
                    d = s.recv(65536)
                    if not d:
                        return
                    (up if s is self.connection else self.connection).sendall(d)
        finally:
            up.close()

    def sinkhole(self, host):
        """--sinkhole: an OFFLINE audit (issue #1912). Terminate the CONNECT's TLS with
        the throwaway leaf, read ONE request, log its method/path and which KIND of
        credential it carried (session credential / something else / none, + length),
        answer 503 and close. Nothing is ever forwarded — nothing leaves the machine."""
        self.send_response(200, "Connection established"); self.end_headers()
        if not self.cfg.mitm_cert:
            return self.log(ev="sinkhole", host=host, tls="no --mitm-cert: host only")
        sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        sctx.load_cert_chain(self.cfg.mitm_cert, self.cfg.mitm_key)
        sctx.set_alpn_protocols(["http/1.1"])
        try:
            cli = sctx.wrap_socket(self.connection, server_side=True)
            cli.settimeout(10)
            d = b""
            while b"\r\n\r\n" not in d and len(d) < 65536:
                c = cli.recv(65536)
                if not c:
                    break
                d += c
        except (ssl.SSLError, OSError) as e:
            return self.log(ev="sinkhole", host=host, tls_fail=str(e)[:100])
        head = d.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        hs = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in head[1:] if ":" in l)}
        auth = hs.get("authorization", "")
        tok = auth[7:].strip() if auth.lower().startswith("bearer ") else auth
        kind = "none" if not tok else ("SESSION-CRED" if tok.startswith("fcp1.") else "other")
        self.log(ev="sinkhole", host=host, req=(head[0].split("?")[0] if head else ""),
                 auth=kind, auth_len=len(tok), acct_hdr="chatgpt-account-id" in hs,
                 ua=hs.get("user-agent", "")[:60])
        try:
            cli.sendall(b"HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
            cli.close()
        except (ssl.SSLError, OSError):
            pass

    def sniff(self, host, up):
        """--mitm-cert: terminate TLS with a throwaway local CA the AUDITED client
        trusts (NODE_EXTRA_CA_CERTS), log each request line + header NAMES and each
        status line, forward bytes unchanged. Research only — never a credential swap."""
        sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        sctx.load_cert_chain(self.cfg.mitm_cert, self.cfg.mitm_key)
        sctx.set_alpn_protocols(["http/1.1"])
        try:
            cli = sctx.wrap_socket(self.connection, server_side=True)
            srv = ssl.create_default_context().wrap_socket(up, server_hostname=host)
        except (ssl.SSLError, OSError) as e:
            self.log(ev="sniff_tls_fail", host=host, err=str(e)[:120]); up.close(); return
        methods = (b"GET ", b"POST ", b"PUT ", b"DELETE ", b"PATCH ", b"HEAD ", b"OPTIONS ")

        def pipe(a, b, outbound):
            try:
                while True:
                    d = a.recv(65536)
                    if not d:
                        break
                    if outbound and d.startswith(methods):
                        head = d.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
                        hs = dict(l.split(":", 1) for l in head[1:] if ":" in l)
                        self.log(ev="bypass_req", host=host, req=head[0].split("?")[0],
                                 auth=sorted("%s=%s" % (k.lower(), red(k, v.strip())) for k, v in hs.items()
                                             if k.lower() in SECRET_HEADERS or k.lower() == "anthropic-beta"),
                                 ua=hs.get("User-Agent", hs.get("user-agent", "")).strip())
                    elif not outbound and d.startswith(b"HTTP/1."):
                        self.log(ev="bypass_resp", host=host, status=d.split(b"\r\n", 1)[0].decode("latin-1"))
                    b.sendall(d)
            except (OSError, ssl.SSLError):
                pass
            finally:
                for s in (a, b):
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

        t = threading.Thread(target=pipe, args=(srv, cli, False), daemon=True); t.start()
        pipe(cli, srv, True); t.join(5); srv.close()

    def do_GET(self): self.forward()
    def do_POST(self): self.forward()
    def do_PUT(self): self.forward()
    def do_DELETE(self): self.forward()
    def do_PATCH(self): self.forward()
    def do_HEAD(self): self.forward()

    def forward(self):
        t0 = time.time()
        path = self.path
        if path.startswith("http://") or path.startswith("https://"):
            # plain-HTTP proxy request in audit mode — log and refuse
            self.log(ev="absolute", url=path.split("?")[0])
            return self.fail(403, "absolute-URI proxying disabled", "forbidden")
        inbound = {k.lower(): v for k, v in self.headers.items()}
        # Read the body FIRST: a refusal that leaves it unread on a keep-alive
        # connection gets the body parsed as the next request (issue #1912 —
        # Codex then showed an HTML "Bad request syntax" instead of our reason).
        n = int(inbound.get("content-length") or 0)
        self.body = self.rfile.read(n) if n else None
        seen = sorted("%s=%s" % (k, red(k, v)) for k, v in inbound.items())
        tok = ""
        if inbound.get("authorization", "").lower().startswith("bearer "):
            tok = inbound["authorization"][7:].strip()
        tok = tok or inbound.get("x-api-key", "")
        if not tok and path.split("?")[0] in PUBLIC:
            return self.passthrough(path, inbound, seen, t0)
        claims, why = verify(self.cfg.state, tok)
        if not claims:
            self.log(ev="deny", path=path, why=why, hdrs=seen)
            return self.fail(401, why)
        acct = bound_account(self.cfg.state, claims)
        out = {k: v for k, v in self.headers.items() if k.lower() not in HOP
               and k.lower() not in ("authorization", "x-api-key")}
        try:
            if path.startswith("/codex/"):
                up = urlsplit(self.cfg.codex_upstream)
                host, upath = up.netloc, up.path.rstrip("/") + "/" + path[len("/codex/"):]
                at, aid = codex_tokens(codex_auth_path(self.cfg, acct))
                out["Authorization"] = "Bearer " + at
                # ALWAYS the bound account's id: a session never picks the
                # workspace its request is billed to (issue #1912).
                out = {k: v for k, v in out.items() if k.lower() != "chatgpt-account-id"}
                if aid:
                    out["chatgpt-account-id"] = aid
            else:
                host, upath = ANTHROPIC, path
                out["Authorization"] = "Bearer " + claude_token(self.cfg.accounts, acct)
                if not self.cfg.no_beta:
                    betas = [b.strip() for k, v in out.items() if k.lower() == "anthropic-beta"
                             for b in v.split(",") if b.strip()]
                    out = {k: v for k, v in out.items() if k.lower() != "anthropic-beta"}
                    if OAUTH_BETA not in betas:
                        betas.append(OAUTH_BETA)
                    out["anthropic-beta"] = ",".join(betas)
        except (OSError, KeyError, ValueError) as e:
            self.log(ev="nocred", sid=claims["sid"], acct=acct, err=type(e).__name__)
            return self.fail(503, "no upstream credential for account %s" % acct, "api_error")
        self.upstream(host, upath, out, inbound, seen, t0, claims["sid"], acct,
                      plain=path.startswith("/codex/") and self.cfg.codex_upstream.startswith("http://"))

    def passthrough(self, path, inbound, seen, t0):
        """An unauthenticated reachability probe (Claude Code's /api/hello): no credential added."""
        out = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        self.upstream(ANTHROPIC, path, out, inbound, seen, t0, "-", "-")

    def upstream(self, host, upath, out, inbound, seen, t0, sid, acct, plain=False):
        path = self.path
        body = self.body
        out["Host"] = host
        if plain:   # --codex-upstream http://127.0.0.1:… (the simulator) — loopback only, checked at start
            conn = http.client.HTTPConnection(host, timeout=600)
        else:
            conn = http.client.HTTPSConnection(host, 443, timeout=600, context=ssl.create_default_context())
        try:
            conn.request(self.command, upath, body=body, headers=out)
            r = conn.getresponse()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, path=path, err=str(e))
            return self.fail(502, "upstream: %s" % e, "api_error")
        ttfb = time.time() - t0
        self.send_response_only(r.status, r.reason)
        rh = [(k, v) for k, v in r.getheaders() if k.lower() not in HOP]
        for k, v in rh:
            self.send_header(k, v)
        chunked = self.command != "HEAD" and r.status not in (204, 304)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        size = 0
        if chunked:
            while True:
                d = r.read1(65536)
                if not d:
                    break
                size += len(d)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        conn.close()
        rl = {k: v for k, v in rh if "ratelimit" in k.lower() or k.lower().startswith("x-codex-")}
        self.log(ev="fwd", sid=sid, acct=acct, m=self.command, path=path.split("?")[0],
                 up=host, status=r.status, ttfb_ms=int(ttfb * 1000),
                 total_ms=int((time.time() - t0) * 1000), bytes=size, hdrs_in=seen,
                 sent=sorted(k.lower() for k in out), beta=out.get("anthropic-beta", ""),
                 rl=sorted(rl))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=8787)
    s.add_argument("--state", required=True)
    s.add_argument("--accounts", default=os.path.expanduser("~/.config/claude-fleet/accounts"))
    s.add_argument("--codex-auth", default=os.path.expanduser("~/.codex/auth.json"),
                   help="the `default` Codex account's auth.json")
    s.add_argument("--codex-homes", default=os.path.expanduser("~/.codex-accounts"),
                   help="any other Codex account: <dir>/<label>/auth.json")
    s.add_argument("--codex-upstream", default="https://chatgpt.com/backend-api/codex",
                   help="where /codex/* goes; http:// is accepted for 127.0.0.1 only")
    s.add_argument("--max-seconds", type=int, default=0, help="exit on its own after N s (0 = never)")
    s.add_argument("--log", default="")
    s.add_argument("--audit", action="store_true", help="tunnel+log CONNECT (HTTPS_PROXY audit)")
    s.add_argument("--mitm-cert", default="", help="audit only: TLS-terminate CONNECTs with this leaf")
    s.add_argument("--mitm-key", default="")
    s.add_argument("--sinkhole", action="store_true",
                   help="audit only: answer every CONNECT locally (503), never connect out")
    s.add_argument("--no-beta", action="store_true", help="do not add the oauth anthropic-beta")
    m = sub.add_parser("mint")
    m.add_argument("--state", required=True); m.add_argument("--account", required=True)
    m.add_argument("--sid", default=""); m.add_argument("--ttl", type=int, default=3600)
    b = sub.add_parser("rebind")
    b.add_argument("--state", required=True); b.add_argument("--sid", required=True)
    b.add_argument("--account", required=True)
    a = ap.parse_args()
    os.makedirs(a.state, mode=0o700, exist_ok=True)
    if a.cmd == "mint":
        print(mint(a.state, a.account, a.sid or "s-" + secrets.token_hex(3), a.ttl))
    elif a.cmd == "rebind":
        p = os.path.join(a.state, "bind.json")
        try:
            d = json.load(open(p))
        except (OSError, ValueError):
            d = {}
        d[a.sid] = a.account
        tmp = p + ".tmp"; json.dump(d, open(tmp, "w")); os.replace(tmp, p)
        print("rebound %s -> %s" % (a.sid, a.account))
    else:
        up = urlsplit(a.codex_upstream)
        if up.scheme == "http" and up.hostname not in ("127.0.0.1", "localhost"):
            sys.exit("cred-proxy: a plain-http --codex-upstream must be loopback")
        if a.max_seconds:
            signal.signal(signal.SIGALRM, lambda *_: os._exit(0)); signal.alarm(a.max_seconds)
        Proxy.cfg = a
        srv = ThreadingHTTPServer(("127.0.0.1", a.port), Proxy)
        srv.daemon_threads = True
        sys.stderr.write("cred-proxy listening on 127.0.0.1:%d\n" % a.port)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
