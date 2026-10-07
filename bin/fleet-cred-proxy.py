#!/usr/bin/env python3
"""fleet-cred-proxy.py — this login's credential proxy (issue #1970, EPIC #1967 C3).

A session never holds a subscription credential: it holds a SESSION credential
and talks to this proxy on loopback; the proxy picks a ROUTE and sends the
request on, with the real credential put in on the way out (or none, centrally).

    serve   [--state DIR] [--port N] [--max-seconds N] [--parent-watch]
    route   [--provider claude|codex] [--refresh] [--json]   → {route, reason, …}
    mint    --account LABEL [--sid NAME] [--ttl SECS] [--wrap PID]
                                                            → fcp1.<…> on stdout
    rebind  --sid NAME --account LABEL                      (next request, no restart)
    revoke  --sid NAME
    attach  --sid NAME          (a hub session credential, fcp-h1.…, on STDIN —
                                 what the central route forwards for this sid)
    status  [--json]
    quota                       → {sid: the last rate-limit reading} as JSON
                                 (issue #1978 — bin/fleet-proxy-quota.sh stamps it)
    store   --kind claude|codex --label LABEL   (the file's bytes on STDIN — the
                                 node agent's lease, separated mode only)
    probe                       (node-probe.json on STDIN — separated mode only)
    node-token                  → a short-lived fcpn1.<…> for the hub broker
    node-hash                   → sha256 hex of the node token (the fleet-mcp
                                 worker assertion's key; the token never leaves)

`serve` binds 127.0.0.1 (the port in <state>/port) and a control socket
<state>/ctl.sock (0600); every other subcommand is a client of that socket.
<state> is $FLEET_CONF_DIR/cred-proxy. bin/fleet-cred-proxy.sh is the launcher
(launchd / systemd run it; it reads fleet.conf and honours FLEET_CRED_PROXY).

QUOTA READINGS (issue #1978): every answer the provider sends carries the
account's rate-limit windows — Claude `anthropic-ratelimit-unified-{5h,7d}-
{utilization,reset}`, Codex `x-codex-{primary,secondary}-{used-percent,
window-minutes,reset-at}`. The proxy keeps the newest one per session (memory
only; no credential in it) and answers it on ctl `quota`;
bin/fleet-proxy-quota.sh hands each to `conf/statusline.sh --from proxy` on the
window whose @cred_sid it is. Not separated, a fresh reading also kicks
FLEET_CRED_QUOTA_PUSH (the launcher points it at that script; empty = off),
at most once per FLEET_CRED_QUOTA_PUSH_SECS (2).

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

A SESSION CREDENTIAL OUTLIVES ITS STAMP WHILE ITS SESSION LIVES (issue #1975):
the session cannot swap the credential in its environment, so the proxy does
the renewing. An fcp1. minted with --wrap PID stays good past its exp while that
process (the session's wrapper) lives and the sid is not revoked, at most
FLEET_CRED_PROXY_RENEW_MAX_SECS (7 days) past it. A hub pass (fcp-h1.) is
renewed with the hub (POST /v1/fleet/session-cred/renew, the node token) once
it reaches its renew point — 2h before exp, or half-life for a short one — on
the session's next request or the background tick, whichever comes first; the
session keeps sending the pass it was born with and the proxy forwards the
newest one it holds for that id (<state>/hub-passes.json, 0600). A pass the hub
refuses (revoked, the session over) is dropped; any other failure is counted in
`status` (renew.hub_err, the doctor's `cred` row).

Rails (共同约定 4/5): loopback + unix socket only; only Authorization is
rewritten (Claude: x-api-key dropped; Codex: chatgpt-account-id overwritten),
the body passes byte for byte, responses stream chunk by chunk; a refusal reads
the request body first; a permanent failure (no credential for the account,
an untrusted machine with no hub credential) answers 403, which neither Claude
Code nor Codex retries; every credential-shaped header is logged as
<redacted:len>.

SEPARATED MODE (issue #1971, EPIC #1967 C4 — bin/fleet-credsep.sh): the proxy
runs as the role account _fleetcred, launched by bin/fleet-credsep-launch.py,
and every credential lives under /var/db/fleet-cred/<login>/ (0700, its own):
FLEET_CRED_ACCOUNTS / FLEET_CRED_CODEX_* / FLEET_CRED_NODE_ENV point there. The
control socket moves to FLEET_CRED_CTL_DIR (/var/run/fleet-cred/<login>/, which
the login can read) at mode 0666, and FLEET_CRED_CTL_UID is then the ONE peer
uid it answers (getpeereid — no group to manage). Three more things only make
sense there: `store` (the agent hands its lease over instead of writing a file
the session could read), `probe`, and the HUB BROKER — /hub/<path> forwards to
the hub with the node token put in, for a fcpn1. credential minted over the
control socket. The broker refuses POST /v1/node/credentials: a session that
asks for the node token gets something that can place, move and lease issues,
never something that can lease the subscription pool (EPIC route ④).

PER-PERSON BUDGET (issue #1977, EPIC #1967 R2): every 2xx answer sent with a
credential of this login (direct / relay) is metered off its own `usage`
(input + cache writes + output — cache reads are left out) and reported to the
hub every FLEET_CRED_BUDGET_SECS (15) as POST /v1/node/usage with the node
token; the hub files it under the login's person and answers their standing
against fleet.person_budget.<principal>. Over it, every request is refused 403
with error.code person_budget_exceeded and the hub's line (「已达个人额度…」) —
neither client retries a 403. The central route is metered by the cluster
proxy, never twice here. No hub / no node token / FLEET_CRED_BUDGET=0 = nothing
reported, nothing refused; a verdict the hub has not renewed for
FLEET_CRED_BUDGET_STALE (600 s) lapses (open).
"""
import argparse, base64, fcntl, hashlib, hmac, http.client, json, os, secrets
import resource, signal, socket, ssl, sys, threading, time, urllib.error, urllib.request
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET_HEADERS = {"authorization", "x-api-key", "cookie", "set-cookie",
                  "chatgpt-account-id", "proxy-authorization", "x-fleet-relay"}
HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding",
       "te", "trailer", "upgrade", "host", "content-length"}
PUBLIC = {"/api/hello"}
OAUTH_BETA = "oauth-2025-04-20"
LOCAL_TAG, HUB_TAG, NODE_TAG = "fcp1", "fcp-h1", "fcpn1"
# never through the hub broker (EPIC #1967 route ④): the subscription pool
HUB_DENY = ("/v1/node/credentials",)
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
        for line in open(env("FLEET_CRED_NODE_ENV", os.path.join(conf_dir(), "node.env"))):
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


# ---- per-person budget (issue #1977) ------------------------------------------
BUDGET_CODE = "person_budget_exceeded"


class Meter:
    """What one answer says it used: the largest value each usage field
    reached (Claude: message_start + message_delta; Codex: response.completed;
    a plain JSON body: once). Mirrors tokenledger internal/credproxy usage.go."""
    MAX_WHOLE = 8 << 20

    def __init__(self):
        self.line, self.whole, self.sse, self.f = bytearray(), bytearray(), False, {}

    def feed(self, d):
        if not self.sse and len(self.whole) < self.MAX_WHOLE:
            self.whole += d
        parts = d.split(b"\n")
        for i, p in enumerate(parts):
            if len(self.line) < (1 << 20):
                self.line += p
            if i < len(parts) - 1:
                self.on_line(bytes(self.line)); self.line = bytearray()

    def on_line(self, l):
        l = l.strip()
        if l.startswith(b"event:"):
            self.sse, self.whole = True, bytearray()
        if not l.startswith(b"data:"):
            return
        self.sse, self.whole = True, bytearray()
        try:
            self.take(json.loads(l[5:].strip()))
        except ValueError:
            pass

    def take(self, v):
        if not isinstance(v, dict):
            return
        for u in (v.get("usage"), (v.get("message") or {}).get("usage") if isinstance(v.get("message"), dict) else None,
                  (v.get("response") or {}).get("usage") if isinstance(v.get("response"), dict) else None):
            if not isinstance(u, dict):
                continue
            for k, x in u.items():
                if isinstance(x, (int, float)) and not isinstance(x, bool) and x > self.f.get(k, 0):
                    self.f[k] = int(x)
            det = u.get("input_tokens_details")
            if isinstance(det, dict) and isinstance(det.get("cached_tokens"), (int, float)):
                self.f["cached_tokens"] = max(self.f.get("cached_tokens", 0), int(det["cached_tokens"]))

    def tokens(self):
        if not self.sse and self.whole:
            try:
                self.take(json.loads(bytes(self.whole)))
            except ValueError:
                pass
            self.whole = bytearray()
        g = self.f.get
        return (max(0, g("input_tokens", 0) - g("cached_tokens", 0)) + g("cache_creation_input_tokens", 0)
                + g("output_tokens", 0) + g("prompt_tokens", 0) + g("completion_tokens", 0))


