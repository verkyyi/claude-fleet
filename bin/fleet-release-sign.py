#!/usr/bin/env python3
"""fleet-release-sign.py — the release signing key's two homes: the offline ROOT
key a person keeps, and the release train's `release-sign` key (issue #3559,
EPIC #3500 C17). Standard library only, so it runs on the root's offline
computer and in the train's job alike — never on the hub, never in a session.

    fleet-release-sign.py keygen <secret file>
        a new ed25519 key: the base64 seed written 0600 (refuses an existing
        file); its `ed25519 <base64>` line and key id printed
    fleet-release-sign.py pub <key>
        its public line
    fleet-release-sign.py cert --by <key> --key <pub line | file> --role sign|root
                               [--note TEXT] [--add <chain.json>]
        <key> vouches for the other: one key_chain entry printed, or appended
        to <chain.json> (conf/release-keys/chain.json — committed, public)
    fleet-release-sign.py revoke --by <root key> --version N [--out <revoked.json>] <key id>…
        the root's revocation list: nothing those keys signed counts again.
        Lists are cumulative — name every id still revoked, raise the version.
    fleet-release-sign.py show [--anchor <pub line | file>] [<chain.json> [<revoked.json>]]
        what a machine pinned to <anchor> (default: conf/release-keys/root.pub)
        trusts: every key, its role, who vouched, what is revoked
    fleet-release-sign.py manifest --key <key> <manifest file>
        the two signatures a release carries, one per line: the base64
        Ed25519 (manifest.sig) and the base64 SSHSIG blob (manifest.sshsig)
    fleet-release-sign.py check --key <key> --dir <checkout> --sha S [--prev P] <manifest file>
        the train's look at what the hub built before it signs: the commit,
        its place on the chain, the signer, the key_chain / revoked the commit
        carries, and every file byte for byte against the checkout
    fleet-release-sign.py scan [--pin <release.pub>] [--manifest <manifest.json>] [<path>…]
        is a release signing PRIVATE key here (BREAK-IT release-key-outside-train)?
        Every small file under <path> (and this process's environment) is read
        for an ed25519 secret — a base64 seed, a PKCS#8 PEM — whose public half
        is the pin or a key the pin vouches for through <manifest>'s key_chain;
        and the variables that only ever hold one (CCQUOTA_FLEET_RELEASE_KEY,
        _PREV_KEY, FLEET_RELEASE_SIGN_KEY) set at all. One `FOUND <where> <what>`
        line each; exit 1 when any (never the secret itself)

<key> is a secret file (base64 32-byte seed — what keygen writes and ccquota's
LoadPrivateKey reads) or `env:NAME` (the train's secret, never on an argv or a
disk). Exit 0 · 1 refused / does not match (the reason on stderr) · 2 usage.

docs/dev/FLEET-HUB.md «发布签名» is the procedure: keygen the root offline, vouch
for the train's key, commit the chain, put the train's secret in the
release-sign environment, revoke by committing a new list (or handing it to
the hub's CCQUOTA_FLEET_RELEASE_REVOKED for the next fetch).
"""
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fleet_release_verify", os.path.join(HERE, "fleet-release-verify.py"))
V = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(V)

CHAIN_PATH = "conf/release-keys/chain.json"
REVOKED_PATH = "conf/release-keys/revoked.json"
ROOT_PATH = "conf/release-keys/root.pub"
SSHSIG_NS = "claude-fleet-release"


