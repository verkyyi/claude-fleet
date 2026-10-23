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
    unstore --kind claude|codex --label LABEL   (the node agent's withdrawal,
                                 issue #3043: a subscription allowlist forbids
                                 this login the account — its index entry, own
                                 copy, pins and picks go; another login's stay)
    (ctl only) prune {keep: {claude: […], codex: […]}} — the node agent's whole
                                 lease, issue #3744: every account this login
                                 holds that the hub's answer no longer lists
                                 goes as `unstore` would (a deleted subscription)
    probe                       (node-probe.json on STDIN — separated mode only)
    relay-probe                 → {relay, peer, anthropic, openai, …}: the road a
                                 session takes through the relay, measured with
                                 the relay pass and NO credential (issue #3364 —
                                 bin/fleet-node-probe.sh judges a relay login by it)
    node-token                  → a short-lived fcpn1.<…> for the hub broker
    node-hash                   → sha256 hex of the node token (the fleet-mcp
                                 worker assertion's key; the token never leaves)
    pass                        (a hub pass, fcp-h1., on STDIN — the shared proxy
                                 files it under the caller's login)
    machine                     → the shared proxy's logins and live session counts

THE SHARED PROXY (issue #2217 — bin/fleet-credsep.sh machine install): on a
managed node ONE process, run by the role account, serves every login:
`serve --shared <tenants.json>` (written by root's fleet-credsep-launch.py
shared). Each login is a TENANT with everything above that is per-login — its
signing key, binds, revocations, live sessions, hub passes, trust, probe, node
token, budget, relay pass, credentials and log — and nothing is shared between
two. One fixed 127.0.0.1 port (FLEET_CRED_SHARED_PORT) for all; a session
credential minted there carries `lg` (its login) and is verified with THAT
login's key, so naming another login only fails the signature; a hub pass is
that login's once registered (`pass`). Each login's OLD port (a per-login
proxy's, moved over) is served too, answering that login only, so a session
started before the switch moves over on its next request. The control socket
(0666) knows the caller from the kernel (getpeereid / SO_PEERCRED): a login's
uid reaches its own tenant, nothing else; root names one (FLEET_CRED_AS).
It reads its tenants once, at start, and writes the logins it serves to
<run>/logins beside <run>/version. A start that finds the lock held by a proxy
serving another version or another set of logins (an orphan the daemon lost,
still running the tenants from before a login joined — issue #4245) takes it
over: SIGTERM, then the lock; only an identical one is "already running".

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

THE ACCOUNT PICK (issue #2412): a SEPARATED login does not choose its
subscription. A Claude session credential minted for it names no account (a
login's --account is ignored and logged; `rebind` is refused — root alone
pins, in bind.json), and the proxy picks one per session from the accounts the
login holds, by those readings (on the shared proxy every login's answers
count): the session keeps it while it is under FLEET_CRED_PICK_CEILING
(default FLEET_ACCOUNT_CEILING, 85) and not limited; at the ceiling the next
request runs on the account with the most room, and a quota 429 moves the SAME
request there (limited until its reset) — no exit, no resume. A credential
minted by root (a pin) that names an account runs on it. ctl `picks`
says which account each session is on (read-only). Not separated: no pick.
A Codex session of a separated login is picked the same way (issue #4606) —
unless it names an account home of its own (FLEET_CODEX_HOME=<homes>/<L>, a
pin): the default home holds no credential there, so a credential naming
`default` (or none) is the proxy's to place. ctl `standing` says, per account
the login holds, whether a pick may land there and when one that is out comes
back — the launch's «every account is out» line.

ROUTES (EPIC #1967 共同约定 1) — decided ONLY by the hub's record of this
machine's trust × the last probe (bin/fleet-node-probe.sh → node-probe.json):

    direct   trusted + reachable    real credential, straight to the provider
    relay    trusted + unreachable  real credential, via the Singapore relay
                                    (FLEET_CRED_RELAY_URL + X-Fleet-Relay)
    central  untrusted              NO credential file is read: the session's
                                    hub credential (fcp-h1.) goes to the
                                    cluster's credential proxy — also a login
                                    the hub gates as not credential-separated
                                    (/v1/node/self credsep_gate, issue #2295)

A region refusal (Anthropic 403 / OpenAI unsupported_country_region_territory)
or a connection that never opens moves THAT session to the next route and
retries the same request; the move is logged `route_switch`.

A SESSION CREDENTIAL OUTLIVES ITS STAMP WHILE ITS SESSION LIVES (issue #1975):
the session cannot swap the credential in its environment, so the proxy does
the renewing. An fcp1. minted with --wrap PID stays good past its exp while that
process (the session's wrapper) lives and the sid is not revoked, at most
FLEET_CRED_PROXY_RENEW_MAX_SECS (7 days) past it. A hub pass (fcp-h1. / fcp-h2.) is
renewed with the hub (POST /v1/fleet/session-cred/renew, the node token) once
it reaches its renew point — 20 % of its life left (#3561; a pass lives 4h) — on
the session's next request or the background tick, whichever comes first; the
session keeps sending the pass it was born with and the proxy forwards the
newest one it holds for that id (<state>/hub-passes.json, 0600). A pass that
LAPSED — the machine asleep, or this proxy down, through its renew window — is
renewed on the session's next request: the hub takes one back for
HUB_RENEW_GRACE (7 days) past its newest expiry unless revoked (issue #2012);
the background tick never renews a lapsed pass (only a live session asks), and
forgets it past the grace. A pass the hub refuses (revoked, the session over,
past the grace) is dropped; any other failure is counted in `status`
(renew.hub_err, the doctor's `cred` row).

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
token — one entry per (provider, session, account, model), the session named by
the worker_id its launcher minted it for (`mint --worker`, kept in
workers.json), with input / cache writes / cache reads / output apart and the
old `tokens` beside them (issue #3376); the hub files each under the login's
person, repo / issue from that session's lease, and answers their standing
against fleet.person_budget.<principal>. Over it, every request is refused 403
with error.code person_budget_exceeded and the hub's line (「已达个人额度…」) —
neither client retries a 403. The central route is metered by the cluster
proxy, never twice here. No hub / no node token / FLEET_CRED_BUDGET=0 = nothing
reported, nothing refused; a verdict the hub has not renewed for
FLEET_CRED_BUDGET_STALE (600 s) lapses (open). A metered request goes out
asking only for codings the meter opens (gzip / deflate — Claude Code asks for
br / zstd too, and Anthropic gzips its stream): the client gets the upstream's
bytes as they came, the meter reads its own decoded copy (issue #3407). A 2xx
answer it still reads nothing from is logged `meter_miss`, and a flush with no
hub / node token / an error is `budget_err` (once per change) — both in
`status` (budget.err · misses) and the doctor's cred-proxy row, never silent.

UPSTREAM STATS (T657): every attempt at a provider (direct / relay / central —
never the hub broker) is sorted into ONE class — ok · refused · reset · timeout
· tls · dns · neterr (a connection that failed otherwise) · 4xx · 429 · 5xx ·
529 — and counted per minute into <stats>/upstream-stats.ndjson (0644, kept 7
days; <stats> = the shared tenants file's "stats", the launcher's
/var/db/fleet-cred/.stats, else the control dir), with the open minute in
upstream-now.json beside it: counts per class and per account, and each failure's
time · class · account · login · session (cred sid) · route · ms. Never a
token, a header or a body. bin/fleet_upstream_stats.py is the one reader (the
doctor's 上游 row, `fleet-cred-proxy.sh upstream`, the 看台's top line).
FLEET_CRED_UPSTREAM_STATS=0 writes nothing. Forwarding itself is untouched.
"""
import argparse, base64, fcntl, hashlib, hmac, http.client, json, os, re, secrets, zlib
import resource, shutil, signal, socket, ssl, sys, threading, time, urllib.error, urllib.request
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:  # the ONE TLS context for the hub: every CA source this computer has (claude-fleet#2878)
    import fleet_tls
    fleet_tls.install()
except ImportError:
    fleet_tls = None

SECRET_HEADERS = {"authorization", "x-api-key", "cookie", "set-cookie",
                  "chatgpt-account-id", "proxy-authorization", "x-fleet-relay"}
HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding",
       "te", "trailer", "upgrade", "host", "content-length"}
PUBLIC = {"/api/hello"}


# A restart that never drops a connection (T595): the next proxy takes this one's
# listening sockets over <state>/handoff.sock (SCM_RIGHTS) — the same kernel
# sockets, so a connection arriving in between waits in their backlog, never
# ECONNREFUSED — and this one stops taking new ones, lets go of the lock and
# finishes what it is serving (`drain`). HANDOFF: what a successor takes —
# "tcp:<port>" -> its Server, "ctl" -> the control socket.
DRAIN = {"on": False, "since": 0.0, "conns": 0, "busy": 0}
DRAIN_LOCK = threading.Lock()
HANDOFF = {}


class Server(ThreadingHTTPServer):
    """http.server's bind looks its own address up (socket.getfqdn): a machine
    whose /etc/hosts lost `127.0.0.1 localhost` waits out a DNS timeout there —
    70 s on a GitHub macOS runner (issue #2319) — before the proxy answers at
    all. The name is never used, so it is never asked for.
    fd: a listening socket handed over by the proxy before (T595), used as is.
    The listener has a timeout: two processes may hold it for a moment, and an
    accept the other one won must return, not block (the accepted socket is
    blocking either way — Python's accept for a socket with a timeout)."""
    request_queue_size = 128

    def __init__(self, addr, handler, fd=None):
        if fd is None:
            ThreadingHTTPServer.__init__(self, addr, handler)
        else:
            ThreadingHTTPServer.__init__(self, addr, handler, bind_and_activate=False)
            self.socket.close()
            self.socket = socket.socket(fileno=fd)
            self.server_address = self.socket.getsockname()
            self.server_name, self.server_port = self.server_address[:2]
            self.socket.listen(self.request_queue_size)
        self.socket.settimeout(1.0)

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def process_request_thread(self, request, client_address):
        with DRAIN_LOCK:
            DRAIN["conns"] += 1
        try:
            ThreadingHTTPServer.process_request_thread(self, request, client_address)
        finally:
            with DRAIN_LOCK:
                DRAIN["conns"] -= 1
OAUTH_BETA = "oauth-2025-04-20"
LOCAL_TAG, HUB_TAG, NODE_TAG = "fcp1", "fcp-h1", "fcpn1"
# a hub pass is fcp-h1 (HMAC, only the hub verifies it) or fcp-h2 (Ed25519 —
# the relay and the cluster proxy verify it themselves, issue #3698)
HUB_TAGS = (HUB_TAG, "fcp-h2")


def is_hub_pass(tok):
    return "." in tok and tok.split(".", 1)[0] in HUB_TAGS
# how long past its newest expiry the hub still renews a never-revoked pass —
# SessionCredRenewGrace in tokenledger/hub/api/fleet_session_cred.go (#2012)
HUB_RENEW_GRACE = 7 * 86400
# the relay pass (issue #3561): renewed when used with < 1/RELAY_RENEW_LEFT of
# its life left, or past RELAY_RENEW_AT of it; a request unanswered is made
# again after RELAY_REASK_SECS; a missing pass asked for on a doubling clock
RELAY_RENEW_LEFT = 5
RELAY_RENEW_AT = 0.8
RELAY_REASK_SECS = int(os.environ.get("FLEET_CRED_RELAY_REASK_SECS") or 300)
RELAY_MISSING_SECS = int(os.environ.get("FLEET_CRED_RELAY_RETRY_SECS") or 60)
RELAY_MISSING_MAX_SECS = int(os.environ.get("FLEET_CRED_RELAY_RETRY_MAX_SECS") or 120)
# never through the hub broker (EPIC #1967 route ④): the subscription pool
HUB_DENY = ("/v1/node/credentials",)
# What a session may reach under /codex/ (issue #4611): the provider-relative paths
# Codex CLI (0.162) calls on its model provider, each with its methods — nothing
# else of chatgpt.com/backend-api/codex is forwarded. ONE list: the same line is
# tokenledger/shared/credproxy CodexAllowSpec (TestCodexAllowMatchesPython).
CODEX_ALLOW_SPEC = "POST responses, POST responses/compact, GET models"
CODEX_ALLOW = {}
for _m, _p in (_x.split() for _x in CODEX_ALLOW_SPEC.split(",")):
    CODEX_ALLOW.setdefault(_p, set()).add(_m)


def codex_refused(method, path):
    """-> why a /codex/ request is refused, or "" (issue #4611): one spelling per
    path — no %, \\, //, ./ or ../ (hub_broker's rule) — on the list, by its method."""
    import posixpath
    bare = path.split("?")[0]
    if "%" in bare or "\\" in bare or posixpath.normpath(bare) != bare:
        return "not a plain /codex/ path"
    meths = CODEX_ALLOW.get(bare[len("/codex/"):])
    if meths is None:
        return "%s is not a path Codex CLI uses" % bare
    if method not in meths:
        return "%s %s is not a request Codex CLI makes" % (method, bare)
    return ""
REGION_MARKS = ("unsupported_country_region_territory", "unsupported_country",
                "unsupported_region", "request not allowed",
                "not available in your country", "not available in your region")
# The upstream's codes for refusing a Codex ACCESS token — the same list as
# tokenledger/shared/codex rpc.go accessRejectCodes (claude-fleet#1920).
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


# Separated (issue #2290): the hosts a credential or the node token may go to.
# The launcher hands this proxy its settings from root's config only, and on top
# of that every upstream must be one of these (+ FLEET_CRED_ALLOW_HOSTS, which
# also comes from root's config alone) — a login that talks the launcher into
# another URL still cannot make the proxy send a real Authorization there.
# The fleet's own hub and relay are not written here (issue #3577): they are the
# hosts of the hub / relay / central URLs root's config names (configured_hosts).
UPSTREAM_HOSTS = ("api.anthropic.com", "chatgpt.com", "api.openai.com", "auth.openai.com")
ALLOWED = None      # None = a login's own proxy (its own credentials): any https host


def allowed_hosts(extra="", urls=()):
    """The public upstreams + FLEET_CRED_ALLOW_HOSTS + the host of every URL in
    `urls` (the hub / relay / central URLs root's config set — configured_hosts)."""
    out = set(UPSTREAM_HOSTS) | {h.strip().lower() for h in re.split(r"[\s,]+", extra or "") if h.strip()}
    for u in urls:
        h = (urlsplit(u).hostname or "").lower() if u else ""
        if h:
            out.add(h)
    return out


def configured_urls(cfgs):
    """The fleet's own hub and relay as root's config names them (issue #3577):
    FLEET_HUB_URL, each config's relay / central URL, and the hub its node.env
    (root's copy in separated mode) points at."""
    urls = [env("FLEET_HUB_URL"), env("FLEET_HUB_INTERNAL_URL")]
    for c in cfgs:
        # + 活页's MCP (task XA4R): FLEET_CRED_SPACE_URL, else the default — /space/mcp only
        urls += [getattr(c, "relay_url", ""), getattr(c, "central_url", ""), getattr(c, "space_url", "")]
        ne = getattr(c, "node_env", "")
        if ne:
            urls.append(node_env(ne).get("CCQUOTA_HUB_URL", ""))
    return [u for u in urls if u]


def loopback_ok(url, cluster=False):
    """An upstream URL: https anywhere, plain http only on loopback (the selftest).
    Separated (ALLOWED set): https to an allowed host only; loopback http only in
    the selftest's sandbox (FLEET_CREDSEP_TEST=1, which root's launcher never sets).
    `cluster` — the central route's URL only (issue #3547): plain http to a
    Kubernetes Service's cluster-local name too (NAME.NS.svc.cluster.local, the
    cluster credential proxy a user pod routes to; what rides it is a hub pass,
    never a subscription credential), still to an allowed host when separated."""
    u = urlsplit(url)
    host = (u.hostname or "").lower()
    loop = u.scheme == "http" and host in ("127.0.0.1", "localhost", "::1")
    incluster = cluster and u.scheme == "http" and host.endswith(".svc.cluster.local") and host.count(".") >= 4
    if ALLOWED is None:
        return u.scheme == "https" or loop or incluster
    if u.scheme == "https" or incluster:
        return host in ALLOWED
    return loop and env("FLEET_CREDSEP_TEST") == "1"


# The node agent's warm road to the hub (claude-fleet T672, tokenledger/shared/
# hubfwd): a managed machine's ccquota agent serves it at /var/db/fleet-node/
# hub.sock (0666) on its kept, warm connection — one round trip instead of a new
# TLS handshake per brokered call. $CCQUOTA_HUB_SOCK names another, "off" none.
HUB_FWD_SOCK = "/var/db/fleet-node/hub.sock"


def hub_fwd_sock():
    v = env("CCQUOTA_HUB_SOCK").strip()
    if v == "off":
        return None
    p = v or HUB_FWD_SOCK
    try:
        import stat
        return p if stat.S_ISSOCK(os.stat(p).st_mode) else None
    except OSError:
        return None


class UnixHTTPConnection(http.client.HTTPConnection):
    """Plain HTTP on a unix socket: the forwarder holds the TLS."""

    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._sock_path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._sock_path)
        self.sock = s


def hub_dial(hub):
    """Where a call to `hub` goes (issue #4175): a person's pod names the hub's
    in-cluster Service (FLEET_HUB_INTERNAL_URL, render.py --hub-internal) and asks
    it there instead of the public door the egress does not carry. `hub` stays the
    identity and is checked as before; the Service must pass loopback_ok's cluster
    rule (http to NAME.NS.svc.cluster.local, an allowed host when separated).
    Unset or not such a URL = `hub`, byte for byte."""
    dial = env("FLEET_HUB_INTERNAL_URL").strip().rstrip("/")
    if hub and dial and loopback_ok(dial, cluster=True):
        return dial
    return hub


def node_env(path=None):
    """$FLEET_CONF_DIR/node.env as a dict — read here, never exported (issue #1491).
    `path`: a tenant's own (the shared proxy, issue #2217)."""
    out = {}
    try:
        for line in open(path or env("FLEET_CRED_NODE_ENV", os.path.join(conf_dir(), "node.env"))):
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
METER_CODINGS = ("gzip", "x-gzip", "deflate", "identity")


def meter_accept(v):
    """The Accept-Encoding a metered request goes out with (issue #3407): the
    client's own list less what the meter cannot open (br, zstd, *) — stdlib
    zlib reads gzip and deflate — else identity."""
    keep = []
    for part in (v or "").split(","):
        if part.split(";")[0].strip().lower() in METER_CODINGS:
            keep.append(part.strip())
    return ", ".join(keep) or "identity"


def codex_ref(kind, value):
    return hashlib.sha256(("fleet-codex-affinity-v1\0" + kind + "\0" + value).encode()).hexdigest()


def codex_output_refs(value):
    """Provider envelopes only, never parse tool arguments or user text."""
    refs = set()
    def visit(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k in ("id", "call_id", "conversation", "encrypted_content") and isinstance(x, str) and x:
                    refs.add(codex_ref("encrypted" if k == "encrypted_content" else "id", x))
                elif isinstance(x, (list, dict)):
                    visit(x)
        elif isinstance(v, list):
            for x in v:
                visit(x)
    v = value.get("response", value)
    if isinstance(v, dict):
        visit({k: v[k] for k in ("id", "output", "item", "conversation") if k in v})
    return refs if len(refs) <= 4096 else set()


def codex_context(method, path, headers, body):
    """Conservative counterpart of shared/credproxy/continuation.go. Only known
    self-contained input can move; unknown fields preserve original context.
    References are purpose-separated hashes, never text/ciphertext on disk.
    """
    refs, unknown = set(), False
    def add(kind, v):
        nonlocal unknown
        if v is None:
            return
        if not isinstance(v, str):
            unknown = True
        elif v:
            refs.add(codex_ref(kind, v))
    for name in ("x-codex-turn-state", "x-codex-routing-hint"):
        add("header:" + name, headers.get(name))
    if headers.get("content-encoding"):
        unknown = True
    if "?" in path and not (method == "GET" and path.split("?", 1)[1].startswith("client_version=") and "&" not in path.split("?", 1)[1]):
        unknown = True
    if method == "GET":
        return not unknown and not refs, refs, unknown
    def unique(pairs):
        d = {}
        for k, v in pairs:
            if k in d:
                raise ValueError("duplicate JSON key")
            d[k] = v
        return d
    try:
        root = json.loads(body, object_pairs_hook=unique)
    except (ValueError, TypeError, RecursionError):
        return False, refs, True
    if not isinstance(root, dict):
        return False, refs, True
    allowed = set("model instructions input tools tool_choice parallel_tool_calls stream store include reasoning text temperature top_p max_output_tokens max_tool_calls truncation metadata prompt_cache_key prompt_cache_retention safety_identifier service_tier background context_management previous_response_id conversation stream_options client_metadata".split())
    unknown |= bool(set(root) - allowed)
    def tools(v):
        if not isinstance(v, list):
            return False
        for t in v:
            if not isinstance(t, dict):
                return False
            typ = t.get("type")
            if typ == "namespace":
                if not tools(t.get("tools")):
                    return False
            elif typ in ("web_search", "web_search_preview"):
                if set(t) - set("type filters user_location search_context_size external_web_access".split()):
                    return False
            elif typ not in ("function", "custom"):
                return False
        return True
    if root.get("tools") is not None and not tools(root["tools"]):
        unknown = True
    metadata = root.get("client_metadata")
    if isinstance(metadata, dict):
        for name in ("x-codex-turn-state", "x-codex-routing-hint"):
            add("header:" + name, metadata.get(name))
    add("id", root.get("previous_response_id"))
    conv = root.get("conversation")
    if isinstance(conv, dict):
        add("id", conv.get("id"))
        unknown |= set(conv) != {"id"}
    else:
        add("id", conv)
    def client_input_id(v):
        # Native Codex assigns IDs before inference to full client messages and
        # tool declarations. Never use an ID prefix or client metadata as proof;
        # assistant items, calls, encrypted state and reference-only items stay
        # provider affinity. Extra/opaque fields cannot gain this exemption.
        if not isinstance(v.get("id"), str):
            return False
        if v.get("type") == "additional_tools":
            return (v.get("role") == "developer" and not set(v) - {"type", "id", "role", "tools"}
                    and tools(v.get("tools")))
        if v.get("type", "") not in ("", "message") or v.get("role") not in ("user", "developer", "system"):
            return False
        if set(v) - {"type", "id", "role", "content"}:
            return False
        content = v.get("content")
        if isinstance(content, str):
            return True
        if not isinstance(content, list) or not content:
            return False
        for part in content:
            if not isinstance(part, dict):
                return False
            if part.get("type") == "input_text":
                if not isinstance(part.get("text"), str) or set(part) - {"type", "text"}:
                    return False
            elif part.get("type") == "input_image":
                if not isinstance(part.get("image_url"), str) or not part["image_url"].startswith("data:") or set(part) - {"type", "image_url", "detail"}:
                    return False
            else:
                return False
        return True

    def item(v):
        nonlocal unknown
        if not isinstance(v, dict):
            unknown = True
            return
        typ = v.get("type", "")
        if not isinstance(typ, str):
            unknown, typ = True, ""
        if typ not in set("message function_call function_call_output custom_tool_call custom_tool_call_output additional_tools local_shell_call web_search_call tool_search_call tool_search_output reasoning compaction item_reference".split()) | {""}:
            unknown = True
        for k in ("id", "call_id"):
            if k != "id" or not client_input_id(v):
                add("id", v.get(k))
        add("encrypted", v.get("encrypted_content"))
        if v.get("tools") is not None and not tools(v["tools"]):
            unknown = True
        if typ in ("function_call_output", "custom_tool_call_output", "item_reference") and v.get("call_id") is None and v.get("id") is None:
            unknown = True
        if typ in ("reasoning", "compaction") and v.get("id") is None and v.get("encrypted_content") is None:
            unknown = True
        unknown |= bool(set(v) - set("type role content id call_id name namespace arguments input output status summary encrypted_content phase tools action execution".split()))
        if isinstance(v.get("output"), list):
            item(dict(type="message", content=v["output"]))
        content = v.get("content")
        if isinstance(content, list):
            for part in content:
                if not isinstance(part, dict):
                    unknown = True
                    continue
                typ = part.get("type")
                if typ in ("input_text", "output_text"):
                    unknown |= bool(set(part) - {"type", "text", "annotations", "logprobs"})
                elif typ == "input_image":
                    unknown |= not isinstance(part.get("image_url"), str) or not part.get("image_url", "").startswith("data:") or bool(set(part) - {"type", "image_url", "detail"})
                else:
                    unknown = True
        elif content is not None and not isinstance(content, str):
            unknown = True
    inp = root.get("input")
    if isinstance(inp, list):
        for v in inp:
            item(v)
    elif inp is not None and not isinstance(inp, str):
        unknown = True
    if len(refs) > 4096:
        return False, set(), True
    return not unknown and not refs, refs, unknown


class Meter:
    """What one answer says it used: the largest value each usage field
    reached (Claude: message_start + message_delta; Codex: response.completed;
    a plain JSON body: once). Mirrors tokenledger shared/credproxy usage.go."""
    MAX_WHOLE = 8 << 20

    def __init__(self, encoding=""):
        self.line, self.whole, self.sse, self.f, self.model = bytearray(), bytearray(), False, {}, ""
        # a compressed answer is opened here, on the meter's copy only — the
        # client gets the upstream's bytes as they came (issue #3407)
        self.references = set()
        self.on_references = None
        self.enc, self.z = (encoding or "").strip().lower(), None
        if self.enc in ("gzip", "x-gzip"):
            self.z = zlib.decompressobj(16 + zlib.MAX_WBITS)
        elif self.enc == "deflate":
            self.z = zlib.decompressobj(zlib.MAX_WBITS)
        elif self.enc in ("", "identity"):
            self.enc = ""
        else:
            self.enc = "unreadable:" + self.enc[:32]

    def feed(self, d):
        if self.z is not None:
            try:
                d = self.z.decompress(d)
            except zlib.error:
                if self.enc == "deflate" and not self.f and not self.line:
                    # a raw deflate stream (no zlib header), as some servers send
                    self.z = zlib.decompressobj(-zlib.MAX_WBITS)
                    try:
                        d = self.z.decompress(d)
                    except zlib.error:
                        self.z, self.enc = None, "unreadable:deflate"
                        return
                else:
                    self.z, self.enc = None, "unreadable:" + self.enc
                    return
        elif self.enc:
            return
        self.feed_plain(d)

    def feed_plain(self, d):
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
        if len(self.references) <= 4096:
            found = codex_output_refs(v)
            self.references.update(found)
            if found and self.on_references:
                self.on_references(found)
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
        # the model the answer names (Claude: message_start's message; Codex:
        # response.*'s response; a plain body: its own) — issue #3376
        for o in (v, v.get("message"), v.get("response")):
            if isinstance(o, dict) and isinstance(o.get("model"), str) and o["model"] and not self.model:
                self.model = o["model"][:128]

    def split(self):
        """-> {in, cache_write, cache_read, out} (issue #3376): in + cache_write +
        out is exactly tokens() — the budget's count — and cache reads ride
        along, never counted."""
        if not self.sse and self.whole:
            try:
                self.take(json.loads(bytes(self.whole)))
            except ValueError:
                pass
            self.whole = bytearray()
        g = self.f.get
        return {"in": max(0, g("input_tokens", 0) - g("cached_tokens", 0)) + g("prompt_tokens", 0),
                "cache_write": g("cache_creation_input_tokens", 0),
                "cache_read": g("cache_read_input_tokens", 0) + g("cached_tokens", 0),
                "out": g("output_tokens", 0) + g("completion_tokens", 0)}

    def tokens(self):
        u = self.split()
        return u["in"] + u["cache_write"] + u["out"]


WORKER_RE = re.compile(r"^[A-Za-z0-9._:/-]{1,200}$")
PENDING_FIELDS = ("tokens", "requests", "in", "cache_write", "cache_read", "out")


class Budget:
    """This login's person's standing, as the hub last said, and what is still
    to be reported — by (provider, session's worker_id, account, model), with
    the usage by kind (issue #3376), so the hub files each session's row under
    its task."""

    def __init__(self, cfg=None):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.pending = {}            # (provider, worker, acct, model) -> [tokens, requests, in, cw, cr, out]
        self.state, self.ts, self.err = {}, 0, ""
        self.said = ""               # the last flush problem logged (said once per change)
        self.misses, self.miss_why = 0, ""   # 2xx answers the meter read nothing from (#3407)

    def worker(self, sid):
        """-> the worker_id the session's credential was minted for ("" = none
        named: an older launcher, a session outside a fleet window)."""
        st = getattr(self.cfg, "state", None)
        if not sid or not st:
            return ""
        return read_json(os.path.join(st, "workers.json"), {}).get(sid, "")

    def add(self, provider, tokens, split=None, worker="", acct="", model=""):
        if tokens <= 0:
            return
        u = split or {"in": tokens}
        with self.lock:
            p = self.pending.setdefault((provider, worker or "", acct or "", model or ""), [0] * len(PENDING_FIELDS))
            for i, n in enumerate((tokens, 1, u.get("in", 0), u.get("cache_write", 0), u.get("cache_read", 0), u.get("out", 0))):
                p[i] += n

    @staticmethod
    def entry(key, v):
        """One report entry: tokens / requests for any hub (an older one counts
        tokens alone), the session and the split for one that files them."""
        e = {"provider": key[0]}
        e.update(zip(PENDING_FIELDS, v))
        for k, x in zip(("worker_id", "account", "model"), key[1:]):
            if x:
                e[k] = x
        return e

    def over(self):
        """-> the hub's line when the person is over (and the word is fresh), else ""."""
        stale = int(env("FLEET_CRED_BUDGET_STALE", "600"))
        with self.lock:
            if self.state.get("over") and time.time() - self.ts < stale:
                return self.state.get("message") or "已达个人额度（%s）" % BUDGET_CODE
        return ""

    def reset_at(self):
        """-> the hub's reset_at (ISO time) for the window the person is over, or "" —
        handed on in the 403 so a client can say until when (issue #3643)."""
        with self.lock:
            r = self.state.get("reset_at")
            return r if isinstance(r, str) else ""

    def miss(self, why):
        with self.lock:
            self.misses, self.miss_why = self.misses + 1, why

    def problem(self, why, log=None):
        """Why a flush sent nothing (issue #3407) — kept for status / the doctor,
        logged once per change, never silent."""
        with self.lock:
            self.err, said, self.said = why, self.said, why
        if log and why and why != said:
            log(ev="budget_err", why=why, pending=sum(v[0] for v in self.pending.values()))

    def flush(self, log=None):
        """POST the pending usage (none = just ask); keep it on failure."""
        if env("FLEET_CRED_BUDGET", "1") == "0":
            return None
        ne = node_env(getattr(self.cfg, "node_env", None))
        hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        tok = ne.get("CCQUOTA_TOKEN", "")
        if not hub or not tok or not loopback_ok(hub):
            ne_path = getattr(self.cfg, "node_env", None) or "node.env"
            self.problem("no node token (CCQUOTA_TOKEN in %s unreadable or missing)" % ne_path if not tok else
                         "no hub address (CCQUOTA_HUB_URL in %s / FLEET_HUB_URL)" % ne_path if not hub else
                         "hub %s is plain http off loopback" % hub, log)
            return None
        with self.lock:
            sent = {k: list(v) for k, v in self.pending.items()}
        body = json.dumps({"usage": [self.entry(k, v) for k, v in sorted(sent.items())]}).encode()
        try:
            req = urllib.request.Request(hub_dial(hub) + "/v1/node/usage", data=body, method="POST",
                                         headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                st = json.loads(r.read() or b"{}")
        except Exception as e:
            self.problem("POST /v1/node/usage: %s" % (
                "HTTP %d" % e.code if isinstance(e, urllib.error.HTTPError) else type(e).__name__), log)
            return None
        with self.lock:
            for k, v in sent.items():
                p = self.pending.get(k)
                if p:
                    for i, n in enumerate(v):
                        p[i] -= n
                    if p[0] <= 0 and p[1] <= 0:
                        del self.pending[k]
            was = bool(self.state.get("over"))
            self.state, self.ts, self.err, self.said = st if isinstance(st, dict) else {}, time.time(), "", ""
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
                       pending=sum(v[0] for v in self.pending.values()),
                       misses=self.misses, miss_why=self.miss_why)
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

    def mint(self, account, sid, ttl, tag=LOCAL_TAG, lg="", capacity=False):
        c = {"sid": sid, "acct": account, "exp": int(time.time()) + ttl, "n": secrets.token_hex(4)}
        if capacity:
            c["capacity_policy"] = 2
        if lg:      # the shared proxy (issue #2217): whose key signs it — never trusted alone
            c["lg"] = lg
        payload = json.dumps(c, separators=(",", ":")).encode()
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
    """The claims of a hub pass (fcp-h1|fcp-h2.<claims>.<sig>), read, NOT verified —
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

    def __init__(self, state, cfg=None, log=None):
        self.cfg, self.log = cfg, log
        self.path = os.path.join(state, "hub-passes.json")
        self.lock = threading.Lock()
        self.busy = set()
        self.held = read_json(self.path, {})
        self.stats = {"ok": 0, "err": 0, "dropped": 0, "local": 0,
                      "last_ok": 0, "last_err": 0, "err_why": ""}
        self.backoff = {}

    @staticmethod
    def renew_at(c):
        # 20 % of its life left (issue #3561 — the hub's renew_after); a pass
        # with no iat: the last 48 minutes of a four-hour one
        iat, exp = int(c.get("iat") or 0), int(c["exp"])
        return exp - (exp - iat) // 5 if iat else exp - 2880

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
        log = log or self.log or (lambda **kv: None)
        now = time.time()
        with self.lock:
            cur = self.held.get(pid, "")
            if not cur or pid in self.busy or self.backoff.get(pid, 0) > now:
                return None
            self.busy.add(pid)
        try:
            ne = node_env(getattr(self.cfg, "node_env", None))
            hub, tok = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/"), ne.get("CCQUOTA_TOKEN", "")
            if not hub or not tok:
                raise RuntimeError("no hub / node token here")
            if not loopback_ok(hub):
                raise RuntimeError("hub URL not allowed (%s)" % hub)
            req = urllib.request.Request(hub_dial(hub) + "/v1/fleet/session-cred/renew", method="POST",
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
            if not is_hub_pass(new) or not nc or nc["id"] != pid:
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
        """Renew every held pass that is due; forget the ones past the hub's
        renewal grace (a lapsed one is kept: its session's next request renews it)."""
        now = time.time()
        with self.lock:
            items = list(self.held.items())
        gone = False
        for pid, tok in items:
            c = hub_claims(tok)
            if not c or c["exp"] < now - HUB_RENEW_GRACE:
                with self.lock:
                    self.held.pop(pid, None)
                gone = True
            elif c["exp"] > now and now >= self.renew_at(c):
                self.renew(pid)
        if gone:
            with self.lock:
                self.save()


class RelayKeep:
    """The relay pass is renewed only when it is needed (issue #3561, EPIC #3500
    C19). An frl2 pass carries its own iat / exp (read, not verified — the proxy
    only needs the clock): used with less than 1/RELAY_RENEW_LEFT of its life
    left, or past RELAY_RENEW_AT of it, the proxy ASKS for a new one — it writes
    `relay-want[.<login>]` (one line: reason, time, jti) in its run directory;
    the login's launcher (a proxy of its own) or the node daemon (the shared
    proxy: the login's `cred-relay` job, run as the login) mints it with
    fleet-relay-cred.sh and hands it back over `relay`. A missing pass is asked
    for on the short doubling clock (#3423: 60 s → 120 s), and a pass the relay
    refused (relay_refused) at once, then at most once a minute. No pass, no
    relay configured, or an frl1 pass (it has no end) ⇒ no request on a clock.
    Every request and every new pass is a line in the proxy's log (ev=relay_want
    reason=…, ev=relay_pass_new reason=…) — the renewals' book."""

    def __init__(self, cfg, log=None):
        self.cfg, self.log = cfg, log or (lambda **kv: None)
        self.lock = threading.Lock()
        self.asked = {}          # jti -> (reason, time) of the request made for it
        self.missing_at, self.missing_wait = 0.0, 0
        self.refused_at = 0.0
        self.seen = None         # the jti (or "frl1") last seen held
        self.pending = ""        # the reason of the last request not yet answered

    @staticmethod
    def claims(tok):
        parts = (tok or "").split(".")
        if len(parts) != 3 or parts[0] != "frl2":
            return None
        try:
            c = json.loads(b64d(parts[1]))
            iat, exp = int(c.get("iat") or 0), int(c.get("exp") or 0)
            return c if c.get("jti") and 0 < iat < exp else None
        except Exception:
            return None

    def ask(self, reason, jti=""):
        path = getattr(self.cfg, "relay_want", "")
        if not path:
            return False
        try:
            tmp = "%s.%d.tmp" % (path, os.getpid())
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            with os.fdopen(fd, "w") as f:
                f.write("%s %d %s\n" % (reason, int(time.time()), jti or "-"))
            os.chmod(tmp, 0o644)   # the asker reads it as another uid
            os.replace(tmp, path)
        except OSError as e:
            self.log(ev="relay_want_err", reason=reason, err=type(e).__name__)
            return False
        self.pending = reason
        self.log(ev="relay_want", reason=reason, jti=(jti or "-")[:8])
        return True

    def _due(self, c, now, used):
        """The reason this frl2 pass should be renewed now, or ''."""
        life = c["exp"] - c["iat"]
        if used and now >= c["exp"] - life / RELAY_RENEW_LEFT:
            return "used"
        if now >= c["iat"] + life * RELAY_RENEW_AT:
            return "80%"
        return ""

    def _renew(self, c, reason, now):
        jti = str(c["jti"])
        with self.lock:
            prev = self.asked.get(jti)
            # one request per pass; asked again only when it went unanswered
            if prev and now - prev[1] < RELAY_REASK_SECS:
                return
            self.asked = {jti: (reason, now)}
        self.ask(reason, jti)

    def used(self, tok):
        """The relay road is about to carry tok: renew it if little is left."""
        c = self.claims(tok)
        if c:
            now = time.time()
            why = self._due(c, now, True)
            if why:
                self._renew(c, why, now)

    def refused(self):
        """The relay's gate refused this login's pass: a new one, once a minute."""
        now = time.time()
        if now - self.refused_at >= 60:
            self.refused_at = now
            self.ask("refused")

    def tick(self):
        if not getattr(self.cfg, "relay_url", "") or getattr(self.cfg, "relay_token", ""):
            return
        now = time.time()
        tok = relay_pass(self.cfg)
        if not tok:
            if now >= self.missing_at:
                self.missing_wait = RELAY_MISSING_SECS if not self.missing_wait else min(
                    self.missing_wait * 2, RELAY_MISSING_MAX_SECS)
                self.missing_at = now + self.missing_wait
                self.ask("missing")
            return
        self.missing_wait, self.missing_at = 0, 0.0
        c = self.claims(tok)
        cur = str(c["jti"]) if c else "frl1"
        if cur != self.seen:
            if self.seen is not None:
                self.log(ev="relay_pass_new", reason=self.pending or "-", kind="frl2" if c else "frl1",
                         jti=cur[:8], exp=c["exp"] if c else "-")
                self.pending = ""
                try:
                    os.unlink(self.cfg.relay_want)
                except (OSError, AttributeError):
                    pass
            self.seen = cur
        if c:
            why = self._due(c, now, False)
            if why:
                self._renew(c, why, now)


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
        ne = node_env(getattr(self.cfg, "node_env", None))
        hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        tok = ne.get("CCQUOTA_TOKEN", "")
        if not hub:
            t, why = "trusted", "no hub: a standalone login"
        elif not loopback_ok(hub):
            t, why = "untrusted", "hub URL not allowed here (%s)" % hub
        elif not tok:
            t, why = "untrusted", "no node token: a client-only computer"
        else:
            try:
                req = urllib.request.Request(hub_dial(hub) + "/v1/node/self", headers={"Authorization": "Bearer " + tok})
                with urllib.request.urlopen(req, timeout=10) as r:
                    body = json.loads(r.read() or b"{}")
                raw = body.get("trust")
                if raw is None:
                    # every hub since #1968 answers one (T600 took the no-record
                    # fallback): a silent answer is not a trust (fail closed)
                    t, why = "untrusted", "hub: no trust in /v1/node/self"
                else:
                    t = "trusted" if str(raw).lower() in ("trusted", "true", "1") else "untrusted"
                    why = "hub: %s" % raw
                if body.get("credsep_gate"):
                    # the hub leases this login no token until it is separated
                    # (issue #2295): every session goes central, as untrusted
                    t, why = "untrusted", "hub: %s — this login is not credential-separated" % body["credsep_gate"]
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
    def probe_route(self):
        """relay | direct | "" — the road the last probe judged this login by
        (issue #3364): relay = this machine's egress is not served, the relay's is."""
        d = read_json(getattr(self.cfg, "probe_path", "") or env("FLEET_CRED_PROBE", os.path.join(conf_dir(), "node-probe.json")), None)
        return str(d.get("route") or "") if isinstance(d, dict) else ""

    def probe(self, provider):
        """reachable | unreachable | unsupported_region | none (never probed)."""
        if env("FLEET_PROBE_FORCE_UNREACHABLE") == "1":
            return "unreachable"
        d = read_json(getattr(self.cfg, "probe_path", "") or env("FLEET_CRED_PROBE", os.path.join(conf_dir(), "node-probe.json")), None)
        if not isinstance(d, dict):
            return "none"
        return str(d.get("anthropic" if provider == "claude" else "openai", "none")) or "none"

    def leases_nothing(self):
        """A person's pod (render.py --cred-central): nothing is ever leased into
        it (node.env CCQUOTA_FLEET_CREDS=0) and a central proxy is named — the
        rule fleet-node-probe.sh and the launchers' _fc_sep / _fx_sep already
        read (#4185, #3554). Its login holds no credential file, so a trusted
        word from the hub must not send it direct (issue #4290: a principal the
        credsep gate does not hold went direct and every turn was 403 nocred)."""
        if not getattr(self.cfg, "central_set", False):
            return False
        return node_env(getattr(self.cfg, "node_env", None)).get("CCQUOTA_FLEET_CREDS") == "0"

    def candidates(self, provider, has_hub_cred):
        """-> ([route, …] best first, reason)."""
        with self.lock:
            trust, twhy = self.trust or "unknown", self.trust_why
        relay = bool(self.cfg.relay_url and relay_pass(self.cfg))
        if trust != "trusted":
            return ["central"], "%s (%s) → central, no credential file is read" % (trust, twhy)
        if self.leases_nothing():
            return ["central"], "trusted + nothing leased in (node.env CCQUOTA_FLEET_CREDS=0, " \
                "FLEET_CRED_CENTRAL_URL set) → central, no credential file is read"
        p = self.probe(provider)
        if relay and self.probe_route() == "relay":
            # the probe judged this login by the relay (issue #3364): this
            # machine's egress is not served even where the API answers
            order, why = ["relay", "direct"], "trusted + probe route relay (local %s)" % p
        elif p in ("reachable", "none"):
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


# ---- one login's half ----------------------------------------------------------
# ---- a trial person's 活页 key (task XA4R) ----------------------------------
# A trial's session publishes its web pages through `space` (bin/mcp-space.py →
# 127.0.0.1:<port>/space/mcp). The key that opens the person's 活页 workspace is
# the hub's: asked here with the login's node token (POST /v1/node/livepage-token
# — the hub opens the account the first time), kept in this process's memory
# only until 5 minutes before its end, put on the forwarded request in place of
# the session's own credential. Never written, never logged, never in an answer.
SPACE_URL_DEFAULT = "https://space.24haowan.com"  # oss-ok: 活页's public MCP, the one partner a trial publishes to (XA4R)
SPACE_TOKEN_PATH = "/v1/node/livepage-token"


def iso_epoch(v):
    """Aware RFC3339 → epoch seconds; 0 on junk or a missing timezone.
    Self-contained: protected LIB installs ship only this proxy and launcher.
    Build datetime directly for old Python, truncating Go nanoseconds to µs.
    """
    try:
        import datetime
        m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?([Zz]|[+-]\d{2}:\d{2})", v)
        if not m:
            return 0
        year, month, day, hour, minute, second, fraction, offset = m.groups()
        tz = datetime.timezone.utc
        if offset not in ("Z", "z"):
            oh, om = int(offset[1:3]), int(offset[4:6])
            if oh > 23 or om > 59:
                return 0
            delta = datetime.timedelta(hours=oh, minutes=om)
            tz = datetime.timezone(-delta if offset[0] == "-" else delta)
        return datetime.datetime(int(year), int(month), int(day), int(hour), int(minute), int(second),
            int((fraction or "")[:6].ljust(6, "0")), tzinfo=tz).timestamp()
    except (TypeError, ValueError, OverflowError, OSError):
        return 0


def space_tunnel():
    """-> (host, port) of the egress proxy 活页 is reached through, or None (direct).
    A person's pod REJECTs the public internet and goes out through the cluster's
    egress (deploy/k8s/egress): FLEET_CRED_SPACE_PROXY, else HTTPS_PROXY, else the
    pod's /etc/fleet-devnet.env (fleet-node-linux.py writes it every start)."""
    v = env("FLEET_CRED_SPACE_PROXY") or env("HTTPS_PROXY") or env("https_proxy")
    if not v:
        try:
            for line in open(env("FLEET_DEVNET_ENV", "/etc/fleet-devnet.env")):
                k, _, val = line.strip().partition("=")
                if k == "HTTPS_PROXY" and val:
                    v = val
                    break
        except OSError:
            pass
    if not v or v == "off":
        return None
    u = urlsplit(v if "://" in v else "http://" + v)
    return (u.hostname, u.port or 3128) if u.hostname else None


class SpaceKey:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.Lock()
        self.tok, self.exp = "", 0.0
        self.seen = (0.0, 0, None)   # GET's last answer: (when, status, body)

    def hub(self, method):
        """-> (status, answer) of the hub's LivePageTokenNodePath."""
        ne = node_env(getattr(self.cfg, "node_env", None))
        hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        tok = ne.get("CCQUOTA_TOKEN", "")
        if not hub or not tok:
            return 503, {"code": "no_node", "message": "no node token on this login (node.env)"}
        if not loopback_ok(hub):
            return 503, {"code": "no_node", "message": "the hub address is neither https nor loopback"}
        req = urllib.request.Request(hub_dial(hub) + SPACE_TOKEN_PATH, data=b"{}" if method == "POST" else None,
                                     method=method, headers={"Authorization": "Bearer " + tok,
                                                             "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, {"code": "hub", "message": "HTTP %d" % e.code}
        except Exception as e:
            return 503, {"code": "hub_unreachable", "message": "the hub: %s" % type(e).__name__}

    def status(self):
        """GET, kept a minute: may this login's person publish to 活页 here."""
        with self.lock:
            at, code, a = self.seen
            if a is not None and time.time() - at < 60:
                return code, a
        code, a = self.hub("GET")
        a = {k: v for k, v in (a if isinstance(a, dict) else {}).items() if k != "token"}
        with self.lock:
            self.seen = (time.time(), code, a)
        return code, a

    def get(self, drop=False):
        """-> (key, new, status, answer): the key, or why there is none."""
        with self.lock:
            if drop:
                self.tok = ""
            if self.tok and time.time() < self.exp - 300:
                return self.tok, False, 200, None
            code, a = self.hub("POST")
            a = a if isinstance(a, dict) else {}
            k = a.pop("token", "")
            if code == 200 and k:
                self.tok = k
                self.exp = iso_epoch(a.get("until")) or time.time() + 3600
                self.seen = (time.time(), 200, {"eligible": True, "ready": True})
                return k, bool(a.get("new")), 200, None
            self.tok = ""
            return "", False, code if code != 200 else 502, a


class Tenant:
    """One login's half of the proxy (issue #2217): its signing key, binds,
    revocations, trust, hub passes, budget, quota readings and log. A per-login
    proxy has exactly one; the machine's shared proxy has one per login, and a
    request or a control call reaches only its own."""

    def __init__(self, cfg, name=""):
        self.cfg, self.name = cfg, name
        self.keys = Keys(cfg.state)
        self.router = Router(cfg)
        self.passes = HubPasses(cfg.state, cfg, self.log)
        self.relay = cfg.relay_keep = RelayKeep(cfg, self.log)
        self.budget = Budget(cfg)
        self.space = SpaceKey(cfg)  # the person's 活页 key (task XA4R; memory only)
        self.extended = set()   # sids whose fcp1 is past its stamp, kept by a live session
        self.skip = {}          # sid -> {route: (until, why)}: a route that refused this session
        self.hubcreds = {}      # sid -> fcp-h1.… handed in over ctl `attach` (memory only)
        self.quota = {}         # sid -> its newest rate-limit reading (issue #1978; memory only)
        self.picks = {("codex", sid): a for sid, a in read_json(os.path.join(cfg.state, "codex-legacy-picks.json"), {}).items()} # (provider, sid) -> the account the proxy picked for it (issue #2412)
        self.paused = set()     # (provider, account) the hub paused: no new pick there (issue #3744)
        self.push_due = False
        self.codex_reads, self.codex_limits = {}, {}
        self.codex_lock = threading.RLock()
        self.capacity_refresh_lock = threading.Lock()
        self.capacity_cache, self.capacity_until, self.capacity_retry = {}, 0, 0
        self.capacity_failures = 0
        self.codex_state = read_json(os.path.join(cfg.state, "codex-routing.json"), {"sessions": {}})
        for sid, record in self.codex_state.get("sessions", {}).items():
            if record.get("account"):
                self.picks[("codex", sid)] = record["account"]

    def log(self, **kv):
        log_line(self.cfg, kv)

    def note_quota(self, sid, provider, acct, route, headers):
        """Keep this answer's rate-limit reading for its session, then kick the push."""
        if sid in ("-", "node"):
            return
        rd = rl_reading(provider, headers)
        if provider == "codex":
            h = {k.lower(): v for k, v in headers}
            full = any((_num(h.get("x-codex-%s-used-percent" % w)) or 0) >= 100 for w in ("primary", "secondary"))
            if full:
                with Proxy.lock:
                    Proxy.limited[(provider, acct)] = limit_until(provider, headers, b"")
                    self.codex_limits[acct] = Proxy.limited[(provider, acct)]
        if not rd:
            return
        rd.update(provider=provider, acct=acct, route=route, ts=int(time.time()))
        with Proxy.lock:
            self.quota[sid] = rd
            if provider == "codex":
                self.codex_reads[acct] = rd
            if self.cfg.store and acct and acct != "-":
                Proxy.reads[(provider, acct)] = rd   # what the account pick reads (issue #2412)
            if len(self.quota) > 4096:   # a day of dead sessions, at most: oldest out
                for k in sorted(self.quota, key=lambda k: self.quota[k]["ts"])[:len(self.quota) - 4096]:
                    del self.quota[k]
            # separated, the proxy is another uid: it cannot reach the login's tmux,
            # so the quota watch's tick pulls instead (fleet-proxy-quota.sh push)
            kick = bool(self.cfg.quota_push) and not self.cfg.store and not self.push_due
            self.push_due = self.push_due or kick
        if kick:
            t = threading.Timer(self.cfg.quota_push_secs, self.run_push)
            t.daemon = True
            t.start()

    def run_push(self):
        with Proxy.lock:
            self.push_due = False
        try:
            import subprocess
            subprocess.Popen([self.cfg.quota_push, "push"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            self.log(ev="quota_push_err", err=type(e).__name__)


    # ---- the account pick (issue #2412) --------------------------------------
    # A SEPARATED login does not choose its subscription and does not need to
    # know it: its session credential names no account, and the proxy picks one
    # here, per session — from the accounts this login holds, by the rate-limit
    # readings every answer carries (#1978; on the shared proxy, every login's
    # answers). A session keeps its account (its prompt cache lives there) until
    # that account reaches the ceiling, answers a quota 429, or is limited; then
    # the next request runs on the one with the most room, the session none the
    # wiser. Unread accounts rank in the middle (PICK_UNKNOWN).
    def held(self, provider):
        if provider == "codex":
            return tenant_labels(self.cfg, "codex")   # the pool's and the store's own homes
        out = {k.split(":", 1)[1] for k in pool_index(self.cfg) if k.startswith(provider + ":")}
        if provider == "claude":
            acc = self.cfg.accounts
            out.update(d[:-4] for d in (os.listdir(acc) if os.path.isdir(acc) else [])
                       if d.endswith(".hub") and os.path.isfile(os.path.join(acc, d, ".credentials.json")))
        return sorted(a for a in out if SAFE_LABEL(a))

    @staticmethod
    def used(provider, acct, now):
        """-> the account's higher window (%), None without a reading; a window
        whose reset has passed reads 0 (it refreshed)."""
        rd = Proxy.reads.get((provider, acct))
        if not rd:
            return None
        u = []
        for pk, rk in (("rl5h", "rl_reset5"), ("rl7d", "rl_reset7")):
            v, r = _num(rd.get(pk)), _num(rd.get(rk))
            if v is None:
                continue
            u.append(0.0 if r and 0 < r <= now else v)
        return max(u) if u else None

    def usable(self, provider, acct, now):
        if Proxy.limited.get((provider, acct), 0) > now:
            return False
        u = self.used(provider, acct, now)
        return u is None or u < self.cfg.pick_ceiling

    def capacity_metadata(self):
        return self.capacity_cache if time.time() < self.capacity_until else {}

    def refresh_capacity_metadata(self):
        """Node-authenticated metadata only. 30s cache, 2s timeout; never lease.
        Expired/unreachable metadata cannot supply positive capacity evidence.
        """
        now = time.time()
        with self.capacity_refresh_lock:
            if now < self.capacity_retry:
                return self.capacity_cache if now < self.capacity_until else {}
            self.capacity_retry = now + min(30, 5 * 2**min(self.capacity_failures, 3))
            self.capacity_failures += 1
            try:
                ne = node_env(getattr(self.cfg, "node_env", None))
                hub = (ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
                token = ne.get("CCQUOTA_TOKEN", "")
                if not hub or not token or not loopback_ok(hub):
                    return {}
                req = urllib.request.Request(hub_dial(hub) + "/v1/node/codex-capacity",
                    headers={"Authorization": "Bearer " + token})
                with urllib.request.urlopen(req, timeout=2) as res:
                    raw = res.read(262145)
                if len(raw) > 262144:
                    raise ValueError("metadata too large")
                data = json.loads(raw)
                until = iso_epoch(data.get("expires_at", ""))
                if data.get("policy") != "codex-capacity-v2" or not isinstance(data.get("accounts"), list) or not now < until <= now + 35:
                    raise ValueError("invalid metadata")
                self.capacity_cache, self.capacity_until = data, min(until, now + 30)
                self.capacity_failures = 0
                # Healthy refresh precedes TTL by >=10s (tick polls every5s).
                self.capacity_retry = now + min(20, max(1, (until-now)/2))
            except (OSError, ValueError, TypeError, AttributeError):
                # Do not log exceptions containing a URL, response or credential.
                pass
            return self.capacity_cache if now < self.capacity_until else {}

    def save_codex_state(self):
        write_json(os.path.join(self.cfg.state, "codex-routing.json"), self.codex_state)

    def codex_pick(self, sid, independent=True, refs=(), unknown=False, pin="", preview=False, proposed=False):
        """Serialize per-tenant independent boundaries. References never change a
        binding. Preview executes the same calculation without any routing writes.
        Load is recent LOCAL session reservations (10m), not global concurrency.
        """
        data = self.capacity_metadata()
        now = time.time()
        with self.codex_lock:
            sessions = self.codex_state.setdefault("sessions", {})
            old = sessions.get(sid, {})
            cur = old.get("account", "")
            held = set(self.held("codex"))
            entries, seen = {}, set()
            idx = pool_index(self.cfg)
            for a in sorted(held):
                # Dedup held token aliases without opening any credential file.
                key = idx.get("codex:" + a, "label:" + a)
                if key in seen:
                    continue
                seen.add(key)
                entries[a] = None
            meta = {r["account"]: r for r in data.get("accounts", []) if isinstance(r, dict) and isinstance(r.get("account"), str)}
            # Metadata is authority-scoped; it never adds an unheld account. A
            # fresh answer also prevents stale, withdrawn holds from being picked.
            if data:
                entries = {a: meta[a] for a in entries if a in meta}
            def state(a, proposed_policy):
                r = entries.get(a) or {}
                if not proposed_policy:
                    r = r.get("conservative", r)
                st = r.get("state", "unknown")
                if self.codex_limits.get(a, 0) > now:
                    return "limited"
                # Local full evidence (even stale) survives until observed reset.
                rd = self.codex_reads.get(a, {})
                for pk, rk in (("rl5h", "rl_reset5"), ("rl7d", "rl_reset7")):
                    pct, reset = _num(rd.get(pk)), _num(rd.get(rk))
                    if pct is not None and pct >= 100 and (not reset or reset > now):
                        return "limited"
                return st
            use_capacity = bool(data) and (proposed or data.get("mode") == "active")
            diagnostics = []
            with Proxy.lock:
                # Activity is actually observed here; idle/dead sessions age out.
                loads = {}
                for tt in (list(Proxy.tenants.values()) or [self]):
                    live = read_json(os.path.join(tt.cfg.state, "live.json"), {})
                    revoked = read_lines(os.path.join(tt.cfg.state, "revoked"))
                    for other, v in list(tt.codex_state.get("sessions", {}).items()):
                        if other in revoked or other in live and not pid_alive(live[other]):
                            continue
                        if tt is self and other == sid:
                            continue
                        reservations = dict(v.get("reservations", {}))
                        if v.get("identity"):
                            reservations[v["identity"]] = max(v.get("seen", 0), reservations.get(v["identity"], 0))
                        for identity, at in reservations.items():
                            if identity and at >= now - 600:
                                loads[identity] = loads.get(identity, 0) + 1
            for a, row in entries.items():
                r = dict(row or {})
                score = _num(r.get("score")) if use_capacity else None
                st = state(a, use_capacity)
                if st not in ("usable", "tight") or score is not None and score < 0:
                    score = None
                n = loads.get(r.get("credential_id", ""), 0)
                diagnostics.append(dict(account=a, owner=r.get("owner", "local"),
                    identity=r.get("credential_id", ""), state=st,
                    refresh_healthy=r.get("refresh_healthy", True),
                    paused=r.get("paused", False) or ("codex", a) in self.paused,
                    score=score / (1+n) if score is not None else None,
                    capacity=r.get("capacity", {"status": "metadata_unknown", "calibration_factor": 1, "calibration_status": "pending_matched_observations"}),
                    local_recent_reservations=n))
            byname = {r["account"]: r for r in diagnostics}
            reason, pick = "conservative_unknown", cur
            if pin:
                pick, reason = pin, "explicit_binding"
            elif not independent:
                # Resolve all references to one original subscription. Unknown
                # context stays on the sole account ever used by this session;
                # after any switch ambiguity must refuse, never guess.
                origins = {old.get("refs", {}).get(ref) for ref in refs}
                if refs and None not in origins and len(origins) == 1 and not unknown:
                    origin = next(iter(origins))
                    pick, reason = origin.split("\0", 1)[0], "source_affinity"
                elif old.get("sole") and not refs:
                    pick, reason = old["sole"], "unknown_context_original"
                else:
                    raise ValueError("Codex continuation source unknown; start an independent request")
            else:
                eligible = [r for r in diagnostics if not r["paused"]]
                if not eligible:
                    if cur in byname:
                        pick, reason = cur, "all_paused_keep_current"
                    else:
                        raise ValueError("no unpaused authorized Codex subscription held")
                else:
                    band = {"usable": 0, "tight": 0, "unknown": 2, "limited": 3}
                    def cohort(r):
                        return (r["state"] == "limited", r["owner"] == "pool", not r["refresh_healthy"], band.get(r["state"], 2))
                    best = min(cohort(r) for r in eligible)
                    group = [r for r in eligible if cohort(r) == best]
                    def basis(r):
                        p = r["capacity"].get("profile") or {}
                        return p.get("pool"), p.get("unit"), p.get("basis")
                    comparable = all(r["score"] is not None and basis(r) == basis(group[0]) for r in group)
                    mx = max((r["score"] or 0 for r in group), default=0)
                    def rank(r):
                        tie = hashlib.sha256((sid + "\0" + r["owner"] + "\0" + r["identity"]).encode()).digest()
                        if comparable:
                            return (0 if r["score"] >= mx*.99 else 1, 0 if r["score"] >= mx*.99 else -r["score"], bytes(255-x for x in tie))
                        return ({"usable": 0, "tight": 1, "unknown": 2, "limited": 3}.get(r["state"], 2), bytes(255-x for x in tie))
                    candidate = min(group, key=rank)
                    pick = candidate["account"]
                    reason = "estimated_capacity_reset_local_load" if comparable else "conservative_order"
                    if cur in byname and cur != pick:
                        current = byname[cur]
                        same_basis = comparable and current["score"] is not None and basis(candidate) == basis(current)
                        if now - old.get("changed", now) < 600:
                            pick, reason = cur, "minimum_hold"
                        elif candidate["state"] not in ("usable", "tight"):
                            pick, reason = cur, "no_known_safe_alternative"
                        elif current["state"] != "limited" and (candidate["owner"] != current["owner"] or not candidate["refresh_healthy"]):
                            pick, reason = cur, "policy_boundary"
                        elif current["state"] == "limited":
                            reason = "restore_configured_window_reserve"
                        elif same_basis and candidate["score"] > current["score"] * 1.25:
                            reason = "material_capacity_advantage"
                        elif not same_basis and current["state"] == "tight" and candidate["state"] == "usable":
                            reason = "restore_dual_window_reserve"
                        else:
                            pick, reason = cur, "no_material_gain"
            if not independent or pin:
                # A pin may not redirect known reference context to another sub.
                origins = {old.get("refs", {}).get(ref) for ref in refs}
                if refs:
                    if None in origins or len(origins) != 1 or next(iter(origins)).split("\0", 1)[0] != pick:
                        raise ValueError("Codex continuation conflicts with subscription identity")
                if unknown and old.get("sole") != pick:
                    raise ValueError("Codex unknown continuation cannot change subscription")
                if pick not in held or data and pick not in meta:
                    raise ValueError("Codex source subscription is no longer authorized or held")
                if state(pick, use_capacity) == "limited":
                    raise ValueError("Codex source subscription is exhausted; continuation cannot switch")
            expected_source = ""
            if refs:
                expected_source = next(iter(origins)).split("\0", 1)[1]
            elif unknown:
                expected_source = old.get("sole_source", "")
                if not expected_source:
                    raise ValueError("Codex continuation source identity unknown")
            result = dict(ok=True, account=pick, reason=reason, inputs=diagnostics, expected_source=expected_source,
                mode=data.get("mode", "off"), catalog_revision=data.get("catalog_revision"),
                metadata_status="fresh" if data else "unavailable_or_stale",
                load_basis="local session reservations observed in last 10m; not global concurrency",
                mutates_bindings=not preview)
            if not preview and independent and not pin and pick:
                row = byname.get(pick, {})
                v = dict(old, managed=True, account=pick, identity=row.get("identity", ""), seen=now,
                         changed=old.get("changed", now) if pick == cur else now,
                         sole=old.get("sole", pick) if not cur or cur == pick else "")
                sessions[sid] = v
                if len(sessions) > 4096:
                    for key in sorted(sessions, key=lambda k: sessions[k].get("seen", 0))[:len(sessions)-4096]:
                        del sessions[key]
                self.save_codex_state()
                with Proxy.lock:
                    self.picks[("codex", sid)] = pick
                self.log(ev="pick", provider="codex", sid=sid, acct=pick, why=reason,
                         catalog_revision=result["catalog_revision"], mode=result["mode"], load_basis="local_recent_reservations")
            return result

    def codex_request(self, sid, enrolled, method, path, headers, body, pin=""):
        """Capacity activation is signed at mint. Old credentials never acquire
        new affinity assumptions. Known managed provenance survives rollback.
        """
        data = self.capacity_metadata()
        if enrolled:
            independent, refs, unknown = codex_context(method, path, headers, body)
            has_profiles = any((r.get("capacity") or {}).get("profile") for r in data.get("accounts", []))
            if not independent or data.get("mode") == "active" and has_profiles:
                return self.codex_pick(sid, independent, refs, unknown, pin)
        account = pin or self.pick_account("codex", sid)
        if enrolled:
            # Independent fallback uses the legacy evidence/ceiling, but records
            # that boundary without losing references to earlier subscriptions.
            with self.codex_lock:
                sessions = self.codex_state.setdefault("sessions", {})
                old = sessions.get(sid, {})
                cur = old.get("account")
                sessions[sid] = dict(old, managed=True, account=account, seen=time.time(),
                    changed=old.get("changed", time.time()) if cur == account else time.time(),
                    sole=old.get("sole", account) if not cur or cur == account else "")
                self.save_codex_state()
        return dict(account=account, reason="legacy_binding" if pin else "legacy_conservative_picker", expected_source="")

    def codex_activity(self, sid, account):
        with self.codex_lock:
            sessions = self.codex_state.setdefault("sessions", {})
            v = sessions.setdefault(sid, {"managed": False, "account": account})
            if not v.get("managed"):
                v["account"] = account
            if v:
                now = time.time()
                row = next((r for r in self.capacity_cache.get("accounts", []) if r.get("account") == account), {})
                identity = row.get("credential_id", "")
                if identity:
                    reservations = v.setdefault("reservations", {})
                    reservations[identity] = now
                    v["reservations"] = {k: at for k, at in reservations.items() if at >= now - 600}
                if v.get("account") == account:
                    v["seen"] = now
                self.save_codex_state()

    def codex_record(self, sid, account, refs, source_identity=""):
        if not source_identity:
            return
        with self.codex_lock:
            sessions = self.codex_state.setdefault("sessions", {})
            v = sessions.setdefault(sid, {"managed": True, "account": account, "sole": account, "changed": time.time(), "seen": time.time()})
            if v.get("account") == account:
                row = next((r for r in self.capacity_cache.get("accounts", []) if r.get("account") == account), {})
                if row.get("credential_id"):
                    v["identity"] = row["credential_id"]
            if v.get("sole") == account:
                prior = v.get("sole_source")
                v["sole_source"] = source_identity if not prior or prior == source_identity else ""
            known = v.setdefault("refs", {})
            for ref in refs:
                # A collision is unresolved rather than silently overwritten.
                origin = account + "\0" + source_identity
                known[ref] = origin if ref not in known or known[ref] == origin else None
            if len(known) > 4096:
                v["refs"] = {} # later continuation explicitly unknown
            self.save_codex_state()

    def pick_account(self, provider, sid, avoid=()):
        """-> the account this session's next request runs on ("" = none held)."""
        now = time.time()
        with Proxy.lock:
            cur = self.picks.get((provider, sid))
        mine = self.held(provider)
        if cur and cur not in mine:
            cur = ""        # withdrawn since (issue #3043): never served again
            with Proxy.lock:
                self.picks.pop((provider, sid), None)
        if cur and cur not in avoid and self.usable(provider, cur, now):
            return cur
        held = [a for a in mine if a not in avoid]
        if not held:
            return cur or ""
        live = [a for a in held if (provider, a) not in self.paused]
        held = live or held     # every one paused: still served, never none
        with Proxy.lock:
            load = {}
            for tt in (list(Proxy.tenants.values()) or [self]):
                for (pv, _), a in tt.picks.items():
                    if pv == provider:
                        load[a] = load.get(a, 0) + 1
        def rank(a):
            u = self.used(provider, a, now)
            return (u if u is not None else PICK_UNKNOWN, load.get(a, 0), a)
        good = [a for a in held if self.usable(provider, a, now)]
        nxt = min(good or held, key=rank)
        if nxt != cur:
            with Proxy.lock:
                self.picks[(provider, sid)] = nxt
                if provider == "codex":
                    write_json(os.path.join(self.cfg.state, "codex-legacy-picks.json"),
                        {k[1]: a for k, a in self.picks.items() if k[0] == "codex"})
            u = self.used(provider, nxt, now)
            self.log(ev="pick", sid=sid, provider=provider, acct=nxt, frm=cur or "-",
                     why=("first" if not cur else "full" if cur not in avoid else "limited"),
                     used="-" if u is None else round(u), full=not good)
        return nxt

    def standing(self, provider):
        """-> one row per account this login holds (issue #4606): {acct, usable,
        used (%, None unread), until (epoch: when one that is out comes back; 0 =
        not out, or not said), paused}. Unread is never out."""
        now, rows = time.time(), []
        for a in self.held(provider):
            u = self.used(provider, a, now)
            until = Proxy.limited.get((provider, a), 0)
            until = until if until > now else 0
            rd = Proxy.reads.get((provider, a)) or {}
            for pk, rk in (("rl5h", "rl_reset5"), ("rl7d", "rl_reset7")):
                v, r = _num(rd.get(pk)), _num(rd.get(rk))
                if v is not None and r and r > now and v >= self.cfg.pick_ceiling:
                    until = max(until, r)
            rows.append({"acct": a, "usable": self.usable(provider, a, now),
                         "used": None if u is None else round(u, 1), "until": int(until),
                         "paused": (provider, a) in self.paused})
        return rows

    def repick(self, provider, sid, acct, until):
        """A quota 429 on <acct>: limited until <until>; -> the account to retry
        on, or None (nowhere better: the 429 goes to the session)."""
        with Proxy.lock:
            Proxy.limited[(provider, acct)] = max(until, Proxy.limited.get((provider, acct), 0))
        nxt = self.pick_account(provider, sid, avoid=(acct,))
        return nxt if nxt and nxt != acct and self.usable(provider, nxt, time.time()) else None


PICK_UNKNOWN = 50.0
REJECT_HOLD = int(os.environ.get("FLEET_CRED_REJECT_HOLD") or 900)    # a 401'd account stays out (s)


def limit_until(provider, headers, body, now=None):
    """-> until when a 429 keeps its account out of the pick (issue #2412): a
    quota answer to its reset (else an hour), anything else a minute."""
    now = now or time.time()
    h = {k.lower(): v for k, v in headers}
    text = (body or b"").decode("utf-8", "replace").lower()
    if provider == "claude":
        quota = (h.get("anthropic-ratelimit-unified-status") or "").lower() == "rejected" \
            or "limit" in text and ("usage" in text or "weekly" in text or "reached" in text)
        resets = [_num(h.get(k)) for k in ("anthropic-ratelimit-unified-reset",
                                          "anthropic-ratelimit-unified-5h-reset",
                                          "anthropic-ratelimit-unified-7d-reset")]
    else:
        # Codex's usage limit (issue #4606): `usage_limit_reached`, its reset in
        # the body (resets_at / resets_in_seconds) — or a window at 100 %
        full = [w for w in ("primary", "secondary") if (_num(h.get("x-codex-%s-used-percent" % w)) or 0) >= 100]
        quota = "usage_limit" in text or bool(full)
        resets = [_num(h.get("x-codex-%s-reset-at" % w)) for w in ("primary", "secondary")]
        resets += [now + s for s in (_num(h.get("x-codex-%s-reset-after-seconds" % w)) for w in full) if s]
        try:
            err = json.loads(body or b"{}").get("error") or {}
        except (ValueError, AttributeError):
            err = {}
        if isinstance(err, dict):
            resets.append(_num(err.get("resets_at")))
            if _num(err.get("resets_in_seconds")):
                resets.append(now + _num(err["resets_in_seconds"]))
    if not quota:
        return now + 60
    future = [r for r in resets if r and r > now]
    return min(max(future) if future else now + 3600, now + 7 * 86400)


class LogSink:
    """The shared proxy's own log, for what happens before a request has a login."""

    def __init__(self, cfg):
        self.cfg = cfg

    def log(self, **kv):
        log_line(self.cfg, kv)


def log_line(cfg, kv):
    kv = dict(t=round(time.time(), 3), **kv)
    line = json.dumps(kv, ensure_ascii=False)
    with Proxy.lock:
        if cfg.log:
            try:
                fd = os.open(cfg.log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                with os.fdopen(fd, "a") as f:
                    f.write(line + "\n")
            except OSError:
                pass
        if getattr(cfg, "verbose", False):
            sys.stderr.write(line + "\n"); sys.stderr.flush()


def tok_login(tok):
    """The `lg` a shared-proxy credential names (read, NOT verified: it only
    picks whose key verifies it)."""
    try:
        lg = json.loads(b64d(tok.split(".")[1])).get("lg")
    except Exception:
        return None
    return lg if isinstance(lg, str) else None


# ---- upstream stats (T657) ---------------------------------------------------
UP_FILE, UP_NOW = "upstream-stats.ndjson", "upstream-now.json"
UP_KEEP = 7 * 86400
UP_FAILS = 40       # failure events kept per minute (the counts are always whole)


def up_err_class(e):
    """A connection's OSError → refused · reset · timeout · tls · dns · neterr."""
    if isinstance(e, socket.gaierror):
        return "dns"
    if isinstance(e, ConnectionRefusedError):
        return "refused"
    if isinstance(e, (ConnectionResetError, ConnectionAbortedError, BrokenPipeError)):
        return "reset"
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(e, ssl.SSLError) or isinstance(e, getattr(ssl, "CertificateError", ())):
        return "tls"
    return "neterr"


def up_status_class(code):
    return ("429" if code == 429 else "529" if code == 529 else "5xx" if code >= 500
            else "4xx" if code >= 400 else "ok")


class UpstreamStats:
    """Per-minute counts of every upstream attempt, readable by every login."""

    def __init__(self, d):
        self.d = d
        self.lock = threading.Lock()
        self.cur = None         # the open minute's row
        self.dirty = False
        self.pruned = 0.0

    def record(self, cls, acct, login, sid, route, ms, what):
        now = time.time()
        m = int(now // 60) * 60
        with self.lock:
            if self.cur and self.cur["m"] != m:
                self._close()
            if not self.cur:
                self.cur = {"m": m, "n": 0, "c": {}, "a": {}, "ms_max": 0, "ms_sum": 0, "f": []}
            r = self.cur
            r["n"] += 1
            r["c"][cls] = r["c"].get(cls, 0) + 1
            a = r["a"].setdefault(acct or "-", {})
            a[cls] = a.get(cls, 0) + 1
            r["ms_max"] = max(r["ms_max"], ms)
            r["ms_sum"] += ms
            if cls != "ok" and len(r["f"]) < UP_FAILS:
                r["f"].append({"t": round(now, 1), "c": cls, "acct": acct or "-", "login": login or "-",
                               "sid": sid or "-", "route": route, "ms": ms, "st": what})
            self.dirty = True

    def _write(self, name, text, append=False):
        p = os.path.join(self.d, name)
        flags = os.O_WRONLY | os.O_CREAT | (os.O_APPEND if append else os.O_TRUNC)
        tmp = p if append else "%s.%d.tmp" % (p, os.getpid())
        fd = os.open(tmp, flags, 0o644)
        try:
            os.fchmod(fd, 0o644)    # every login reads it (the proxy's umask is 077)
            os.write(fd, text.encode())
        finally:
            os.close(fd)
        if not append:
            os.replace(tmp, p)

    def _close(self):
        try:
            self._write(UP_FILE, json.dumps(self.cur, separators=(",", ":")) + "\n", append=True)
        except OSError:
            pass
        self.cur = None

    def flush(self, final=False):
        """The tick's: close a finished minute, keep upstream-now.json current,
        prune past UP_KEEP once an hour."""
        now = time.time()
        with self.lock:
            if self.cur and (final or self.cur["m"] != int(now // 60) * 60):
                self._close()
                self.dirty = True
            if self.dirty:
                self.dirty = False
                try:
                    self._write(UP_NOW, json.dumps(self.cur or {"m": int(now // 60) * 60, "n": 0},
                                                   separators=(",", ":")) + "\n")
                except OSError:
                    pass
            if now - self.pruned >= 3600:
                self.pruned = now
                self._prune(now)

    def _prune(self, now):
        p = os.path.join(self.d, UP_FILE)
        try:
            with open(p) as f:
                lines = f.readlines()
        except OSError:
            return
        keep = []
        for ln in lines:
            try:
                if json.loads(ln)["m"] >= now - UP_KEEP:
                    keep.append(ln)
            except (ValueError, KeyError, TypeError):
                pass
        if len(keep) != len(lines):
            try:
                self._write(UP_FILE, "".join(keep))
            except OSError:
                pass


def up_stats_open(d):
    if env("FLEET_CRED_UPSTREAM_STATS", "1") == "0" or not d:
        return None
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        return None
    return UpstreamStats(d)


# ---- the proxy ---------------------------------------------------------------
class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    lock = threading.Lock()
    T = None        # the one tenant of a per-login proxy
    tenants = {}    # the shared proxy (issue #2217): login -> Tenant
    reads = {}      # (provider, account) -> its newest reading, separated tenants (issue #2412)
    limited = {}    # (provider, account) -> until: a quota 429 keeps it out of the pick
    sink = None     # where a request is logged before it has a tenant
    ustats = None   # UpstreamStats: every attempt's class, per minute (T657)
    fixed = None    # a login's old port on the shared proxy: that login's tenant
    t = None

    cfg = property(lambda self: self.t.cfg)
    keys = property(lambda self: self.t.keys)
    router = property(lambda self: self.t.router)
    passes = property(lambda self: self.t.passes)
    budget = property(lambda self: self.t.budget)

    def log_message(self, fmt, *a):
        pass

    # draining (T595): a request in flight is finished, the connection closed
    # after it — said in the answer, so the client opens its next one to the new proxy
    def parse_request(self):
        ok = BaseHTTPRequestHandler.parse_request(self)
        if ok:
            self._busy = True
            with DRAIN_LOCK:
                DRAIN["busy"] += 1
        return ok

    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        finally:
            if getattr(self, "_busy", False):
                self._busy = False
                with DRAIN_LOCK:
                    DRAIN["busy"] -= 1
            if DRAIN["on"]:
                self.close_connection = True

    def end_headers(self):
        if DRAIN["on"] and not self.close_connection:
            self.send_header("Connection", "close")
        BaseHTTPRequestHandler.end_headers(self)

    def log(self, **kv):
        (self.t or Proxy.sink or Proxy.T).log(**kv)

    @staticmethod
    def log_any(**kv):
        (Proxy.sink or Proxy.T).log(**kv)

    @classmethod
    def pick(cls, tok):
        """-> the tenant a request is for (None: the shared proxy cannot tell)."""
        if cls.fixed or not cls.tenants:
            return cls.fixed or cls.T
        # one tenant (a person's pod, issue #4674): its sessions' hub passes are
        # never registered (no credsep.json — the hub checks them), and what its
        # per-login proxy minted before the switch names no login: the same state
        # dir, the same key, so that tenant takes both
        one = next(iter(cls.tenants.values())) if len(cls.tenants) == 1 else None
        if is_hub_pass(tok):
            c = hub_claims(tok)
            for t in cls.tenants.values():
                if c and c["id"] in t.passes.held:
                    return t
            return one
        lg = tok_login(tok)
        return cls.tenants.get(lg) if lg else one

    def fail(self, code, msg, typ="authentication_error", ecode="", extra=None):
        err = {"type": typ, "message": "cred-proxy: " + msg}
        if ecode:
            err["code"] = ecode
        err.update(extra or {})
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
        self.extra_resp, self.space_retry = [], False
        if path.startswith("http://") or path.startswith("https://"):
            self.log(ev="deny", path=path.split("?")[0], why="absolute-URI proxying disabled")
            return self.fail(403, "absolute-URI proxying disabled", "permission_error")
        if path.startswith("/hub/"):
            return self.hub_broker(inbound, path[len("/hub"):], body, t0)
        if path.startswith("/space/"):
            return self.space(inbound, path, body, t0)
        provider = "codex" if path.startswith("/codex/") else "claude"
        if provider == "codex":
            why = codex_refused(self.command, path)
            if why:
                self.log(ev="deny", path=path.split("?")[0], why=why)
                return self.fail(403, why, "permission_error")
        seen = sorted("%s=%s" % (k, red(k, v)) for k, v in inbound.items())
        tok = ""
        if inbound.get("authorization", "").lower().startswith("bearer "):
            tok = inbound["authorization"][7:].strip()
        tok = tok or inbound.get("x-api-key", "")
        if not tok and path.split("?")[0] in PUBLIC:
            self.t = self.fixed or self.T or next((self.tenants[k] for k in sorted(self.tenants)), None)
            if not self.t:
                return self.fail(503, "no login has joined this machine's credential proxy", "api_error")
            return self.send(["direct"], provider, path, body, None, "-", "-", seen, t0, public=True)
        self.t = self.pick(tok)
        if not self.t:
            # the shared proxy (issue #2217): the credential names no login it serves
            why = ("hub pass not registered here (fleet-session-cred.sh mint registers it)"
                   if is_hub_pass(tok) else "session credential names no login served here")
            self.log(ev="deny", path=path.split("?")[0], why=why, hdrs=seen)
            return self.fail(401, why)
        if is_hub_pass(tok):
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
                first = sid not in self.t.extended
                self.t.extended.add(sid)
            if first:
                self.passes.stats["local"] += 1
                self.log(ev="renew", kind="local", sid=sid)
        # root's pin (bind.json) first, then the account the credential names
        # (not separated, a root mint, a named Codex home); none: the proxy picks
        pin = read_json(os.path.join(self.cfg.state, "bind.json"), {}).get(sid)
        acct = pin or claims.get("acct") or ""
        if not pin and provider == "codex" and self.cfg.store and acct == "default":
            # separated, the default Codex home holds no credential (issue #4606):
            # a session minted for it — before #4606, or by an older launcher — is
            # the proxy's to place, so a weekly-full `default` is skipped and a
            # usage-limit 429 moves it; a named home (<homes>/<L>) stays its pin
            acct = ""
        self.auto = not acct and bool(self.cfg.store)
        self.codex_policy = provider == "codex" and self.cfg.store and claims.get("capacity_policy") == 2
        self.codex_expected_source = ""
        if provider == "codex" and self.cfg.store:
            try:
                decision = self.t.codex_request(sid, self.codex_policy, self.command, path, inbound, body, acct)
                acct, self.codex_expected_source = decision["account"], decision["expected_source"]
            except ValueError as e:
                return self.fail(409, str(e), "codex_affinity_unavailable")
        elif self.auto:
            acct = self.t.pick_account(provider, sid)
        if self.auto:
            if not acct:
                self.log(ev="deny", sid=sid, path=path.split("?")[0], why="no account held")
                return self.fail(403, no_account_why(self.cfg, provider), "permission_error")
        hubcred = self.t.hubcreds.get(sid)
        if hubcred:
            hubcred = self.passes.best(hubcred)
        order, _ = self.router.candidates(provider, bool(hubcred))
        self.send(order, provider, path, body, hubcred, sid, acct, seen, t0)

    def hub_broker(self, inbound, path, body, t0):
        """/hub/<path> → the hub, with the node token put in (separated mode only)."""
        tok = inbound.get("authorization", "")[7:].strip() if inbound.get("authorization", "").lower().startswith("bearer ") else ""
        bare = path.split("?")[0].rstrip("/")
        if not tok:
            # nothing to name a login with (issue #4906): say that, not «names no login»
            self.t = self.fixed or self.T
            self.log(ev="deny", path="/hub" + bare, why="no credential")
            return self.fail(401, "no node credential on the request (fleet-cred-proxy.sh node-token mints one)")
        self.t = self.pick(tok)
        if not self.t:
            self.log(ev="deny", path="/hub" + bare, why="names no login served here")
            return self.fail(401, "node credential names no login served here")
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
        ne = node_env(self.cfg.node_env)
        hub, ntok = (ne.get("CCQUOTA_HUB_URL") or "").rstrip("/"), ne.get("CCQUOTA_TOKEN", "")
        if not hub or not ntok:
            return self.fail(403, "no node token here", "permission_error")
        if not loopback_ok(hub):
            return self.fail(403, "hub URL is neither https nor loopback", "permission_error")
        out = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() != "authorization"}
        out["Authorization"] = "Bearer " + ntok
        # the warm road (T672): only for a remote https hub, named as the
        # forwarder knows it (before any in-cluster dial)
        fs = hub_fwd_sock()
        self.hub_fwd = (fs, hub) if fs and (hub.startswith("https://") or env("CCQUOTA_HUB_SOCK")) else None
        hub = hub_dial(hub)
        self.upstream(hub, urlsplit(hub).path.rstrip("/") + path, out, body, "hub", "node", "-", "node",
                      [], t0, "hub", can_switch=False)

    def space(self, inbound, path, body, t0):
        """/space/mcp → 活页's MCP with the person's key (task XA4R); /space/status
        says whether this login's person may publish there. Only a session's own
        credential gets either."""
        bare = path.split("?")[0]
        q = path[len(bare):]
        tok = inbound.get("authorization", "")[7:].strip() if inbound.get("authorization", "").lower().startswith("bearer ") else ""
        self.t = self.pick(tok) if tok else None
        if not self.t:
            self.t = self.fixed or self.T
            self.log(ev="deny", path=bare, why="no session credential")
            return self.fail(401, "no session credential")
        if is_hub_pass(tok):
            if not hub_claims(tok):
                self.log(ev="deny", path=bare, why="not a hub pass")
                return self.fail(401, "not a hub pass")
            sid = "h-" + hashlib.sha256(tok.encode()).hexdigest()[:10]
        else:
            claims, why = self.keys.verify(tok, live=live_session(self.cfg.state))
            if not claims:
                self.log(ev="deny", path=bare, why=why)
                return self.fail(401, why)
            sid = claims["sid"]
        seen = sorted("%s=%s" % (k, red(k, v)) for k, v in inbound.items())

        def say(code, a):
            b = json.dumps(a if isinstance(a, dict) else {}, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        if bare == "/space/status":
            code, a = self.t.space.status()
            self.log(ev="space_status", sid=sid, status=code, code=(a or {}).get("code", ""))
            return say(code, a)
        if bare != "/space/mcp":
            self.log(ev="deny", sid=sid, path=bare, why="only /space/mcp")
            return self.fail(404, "only /space/mcp is forwarded", "not_found_error")
        base = getattr(self.cfg, "space_url", "") or SPACE_URL_DEFAULT
        if not loopback_ok(base):
            return self.fail(403, "活页's address is not an allowed upstream", "permission_error")
        for again in (False, True):
            key, new, code, a = self.t.space.get(drop=again)
            if not key:
                self.log(ev="deny", sid=sid, path=bare, why="no 活页 key", status=code, code=(a or {}).get("code", ""))
                return say(code, a)
            out = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP and k.lower() not in ("authorization", "x-api-key", "host", "content-length")}
            out["Authorization"] = "Bearer " + key
            if body is not None:
                out["Content-Length"] = str(len(body))
            self.extra_resp = [("X-Fleet-Space-New", "1")] if new else []
            self.space_retry = not again
            r = self.upstream(base, urlsplit(base).path.rstrip("/") + "/mcp" + q, out, body, "space", sid, "-",
                              "space", seen, t0, "space", can_switch=False)
            if r != "space401":
                return None
        return None

    def plan(self, order, sid):
        """-> (routes, skipped): drop the routes that refused this session
        recently (all of them = try again); `skipped` says why, for a refusal."""
        now = time.time()
        with self.lock:
            sk = {r: u for r, u in self.t.skip.get(sid, {}).items() if u[0] > now}
            self.t.skip[sid] = sk
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
            keep = getattr(c, "relay_keep", None)
            if keep:
                keep.used(put["X-Fleet-Relay"])
        if public:
            return base, upath, put, set(), "none"
        if route == "central":
            # never a credential file: the hub credential is the whole auth
            put["Authorization"] = "Bearer " + hubcred
            return base, upath, put, drop, "none"
        if provider == "codex":
            path = pool_resolve(c, "codex", acct) or codex_auth_path(c, acct)
            at, aid, fp = codex_tokens(path)
            self.codex_source_identity = codex_ref("account", aid) if aid else ""
            self.codex_seen = (os.path.dirname(path), fp)
            put["Authorization"] = "Bearer " + at
            drop.add("chatgpt-account-id")
            if aid:   # ALWAYS the bound account's: a session never picks its workspace (#1912)
                put["chatgpt-account-id"] = aid
        else:
            pp = pool_resolve(c, "claude", acct)
            if pp:
                with open(pp) as f:
                    put["Authorization"] = "Bearer " + json.load(f)["claudeAiOauth"]["accessToken"]
            else:
                put["Authorization"] = "Bearer " + claude_token(c.accounts, acct)
        return base, upath, put, drop, "file"

    def send(self, order, provider, path, body, hubcred, sid, acct, seen, t0, public=False):
        over = "" if public else self.budget.over()
        if over:
            # the person is over their budget (issue #1977): 403, never retried
            self.log(ev="deny", sid=sid, acct=acct, path=path.split("?")[0], why=BUDGET_CODE)
            ra = self.budget.reset_at()
            return self.fail(403, over, "permission_error", BUDGET_CODE, {"reset_at": ra} if ra else None)
        order, skipped = self.plan(order, sid)
        order = [r for r in order
                 if (r != "relay" or (self.cfg.relay_url and relay_pass(self.cfg))) and (r != "central" or (self.cfg.central_url and hubcred))]
        if not order:
            # permanent: 403, which neither client retries (never a 503)
            # name the router's word and its reason (issue #4623: a separated
            # login the hub gated as not_separated read only «no usable route»)
            trust, twhy = self.router.trust or "unknown", self.router.trust_why or "-"
            self.log(ev="deny", sid=sid, path=path.split("?")[0], why="no usable route — trust %s (%s)" % (trust, twhy))
            return self.fail(403, "this machine routes central (untrusted) and this session has no "
                             "hub session credential (or no central proxy is configured) — trust %s: %s"
                             % (trust, twhy), "permission_error")
        last, tried = None, list(skipped)
        for i, route in enumerate(order):
            nxt = order[i + 1] if i + 1 < len(order) else None
            for hops in range(4):
                res = self.attempt(route, nxt, provider, path, body, hubcred, sid, acct, seen, t0, public, tried, hops)
                if not (isinstance(res, tuple) and res[0] == "acct"):
                    break
                acct = res[1]       # a quota 429 on a picked account: the same request on the next one
            if res is None:
                return
            if isinstance(res, tuple):          # ("nocred", the answer): this route has no credential
                last = res[1]
                continue
            tried.append("%s: %s" % (route, res))
            # a region refusal / a connection that never opened: next route, same request
            with self.lock:
                self.t.skip.setdefault(sid, {})[route] = (time.time() + self.cfg.switch_ttl, res)
            self.log(ev="route_switch", sid=sid, acct=acct, provider=provider, frm=route, to=nxt, why=res)
        code, msg, typ = last or (502, "no route answered", "api_error")
        self.fail(code, msg, typ)

    def attempt(self, route, nxt, provider, path, body, hubcred, sid, acct, seen, t0, public, tried, hops):
        """One request on one route and account: upstream's answer, or
        ("nocred", the refusal) when this account has no credential here."""
        try:
            base, upath, put, drop, cred = self.target(route, provider, path, acct, hubcred, public)
        except (OSError, KeyError, ValueError, TypeError) as e:
            self.log(ev="nocred", sid=sid, acct=acct, route=route, err=type(e).__name__)
            tried.append("%s: no credential for %s" % (route, acct))
            return ("nocred", (403, "no upstream credential for account %s" % acct, "permission_error"))
        if provider == "codex" and cred == "file" and getattr(self, "codex_expected_source", ""):
            if self.codex_expected_source != getattr(self, "codex_source_identity", ""):
                self.fail(409, "Codex continuation source identity changed", "codex_affinity_unavailable")
                return None
        out = {k: v for k, v in self.headers.items() if k.lower() not in HOP and k.lower() not in drop}
        if provider == "claude" and cred == "file":
            betas = [b.strip() for k, v in out.items() if k.lower() == "anthropic-beta"
                     for b in v.split(",") if b.strip()]
            out = {k: v for k, v in out.items() if k.lower() != "anthropic-beta"}
            if OAUTH_BETA not in betas:
                betas.append(OAUTH_BETA)
            out["anthropic-beta"] = ",".join(betas)
        if cred == "file":
            # a metered answer must be readable here (issue #3407): Claude Code
            # asks for br / zstd, which the meter cannot open — and a gzip'd
            # stream it could not open either counted nothing
            ae = meter_accept(" ".join(v for k, v in out.items() if k.lower() == "accept-encoding"))
            out = {k: v for k, v in out.items() if k.lower() != "accept-encoding"}
            out["Accept-Encoding"] = ae
        out.update(put)
        # a picked account (issue #2412) may hand a quota 429 to the next one — three times at most
        self.rehome = getattr(self, "auto", False) and cred == "file" and hops < 3
        return self.upstream(base, upath, out, body, route, sid, acct, cred, seen, t0, provider,
                             can_switch=nxt is not None, tried=tried)

    def ustat(self, route, acct, sid, cls, t1, what):
        """One attempt into the upstream stats (T657) — never the hub broker's."""
        st = Proxy.ustats
        if st is None or route == "hub":
            return
        try:
            st.record(cls, acct, getattr(self.cfg, "name", "") or "", sid, route,
                      int((time.time() - t1) * 1000), what)
        except Exception:
            pass

    def upstream(self, base, upath, out, body, route, sid, acct, cred, seen, t0, provider, can_switch, tried=()):
        """Send one request. None = answered (the response went to the client);
        a reason string = switch routes (only when can_switch). On the LAST
        route after others failed (`tried`), a refusal of the same kind is the
        proxy's own answer naming every road (issue #1975) — never the
        upstream's bare "Request not allowed"."""
        u = urlsplit(base)
        out["Host"] = u.netloc
        t1 = time.time()
        fwd = getattr(self, "hub_fwd", None) if provider == "hub" else None
        again = lambda: self.upstream(base, upath, out, body, route, sid, acct, cred, seen, t0, provider, can_switch, tried)
        if fwd:
            # the forwarder refuses before it sends anything, so the direct road
            # after a refusal (or nobody on the socket) never sends twice
            conn = UnixHTTPConnection(fwd[0], self.cfg.timeout)
            out["X-Fleet-Hub"] = fwd[1]
            try:
                conn.connect()
            except OSError:
                self.hub_fwd = None
                out.pop("X-Fleet-Hub", None)
                return again()
        elif u.scheme == "http":
            conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=self.cfg.timeout)
        elif provider == "space" and space_tunnel():
            # 活页 from a person's pod: a CONNECT through the cluster's egress, TLS end to end
            th, tp = space_tunnel()
            conn = http.client.HTTPSConnection(th, tp, timeout=self.cfg.timeout,
                                               context=ssl._create_default_https_context())
            conn.set_tunnel(u.hostname, u.port or 443)
        else:
            conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=self.cfg.timeout,
                                               context=ssl._create_default_https_context())  # fleet_tls's when it loaded
        try:
            fwd or conn.connect()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, route=route, phase="connect", err=type(e).__name__)
            self.ustat(route, acct, sid, up_err_class(e), t1, type(e).__name__)
            if can_switch:
                return "connect failed (%s)" % type(e).__name__
            self.fail(502, "upstream %s unreachable: %s%s" % (route, type(e).__name__,
                      "".join("; " + t for t in tried)), "api_error")
            return None
        try:
            conn.request(self.command, upath, body=body, headers=out)
            r = conn.getresponse()
            if fwd and r.getheader("X-Fleet-Hubfwd") == "refused":
                r.read()
                conn.close()
                self.hub_fwd = None
                out.pop("X-Fleet-Hub", None)
                return again()
        except OSError as e:
            self.log(ev="upstream_err", sid=sid, route=route, phase="request", err=type(e).__name__)
            self.ustat(route, acct, sid, up_err_class(e), t1, type(e).__name__)
            self.fail(502, "upstream %s: %s" % (route, type(e).__name__), "api_error")
            return None
        ttfb = time.time() - t0
        self.ustat(route, acct, sid, up_status_class(r.status), t1, r.status)
        if provider in ("claude", "codex"):
            self.t.note_quota(sid, provider, acct, route, r.getheaders())
        first = b""
        if r.status == 429 and provider == "codex" and cred == "file":
            first = r.read(65536)
            with Proxy.lock:
                Proxy.limited[(provider, acct)] = limit_until(provider, r.getheaders(), first)
                self.t.codex_limits[acct] = Proxy.limited[(provider, acct)]
        if r.status == 429 and provider != "codex" and getattr(self, "rehome", False):
            first = r.read(65536)
            nxt = self.t.repick(provider, sid, acct, limit_until(provider, r.getheaders(), first))
            if nxt:
                conn.close()
                self.log(ev="acct_switch", sid=sid, provider=provider, frm=acct, to=nxt, why="429")
                return ("acct", nxt)
        if r.status == 401 and provider == "claude" and getattr(self, "rehome", False):
            # the provider refused this account's token (issue #3744): revoked
            # upstream, or a subscription the hub deleted that this machine still
            # held. Out of the pick for REJECT_HOLD and the same request on the
            # next account — never a 401 the session can only answer with /login.
            # A relay's own 401 (its pass) names no provider error: passed on.
            first = r.read(65536)
            if route == "direct" or b"authentication_error" in first:
                with Proxy.lock:
                    Proxy.limited[(provider, acct)] = time.time() + REJECT_HOLD
                nxt = self.t.pick_account(provider, sid, avoid=(acct,))     # any held one beats a dead one
                if nxt and nxt != acct:
                    conn.close()
                    self.log(ev="acct_switch", sid=sid, provider=provider, frm=acct, to=nxt, why="401")
                    return ("acct", nxt)
        if r.status == 403:
            first = r.read(65536)
            if route == "relay" and b"relay_refused" in first and getattr(self.cfg, "relay_keep", None):
                self.cfg.relay_keep.refused()   # the relay's gate, not the provider (#3561)
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
        if r.status == 401 and provider == "space" and getattr(self, "space_retry", False):
            r.read()     # the kept 活页 key went stale: ask the hub once more
            conn.close()
            return "space401"
        if provider == "codex" and cred == "file":
            if r.status == 401:
                first = r.read(65536)
            codex_verdict(getattr(self, "codex_seen", None), route, r.status, first)
        if getattr(self, "codex_policy", False) and cred == "file" and 200 <= r.status < 300:
            self.t.codex_record(sid, acct, [codex_ref("header:" + k.lower(), v)
                for k, v in r.getheaders() if k.lower() in ("x-codex-turn-state", "x-codex-routing-hint") and v],
                getattr(self, "codex_source_identity", ""))
        self.send_response_only(r.status, r.reason)
        rh = [(k, v) for k, v in r.getheaders() if k.lower() not in HOP]
        for k, v in rh:
            self.send_header(k, v)
        for k, v in getattr(self, "extra_resp", None) or ():
            self.send_header(k, v)
        chunked = self.command != "HEAD" and r.status not in (204, 304)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        size = 0
        # metered here only when this login's credential was used (issue #1977):
        # the central route's answer is the cluster proxy's to count
        meter = Meter(r.getheader("Content-Encoding", "")) if cred == "file" and 200 <= r.status < 300 else None
        if meter and getattr(self, "codex_policy", False):
            meter.on_references = lambda refs: self.t.codex_record(sid, acct, refs, getattr(self, "codex_source_identity", ""))
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
            split = meter.split()
            if provider == "codex":
                self.t.codex_activity(sid, acct)
                if getattr(self, "codex_policy", False):
                    self.t.codex_record(sid, acct, meter.references, getattr(self, "codex_source_identity", ""))
            extra["tokens"] = split["in"] + split["cache_write"] + split["out"]
            self.budget.add(provider, extra["tokens"], split, self.budget.worker(sid), acct, meter.model)
            if extra["tokens"] <= 0 and provider in ("claude", "codex") and self.command == "POST":
                # a 2xx answer the meter could read nothing from (issue #3407):
                # said once per answer, never silent
                extra["meter_miss"] = meter.enc or "no usage"
                self.budget.miss(extra["meter_miss"])
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


# ---- the machine's one copy (issue #2311) -------------------------------------
# On the shared proxy a lease is filed ONCE for the whole machine: under
# <shared state>/pool/<kind>/<key>/, where <key> hashes the access token itself
# — never the account's label, which two people may both use (the hub's key is
# principal + provider + account). Each tenant keeps only its index,
# <tenant state>/pool.json {"<kind>:<label>": key}: a tenant is served a pool
# file only through its own index, so two logins share a file exactly when they
# leased the same token, and a token one login never leased stays out of reach
# of its sessions. A file no index names any more is removed.
POOL_FILE = {"claude": ".credentials.json", "codex": "auth.json"}
POOL_LOCK = threading.Lock()


def pool_key(kind, data):
    d = json.loads(data)
    tok = d["claudeAiOauth"]["accessToken"] if kind == "claude" else d["tokens"]["access_token"]
    if not tok:
        raise ValueError("no access token")
    return hashlib.sha256(("%s\0%s" % (kind, tok)).encode()).hexdigest()[:32]


def own_path(cfg, kind, label):
    """Where a tenant's own copy lived before the pool (and goes back to on uninstall)."""
    if kind == "claude":
        return os.path.join(cfg.accounts, label + ".hub", ".credentials.json")
    return codex_auth_path(cfg, label)


def pool_resolve(cfg, kind, label):
    """-> the pool file for <kind>:<label>, folding a tenant's own copy in first
    (issue #2849): on the shared proxy a label resolves to the pool's copy only,
    and an own accounts/<label>.hub left from before (a join's hold, an install)
    moves in on the first read. "" when there is none (the own path is read)."""
    pp = pool_entry(cfg, kind, label)
    if pp or not getattr(cfg, "pool", ""):
        return pp
    own = own_path(cfg, kind, label)
    if not os.path.isfile(own):
        return ""
    try:
        with POOL_LOCK:
            with open(own, "rb") as f:
                pool_put(cfg, kind, label, f.read())
    except (OSError, ValueError, KeyError, TypeError) as e:
        sys.stderr.write("fleet-cred-proxy: pool: %s %s:%s left in place (%s)\n" % (cfg.name, kind, label, e))
    return pool_entry(cfg, kind, label)


def pool_index(cfg):
    d = read_json(os.path.join(cfg.state, "pool.json"), {})
    return d if isinstance(d, dict) else {}


def pool_entry(cfg, kind, label):
    """-> the pool file a tenant's index names for <kind>:<label>, or ""."""
    k = pool_index(cfg).get("%s:%s" % (kind, label)) if getattr(cfg, "pool", "") else ""
    return os.path.join(cfg.pool, kind, k, POOL_FILE[kind]) if k else ""


def pool_put(cfg, kind, label, data):
    """File one lease in the pool, point the tenant's index at it, drop its own copy."""
    key = pool_key(kind, data)
    dst = os.path.join(cfg.pool, kind, key, POOL_FILE[kind])
    if not os.path.isfile(dst):
        write_private(dst, data)
    idx = pool_index(cfg)
    idx["%s:%s" % (kind, label)] = key
    write_json(os.path.join(cfg.state, "pool.json"), idx)
    own = own_path(cfg, kind, label)
    if os.path.lexists(own):
        os.unlink(own)
        try:
            os.rmdir(os.path.dirname(own))
        except OSError:
            pass
    return key


def lease_expiries(cfg):
    """{label: expiresAt (ms) or None} of every hub-leased Claude account this
    tenant holds — its pool entries and any own copy."""
    out = {}
    labels = {k.split(":", 1)[1] for k in pool_index(cfg) if k.startswith("claude:")}
    acc = cfg.accounts
    labels.update(d[:-4] for d in (os.listdir(acc) if os.path.isdir(acc) else []) if d.endswith(".hub"))
    for label in sorted(labels):
        if not SAFE_LABEL(label):
            continue
        try:
            with open(pool_entry(cfg, "claude", label) or own_path(cfg, "claude", label)) as f:
                o = json.load(f)["claudeAiOauth"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if o.get("accessToken"):
            out[label] = o.get("expiresAt")
    return out


def account_quota(t):
    """{provider: {account: its newest rate-limit reading}} (issue #2412) — the
    readings the proxy picks a SEPARATED login's accounts by, for that login to
    read (it cannot read the hub's quota, and its own sessions see only the
    accounts they ran on). On the machine's shared proxy
    every login's sessions count, but only for an account THIS login also holds
    (its pool index, its leases, its own readings): percentages and resets, never
    a session id, a login or a token."""
    held = set()
    for k in pool_index(t.cfg):
        kind, _, label = k.partition(":")
        held.add((kind, label))
    if t.cfg.store:
        held.update(("claude", label) for label in lease_expiries(t.cfg))
    cutoff = time.time() - 86400
    out = {}
    with Proxy.lock:
        for tt in (list(Proxy.tenants.values()) or [t]):
            for v in tt.quota.values():
                key = (v.get("provider") or "claude", v.get("acct") or "")
                if not key[1] or v.get("ts", 0) <= cutoff or (tt is not t and key not in held):
                    continue
                cur = out.setdefault(key[0], {}).get(key[1])
                if cur is None or v["ts"] > cur["ts"]:
                    out[key[0]][key[1]] = {f: v[f] for f in ("rl5h", "rl7d", "rl_reset5", "rl_reset7", "ts") if f in v}
    return out


def tenant_labels(cfg, kind):
    """-> every <kind> label this tenant holds: its pool index and own copies."""
    out = {k.split(":", 1)[1] for k in pool_index(cfg) if k.startswith(kind + ":")}
    if kind == "claude":
        acc = cfg.accounts
        out.update(d[:-4] for d in (os.listdir(acc) if os.path.isdir(acc) else []) if d.endswith(".hub"))
    else:
        cx = cfg.codex_homes
        out.update(d for d in (os.listdir(cx) if os.path.isdir(cx) else [])
                   if os.path.isfile(os.path.join(cx, d, "auth.json")))
    return sorted(a for a in out if SAFE_LABEL(a))


def tenant_unstore(t, kind, label):
    """One account leaves this tenant (`unstore`, `prune`): its index entry, its
    own copy, the pool file no tenant names any more, every pick and pin of it."""
    cfg = t.cfg
    with POOL_LOCK:
        idx = pool_index(cfg)
        had = idx.pop("%s:%s" % (kind, label), None)
        if had:
            write_json(os.path.join(cfg.state, "pool.json"), idx)
        own = own_path(cfg, kind, label)
        if os.path.lexists(own):
            os.unlink(own)
            try:
                os.rmdir(os.path.dirname(own))
            except OSError:
                pass
        if getattr(cfg, "pool", ""):
            pool_gc(cfg.pool, [x.cfg for x in Proxy.tenants.values()] or [cfg])
    with Proxy.lock:
        for k in [k for k, a in t.picks.items() if k[0] == kind and a == label]:
            del t.picks[k]
        bp = os.path.join(cfg.state, "bind.json")
        b = read_json(bp, {})
        pinned = [sid for sid, a in (b.items() if isinstance(b, dict) else []) if a == label]
        for sid in pinned:
            del b[sid]
        if pinned:
            write_json(bp, b)
    t.log(ev="unstore", kind=kind, acct=label, pool=(had or "-")[:12], unpinned=len(pinned))


def pool_gc(pool, cfgs):
    """Remove every pool file no tenant's index names."""
    keep = set()
    for c in cfgs:
        keep.update("%s/%s" % (k.split(":", 1)[0], v) for k, v in pool_index(c).items())
    for kind in POOL_FILE:
        d = os.path.join(pool, kind)
        for k in os.listdir(d) if os.path.isdir(d) else []:
            if "%s/%s" % (kind, k) not in keep:
                shutil.rmtree(os.path.join(d, k), ignore_errors=True)


def pool_adopt(cfgs):
    """A tenant that joined before the pool: its own copies move in, one each."""
    n = 0
    for c in cfgs:
        found = []
        acc = c.accounts
        for d in sorted(os.listdir(acc)) if os.path.isdir(acc) else []:
            if d.endswith(".hub") and SAFE_LABEL(d[:-4]):
                found.append(("claude", d[:-4]))
        cx = c.codex_homes
        for d in sorted(os.listdir(cx)) if os.path.isdir(cx) else []:
            if SAFE_LABEL(d):
                found.append(("codex", d))
        for kind, label in found:
            p = own_path(c, kind, label)
            if not os.path.isfile(p):
                continue
            try:
                with open(p, "rb") as f:
                    pool_put(c, kind, label, f.read())
                n += 1
            except (OSError, ValueError, KeyError, TypeError) as e:
                sys.stderr.write("fleet-cred-proxy: pool: %s %s:%s left in place (%s)\n" % (c.name, kind, label, e))
    return n


def codex_tokens(path):
    """-> (access token, account id, credential fingerprint). The fingerprint is
    ccquota's credential_version (sha256 of access NUL refresh), so a verdict
    names the exact credential it was given on and nothing more."""
    with open(path) as f:
        t = json.load(f)["tokens"]
    fp = hashlib.sha256((t["access_token"] + "\0" + (t.get("refresh_token") or "")).encode()).hexdigest()
    return t["access_token"], t.get("account_id"), fp


def codex_rejections(cfg):
    rejected = []
    labels = set(tenant_labels(cfg, "codex"))
    if os.path.isfile(cfg.codex_auth):
        labels.add("default")
    with POOL_LOCK:
        for label in sorted(labels):
            path = pool_entry(cfg, "codex", label) or codex_auth_path(cfg, label)
            try:
                bundle = read_json(path, {})
                if bundle.get("tokens", {}).get("refresh_token") != "hub-managed":
                    continue
                access, _, fingerprint = codex_tokens(path)
                verdict = read_json(os.path.join(os.path.dirname(path), ".ccquota-upstream.json"), {})
                if verdict.get("credential_version") != fingerprint or verdict.get("state") != "rejected":
                    continue
                code = verdict.get("error")
                if code not in ACCESS_REJECT and code != "401":
                    continue
                rejected.append(dict(provider="codex", account=label,
                                     fingerprint=hashlib.sha256(access.encode()).hexdigest(),
                                     error=code))
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
    return rejected


def codex_target_auth(t, label):
    """Metadata-only preflight for a transfer, scoped by ctl_tenant's peer uid.

    Use the same account path as target(), without minting a pass or moving
    files. Unknown, missing, expired and upstream-rejected leases fail closed.
    Central-only routes need their own remote attestation; a local lease cannot
    prove that the central service will admit a new target session.
    """
    def refuse(reason):
        return dict(ok=True, verdict='refuse', reason=reason)
    if not SAFE_LABEL(label):
        return refuse('invalid Codex proxy account')
    order, _ = t.router.candidates('codex', False)
    if not order or order[0] == 'central':
        return refuse('central Codex target cannot be verified by the local credential proxy')
    if order[0] == 'relay' and not relay_pass(t.cfg):
        return refuse('Codex relay has no usable pass')
    path = pool_entry(t.cfg, 'codex', label) or codex_auth_path(t.cfg, label)
    try:
        token, account, fingerprint = codex_tokens(path)
        parts = token.split('.')
        if len(parts) != 3 or not account:
            return refuse('Codex proxy lease has no subscription identity')
        claims = json.loads(base64.urlsafe_b64decode(parts[1] + '=' * (-len(parts[1]) % 4)))
        expiry = _num(claims.get('exp'))
        if expiry is None or expiry <= time.time():
            return refuse('Codex proxy lease is expired or has no expiry')
        verdict = read_json(os.path.join(os.path.dirname(path), '.ccquota-upstream.json'), {})
        if isinstance(verdict, dict) and verdict.get('credential_version') == fingerprint and verdict.get('state') == 'rejected':
            return refuse('upstream rejected this Codex proxy lease')
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return refuse('Codex proxy lease is missing or unreadable')
    return dict(ok=True, verdict='ok', reason='')


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


def no_account_why(cfg, provider):
    """The 403 a session gets when this login holds no <provider> account
    (issue #3155): the hub's last lease verdict made plain — why, and who can
    change it — never «run /login», which a separated login cannot do."""
    head = "this login holds no %s account the proxy could pick" % provider
    v = read_json(os.path.join(cfg.state, "lease.json"), {})
    if not isinstance(v, dict):
        v = {}
    if v.get("state") == "refused":
        why = v.get("message") or v.get("reason") or "refused"
        return ("%s — the hub refuses to lease this login any account (%s%s). /login cannot fix this: "
                "ask the fleet operator who opened your login to grant it a subscription."
                % (head, why, " · " + v["reason"] if v.get("reason") and v.get("message") else ""))
    if v.get("state") == "ok" and provider == "claude" and not v.get("claude"):
        return ("%s — the hub leased this login no claude account (none is allowed for you on this machine: "
                "the subscription allowlists, or an empty pool). /login cannot fix this: ask the fleet "
                "operator to allow you a subscription." % head)
    if not v:
        return ("%s — this login has not leased an account from the hub yet (its node program has not run "
                "a lease, or cannot reach the hub). Try again in a minute; if it stays, ask the fleet operator."
                % head)
    return head


# ---- the control socket ------------------------------------------------------
def credential_inspect(req, t):
    """Read-only proof of the original pass; ctl_tenant has checked peer uid.

    Never best()/renew(), pick(), mint(), attach(), or forward here. Responses
    are a small non-secret scope, never tokens, claims, URLs or error bodies.
    """
    refuse = {"ok": False, "err": "original credential scope cannot be verified"}
    try:
        expected = req['expected']
        if req.get('version') != 1 or req.get('provider') != 'codex':
            return refuse
        token = req['cred']
        if is_hub_pass(token):
            claims = hub_claims(token)  # lookup only; the Hub verifies BOTH signatures
            if not claims:
                return refuse
            with t.passes.lock:
                effective = t.passes.held.get(claims['id'], token)
            ne = node_env(getattr(t.cfg, 'node_env', None))
            # One authoritative pair; an ambient URL is never combined with a
            # token from another source at this new verification boundary.
            hub, node = ne.get('CCQUOTA_HUB_URL', '').rstrip('/'), ne.get('CCQUOTA_TOKEN', '')
            if not hub or not node or not loopback_ok(hub):
                return refuse
            request = urllib.request.Request(hub_dial(hub) + '/v1/fleet/session-cred/inspect', method='POST',
                data=json.dumps(dict(original=token, effective=effective, worker_id=expected['worker_id'], provider='codex')).encode(),
                headers={'Authorization': 'Bearer ' + node, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=8) as response:
                data = json.loads(response.read(32769))
            if data.get('id') != expected.get('hub_id') or data.get('worker_id') != expected['worker_id']:
                return refuse
            return dict(ok=True, scope=dict(kind='central', port=t.cfg.bound_port, **{k: data[k] for k in
                        ('id', 'principal', 'worker_id', 'machine', 'endpoint_id', 'provider', 'binding')}))
        with Proxy.lock:
            claims, why = t.keys.verify(token, live=live_session(t.cfg.state))
            if why or not claims or (claims.get('lg') and claims['lg'] != t.name):
                return refuse
            sid = claims['sid']
            worker = read_json(os.path.join(t.cfg.state, 'workers.json'), {}).get(sid)
            wrapper = read_json(os.path.join(t.cfg.state, 'live.json'), {}).get(sid)
            override = read_json(os.path.join(t.cfg.state, 'bind.json'), {}).get(sid)
            account = override or claims['acct']
            if (sid != expected['sid'] or worker != expected['worker_id'] or wrapper != expected['wrap_pid']
                    or account != expected['account'] or not pid_alive(wrapper)):
                return refuse
            if codex_target_auth(t, account).get('verdict') != 'ok':
                return refuse
            return dict(ok=True, scope=dict(kind='local', port=t.cfg.bound_port, sid=sid, worker_id=worker, wrap_pid=wrapper,
                        account=account, original_account=claims['acct'], override=override, tenant=t.name))
    except Exception:
        return refuse


def ctl_handle(req, t):
    cfg = t.cfg
    op = req.get("op")
    if op == 'credential-inspect':
        return credential_inspect(req, t)
    if op == "target-auth":
        return codex_target_auth(t, req.get("account") or "")
    if op == "upstream-rejections":
        if not cfg.store:
            return {"ok": False, "err": "upstream-rejections: not separated"}
        return {"ok": True, "rejected": codex_rejections(cfg)}
    if op == "route":
        if req.get("refresh"):
            t.router.refresh(t.log)
        prov = req.get("provider") or "claude"
        order, why = t.router.candidates(prov, False)
        return {"ok": True, "route": order[0], "reason": why, "candidates": order,
                "trust": t.router.trust or "unknown", "probe": t.router.probe(prov),
                "provider": prov}
    if op == "mint":
        acct = req.get("account") or ""
        # separated, a Claude session names no account (issue #2412): the proxy
        # picks it per request — a login's --account is ignored (logged), only
        # root names one. No provider: a mint for a named account (--account).
        if cfg.store and req.get("provider") == "claude" and not req.get("_root"):
            if acct:
                t.log(ev="mint_account_ignored", sid=req.get("sid") or "-", acct=acct)
            acct = ""
        elif cfg.store and req.get("provider") == "codex" and not acct:
            pass    # the default home's session (issue #4606): the proxy picks, as for Claude
        elif not acct or "/" in acct or acct.startswith("."):
            return {"ok": False, "err": "mint: --account LABEL"}
        sid = req.get("sid") or "s-" + secrets.token_hex(4)
        existing = ("codex", sid) in t.picks or sid in read_json(os.path.join(cfg.state, "live.json"), {}) or sid in read_json(os.path.join(cfg.state, "workers.json"), {})
        managed = t.codex_state.get("sessions", {}).get(sid, {}).get("managed", False)
        tok = t.keys.mint(acct, sid, int(req.get("ttl") or cfg.ttl), lg=t.name,
            capacity=req.get("provider") == "codex" and (managed or not existing and t.capacity_metadata().get("mode") == "active"))
        wid = req.get("worker") or ""
        if wid and WORKER_RE.match(wid):
            # the session's worker_id (its fleet credential's, issue #3376): its
            # usage is reported under it, so the hub files it under its task
            p = os.path.join(cfg.state, "workers.json")
            with Proxy.lock:
                d = read_json(p, {}); d[sid] = wid; write_json(p, d)
        wrap = int(req.get("wrap") or 0)
        if wrap > 1:
            # the session's wrapper: while it lives, this credential outlives its stamp
            p = os.path.join(cfg.state, "live.json")
            with Proxy.lock:
                d = read_json(p, {})
                d = {k: v for k, v in d.items() if pid_alive(v)}
                d[sid] = wrap; write_json(p, d)
        t.log(ev="mint", sid=sid, acct=acct or "(proxy picks)")
        return {"ok": True, "token": tok, "sid": sid}
    if op == "rebind":
        sid, acct = req.get("sid") or "", req.get("account") or ""
        if not sid or not acct:
            return {"ok": False, "err": "rebind: --sid and --account"}
        if cfg.store and not req.get("_root"):
            # separated, the account is the proxy's to pick (issue #2412): a pin is root's
            t.log(ev="deny", path="ctl rebind", sid=sid, acct=acct, why="separated: only root pins an account")
            return {"ok": False, "err": "rebind: this login's account is the credential proxy's to pick "
                                        "(separated, issue #2412) — only root pins one"}
        p = os.path.join(cfg.state, "bind.json")
        with Proxy.lock:
            d = read_json(p, {}); d[sid] = acct; write_json(p, d)
        t.log(ev="rebind", sid=sid, acct=acct)
        return {"ok": True}
    if op == "revoke":
        sid = req.get("sid") or ""
        if not sid:
            return {"ok": False, "err": "revoke: --sid"}
        with Proxy.lock:
            fd = os.open(os.path.join(cfg.state, "revoked"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.write(fd, (sid + "\n").encode()); os.close(fd)
            t.hubcreds.pop(sid, None)
            t.quota.pop(sid, None)
            for k in [k for k in t.picks if k[1] == sid]:
                del t.picks[k]
            b = read_json(os.path.join(cfg.state, "bind.json"), {})
            if b.pop(sid, None) is not None:
                write_json(os.path.join(cfg.state, "bind.json"), b)
            for f in ("live.json", "workers.json"):
                p = os.path.join(cfg.state, f)
                d = read_json(p, {})
                if d.pop(sid, None) is not None:
                    write_json(p, d)
        t.log(ev="revoke", sid=sid)
        return {"ok": True}
    if op == "attach":
        sid, hc = req.get("sid") or "", (req.get("cred") or "").strip()
        if not sid or not is_hub_pass(hc):
            return {"ok": False, "err": "attach: --sid and a %s. credential on stdin" % "./".join(HUB_TAGS)}
        with Proxy.lock:
            t.hubcreds[sid] = hc
        t.log(ev="attach", sid=sid)
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
        if kind not in POOL_FILE:
            return {"ok": False, "err": "store: kind claude|codex"}
        if getattr(cfg, "pool", ""):
            # the shared proxy: one copy for the machine (issue #2311)
            try:
                with POOL_LOCK:
                    key = pool_put(cfg, kind, label, data)
                    pool_adopt([cfg])   # an own copy left from before goes in too (issue #2849)
                    pool_gc(cfg.pool, [x.cfg for x in Proxy.tenants.values()])
            except (OSError, ValueError, KeyError, TypeError) as e:
                return {"ok": False, "err": "store: %s" % e}
            t.log(ev="store", kind=kind, acct=label, bytes=len(data), pool=key[:12])
            return {"ok": True}
        write_private(own_path(cfg, kind, label), data)
        t.log(ev="store", kind=kind, acct=label, bytes=len(data))
        return {"ok": True}
    if op == "unstore":
        # the node agent's withdrawal (issue #3043): a subscription allowlist no
        # longer lets THIS login use <kind>:<label>. Only this tenant's index
        # entry and own copy go — a pool file another login still names stays
        # (pool_gc counts references), so one person's narrowing never takes a
        # token from another login it is still allowed to. Its pins and picks
        # naming the label go too, so no session keeps running on it.
        if not cfg.store:
            return {"ok": False, "err": "unstore: not separated (FLEET_CRED_STORE unset)"}
        kind, label = req.get("kind") or "", req.get("label") or ""
        if kind not in POOL_FILE or not SAFE_LABEL(label):
            return {"ok": False, "err": "unstore: kind claude|codex and a safe label"}
        tenant_unstore(t, kind, label)
        return {"ok": True}
    if op == "prune":
        # the node agent's whole lease (issue #3744): every account this tenant
        # holds that the hub's latest answer no longer lists — deleted, paused
        # out of the pool, the person's row gone — goes as an `unstore` would.
        # The hub's word is the lease, and a lease never lists an account the
        # hub dropped: without this, its copy stayed and a session bound to it
        # got the upstream's 401 («OAuth token revoked · Please run /login»).
        if not cfg.store:
            return {"ok": False, "err": "prune: not separated (FLEET_CRED_STORE unset)"}
        keep = req.get("keep")
        if not isinstance(keep, dict) or any(not isinstance(keep.get(k, []), list) for k in POOL_FILE):
            return {"ok": False, "err": "prune: keep {claude: [labels], codex: [labels]}"}
        gone = []
        for kind in POOL_FILE:
            want = {x for x in keep.get(kind) or [] if isinstance(x, str)}
            for label in tenant_labels(cfg, kind):
                if label not in want:
                    tenant_unstore(t, kind, label)
                    gone.append("%s:%s" % (kind, label))
        # a paused pool account (claude-fleet#1990) is still leased so a session
        # on it finishes; the pick starts no NEW session there
        pz = req.get("paused") if isinstance(req.get("paused"), dict) else {}
        paused = {(k, x) for k in POOL_FILE for x in (pz.get(k) or []) if isinstance(x, str) and SAFE_LABEL(x)}
        with Proxy.lock:
            was, t.paused = t.paused, paused
        if gone or paused != was:
            t.log(ev="prune", gone=gone, paused=sorted("%s:%s" % p for p in paused))
        return {"ok": True, "gone": gone}
    if op == "lease":
        # the node agent's last lease verdict (issue #3155): refused (the hub's
        # reason) or ok with N claude accounts — what a session that finds no
        # account is told, instead of a bare 403 Claude Code reads as /login
        if not cfg.store:
            return {"ok": False, "err": "lease: not separated (FLEET_CRED_STORE unset)"}
        v = {"state": req.get("state") if req.get("state") in ("ok", "refused") else "",
             "reason": str(req.get("reason") or "")[:64], "message": str(req.get("message") or "")[:300]}
        try:
            v["claude"] = max(0, int(req.get("claude") or 0))
        except (TypeError, ValueError):
            v["claude"] = 0
        if not v["state"]:
            return {"ok": False, "err": "lease: state ok|refused"}
        path = os.path.join(cfg.state, "lease.json")
        old = read_json(path, {})
        if not isinstance(old, dict) or {k: old.get(k) for k in v} != v:
            v["at"] = int(time.time())
            write_json(path, v)
            t.log(ev="lease", state=v["state"], reason=v["reason"] or "-", claude=v["claude"])
        return {"ok": True}
    if op == "pool-drop":
        # the node's pool sweep (issue #2850): a token the hub no longer lists
        # leaves the machine — every tenant's index entry naming it, then its
        # file. Root only: it reaches past the calling tenant.
        if not req.get("_root"):
            return {"ok": False, "err": "pool-drop: root only"}
        if not getattr(cfg, "pool", ""):
            return {"ok": False, "err": "pool-drop: not the shared proxy"}
        kind, key = req.get("kind") or "", req.get("key") or ""
        if kind not in POOL_FILE or not re.match(r"^[0-9a-f]{32}$", key):
            return {"ok": False, "err": "pool-drop: kind claude|codex and a 32-hex key"}
        dropped = []
        with POOL_LOCK:
            cfgs = [x.cfg for x in Proxy.tenants.values()]
            for c in cfgs:
                idx = pool_index(c)
                gone = [k for k, v in idx.items() if v == key and k.startswith(kind + ":")]
                for k in gone:
                    del idx[k]
                    dropped.append(k.split(":", 1)[1])
                if gone:
                    write_json(os.path.join(c.state, "pool.json"), idx)
            shutil.rmtree(os.path.join(cfg.pool, kind, key), ignore_errors=True)
            pool_gc(cfg.pool, cfgs)
        t.log(ev="pool_drop", kind=kind, pool=key[:12], accts=",".join(sorted(set(dropped))) or "-")
        return {"ok": True, "labels": sorted(set(dropped))}
    if op == "accounts":
        # a separated login cannot read its leased files: when each Claude
        # account's lease runs out — the expiry only, never a token (issue #2308)
        if not cfg.store:
            return {"ok": False, "err": "accounts: not separated"}
        return {"ok": True, "claude": lease_expiries(cfg)}
    if op == "probe":
        pp = getattr(cfg, "probe_path", "") or env("FLEET_CRED_PROBE")
        if not cfg.store or not pp:
            return {"ok": False, "err": "probe: not separated"}
        d = json.loads(req.get("data") or "null")
        if not isinstance(d, dict):
            return {"ok": False, "err": "probe: a JSON object"}
        write_json(pp, d)
        return {"ok": True}
    if op == "relay_probe":
        return dict(relay_probe(cfg, t.router), ok=True)
    if op == "relay":
        # separated: the relay pass fleet-relay-cred.sh minted for the login
        if not cfg.store:
            return {"ok": False, "err": "relay: not separated"}
        tok = (req.get("data") or "").strip()
        if not tok or len(tok) > 4096 or any(c.isspace() for c in tok):
            return {"ok": False, "err": "relay: one pass on stdin"}
        write_private(os.path.join(cfg.state, "relay.token"), tok.encode() + b"\n")
        t.log(ev="relay_pass")
        try:
            t.relay.tick()   # the request it answers is done: logged, its file gone (#3561)
        except Exception:
            pass
        return {"ok": True}
    if op == "node-token":
        if not cfg.broker:
            return {"ok": False, "err": "node-token: no hub broker here (not separated)"}
        ne = node_env(cfg.node_env)
        if not ne.get("CCQUOTA_TOKEN"):
            return {"ok": False, "err": "node-token: no node token here"}
        port = cfg.bound_port
        return {"ok": True, "token": t.keys.mint("-", "node", int(req.get("ttl") or 600), NODE_TAG, lg=t.name),
                "url": "http://127.0.0.1:%d/hub" % port}
    if op == "node-hash":
        if not cfg.broker:
            return {"ok": False, "err": "node-hash: no hub broker here (not separated)"}
        nt = node_env(cfg.node_env).get("CCQUOTA_TOKEN", "")
        if not nt:
            return {"ok": False, "err": "node-hash: no node token here"}
        return {"ok": True, "hash": hashlib.sha256(nt.encode()).hexdigest()}
    if op == "quota":
        with Proxy.lock:
            q = {k: dict(v) for k, v in t.quota.items() if v["ts"] > time.time() - 86400}
        return {"ok": True, "quota": q}
    if op == "account-quota":
        return {"ok": True, "accounts": account_quota(t)}
    if op == "capacity-preview":
        sid = req.get("sid")
        if not isinstance(sid, str) or not sid or len(sid) > 256:
            return {"ok": False, "err": "capacity-preview: --sid required"}
        pin = read_json(os.path.join(cfg.state, "bind.json"), {}).get(sid, "")
        return t.codex_pick(sid, pin=pin, preview=True, proposed=True)
    if op == "standing":
        # issue #4606, read-only: may a pick land on each account, and when does
        # one that is out come back — percentages and times, never a token
        if not cfg.store:
            return {"ok": False, "err": "standing: not separated (the login picks its own account)"}
        prov = req.get("provider") or "codex"
        if prov not in POOL_FILE:
            return {"ok": False, "err": "standing: --provider claude|codex"}
        return {"ok": True, "provider": prov, "accounts": t.standing(prov)}
    if op == "picks":
        # which account the proxy runs each of this login's sessions on (issue #2412): read-only
        with Proxy.lock:
            pk = {"%s:%s" % (pv, sid): a for (pv, sid), a in t.picks.items()}
        b = read_json(os.path.join(cfg.state, "bind.json"), {})
        return {"ok": True, "picks": pk, "pinned": b if isinstance(b, dict) else {}}
    if op == "pass":
        # the shared proxy (issue #2217): a session's hub pass is filed under its
        # login here, so a request carrying it is that login's (renewal, log)
        hc = (req.get("cred") or "").strip()
        if not is_hub_pass(hc) or not hub_claims(hc):
            return {"ok": False, "err": "pass: a %s. credential on stdin" % "./".join(HUB_TAGS)}
        t.passes.best(hc)
        t.log(ev="pass", pass_id=hub_claims(hc)["id"])
        return {"ok": True}
    if op == "machine":
        # the shared proxy (issue #2217), to any login it serves: how many live
        # sessions each login has on it — counts only, never a sid or an account
        if not Proxy.tenants:
            return {"ok": False, "err": "machine: not the shared proxy"}
        now, logins = time.time(), {}
        for name, tt in sorted(Proxy.tenants.items()):
            live = read_json(os.path.join(tt.cfg.state, "live.json"), {})
            n = sum(1 for p in live.values() if pid_alive(p))
            n += sum(1 for v in list(tt.passes.held.values()) if (hub_claims(v) or {}).get("exp", 0) > now)
            logins[name] = {"live": n}
        return {"ok": True, "port": cfg.bound_port, "user": cfg.run_user, "version": cfg.version,
                "logins": logins}
    if op == "status":
        out = {"ok": True, "pid": os.getpid(), "port": cfg.bound_port, "separated": bool(cfg.store),
               "trust": t.router.trust or "unknown", "trust_why": t.router.trust_why,
               "relay": bool(cfg.relay_url), "relay_pass": bool(relay_pass(cfg)),
               "central": cfg.central_url or "", "budget": t.budget.view(),
               "renew": dict(t.passes.stats), "hub_passes": len(t.passes.held)}
        if Proxy.tenants:
            out.update(shared=True, login=t.name, logins=sorted(Proxy.tenants), user=cfg.run_user,
                       version=cfg.version)
        return out
    return {"ok": False, "err": "unknown op %r" % op}


def ctl_serve(sock, cfg):
    sock.settimeout(1.0)    # shared with a successor for a moment (T595): never block in accept
    while not DRAIN["on"]:
        try:
            c, _ = sock.accept()
        except socket.timeout:
            continue
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


def ctl_tenant(c, req):
    """-> (tenant, None), or (None, the refusal): whose control call this is.
    A per-login proxy has one tenant; separated, its socket is 0666 and the peer
    uid is the gate. The shared proxy (issue #2217) answers each login's uid with
    that login's tenant and nothing else — the kernel's word (getpeereid /
    SO_PEERCRED), never the caller's; root names the login (`as`)."""
    if not Proxy.tenants:
        cfg = Proxy.T.cfg
        if cfg.ctl_uid is not None:
            try:
                u = peer_uid(c)
            except OSError:
                u = -1
            if u not in (cfg.ctl_uid, 0):
                return None, ("peer uid %d" % u, "not this login's proxy")
        return Proxy.T, None
    try:
        u = peer_uid(c)
    except OSError:
        u = -1
    if env("FLEET_CRED_SHARED_TEST") == "1" and isinstance(req.get("peer_uid"), int):
        u = req["peer_uid"]     # the selftest's sandbox only: every login there is one uid
    if u == 0:
        t = Proxy.tenants.get(req.get("as") or "")
        return (t, None) if t else (None, ("root, as %r" % req.get("as"), "root: say which login (--as)"))
    mine = [t for t in Proxy.tenants.values() if t.cfg.uid == u]
    if len(mine) != 1:
        return None, ("peer uid %d" % u, "this login has not joined this machine's credential proxy")
    if req.get("as") and req["as"] != mine[0].name:
        return None, ("peer uid %d as %s" % (u, req["as"]), "not your login")
    return mine[0], None


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
            req = json.loads(buf.split(b"\n", 1)[0] or b"{}")
            req = req if isinstance(req, dict) else {}
        except ValueError:
            req = {}
        req.pop("_root", None)          # never the caller's word
        try:
            u = peer_uid(c)
        except OSError:
            u = -1
        if env("FLEET_CRED_SHARED_TEST") == "1" and isinstance(req.get("peer_uid"), int):
            u = req["peer_uid"]
        req["_root"] = u == 0
        t, why = ctl_tenant(c, req)
        if not t:
            Proxy.log_any(ev="deny", path="ctl", why=why[0])
            c.sendall((json.dumps({"ok": False, "err": why[1]}) + "\n").encode())
            return
        try:
            res = ctl_handle(req, t)
        except Exception as e:
            res = {"ok": False, "err": "%s: %s" % (type(e).__name__, e)}
        c.sendall((json.dumps(res) + "\n").encode())
    except OSError:
        pass
    finally:
        c.close()


def ctl_call(state, req):
    if env("FLEET_CRED_AS"):                # root at the shared proxy: which login
        req["as"] = env("FLEET_CRED_AS")
    if env("FLEET_CRED_TEST_PEER_UID"):     # selftest seam (honoured only by a FLEET_CRED_SHARED_TEST proxy)
        req["peer_uid"] = int(env("FLEET_CRED_TEST_PEER_UID"))
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


def relay_probe(cfg, router):
    """The relay road, measured (issue #3364): one request per provider through
    the relay with the pass and NO credential — what a session sends, minus the
    subscription. Each answer reads as fleet-node-probe.sh's words: reachable
    (the provider answered, an auth error included) · unsupported_region (a
    region refusal through the relay) · unreachable (no answer, a gateway error,
    or the relay's own gate refused the pass). `peer` is the address the relay
    answered from — the probe asks where it is."""
    if not cfg.relay_url:
        return {"relay": False, "why": "no relay configured (FLEET_CRED_RELAY_URL)"}
    tok = relay_pass(cfg)
    if not tok:
        return {"relay": False, "why": "no relay pass (fleet-relay-cred.sh fetch)"}
    trust = router.trust or "unknown"
    if trust != "trusted":
        return {"relay": False, "why": "%s: sessions go central, not the relay" % trust}
    out, peer = {"relay": True}, ""
    for prov, method, path, body in (("anthropic", "POST", "/anthropic/v1/messages", b"{}"),
                                     ("openai", "GET", "/chatgpt/wham/usage", None)):
        u = urlsplit(cfg.relay_url + path)
        hdrs = {"Host": u.netloc, "X-Fleet-Relay": tok, "content-type": "application/json",
                "anthropic-version": "2023-06-01"}
        word, code = "unreachable", "000"
        try:
            if u.scheme == "http":
                conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=10)
            else:
                conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=10,
                                                   context=ssl._create_default_https_context())
            conn.connect()
            peer = peer or conn.sock.getpeername()[0]
            conn.request(method, u.path, body=body, headers=hdrs)
            r = conn.getresponse()
            text = r.read(65536).decode("utf-8", "replace").lower()
            conn.close()
            code = str(r.status)
            if "relay_refused" in text or "relay_check_unavailable" in text:
                word = "unreachable"          # the relay's gate, not the provider
            elif r.status == 403 and any(m in text for m in REGION_MARKS):
                word = "unsupported_region"
            elif r.status in (502, 503, 504):
                word = "unreachable"
            else:
                word = "reachable"
        except (OSError, http.client.HTTPException):
            pass
        out[prov], out[prov + "_code"] = word, code
    out["peer"] = peer
    return out


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
def tenant_cfg(base, spec):
    """One login's settings on the shared proxy (issue #2217): the common ones
    (upstreams, timeouts) from the process, the rest from the login's own spec
    — written by root's launcher from the login's store and conf, never by the
    login."""
    import copy
    c = copy.copy(base)
    st = spec["settings"] if isinstance(spec.get("settings"), dict) else {}
    c.name, c.uid = spec["login"], int(spec["uid"])
    c.state = spec["state"]
    c.log = spec.get("log") or base.log
    c.accounts, c.codex_auth, c.codex_homes = spec["accounts"], spec["codex_auth"], spec["codex_homes"]
    c.node_env, c.probe_path = spec["node_env"], spec.get("probe") or ""
    c.relay_url = (st.get("FLEET_CRED_RELAY_URL") or "").rstrip("/")
    c.relay_token = st.get("FLEET_CRED_RELAY_TOKEN") or ""
    ne = node_env(c.node_env)
    c.central_set = bool(st.get("FLEET_CRED_CENTRAL_URL"))
    c.central_url = (st.get("FLEET_CRED_CENTRAL_URL") or ne.get("CCQUOTA_HUB_URL")
                     or st.get("FLEET_HUB_URL") or "").rstrip("/")
    c.quota_push, c.store, c.broker, c.ctl_uid = "", True, True, c.uid
    return c


def shared_logins(run):
    """-> the logins the running shared proxy serves (<run>/logins), or None
    when it wrote none (a proxy older than issue #4245)."""
    try:
        return sorted(l for l in open(os.path.join(run, "logins")).read().split() if l)
    except OSError:
        return None


def shared_stale(shared):
    """-> (pid, why) when the lock's holder is a shared proxy that is NOT this
    tenants file's — another version, or another set of logins (issue #4245: an
    orphan from before the daemon restarted kept the lock for two days, and every
    restart the daemon made printed «already running» and exited, so a login that
    joined since was never served) — else None: the holder is current, or not a
    proxy we may stop."""
    run = shared.get("run") or ""
    want_v = shared.get("version") or "-"
    want = sorted(str(t.get("login")) for t in shared["tenants"] if isinstance(t, dict))
    try:
        have_v = open(os.path.join(run, "version")).read().strip()
    except OSError:
        have_v = ""
    have = shared_logins(run)
    if have_v == want_v and have == want:
        return None
    pid = shared_holder(run)
    if not pid:
        return None
    if have is None:
        why = "version %s (want %s), its logins unknown" % (have_v or "?", want_v)
    else:
        why = "version %s → %s, logins %s → %s" % (have_v or "?", want_v, ",".join(have) or "-", ",".join(want) or "-")
    return pid, why


def shared_holder(run):
    """-> the pid of the live shared proxy <run>/pid names, else None (a pid
    reused by someone else is never ours to stop)."""
    try:
        pid = int(open(os.path.join(run, "pid")).read().strip())
    except (OSError, ValueError):
        return None
    if pid <= 1 or pid == os.getpid() or not pid_alive(pid):
        return None
    try:
        argv = subprocess_out(["ps", "-o", "command=", "-p", str(pid)])
    except OSError:
        return None
    if "fleet-cred-proxy.py" not in argv or "--shared" not in argv:
        return None
    return pid


# AF_UNIX sun_path: 104 bytes on macOS (108 on Linux), the NUL included
SUN_PATH_MAX = 104 if sys.platform == "darwin" else 108


def handoff_path(st, ctld):
    """<state>/handoff.sock, else — a state dir too deep for AF_UNIX, e.g. under
    macOS's /private/var/folders — <ctl dir>/handoff.sock, the dir ctl.sock is
    sized for; None when neither fits. Both halves ask it with the same dirs."""
    for d in (st, ctld):
        path = os.path.join(d, "handoff.sock")
        if len(os.fsencode(path)) < SUN_PATH_MAX:
            return path
    return None


def handoff_listen(st, lockf, ctld):
    """The old half of a restart that drops nothing (T595): <state>/handoff.sock
    (0600 in the 0700 state dir; the peer must be this uid or root) hands every
    listening socket in HANDOFF to the next proxy, then this one drains. A path
    that cannot be bound only turns the handoff off — the proxy serves on."""
    path = handoff_path(st, ctld)
    if not path:
        sys.stderr.write("fleet-cred-proxy: no handoff socket (the state dir %s is too deep for AF_UNIX)\n" % st)
        return
    try:
        os.unlink(path)
    except OSError:
        pass
    hs = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        hs.bind(path)
    except OSError as e:
        hs.close()
        sys.stderr.write("fleet-cred-proxy: no handoff socket (%s: %s)\n" % (path, e))
        return
    finally:
        os.umask(old)
    hs.listen(4)
    threading.Thread(target=handoff_serve, args=(hs, lockf), daemon=True).start()


def handoff_serve(hs, lockf):
    while True:
        try:
            c, _ = hs.accept()
        except OSError:
            return
        try:
            c.settimeout(10)
            u = peer_uid(c)
            line = c.recv(4096).split(b"\n", 1)[0]
            req = json.loads(line or b"{}")
            if u not in (os.geteuid(), 0) or not isinstance(req, dict) or req.get("op") != "handoff":
                Proxy.log_any(ev="deny", path="handoff", why="peer uid %d" % u)
                c.close()
                continue
            held = sorted(HANDOFF.items())
            keys = [k for k, _ in held]
            fds = [o.fileno() for _, o in held]
            head = json.dumps({"ok": True, "pid": os.getpid(), "keys": keys}).encode() + b"\n"
            c.sendmsg([head], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, b"".join(
                f.to_bytes(4, sys.byteorder, signed=True) for f in fds))])
            if not c.recv(16).startswith(b"ok"):
                c.close()       # it could not take them: this one keeps serving
                continue
        except (OSError, ValueError):
            try:
                c.close()
            except OSError:
                pass
            continue
        # handed over: take nothing new, let go of the lock, finish what runs
        DRAIN.update(on=True, since=time.time())
        hs.close()
        Proxy.log_any(ev="handoff", to=req.get("pid"), keys=keys)
        stops = [threading.Thread(target=o.shutdown, daemon=True) for k, o in held if k.startswith("tcp:")]
        for th in stops:
            th.start()
        for th in stops:
            th.join(10)
        time.sleep(1.2)         # the control loop's accept timeout: it has stopped too
        fcntl.flock(lockf, fcntl.LOCK_UN)
        try:
            c.sendall(b"released\n")
            c.close()
        except OSError:
            pass
        return


def handoff_from(lockf, st, ctld):
    """The new half (T595): ask the proxy holding the lock for its listening
    sockets; once it says it let go, take the lock. -> {key: fd}, the lock held;
    None when it cannot hand over (an older proxy, gone) — nothing changed then."""
    path = handoff_path(st, ctld)
    if not path:
        return None
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(15)
    try:
        c.connect(path)
        c.sendall(json.dumps({"op": "handoff", "pid": os.getpid()}).encode() + b"\n")
        msg, anc, _, _ = c.recvmsg(65536, socket.CMSG_SPACE(64 * 4))
    except OSError:
        c.close()
        return None
    fds = []
    for lvl, typ, data in anc:
        if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
            fds += [int.from_bytes(data[i:i + 4], sys.byteorder, signed=True)
                    for i in range(0, len(data) - len(data) % 4, 4)]
    try:
        head = json.loads(msg.split(b"\n", 1)[0] or b"{}")
    except ValueError:
        head = {}
    keys = head.get("keys") if isinstance(head, dict) else None
    if not head.get("ok") or not isinstance(keys, list) or len(keys) != len(fds):
        for f in fds:
            os.close(f)
        c.close()
        return None
    try:
        c.sendall(b"ok\n")
    except OSError:
        for f in fds:
            os.close(f)
        c.close()
        return None
    # from here the sockets are ours: whatever the old one does, we serve them
    secs = float(env("FLEET_CRED_TAKEOVER_SECS", "10") or 10)
    t0, pid = time.time(), int(head.get("pid") or 0)
    try:
        c.recv(16)              # «released» (or its end)
    except OSError:
        pass
    c.close()
    killed = False
    while True:
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            pass
        if not killed and time.time() - t0 >= secs and pid > 1:
            killed = True
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        if time.time() - t0 >= 2 * secs:
            sys.exit("fleet-cred-proxy: pid %d handed over but still holds %s/lock" % (pid, st))
        time.sleep(0.05)
    sys.stderr.write("fleet-cred-proxy: took over from pid %d in %.1fs, %d socket(s) handed over\n"
                     % (pid, time.time() - t0, len(fds)))
    return dict(zip(keys, fds))


def drain_out(tenants):
    """Handed over (T595): wait for the requests still in flight — every
    connection closed, or none busy for FLEET_CRED_DRAIN_IDLE_SECS (an idle
    keep-alive the client has not dropped yet), at most FLEET_CRED_DRAIN_SECS —
    report what they used, and go, leaving the successor's files alone."""
    cap = float(env("FLEET_CRED_DRAIN_SECS", "900") or 900)
    idle = float(env("FLEET_CRED_DRAIN_IDLE_SECS", "30") or 30)
    quiet = None
    while time.time() - DRAIN["since"] < cap:
        with DRAIN_LOCK:
            conns, busy = DRAIN["conns"], DRAIN["busy"]
        if conns <= 0:
            break
        if busy <= 0:
            quiet = quiet or time.time()
            if time.time() - quiet >= idle:
                break
        else:
            quiet = None
        time.sleep(0.2)
    for t in tenants:
        try:
            t.budget.flush(t.log)
        except Exception:
            pass
    if Proxy.ustats:
        try:
            Proxy.ustats.flush(final=True)
        except Exception:
            pass
    Proxy.log_any(ev="drained", secs=round(time.time() - DRAIN["since"], 1), left=DRAIN["conns"])
    os._exit(0)


def subprocess_out(cmd):
    import subprocess
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
                          universal_newlines=True).stdout


def shared_takeover(lockf, st, pid, why):
    """Stop the stale holder and take its lock (SIGTERM, then SIGKILL past
    FLEET_CRED_TAKEOVER_SECS / 2) — or exit 1, said, so the daemon's log shows it."""
    secs = float(env("FLEET_CRED_TAKEOVER_SECS", "10") or 10)
    sys.stderr.write("fleet-cred-proxy: the shared proxy pid %d is stale (%s): taking over\n" % (pid, why))
    t0, killed = time.time(), False
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as e:
        sys.exit("fleet-cred-proxy: cannot stop the stale shared proxy pid %d (%s) — it keeps %s/lock" % (pid, e, st))
    while time.time() - t0 < secs:
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.stderr.write("fleet-cred-proxy: took over from pid %d in %.1fs\n" % (pid, time.time() - t0))
            return
        except OSError:
            pass
        if not killed and time.time() - t0 >= secs / 2:
            killed = True
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.1)
    sys.exit("fleet-cred-proxy: the stale shared proxy pid %d still holds %s/lock after %gs" % (pid, st, secs))


def snapshot_legacy_picks(ctl_dir, shared, state):
    """Before socket handoff, preserve the old proxy's established bindings.
    Root/uid-gated control reads only; no history/source provenance is inferred.
    A proxy already stopped cannot supply a snapshot: retain its persisted one.
    """
    for spec in (shared or {}).get("tenants", [{"state": state}]):
        try:
            req = {"op": "picks"}
            if spec.get("login"):
                req["as"] = spec["login"]
            reply = ctl_call(ctl_dir, req)
            picks = {k.split(":", 1)[1]: a for k, a in reply.get("picks", {}).items()
                     if k.startswith("codex:") and isinstance(a, str) and SAFE_LABEL(a)}
            write_json(os.path.join(spec["state"], "codex-legacy-picks.json"), picks)
        except (OSError, RuntimeError, ValueError, SystemExit):
            pass


def serve(a):
    cfg = a
    shared = None
    if a.shared:
        shared = read_json(a.shared, None)
        if not isinstance(shared, dict) or not isinstance(shared.get("tenants"), list):
            sys.exit("fleet-cred-proxy: --shared %s: not a tenants file" % a.shared)
        a.state = shared["state"]
    st = a.state
    os.makedirs(st, mode=0o700, exist_ok=True)
    lockf = open(os.path.join(st, "lock"), "w")
    inherited = {}
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # FLEET_CRED_HANDOFF=1 (the machine daemon's start, T595): this start
        # replaces the holder without a moment of nobody listening — its sockets
        # handed over, else (an older proxy) stopped as a stale one is
        handing = env("FLEET_CRED_HANDOFF") == "1"
        ctl0 = (shared.get("run") or st) if shared else env("FLEET_CRED_CTL_DIR", st)
        if handing and not shared:
            # Shared snapshots are root's job in the launcher, BEFORE it drops
            # to the service role (which the old control correctly refuses).
            snapshot_legacy_picks(ctl0, None, st)
        took = handoff_from(lockf, st, ctl0) if handing else None
        if took is not None:
            inherited = took
        else:
            stale = shared_stale(shared) if shared else None
            if not stale and handing and shared:
                pid = shared_holder(shared.get("run") or "")
                stale = (pid, "a new start (no handoff from it)") if pid else None
            if not stale:
                sys.stderr.write("fleet-cred-proxy: already running (%s/lock)\n" % st)
                sys.exit(0)
            shared_takeover(lockf, st, *stale)
    handed = bool(inherited)
    cfg.anthropic_url = env("FLEET_CRED_ANTHROPIC_URL", "https://api.anthropic.com").rstrip("/")
    cfg.codex_url = env("FLEET_CRED_CODEX_URL", "https://chatgpt.com/backend-api/codex").rstrip("/")
    cfg.space_url = env("FLEET_CRED_SPACE_URL", SPACE_URL_DEFAULT).rstrip("/")
    cfg.ttl = int(env("FLEET_CRED_PROXY_TTL", "86400"))
    cfg.switch_ttl = int(env("FLEET_CRED_PROXY_SWITCH_SECS", "1800"))
    # the account pick's ceiling (issue #2412): a session leaves an account at it
    cfg.pick_ceiling = float(env("FLEET_CRED_PICK_CEILING", env("FLEET_ACCOUNT_CEILING", "85")) or 85)
    cfg.timeout = int(env("FLEET_CRED_PROXY_TIMEOUT", "600"))
    cfg.quota_push_secs = float(env("FLEET_CRED_QUOTA_PUSH_SECS", "2"))
    if not cfg.log:
        cfg.log = env("FLEET_CRED_PROXY_LOG", os.path.join(conf_dir(), "logs", "cred-proxy.log"))
    if shared:
        cfg.run_user = shared.get("user") or ""
        cfg.version = shared.get("version") or ""
        cfg.uid = None
        Proxy.sink = LogSink(cfg)
        seen = {}
        for spec in shared["tenants"]:
            try:
                tc = tenant_cfg(cfg, spec)
            except (KeyError, TypeError, ValueError) as e:
                sys.exit("fleet-cred-proxy: --shared: a bad tenant (%s)" % e)
            if tc.uid in seen and env("FLEET_CRED_SHARED_TEST") != "1":
                sys.exit("fleet-cred-proxy: --shared: logins %s and %s share uid %d" % (seen[tc.uid], tc.name, tc.uid))
            seen[tc.uid] = tc.name
            os.makedirs(tc.state, mode=0o700, exist_ok=True)
            tc.pool = os.path.join(st, "pool")
            Proxy.tenants[tc.name] = Tenant(tc, tc.name)
        everyone = [t.cfg for t in Proxy.tenants.values()]
        with POOL_LOCK:
            n = pool_adopt(everyone)
            pool_gc(os.path.join(st, "pool"), everyone)
        if n:
            Proxy.sink.log(ev="pool_adopt", files=n)
        ctld = shared["run"]
        a.port = int(shared.get("port") or a.port or 0)
    else:
        cfg.relay_url = env("FLEET_CRED_RELAY_URL").rstrip("/")
        cfg.relay_token = env("FLEET_CRED_RELAY_TOKEN")
        cfg.node_env = env("FLEET_CRED_NODE_ENV", os.path.join(conf_dir(), "node.env"))
        cfg.probe_path = env("FLEET_CRED_PROBE", os.path.join(conf_dir(), "node-probe.json"))
        ne = node_env(cfg.node_env)
        cfg.central_set = bool(env("FLEET_CRED_CENTRAL_URL"))
        cfg.central_url = env("FLEET_CRED_CENTRAL_URL", ne.get("CCQUOTA_HUB_URL") or env("FLEET_HUB_URL")).rstrip("/")
        cfg.accounts = env("FLEET_CRED_ACCOUNTS", os.path.join(conf_dir(), "accounts"))
        cfg.codex_auth = env("FLEET_CRED_CODEX_AUTH", os.path.expanduser("~/.codex/auth.json"))
        cfg.codex_homes = env("FLEET_CRED_CODEX_HOMES", os.path.expanduser("~/.codex-accounts"))
        cfg.quota_push = env("FLEET_CRED_QUOTA_PUSH")
        # separated mode (issue #1971): set by bin/fleet-credsep-launch.py only
        cfg.store = env("FLEET_CRED_STORE") == "1"
        cfg.broker = cfg.store
        cfg.ctl_uid = int(env("FLEET_CRED_CTL_UID")) if env("FLEET_CRED_CTL_UID") else None
        cfg.uid = cfg.ctl_uid
        ctld = env("FLEET_CRED_CTL_DIR", st)
        everyone = [cfg]
    for c in everyone:   # where this proxy asks for a new relay pass (#3561)
        c.relay_want = os.path.join(ctld, "relay-want." + c.name if shared else "relay-want")
    global ALLOWED
    if shared or cfg.store:
        ALLOWED = allowed_hosts(env("FLEET_CRED_ALLOW_HOSTS"), configured_urls([cfg] + everyone))
    for c in [cfg] + everyone:
        for name in ("anthropic_url", "codex_url", "relay_url", "central_url", "space_url"):
            v = getattr(c, name, "")
            if v and not loopback_ok(v, cluster=name == "central_url"):
                sys.exit("fleet-cred-proxy: %s=%s: %s" % (
                    name, v, "https, or plain http on loopback only" if ALLOWED is None else
                    "not an allowed upstream (https to %s; FLEET_CRED_ALLOW_HOSTS in root's config adds one)"
                    % ", ".join(sorted(ALLOWED))))
    for c in everyone:
        if c.relay_url and not relay_pass(c):
            # not fatal: the launcher mints one (fleet-relay-cred.sh fetch); until
            # then the relay road is simply not a candidate
            sys.stderr.write("fleet-cred-proxy: FLEET_CRED_RELAY_URL set but no relay pass yet "
                             "(FLEET_CRED_RELAY_TOKEN or %s) — relay road off\n" % os.path.join(c.state, "relay.token"))
    for c in [cfg] + everyone:
        try:
            os.makedirs(os.path.dirname(c.log), exist_ok=True)
        except OSError:
            pass
    if not shared:
        Proxy.T = Tenant(cfg)

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
            srv = Server(("127.0.0.1", p), Proxy, fd=inherited.pop("tcp:%d" % p, None) if p else None)
            break
        except OSError:
            if a.port and p == a.port:
                sys.exit("fleet-cred-proxy: 127.0.0.1:%d is taken" % p)
    srv.daemon_threads = True
    cfg.bound_port = srv.server_address[1]
    gated = bool(shared) or cfg.ctl_uid is not None   # the login is another uid: 0666 + the peer-uid gate
    for c in everyone:
        c.bound_port = cfg.bound_port

    Proxy.ustats = up_stats_open((shared or {}).get("stats") or ctld)
    HANDOFF["tcp:%d" % cfg.bound_port] = srv
    sockp, pidf = os.path.join(ctld, "ctl.sock"), os.path.join(ctld, "pid")
    cfd = inherited.pop("ctl", None)
    if cfd is not None and os.path.exists(sockp):
        ctl = socket.socket(fileno=cfd)     # the same bound path, never unlinked (T595)
    else:
        if cfd is not None:
            os.close(cfd)
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
    # 0666 only with the peer-uid gate (separated / shared: the login is another uid)
    os.chmod(sockp, 0o666 if gated else 0o600)
    # every login of a shared proxy asks here (T903): macOS refuses a unix
    # connect past the backlog at once, so a reconnect's burst of logins ×
    # repos re-reads read «no node token» with a backlog of 16
    ctl.listen(128)
    HANDOFF["ctl"] = ctl

    def bye(*_):
        # Once: a second TERM (a pid file and a parent naming the same process)
        # re-entered this handler inside the first's ustats.flush, blocked on its
        # lock, and the proxy never stopped (T889).
        if threading.current_thread() is threading.main_thread():   # tick's parent watch calls it too
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGALRM):
                signal.signal(sig, signal.SIG_IGN)
        if Proxy.ustats:
            try:
                Proxy.ustats.flush(final=True)
            except Exception:
                pass
        if DRAIN["on"]:
            os._exit(0)     # handed over: the pid, port and socket are the successor's
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

    tenants = [Proxy.T] if Proxy.T else list(Proxy.tenants.values())

    def first_refresh():
        for t in tenants:
            t.router.refresh(t.log)
            try:
                t.budget.flush(t.log)
            except Exception:
                pass
    if handed:      # the handed-over sockets queue meanwhile: serve first, ask after (T595)
        threading.Thread(target=first_refresh, daemon=True).start()
    else:
        first_refresh()
    with open(portf + ".tmp", "w") as f:
        f.write("%d\n" % cfg.bound_port)
    os.replace(portf + ".tmp", portf)
    with open(pidf, "w") as f:
        f.write("%d\n" % os.getpid())
    files = [portf, pidf]
    if shared:      # what `status --machine` and the doctor read without asking
        vf = os.path.join(ctld, "version")
        with open(vf, "w") as f:
            f.write("%s\n" % (cfg.version or "-"))
        files.append(vf)
        # the logins it serves (issue #4245): the doctor's «joined, not served»
        lf = os.path.join(ctld, "logins")
        with open(lf + ".tmp", "w") as f:
            f.write("".join("%s\n" % n for n in sorted(Proxy.tenants)))
        os.replace(lf + ".tmp", lf)
        files.append(lf)
    for f in inherited.values():    # a handed-over port nobody here serves any more
        os.close(f)
    handoff_listen(st, lockf, ctld)
    if gated:   # separated / shared: the login (another uid) reads them
        for p in files:
            os.chmod(p, 0o644)

    parent = os.getppid()

    def capacity_tick(t):
        while not DRAIN["on"]:
            t.refresh_capacity_metadata()
            time.sleep(5)
    for tenant in tenants:
        threading.Thread(target=capacity_tick, args=(tenant,), daemon=True).start()

    def tick():
        every = max(5, int(env("FLEET_CRED_PROXY_TRUST_SECS", "300")))
        bevery = max(1, int(env("FLEET_CRED_BUDGET_SECS", "15")))
        last = blast = last_pass = time.time()
        while True:
            time.sleep(1)
            if a.parent_watch and os.getppid() != parent:
                bye()       # the launcher died: never outlive it as an orphan
            if Proxy.ustats:
                try:
                    Proxy.ustats.flush()
                except Exception:
                    pass
            if time.time() - blast >= bevery:
                blast = time.time()
                for t in tenants:
                    try:
                        t.budget.flush(t.log)
                    except Exception:
                        pass
            if DRAIN["on"]:
                continue    # handed over (T595): the successor refreshes and renews
            if time.time() - last >= every:
                last = time.time()
                for t in tenants:
                    try:
                        t.router.refresh(t.log)
                    except Exception:
                        pass
            if time.time() - last_pass >= 60:
                last_pass = time.time()
                for t in tenants:
                    try:
                        t.passes.tick()
                    except Exception:
                        pass
                    try:
                        t.relay.tick()
                    except Exception:
                        pass
    threading.Thread(target=tick, daemon=True).start()
    threading.Thread(target=ctl_serve, args=(ctl, cfg), daemon=True).start()
    nofile = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    for t in tenants:
        order, why = t.router.candidates("claude", False)
        t.log(ev="start", pid=os.getpid(), port=cfg.bound_port, route=order[0], reason=why, nofile=nofile,
              handed=handed)
    if shared:
        Proxy.sink.log(ev="start", pid=os.getpid(), port=cfg.bound_port, shared=True, logins=sorted(Proxy.tenants), handed=handed,
                       version=cfg.version, nofile=nofile)
        sys.stderr.write("fleet-cred-proxy: shared 127.0.0.1:%d · %d login(s) · nofile=%d\n"
                         % (cfg.bound_port, len(tenants), nofile))
    else:
        sys.stderr.write("fleet-cred-proxy: 127.0.0.1:%d · route %s (%s) · nofile=%d\n" % (cfg.bound_port, order[0], why, nofile))
    srv.serve_forever()
    if DRAIN["on"]:
        drain_out(tenants)


def main():
    ap = argparse.ArgumentParser(prog="fleet-cred-proxy.py")
    ap.add_argument("--state", default="")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=int(env("FLEET_CRED_PROXY_PORT", "0")))
    s.add_argument("--max-seconds", type=int, default=0)
    s.add_argument("--log", default="")
    s.add_argument("--parent-watch", action="store_true")
    s.add_argument("--shared", default="", help="the machine's shared proxy: its tenants file (issue #2217)")
    s.add_argument("--verbose", action="store_true")
    r = sub.add_parser("route")
    r.add_argument("--provider", default="claude", choices=("claude", "codex"))
    r.add_argument("--refresh", action="store_true")
    r.add_argument("--json", action="store_true")
    m = sub.add_parser("mint")
    m.add_argument("--account", default=""); m.add_argument("--sid", default="")
    m.add_argument("--provider", default=""); m.add_argument("--worker", default="")
    m.add_argument("--ttl", type=int, default=0); m.add_argument("--wrap", type=int, default=0)
    b = sub.add_parser("rebind")
    b.add_argument("--sid", required=True); b.add_argument("--account", required=True)
    v = sub.add_parser("revoke")
    v.add_argument("--sid", required=True)
    t = sub.add_parser("attach")
    t.add_argument("--sid", required=True)
    sub.add_parser("quota")
    sub.add_parser("account-quota")
    sub.add_parser("picks")
    cp = sub.add_parser("capacity-preview")
    cp.add_argument("--sid", required=True)
    g = sub.add_parser("standing")
    g.add_argument("--provider", default="codex", choices=("claude", "codex"))
    u = sub.add_parser("status")
    u.add_argument("--json", action="store_true")
    sub.add_parser("machine")
    o = sub.add_parser("store")
    o.add_argument("--kind", required=True, choices=("claude", "codex")); o.add_argument("--label", required=True)
    o = sub.add_parser("unstore")
    o.add_argument("--kind", required=True, choices=("claude", "codex")); o.add_argument("--label", required=True)
    sub.add_parser("accounts")
    a = sub.add_parser("target-auth")
    a.add_argument("--account", required=True)
    sub.add_parser("credential-inspect")
    sub.add_parser("probe")
    sub.add_parser("relay")
    sub.add_parser("relay-probe")
    sub.add_parser("pass")
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
        req = {"op": "mint", "account": a.account, "sid": a.sid, "ttl": a.ttl, "wrap": a.wrap}
        if a.provider:
            req["provider"] = a.provider
        if a.worker:
            req["worker"] = a.worker
        print(ctl_call(a.state, req)["token"])
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
    elif a.cmd == "unstore":
        ctl_call(a.state, {"op": "unstore", "kind": a.kind, "label": a.label})
    elif a.cmd == "accounts":
        print(json.dumps(ctl_call(a.state, {"op": "accounts"}).get("claude") or {}, sort_keys=True))
    elif a.cmd == "target-auth":
        res = ctl_call(a.state, {"op": "target-auth", "account": a.account})
        print(json.dumps({k: res[k] for k in ("verdict", "reason")}))
    elif a.cmd == 'credential-inspect':
        req = json.loads(sys.stdin.read(32769))
        req['op'] = 'credential-inspect'
        res = ctl_call(a.state, req)
        print(json.dumps(dict(scope=res['scope'])))
    elif a.cmd == "probe":
        ctl_call(a.state, {"op": "probe", "data": sys.stdin.read(65536)})
    elif a.cmd == "relay-probe":
        res = ctl_call(a.state, {"op": "relay_probe"})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False))
    elif a.cmd == "relay":
        ctl_call(a.state, {"op": "relay", "data": sys.stdin.read(4097)})
    elif a.cmd == "pass":
        ctl_call(a.state, {"op": "pass", "cred": sys.stdin.readline()})
    elif a.cmd == "node-token":
        res = ctl_call(a.state, {"op": "node-token"})
        print("%s\t%s" % (res["url"], res["token"]))
    elif a.cmd == "node-hash":
        print(ctl_call(a.state, {"op": "node-hash"})["hash"])
    elif a.cmd == "machine":
        res = ctl_call(a.state, {"op": "machine"})
        res.pop("ok", None)
        print(json.dumps(res, sort_keys=True))
    elif a.cmd == "quota":
        print(json.dumps(ctl_call(a.state, {"op": "quota"})["quota"], sort_keys=True))
    elif a.cmd == "capacity-preview":
        print(json.dumps(ctl_call(a.state, {"op": "capacity-preview", "sid": a.sid}), sort_keys=True))
    elif a.cmd == "picks":
        res = ctl_call(a.state, {"op": "picks"})
        print(json.dumps({"picks": res["picks"], "pinned": res["pinned"]}, sort_keys=True))
    elif a.cmd == "standing":
        print(json.dumps(ctl_call(a.state, {"op": "standing", "provider": a.provider})["accounts"], sort_keys=True))
    elif a.cmd == "account-quota":
        res = ctl_call(a.state, {"op": "account-quota"})
        if "accounts" not in res:      # an older proxy: no such op
            sys.exit(1)
        print(json.dumps(res["accounts"], sort_keys=True))
    elif a.cmd == "status":
        res = ctl_call(a.state, {"op": "status"})
        res.pop("ok", None)
        print(json.dumps(res, ensure_ascii=False) if a.json else
              "pid %s · 127.0.0.1:%s · trust %s (%s)" % (res["pid"], res["port"], res["trust"], res["trust_why"]))


if __name__ == "__main__":
    main()