class Budget:
    """This login's person's standing, as the hub last said, and what is still
    to be reported."""

    def __init__(self):
        self.lock = threading.Lock()
        self.pending = {}            # provider -> [tokens, requests]
        self.state, self.ts, self.err = {}, 0, ""

    def add(self, provider, tokens):
        if tokens <= 0:
            return
        with self.lock:
            p = self.pending.setdefault(provider, [0, 0])
            p[0] += tokens; p[1] += 1

    def over(self):
        """-> the hub's line when the person is over (and the word is fresh), else ""."""
        stale = int(env("FLEET_CRED_BUDGET_STALE", "600"))
        with self.lock:
            if self.state.get("over") and time.time() - self.ts < stale:
                return self.state.get("message") or "已达个人额度（%s）" % BUDGET_CODE
        return ""

    def flush(self, log=None):
        """POST the pending usage (none = just ask); keep it on failure."""
        if env("FLEET_CRED_BUDGET", "1") == "0":
            return None
        ne = node_env()
        hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        tok = ne.get("CCQUOTA_TOKEN", "")
        if not hub or not tok or not loopback_ok(hub):
            return None
        with self.lock:
            sent = {k: list(v) for k, v in self.pending.items()}
        body = json.dumps({"usage": [{"provider": k, "tokens": v[0], "requests": v[1]} for k, v in sorted(sent.items())]}).encode()
        try:
            req = urllib.request.Request(hub + "/v1/node/usage", data=body, method="POST",
                                         headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                st = json.loads(r.read() or b"{}")
        except Exception as e:
            with self.lock:
                self.err = type(e).__name__
            return None
        with self.lock:
            for k, (t, n) in sent.items():
                p = self.pending.get(k)
                if p:
                    p[0] -= t; p[1] -= n
                    if p[0] <= 0 and p[1] <= 0:
                        del self.pending[k]
            was = bool(self.state.get("over"))
            self.state, self.ts, self.err = st if isinstance(st, dict) else {}, time.time(), ""
            now_over = bool(self.state.get("over"))
        if log and was != now_over:
            log(ev="budget", over=now_over, principal=self.state.get("principal", ""),
                window=self.state.get("window", ""), used_5h=self.state.get("used_5h", 0),
                used_week=self.state.get("used_week", 0))
        return self.state

    def view(self):
        with self.lock:
            s = dict(self.state)
            out = {k: s.get(k) for k in ("principal", "over", "window", "used_5h", "limit_5h",
                                         "used_week", "limit_week", "message") if k in s}
            out.update(age=int(time.time() - self.ts) if self.ts else None, err=self.err,
                       pending=sum(v[0] for v in self.pending.values()))
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

    def mint(self, account, sid, ttl, tag=LOCAL_TAG):
        payload = json.dumps({"sid": sid, "acct": account, "exp": int(time.time()) + ttl,
                              "n": secrets.token_hex(4)}, separators=(",", ":")).encode()
        return tag + "." + b64e(payload) + "." + b64e(hmac.new(self.key, payload, hashlib.sha256).digest())

    def verify(self, tok, want=LOCAL_TAG, live=None):
        """-> (claims, None) or (None, reason). `live(claims)` true = an expired
        credential whose session still runs: good (issue #1975)."""
        try:
            tag, p, s = tok.split(".")
            if tag != want:
                return None, "not a session credential"
            payload = b64d(p)
            if not hmac.compare_digest(hmac.new(self.key, payload, hashlib.sha256).digest(), b64d(s)):
                return None, "bad signature"
            c = json.loads(payload)
        except Exception:
            return None, "malformed session credential"
        if c.get("sid") in read_lines(os.path.join(self.state, "revoked")):
            return None, "session credential revoked"
        if c.get("exp", 0) < time.time():
            if not (live and live(c)):
                return None, "session credential expired"
            c["renewed"] = True
        return c, None


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        return True     # another uid's (separated mode): it exists
    except (OSError, ValueError, TypeError):
        return False
    return True


def hub_claims(tok):
    """The claims of a hub pass (fcp-h1.<claims>.<sig>), read, NOT verified —
    only the hub can; the proxy needs the id and the clock."""
    try:
        c = json.loads(b64d(tok.split(".")[1]))
        return c if c.get("id") and int(c.get("exp", 0)) > 0 else None
    except Exception:
        return None


class HubPasses:
    """The newest hub pass the proxy holds per pass id, renewed at its renew
    point (issue #1975). The session's own pass is the key; what goes out is
    whichever of the two lives longer."""

    def __init__(self, state):
        self.path = os.path.join(state, "hub-passes.json")
        self.lock = threading.Lock()
        self.busy = set()
        self.held = read_json(self.path, {})
        self.stats = {"ok": 0, "err": 0, "dropped": 0, "local": 0,
                      "last_ok": 0, "last_err": 0, "err_why": ""}
        self.backoff = {}

    @staticmethod
    def renew_at(c):
        iat, exp = int(c.get("iat") or 0), int(c["exp"])
        return max(exp - 7200, iat + (exp - iat) // 2) if iat else exp - 7200

    def save(self):
        try:
            write_json(self.path, self.held)
        except OSError:
            pass

    def best(self, tok):
        """-> the pass to forward for this session's `tok`, renewed when due."""
        c = hub_claims(tok)
        if not c:
            return tok
        pid = c["id"]
        with self.lock:
            have = self.held.get(pid, "")
            hc = hub_claims(have) if have else None
            if not hc or hc["exp"] < c["exp"]:
                self.held[pid], hc, have = tok, c, tok
                self.save()
        if time.time() >= self.renew_at(hc):
            have = self.renew(pid) or have
        return have

    def renew(self, pid, log=None):
        log = log or Proxy.log
        now = time.time()
        with self.lock:
            cur = self.held.get(pid, "")
            if not cur or pid in self.busy or self.backoff.get(pid, 0) > now:
                return None
            self.busy.add(pid)
        try:
            ne = node_env()
            hub, tok = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/"), ne.get("CCQUOTA_TOKEN", "")
            if not hub or not tok:
                raise RuntimeError("no hub / node token here")
            req = urllib.request.Request(hub + "/v1/fleet/session-cred/renew", method="POST",
                                         data=json.dumps({"cred": cur}).encode(),
                                         headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as r:
                    new = (json.loads(r.read() or b"{}").get("cred") or "").strip()
            except urllib.error.HTTPError as e:
                if e.code in (403, 404):
                    # the hub says this pass is over (revoked, ran out, not ours): so is the session
                    with self.lock:
                        self.held.pop(pid, None); self.save()
                        self.stats["dropped"] += 1
                    log(ev="renew_drop", kind="hub", pass_id=pid, status=e.code)
                    return None
                raise RuntimeError("hub answered %d" % e.code)
            nc = hub_claims(new)
            if not new.startswith(HUB_TAG + ".") or not nc or nc["id"] != pid:
                raise RuntimeError("the hub's answer carries no pass")
            with self.lock:
                self.held[pid] = new; self.save()
                self.stats["ok"] += 1; self.stats["last_ok"] = int(time.time())
            log(ev="renew", kind="hub", pass_id=pid, exp=nc["exp"])
            return new
        except Exception as e:
            why = str(e) if isinstance(e, RuntimeError) else type(e).__name__
            with self.lock:
                self.stats["err"] += 1; self.stats["last_err"] = int(time.time()); self.stats["err_why"] = why
                self.backoff[pid] = time.time() + 30
            log(ev="renew_err", kind="hub", pass_id=pid, err=why)
            return None
        finally:
            with self.lock:
                self.busy.discard(pid)

    def tick(self):
        """Renew every held pass that is due; forget the ones long over."""
        now = time.time()
        with self.lock:
            items = list(self.held.items())
        gone = False
        for pid, tok in items:
            c = hub_claims(tok)
            if not c or c["exp"] < now - 86400:
                with self.lock:
                    self.held.pop(pid, None)
                gone = True
            elif c["exp"] > now and now >= self.renew_at(c):
                self.renew(pid)
        if gone:
            with self.lock:
                self.save()


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


def live_session(state):
    """-> live(claims): an expired fcp1 whose session (its --wrap pid) still runs."""
    def live(c):
        if time.time() > c.get("exp", 0) + int(env("FLEET_CRED_PROXY_RENEW_MAX_SECS", str(7 * 86400))):
            return False
        pid = read_json(os.path.join(state, "live.json"), {}).get(c.get("sid", ""))
        return bool(pid) and pid_alive(pid)
    return live


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
        d = read_json(env("FLEET_CRED_PROBE", os.path.join(conf_dir(), "node-probe.json")), None)
        if not isinstance(d, dict):
            return "none"
        return str(d.get("anthropic" if provider == "claude" else "openai", "none")) or "none"

    def candidates(self, provider, has_hub_cred):
        """-> ([route, …] best first, reason)."""
        with self.lock:
            trust, twhy = self.trust or "unknown", self.trust_why
        relay = bool(self.cfg.relay_url and relay_pass(self.cfg))
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
                why += (", no relay pass (fleet-relay-cred.sh fetch)" if self.cfg.relay_url
                        else ", no relay configured (FLEET_CRED_RELAY_URL)")
        if has_hub_cred:
            order.append("central")
        return order, why


# ---- the proxy ---------------------------------------------------------------
class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    cfg = keys = router = passes = None
    budget = Budget()
    lock = threading.Lock()
    extended = set()   # sids whose fcp1 is past its stamp, kept by a live session
    skip = {}       # sid -> {route: (until, why)}: a route that refused this session
    hubcreds = {}   # sid -> fcp-h1.… handed in over ctl `attach` (memory only)
    quota = {}      # sid -> its newest rate-limit reading (issue #1978; memory only)
    push_due = False

    @classmethod
    def note_quota(cls, sid, provider, acct, route, headers):
        """Keep this answer's rate-limit reading for its session, then kick the push."""
        if sid in ("-", "node"):
            return
        rd = rl_reading(provider, headers)
        if not rd:
            return
        rd.update(provider=provider, acct=acct, route=route, ts=int(time.time()))
        with cls.lock:
            cls.quota[sid] = rd
            if len(cls.quota) > 4096:   # a day of dead sessions, at most: oldest out
                for k in sorted(cls.quota, key=lambda k: cls.quota[k]["ts"])[:len(cls.quota) - 4096]:
                    del cls.quota[k]
            # separated, the proxy is another uid: it cannot reach the login's tmux,
            # so the quota watch's tick pulls instead (fleet-proxy-quota.sh push)
            kick = bool(cls.cfg.quota_push) and not cls.cfg.store and not cls.push_due
            cls.push_due = cls.push_due or kick
        if kick:
            t = threading.Timer(cls.cfg.quota_push_secs, cls.run_push)
            t.daemon = True
            t.start()

    @classmethod
    def run_push(cls):
        with cls.lock:
            cls.push_due = False
        try:
            import subprocess
            subprocess.Popen([cls.cfg.quota_push, "push"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            cls.log(ev="quota_push_err", err=type(e).__name__)

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

    def fail(self, code, msg, typ="authentication_error", ecode=""):
        err = {"type": typ, "message": "cred-proxy: " + msg}
        if ecode:
            err["code"] = ecode
        body = json.dumps({"type": "error", "error": err}, ensure_ascii=False).encode()
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
        if path.startswith("/hub/"):
            return self.hub_broker(inbound, path[len("/hub"):], body, t0)
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
            return self.send(["central"], provider, path, body, self.passes.best(tok), sid, "-", seen, t0)
        claims, why = self.keys.verify(tok, live=live_session(self.cfg.state))
        if not claims:
            self.log(ev="deny", path=path.split("?")[0], why=why, hdrs=seen)
            return self.fail(401, why)
        sid = claims["sid"]
        if claims.get("renewed"):
            with self.lock:
                first = sid not in self.extended
                self.extended.add(sid)
            if first:
                self.passes.stats["local"] += 1
                self.log(ev="renew", kind="local", sid=sid)
        acct = read_json(os.path.join(self.cfg.state, "bind.json"), {}).get(sid, claims["acct"])
        hubcred = self.hubcreds.get(sid)
        if hubcred:
            hubcred = self.passes.best(hubcred)
        order, _ = self.router.candidates(provider, bool(hubcred))
        self.send(order, provider, path, body, hubcred, sid, acct, seen, t0)

    def hub_broker(self, inbound, path, body, t0):
        """/hub/<path> → the hub, with the node token put in (separated mode only)."""
        tok = inbound.get("authorization", "")[7:].strip() if inbound.get("authorization", "").lower().startswith("bearer ") else ""
        bare = path.split("?")[0].rstrip("/")
        if not self.cfg.broker:
            return self.fail(404, "no hub broker here (not separated)", "not_found_error")
        claims, why = self.keys.verify(tok, NODE_TAG)
        if not claims:
            self.log(ev="deny", path="/hub" + bare, why=why)
            return self.fail(401, why)
        import posixpath
        if not bare.startswith("/v1/") or "%" in bare or "\\" in bare or posixpath.normpath(bare) != bare:
            # one spelling per path: no //, ./, ../ or escapes to slip past HUB_DENY
            self.log(ev="deny", path="/hub" + bare, why="not a plain /v1/ path")
            return self.fail(403, "the broker forwards plain /v1/ paths only", "permission_error")
        if any(bare.lower() == d or bare.lower().startswith(d + "/") for d in HUB_DENY):
            self.log(ev="deny", path="/hub" + bare, why="the subscription pool never goes through the broker")
            return self.fail(403, "%s is not brokered: the subscription pool stays with the node agent" % bare,
                             "permission_error")
        ne = node_env()
        hub, ntok = (ne.get("CCQUOTA_HUB_URL") or "").rstrip("/"), ne.get("CCQUOTA_TOKEN", "")
        if not hub or not ntok:
            return self.fail(403, "no node token here", "permission_error")
        if not loopback_ok(hub):
            return self.fail(403, "hub URL is neither https nor loopback", "permission_error")
        out = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() != "authorization"}
        out["Authorization"] = "Bearer " + ntok
        self.upstream(hub, urlsplit(hub).path.rstrip("/") + path, out, body, "hub", "node", "-", "node",
                      [], t0, "hub", can_switch=False)

    def plan(self, order, sid):
        """-> (routes, skipped): drop the routes that refused this session
        recently (all of them = try again); `skipped` says why, for a refusal."""
        now = time.time()
        with self.lock:
            sk = {r: u for r, u in self.skip.get(sid, {}).items() if u[0] > now}
            self.skip[sid] = sk
        left = [r for r in order if r not in sk]
        if not left:
            return order, []
        return left, ["%s: %s %ds ago, skipped" % (r, sk[r][1], now - sk[r][0] + self.cfg.switch_ttl)
                      for r in order if r in sk]

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
            put["X-Fleet-Relay"] = relay_pass(c)
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
        over = "" if public else self.budget.over()
        if over:
            # the person is over their budget (issue #1977): 403, never retried
            self.log(ev="deny", sid=sid, acct=acct, path=path.split("?")[0], why=BUDGET_CODE)
            return self.fail(403, over, "permission_error", BUDGET_CODE)
        order, skipped = self.plan(order, sid)
        order = [r for r in order
                 if (r != "relay" or (self.cfg.relay_url and relay_pass(self.cfg))) and (r != "central" or (self.cfg.central_url and hubcred))]
        if not order:
            # permanent: 403, which neither client retries (never a 503)
            self.log(ev="deny", sid=sid, path=path.split("?")[0], why="no usable route")
            return self.fail(403, "this machine routes central (untrusted) and this session has no "
                             "hub session credential (or no central proxy is configured)", "permission_error")
        last, tried = None, list(skipped)
        for i, route in enumerate(order):
            try:
                base, upath, put, drop, cred = self.target(route, provider, path, acct, hubcred, public)
            except (OSError, KeyError, ValueError, TypeError) as e:
                self.log(ev="nocred", sid=sid, acct=acct, route=route, err=type(e).__name__)
                last = (403, "no upstream credential for account %s" % acct, "permission_error")
                tried.append("%s: no credential for %s" % (route, acct))
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
                                can_switch=nxt is not None, tried=tried)
            if res is None:
                return
            tried.append("%s: %s" % (route, res))
            # a region refusal / a connection that never opened: next route, same request
            with self.lock:
                self.skip.setdefault(sid, {})[route] = (time.time() + self.cfg.switch_ttl, res)
            self.log(ev="route_switch", sid=sid, acct=acct, provider=provider, frm=route, to=nxt, why=res)
        code, msg, typ = last or (502, "no route answered", "api_error")
        self.fail(code, msg, typ)

    def upstream(self, base, upath, out, body, route, sid, acct, cred, seen, t0, provider, can_switch, tried=()):
        """Send one request. None = answered (the response went to the client);
        a reason string = switch routes (only when can_switch). On the LAST
        route after others failed (`tried`), a refusal of the same kind is the
        proxy's own answer naming every road (issue #1975) — never the
        upstream's bare "Request not allowed"."""
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
            self.fail(502, "upstream %s unreachable: %s%s" % (route, type(e).__name__,
                      "".join("; " + t for t in tried)), "api_error")
            return None
        try:
            conn.request(self.command, upath, body=body, headers=out)
            r = conn.getresponse()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, route=route, phase="request", err=type(e).__name__)
            self.fail(502, "upstream %s: %s" % (route, type(e).__name__), "api_error")
            return None
        ttfb = time.time() - t0
        if provider in ("claude", "codex"):
            self.note_quota(sid, provider, acct, route, r.getheaders())
        first = b""
        if r.status == 403:
            first = r.read(65536)
            if any(m in first.decode("utf-8", "replace").lower() for m in REGION_MARKS):
                if can_switch:
                    conn.close()
                    return "region refusal (403)"
                if tried:
                    conn.close()
                    self.log(ev="deny", sid=sid, path=self.path.split("?")[0], why="every route refused",
                             tried=list(tried) + ["%s: region refusal (403)" % route])
                    self.fail(403, "no route can reach the provider from here: %s; %s: region refusal (403)"
                              % ("; ".join(tried), route), "permission_error")
                    return None
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
        # metered here only when this login's credential was used (issue #1977):
        # the central route's answer is the cluster proxy's to count
        meter = Meter() if cred == "file" and 200 <= r.status < 300 else None
        try:
            if chunked:
                d = first
                while True:
                    if d:
                        size += len(d)
                        if meter:
                            meter.feed(d)
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(d), d)); self.wfile.flush()
                    d = r.read1(65536)
                    if not d:
                        break
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except OSError:
            pass
        conn.close()
        extra = {}
        if meter:
            extra["tokens"] = meter.tokens()
            self.budget.add(provider, extra["tokens"])
        self.log(ev="fwd", sid=sid, acct=acct, route=route, cred=cred, provider=provider,
                 m=self.command, path=self.path.split("?")[0], up=u.netloc, status=r.status,
                 ttfb_ms=int(ttfb * 1000), total_ms=int((time.time() - t0) * 1000), bytes=size,
                 hdrs_in=seen, sent=sorted(k.lower() for k in out), **extra)
        return None


