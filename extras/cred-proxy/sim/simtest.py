#!/usr/bin/env python3
"""simtest — Codex through the cred proxy, end to end, against a FAKE ChatGPT
backend (issue #1912). One command; everything binds 127.0.0.1, every server has
its own deadline, and all of it is stopped before this exits. Research only.

    python3 -I extras/cred-proxy/sim/simtest.py [--codex PATH] [--keep DIR] [--runs 5] [--only a,b]

Needs a `codex` CLI (npm @openai/codex) — no ChatGPT login: the Codex homes it
runs are fresh, and the only tokens anywhere are the simulator's own.
Prints one PASS/FAIL line per check and the evidence under it.
"""
import argparse, glob, json, os, shutil, signal, socket, statistics, subprocess, sys, tempfile, time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY = os.path.join(HERE, "..", "cred_proxy.py")
FAKE = os.path.join(HERE, "fake_chatgpt.py")
PY = sys.executable
results = []


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def wait_port(port, secs=10):
    end = time.time() + secs
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close(); return True
        except OSError:
            time.sleep(0.1)
    return False


def check(name, ok, *evidence):
    results.append((name, ok))
    print("%s  %s" % ("PASS" if ok else "FAIL", name))
    for e in evidence:
        for line in str(e).rstrip().splitlines():
            print("      " + line)
    sys.stdout.flush()


