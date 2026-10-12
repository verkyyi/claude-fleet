#!/usr/bin/env python3
"""fleet-relay-check.py — the Singapore relay's local gate (claude-fleet#2048,
EPIC #2119 C7). Caddy's forward_auth asks THIS process (127.0.0.1 only), and it
asks the hub's GET /v1/relay/check — so the relay keeps forwarding while the hub
restarts. docs/dev/CRED-RELAY.md «入口重启时» is the runbook;
bin/fleet-break-it-cred-selftest.sh (`cred-relay-hub-restart`) drills it.

The verdict, per (SHA-256 of the pass, route prefix):
  - the hub said 2xx less than RELAY_CHECK_CACHE_S ago (30)  → 200, the hub not asked;
  - otherwise ask the hub: 2xx → 200 and remember the time; any other answer
    below 500 → that answer, and forget the pass (a revocation lands here, so it
    takes at most RELAY_CHECK_CACHE_S);
  - the hub 5xx / unreachable / timed out (RELAY_CHECK_TIMEOUT_S, 5):
      the hub said 2xx less than RELAY_CHECK_GRACE_S ago (600) → 200, log `grace`;
      else 503, log `refused-unavailable`.
A grace pass never extends the window: only a real hub 2xx does. A pass the hub
last refused, never saw, or saw on another prefix is not in the table.

The revocation list (claude-fleet#3560, EPIC #3500 C18) comes FIRST when it is
on (a token for it): a thread follows the hub's GET /v1/relay/revocations
(held up to 25 s, answered the moment the list moves), keeps it in a file, and
every check looks there before the table above — a pass on it is 403 `revoked`
at once, whatever the cache or the grace says, and with the hub away the last
list still refuses. A relay credential is matched by `frl1:<sha256>`, a session
pass by `fcp:<id>` or a {machine, principal, before} scope against its own
(unverified — a refusal only) claims. A list older than RELAY_REVOCATIONS_STALE_S
(600) is logged `list-stale`, never a reason to refuse. Off (no token) ⇒ byte
for byte as before.

An frl2 relay pass (claude-fleet#3561, EPIC #3500 C19 — four hours, signed by
the hub) is verified HERE once the key is known — the list's `relay_pub`, else
FLEET_RELAY_PUB (base64): signature, exp, then the list (`frl2:<jti>`, or a
{machine|login|principal, before} scope against its signed claims). A good one is
200 and remembered like a hub 2xx (a list entry still refuses it first); a bad
one is 403. The hub is never asked about it — so the hub's /v1/relay/check sees
no frl2 traffic, and a hub that is down changes nothing for it. The signature is
checked with the `cryptography` package when python3 has it, else with
bin/fleet_ed25519.py installed beside this file (FLEET_RELAY_ED25519 names another).
No key known ⇒ an frl2 goes to the hub like any other pass.

An fcp-h2 session pass (claude-fleet#3698 — signed with the same key) is
verified here the same way, but only while the list is on (a session pass is
revoked by the list's `fcp:<id>` and its scopes, and the hub is not asked):
signature, exp, and the provider the route goes to among the pass's providers
(/anthropic/ → claude, /chatgpt/ and /openai-auth/ → codex; /github-oauth/ is
never a session's). No key or no list ⇒ it goes to the hub, like an fcp-h1.

What it keeps is the pass's hash and two timestamps, in memory only — never the
pass, never an Authorization (Caddy strips it before asking, and this process
forwards only X-Fleet-Relay + X-Forwarded-Uri/-Method to the hub). The log has
the event, the prefix, the hub's failure and an age — nothing that names a pass.

Environment (none is a secret):
  FLEET_HUB_URL              the hub, e.g. https://hub.example.com (required)
  FLEET_RELAY_CHECK_LISTEN   127.0.0.1:2091 (loopback only; anything else refused)
  RELAY_CHECK_CACHE_S        30    RELAY_CHECK_GRACE_S   600    RELAY_CHECK_TIMEOUT_S  5
  FLEET_RELAY_CHECK_LOG      a file to append to (default stderr → journald)
  FLEET_RELAY_CHECK_MAX_SECONDS  exit after this long (tests only)
  FLEET_RELAY_REVOCATIONS_TOKEN_FILE   the list's token (the hub's
      CCQUOTA_FLEET_REVOCATIONS_TOKEN); default $CREDENTIALS_DIRECTORY/revocations-token
      (systemd LoadCredential). The one secret here — a file, never the unit.
  FLEET_RELAY_REVOCATIONS_FILE   where the list is kept (default
      $STATE_DIRECTORY/revocations.json; none ⇒ memory only)
  RELAY_REVOCATIONS_WAIT_S 25    RELAY_REVOCATIONS_STALE_S 600    RELAY_REVOCATIONS_BACKOFF_S 5
  FLEET_RELAY_PUB            the hub's relay pass key (base64), when no list hands it over
  FLEET_RELAY_ED25519        fleet_ed25519.py's path (default: beside this file)
"""
import base64
import hashlib
import http.client
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PREFIXES = ("/anthropic/", "/chatgpt/", "/openai-auth/", "/github-oauth/")
FORWARD = ("X-Fleet-Relay", "X-Forwarded-Uri", "X-Forwarded-Method")
MAX_ENTRIES = 20000