def _num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return x if x == x and x not in (float("inf"), float("-inf")) else None


def rl_reading(provider, headers, now=None):
    """The rate-limit windows on one upstream answer, on the bus's scale (issue
    #1978): {"rl5h", "rl7d", "rl_reset5", "rl_reset7"} — percents as decimal
    strings (Claude's fraction × 100, ccquota's Utilization; never rounded here:
    conf/statusline.sh is the one place that floors) and epoch-second resets
    ("-" when absent) — or None when either window is missing: a half reading
    is no reading (the quota watch's rule)."""
    h = {k.lower(): v for k, v in headers}
    now = int(now or time.time())
    if provider == "codex":
        wins = []
        for w in ("primary", "secondary"):
            pct = _num(h.get("x-codex-%s-used-percent" % w))
            if pct is None:
                return None
            mins = _num(h.get("x-codex-%s-window-minutes" % w))
            rs = _num(h.get("x-codex-%s-reset-at" % w))
            if rs is None and _num(h.get("x-codex-%s-reset-after-seconds" % w)) is not None:
                rs = now + _num(h.get("x-codex-%s-reset-after-seconds" % w))
            wins.append((mins, pct, rs))
        # primary is the short window; trust the minutes when both say otherwise
        if wins[0][0] is not None and wins[1][0] is not None and wins[0][0] > wins[1][0]:
            wins.reverse()
        (_, p5, r5), (_, p7, r7) = wins
    else:
        p5 = _num(h.get("anthropic-ratelimit-unified-5h-utilization"))
        p7 = _num(h.get("anthropic-ratelimit-unified-7d-utilization"))
        if p5 is None or p7 is None:
            return None
        p5, p7 = p5 * 100, p7 * 100
        r5 = _num(h.get("anthropic-ratelimit-unified-5h-reset"))
        r7 = _num(h.get("anthropic-ratelimit-unified-7d-reset"))
    if p5 < 0 or p7 < 0:
        return None
    # six places cancel the float noise (0.29 × 100 = 28.999…96 → "29")
    pc = lambda x: ("%.6f" % x).rstrip("0").rstrip(".")
    rs = lambda r: str(int(r)) if r is not None and r > 0 else "-"
    return {"rl5h": pc(p5), "rl7d": pc(p7), "rl_reset5": rs(r5), "rl_reset7": rs(r7)}


