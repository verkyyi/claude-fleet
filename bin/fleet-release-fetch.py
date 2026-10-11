#!/usr/bin/env python3
"""fleet-release-fetch.py — take one of the hub's signed releases with only
what the computer already has: python3's standard library and the system's
`ssh-keygen` (issue #3162, EPIC #3139 C8). A client needs no ccquota.

    fleet-release-fetch.py --hub <url> --pubkey <release.pub> <sha|stable> <dest>

<dest> must not exist. On success it holds the runtime tree and
.release/{manifest.json, manifest.sig, manifest.sshsig} — the same layout as
`ccquota release fetch` (no artifacts: a login install never needs them) —
and `<sha> <seq>` is printed. Exit 1 with the reason on stderr's last line;
nothing is left at <dest> (it is built at <dest>.partial and renamed whole).

TRUST. Only the key pinned in <release.pub> (`ed25519 <base64>`) counts. The
manifest's bytes are checked first, then every byte below them: tree.tar.gz by
the size + sha256 the manifest names, each file in it by its own — an extra,
missing or altered file is refused.

  * The hub signs each manifest it serves in OpenSSH's SSHSIG format too
    (X-Ccquota-Release-Sshsig, namespace claude-fleet-release): checked with
    `ssh-keygen -Y verify` against an allowed_signers line built from the
    pinned key — no new trust, no crypto library.
  * A hub from before that (no SSHSIG at all) is checked with the base64
    ed25519 signature every release always carried, verified by
    fleet-release-verify.py's RFC 8032 code — so a client needs no ccquota
    from its first run, whichever hub it meets.
  * A new signing key is taken only when the pinned one vouches for it: the
    manifest names another key (its `key` = KeyID), the hub's
    /v1/fleet/release/key-endorsement holds that key's line signed by the
    pinned key (namespace claude-fleet-release-key) — then <release.pub> is
    re-pinned (the old kept as release.pub.prev) and said on stderr. No
    endorsement, or one that does not verify: refused, the pin unchanged.

FORMAT. Frozen, only ever added to: a field this reader does not know is
ignored. A release that needs a newer reader says so in `min_client_compat`
(an integer > COMPAT): refused with what to do by hand.
"""
import base64
import gzip
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

COMPAT = 1                       # the release format this reader takes
SCHEMA = 1
NS, KEY_NS = "claude-fleet-release", "claude-fleet-release-key"
SIG_HDR, SSHSIG_HDR = "X-Ccquota-Release-Signature", "X-Ccquota-Release-Sshsig"
MANIFEST_MAX, TREE_MAX = 8 << 20, 512 << 20
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HERE = os.path.dirname(os.path.abspath(__file__))


class Refused(Exception):
    pass


