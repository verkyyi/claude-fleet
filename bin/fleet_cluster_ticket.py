#!/usr/bin/python3 -I
"""fleet_cluster_ticket.py — the cluster provisioner's ticket (issue #3558, EPIC #3500 C16).

In the cluster ONE service may write to Kubernetes: fleet-provisioner
(bin/fleet-provisioner.py). It is never connected to the hub; fleet-ops hands it
what the hub sent, and it runs an op only on a ticket the hub signed with its
account-op key (the same key as the admin seat's account tickets, C15 —
GET /v1/fleet/account-key) under its own domain, so neither kind of ticket can
ever stand in for the other:

  c1.<payload>.<sig>   base64url, no padding; sig = ed25519 over
                       "fleet-cluster-ticket-v1\\0" + the payload bytes as sent

The payload is exactly {op, cluster, nonce, exp} plus the op's own fields:

  create-user-pod   pod, limits, join  a person's pod (render.py --user-pod) and
                                       its join Secret (the pod's one-time
                                       machine join code, #3553)
  destroy-user-pod  pod                those, and the join Secret
  set-limits        pod, limits        only that pod's Deployment rolls
  create-job        pod, repo, ref     a throwaway Job for that pod's session
  bind-user-pod     pod, principal     a claimed spare pod's fleet/principal
                                       label (#3553)

tokenledger/internal/control/cluster_ticket.go is the Go twin; its test pins one
ticket both sides make byte for byte. check() refuses a ticket not the key's,
for another cluster, past its exp, with a field missing, extra or off its
grammar; the caller spends the nonce (once, cluster-wide — the provisioner's
book is a ConfigMap). Pure Python (fleet_ed25519.py): no package to trust.
"""
import base64
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fleet_ed25519  # noqa: E402
from fleet_admin_ticket import Refused, b64url, read_pub  # noqa: E402,F401

PREFIX = "c1."
DOMAIN = b"fleet-cluster-ticket-v1\x00"
COMMON = ("op", "cluster", "nonce", "exp")
OPS = {
    "create-user-pod": ("pod", "limits", "join"),
    "destroy-user-pod": ("pod",),
    "set-limits": ("pod", "limits"),
    "create-job": ("pod", "repo", "ref"),
    "bind-user-pod": ("pod", "principal"),
}
# the Go struct's field order (json.Marshal): what sign() writes, so the bytes match
ORDER = ("op", "cluster", "pod", "limits", "repo", "ref", "join", "principal", "nonce", "exp")
GRAMMAR = {
    "cluster": re.compile(r"^[a-z0-9][a-z0-9.-]{0,62}$"),
    "pod": re.compile(r"^u-[a-z0-9]{4,20}$"),
    # render.user_pod_limits is the full check; this keeps the field to its alphabet
    "limits": re.compile(r"^[a-z]+=[0-9]+[A-Za-z]{0,2}(,[a-z]+=[0-9]+[A-Za-z]{0,2}){0,2}$|^$"),
    "repo": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$"),
    "ref": re.compile(r"^[0-9a-f]{40}$"),
    # the hub's MintJoinCode: fj_ + 26 of base32's lower alphabet
    "join": re.compile(r"^fj_[a-z2-7]{26}$"),
    # a Kubernetes label value (the hub writes gh:12345 as gh.12345)
    "principal": re.compile(r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$"),
    "nonce": re.compile(r"^[0-9a-f]{32}$"),
}


def check(pub, ticket, cluster, now):
    """The ticket's fields when it is the key's, for this cluster, not expired,
    and exactly its op's shape; else Refused."""
    if not ticket:
        raise Refused("no ticket: the provisioner acts only on one the hub signed")
    if not ticket.startswith(PREFIX):
        raise Refused("not a c1 cluster ticket")
    parts = ticket[len(PREFIX):].split(".")
    if len(parts) != 2:
        raise Refused("malformed ticket")
    try:
        payload, sig = b64url(parts[0]), b64url(parts[1])
    except (ValueError, TypeError):
        raise Refused("malformed ticket")
    if not fleet_ed25519.verify(pub, DOMAIN + payload, sig):
        raise Refused("ticket not signed by the hub's account key")
    try:
        t = json.loads(payload)
    except ValueError:
        raise Refused("malformed ticket")
    if not isinstance(t, dict) or t.get("op") not in OPS:
        raise Refused("not a provisioner op: %r" % (t.get("op") if isinstance(t, dict) else t))
    want = set(COMMON) | set(OPS[t["op"]])
    if set(t) != want:
        raise Refused("%s ticket fields are not {%s}" % (t["op"], ", ".join(sorted(want))))
    if not isinstance(t["exp"], int) or isinstance(t["exp"], bool) or now >= t["exp"]:
        raise Refused("ticket expired")
    for k, v in t.items():
        if k in GRAMMAR and not (isinstance(v, str) and GRAMMAR[k].match(v)):
            raise Refused("ticket %s %r is off its grammar" % (k, v))
    if t["cluster"] != cluster:
        raise Refused("ticket is for cluster %r, not %r" % (t["cluster"], cluster))
    return t


def sign(seed, fields):
    """The hub's side (control.SignClusterTicket), for drills and tests only:
    the provisioner never holds a private key."""
    # Go's order first; any other key after it (a drill's off-template field)
    ordered = dict((k, fields[k]) for k in ORDER if k in fields)
    ordered.update((k, v) for k, v in fields.items() if k not in ORDER)
    payload = json.dumps(ordered, separators=(",", ":")).encode()
    enc = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()  # noqa: E731
    return PREFIX + enc(payload) + "." + enc(fleet_ed25519.sign(seed, DOMAIN + payload))


if __name__ == "__main__":
    # sign <seed-file> <json fields> | pub <seed-file> — drills only
    if len(sys.argv) >= 3 and sys.argv[1] in ("sign", "pub"):
        seed = open(sys.argv[2], "rb").read()
        if sys.argv[1] == "pub":
            print("ed25519 " + base64.b64encode(fleet_ed25519.public_key(seed)).decode())
        else:
            print(sign(seed, json.loads(sys.argv[3])))
        sys.exit(0)
    print(__doc__.split("\n\n")[0], file=sys.stderr)
    sys.exit(2)