def env_num(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        sys.exit("fleet-relay-check: %s is not a number" % name)


CACHE_S = env_num("RELAY_CHECK_CACHE_S", 30)
GRACE_S = env_num("RELAY_CHECK_GRACE_S", 600)
TIMEOUT_S = env_num("RELAY_CHECK_TIMEOUT_S", 5)
HUB = urlsplit(os.environ.get("FLEET_HUB_URL", "").rstrip("/"))
if HUB.scheme not in ("http", "https") or not HUB.hostname:
    sys.exit("fleet-relay-check: FLEET_HUB_URL must be an http(s) URL")
HUB_BASE = HUB.path or ""

_ok = {}            # key -> monotonic time of the hub's last 2xx
_lock = threading.Lock()
_log_lock = threading.Lock()
_logf = None
_hub_state = {"down": False}

REV_WAIT_S = env_num("RELAY_REVOCATIONS_WAIT_S", 25)
REV_STALE_S = env_num("RELAY_REVOCATIONS_STALE_S", 600)
# reconnect within this long: a hub that comes back is heard inside the 10 s promise
REV_BACKOFF_S = env_num("RELAY_REVOCATIONS_BACKOFF_S", 5)
# the list as last fetched: version, when (wall clock), the jti set, the scopes
_rev = {"on": False, "v": None, "at": 0.0, "jti": {}, "scopes": [], "file": "", "pub": b""}
_rev_lock = threading.Lock()
_verify = None      # (pub, msg, sig) -> bool, loaded on first need


def b64any(s):
    s = str(s or "").strip()
    try:
        if "-" in s or "_" in s:
            return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        return base64.b64decode(s + "=" * (-len(s) % 4))
    except (ValueError, TypeError):
        return b""


def ed25519_verify():
    """The signature check: the cryptography package, else fleet_ed25519.py."""
    global _verify
    if _verify is not None:
        return _verify
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        from cryptography.exceptions import InvalidSignature

        def v(pub, msg, sig):
            try:
                Ed25519PublicKey.from_public_bytes(pub).verify(sig, msg)
                return True
            except (InvalidSignature, ValueError):
                return False
        _verify = v
    except ImportError:
        import importlib.util
        here = os.path.dirname(os.path.abspath(__file__))
        path = os.environ.get("FLEET_RELAY_ED25519") or next(
            (p for p in (os.path.join(here, "fleet_ed25519.py"),                  # installed beside it
                         os.path.join(here, "..", "..", "bin", "fleet_ed25519.py"))  # the repo's
             if os.path.exists(p)), os.path.join(here, "fleet_ed25519.py"))
        try:
            spec = importlib.util.spec_from_file_location("fleet_ed25519", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _verify = lambda pub, msg, sig: bool(mod.verify(pub, msg, sig))
        except (OSError, ImportError, AttributeError) as e:
            log("ed25519-missing", path=path, why=type(e).__name__)
            _verify = False
    return _verify


def relay_pub():
    with _rev_lock:
        if _rev["pub"]:
            return _rev["pub"]
    k = b64any(os.environ.get("FLEET_RELAY_PUB", ""))
    return k if len(k) == 32 else b""


def frl2_claims(tok):
    """An frl2 pass's claims, unverified (the list's matcher), or None."""
    parts = tok.split(".")
    if len(parts) != 3 or parts[0] != "frl2":
        return None
    c = b64any(parts[1])
    try:
        c = json.loads(c)
    except (ValueError, TypeError):
        return None
    return c if isinstance(c, dict) else None


def frl2_check(tok):
    """'' when this frl2 pass is good, else why not; None when no key is known
    here (the hub's road then)."""
    pub = relay_pub()
    if not pub:
        return None
    v = ed25519_verify()
    if not v:
        return None
    body, _, sig = tok.rpartition(".")
    c = frl2_claims(tok)
    if c is None or not body or not v(pub, body.encode(), b64any(sig)):
        return "bad signature"
    try:
        if int(c.get("v") or 0) != 2 or not c.get("jti") or time.time() >= int(c.get("exp") or 0):
            return "expired"
    except (TypeError, ValueError):
        return "malformed"
    return ""


ROUTE_PROVIDER = {"/anthropic/": "claude", "/chatgpt/": "codex", "/openai-auth/": "codex"}


def fcp2_check(tok, pre):
    """'' when this fcp-h2 session pass is good for route pre, else why not;
    None when it is the hub's to judge (no key, no list here)."""
    pub = relay_pub()
    with _rev_lock:
        listed = _rev["on"] and _rev["v"] is not None
    if not pub or not listed:
        return None
    v = ed25519_verify()
    if not v:
        return None
    body, _, sig = tok.rpartition(".")
    c = pass_claims(tok)
    if c is None or not body or not v(pub, body.encode(), b64any(sig)):
        return "bad signature"
    try:
        if int(c.get("v") or 0) != 2 or not c.get("id") or time.time() >= int(c.get("exp") or 0):
            return "expired"
    except (TypeError, ValueError):
        return "malformed"
    want = ROUTE_PROVIDER.get(pre)
    if not want or want not in (c.get("providers") or []):
        return "does not cover %s" % (want or pre)
    return ""


def log(event, **kv):
    line = "%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), event,
                           " ".join("%s=%s" % (k, v) for k, v in kv.items()))
    with _log_lock:
        (_logf or sys.stderr).write(line)
        (_logf or sys.stderr).flush()


def prefix_of(uri):
    for p in PREFIXES:
        if uri.startswith(p):
            return p
    return ""


def ask_hub(headers):
    """→ (status, body) from the hub, or (None, why) when it could not answer."""
    cls = http.client.HTTPSConnection if HUB.scheme == "https" else http.client.HTTPConnection
    conn = cls(HUB.hostname, HUB.port, timeout=TIMEOUT_S)
    try:
        conn.request("GET", HUB_BASE + "/v1/relay/check", headers=headers)
        r = conn.getresponse()
        return r.status, r.read(65536)
    except (OSError, http.client.HTTPException) as e:
        return None, type(e).__name__
    finally:
        conn.close()


def rev_token():
    path = os.environ.get("FLEET_RELAY_REVOCATIONS_TOKEN_FILE", "")
    if not path and os.environ.get("CREDENTIALS_DIRECTORY"):
        path = os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "revocations-token")
    if not path or not os.path.exists(path):
        return ""
    with open(path) as f:
        return f.read().strip()