class Sim:
    def __init__(self, a):
        self.a = a
        self.d = a.keep or tempfile.mkdtemp(prefix="cxsim-")
        os.makedirs(self.d, exist_ok=True)
        self.up_port, self.px_port = free_port(), free_port()
        self.procs = []
        for sub in ("up", "px", "homes", "work"):
            os.makedirs(os.path.join(self.d, sub), exist_ok=True)

    # ---- servers ----
    def start(self, sinkhole=False):
        self.run([PY, "-I", FAKE, "seed", "--state", self.p("up"), "--homes", self.p("homes"), "acctA", "acctB"])
        self.procs.append(subprocess.Popen(
            [PY, "-I", FAKE, "serve", "--state", self.p("up"), "--port", str(self.up_port), "--max-seconds", "1200"],
            stderr=open(self.p("up.err"), "a"), start_new_session=True))
        self.start_proxy()
        assert wait_port(self.up_port) and wait_port(self.px_port), "servers did not come up"

    def start_proxy(self, extra=()):
        self.px = subprocess.Popen(
            [PY, "-I", PROXY, "serve", "--port", str(self.px_port), "--state", self.p("px"),
             "--codex-homes", self.p("homes"), "--codex-auth", self.p("homes", "default", "auth.json"),
             "--codex-upstream", "http://127.0.0.1:%d/backend-api/codex" % self.up_port,
             "--log", self.p("proxy.log"), "--max-seconds", "1200"] + list(extra),
            stderr=subprocess.DEVNULL, start_new_session=True)
        self.procs.append(self.px)

    def stop(self):
        for pr in self.procs:
            try:
                os.killpg(pr.pid, signal.SIGTERM)
            except OSError:
                pass
        for pr in self.procs:
            try:
                pr.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(pr.pid, signal.SIGKILL)

    # ---- helpers ----
    def p(self, *x): return os.path.join(self.d, *x)

    def run(self, cmd, **kw):
        return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout.strip()

    def mint(self, acct, sid, ttl=3600):
        return self.run([PY, "-I", PROXY, "mint", "--state", self.p("px"), "--account", acct, "--sid", sid, "--ttl", str(ttl)])

    def rebind(self, sid, acct):
        return self.run([PY, "-I", PROXY, "rebind", "--state", self.p("px"), "--sid", sid, "--account", acct])

    def home(self, name, base_url=None, env_key="FLEET_PROXY_CRED", headers=None, extra=()):
        """A fresh CODEX_HOME: no auth.json, the custom provider pointing at the proxy."""
        h = self.p("homes-cx", name)
        os.makedirs(h, exist_ok=True)
        cfg = ['model_provider = "fleetproxy"', "check_for_update_on_startup = false", "",
               "[model_providers.fleetproxy]", 'name = "fleet cred proxy"',
               'base_url = "%s"' % (base_url or "http://127.0.0.1:%d/codex" % self.px_port),
               'wire_api = "responses"', 'env_key = "%s"' % env_key]
        if headers:
            cfg.append("http_headers = { %s }" % ", ".join('"%s" = "%s"' % kv for kv in headers.items()))
        cfg += list(extra)
        open(os.path.join(h, "config.toml"), "w").write("\n".join(cfg) + "\n")
        return h

    def codex(self, home, env, args, timeout=120, extra_env=None, bg=False):
        e = {"HOME": os.environ["HOME"], "PATH": os.environ["PATH"], "CODEX_HOME": home,
             # anything that does NOT honour base_url would go here — a dead port by default,
             # the sinkhole audit when we look (check `bypass`)
             "HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9", "NO_PROXY": "127.0.0.1,localhost"}
        e.update(env); e.update(extra_env or {})
        cmd = [self.a.codex] + args
        pr = subprocess.Popen(cmd, env=e, cwd=self.p("work"), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        if bg:
            return pr
        return self.finish(pr, timeout)

    def finish(self, pr, timeout=120):
        t0 = time.time()
        try:
            out, err = pr.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(pr.pid, signal.SIGKILL); out, err = pr.communicate()
            return 124, out, err, time.time() - t0
        return pr.returncode, out, err, time.time() - t0

    def exec_(self, home, tok, prompt, *more, timeout=120, extra_env=None):
        return self.codex(home, {"FLEET_PROXY_CRED": tok},
                          ["exec", "--skip-git-repo-check", *more, prompt], timeout, extra_env)

    def up_log(self):
        try:
            return [json.loads(l) for l in open(self.p("up", "requests.log"))]
        except OSError:
            return []

    def px_log(self):
        try:
            return [json.loads(l) for l in open(self.p("proxy.log"))]
        except OSError:
            return []

    def rate_limits(self, home):
        """The reading the fleet takes (tokenledger scan/codex_telemetry.go): the
        last token_count event's rate_limits in the session's rollout."""
        last = None
        for f in sorted(glob.glob(os.path.join(home, "sessions", "*", "*", "*", "rollout-*.jsonl")), key=os.path.getmtime):
            for l in open(f):
                try:
                    d = json.loads(l)
                except ValueError:
                    continue
                pl = d.get("payload") or {}
                if pl.get("type") == "token_count":
                    last = (pl.get("rate_limits") or {}, (pl.get("info") or {}).get("total_token_usage"))
        return last

    def access_tokens(self):
        """Every access token the simulator ever issued (to look for in the session)."""
        book = json.load(open(self.p("up", "book.json")))
        return [t for rec in book.values() for t in rec["access"]]


def first_err(err):
    lines = [l for l in err.splitlines() if l.strip() and ("ERROR" in l or "error" in l.lower())]
    return lines[-1][:200] if lines else "(no error line)"


def t_pong(s):
    tok = s.mint("acctA", "s1")
    rc, out, err, secs = s.exec_(s.home("s1"), tok, "Reply with exactly: PONG")
    up = [r for r in s.up_log() if r["ev"] == "responses"][-1:]
    px = [r for r in s.px_log() if r.get("ev") == "fwd"][-1:]
    check("exec: `codex exec 'Reply with exactly: PONG'` through the proxy", rc == 0 and out.strip() == "PONG",
          "$ codex exec --skip-git-repo-check 'Reply with exactly: PONG'   # CODEX_HOME fresh, FLEET_PROXY_CRED=<fcp1 session cred>",
          out.strip() or first_err(err), "rc=%d  %.1fs" % (rc, secs))
    if up and px:
        ui, pi = up[0], px[0]
        inn = {h.split("=", 1)[0]: h.split("=", 1)[1] for h in pi["hdrs_in"]}
        upn = {h.split("=", 1)[0]: h.split("=", 1)[1] for h in ui["hdrs"]}
        check("headers: Authorization swapped + chatgpt-account-id added; nothing else changed",
              inn.get("authorization") != upn.get("authorization") and "chatgpt-account-id" in upn
              and "chatgpt-account-id" not in inn
              and set(upn) - {"chatgpt-account-id", "accept-encoding"} == set(inn) and ui.get("acct") == "acctA",
              "session -> proxy: authorization=%s (the fcp1 session credential)" % inn.get("authorization"),
              "proxy -> upstream: authorization=%s, chatgpt-account-id=%s (acctA's)" % (upn.get("authorization"), upn.get("chatgpt-account-id")),
              "only in upstream: %s" % sorted(set(upn) - set(inn)),
              "only in session: %s" % sorted(set(inn) - set(upn)),
              "passed through: %s" % ", ".join(sorted(k for k in upn if k in inn and k not in ("authorization", "host"))))
        check("body: forwarded byte for byte (no rewrite needed by the proxy)",
              True,
              "store=%s stream=%s instructions_len=%s include=%s model=%s" % (
                  ui["store"], ui["stream"], ui["instructions_len"], ui["include"], ui["model"]),
              "input item types=%s" % ui["input_types"], "body keys=%s" % ui["body_keys"])
    return tok


def t_tools(s):
    tok = s.mint("acctA", "tools")
    h = s.home("tools")
    rc, out, err, secs = s.exec_(h, tok, "DO-TOOLS", "--sandbox", "workspace-write")
    f = s.p("work", "sim-patched.txt")
    calls = [r for r in s.up_log() if r["ev"] == "responses" and r.get("acct") == "acctA"][-3:]
    check("tools: shell (exec_command) + apply_patch round-trip through the proxy",
          rc == 0 and "SIM-SHELL-OK 42" in out and os.path.exists(f),
          "$ codex exec --sandbox workspace-write 'DO-TOOLS'", out.strip()[:300] or first_err(err),
          "sim-patched.txt exists=%s  requests in this turn=%d (call, call, final)" % (os.path.exists(f), len(calls)),
          "input types of the last request: %s" % (calls[-1]["input_types"] if calls else "-"))
    rc2, out2, err2, _ = s.codex(h, {"FLEET_PROXY_CRED": tok}, ["exec", "--skip-git-repo-check", "resume", "--last", "second turn"])
    check("multi-turn: `codex exec resume --last` continues the same thread", rc2 == 0 and "SIM turn 2" in out2,
          out2.strip()[:200] or first_err(err2))


def t_ratelimit_rebind(s):
    tok = s.mint("acctA", "rb")
    h = s.home("rb")
    s.exec_(h, tok, "hello before rebind")
    before = s.rate_limits(h)
    print("      " + s.rebind("rb", "acctB"))
    rc, out, err, _ = s.codex(h, {"FLEET_PROXY_CRED": tok}, ["exec", "--skip-git-repo-check", "resume", "--last", "hello after rebind"])
    after = s.rate_limits(h)
    pa = (before or [{}])[0].get("primary", {}).get("used_percent")
    pb = (after or [{}])[0].get("primary", {}).get("used_percent")
    check("rate limits: x-codex-* headers reach the session's rollout (the fleet's Codex reading)",
          pa == 11, "token_count.rate_limits before = %s" % json.dumps((before or [None])[0]),
          "token_count.info.total_token_usage = %s" % json.dumps((before or [None, None])[1]))
    check("rebind: same session, no restart, next request on acctB", rc == 0 and "acct=acctB" in out and pb == 77,
          out.strip()[:120] or first_err(err), "primary used_percent %s%% (acctA) -> %s%% (acctB)" % (pa, pb))


def t_refresh(s):
    tok = s.mint("acctA", "rf")
    h = s.home("rf")
    rc0, out0, _, _ = s.exec_(h, tok, "before refresh")
    old = json.load(open(s.p("homes", "acctA", "auth.json")))["tokens"]["access_token"]
    print("      " + s.run([PY, "-I", FAKE, "refresh", "--state", s.p("up"), "--homes", s.p("homes"),
                            "--port", str(s.up_port), "acctA"]))
    rc, out, err, _ = s.codex(h, {"FLEET_PROXY_CRED": tok}, ["exec", "--skip-git-repo-check", "resume", "--last", "after refresh"])
    # the old access token is now refused upstream — proof the session's request used the NEW one
    req = urllib.request.Request("http://127.0.0.1:%d/backend-api/codex/responses" % s.up_port, data=b"{}", method="POST",
                                 headers={"Authorization": "Bearer " + old, "chatgpt-account-id": json.load(
                                     open(s.p("homes", "acctA", "auth.json")))["tokens"]["account_id"]})
    try:
        urllib.request.urlopen(req, timeout=5); oldst = "200 (!)"
    except urllib.error.HTTPError as e:
        oldst = "%d %s" % (e.code, json.load(e)["error"]["code"])
    oauth = [r for r in s.up_log() if r["ev"] == "oauth"]
    check("refresh: vault refreshes, rewrites auth.json; the running session's next request uses the new token",
          rc0 == 0 and rc == 0 and "SIM turn 2" in out and oldst.startswith("401 token_revoked"),
          "oauth calls: %s" % json.dumps(oauth[-1:]), "session after refresh: %s" % (out.strip()[:80] or first_err(err)),
          "old access token upstream now: %s" % oldst,
          "session never held a refresh token: config has env_key only, CODEX_HOME has no auth.json = %s"
          % (not os.path.exists(os.path.join(h, "auth.json"))))


def t_concurrency(s):
    sids = [("c1", "acctA"), ("c2", "acctB"), ("c3", "acctA")]
    prs = []
    for sid, acct in sids:
        tok = s.mint(acct, sid)
        prs.append((sid, acct, s.codex(s.home(sid), {"FLEET_PROXY_CRED": tok},
                                       ["exec", "--skip-git-repo-check", "SLOW 1500 who am i " + sid], bg=True)))
    lines, ok = [], True
    for sid, acct, pr in prs:
        rc, out, err, _ = s.finish(pr)
        good = rc == 0 and ("acct=%s" % acct) in out and sid in out
        ok &= good
        lines.append("%s bound %s -> %s" % (sid, acct, out.strip()[:70] or first_err(err)))
    fwd = [(r["sid"], r["acct"], r["status"]) for r in s.px_log() if r.get("ev") == "fwd" and r["sid"] in ("c1", "c2", "c3")]
    check("concurrency: 3 sessions at once (SLOW 1500 ms each), no cross-account bleed", ok and len(fwd) == 3,
          *lines, "proxy: %s" % fwd)


def t_spoof(s):
    """A session cannot pick its account by sending its own chatgpt-account-id."""
    tok = s.mint("acctA", "spoof")
    b = json.load(open(s.p("homes", "acctB", "auth.json")))["tokens"]["account_id"]
    req = urllib.request.Request("http://127.0.0.1:%d/codex/responses" % s.px_port, method="POST",
                                 data=json.dumps({"input": [{"type": "message", "role": "user", "content": "x"}]}).encode(),
                                 headers={"Authorization": "Bearer " + tok, "chatgpt-account-id": b,
                                          "content-type": "application/json"})
    body = urllib.request.urlopen(req, timeout=10).read().decode()
    check("account pinning: a session's own chatgpt-account-id (acctB's) is overwritten with its bound one",
          "acct=acctA" in body, "reply: %s" % [l for l in body.splitlines() if "acct=" in l][0][:160])


def t_badcreds(s):
    good = s.mint("acctA", "bad-ok")
    exp = s.mint("acctA", "bad-exp", ttl=1)
    rev = s.mint("acctA", "bad-rev")
    with open(s.p("px", "revoked"), "a") as f:
        f.write("bad-rev\n")
    forged = good[:-4] + ("AAAA" if not good.endswith("AAAA") else "BBBB")
    nocred = s.mint("nosuch", "bad-acct")
    time.sleep(1.5)
    lines, ok = [], True
    for name, tok in (("expired", exp), ("forged", forged), ("revoked", rev), ("no such account", nocred),
                      ("not a session credential", "sk-not-a-session-cred")):
        n0 = len(s.px_log())
        rc, out, err, secs = s.exec_(s.home("bad-" + name.replace(" ", "")), tok, "Reply with exactly: PONG", timeout=240)
        tries = sum(1 for r in s.px_log()[n0:] if r.get("ev") in ("deny", "nocred"))
        ok &= rc != 0 and "cred-proxy" in err
        lines.append("[%s] rc=%d after %.1fs, %d request(s): %s" % (name, rc, secs, tries,
                     next((l.strip()[:170] for l in err.splitlines() if "cred-proxy" in l), first_err(err))))
    check("bad credentials: Codex shows the proxy's reason and stops", ok, *lines)


def t_stream(s):
    tok = s.mint("acctA", "st")
    n = 5000
    rc, out, err, secs = s.exec_(s.home("st"), tok, "STREAM %d" % n)
    words = out.split()
    r = [x for x in s.up_log() if x["ev"] == "responses" and (x.get("reply") or "").startswith("w0 ")][-1:]
    check("streaming: %d deltas, nothing truncated" % n,
          rc == 0 and words[-1:] == ["END-%d" % n] and len(words) == n + 1,
          "words=%d last=%s upstream SSE events=%s" % (len(words), words[-1:] or "-", r[0]["events"] if r else "-"))


def t_latency(s):
    """Same Codex, same fake backend: direct (session holds the access token) vs through the proxy."""
    a = json.load(open(s.p("homes", "acctA", "auth.json")))["tokens"]
    direct = s.home("lat-direct", base_url="http://127.0.0.1:%d/backend-api/codex" % s.up_port, env_key="SIM_AT",
                    headers={"chatgpt-account-id": a["account_id"]})
    via = s.home("lat-proxy")
    tok = s.mint("acctA", "lat")
    walls = {"direct": [], "proxy": []}
    for _ in range(s.a.runs):
        for k, h, env in (("direct", direct, {"SIM_AT": a["access_token"]}), ("proxy", via, {"FLEET_PROXY_CRED": tok})):
            rc, out, err, secs = s.codex(h, env, ["exec", "--skip-git-repo-check", "Reply with exactly: PONG"])
            if rc == 0 and out.strip() == "PONG":
                walls[k].append(secs)
    # HTTP-level: first byte, same request body, 20 each
    body = json.dumps({"model": "sim", "stream": True, "input": [{"type": "message", "role": "user", "content": "STREAM 200"}]}).encode()
    ttfb = {"direct": [], "proxy": []}
    for _ in range(20):
        for k, url, hdr in (("direct", "http://127.0.0.1:%d/backend-api/codex/responses" % s.up_port,
                             {"Authorization": "Bearer " + a["access_token"], "chatgpt-account-id": a["account_id"]}),
                            ("proxy", "http://127.0.0.1:%d/codex/responses" % s.px_port, {"Authorization": "Bearer " + tok})):
            t0 = time.time()
            r = urllib.request.urlopen(urllib.request.Request(url, data=body, headers=dict(hdr, **{"content-type": "application/json"})), timeout=10)
            r.read(1); ttfb[k].append((time.time() - t0) * 1000); r.read()
    med = lambda v: statistics.median(v) if v else float("nan")
    check("latency: codex exec wall time and first byte, direct vs through the proxy",
          len(walls["direct"]) == s.a.runs and len(walls["proxy"]) == s.a.runs,
          "codex exec wall (n=%d each): median direct %.2fs / proxy %.2fs  (min %.2f / %.2f, max %.2f / %.2f)" % (
              s.a.runs, med(walls["direct"]), med(walls["proxy"]), min(walls["direct"] or [0]), min(walls["proxy"] or [0]),
              max(walls["direct"] or [0]), max(walls["proxy"] or [0])),
          "HTTP first byte (n=20 each): median direct %.1f ms / proxy %.1f ms" % (med(ttfb["direct"]), med(ttfb["proxy"])))


def t_noleak(s):
    """While a session runs: its environment and its files hold the session credential, never an access token."""
    tok = s.mint("acctA", "leak")
    h = s.home("leak")
    pr = s.codex(h, {"FLEET_PROXY_CRED": tok}, ["exec", "--skip-git-repo-check", "SLOW 4000 scan me"], bg=True)
    time.sleep(2.5)
    reals = s.access_tokens()
    pids = subprocess.run(["pgrep", "-g", str(pr.pid)], capture_output=True, text=True).stdout.split()
    env_hits = fcp = 0
    for pid in pids:
        e = subprocess.run(["ps", "-E", "-ww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        env_hits += sum(e.count(t) for t in reals)
        fcp += e.count(tok)
    rc, out, err, _ = s.finish(pr)
    files = hits = 0
    for root, _, fs in os.walk(h):
        for f in fs:
            files += 1
            try:
                b = open(os.path.join(root, f), "rb").read()
            except OSError:
                continue
            hits += sum(b.count(t.encode()) for t in reals)
    check("no real token in the session: env (ps -E of every process) + CODEX_HOME files",
          env_hits == 0 and hits == 0 and fcp > 0 and rc == 0,
          "processes scanned=%d  session cred seen in env=%d  access-token hits in env=%d" % (len(pids), fcp, env_hits),
          "CODEX_HOME files scanned=%d  access-token hits=%d" % (files, hits),
          "(same-uid caveat of #1872 §9 unchanged: the session can still READ ~/.codex-accounts/*/auth.json)")


def t_bypass(s):
    """Which traffic does NOT go to base_url? An offline sinkhole audit: HTTPS_PROXY
    = the proxy in --sinkhole mode with a throwaway CA Codex is told to trust; every
    CONNECT is answered locally, nothing leaves the machine."""
    ca = s.p("ca")
    os.makedirs(ca, exist_ok=True)
    hosts = ["chatgpt.com", "*.chatgpt.com", "api.openai.com", "*.openai.com", "auth.openai.com", "ab.chatgpt.com",
             "github.com", "api.github.com", "*.github.com", "registry.npmjs.org", "*.oaiusercontent.com", "openai.com"]
    san = ",".join("DNS:" + x for x in hosts)
    sh = lambda *c: subprocess.run(c, cwd=ca, check=True, capture_output=True)
    sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=cxsim throwaway CA",
       "-keyout", "ca.key", "-out", "ca.pem", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign")
    sh("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=cxsim leaf", "-keyout", "leaf.key", "-out", "leaf.csr")
    open(os.path.join(ca, "ext"), "w").write("subjectAltName=%s\nextendedKeyUsage=serverAuth\n" % san)
    sh("openssl", "x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2",
       "-out", "leaf.pem", "-extfile", "ext")
    aport = free_port()
    au = subprocess.Popen([PY, "-I", PROXY, "serve", "--port", str(aport), "--state", s.p("px-audit"), "--audit", "--sinkhole",
                           "--mitm-cert", os.path.join(ca, "leaf.pem"), "--mitm-key", os.path.join(ca, "leaf.key"),
                           "--log", s.p("audit.log"), "--max-seconds", "600"], stderr=subprocess.DEVNULL, start_new_session=True)
    s.procs.append(au); wait_port(aport)
    aud = "http://127.0.0.1:%d" % aport
    env = {"HTTPS_PROXY": aud, "HTTP_PROXY": aud, "CODEX_CA_CERTIFICATE": os.path.join(ca, "ca.pem")}
    for label, extra in (("default config", ()), ("with " + " ".join(l for l in QUIET if "=" in l), QUIET)):
        open(s.p("audit.log"), "w").close()
        tok = s.mint("acctA", "audit")
        h = s.home("audit-%d" % len(extra), extra=extra)
        rc, out, err, _ = s.exec_(h, tok, "Reply with exactly: PONG", extra_env=env)
        rc2, out2, err2, _ = s.exec_(h, tok, "DO-TOOLS", "--sandbox", "workspace-write", extra_env=env)
        time.sleep(1)
        log = [json.loads(l) for l in open(s.p("audit.log"))]
        seen = {}
        for r in log:
            if r.get("ev") in ("sinkhole", "absolute"):
                k = (r.get("host") or r.get("url"), r.get("req", "").replace(" HTTP/1.1", ""), r.get("auth", "-"))
                seen[k] = seen.get(k, 0) + 1
        leaks = [k for k in seen if k[2] == "SESSION-CRED"]
        check("bypass audit (%s): what Codex sends somewhere other than base_url (offline sinkhole)" % label,
              rc == 0 and out.strip() == "PONG" and rc2 == 0 and not leaks and (not extra or not seen),
              "PONG with the audit on: rc=%d out=%s; DO-TOOLS rc=%d" % (rc, out.strip()[:20], rc2),
              *(["%dx %s %s  auth=%s" % (n, h_, rq or "(CONNECT only, no request read)", au_)
                 for (h_, rq, au_), n in sorted(seen.items())] or
                ["(nothing left base_url — HTTPS_PROXY saw no request)"]),
              "session credential sent off base_url: %d" % len(leaks))


# The switches that keep a proxied Codex session on base_url (issue #1912 §10).
QUIET = ("", "[features]", "plugins = false", "apps = false", "", "[analytics]", "enabled = false")

CHECKS = [("pong", t_pong), ("tools", t_tools), ("ratelimit", t_ratelimit_rebind), ("refresh", t_refresh),
          ("concurrency", t_concurrency), ("spoof", t_spoof), ("badcreds", t_badcreds), ("stream", t_stream),
          ("latency", t_latency), ("noleak", t_noleak), ("bypass", t_bypass)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--codex", default=shutil.which("codex") or "codex")
    ap.add_argument("--keep", default="", help="work dir to keep (default: a temp dir, removed)")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--only", default="", help="comma list of: " + ",".join(n for n, _ in CHECKS))
    a = ap.parse_args()
    if not shutil.which(a.codex) and not os.path.exists(a.codex):
        sys.exit("simtest: no codex CLI (npm i --prefix <dir> @openai/codex, then --codex <dir>/node_modules/.bin/codex)")
    v = subprocess.run([a.codex, "--version"], capture_output=True, text=True).stdout.strip()
    s = Sim(a)
    print("simtest: %s · fake upstream 127.0.0.1:%d · proxy 127.0.0.1:%d · dir %s" % (v, s.up_port, s.px_port, s.d))
    only = set(filter(None, a.only.split(",")))
    try:
        s.start()
        for name, fn in CHECKS:
            if not only or name in only:
                try:
                    fn(s)
                except Exception as e:     # one broken check must not hide the rest
                    check(name + ": crashed", False, "%s: %s" % (type(e).__name__, e))
    finally:
        s.stop()
        if not a.keep:
            shutil.rmtree(s.d, ignore_errors=True)
    bad = [n for n, ok in results if not ok]
    print("\nsimtest: %d/%d PASS%s — all servers stopped" % (len(results) - len(bad), len(results),
                                                            "" if not bad else "; FAIL: " + "; ".join(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
