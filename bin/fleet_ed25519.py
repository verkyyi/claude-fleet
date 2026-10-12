"""fleet_ed25519.py — Ed25519 (RFC 8032) in plain Python, for the root core
(issue #3555, EPIC #3500 C13).

The core re-checks a release's signature itself before it moves `current`, and it
must not lean on the binary it is about to replace (ccquota) nor on a package a
stock /usr/bin/python3 does not have. So: the RFC's own arithmetic, extended
coordinates, nothing else. `verify` is what the core runs; `sign` / `public_key`
exist for the selftests and the BREAK-IT drills, which sign a release of their own.
Not constant-time — it handles public data only (a signature check), never a key
the core holds.
"""
import hashlib

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _sha512(b):
    return hashlib.sha512(b).digest()


def _inv(x):
    return pow(x, P - 2, P)


def _add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _equal(p, q):
    x1, y1, z1, _ = p
    x2, y2, z2, _ = q
    return (x1 * z2 - x2 * z1) % P == 0 and (y1 * z2 - y2 * z1) % P == 0


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


_GY = 4 * _inv(5) % P
_GX = _recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def _compress(p):
    x, y, z, _ = p
    zi = _inv(z)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def _secret_expand(secret):
    if len(secret) != 32:
        raise ValueError("an Ed25519 secret is 32 bytes")
    h = _sha512(secret)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(secret):
    a, _ = _secret_expand(secret)
    return _compress(_mul(a, G))


def sign(secret, msg):
    a, prefix = _secret_expand(secret)
    pub = _compress(_mul(a, G))
    r = int.from_bytes(_sha512(prefix + msg), "little") % L
    rs = _compress(_mul(r, G))
    h = int.from_bytes(_sha512(rs + pub + msg), "little") % L
    s = (r + h * a) % L
    return rs + int.to_bytes(s, 32, "little")


def verify(pub, msg, sig):
    """True only for a valid signature of msg by pub (both raw bytes)."""
    if len(pub) != 32 or len(sig) != 64:
        return False
    a = _decompress(pub)
    if a is None:
        return False
    r = _decompress(sig[:32])
    if r is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= L:
        return False
    h = int.from_bytes(_sha512(sig[:32] + pub + msg), "little") % L
    return _equal(_mul(s, G), _add(r, _mul(h, a)))
