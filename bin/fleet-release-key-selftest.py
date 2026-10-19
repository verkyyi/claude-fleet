#!/usr/bin/env python3
"""Isolated status drill: real signed chains, curl fixture, no live pins/network."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(os.path.abspath(__file__)).parent
spec = importlib.util.spec_from_file_location("verify", BIN / "fleet-release-verify.py")
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)
SEEDS = {k: hashlib.sha256(("status-fixture-" + k).encode()).digest()
         for k in ("old", "root", "stranger")}
KEYS = {k: V.pub_of(seed) for k, seed in SEEDS.items()}


def cert(role="root"):
    return V.make_doc(SEEDS["old"], {"schema": 1, "kind": "release-key",
        "by": V.key_id(KEYS["old"]), "key": V.key_line(KEYS["root"]), "role": role})


class Status(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="release-key-status-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for p in ("home/.claude/fleet", "conf", "node", "runtime", "shim"):
            (self.root / p).mkdir(parents=True)
        self.pin = self.root / "conf/release.pub"
        self.pin.write_text(V.key_line(KEYS["old"]) + "\n")
        (self.root / "key").write_text(V.key_line(KEYS["root"]) + "\n")
        self.manifest = {"key_chain": [cert()]}
        curl = self.root / "shim/curl"
        curl.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
p = pathlib.Path(os.environ["STATUS_FIXTURE"])
a = sys.argv[1:]
route = a[-1].rsplit("/", 1)[-1]
if route not in ("key", "stable"):
    sys.exit(2)
with (p / "requests").open("a") as f:
    f.write(route + "\\n")
code = "503" if route == "stable" and (p / "unavailable").exists() else "200"
pathlib.Path(a[a.index("-o") + 1]).write_bytes((p / route).read_bytes() if code == "200" else b"")
if "-D" in a:
    print("X-Ccquota-Release-Signer: train\\r")
if "-w" in a:
    print(code, end="")
''')
        curl.chmod(0o755)
        self.env = {"PATH": str(self.root / "shim") + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root / "home"), "TMPDIR": str(self.root),
            "FLEET_CONF_DIR": str(self.root / "conf"),
            "FLEET_NODE_STATE": str(self.root / "node"),
            "FLEET_NODE_ROOT": str(self.root / "runtime"),
            "FLEET_INSTALL_LOGIN": "fixture", "FLEET_HUB_URL": "http://fixture.invalid",
            "STATUS_FIXTURE": str(self.root), "PYTHONDONTWRITEBYTECODE": "1"}

    def status(self, code, words):
        stable = self.root / "stable"
        if not stable.exists():
            stable.write_text(json.dumps(self.manifest))
        def pins():
            return {str(p): p.read_bytes() for d in ("conf", "node")
                    for p in (self.root / d).rglob("*") if p.is_file()}
        before = pins()
        got = subprocess.run(["bash", str(BIN / "fleet-release-key.sh"), "status"],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=15)
        print("%s: exit %d\n%s" % (self._testMethodName, got.returncode, got.stdout), flush=True)
        self.assertEqual(before, pins(), "status changed a pin or revocation record")
        self.assertEqual(code, got.returncode)
        self.assertIn(words, got.stdout)
        return got.stdout

    def test_endorsed_root(self):
        self.status(0, "担保链认可 · 下次取版本自动重钉到根")

    def test_same_key(self):
        self.pin.write_text((self.root / "key").read_text())
        self.status(0, "= 入口现在用的")
        self.assertNotIn("stable", (self.root / "requests").read_text())

    def test_unknown_key(self):
        self.manifest["key_chain"] = []
        self.status(1, "≠")

    def test_chain_endorses_a_different_root(self):
        (self.root / "key").write_text(V.key_line(KEYS["stranger"]) + "\n")
        self.status(1, "≠")

    def test_unpinned_login(self):
        self.pin.unlink()
        self.status(0, "还没记下入口的钥匙")

    def test_forged_chain(self):
        self.manifest["key_chain"][0]["sig"] = cert()["sig"][::-1]
        self.status(1, "≠")

    def test_signer_is_not_a_root(self):
        self.manifest["key_chain"] = [cert("sign")]
        self.status(1, "≠")

    def test_revoked_root(self):
        self.manifest["revoked"] = V.make_doc(SEEDS["old"], {
            "schema": 1, "kind": "release-revoked", "by": V.key_id(KEYS["old"]),
            "keys": [V.key_id(KEYS["root"])], "version": 1})
        self.status(1, "≠")

    def test_remembered_revocation(self):
        self.pin.with_suffix(".pub.revoked").write_text(json.dumps({
            "keys": [V.key_id(KEYS["root"])], "version": 1}))
        self.status(1, "≠")

    def test_unavailable_manifest(self):
        (self.root / "unavailable").touch()
        out = self.status(1, "暂时无法核对担保链")
        self.assertNotIn("≠", out)

    def test_malformed_manifest(self):
        (self.root / "stable").write_text("[]")
        out = self.status(1, "无法核对 stable 清单的担保链")
        self.assertNotIn("≠", out)

    def managed(self, linked=False):
        self.pin.write_text(V.key_line(KEYS["stranger"]) + "\n")
        if linked:     # ~/.claude/fleet → <runtime>/current (issue #4669)
            (self.root / "home/.claude/fleet").rmdir()
            (self.root / "home/.claude/fleet").symlink_to(self.root / "runtime" / "current")
        else:
            (self.root / "node/accounts.json").write_text('{"fixture":{"managed":true}}')
        (self.root / "node/release.pub").write_text((self.root / "key").read_text())

    def test_managed_pin(self):
        self.managed()
        out = self.status(0, "以机器级")
        self.assertIn(str(self.root / "node/release.pub"), out)
        self.assertIn("登录级 pin 不起作用", out)

    def test_linked_login(self):
        self.managed(linked=True)
        self.status(0, "以机器级")

    def test_managed_endorsed_root(self):
        self.managed()
        (self.root / "node/release.pub").write_text(V.key_line(KEYS["old"]) + "\n")
        self.status(0, "担保链认可")

    def test_managed_unknown_root(self):
        self.managed()
        (self.root / "node/release.pub").write_text(V.key_line(KEYS["stranger"]) + "\n")
        self.status(1, "≠")

    def test_managed_missing_pin(self):
        self.managed()
        (self.root / "node/release.pub").unlink()
        self.status(1, "机器级钥匙不可读")


if __name__ == "__main__":
    unittest.main()
