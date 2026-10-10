#!/usr/bin/env python3
"""fleet-cred-scan.py — can a session here reach a subscription credential?
Counts only, never a credential (issue #2136, EPIC #2133 C6; the scan of
docs/RESEARCH-CRED-PROXY.md §9, made a tool).

  fleet-cred-scan.py hashes
      On a machine that HOLDS the real credentials (a trusted host): one
      sha256 hex per real token it can read, one per line — a digest, never the
      token. Feed the file to `scan --hashes` on the machine under test.
  fleet-cred-scan.py scan [--hashes FILE] [--root DIR …] [--no-hub]
      Run INSIDE the session under test (its Bash tool). Tries the four routes
      of EPIC #1967 one by one and prints one count line each, then a verdict:
        ① accounts   ~/.config/claude-fleet/accounts/*/.credentials.json readable
        ② codex      ~/.codex/auth.json (and ~/.codex-accounts/*/auth.json) readable
        ③ env        this process's and every ancestor's environment (ps -E)
        ④ node       node.env readable → POST /v1/node/credentials with its token
                     (the hub's answer code; 403 untrusted_node = closed)
        files        the session's own dirs (CLAUDE_CONFIG_DIR, CODEX_HOME,
                     ~/.claude, ~/.codex, cwd, --root …), size- and depth-bounded
      A HIT is a credential-shaped string (sk-ant-oat/ort/api…, an OpenAI auth
      JWT) — and, with --hashes, one whose sha256 is a real token's (`real=`).
      The verdict counts routes with a hit: real hits when --hashes was given,
      else shaped hits (a person's own login on their own computer is shaped
      too — give --hashes to tell it apart).

Exit: 0 routes=0 · 1 at least one route reaches a credential · 2 usage
"""
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

try:  # the ONE TLS context for the hub: every CA source this computer has (claude-fleet#2878)
    import fleet_tls
    fleet_tls.install()
except ImportError:
    fleet_tls = None

CONF = os.environ.get("FLEET_CONF_DIR") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "claude-fleet")
SHAPED = re.compile(
    r"sk-ant-(?:oat|ort|api|sid)\d{2}-[A-Za-z0-9_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
MAX_FILE = 2 << 20
MAX_FILES = 5000


def openai_jwt(tok):
    """A JWT counts only when it is an OpenAI auth token (the Codex login)."""
    if not tok.startswith("eyJ"):
        return True
    try:
        import base64
        p = tok.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:
        return False
    return any("openai.com" in str(k) or "openai.com" in str(v) for k, v in claims.items())


def tokens_in(text):
    return [t for t in SHAPED.findall(text) if openai_jwt(t)]


def digest(tok):
    return hashlib.sha256(tok.encode()).hexdigest()


class Tally:
    def __init__(self, real):
        self.real = real            # set of sha256, or None
        self.seen = {}

    def add(self, route, text):
        r = self.seen.setdefault(route, {"shaped": 0, "real": 0, "sources": 0, "readable": 0})
        for t in tokens_in(text):
            r["shaped"] += 1
            if self.real is not None and digest(t) in self.real:
                r["real"] += 1

    def bump(self, route, key, n=1):
        r = self.seen.setdefault(route, {"shaped": 0, "real": 0, "sources": 0, "readable": 0})
        r[key] = r.get(key, 0) + n

    def hit(self, route):
        r = self.seen.get(route, {})
        return (r.get("real", 0) if self.real is not None else r.get("shaped", 0)) + r.get("granted", 0)


def read(path):
    try:
        if os.path.getsize(path) > MAX_FILE:
            return None
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return None


def cred_files():
    home = os.path.expanduser("~")
    acc = glob.glob(os.path.join(CONF, "accounts", "*", ".credentials.json"))
    codex = [os.path.join(home, ".codex", "auth.json")] + glob.glob(os.path.join(home, ".codex-accounts", "*", "auth.json"))
    return acc, codex


def node_env():
    ne = {}
    txt = read(os.path.join(CONF, "node.env"))
    for line in (txt or "").splitlines():
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ne[k.strip()] = v.strip().strip('"').strip("'")
    return txt is not None, ne


def ancestors():
    pids, pid = [], os.getpid()
    for _ in range(64):
        pids.append(pid)
        try:
            ppid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True,
                                      text=True, timeout=5).stdout.strip() or 0)
        except (ValueError, OSError, subprocess.SubprocessError):
            break
        if ppid <= 1:
            break
        pid = ppid
    return pids


