#!/usr/bin/env python3
"""fleet-release-verify.py — check a hub release's signed manifest against the
key this login pinned, with no ccquota (issue #3047).

    fleet-release-verify.py <pubkey file> <manifest file> <signature> [<artifact>]

<pubkey file> holds `ed25519 <base64>` (release.pub); <signature> is the base64
the hub sends as X-Ccquota-Release-Signature / manifest.sig (`@<file>` reads it
from a file). The signature is checked over the manifest's exact bytes — the
same check as ccquota's release.VerifyTrusted: by the pinned key, or by a key
it vouches for through the manifest's key_chain that no revocation (the
manifest's, or <pubkey file>.revoked) names (issue #3559) — then the manifest
is read.

As a module it is the ONE Python copy of the release trust: verify / sign,
the key chain, the revocation list (fleet-release-fetch.py, fleet-release-sign.py
and the selftests' hub import it).

Prints `<sha> <seq>`, and with <artifact> a second line: that artifact's
sha256 as the signed manifest names it.

Exit 0 verified · 1 the signature does not verify, or the manifest / artifact
is not there · 2 usage.

Why it exists: a login whose ccquota predates `ccquota release` cannot check
any release, so it could never take the release that carries a newer ccquota.
This lets the already-pinned key vouch for that ccquota — no new trust, no
re-pin. macOS's python3 (3.9) and LibreSSL have no ed25519, so the RFC 8032
verification is written out below (verify only: no secret, no timing concern).
"""
import base64
import hashlib
import json
import os
import re
import sys

P = 2 ** 255 - 19
Q = 2 ** 252 + 27742317777372353535851937790883648493


def _inv(x):
    return pow(x, P - 2, P)


D = -121665 * _inv(121666) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    aa = (y1 - x1) * (y2 - x2) % P
    bb = (y1 + x1) * (y2 + x2) % P
    cc = 2 * t1 * t2 * D % P
    dd = 2 * z1 * z2 % P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, pt):
    acc = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            acc = _add(acc, pt)
        pt = _add(pt, pt)
        s >>= 1
    return acc


def _eq(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1)
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