def rev_index(lst, fetched_at):
    """The list as the checks read it, or None when it is not one."""
    if not isinstance(lst, dict) or not isinstance(lst.get("v"), int) or not isinstance(lst.get("entries"), list):
        return None
    jti, scopes = {}, []
    for e in lst["entries"]:
        if not isinstance(e, dict) or not isinstance(e.get("exp"), int):
            continue
        if e.get("jti"):
            jti[str(e["jti"])] = e["exp"]
        elif e.get("machine") or e.get("principal"):
            scopes.append((str(e.get("machine") or ""), str(e.get("principal") or ""),
                           str(e.get("login") or ""), int(e.get("before") or 0), e["exp"]))
    pub = b64any(lst.get("relay_pub"))
    return {"v": lst["v"], "at": fetched_at, "jti": jti, "scopes": scopes, "pub": pub if len(pub) == 32 else b""}


def rev_set(lst, fetched_at, persist=True):
    idx = rev_index(lst, fetched_at)
    if idx is None:
        return False
    with _rev_lock:
        moved = idx["v"] != _rev["v"]
        _rev.update(idx)
    if moved:
        log("list", v=idx["v"], entries=len(idx["jti"]) + len(idx["scopes"]))
    if persist and _rev["file"]:
        tmp = _rev["file"] + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump({"fetched_at": fetched_at, "list": lst}, f)
            os.replace(tmp, _rev["file"])
        except OSError as e:
            log("list-keep-failed", why=type(e).__name__)
    return True


def machine_of(m):
    return (m or "").strip().split(".")[0].lower()


