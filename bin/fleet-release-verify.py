#!/usr/bin/env python3
"""fleet-release-verify.py — check a hub release's signed manifest against the
key this login pinned, with no ccquota (issue #3047).

    fleet-release-verify.py <pubkey file> <manifest file> <signature> [<artifact>]

<pubkey file> holds `ed25519 <base64>` (release.pub); <signature> is the base64
the hub sends as X-Ccquota-Release-Signature / manifest.sig (`@<file>` reads it
from a file). The signature is checked over the manifest's exact bytes — the
same check as ccquota's release.Verify — then the manifest is read.

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
    if not verify(pub, msg, sig):
        sys.stderr.write("fleet-release-verify: signature does not match the pinned key\n")
        return 1
    try:
        m = json.loads(msg)
        sha, seq = str(m.get("sha") or ""), int(m.get("seq") or 0)
    except (ValueError, TypeError, AttributeError):
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
