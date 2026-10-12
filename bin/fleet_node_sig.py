#!/usr/bin/env python3
"""fleet_node_sig.py — a node's own signing key: its requests are signed, not a
token anyone can copy (issue #3699, EPIC #3500; 发起人拍板 23).

A machine (machine.env) or a login (node.env) holds an Ed25519 key beside its
token; once the hub has its public key (POST /v1/node/key), a request carries

    Authorization: FleetSig keyid=nk_…, ts=<unix>, nonce=<random>, sig=<b64url>

signed over the lines `fleet-sig-v1 · keyid · ts · nonce · METHOD · URI` — the
hub's half is tokenledger/internal/api/node_sig.go. A signature is good once and
for two minutes, so a copied header is worth nothing and the private key never
leaves this file. This script only does the arithmetic; HTTP is the caller's
(curl, with its own seams).

    fleet_node_sig.py keygen <keyfile>              # new key, 0600; refuses to overwrite
    fleet_node_sig.py keyid <keyfile>               # nk_<24 hex of sha256(pub)>
    fleet_node_sig.py pub <keyfile>                 # base64 public key
    fleet_node_sig.py register-body <keyfile> [--bearer-off]
                                                    # the JSON POST /v1/node/key takes
    fleet_node_sig.py header <keyfile> <METHOD> <URI>
                                                    # the Authorization value for one request

The key file holds the 32-byte seed in base64 on one line. Signing uses the
`cryptography` package when present (constant time), else fleet_ed25519.py (plain
Python, RFC 8032) — a stock /usr/bin/python3 has only the second.

Exit: 0 · 1 failure (stderr says why) · 2 usage.
"""
import base64
import hashlib
import json
import os
import secrets
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_ed25519  # noqa: E402

VERSION = "fleet-sig-v1"
PROOF_LINE = "fleet-node-key-v1"


def _read_seed(path):
    with open(path) as f:
        seed = base64.b64decode(f.read().strip())
    if len(seed) != 32:
        raise ValueError("%s: not a 32-byte Ed25519 seed" % path)
    return seed


def _public(seed):
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives import serialization
        k = Ed25519PrivateKey.from_private_bytes(seed)
        return k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    except ImportError:
        return fleet_ed25519.public_key(seed)


def _sign(seed, msg):
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        return Ed25519PrivateKey.from_private_bytes(seed).sign(msg)
    except ImportError:
        return fleet_ed25519.sign(seed, msg)


def key_id(pub):
    return "nk_" + hashlib.sha256(pub).hexdigest()[:24]


def message(kid, ts, nonce, method, uri):
    return "\n".join([VERSION, kid, ts, nonce, method, uri]).encode()


def b64url(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def keygen(path):
    seed = secrets.token_bytes(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(base64.b64encode(seed).decode() + "\n")
    return seed


def header(seed, method, uri, now=None, nonce=None):
    pub = _public(seed)
    kid = key_id(pub)
    ts = str(int(now if now is not None else time.time()))
    nonce = nonce or secrets.token_urlsafe(18)
    sig = _sign(seed, message(kid, ts, nonce, method.upper(), uri))
    return "FleetSig keyid=%s, ts=%s, nonce=%s, sig=%s" % (kid, ts, nonce, b64url(sig))


def register_body(seed, bearer_off=False):
    pub = base64.b64encode(_public(seed)).decode()
    proof = b64url(_sign(seed, (PROOF_LINE + "\n" + pub).encode()))
    return {"public_key": pub, "proof": proof, "bearer_off": bool(bearer_off)}


def main(argv):
    if len(argv) < 2 or argv[0] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, path = argv[0], argv[1]
    try:
        if cmd == "keygen":
            if len(argv) != 2:
                return 2
            if os.path.exists(path) and os.path.getsize(path) > 0:
                print("fleet_node_sig: %s already holds a key (never overwritten)" % path, file=sys.stderr)
                return 1
            if os.path.exists(path):
                os.unlink(path)
            print(key_id(_public(keygen(path))))
            return 0
        seed = _read_seed(path)
        if cmd == "keyid" and len(argv) == 2:
            print(key_id(_public(seed)))
        elif cmd == "pub" and len(argv) == 2:
            print(base64.b64encode(_public(seed)).decode())
        elif cmd == "register-body" and len(argv) in (2, 3):
            off = len(argv) == 3
            if off and argv[2] != "--bearer-off":
                return 2
            print(json.dumps(register_body(seed, off)))
        elif cmd == "header" and len(argv) == 4:
            print(header(seed, argv[2], argv[3]))
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    except (OSError, ValueError) as e:
        print("fleet_node_sig: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