def claude_token(accounts, label):
    """A hub-leased account's renewed file (#1415), else the account's own token file
    — a `claude setup-token` line (bin/fleet-account.sh acct_token, issue #1972)."""
    hub = os.path.join(accounts, label + ".hub", ".credentials.json")
    if os.path.exists(hub):
        with open(hub) as f:
            return json.load(f)["claudeAiOauth"]["accessToken"]
    with open(os.path.join(accounts, label)) as f:
        tok = f.readline().strip()
    if not tok or tok.startswith("hub:"):
        raise ValueError("no token for this account")
    return tok


def codex_auth_path(cfg, label):
    """`default` = ~/.codex/auth.json, any other label = <codex homes>/<label>/auth.json
    (the node agent's mapping, tokenledger agent/node_creds.go codexHomeFor)."""
    if label == "default":
        return cfg.codex_auth
    return os.path.join(cfg.codex_homes, label, "auth.json")


def SAFE_LABEL(s):
    import re
    return bool(re.match(r"^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$", s or ""))


def write_private(path, data):
    """0600, via a same-directory rename (a reader sees old or new, never half)."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".%s.%s" % (os.path.basename(path), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(tmp, path)


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
        wrap = int(req.get("wrap") or 0)
        if wrap > 1:
            # the session's wrapper: while it lives, this credential outlives its stamp
            p = os.path.join(cfg.state, "live.json")
            with Proxy.lock:
                d = read_json(p, {})
                d = {k: v for k, v in d.items() if pid_alive(v)}
                d[sid] = wrap; write_json(p, d)
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
            Proxy.quota.pop(sid, None)
            p = os.path.join(cfg.state, "live.json")
            d = read_json(p, {})
            if d.pop(sid, None) is not None:
                write_json(p, d)
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
    if op == "store":
        # the node agent's lease (tokenledger agent/node_credstore.go): the
        # bytes it would have written itself, written here where only we read
        if not cfg.store:
            return {"ok": False, "err": "store: not separated (FLEET_CRED_STORE unset)"}
        kind, label = req.get("kind") or "", req.get("label") or ""
        if not SAFE_LABEL(label):
            return {"ok": False, "err": "store: unsafe label %r" % label}
        data = base64.b64decode(req.get("data") or "")
        if not data or len(data) > 65536:
            return {"ok": False, "err": "store: empty or oversized"}
        if kind == "claude":
            dst = os.path.join(cfg.accounts, label + ".hub", ".credentials.json")
        elif kind == "codex":
            dst = codex_auth_path(cfg, label)
        else:
            return {"ok": False, "err": "store: kind claude|codex"}
        write_private(dst, data)
        Proxy.log(ev="store", kind=kind, acct=label, bytes=len(data))
        return {"ok": True}
    if op == "probe":
        pp = env("FLEET_CRED_PROBE")
        if not cfg.store or not pp:
            return {"ok": False, "err": "probe: not separated"}
        d = json.loads(req.get("data") or "null")
        if not isinstance(d, dict):
            return {"ok": False, "err": "probe: a JSON object"}
        write_json(pp, d)
        return {"ok": True}
    if op == "relay":
        # separated: the relay pass fleet-relay-cred.sh minted for the login
        if not cfg.store:
            return {"ok": False, "err": "relay: not separated"}
        tok = (req.get("data") or "").strip()
        if not tok or len(tok) > 4096 or any(c.isspace() for c in tok):
            return {"ok": False, "err": "relay: one pass on stdin"}
        write_private(os.path.join(cfg.state, "relay.token"), tok.encode() + b"\n")
        Proxy.log(ev="relay_pass")
        return {"ok": True}
    if op == "node-token":
        if not cfg.broker:
            return {"ok": False, "err": "node-token: no hub broker here (not separated)"}
        ne = node_env()
        if not ne.get("CCQUOTA_TOKEN"):
            return {"ok": False, "err": "node-token: no node token here"}
        port = cfg.bound_port
        return {"ok": True, "token": Proxy.keys.mint("-", "node", int(req.get("ttl") or 600), NODE_TAG),
                "url": "http://127.0.0.1:%d/hub" % port}
    if op == "node-hash":
        if not cfg.broker:
            return {"ok": False, "err": "node-hash: no hub broker here (not separated)"}
        t = node_env().get("CCQUOTA_TOKEN", "")
        if not t:
            return {"ok": False, "err": "node-hash: no node token here"}
        return {"ok": True, "hash": hashlib.sha256(t.encode()).hexdigest()}
    if op == "quota":
        with Proxy.lock:
            q = {k: dict(v) for k, v in Proxy.quota.items() if v["ts"] > time.time() - 86400}
        return {"ok": True, "quota": q}
    if op == "status":
        return {"ok": True, "pid": os.getpid(), "port": cfg.bound_port, "separated": bool(cfg.store),
                "trust": Proxy.router.trust or "unknown", "trust_why": Proxy.router.trust_why,
                "relay": bool(cfg.relay_url), "relay_pass": bool(relay_pass(cfg)),
                "central": cfg.central_url or "", "budget": Proxy.budget.view(),
                "renew": dict(Proxy.passes.stats), "hub_passes": len(Proxy.passes.held)}
    return {"ok": False, "err": "unknown op %r" % op}


def ctl_serve(sock, cfg):
    while True:
        try:
            c, _ = sock.accept()
        except OSError:
            return
        threading.Thread(target=ctl_conn, args=(c, cfg), daemon=True).start()


def peer_uid(c):
    """The connecting process's uid: LOCAL_PEERCRED's xucred (macOS) and
    SO_PEERCRED's ucred (Linux) both carry it at byte 4."""
    if sys.platform == "darwin":
        raw = c.getsockopt(0, 0x001, 76)        # SOL_LOCAL, LOCAL_PEERCRED
    else:
        raw = c.getsockopt(socket.SOL_SOCKET, getattr(socket, "SO_PEERCRED", 17), 12)
    return int.from_bytes(raw[4:8], sys.byteorder)


