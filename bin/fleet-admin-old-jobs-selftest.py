#!/usr/bin/env python3
"""fleet-admin-old-jobs-selftest.py — the sweep's two steps for issue #4363 (EPIC
#4354 C10), on a sandbox state / LaunchDaemons / passwd / runtime and a fake
launchctl (nothing reaches a real launchd domain — FLEET_NODE_LAUNCHCTL):

  A  the admin's com.claude-fleet.<admin>.dispatch (no template in the release)
     and .install-sync (its ~/.claude/fleet linked into this root) are booted out
     into the attic, one log line before and one after each; its old node agent
     (com.ccquota.agent.<admin>) stays — the seat's handover (#3725) is its road
  B  install-sync of an admin whose install is its own copy stays, named; a unit
     the release still ships stays, unnamed; an empty runtime launchd/ retires nothing
  C  a tenant's (non-admin) units and a gone login's are not this road's; no old
     unit at all ⇒ nothing done (no launchctl, no attic)
  D  --dry-run moves nothing; `attic restore` puts a retired unit back
  E  a managed login still on its own credential proxy is joined (machine join),
     a shared one is not; a failed join is named, nothing else moved;
     FLEET_NODE_CREDSEP_JOIN=0 asks nothing
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
SUP = os.path.join(BIN, "fleet-node-supervisor.py")


class OldJobs(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="faoj.")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_NODE_", "FLEET_ADMIN_", "FLEET_CREDSEP_"))}
        self.dd = os.path.join(self.d, "LaunchDaemons")
        self.st = os.path.join(self.d, "db")
        self.root = os.path.join(self.d, "root")
        self.rt = os.path.join(self.root, "current")
        os.makedirs(self.dd)
        os.makedirs(os.path.join(self.rt, "launchd"))
        for u in ("install-sync", "diskguard"):
            open(os.path.join(self.rt, "launchd", "com.claude-fleet.%s.plist.tmpl" % u), "w").close()
        self.users = os.path.join(self.d, "Users")
        pw = {}
        for who in ("bob", "carol"):
            os.makedirs(os.path.join(self.users, who))
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": os.path.join(self.users, who)}
        pw["bob"].update(groups=["staff", "admin"])          # the machine's admin
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump(pw, f)
        self.lclog = os.path.join(self.d, "lc.log")
        lc = self.script("launchctl", 'echo "$*" >> %s\n[ "$1" = print ] && exit 113\nexit 0\n' % self.lclog)
        # the credential store's two answers: `machine managed --json` from state.json,
        # `machine join` logged, its rc from join.rc
        self.cslog = os.path.join(self.d, "cs.log")
        self.csstate = os.path.join(self.d, "cs-state.json")
        self.csrc = os.path.join(self.d, "join.rc")
        self.cs = os.path.join(self.d, "fleet-credsep.py")
        with open(self.cs, "w") as f:
            f.write("import json, sys\n"
                    "open(%r, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                    "if sys.argv[1:3] == ['machine', 'managed']:\n"
                    "    print(json.dumps({'managed': [], 'state': json.load(open(%r))}))\n"
                    "    sys.exit(0)\n"
                    "rc = int(open(%r).read().strip() or 0)\n"
                    "print('join: %%s — on the shared proxy' %% sys.argv[-1] if rc == 0 else 'join: FAILED')\n"
                    "sys.exit(rc)\n" % (self.cslog, self.csstate, self.csrc))
        self.cstate({})
        with open(self.csrc, "w") as f:
            f.write("0\n")
        self.env.update({
            "FLEET_NODE_STATE": self.st, "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_ROOT": self.root, "FLEET_NODE_RUNTIME": self.rt, "FLEET_NODE_DAEMON_DIR": self.dd,
            "FLEET_NODE_USERS": self.users, "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_PASSWD": os.path.join(self.d, "passwd.json"), "FLEET_NODE_TEST": "1",
            "FLEET_NODE_LAUNCHCTL": lc, "FLEET_NODE_BOOTOUT_WAIT": "0.3",
            "FLEET_NODE_CREDSEP_PY": self.cs, "FLEET_NODE_SWEEP_HOLD": "no-such-drill.sh",
            "FLEET_CREDSEP_ROOT_BASE": os.path.join(self.d, "cred"),
        })
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump({"children": [], "tasks": []}, f)

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def script(self, name, body):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write("#!/bin/bash\n" + body)
        os.chmod(p, 0o755)
        return p

    def cstate(self, st):
        with open(self.csstate, "w") as f:
            json.dump(st, f)

    def unit(self, label, user=None):
        p = os.path.join(self.dd, label + ".plist")
        pl = {"Label": label, "ProgramArguments": ["/bin/sh", "-c", "true"]}
        if user:
            pl["UserName"] = user
        with open(p, "wb") as f:
            plistlib.dump(pl, f)
        return p

    def link_install(self, login, root=None):
        """<home>/.claude/fleet → a version tree whose .fleet-linked names <root>."""
        home = os.path.join(self.users, login)
        tree = os.path.join(home, ".claude", "fleet.versions", "a" * 40)
        os.makedirs(tree)
        with open(os.path.join(tree, ".fleet-linked"), "w") as f:
            json.dump({"sha": "a" * 40, "root": root or self.root, "at": 1}, f)
        os.symlink(tree, os.path.join(home, ".claude", "fleet"))

    def sweep(self, *args, **kw):
        e = dict(self.env, **kw.pop("env", {}))
        r = subprocess.run([sys.executable, SUP, "sweep"] + list(args), env=e, capture_output=True, text=True,
                           timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def attic(self):
        try:
            return json.load(open(os.path.join(self.st, "attic", "index.json")))
        except (OSError, ValueError):
            return []

    def lc(self):
        try:
            return open(self.lclog).read()
        except OSError:
            return ""

    def cs_calls(self):
        try:
            return open(self.cslog).read().splitlines()
        except OSError:
            return []

    # -- A
    def test_a_dispatch_and_linked_install_sync_retired(self):
        disp = self.unit("com.claude-fleet.bob.dispatch", "bob")
        isync = self.unit("com.claude-fleet.bob.install-sync", "bob")
        agent = self.unit("com.ccquota.agent.bob")
        self.link_install("bob")
        r = self.sweep()
        self.assertFalse(os.path.exists(disp), r.stdout + r.stderr)
        self.assertFalse(os.path.exists(isync), r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(agent), "the old admin agent is the seat handover's (#3725), not this road's")
        log = self.lc()
        self.assertIn("bootout system/com.claude-fleet.bob.dispatch", log)
        self.assertIn("bootout system/com.claude-fleet.bob.install-sync", log)
        self.assertNotIn("com.ccquota.agent.bob", log.replace("print system/com.ccquota.agent.bob", ""))
        a = dict((e["label"], e) for e in self.attic())
        self.assertEqual(set(a), {"com.claude-fleet.bob.dispatch", "com.claude-fleet.bob.install-sync"})
        for e in a.values():
            self.assertTrue(os.path.isfile(e["dst"]))
        for lb in ("com.claude-fleet.bob.dispatch", "com.claude-fleet.bob.install-sync"):
            self.assertIn("admin old job %s (bob): retiring" % lb, r.stderr)
            self.assertIn("admin old job %s (bob): booted out → attic" % lb, r.stderr)
            self.assertIn("booted out admin old job %s" % lb, r.stdout)
        self.assertIn("ships no unit dispatch", r.stdout)
        self.assertIn("linked into", r.stdout)
        # a second sweep has nothing left
        r = self.sweep()
        self.assertNotIn("admin old job", r.stdout + r.stderr)
        self.assertEqual(len(self.attic()), 2)

    # -- B
    def test_b_own_copy_and_shipped_units_stay(self):
        isync = self.unit("com.claude-fleet.bob.install-sync", "bob")
        dg = self.unit("com.claude-fleet.bob.diskguard", "bob")
        r = self.sweep()
        self.assertTrue(os.path.isfile(isync), "an own copy's install-sync is what updates it")
        self.assertIn("admin old job com.claude-fleet.bob.install-sync left in place", r.stdout)
        self.assertIn("own copy", r.stdout)
        self.assertTrue(os.path.isfile(dg))
        self.assertNotIn("diskguard", r.stdout + r.stderr)
        # linked into ANOTHER root is not this machine's to move
        self.link_install("bob", root=os.path.join(self.d, "elsewhere"))
        self.sweep()
        self.assertTrue(os.path.isfile(isync))
        # a runtime with no launchd templates says nothing about what is shipped
        disp = self.unit("com.claude-fleet.bob.dispatch", "bob")
        shutil.rmtree(os.path.join(self.rt, "launchd"))
        r = self.sweep()
        self.assertTrue(os.path.isfile(disp), r.stdout + r.stderr)
        self.assertEqual(self.attic(), [])
        self.assertNotIn("bootout", self.lc())

    # -- C
    def test_c_not_an_admins_and_nothing_old(self):
        r = self.sweep()
        self.assertEqual(self.attic(), [])
        self.assertEqual(self.lc(), "")
        self.assertNotIn("admin old job", r.stdout + r.stderr)
        tenant = self.unit("com.claude-fleet.carol.dispatch", "carol")
        gone = self.unit("com.claude-fleet.zed.dispatch", "zed")
        shared = self.unit("com.claude-fleet.credsep.carol")
        r = self.sweep()
        for p in (tenant, gone, shared):
            self.assertTrue(os.path.isfile(p), "%s is not the admin's old job" % p)
        self.assertNotIn("admin old job", r.stdout + r.stderr)
        self.assertNotIn("bootout", self.lc())

    # -- D
    def test_d_dry_run_and_restore(self):
        disp = self.unit("com.claude-fleet.bob.dispatch", "bob")
        r = self.sweep("--dry-run")
        self.assertIn("would boot out admin old job com.claude-fleet.bob.dispatch", r.stdout)
        self.assertIn("would retire", r.stderr)
        self.assertTrue(os.path.isfile(disp))
        self.assertEqual(self.attic(), [])
        self.assertNotIn("bootout", self.lc())
        self.sweep()
        self.assertFalse(os.path.exists(disp))
        e = self.attic()[0]
        r = subprocess.run([sys.executable, SUP, "attic", "restore", e["id"]], env=self.env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(disp))

    # -- E
    def test_e_own_credential_proxy_joined(self):
        self.cstate({"carol": "own", "dave": "shared"})
        r = self.sweep()
        calls = self.cs_calls()
        self.assertIn("machine managed --json", calls)
        self.assertIn("machine join --logins carol", calls)
        self.assertFalse([c for c in calls if "dave" in c], "a login already on the shared proxy is left alone")
        self.assertIn("credsep carol: on its own proxy — joining", r.stderr)
        self.assertIn("credsep carol: joined", r.stderr)
        self.assertIn("joined carol to the shared credential proxy", r.stdout)
        # a dry run passes --dry-run
        os.unlink(self.cslog)
        r = self.sweep("--dry-run")
        self.assertIn("machine join --logins carol --dry-run", self.cs_calls())
        # a failed join is named
        with open(self.csrc, "w") as f:
            f.write("1\n")
        r = self.sweep()
        self.assertIn("credsep carol stays on its own proxy: rc 1", r.stdout)
        self.assertEqual(self.attic(), [])
        # nobody on an own proxy ⇒ no join asked; the switch off ⇒ nothing asked
        self.cstate({"carol": "shared"})
        os.unlink(self.cslog)
        self.sweep()
        self.assertEqual(self.cs_calls(), ["machine managed --json"])
        os.unlink(self.cslog)
        self.cstate({"carol": "own"})
        self.sweep(env={"FLEET_NODE_CREDSEP_JOIN": "0"})
        self.assertEqual(self.cs_calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