def pass_claims(tok):
    """An fcp-h1 / fcp-h2 pass's claims, unverified (to refuse; fcp2_check
    verifies an fcp-h2's before it lets one by)."""
    parts = tok.split(".")
    if len(parts) != 3 or parts[0] not in ("fcp-h1", "fcp-h2"):
        return None
    try:
        c = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
    except (ValueError, TypeError):
        return None
    return c if isinstance(c, dict) else None


def revoked(tok):
    """'' when the list lets tok by, else what it matched (for the log)."""
    with _rev_lock:
        if not _rev["on"] or _rev["v"] is None:
            return ""
        jti, scopes = _rev["jti"], _rev["scopes"]
    now = time.time()
    if tok.startswith("frl1."):
        exp = jti.get("frl1:" + hashlib.sha256(tok.encode()).hexdigest())
        return "frl1" if exp is not None and exp > now else ""
    if tok.startswith("frl2."):
        c, kind, lg = frl2_claims(tok), "frl2", None
        if c is None:
            return ""
        lg = str(c.get("login") or "")
    else:
        c, kind, lg = pass_claims(tok), "fcp", None
        if c is None:
            return ""
    exp = jti.get(kind + ":" + str(c.get("jti" if kind == "frl2" else "id") or ""))
    if exp is not None and exp > now:
        return kind
    m, p = machine_of(str(c.get("machine") or "")), str(c.get("principal") or "")
    try:
        iat = int(c.get("iat") or 0)
    except (TypeError, ValueError):
        iat = 0
    for sm, sp, sl, before, sexp in scopes:
        if sexp <= now or (sl and lg is None) or (sl and sl != lg) or (sm and sm != m) or (sp and sp != p):
            continue   # a login scope cannot be told from a session pass's claims (an frl2 names its login)
        if iat < before:
            return "scope"
    return ""