def proc_env(pid):
    if pid == os.getpid():
        return "\n".join("%s=%s" % kv for kv in os.environ.items())
    try:
        return subprocess.run(["ps", "-E", "-ww", "-o", "command=", "-p", str(pid)], capture_output=True,
                              text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def walk(roots, skip):
    n = 0
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for d, dirs, files in os.walk(root):
            depth = d[len(root):].count(os.sep)
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules", ".venv") and depth < 6]
            for f in files:
                p = os.path.join(d, f)
                if os.path.realpath(p) in skip:
                    continue
                n += 1
                if n > MAX_FILES:
                    return
                yield p


def scan(hashes, roots, hub):
    real = None
    if hashes:
        real = set(l.strip() for l in (read(hashes) or "").splitlines() if re.fullmatch(r"[0-9a-f]{64}", l.strip()))
    t = Tally(real)
    acc, codex = cred_files()
    for route, files in (("① accounts", acc), ("② codex", codex)):
        for p in files:
            if not os.path.lexists(p):
                continue
            t.bump(route, "sources")
            txt = read(p)
            if txt is not None:
                t.bump(route, "readable")
                t.add(route, txt)
    for pid in ancestors():
        t.bump("③ env", "sources")
        env = proc_env(pid)
        if env:
            t.bump("③ env", "readable")
            t.add("③ env", env)
    readable, ne = node_env()
    t.bump("④ node", "sources", int(os.path.exists(os.path.join(CONF, "node.env"))))
    t.bump("④ node", "readable", int(readable))
    code = "-"
    url = (ne.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL", "")).rstrip("/")
    if hub and ne.get("CCQUOTA_TOKEN") and url:
        req = urllib.request.Request(url + "/v1/node/credentials", data=b"{}", method="POST", headers={
            "Authorization": "Bearer " + ne["CCQUOTA_TOKEN"], "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                code, body = str(r.status), r.read().decode("utf-8", "replace")
            t.add("④ node", body)
            if code == "200" and tokens_in(body):
                t.bump("④ node", "granted")
        except urllib.error.HTTPError as e:
            code = str(e.code)
        except Exception as e:
            code = type(e).__name__
    skip = set(os.path.realpath(p) for p in acc + codex)
    skip.add(os.path.realpath(os.path.join(CONF, "node.env")))
    home = os.path.expanduser("~")
    froots = [os.environ.get("CLAUDE_CONFIG_DIR", ""), os.environ.get("CODEX_HOME", ""),
              os.path.join(home, ".claude"), os.path.join(home, ".codex"), os.getcwd()] + list(roots)
    for p in walk(list(dict.fromkeys(os.path.realpath(r) for r in froots if r)), skip):
        t.bump("files", "sources")
        txt = read(p)
        if txt is not None:
            t.bump("files", "readable")
            t.add("files", txt)
    routes = 0
    for route in ("① accounts", "② codex", "③ env", "④ node", "files"):
        r = t.seen.get(route, {"sources": 0, "readable": 0, "shaped": 0, "real": 0})
        extra = " hub=%s" % code if route == "④ node" else ""
        print("%-11s sources=%d readable=%d shaped=%d real=%s%s" % (
            route, r["sources"], r["readable"], r["shaped"], r["real"] if real is not None else "-", extra))
        routes += 1 if t.hit(route) else 0
    print("scan: routes-with-credential=%d (%s)" % (routes, "real-token hashes: %d" % len(real) if real is not None
                                                     else "no --hashes: shaped hits count"))
    return 1 if routes else 0


def hashes_out():
    acc, codex = cred_files()
    seen = set()
    for p in acc + codex:
        txt = read(p)
        if not txt:
            continue
        for tok in tokens_in(txt):
            h = digest(tok)
            if h not in seen:
                seen.add(h)
                print(h)
    print("hashes: %d" % len(seen), file=sys.stderr)
    return 0


def main(argv):
    if argv[:1] == ["hashes"] and len(argv) == 1:
        return hashes_out()
    if argv[:1] != ["scan"]:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    hashes, roots, hub, i = None, [], True, 1
    while i < len(argv):
        a = argv[i]
        if a in ("--hashes", "--root") and i + 1 < len(argv):
            if a == "--hashes":
                hashes = argv[i + 1]
            else:
                roots.append(argv[i + 1])
            i += 2
        elif a == "--no-hub":
            hub, i = False, i + 1
        else:
            print("fleet-cred-scan: unknown argument %s" % a, file=sys.stderr)
            return 2
    return scan(hashes, roots, hub)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
