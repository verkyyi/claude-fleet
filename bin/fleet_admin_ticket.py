#!/usr/bin/python3 -I
"""fleet_admin_ticket.py — the admin seat's ticket check (issue #3557, EPIC #3500 C15).

The machine's account ops run as root through two sudo-able scripts the admin
role account (_fleetadmin / fleetadmin) may call; bin/fleet-admin-gate.sh is
those two scripts, and before anything runs it asks this:

  fleet_admin_ticket.py spend --pub <file> --used <dir> --op <op> --login <login>
                              [--machine <name>] [--trust <path>]... <ticket>

exit 0: the ticket is the hub's account key's, for exactly this op, login and
machine, not past its exp — and its nonce (the op's op_id) was not spent
before: it is spent now, in <used>/<nonce> (O_EXCL). Exit 3: refused, one
line on stderr saying why; nothing is spent. Exit 2: usage. Run as root (the
gate under sudo), every file it trusts — the key, the nonce book, this program
and its directory, each --trust path — must be root's and writable by no one
else, or it refuses: a key or a book another account could write is no check.

A ticket is `v1.<payload>.<sig>` (base64url, no padding): the signature is the
hub's ed25519 over "fleet-account-ticket-v1\\0" + the payload bytes as sent
(tokenledger/internal/control/account_ticket.go is the Go twin; its test pins
one ticket both sides make byte for byte). The public key file is
`ed25519 <base64>` — what GET /v1/fleet/account-key serves, pinned root-owned
beside the gate. Pure Python (fleet_ed25519.py): no package to trust.
"""
import base64
import json
import os
import re
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_ed25519  # noqa: E402

PREFIX = "v1."
DOMAIN = b"fleet-account-ticket-v1\x00"
OPS = ("create", "remove", "reset")
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
LOGIN_RE = re.compile(r"^[a-z0-9][a-z0-9_]{0,31}$")
# a spent nonce is kept this long past its ticket's exp: by then the ticket is
# refused as expired anyway, so dropping the mark cannot reopen a replay
KEEP_PAST_EXP = 86400


class Refused(Exception):
    pass


def b64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def read_pub(path):
    try:
        with open(path) as f:
            kind, b64 = f.read().split()[:2]
        raw = base64.b64decode(b64, validate=True)
    except (OSError, ValueError, TypeError):
        raise Refused("no account key at %s" % path)
    if kind != "ed25519" or len(raw) != 32:
        raise Refused("%s is not an ed25519 public key" % path)
    return raw


def check(pub, ticket, op, login, machine, now):
    """The ticket's fields when it is the key's, for exactly (op, login, machine),
    and not expired; else Refused."""
    if not ticket:
        raise Refused("no ticket: an account op runs here only with one the hub signed")
    if not ticket.startswith(PREFIX):
        raise Refused("not a v1 account ticket")
    parts = ticket[len(PREFIX):].split(".")
    if len(parts) != 2:
        raise Refused("malformed ticket")
    try:
        payload, sig = b64url(parts[0]), b64url(parts[1])
    except (ValueError, TypeError):
        raise Refused("malformed ticket")
    if not fleet_ed25519.verify(pub, DOMAIN + payload, sig):
        raise Refused("ticket not signed by this machine's account key")
    try:
        t = json.loads(payload)
    except ValueError:
        raise Refused("malformed ticket")
    if not isinstance(t, dict) or set(t) != {"op", "login", "machine", "nonce", "exp"}:
        raise Refused("ticket fields are not {op, login, machine, nonce, exp}")
    if not isinstance(t["exp"], int) or now >= t["exp"]:
        raise Refused("ticket expired")
    if not isinstance(t["nonce"], str) or not NONCE_RE.match(t["nonce"]):
        raise Refused("ticket nonce is not an op id")
    for k, want in (("op", op), ("login", login), ("machine", machine)):
        if t[k] != want:
            raise Refused("ticket is for %s %r, not %r" % (k, t[k], want))
    return t


def trusted(paths):
    """Refused unless each path is root's and not group/other-writable (as root
    only: a test run as a person checks the ticket, not the owners)."""
    if os.geteuid() != 0:
        return
    for p in paths:
        try:
            st = os.lstat(p)
        except OSError:
            raise Refused("%s is missing" % p)
        if st.st_uid != 0 or st.st_mode & 0o022:
            raise Refused("%s is not root's alone (uid %d, mode %o)" % (p, st.st_uid, st.st_mode & 0o7777))


def spend(used, nonce, exp, now):
    """Mark nonce spent; Refused when it already was (a replay)."""
    os.makedirs(used, mode=0o700, exist_ok=True)
    try:
        fd = os.open(os.path.join(used, nonce), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Refused("ticket already used (nonce %s)" % nonce)
    with os.fdopen(fd, "w") as f:
        f.write("%d\n" % exp)
    prune(used, now)


def prune(used, now):
    for name in os.listdir(used):
        p = os.path.join(used, name)
        try:
            with open(p) as f:
                exp = int(f.read().strip() or 0)
        except (OSError, ValueError):
            continue
        if now > exp + KEEP_PAST_EXP:
            try:
                os.unlink(p)
            except OSError:
                pass


def main(argv):
    if not argv or argv[0] != "spend":
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    opts, rest, trust = {}, [], []
    it = iter(argv[1:])
    for a in it:
        if a == "--":  # the rest is the ticket, never an option
            rest.extend(it)
            break
        if a in ("--pub", "--used", "--op", "--login", "--machine", "--trust"):
            v = next(it, None)
            if v is None:
                return 2
            if a == "--trust":
                trust.append(v)
            else:
                opts[a[2:]] = v
        else:
            rest.append(a)
    if len(rest) != 1 or not {"pub", "used", "op", "login"} <= set(opts):
        print("usage: fleet_admin_ticket.py spend --pub F --used D --op O --login L [--machine M] <ticket>",
              file=sys.stderr)
        return 2
    machine = opts.get("machine") or socket.gethostname()
    now = int(time.time())
    try:
        if opts["op"] not in OPS or not LOGIN_RE.match(opts["login"]):
            raise Refused("not an account op: %s %s" % (opts["op"], opts["login"]))
        used = opts["used"]
        trusted([HERE, os.path.abspath(__file__), opts["pub"], os.path.dirname(os.path.abspath(used))]
                + ([used] if os.path.exists(used) else []) + trust)
        t = check(read_pub(opts["pub"]), rest[0], opts["op"], opts["login"], machine, now)
        spend(used, t["nonce"], t["exp"], now)
    except Refused as e:
        print("fleet_admin_ticket: refused: %s" % e, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
