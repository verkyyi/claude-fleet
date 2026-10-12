#!/usr/bin/env python3
"""fleet_node_codesign.py — the machine's ONE fixed code-signing identity
(issue #3433, EPIC #2482).

macOS privacy protection (TCC) remembers a grant against the client's SIGNING
identity — for a binary that is not an Apple one, its designated requirement
(`identifier "…" and certificate leaf = H"…"`), checked again at every access.
The ccquota a release ships is ad-hoc signed by the Go linker: its requirement is
its own cdhash, a new one on every build. So every version switch made the admin
agent (ccquota, the responsible process of every account script) a stranger to
tccd: the Full Disk Access a person had granted by hand stopped applying, and
creating or removing a login met a dialog nobody answered, an eDSPermissionError,
or a hang (#3034, #3167, #3405, #3419, the FDA story in #2996).

This makes ONE identity per machine and never another: a self-signed
code-signing certificate (CN «claude-fleet node <host>», 100 years) whose private
key is generated ON the machine into a keychain only root reads, under
<state>/codesign/ (0700):

  identity.keychain-db   the certificate + private key (the key never leaves it)
  keychain.pass          the keychain's random password (0600; root's, like the
                         node token in machine.env — never a config, a commit, an
                         issue or a comment)
  cert.pem               the certificate (public)
  identity.json          {"sha1", "cn", "identifier", "created"}

Every ccquota the updater stages is re-signed with it under the identifier
com.claude-fleet.ccquota, and the stage is refused unless the result satisfies
the requirement — so the requirement a grant recorded once holds for every
release after. The certificate needs no trust setting (TCC matches the leaf's
hash, not a chain), so nothing asks a person anything. An identity that exists
is never regenerated: a broken keychain is an error to look at, not a reason to
mint a new identity and silently drop every grant. Delete the directory to start
over (and grant again).

Off — not macOS, no /usr/bin/codesign · security · openssl, or
FLEET_NODE_CODESIGN=0 — nothing is made or signed, byte for byte as before.

Usage (root, on the machine):
  fleet_node_codesign.py status [--json]     the identity and its requirement, or why none
  fleet_node_codesign.py ensure              make the identity if there is none
  fleet_node_codesign.py sign <file>         sign a copy in place (atomic) and check it
  fleet_node_codesign.py check <file>        exit 0 ⇔ <file> satisfies the requirement
"""
from __future__ import print_function

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

IDENTIFIER = "com.claude-fleet.ccquota"
CODESIGN = "/usr/bin/codesign"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
DIRNAME = "codesign"
KEYCHAIN = "identity.keychain-db"


class CodesignError(Exception):
    pass


def enabled():
    """Signing applies on this machine (macOS with the three tools, not turned off)."""
    if os.environ.get("FLEET_NODE_CODESIGN", "1") == "0":
        return False
    if os.environ.get("FLEET_NODE_CODESIGN_FORCE") != "1" and sys.platform != "darwin":
        return False
    return all(os.access(t, os.X_OK) for t in (tool("codesign"), tool("security"), tool("openssl")))


def tool(name):
    """A tool's path; FLEET_NODE_CODESIGN_<NAME> is the sandbox seam."""
    return os.environ.get("FLEET_NODE_CODESIGN_" + name.upper(), {"codesign": CODESIGN, "security": SECURITY,
                                                                  "openssl": OPENSSL}[name])


def _run(argv, timeout=120, **kw):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           timeout=timeout, **kw)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "%s: timed out after %ds" % (os.path.basename(argv[0]), timeout)
    except OSError as e:
        return 127, "", str(e)


def _sec(args, timeout=120):
    """One `security` command fed through `security -i` on stdin, so the keychain
    password is never an argv another login's `ps` can read."""
    line = " ".join('"%s"' % a.replace("\\", "\\\\").replace('"', '\\"') for a in args)
    return _run([tool("security"), "-i"], timeout=timeout, input=line + "\n")


def _last(out, err, rc):
    return ((err or out).strip().splitlines() or ["rc %d" % rc])[-1][:200]


