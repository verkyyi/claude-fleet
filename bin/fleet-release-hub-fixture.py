#!/usr/bin/env python3
"""fleet-release-hub-fixture.py — a sandbox hub for the selftests that serves
REALLY signed releases, the way tokenledger's handleRelease does (issue #3162):
the manifest signed in OpenSSH's SSHSIG format by `ssh-keygen -Y sign`, so a
test exercises the client's real check (bin/fleet-release-fetch.py) instead
of a fake ccquota. Test-only; binds 127.0.0.1, dies with its alarm.

    fleet-release-hub-fixture.py <w>

<w>/rel/<sha>/              a release's tree, as the hub would hand it out
<w>/rel/<sha>/.release/manifest.json   its seq / prev / artifacts (the rest is
                            computed: files, tree, key)
<w>/rel/stable              the sha /v1/fleet/release/stable names
<w>/hubkey (+ .pub)         the signing key (made on first start); <w>/key is
                            its `ed25519 <base64>` line (written if absent —
                            a test may overwrite it to show another key)
<w>/badsig                  present: sign with <w>/otherkey instead (a release
                            the pinned key does not verify)
<w>/nostore                 present: every route 404s (a hub with no store)
<w>/tamper                  present: the tree's first file is altered inside a
                            tree.tar.gz the manifest's `tree` digest does name
                            (only the per-file check can catch it)
<w>/legacy                  present: a hub from before SSHSIG — no SSHSIG
                            anywhere; the manifest signed with a plain ed25519
                            key (seed sha256("legacy")), in the
                            X-Ccquota-Release-Signature header (unless
                            <w>/nosigheader) and at <sha>/manifest.sig; /key
                            serves that key
<w>/endorse                 present: /key-endorsement = <w>/key's line vouched
                            for by <w>/prevkey (namespace claude-fleet-release-key)
<w>/hub.log                 every path asked, one per line
<w>/port                    written once listening
"""
import base64
import gzip
import hashlib
import io
import json
import os
import signal
import subprocess
import sys
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

W = sys.argv[1]
P = "/v1/fleet/release/"
signal.alarm(600)


def keygen(name):
    k = os.path.join(W, name)
    if not os.path.exists(k):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", k], check=True)
    return k


def raw_pub(k):
    wire = base64.b64decode(open(k + ".pub").read().split()[1])
    return wire[-32:]


def ed_line(k):
    return "ed25519 " + base64.b64encode(raw_pub(k)).decode() + "\n"


def sshsign(k, ns, data):
    d = os.path.join(W, ".sign.%d" % threading.get_ident())
    with open(d, "wb") as f:
        f.write(data)
    subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", k, "-n", ns, d],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    s = open(d + ".sig").read()
    os.remove(d)
    os.remove(d + ".sig")
    return s


HUBKEY, OTHER, PREV = keygen("hubkey"), keygen("otherkey"), keygen("prevkey")
if not os.path.exists(os.path.join(W, "key")):
    open(os.path.join(W, "key"), "w").write(ed_line(HUBKEY))


HERE = os.path.dirname(os.path.abspath(__file__))