def _decompress(b):
    if len(b) != 32:
        return None
    y = int.from_bytes(b, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


_GY = 4 * _inv(5) % P
G = (_recover_x(_GY, 0), _GY, 1, _recover_x(_GY, 0) * _GY % P)


def verify(pub, msg, sig):
    """RFC 8032 §5.1.7: True when sig is pub's Ed25519 signature over msg."""
    if len(pub) != 32 or len(sig) != 64:
        return False
    a = _decompress(pub)
    r = _decompress(sig[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= Q:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), "little") % Q
    return _eq(_mul(s, G), _add(r, _mul(h, a)))


# ── signing (RFC 8032 §5.1.6) — the offline root and the train's key ─────────
# Not constant-time: it runs on the root key's own offline computer and in the
# release train's job, never on a machine that serves anything (issue #3559).

def _enc(pt):
    zi = _inv(pt[2])
    x, y = pt[0] * zi % P, pt[1] * zi % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _expand(seed):
    if len(seed) != 32:
        raise ValueError("an ed25519 seed is 32 bytes")
    h = hashlib.sha512(seed).digest()
    return int.from_bytes(h[:32], "little") & ((1 << 254) - 8) | (1 << 254), h[32:]


def pub_of(seed):
    """the 32-byte public key of a 32-byte seed"""
    return _enc(_mul(_expand(seed)[0], G))


def sign(seed, msg):
    """the 64-byte Ed25519 signature of msg"""
    a, prefix = _expand(seed)
    pub = _enc(_mul(a, G))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % Q
    rb = _enc(_mul(r, G))
    k = int.from_bytes(hashlib.sha512(rb + pub + msg).digest(), "little") % Q
    return rb + ((r + k * a) % Q).to_bytes(32, "little")


def read_seed(path):
    """a secret key file: base64 32-byte seed on one line (what ccquota's
    LoadPrivateKey and `fleet-release-sign.py keygen` write)"""
    with open(path) as f:
        raw = base64.b64decode(f.read().strip(), validate=True)
    if len(raw) != 32:
        raise ValueError("%s: not a base64 32-byte ed25519 seed" % path)
    return raw


def key_line(raw):
    return "ed25519 " + base64.b64encode(raw).decode()


def key_id(raw):
    """ccquota's release.KeyID: sha256 of the raw key, 16 hex"""
    return hashlib.sha256(raw).hexdigest()[:16]


def parse_key(line):
    parts = str(line).split()
    if len(parts) != 2 or parts[0] != "ed25519":
        raise ValueError("not an `ed25519 <base64>` key")
    raw = base64.b64decode(parts[1])
    if len(raw) != 32:
        raise ValueError("not an ed25519 public key")
    return raw


# ── the key chain and the revocation list (issue #3559) ──────────────────────
# Both are signed documents in ONE envelope, {"payload": <base64 of the exact
# JSON bytes>, "sig": <base64 Ed25519 over DOC_PREFIX + those bytes>} — the
# bytes travel as they were signed, so no reader re-serializes anything
# (ccquota's release.Doc is the same). Payloads:
#
#   {"schema":1,"kind":"release-key","key":"ed25519 …","role":"sign"|"root",
#    "by":"<signer's key id>","created":"…","note":"…"}
#        `by` vouches for `key`. role root may vouch and revoke in turn — only
#        when `by` is itself a root (the pinned key always is).
#   {"schema":1,"kind":"release-revoked","version":N,"keys":["<key id>",…],
#    "by":"<a root's key id>","created":"…"}
#        nothing those keys signed counts, from the first time a machine sees
#        the list; a machine keeps every id it ever saw (<pin>.revoked).

DOC_PREFIX = b"claude-fleet-release-doc\n"


def make_doc(seed, payload):
    b = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return {"payload": base64.b64encode(b).decode(),
            "sig": base64.b64encode(sign(seed, DOC_PREFIX + b)).decode()}


def doc_payload(doc):
    """(payload dict, its bytes) — UNVERIFIED; None when malformed"""
    try:
        b = base64.b64decode(doc["payload"], validate=True)
        p = json.loads(b)
        return (p, b) if isinstance(p, dict) else None
    except Exception:
        return None


def doc_verifies(doc, raw):
    got = doc_payload(doc)
    if got is None:
        return False
    try:
        sig = base64.b64decode(doc["sig"], validate=True)
    except Exception:
        return False
    return verify(raw, DOC_PREFIX + got[1], sig)


def _close(anchor, chain, revoked):
    aid = key_id(anchor)
    t = {aid: (anchor, "root", "")}
    grew = True
    while grew:
        grew = False
        for d in chain or []:
            got = doc_payload(d) if isinstance(d, dict) else None
            if got is None or got[0].get("kind") != "release-key":
                continue
            p = got[0]
            by = str(p.get("by") or "")
            if by not in t or (by in revoked and by != aid):
                continue
            try:
                raw = parse_key(p.get("key"))
            except (ValueError, TypeError):
                continue
            kid = key_id(raw)
            if kid in t or kid in revoked or not doc_verifies(d, t[by][0]):
                continue
            role = "root" if p.get("role") == "root" and t[by][1] == "root" else "sign"
            t[kid] = (raw, role, by)
            grew = True
    return t


def trust(anchor, chain, revocations, known=()):
    """Every key the pinned <anchor> vouches for through <chain>, after every
    revocation a root among them signed: (trusted {id: (raw, role, by)},
    revoked ids, the newest list's version, a root the anchor vouched for
    directly — the key to re-pin to, else None). The anchor itself is never
    revoked: a pinned root that leaked is the one case a person re-pins."""
    aid = key_id(anchor)
    rev = set(known) - {aid}
    ver = 0
    first = _close(anchor, chain, rev)
    for d in revocations or []:
        got = doc_payload(d) if isinstance(d, dict) else None
        if got is None or got[0].get("kind") != "release-revoked":
            continue
        p = got[0]
        by = first.get(str(p.get("by") or ""))
        if by is None or by[1] != "root" or not doc_verifies(d, by[0]):
            continue
        rev |= {str(k) for k in p.get("keys") or [] if re.match(r"^[0-9a-f]{16}$", str(k))}
        try:
            ver = max(ver, int(p.get("version") or 0))
        except (TypeError, ValueError):
            pass
    rev.discard(aid)
    t = _close(anchor, chain, rev)
    repin = None
    for kid, (raw, role, by) in t.items():
        if role == "root" and by == aid and kid != aid:
            repin = raw
            break
    return t, rev, ver, repin


def load_revoked(path):
    """(ids, version) a machine has already seen — <pin>.revoked"""
    try:
        with open(path) as f:
            d = json.load(f)
        return {str(k) for k in d.get("keys") or []}, int(d.get("version") or 0)
    except (OSError, ValueError, TypeError, AttributeError):
        return set(), 0


def save_revoked(path, ids, version):
    """keep every id ever seen (only ever grows); one rename"""
    old, over = load_revoked(path)
    ids, version = set(ids) | old, max(version, over)
    if ids == old and version == over and os.path.exists(path):
        return
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump({"version": version, "keys": sorted(ids)}, f)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def signer_of(anchor, manifest, extra_revocations=(), known=()):
    """(the raw key that must have signed <manifest> (a dict), trust()'s tuple)
    or (None, why) — before any signature is checked"""
    chain = manifest.get("key_chain") or []
    revs = [manifest["revoked"]] if isinstance(manifest.get("revoked"), dict) else []
    revs += [d for d in extra_revocations or [] if isinstance(d, dict)]
    t = trust(anchor, chain, revs, known)
    want = str(manifest.get("key") or key_id(anchor))
    if want in t[1]:
        return None, "signed by %s, a key the root revoked" % want
    if want not in t[0]:
        return None, ("the signature does not match the pinned key %s (signed by %s, which it does not vouch for)"
                      % (key_id(anchor), want))
    return t[0][want][0], t


def _pubkey(path):
    with open(path) as f:
        line = f.readline().split()
    if len(line) != 2 or line[0] != "ed25519":
        raise ValueError("not an `ed25519 <base64>` key")
    raw = base64.b64decode(line[1])
    if len(raw) != 32:
        raise ValueError("not an ed25519 public key")
    return raw


def main(argv):
    if len(argv) not in (3, 4):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    try:
        pub = _pubkey(argv[0])
        with open(argv[1], "rb") as f:
            msg = f.read()
        s = argv[2]
        if s.startswith("@"):
            with open(s[1:]) as f:
                s = f.read()
        sig = base64.b64decode(s.strip())
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-release-verify: %s\n" % e)
        return 1
    try:
        m = json.loads(msg)
        if not isinstance(m, dict):
            raise ValueError
    except ValueError:
        sys.stderr.write("fleet-release-verify: the manifest is not JSON\n")
        return 1
    # the pinned key, or one it vouches for through the manifest's key_chain
    # and no revocation names (issue #3559)
    signer, why = signer_of(pub, m, known=load_revoked(argv[0] + ".revoked")[0])
    if signer is None:
        sys.stderr.write("fleet-release-verify: %s\n" % why)
        return 1
    if not verify(signer, msg, sig):
        sys.stderr.write("fleet-release-verify: signature does not match the pinned key\n")
        return 1
    try:
        sha, seq = str(m.get("sha") or ""), int(m.get("seq") or 0)
    except (ValueError, TypeError):
        sys.stderr.write("fleet-release-verify: the signed manifest is not JSON\n")
        return 1
    if not re.match(r"^[0-9a-f]{40}$", sha):
        sys.stderr.write("fleet-release-verify: the signed manifest names no sha\n")
        return 1
    print(sha, seq)
    if len(argv) == 4:
        for a in m.get("artifacts") or []:
            if isinstance(a, dict) and a.get("name") == argv[3] and re.match(r"^[0-9a-f]{64}$", str(a.get("sha256") or "")):
                print(a["sha256"])
                return 0
        sys.stderr.write("fleet-release-verify: the signed release carries no %s\n" % argv[3])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
