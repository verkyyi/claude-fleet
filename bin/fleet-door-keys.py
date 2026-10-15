#!/usr/bin/env python3
"""fleet-door-keys.py — the door's jump account's AuthorizedKeysCommand
(claude-fleet#4193, design #4181 A2).

The door's sshd has one fixed account (fleet-jump, baked into the door image):
no shell, no session. sshd asks this script, as `nobody`, which keys it takes
for that account, handing it the key the client offered:

    fleet-door-keys.py <book> <keys dir> <namespace> <jump user> [--targets M] <%u> <%t> <%k>

It answers the key's ONE line when the door's book knows it — a key of a
person whose home is a pod — with the only thing that key may do:

    restrict,port-forwarding,permitopen="u-<nonce>.<namespace>.svc.cluster.local:22" <type> <b64>

a tunnel to its owner's own pod, port 22, and nothing else (a person with two
pods, #3562: one permitopen each). Every other key, user or shape: nothing,
exit 0 — sshd refuses it. The real login is the pod's own sshd's, with the
person's own key: the door holds no key into any pod on this road.

<book> is the door's state.json (0644; its `jump` section, written from
GET /v1/node/entry-routes: login → service), <keys dir> the door's jump keys
files (entry/jump-keys/<login>, 0644) — read, never written; nothing here
logs (the door's sshd log line, LogLevel VERBOSE, is the record:
fleet-node-supervisor.py's entry audit names the person and the pod).
--targets (the drill's seam, written only under FLEET_NODE_TEST): u-<nonce>=host:port,…
"""
import json
import os
import re
import sys

SERVICE_RE = re.compile(r"^u-[a-z0-9]{4,20}$")
LOGIN_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
TYPE_RE = re.compile(r"^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|"
                     r"sk-ecdsa-sha2-nistp256@openssh\.com)$")
B64_RE = re.compile(r"^[A-Za-z0-9+/]{16,16384}={0,2}$")
NS_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
TARGET_RE = re.compile(r"^[A-Za-z0-9.-]{1,253}:[0-9]{1,5}$")


def targets_of(spec):
    out = {}
    for item in (spec or "").split(","):
        svc, _, tgt = item.partition("=")
        if SERVICE_RE.match(svc) and TARGET_RE.match(tgt):
            out[svc] = tgt
    return out


def answer(book, keys_dir, ns, jump, user, ktype, kb64, targets=None):
    """The keys-file line for <ktype> <kb64> offered as <user>, or ""."""
    if user != jump or not TYPE_RE.match(ktype or "") or not B64_RE.match(kb64 or "") or not NS_RE.match(ns or ""):
        return ""
    try:
        with open(book) as f:
            logins = (json.load(f).get("jump") or {})
    except (OSError, ValueError, AttributeError):
        return ""
    opens = []
    for login in sorted(logins):
        ent = logins[login] if isinstance(logins[login], dict) else {}
        svc = str(ent.get("service") or "")
        if not LOGIN_RE.match(login) or not SERVICE_RE.match(svc):
            continue
        try:
            with open(os.path.join(keys_dir, login)) as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        if not any(l.split()[:2] == [ktype, kb64] for l in lines if l.strip()):
            continue
        tgt = (targets or {}).get(svc) or "%s.%s.svc.cluster.local:22" % (svc, ns)
        if tgt not in opens:
            opens.append(tgt)
    if not opens:
        return ""
    return "restrict,port-forwarding,%s %s %s\n" % (
        ",".join('permitopen="%s"' % t for t in opens), ktype, kb64)


def main(argv):
    targets = None
    args = list(argv)
    if "--targets" in args:
        i = args.index("--targets")
        targets = targets_of(args[i + 1] if i + 1 < len(args) else "")
        del args[i:i + 2]
    if len(args) != 7:
        return 0
    book, keys_dir, ns, jump, user, ktype, kb64 = args
    sys.stdout.write(answer(book, keys_dir, ns, jump, user, ktype, kb64, targets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