def legacy_key():
    """(sign(msg) -> base64, `ed25519 <b64>` line): RFC 8032 §5.1.6 on
    fleet-release-verify.py's own curve code"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("v", os.path.join(HERE, "fleet-release-verify.py"))
    v = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(v)

    def enc(pt):
        zi = v._inv(pt[2])
        x, y = pt[0] * zi % v.P, pt[1] * zi % v.P
        return (y | ((x & 1) << 255)).to_bytes(32, "little")
    h = hashlib.sha512(hashlib.sha256(b"legacy").digest()).digest()
    a = int.from_bytes(h[:32], "little") & ((1 << 254) - 8) | (1 << 254)
    A = enc(v._mul(a, v.G))

    def sign(msg):
        r = int.from_bytes(hashlib.sha512(h[32:] + msg).digest(), "little") % v.Q
        R = enc(v._mul(r, v.G))
        k = int.from_bytes(hashlib.sha512(R + A + msg).digest(), "little") % v.Q
        return base64.b64encode(R + ((r + k * a) % v.Q).to_bytes(32, "little")).decode()
    return sign, "ed25519 " + base64.b64encode(A).decode() + "\n", hashlib.sha256(A).hexdigest()[:16]


LEGACY = legacy_key()


def flag(n):
    return os.path.exists(os.path.join(W, n))


def build(sha):
    """(manifest bytes, tree bytes) for <w>/rel/<sha>/"""
    root = os.path.join(W, "rel", sha)
    meta = {}
    mp = os.path.join(root, ".release", "manifest.json")
    if os.path.exists(mp):
        meta = json.load(open(mp))
    files = []
    buf = io.BytesIO()
    tamper = flag("tamper")
    with tarfile.open(fileobj=buf, mode="w") as t:
        for d, dirs, names in os.walk(root):
            dirs[:] = sorted(x for x in dirs if not (d == root and x == ".release"))
            for n in sorted(names):
                p = os.path.join(d, n)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                rel = os.path.relpath(p, root)
                b = open(p, "rb").read()
                mode = 0o755 if os.access(p, os.X_OK) else 0o644
                files.append({"path": rel, "sha256": hashlib.sha256(b).hexdigest(), "size": len(b), "mode": mode})
                if tamper:
                    b, tamper = bytes([b[0] ^ 1]) + b[1:] if b else b"x", False
                ti = tarfile.TarInfo(rel)
                ti.size, ti.mode = len(b), mode
                t.addfile(ti, io.BytesIO(b))
    tree = gzip.compress(buf.getvalue(), mtime=0)
    signer = OTHER if flag("badsig") else HUBKEY
    m = dict(meta)
    m.update({"schema": 1, "repo": "o/r", "sha": sha,
              "key": LEGACY[2] if flag("legacy") else hashlib.sha256(raw_pub(signer)).hexdigest()[:16],
              "tree": {"name": "tree.tar.gz", "sha256": hashlib.sha256(tree).hexdigest(), "size": len(tree)},
              "files": files})
    m.setdefault("artifacts", [])
    return json.dumps(m, indent=1).encode(), tree, signer


class H(BaseHTTPRequestHandler):
    def send(self, code, body=b"", hdrs=()):
        self.send_response(code)
        for k, v in hdrs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(os.path.join(W, "hub.log"), "a") as f:
            f.write(self.path + "\n")
        if os.path.exists(os.path.join(W, "nostore")) or not self.path.startswith(P):
            return self.send(404)
        rest = self.path[len(P):]
        if rest == "key":
            if flag("legacy"):
                return self.send(200, LEGACY[1].encode())
            return self.send(200, open(os.path.join(W, "key"), "rb").read())
        if rest == "key-endorsement":
            if not os.path.exists(os.path.join(W, "endorse")):
                return self.send(404)
            line = open(os.path.join(W, "key")).readline()
            return self.send(200, (line + sshsign(PREV, "claude-fleet-release-key", line.encode())).encode())
        sha, _, sub = rest.partition("/")
        if sha == "stable" and not sub:
            sha = open(os.path.join(W, "rel", "stable")).read().strip()
        if not os.path.isdir(os.path.join(W, "rel", sha)):
            return self.send(404)
        mb, tree, signer = build(sha)
        if flag("legacy"):
            sig = LEGACY[0](mb) if not flag("badsig") else LEGACY[0](mb + b" ")
            if sub == "":
                return self.send(200, mb, [] if flag("nosigheader") else [("X-Ccquota-Release-Signature", sig)])
            if sub == "manifest.sig":
                return self.send(200, (sig + "\n").encode())
            if sub == "tree.tar.gz":
                return self.send(200, tree)
            return self.send(404)
        if sub == "":
            sig = sshsign(signer, "claude-fleet-release", mb)
            blob = "".join(l for l in sig.splitlines() if not l.startswith("-----"))
            return self.send(200, mb, [("X-Ccquota-Release-Sshsig", blob)])
        if sub == "manifest.sshsig":
            return self.send(200, sshsign(signer, "claude-fleet-release", mb).encode())
        if sub == "tree.tar.gz":
            return self.send(200, tree)
        return self.send(404)

    def log_message(self, *a):
        pass


s = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=s.serve_forever, daemon=True).start()
open(os.path.join(W, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(W, "port.tmp"), os.path.join(W, "port"))
threading.Event().wait()