def rev_follow(token):
    """The list follower: ask with the version held, wait, apply, repeat."""
    back = 1.0
    stale_said = 0.0
    cls = http.client.HTTPSConnection if HUB.scheme == "https" else http.client.HTTPConnection
    while True:
        v = _rev["v"]
        q = "?since=%d&wait=%d" % (v, int(REV_WAIT_S)) if v is not None else ""
        conn = cls(HUB.hostname, HUB.port, timeout=REV_WAIT_S + 10)
        why = ""
        try:
            conn.request("GET", HUB_BASE + "/v1/relay/revocations" + q,
                         headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
            r = conn.getresponse()
            body = r.read(8 << 20)
            if r.status == 200:
                if not rev_set(json.loads(body.decode("utf-8")), time.time()):
                    why = "not-a-list"
            elif r.status == 304:
                with _rev_lock:
                    _rev["at"] = time.time()
            else:
                why = "http-%d" % r.status
        except (OSError, http.client.HTTPException, ValueError) as e:
            why = type(e).__name__
        finally:
            conn.close()
        age = time.time() - (_rev["at"] or 0)
        if age > REV_STALE_S and time.time() - stale_said >= 60:
            stale_said = time.time()
            log("list-stale", v=_rev["v"] if _rev["v"] is not None else "-", age="%ds" % int(age) if _rev["at"] else "never",
                hub=why or "-")
        if why:
            time.sleep(back)
            back = min(back * 2, REV_BACKOFF_S)
        else:
            back = 1.0


def rev_start():
    token = rev_token()
    if not token:
        return
    st = os.environ.get("STATE_DIRECTORY", "").split(":")[0]
    _rev["file"] = os.environ.get("FLEET_RELAY_REVOCATIONS_FILE") or (os.path.join(st, "revocations.json") if st else "")
    _rev["on"] = True
    if _rev["file"] and os.path.exists(_rev["file"]):
        try:
            with open(_rev["file"]) as f:
                kept = json.load(f)
            rev_set(kept.get("list"), float(kept.get("fetched_at") or 0), persist=False)
        except (OSError, ValueError, AttributeError) as e:
            log("list-unreadable", why=type(e).__name__)
    threading.Thread(target=rev_follow, args=(token,), name="revocations", daemon=True).start()


def hub_mark(down, why=""):
    if down != _hub_state["down"]:
        _hub_state["down"] = down
        log("hub-down" if down else "hub-up", why=why or "-")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Cache-Control", "no-store")
        if body:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, b"ok", "text/plain")
        tok = (self.headers.get("X-Fleet-Relay") or "").strip()
        pre = prefix_of(self.headers.get("X-Forwarded-Uri") or "")
        key = hashlib.sha256(tok.encode()).hexdigest() + "\0" + pre if tok and pre else None
        now = time.monotonic()
        hit = revoked(tok) if tok else ""
        if hit:
            with _lock:
                _ok.pop(key, None)
            log("revoked", prefix=pre or "-", by=hit, v=_rev["v"])
            return self.reply(403, b'{"error":"relay_refused","message":"this pass was revoked"}')
        if key is not None:
            with _lock:
                t = _ok.get(key)
            if t is not None and now - t < CACHE_S:
                return self.reply(200)
        if tok.startswith("frl2.") and pre:
            why = frl2_check(tok)
            if why is not None:   # verified here; the hub is not asked (#3561)
                if why:
                    with _lock:
                        _ok.pop(key, None)
                    log("refused", prefix=pre, kind="frl2", why=why.replace(" ", "-"))
                    return self.reply(403, json.dumps({"error": "relay_refused", "message": "relay pass: " + why}).encode())
                with _lock:
                    if key not in _ok and len(_ok) >= MAX_ENTRIES:
                        self.prune(now)
                    _ok[key] = now
                return self.reply(200)
        if tok.startswith("fcp-h2.") and pre:
            why = fcp2_check(tok, pre)
            if why is not None:   # verified here, with the list; the hub is not asked (#3698)
                if why:
                    with _lock:
                        _ok.pop(key, None)
                    log("refused", prefix=pre, kind="fcp-h2", why=why.replace(" ", "-"))
                    return self.reply(403, json.dumps({"error": "relay_refused", "message": "session pass: " + why}).encode())
                with _lock:
                    if key not in _ok and len(_ok) >= MAX_ENTRIES:
                        self.prune(now)
                    _ok[key] = now
                return self.reply(200)
        hdrs = {k: self.headers[k] for k in FORWARD if self.headers.get(k) is not None}
        status, body = ask_hub(hdrs)
        if status is not None and status < 500:
            hub_mark(False)
            if key is not None:
                with _lock:
                    if 200 <= status < 300:
                        if key not in _ok and len(_ok) >= MAX_ENTRIES:
                            self.prune(now)
                        _ok[key] = now
                    else:
                        _ok.pop(key, None)
            return self.reply(status if status >= 200 else 502, body if status >= 300 else b"")
        why = "http-%d" % status if status is not None else body
        hub_mark(True, why)
        with _lock:
            t = _ok.get(key) if key is not None else None
        if t is not None and now - t < GRACE_S:
            log("grace", prefix=pre, hub=why, age="%ds" % int(now - t))
            return self.reply(200)
        log("refused-unavailable", prefix=pre or "-", hub=why,
            seen="expired" if t is not None else "no")
        return self.reply(503, b'{"error":"relay_check_unavailable","message":"the hub cannot check this pass right now"}')

    @staticmethod
    def prune(now):
        # under _lock: drop what can no longer pass; still full → the oldest half
        for k in [k for k, t in _ok.items() if now - t >= GRACE_S]:
            del _ok[k]
        if len(_ok) >= MAX_ENTRIES:
            for k, _ in sorted(_ok.items(), key=lambda kv: kv[1])[: MAX_ENTRIES // 2]:
                del _ok[k]


def main():
    global _logf
    listen = os.environ.get("FLEET_RELAY_CHECK_LISTEN", "127.0.0.1:2091")
    host, _, port = listen.rpartition(":")
    if host not in ("127.0.0.1", "localhost", "::1", "[::1]"):
        sys.exit("fleet-relay-check: listens on loopback only, not %s" % listen)
    if os.environ.get("FLEET_RELAY_CHECK_LOG"):
        _logf = open(os.environ["FLEET_RELAY_CHECK_LOG"], "a")
    if os.environ.get("FLEET_RELAY_CHECK_MAX_SECONDS"):
        signal.alarm(int(float(os.environ["FLEET_RELAY_CHECK_MAX_SECONDS"])))
    ThreadingHTTPServer.daemon_threads = True
    srv = ThreadingHTTPServer((host.strip("[]"), int(port)), H)
    rev_start()
    log("start", listen=listen, hub=HUB.hostname, cache="%gs" % CACHE_S, grace="%gs" % GRACE_S,
        **({"revocations": "on"} if _rev["on"] else {}))
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    srv.serve_forever()


if __name__ == "__main__":
    main()