class Identity(object):
    def __init__(self, state):
        self.dir = os.path.join(state, DIRNAME)
        self.keychain = os.path.join(self.dir, KEYCHAIN)
        self.passfile = os.path.join(self.dir, "keychain.pass")
        self.cert = os.path.join(self.dir, "cert.pem")
        self.meta = os.path.join(self.dir, "identity.json")

    def info(self):
        """identity.json, or None when there is no whole identity."""
        try:
            with open(self.meta) as f:
                m = json.load(f)
        except (OSError, ValueError):
            return None
        if not isinstance(m, dict) or len(str(m.get("sha1") or "")) != 40:
            return None
        if not (os.path.exists(self.keychain) and os.path.exists(self.passfile)):
            return None
        return m

    def requirement(self, info=None):
        info = info or self.info()
        if not info:
            return None
        return 'identifier "%s" and certificate leaf = H"%s"' % (info.get("identifier") or IDENTIFIER,
                                                                  info["sha1"].lower())

    def password(self):
        with open(self.passfile) as f:
            return f.read().strip()

    def ensure(self):
        """The identity, made once. -> info dict; CodesignError when it cannot be."""
        info = self.info()
        if info:
            return info
        if os.path.exists(self.meta) or os.path.exists(self.keychain):
            # half there: never mint a second identity over a first one's remains
            raise CodesignError("%s is incomplete (identity.json · %s · keychain.pass) — look at it, or remove "
                                "the directory to make a NEW identity (every TCC grant then has to be given again)"
                                % (self.dir, KEYCHAIN))
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        os.chmod(self.dir, 0o700)
        work = tempfile.mkdtemp(prefix=".make-", dir=self.dir)
        try:
            return self._make(work)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def _make(self, work):
        host = socket.gethostname().split(".")[0] or "mac"
        cn = ("claude-fleet node %s" % host)[:64]   # X.509 caps a CN at 64 (a CI runner's hostname is longer)
        cnf = os.path.join(work, "req.cnf")
        with open(cnf, "w") as f:
            f.write("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n"
                    "[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                    "extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n" % cn)
        key, cert, p12 = (os.path.join(work, n) for n in ("key.pem", "cert.pem", "id.p12"))
        old = os.umask(0o077)
        try:
            rc, out, err = _run([tool("openssl"), "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                                 "-out", cert, "-days", "36500", "-config", cnf])
            if rc != 0:
                raise CodesignError("openssl req: %s" % _last(out, err, rc))
            rc, pw, err = _run([tool("openssl"), "rand", "-hex", "24"])
            pw = pw.strip()
            if rc != 0 or len(pw) < 32:
                raise CodesignError("openssl rand: %s" % _last("", err, rc))
            # the passphrase on stdin's file descriptor, never an argv another login's ps can read
            rc, out, err = _run([tool("openssl"), "pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12,
                                 "-name", cn, "-passout", "stdin"], input=pw + "\n")
            if rc != 0:
                raise CodesignError("openssl pkcs12: %s" % _last(out, err, rc))
            os.remove(key)
            with open(self.passfile + ".tmp", "w") as f:
                f.write(pw + "\n")
            os.chmod(self.passfile + ".tmp", 0o600)
            os.rename(self.passfile + ".tmp", self.passfile)
        finally:
            os.umask(old)
        kc = self.keychain
        before = self._search_list()
        steps = [
            ["create-keychain", "-p", pw, kc],
            ["set-keychain-settings", kc],   # no auto-lock
            ["unlock-keychain", "-p", pw, kc],
            ["import", p12, "-k", kc, "-P", pw, "-T", tool("codesign")],
            ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", pw, kc],
        ]
        try:
            for argv in steps:
                what = argv[0]
                rc, out, err = _sec(argv)
                if rc != 0:
                    raise CodesignError("security %s: %s" % (what, _last(out, err, rc)))
        except CodesignError:
            for p in (kc, self.passfile):
                try:
                    os.remove(p)
                except OSError:
                    pass
            raise
        finally:
            self._restore_search_list(before)
        rc, der, err = _run([tool("openssl"), "x509", "-in", cert, "-noout", "-fingerprint", "-sha1"])
        sha1 = der.strip().split("=")[-1].replace(":", "").lower() if rc == 0 else ""
        if len(sha1) != 40:
            raise CodesignError("openssl x509 -fingerprint: %s" % _last(der, err, rc))
        shutil.copyfile(cert, self.cert)
        os.chmod(self.cert, 0o644)
        info = {"sha1": sha1, "cn": cn, "identifier": IDENTIFIER, "created": int(time.time())}
        with open(self.meta + ".tmp", "w") as f:
            json.dump(info, f, indent=1)
        os.chmod(self.meta + ".tmp", 0o644)
        os.rename(self.meta + ".tmp", self.meta)
        return info

    def _search_list(self):
        rc, out, _ = _run([tool("security"), "list-keychains", "-d", "user"], timeout=30)
        return [l.strip().strip('"') for l in out.splitlines() if l.strip()] if rc == 0 else None

    def _restore_search_list(self, before):
        """create-keychain adds the new keychain to the caller's search list; the
        identity is always named by path, so put the list back as it was."""
        if before is None:
            return
        now_ = self._search_list()
        if now_ is not None and now_ != before:
            _run([tool("security"), "list-keychains", "-d", "user", "-s"] + before, timeout=30)

    def satisfies(self, path, info=None):
        """(ok, why): does <path> carry a valid signature meeting the requirement?"""
        req = self.requirement(info)
        if not req:
            return False, "no identity"
        rc, out, err = _run([tool("codesign"), "--verify", "--strict", "-R=" + req, path], timeout=60)
        return rc == 0, "" if rc == 0 else _last(out, err, rc)

    def sign(self, path, info=None):
        """Sign <path> with the identity — a copy beside it, signed, checked, then
        renamed over (a running process keeps its old inode). CodesignError when
        the result does not satisfy the requirement."""
        info = info or self.ensure()
        rc, out, err = _sec(["unlock-keychain", "-p", self.password(), self.keychain], timeout=30)
        if rc != 0:
            raise CodesignError("security unlock-keychain: %s" % _last(out, err, rc))
        tmp = "%s.sign-%d" % (path, os.getpid())
        shutil.copy2(path, tmp)
        try:
            rc, out, err = _run([tool("codesign"), "--force", "--sign", info["sha1"], "--keychain", self.keychain,
                                 "--identifier", info.get("identifier") or IDENTIFIER, "--timestamp=none", tmp])
            if rc != 0:
                raise CodesignError("codesign: %s" % _last(out, err, rc))
            ok, why = self.satisfies(tmp, info)
            if not ok:
                raise CodesignError("signed, but it does not satisfy %s: %s" % (self.requirement(info), why))
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            os.rename(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
        return info

    def designated(self, path):
        """The designated requirement <path> carries (what TCC records), or ''."""
        rc, out, err = _run([tool("codesign"), "-d", "-r-", path], timeout=60)
        for line in (out + "\n" + err).splitlines():
            if line.startswith("designated => "):
                return line[len("designated => "):].strip()
        return ""


def state_dir():
    return os.environ.get("FLEET_NODE_STATE", "/var/db/fleet-node")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    rest = argv[2:]
    ident = Identity(state_dir())
    if cmd == "status":
        info = ident.info()
        out = {"enabled": enabled(), "dir": ident.dir, "identity": info,
               "requirement": ident.requirement(info) if info else None}
        if "--json" in rest:
            print(json.dumps(out, indent=1))
        elif not out["enabled"]:
            print("codesign: off (not macOS, a tool missing, or FLEET_NODE_CODESIGN=0)")
        elif not info:
            print("codesign: no identity yet under %s — the updater's next tick makes it" % ident.dir)
        else:
            print("codesign: %s · sha1 %s\nrequirement: %s" % (info.get("cn"), info["sha1"], out["requirement"]))
        return 0
    if not enabled():
        sys.stderr.write("fleet_node_codesign: off on this machine\n")
        return 2
    try:
        if cmd == "ensure":
            info = ident.ensure()
            print("%s · sha1 %s" % (info.get("cn"), info["sha1"]))
            return 0
        if cmd == "sign" and rest:
            ident.sign(rest[0])
            print("signed %s · %s" % (rest[0], ident.requirement()))
            return 0
        if cmd == "check" and rest:
            ok, why = ident.satisfies(rest[0])
            print("ok" if ok else why)
            return 0 if ok else 1
    except CodesignError as e:
        sys.stderr.write("fleet_node_codesign: %s\n" % e)
        return 1
    sys.stderr.write(__doc__.split("Usage")[1] if "Usage" in __doc__ else "usage\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