def ctl_conn(c, cfg):
    try:
        if cfg.ctl_uid is not None:
            # the socket is 0666 in separated mode: the peer's uid is the gate
            try:
                u = peer_uid(c)
            except OSError:
                u = -1
            if u not in (cfg.ctl_uid, 0):
                Proxy.log(ev="deny", path="ctl", why="peer uid %d" % u)
                c.sendall(b'{"ok": false, "err": "not this login\'s proxy"}\n')
                return
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
    sockp = os.path.join(env("FLEET_CRED_CTL_DIR", state), "ctl.sock")
    try:
        s.connect(sockp)
    except OSError as e:
        sys.stderr.write("fleet-cred-proxy: not running (%s: %s)\n" % (sockp, e.strerror))
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


def relay_pass(cfg):
    """The relay pass (#1974): FLEET_CRED_RELAY_TOKEN, else the one
    fleet-relay-cred.sh minted for this login (<state>/relay.token, 0600) —
    read per request, so a re-mint needs no restart."""
    if cfg.relay_token:
        return cfg.relay_token
    try:
        with open(os.path.join(cfg.state, "relay.token")) as f:
            return f.read().strip()
    except OSError:
        return ""


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
    cfg.quota_push = env("FLEET_CRED_QUOTA_PUSH")
    cfg.quota_push_secs = float(env("FLEET_CRED_QUOTA_PUSH_SECS", "2"))
    # separated mode (issue #1971): set by bin/fleet-credsep-launch.py only
    cfg.store = env("FLEET_CRED_STORE") == "1"
    cfg.broker = cfg.store
    cfg.ctl_uid = int(env("FLEET_CRED_CTL_UID")) if env("FLEET_CRED_CTL_UID") else None
    ctld = env("FLEET_CRED_CTL_DIR", st)
    for name in ("anthropic_url", "codex_url", "relay_url", "central_url"):
        v = getattr(cfg, name)
        if v and not loopback_ok(v):
            sys.exit("fleet-cred-proxy: %s=%s: https, or plain http on loopback only" % (name, v))
    if cfg.relay_url and not relay_pass(cfg):
        # not fatal: the launcher mints one (fleet-relay-cred.sh fetch); until
        # then the relay road is simply not a candidate
        sys.stderr.write("fleet-cred-proxy: FLEET_CRED_RELAY_URL set but no relay pass yet "
                         "(FLEET_CRED_RELAY_TOKEN or %s) — relay road off\n" % os.path.join(cfg.state, "relay.token"))
    if not cfg.log:
        cfg.log = env("FLEET_CRED_PROXY_LOG", os.path.join(os.path.dirname(BIN), "logs", "cred-proxy.log"))
    try:
        os.makedirs(os.path.dirname(cfg.log), exist_ok=True)
    except OSError:
        pass
    Proxy.cfg, Proxy.keys, Proxy.router, Proxy.passes = cfg, Keys(st), Router(cfg), HubPasses(st)

    # the port: --port, else the last one used (live sessions carry it in
    # ANTHROPIC_BASE_URL — a restart must not move it), else any free one
    portf = os.path.join(ctld, "port")
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

    sockp, pidf = os.path.join(ctld, "ctl.sock"), os.path.join(ctld, "pid")
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
    # 0666 only with the peer-uid gate (separated: the login is another uid)
    os.chmod(sockp, 0o666 if cfg.ctl_uid is not None else 0o600)
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
    try:
        Proxy.budget.flush(Proxy.log)
    except Exception:
        pass
    with open(portf + ".tmp", "w") as f:
        f.write("%d\n" % cfg.bound_port)
    os.replace(portf + ".tmp", portf)
    with open(pidf, "w") as f:
        f.write("%d\n" % os.getpid())
    if cfg.ctl_uid is not None:   # separated: the login (another uid) reads both
        for p in (portf, pidf):
            os.chmod(p, 0o644)

    parent = os.getppid()

    def tick():
        every = max(5, int(env("FLEET_CRED_PROXY_TRUST_SECS", "300")))
        bevery = max(1, int(env("FLEET_CRED_BUDGET_SECS", "15")))
        last = blast = last_pass = time.time()
        while True:
            time.sleep(1)
            if a.parent_watch and os.getppid() != parent:
                bye()       # the launcher died: never outlive it as an orphan
            if time.time() - blast >= bevery:
                blast = time.time()
                try:
                    Proxy.budget.flush(Proxy.log)
                except Exception:
                    pass
            if time.time() - last >= every:
                last = time.time()
                try:
                    Proxy.router.refresh(Proxy.log)
                except Exception:
                    pass
            if time.time() - last_pass >= 60:
                last_pass = time.time()
                try:
                    Proxy.passes.tick()
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
    m.add_argument("--ttl", type=int, default=0); m.add_argument("--wrap", type=int, default=0)
    b = sub.add_parser("rebind")
    b.add_argument("--sid", required=True); b.add_argument("--account", required=True)
    v = sub.add_parser("revoke")
    v.add_argument("--sid", required=True)
    t = sub.add_parser("attach")
    t.add_argument("--sid", required=True)
    sub.add_parser("quota")
    u = sub.add_parser("status")
    u.add_argument("--json", action="store_true")
    o = sub.add_parser("store")
    o.add_argument("--kind", required=True, choices=("claude", "codex")); o.add_argument("--label", required=True)
    sub.add_parser("probe")
    sub.add_parser("relay")
    sub.add_parser("node-token")
    sub.add_parser("node-hash")
    a = ap.parse_args()
    a.state = a.state or default_state()
    if a.cmd == "serve":
        return serve(a)
    if a.cmd == "route":
        res = ctl_call(a.state, {"op": "route", "provider": a.provider, "refresh": a.refresh})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False) if a.json else "%s\t%s" % (res["route"], res["reason"]))
    elif a.cmd == "mint":
        print(ctl_call(a.state, {"op": "mint", "account": a.account, "sid": a.sid, "ttl": a.ttl,
                                 "wrap": a.wrap})["token"])
    elif a.cmd == "rebind":
        ctl_call(a.state, {"op": "rebind", "sid": a.sid, "account": a.account})
        print("rebound %s -> %s" % (a.sid, a.account))
    elif a.cmd == "revoke":
        ctl_call(a.state, {"op": "revoke", "sid": a.sid})
        print("revoked %s" % a.sid)
    elif a.cmd == "attach":
        ctl_call(a.state, {"op": "attach", "sid": a.sid, "cred": sys.stdin.readline()})
        print("attached %s" % a.sid)
    elif a.cmd == "store":
        ctl_call(a.state, {"op": "store", "kind": a.kind, "label": a.label,
                           "data": base64.b64encode(sys.stdin.buffer.read(65537)).decode()})
    elif a.cmd == "probe":
        ctl_call(a.state, {"op": "probe", "data": sys.stdin.read(65536)})
    elif a.cmd == "relay":
        ctl_call(a.state, {"op": "relay", "data": sys.stdin.read(4097)})
    elif a.cmd == "node-token":
        res = ctl_call(a.state, {"op": "node-token"})
        print("%s\t%s" % (res["url"], res["token"]))
    elif a.cmd == "node-hash":
        print(ctl_call(a.state, {"op": "node-hash"})["hash"])
    elif a.cmd == "quota":
        print(json.dumps(ctl_call(a.state, {"op": "quota"})["quota"], sort_keys=True))
    elif a.cmd == "status":
        res = ctl_call(a.state, {"op": "status"})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False) if a.json else
              "pid %s · 127.0.0.1:%s · trust %s (%s)" % (res["pid"], res["port"], res["trust"], res["trust_why"]))


if __name__ == "__main__":
    main()