def http_get(url, limit, timeout):
    """(body, headers); Refused on anything but 200. 404 → Refused('404')."""
    req = urllib.request.Request(url, headers={"User-Agent": "fleet-release-fetch"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(limit + 1)
            if len(body) > limit:
                raise Refused("%s: larger than %d bytes" % (url, limit))
            return body, r.headers
    except urllib.error.HTTPError as e:
        raise Refused("HTTP %d from %s" % (e.code, url)) from None
    except (urllib.error.URLError, OSError) as e:
        raise Refused("no answer from %s (%s)" % (url, getattr(e, "reason", e))) from None


def raw_key(line):
    """the 32 raw bytes of an `ed25519 <base64>` line"""
    parts = line.split()
    if len(parts) < 2 or parts[0] != "ed25519":
        raise Refused("not an `ed25519 <base64>` key: %r" % line[:60])
    k = base64.b64decode(parts[1])
    if len(k) != 32:
        raise Refused("not a 32-byte ed25519 key")
    return k


def key_id(raw):
    return hashlib.sha256(raw).hexdigest()[:16]


def ssh_wire(raw):
    def s(b):
        return len(b).to_bytes(4, "big") + b
    return s(b"ssh-ed25519") + s(raw)


def ssh_keygen():
    for c in (shutil.which("ssh-keygen"), "/usr/bin/ssh-keygen"):
        if c and os.access(c, os.X_OK):
            return c
    return None


def armor(blob_b64):
    b = re.sub(r"\s+", "", blob_b64)
    return ("-----BEGIN SSH SIGNATURE-----\n"
            + "\n".join(b[i:i + 70] for i in range(0, len(b), 70))
            + "\n-----END SSH SIGNATURE-----\n")


def ssh_verify(raw, ns, data, armored):
    """True when ssh-keygen -Y verify takes <armored> over <data> by <raw>."""
    kg = ssh_keygen()
    if not kg:
        raise Refused("no ssh-keygen on this computer — it checks the hub's releases")
    with tempfile.TemporaryDirectory(prefix="fleet-rel-") as d:
        signers, sig = os.path.join(d, "allowed_signers"), os.path.join(d, "sig")
        with open(signers, "w") as f:
            f.write('fleet-release namespaces="%s" ssh-ed25519 %s\n'
                    % (ns, base64.b64encode(ssh_wire(raw)).decode()))
        with open(sig, "w") as f:
            f.write(armored)
        p = subprocess.run([kg, "-Y", "verify", "-f", signers, "-I", "fleet-release",
                            "-n", ns, "-s", sig], input=data,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode == 0


def ed25519_verify(raw, data, sig_b64):
    """the release's legacy signature (a hub from before SSHSIG), RFC 8032"""
    spec = importlib.util.spec_from_file_location(
        "fleet_release_verify", os.path.join(HERE, "fleet-release-verify.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    try:
        sig = base64.b64decode(sig_b64.strip(), validate=True)
    except Exception:
        return False
    return mod.verify(raw, data, sig)


class Fetch:
    def __init__(self, hub, pubkey, timeout):
        self.hub = hub.rstrip("/") + "/v1/fleet/release/"
        self.pubkey = pubkey
        self.timeout = timeout
        with open(pubkey) as f:
            self.raw = raw_key(f.readline())

    def get(self, rel, limit):
        return http_get(self.hub + rel, limit, self.timeout)

    def checked(self, mb, at, hdrs, raw):
        """which signature verified ('sshsig' · 'ed25519'), else None. The
        signatures come with the bytes when the hub sends them in the header."""
        blob = (hdrs.get(SSHSIG_HDR) or "").strip()
        sshsig = armor(blob) if blob else None
        if sshsig is None:
            try:
                sshsig = self.get(at + "/manifest.sshsig", 64 << 10)[0].decode()
            except Refused as e:
                if not str(e).startswith("HTTP 404"):
                    raise
        if sshsig is not None:
            return "sshsig" if ssh_verify(raw, NS, mb, sshsig) else None
        sig = (hdrs.get(SIG_HDR) or "").strip()
        if not sig:
            sig = self.get(at + "/manifest.sig", 1024)[0].decode().strip()
        return "ed25519" if ed25519_verify(raw, mb, sig) else None

    def endorsed(self, want_id):
        """the new key the pinned one vouches for, re-pinned; None if none"""
        try:
            body = self.get("key-endorsement", 16 << 10)[0].decode()
        except Refused:
            return None
        line, _, sig = body.partition("\n")
        try:
            new = raw_key(line)
        except Refused:
            return None
        if key_id(new) != want_id or not ssh_verify(self.raw, KEY_NS, (line + "\n").encode(), sig):
            return None
        prev = self.pubkey + ".prev"
        shutil.copyfile(self.pubkey, prev)
        tmp = self.pubkey + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            f.write(line.strip() + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.pubkey)
        sys.stderr.write("fleet-release: the pinned key %s vouched for the hub's new key %s — "
                         "re-pinned %s (the old kept as %s)\n"
                         % (key_id(self.raw), key_id(new), self.pubkey, prev))
        self.raw = new
        return new

    def manifest(self, sha):
        mb, hdrs = self.get(sha, MANIFEST_MAX)
        try:
            m = json.loads(mb)
        except ValueError:
            raise Refused("the hub's manifest for %s is not JSON" % sha[:12])
        at = str(m.get("sha") or "")
        if not SHA_RE.match(at):
            raise Refused("the hub's manifest names no commit")
        how = self.checked(mb, at, hdrs, self.raw)
        if how is None:
            # one more read: a reseal between the two reads (#2843) — then a key
            # the pinned one vouched for, and only that
            mb, hdrs = self.get(sha, MANIFEST_MAX)
            m = json.loads(mb)
            at = str(m.get("sha") or "")
            how = self.checked(mb, at, hdrs, self.raw) if SHA_RE.match(at) else None
            if how is None and m.get("key") and m.get("key") != key_id(self.raw):
                if self.endorsed(str(m.get("key"))) is not None:
                    how = self.checked(mb, at, hdrs, self.raw)
        if how is None:
            raise Refused("release %s: the signature does not match the pinned key %s (%s)"
                          % (at[:12], key_id(self.raw), self.pubkey))
        if m.get("schema") != SCHEMA:
            raise Refused("release %s: manifest schema %r, this reader knows %d"
                          % (at[:12], m.get("schema"), SCHEMA))
        need = m.get("min_client_compat")
        if isinstance(need, int) and need > COMPAT:
            raise Refused("release %s needs a newer fleet client (format %d, this one reads %d) — "
                          "update it by hand: curl -fsSL <hub>/install | sh" % (at[:12], need, COMPAT))
        if sha != "stable" and at != sha:
            raise Refused("asked for %s, the signed manifest is %s" % (sha, at))
        sig = (hdrs.get(SIG_HDR) or "").strip()
        blob = (hdrs.get(SSHSIG_HDR) or "").strip()
        return m, mb, how, sig, blob

    def run(self, sha, dest):
        if os.path.lexists(dest):
            raise Refused("%s already exists" % dest)
        m, mb, how, sig, blob = self.manifest(sha)
        at = m["sha"]
        tree = m.get("tree") or {}
        tb = self.get(at + "/tree.tar.gz", TREE_MAX)[0]
        if len(tb) != tree.get("size") or hashlib.sha256(tb).hexdigest() != tree.get("sha256"):
            raise Refused("tree.tar.gz: digest does not match the manifest")
        tmp = dest + ".partial"
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            unpack(m, tb, tmp)
            meta = os.path.join(tmp, ".release")
            os.makedirs(os.path.join(meta, "artifacts"), exist_ok=True)
            with open(os.path.join(meta, "manifest.json"), "wb") as f:
                f.write(mb)
            if sig:
                with open(os.path.join(meta, "manifest.sig"), "w") as f:
                    f.write(sig + "\n")
            if blob:
                with open(os.path.join(meta, "manifest.sshsig"), "w") as f:
                    f.write(armor(blob))
            os.rename(tmp, dest)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        return m, how


def valid_path(p):
    return (isinstance(p, str) and p and not p.startswith("/") and os.path.normpath(p) == p
            and p not in (".", "..") and not p.startswith("../") and "\\" not in p and "\0" not in p)


def unpack(m, tb, d):
    """every file the manifest names, each checked, under d (as release.Unpack)"""
    want = {}
    for f in m.get("files") or []:
        if not valid_path(f.get("path")):
            raise Refused("manifest: bad path %r" % f.get("path"))
        want[f["path"]] = f
    os.makedirs(d)
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(tb)), mode="r:") as t:
        for h in t:
            f = want.get(h.name)
            if f is None or not h.isreg() or h.name in seen:
                raise Refused("%s: not in the manifest" % h.name)
            b = t.extractfile(h).read(int(f.get("size") or 0) + 1)
            if len(b) != f.get("size") or hashlib.sha256(b).hexdigest() != f.get("sha256"):
                raise Refused("%s: digest does not match the manifest" % h.name)
            p = os.path.join(d, h.name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as o:
                o.write(b)
            os.chmod(p, int(f.get("mode") or 0o644) & 0o755)
            seen.add(h.name)
    if len(seen) != len(want):
        raise Refused("tree: %d of %d files" % (len(seen), len(want)))


def main(argv):
    hub = pub = None
    timeout = 60
    pos = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--hub", "--pubkey", "--timeout") and i + 1 < len(argv):
            if a == "--hub":
                hub = argv[i + 1]
            elif a == "--pubkey":
                pub = argv[i + 1]
            else:
                timeout = float(argv[i + 1])
            i += 2
            continue
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        pos.append(a)
        i += 1
    if not hub or not pub or len(pos) != 2:
        sys.stderr.write("usage: fleet-release-fetch.py --hub <url> --pubkey <file> <sha|stable> <dest>\n")
        return 2
    sha, dest = pos
    if sha != "stable" and not SHA_RE.match(sha):
        sys.stderr.write("bad sha %r\n" % sha)
        return 2
    t0 = time.time()
    try:
        m, how = Fetch(hub, pub, timeout).run(sha, dest)
    except Refused as e:
        sys.stderr.write("%s\n" % e)
        return 1
    except (OSError, ValueError, tarfile.TarError, EOFError) as e:
        sys.stderr.write("release fetch failed: %s\n" % e)
        return 1
    sys.stderr.write("fleet-release: %s seq %s verified (%s) in %.1fs\n"
                     % (m["sha"][:12], m.get("seq") or 0, how, time.time() - t0))
    print(m["sha"], int(m.get("seq") or 0))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