class Refused(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def seed_of(spec):
    if spec.startswith("env:"):
        v = os.environ.get(spec[4:], "").strip()
        if not v:
            raise Refused("%s is empty — no key" % spec[4:])
        raw = base64.b64decode(v, validate=True)
        if len(raw) != 32:
            raise Refused("%s: not a base64 32-byte ed25519 seed" % spec[4:])
        return raw
    with open(spec) as f:
        text = f.read()
    seeds = list(secrets_in(text))  # a base64 seed, or the hub's PKCS#8 PEM
    if len(seeds) != 1:
        raise Refused("%s: not one ed25519 secret key (a base64 seed or a PKCS#8 PEM)" % spec)
    return seeds[0]


def pub_of_arg(arg):
    if os.path.exists(arg):
        with open(arg) as f:
            arg = f.readline()
    return V.parse_key(arg.strip())


def _s(b):
    return len(b).to_bytes(4, "big") + b


def sshsig(seed, ns, msg):
    """OpenSSH's SSHSIG blob (PROTOCOL.sshsig, sha512) — ccquota's release.SSHSign"""
    pub = V.pub_of(seed)
    wire = _s(b"ssh-ed25519") + _s(pub)
    signed = b"SSHSIG" + _s(ns.encode()) + _s(b"") + _s(b"sha512") + _s(hashlib.sha512(msg).digest())
    sig = _s(b"ssh-ed25519") + _s(V.sign(seed, signed))
    return (b"SSHSIG" + (1).to_bytes(4, "big") + _s(wire) + _s(ns.encode()) + _s(b"")
            + _s(b"sha512") + _s(sig))


def load_json(path, default):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def write_json(path, v):
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(v, f, indent=1)
        f.write("\n")
    os.replace(tmp, path)


# ── verbs ────────────────────────────────────────────────────────────────────

def keygen(a):
    if len(a) != 1:
        raise SystemExit(2)
    if os.path.lexists(a[0]):
        raise Refused("%s exists — never overwrite a key" % a[0])
    seed = os.urandom(32)
    fd = os.open(a[0], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(base64.b64encode(seed).decode() + "\n")
    pub = V.pub_of(seed)
    print(V.key_line(pub))
    print("id", V.key_id(pub))


def pub(a):
    if len(a) != 1:
        raise SystemExit(2)
    print(V.key_line(V.pub_of(seed_of(a[0]))))


def opts(a, names, flags=()):
    o, rest, i = {}, [], 0
    while i < len(a):
        k = a[i]
        if k in names and i + 1 < len(a):
            o[k] = a[i + 1]
            i += 2
        elif k in flags:
            o[k] = True
            i += 1
        elif k.startswith("--"):
            raise Refused("unknown option %s" % k)
        else:
            rest.append(k)
            i += 1
    return o, rest


def cert(a):
    o, rest = opts(a, ("--by", "--key", "--role", "--note", "--add"))
    if rest or not o.get("--by") or not o.get("--key") or o.get("--role") not in ("sign", "root"):
        raise SystemExit(2)
    seed = seed_of(o["--by"])
    key = pub_of_arg(o["--key"])
    p = {"schema": 1, "kind": "release-key", "key": V.key_line(key), "role": o["--role"],
         "by": V.key_id(V.pub_of(seed)), "created": now()}
    if o.get("--note"):
        p["note"] = o["--note"]
    d = V.make_doc(seed, p)
    if o.get("--add"):
        chain = load_json(o["--add"], [])
        chain.append(d)
        write_json(o["--add"], chain)
        print("%s vouches for %s (%s) — %s now holds %d" % (p["by"], V.key_id(key), p["role"], o["--add"], len(chain)))
    else:
        print(json.dumps(d))


def revoke(a):
    o, rest = opts(a, ("--by", "--version", "--out"))
    if not rest or not o.get("--by") or not str(o.get("--version", "")).isdigit():
        raise SystemExit(2)
    for k in rest:
        if len(k) != 16 or any(c not in "0123456789abcdef" for c in k):
            raise Refused("%s: not a key id (16 hex — `show` lists them)" % k)
    seed = seed_of(o["--by"])
    old = load_json(o["--out"], None) if o.get("--out") else None
    if old is not None:
        got = V.doc_payload(old)
        if got and int(got[0].get("version") or 0) >= int(o["--version"]):
            raise Refused("the list there is version %s — raise --version" % got[0].get("version"))
        missing = set(got[0].get("keys") or []) - set(rest) if got else set()
        if missing:
            raise Refused("lists are cumulative: name %s again" % " ".join(sorted(missing)))
    d = V.make_doc(seed, {"schema": 1, "kind": "release-revoked", "version": int(o["--version"]),
                          "keys": sorted(set(rest)), "by": V.key_id(V.pub_of(seed)), "created": now()})
    if o.get("--out"):
        write_json(o["--out"], d)
        print("revoked %s — version %s in %s" % (" ".join(sorted(set(rest))), o["--version"], o["--out"]))
    else:
        print(json.dumps(d))


def show(a):
    o, rest = opts(a, ("--anchor",))
    anchor = pub_of_arg(o.get("--anchor") or ROOT_PATH)
    chain = load_json(rest[0] if rest else CHAIN_PATH, [])
    revd = load_json(rest[1] if len(rest) > 1 else REVOKED_PATH, None)
    t, rev, ver, repin = V.trust(anchor, chain, [revd] if revd else [])
    print("anchor  %s" % V.key_id(anchor))
    for kid, (_, role, by) in t.items():
        if kid != V.key_id(anchor):
            print("trusts  %s  %-4s  vouched by %s" % (kid, role, by))
    for d in chain:
        got = V.doc_payload(d)
        if got:
            try:
                kid = V.key_id(V.parse_key(got[0].get("key")))
            except ValueError:
                kid = "?"
            if kid not in t:
                print("ignored %s  (%s)" % (kid, "revoked" if kid in rev else "not vouched for by a trusted key"))
    print("revoked %s (list version %d)" % (" ".join(sorted(rev)) or "none", ver))
    if repin is not None:
        print("re-pin  a machine pinned to %s moves to the root %s" % (V.key_id(anchor), V.key_id(repin)))


def manifest(a):
    o, rest = opts(a, ("--key",))
    if len(rest) != 1 or not o.get("--key"):
        raise SystemExit(2)
    seed = seed_of(o["--key"])
    with open(rest[0], "rb") as f:
        mb = f.read()
    m = json.loads(mb)
    if m.get("key") != V.key_id(V.pub_of(seed)):
        raise Refused("the manifest names signer %s, this key is %s" % (m.get("key"), V.key_id(V.pub_of(seed))))
    print(base64.b64encode(V.sign(seed, mb)).decode())
    print(base64.b64encode(sshsig(seed, SSHSIG_NS, mb)).decode())


def git_blobs(d, sha, paths):
    """{path: bytes} for every path at <sha> (missing → absent)"""
    p = subprocess.run(["git", "-C", d, "cat-file", "--batch"], input="".join("%s:%s\n" % (sha, x) for x in paths).encode(),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    out, i, got = p.stdout, 0, {}
    for x in paths:
        nl = out.index(b"\n", i)
        head = out[i:nl].split()
        i = nl + 1
        if len(head) == 2 and head[1] == b"missing":
            continue
        n = int(head[2])
        if head[1] == b"blob":
            got[x] = out[i:i + n]
        i += n + 1
    return got


def check(a):
    o, rest = opts(a, ("--key", "--dir", "--sha", "--prev"))
    if len(rest) != 1 or not o.get("--key") or not o.get("--sha"):
        raise SystemExit(2)
    d = o.get("--dir") or "."
    key = V.pub_of(seed_of(o["--key"]))
    with open(rest[0], "rb") as f:
        m = json.loads(f.read())
    sha = o["--sha"]
    bad = []
    if m.get("schema") != 1:
        bad.append("schema %r" % m.get("schema"))
    if m.get("sha") != sha:
        bad.append("the hub built %s, not %s" % (m.get("sha"), sha))
    if "--prev" in o and (m.get("prev") or "") != o["--prev"]:
        bad.append("prev %s, the train published from %s" % (m.get("prev") or "none", o["--prev"] or "none"))
    if not isinstance(m.get("seq"), int) or m["seq"] < 1:
        bad.append("no seq")
    if m.get("key") != V.key_id(key):
        bad.append("signer %s, the train's key is %s" % (m.get("key"), V.key_id(key)))
    have = git_blobs(d, sha, [CHAIN_PATH, REVOKED_PATH])
    want_chain = json.loads(have[CHAIN_PATH]) if CHAIN_PATH in have else []
    if (m.get("key_chain") or []) != want_chain:
        bad.append("key_chain is not the commit's %s" % CHAIN_PATH)
    want_rev = json.loads(have[REVOKED_PATH]) if REVOKED_PATH in have else None
    if m.get("revoked") != want_rev:
        bad.append("revoked is not the commit's %s" % REVOKED_PATH)
    files = m.get("files") or []
    blobs = git_blobs(d, sha, [str(f.get("path")) for f in files])
    for f in files:
        b = blobs.get(str(f.get("path")))
        if b is None:
            bad.append("%s: not in %s" % (f.get("path"), sha[:7]))
            continue
        mode = 0o755 if str(f["path"]).startswith("bin/") or b.startswith(b"#!") else 0o644
        if hashlib.sha256(b).hexdigest() != f.get("sha256") or len(b) != f.get("size") or f.get("mode") != mode:
            bad.append("%s: not the commit's bytes" % f["path"])
    if not files:
        bad.append("no files")
    if bad:
        raise Refused("the hub's release of %s is not what the train checked out: %s%s"
                      % (sha[:7], "; ".join(bad[:8]), " …" if len(bad) > 8 else ""))
    print("checked %s seq %s: %d files = the commit's, signer %s, key_chain %d, revoked %s"
          % (sha[:7], m.get("seq"), len(files), V.key_id(key), len(want_chain), "yes" if want_rev else "none"))


SIGN_ENV = ("CCQUOTA_FLEET_RELEASE_KEY", "CCQUOTA_FLEET_RELEASE_PREV_KEY", "FLEET_RELEASE_SIGN_KEY")
B64_SEED = re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])")
PEM = re.compile(r"-----BEGIN PRIVATE KEY-----\s*([A-Za-z0-9+/=\s]+?)-----END PRIVATE KEY-----")
PKCS8_ED25519 = bytes.fromhex("302e020100300506032b657004220420")


def secrets_in(text):
    """every 32-byte ed25519 seed a text may hold"""
    for m in PEM.finditer(text):
        try:
            der = base64.b64decode(re.sub(r"\s+", "", m.group(1)))
        except ValueError:
            continue
        if len(der) == 48 and der[:16] == PKCS8_ED25519:
            yield der[16:]
    for m in B64_SEED.finditer(text):
        try:
            raw = base64.b64decode(m.group(0), validate=True)
        except ValueError:
            continue
        if len(raw) == 32:
            yield raw


def scan(a):
    o, rest = opts(a, ("--pin", "--manifest"))
    chain = []
    if o.get("--manifest") and os.path.exists(o["--manifest"]):
        chain = (load_json(o["--manifest"], {}) or {}).get("key_chain") or []
    # no pin yet: only the variables that hold nothing but a signing key
    anchor = pub_of_arg(o["--pin"]) if o.get("--pin") else None
    trusted = V.trust(anchor, chain, [])[0] if anchor else {}
    found = []

    def look(where, text):
        for seed in secrets_in(text):
            kid = V.key_id(V.pub_of(seed))
            if kid in trusted:
                found.append("FOUND %s the private half of %s (%s)" % (where, kid, trusted[kid][1]))

    for n in SIGN_ENV:
        if os.environ.get(n, "").strip():
            found.append("FOUND env %s is set (a release signing key's variable)" % n)
    for n, v in sorted(os.environ.items()):
        if n not in SIGN_ENV and len(v) < 8192:
            look("env " + n, v)
    for root in rest:
        for d, dirs, names in os.walk(root):
            dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "fleet.versions", "logs")]
            if d[len(root):].count(os.sep) > 4:
                dirs[:] = []
            for n in names:
                p = os.path.join(d, n)
                try:
                    if os.path.islink(p) or os.path.getsize(p) > 16384:
                        continue
                    with open(p, "rb") as f:
                        text = f.read().decode("utf-8", "replace")
                except OSError:
                    continue
                look(p, text)
    for line in found:
        print(line)
    if found:
        raise Refused("%d release signing private key(s) outside the release train" % len(found))
    print("none: no release signing private key here (pin %s, %d key(s) it vouches for)"
          % (V.key_id(anchor) if anchor else "none yet", len(trusted)))


VERBS = {"keygen": keygen, "pub": pub, "cert": cert, "revoke": revoke, "show": show,
         "manifest": manifest, "check": check, "scan": scan}


def main(argv):
    if not argv or argv[0] not in VERBS:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 2
    try:
        VERBS[argv[0]](argv[1:])
    except SystemExit as e:
        if e.code == 2:
            sys.stderr.write("fleet-release-sign: usage — see %s --help\n" % os.path.basename(sys.argv[0]))
        return int(e.code or 0)
    except (Refused, ValueError, OSError, KeyError, subprocess.CalledProcessError) as e:
        sys.stderr.write("fleet-release-sign: %s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__)
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
