#!/usr/bin/env python3
"""fleet-node-update-selftest.py — the machine's one updater in a sandbox (issue #2334).

Driven by bin/fleet-node-update-selftest.sh. Every path goes through the
FLEET_NODE_* seams; a fake ccquota "fetches" a release from a fixture directory
the way `ccquota release fetch --artifacts` lays one out (C7). Nothing touches
/Library, /var or a real login.

  A  a fresh machine: every part lands on the release (runtime, ccquota, claude,
     codex, tmux, the bootstrap cache, a managed account's links, the daemon) and
     `versions` says 各部件 = 发布版声明
  B  an upgrade whose new Claude Code fails the doctor: the whole machine goes
     back — current, ccquota, every tool, the cache, the account links — and the
     version is skipped until the target moves
  C  an upgrade the daemon never restarted on is rolled back too; a good one commits
  D  killed half way: a stage without its mark is fetched again, a switch and a
     rollback cut short are finished — never half old, half new
  E  a release missing an artifact fails BEFORE anything switches, then backs off
  F  a running EPIC batch with work defers the switch, until the hold cap
  G  the daemon: a restart request after `current` moved stops it (launchd brings
     the new code); on the new code, or with nothing moved, the request is removed
  H  release.json: the repo's own passes the one validator; broken ones do not
"""
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
UPD = os.path.join(BIN, "fleet-node-update.py")
SUP = os.path.join(BIN, "fleet-node-supervisor.py")
REPO = os.path.dirname(BIN)
V1 = "1" * 40
V2 = "2" * 40
V3 = "3" * 40

FAKE_CCQUOTA = r"""#!/bin/bash
# fake `ccquota release fetch --hub H --pubkey P --artifacts <sha> <dest>`
[ "$1" = release ] && [ "$2" = fetch ] || { echo "fake ccquota: $*" >&2; exit 2; }
shift 2
while [ "$#" -gt 2 ]; do shift; done
sha=$1 dest=$2
echo "$sha" >> "$FAKE_REL/.fetched"
[ -d "$FAKE_REL/$sha" ] || { echo "HTTP 404 no release $sha" >&2; exit 1; }
[ -e "$dest" ] && { echo "$dest already exists" >&2; exit 1; }
cp -R "$FAKE_REL/$sha" "$dest.partial" || exit 1
[ -z "${FAKE_SLOW:-}" ] || sleep "$FAKE_SLOW"   # a fetch the drill kills half way
mv "$dest.partial" "$dest"
echo '{"sha":"'"$sha"'"}'
"""


def sh256(b):
    return hashlib.sha256(b).hexdigest()


def wj(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


def make_release(rel, sha, claude="2.1.1", codex="0.154.0", tmux="3.7c", broken=(), drop=()):
    """A release dir as `ccquota release fetch --artifacts` leaves it, under <rel>/<sha>."""
    d = os.path.join(rel, sha)
    os.makedirs(os.path.join(d, ".release", "artifacts"))
    os.makedirs(os.path.join(d, "bin"))
    with open(os.path.join(REPO, "release.json")) as f:
        spec = json.load(f)
    c = spec["components"]
    c["claude"]["version"], c["codex"]["version"], c["tmux"]["version"] = claude, codex, tmux
    wj(os.path.join(d, "release.json"), spec)
    shutil.copy(UPD, os.path.join(d, "bin"))
    shutil.copy(SUP, os.path.join(d, "bin"))
    arts = {
        "ccquota-darwin-arm64": 'echo "ccquota prod-%s"' % sha[:7],
        "claude-%s-darwin-arm64" % claude: 'echo "%s (Claude Code)"' % claude,
        "codex-%s-darwin-arm64" % codex: 'echo "codex-cli %s"' % codex,
        "tmux-%s-darwin-arm64" % tmux: 'echo "tmux %s"' % tmux,
    }
    man = []
    for n, body in sorted(arts.items()):
        if any(n.startswith(x) for x in drop):
            continue
        if any(n.startswith(x) for x in broken):
            body = "echo broken >&2; exit 3"
        b = ("#!/bin/sh\n%s\n" % body).encode()
        with open(os.path.join(d, ".release", "artifacts", n), "wb") as f:
            f.write(b)
        os.chmod(os.path.join(d, ".release", "artifacts", n), 0o755)
        man.append({"name": n, "sha256": sh256(b), "size": len(b)})
    wj(os.path.join(d, ".release", "manifest.json"), {"schema": 1, "sha": sha, "artifacts": man})
    return d


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fnu.")
        self.root = os.path.join(self.d, "root")
        self.rel = os.path.join(self.d, "rel")
        self.home = os.path.join(self.d, "Users", "alice")
        for x in (self.root, self.rel, self.home, os.path.join(self.d, "db")):
            os.makedirs(x)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("FLEET_")}
        cq = os.path.join(self.d, "ccquota")
        with open(cq, "w") as f:
            f.write(FAKE_CCQUOTA)
        os.chmod(cq, 0o755)
        self.env.update({
            "FLEET_NODE_STATE": os.path.join(self.d, "db"),
            "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_RUNTIME": os.path.join(self.root, "current"),
            "FLEET_NODE_DAEMON_DIR": os.path.join(self.d, "LaunchDaemons"),
            "FLEET_NODE_USERS": os.path.join(self.d, "Users"),
            "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_PASSWD": os.path.join(self.d, "passwd.json"),
            "FLEET_NODE_TEST": "1",
            "FLEET_NODE_LAUNCHCTL": "",
            "FLEET_NODE_CCQUOTA": cq,
            "FLEET_NODE_UPDATE_PLATFORM": "darwin-arm64",
            "FLEET_NODE_UPDATE_SETTLE": "0",
            "FLEET_NODE_UPDATE_LIB": os.path.join(self.d, "no-lib.sh"),
            "FAKE_REL": self.rel,
        })
        os.makedirs(self.env["FLEET_NODE_DAEMON_DIR"])
        self.wj(self.env["FLEET_NODE_TABLE"], {"children": [], "tasks": []})
        self.wj(self.env["FLEET_NODE_PASSWD"], {"alice": {"uid": os.geteuid(), "gid": os.getegid(), "home": self.home}})
        self.wj(os.path.join(self.d, "db", "accounts.json"), {"alice": {"managed": True, "since": 1}})
        with open(os.path.join(self.d, "db", "machine.env"), "w") as f:
            f.write("CCQUOTA_HUB_URL=https://hub.invalid\n")
        with open(os.path.join(self.d, "db", "release.pub"), "w") as f:
            f.write("ed25519 AAAA\n")
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        shutil.rmtree(self.d, ignore_errors=True)

    # -- helpers
    def wj(self, path, obj):
        with open(path, "w") as f:
            json.dump(obj, f)

    def rj(self, path):
        with open(path) as f:
            return json.load(f)

    def release(self, sha, **kw):
        return make_release(self.rel, sha, **kw)

    def tick(self, target, **extra):
        e = dict(self.env, FLEET_NODE_UPDATE_TARGET=target, **extra)
        r = subprocess.run([sys.executable, UPD, "tick"], env=e, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return self.state()

    def cmd(self, *args):
        return subprocess.run([sys.executable, UPD] + list(args), env=self.env, capture_output=True, text=True,
                              timeout=60)

    def state(self):
        return self.rj(os.path.join(self.d, "db", "update.json"))

    def daemon_on(self, sha):
        """The daemon came back (launchd) on <sha>: its heartbeat, its runtime."""
        self.wj(os.path.join(self.d, "db", "state.json"),
                {"supervisor": {"pid": os.getpid(), "heartbeat": time.time(), "runtime": sha}})

    def current(self):
        return os.path.basename(os.readlink(os.path.join(self.root, "current")))

    def out(self, tool):
        p = os.path.join(self.root, "current", "tools", "bin", tool)
        return subprocess.run([p], capture_output=True, text=True).stdout.strip()

    def install(self, sha, **kw):
        """Bring the sandbox to <sha>, committed."""
        self.release(sha, **kw)
        st = self.tick(sha)
        self.assertEqual(st["phase"], "switched", st)
        self.daemon_on(sha)
        st = self.tick(sha)
        self.assertEqual(st["result"], "committed", st)

    def assert_all_on(self, sha, claude):
        self.assertEqual(self.current(), sha)
        ccq = os.path.join(self.root, "current", "bin", "ccquota")
        self.assertEqual(subprocess.run([ccq], capture_output=True, text=True).stdout.strip(), "ccquota prod-" + sha[:7])
        self.assertEqual(self.out("claude"), claude + " (Claude Code)")
        self.assertEqual(open(os.path.join(self.root, "cache", "claude", "current")).read().strip(), claude)
        self.assertTrue(os.path.exists(os.path.join(self.root, "cache", "claude", claude, "claude")))
        link = os.path.join(self.home, ".local", "bin", "claude")
        self.assertEqual(os.readlink(link), os.path.join(self.root, "current", "tools", "bin", "claude"))
        self.assertEqual(subprocess.run([link], capture_output=True, text=True).stdout.strip(), claude + " (Claude Code)")
        tm = os.path.join(self.home, ".local", "share", "claude-fleet-vendor", "bin", "tmux")
        self.assertTrue(os.path.islink(tm))


class A_Fresh(Sandbox):
    def test_every_part_lands(self):
        self.install(V1, claude="2.1.1")
        self.assert_all_on(V1, "2.1.1")
        self.assertTrue(os.path.exists(os.path.join(self.root, V1, ".release", "staged.json")))
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        for row in ("runtime", "ccquota", "claude", "codex", "tmux", "daemon", "cache", "account"):
            self.assertRegex(r.stdout, r"PASS\s+%s\b" % row)
        r = subprocess.run(["sh", os.path.join(BIN, "fleet-doctor.sh"), "--machine"], env=self.env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("各部件 = 发布版声明", r.stdout)
        v = self.cmd("versions").stdout
        self.assertIn("各部件 = 发布版声明", v)
        self.assertIn("claude 2.1.1", v)
        self.assertIn("codex codex-cli 0.154.0", v)
        # the daemon is asked to restart onto it
        self.assertEqual(self.rj(os.path.join(self.d, "db", "update-restart.json"))["to"], V1)
        # again: nothing to do, still current
        self.assertEqual(self.tick(V1)["result"], "current")
        # a Claude Code that updated itself (its own link) is put back on the next tick
        link = os.path.join(self.home, ".local", "bin", "claude")
        os.remove(link)
        os.symlink("/nowhere/claude", link)
        self.assertRegex(self.cmd("doctor").stdout, r"WARN\s+account")
        self.tick(V1)
        self.assertEqual(os.readlink(link), os.path.join(self.root, "current", "tools", "bin", "claude"))
        # never over the account's own regular file
        os.remove(link)
        open(link, "w").write("mine")
        self.tick(V1)
        self.assertEqual(open(link).read(), "mine")


class B_RollbackWhole(Sandbox):
    def test_new_fail_rolls_every_part_back(self):
        self.install(V1, claude="2.1.1")
        self.release(V2, claude="2.1.9", codex="0.155.0", broken=("claude-",))
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched")
        self.assertEqual(self.current(), V2)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertIn("claude", st["reason"])
        # every part is the old release's again
        self.assert_all_on(V1, "2.1.1")
        self.assertEqual(self.out("codex"), "codex-cli 0.154.0")
        self.assertEqual(os.path.basename(os.readlink(os.path.join(self.root, ".prev"))), V2)
        self.assertEqual(self.rj(os.path.join(self.d, "db", "update-restart.json"))["to"], V1)
        # not retried until the target moves
        self.daemon_on(V1)
        self.assertEqual(self.tick(V2)["result"], "skipped")
        self.assertEqual(self.current(), V1)
        self.assertNotEqual(self.cmd("status", "--check").returncode, 0)


class C_DaemonAndCommit(Sandbox):
    def test_daemon_not_restarted_is_rolled_back(self):
        self.install(V1)
        self.release(V2, claude="2.1.2")
        self.tick(V2)
        # launchd never brought the daemon back on V2: still the V1 process
        self.daemon_on(V1)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertIn("daemon", st["reason"])
        self.assertEqual(self.current(), V1)

    def test_good_upgrade_commits(self):
        self.install(V1, claude="2.1.1")
        self.release(V2, claude="2.1.2", codex="0.155.0")
        self.tick(V2)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "committed", st)
        self.assert_all_on(V2, "2.1.2")
        self.assertEqual(self.out("codex"), "codex-cli 0.155.0")
        self.assertEqual(os.path.basename(os.readlink(os.path.join(self.root, ".prev"))), V1)
        self.assertEqual(self.cmd("status", "--check").returncode, 0)
        # the old cache version went; the old release is kept (prev) until it retires
        self.assertFalse(os.path.exists(os.path.join(self.root, "cache", "claude", "2.1.1")))
        self.assertTrue(os.path.isdir(os.path.join(self.root, V1)))
        # a third release retires V1 (KEEP 0): V1 goes, V2 (prev) stays
        self.release(V3, claude="2.1.3")
        self.tick(V3)
        self.daemon_on(V3)
        st = self.tick(V3, FLEET_NODE_UPDATE_KEEP_SECS="0")
        self.assertEqual(st["result"], "committed", st)
        self.assertFalse(os.path.exists(os.path.join(self.root, V1)))
        self.assertTrue(os.path.isdir(os.path.join(self.root, V2)))
        tools = os.listdir(os.path.join(self.root, "tools", "claude"))
        self.assertEqual(len(tools), 2, tools)   # V2's and V3's, not V1's


class D_KilledHalfWay(Sandbox):
    def test_stage_cut_short_is_fetched_again(self):
        self.install(V1)
        self.release(V2, claude="2.1.2")
        # a stage cut short: the dir is there, its staged.json is not
        shutil.copytree(os.path.join(self.rel, V2), os.path.join(self.root, V2))
        os.remove(os.path.join(self.root, V2, "release.json"))
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched", st)
        self.assertTrue(os.path.exists(os.path.join(self.root, V2, "release.json")))
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "committed")
        self.assert_all_on(V2, "2.1.2")

    def test_switch_cut_short_is_finished(self):
        self.install(V1, claude="2.1.1")
        self.release(V2, claude="2.1.2")
        # staged, phase saved as switching, then killed before the link moved
        self.tick(V2)   # a whole switch, to get a real staged V2 …
        # … then wind it back to "killed after `switching` was saved"
        os.remove(os.path.join(self.root, "current"))
        os.symlink(os.path.join(self.root, V1), os.path.join(self.root, "current"))
        st = self.state()
        st["phase"] = "switching"
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        self.assertEqual(self.current(), V1)
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched")
        self.assertEqual(self.current(), V2)
        self.assertEqual(open(os.path.join(self.root, "cache", "claude", "current")).read().strip(), "2.1.2")
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "committed")
        self.assert_all_on(V2, "2.1.2")

    def test_rollback_cut_short_is_finished(self):
        self.install(V1, claude="2.1.1")
        self.release(V2, claude="2.1.2", broken=("claude-",))
        self.tick(V2)
        # killed right after `rolling-back` was saved: current still the bad one
        st = self.state()
        st.update(phase="rolling-back", rollback_reason="new FAIL: claude")
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        self.assertEqual(self.current(), V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assert_all_on(V1, "2.1.1")


class E_MissingArtifact(Sandbox):
    def test_nothing_switches(self):
        self.install(V1)
        self.release(V2, drop=("codex-",))
        st = self.tick(V2)
        self.assertEqual(st["result"], "failed", st)
        self.assertIn("codex-0.154.0-darwin-arm64", st["reason"])
        self.assertEqual(self.current(), V1)
        self.assertFalse(os.path.exists(os.path.join(self.root, V2)))
        n = len(open(os.path.join(self.rel, ".fetched")).read().split())
        self.assertEqual(self.tick(V2)["result"], "backoff")
        self.assertEqual(len(open(os.path.join(self.rel, ".fetched")).read().split()), n, "a backoff fetched again")
        # no pinned key: refused before any fetch
        os.remove(os.path.join(self.d, "db", "release.pub"))
        st = self.tick(V3, FLEET_NODE_UPDATE_RETRY="0")
        self.assertEqual(st["result"], "failed")
        self.assertIn("pinned release key", st["reason"])


class F_EpicHold(Sandbox):
    def test_batch_with_work_defers_until_the_cap(self):
        self.install(V1)
        lib = os.path.join(self.d, "lib.sh")
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo "active epic=2329 conf=$FLEET_CONF_DIR"; return 0; }\n')
        self.release(V2)
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib)
        self.assertEqual(st["result"], "deferred", st)
        self.assertIn("alice", st["reason"])
        self.assertIn(os.path.join(self.home, ".config", "claude-fleet"), st["reason"])
        self.assertEqual(self.current(), V1)
        # past the cap the tick goes on
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="0")
        self.assertEqual(st["phase"], "switched", st)
        self.assertIn("hold released", open(os.path.join(self.d, "log", "update.log")).read())
        # an idle batch (fleet_epic_holding rc 1) never holds
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo idle; return 1; }\n')
        self.daemon_on(V2)
        self.tick(V2, FLEET_NODE_UPDATE_LIB=lib)
        self.release(V3)
        self.assertEqual(self.tick(V3, FLEET_NODE_UPDATE_LIB=lib)["phase"], "switched")


class G_DaemonRestart(Sandbox):
    def sup(self):
        e = dict(self.env, FLEET_NODE_TICK="0.1")
        p = subprocess.Popen([sys.executable, SUP, "run"], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.procs.append(p)
        st = os.path.join(self.d, "db", "state.json")

        def up():
            try:
                return (self.rj(st).get("supervisor") or {}).get("pid") == p.pid
            except (IOError, OSError, ValueError):
                return False
        end = time.time() + 15
        while time.time() < end and not up():
            time.sleep(0.1)
        return p

    def test_restart_request(self):
        for s in (V1, V2):
            os.makedirs(os.path.join(self.root, s))
        cur = os.path.join(self.root, "current")
        os.symlink(os.path.join(self.root, V1), cur)
        req = os.path.join(self.d, "db", "update-restart.json")
        # a stale request (current did not move) is removed, the daemon stays
        p = self.sup()
        self.wj(req, {"to": V2})
        end = time.time() + 10
        while time.time() < end and os.path.exists(req):
            time.sleep(0.1)
        self.assertFalse(os.path.exists(req))
        self.assertIsNone(p.poll())
        # current moved: the daemon stops (launchd starts the new code)
        os.remove(cur)
        os.symlink(os.path.join(self.root, V2), cur)
        self.wj(req, {"to": V2})
        self.assertEqual(p.wait(timeout=15), 0)
        self.assertTrue(os.path.exists(req))
        # the new one runs V2 and clears the request
        p2 = self.sup()
        end = time.time() + 10
        while time.time() < end and os.path.exists(req):
            time.sleep(0.1)
        self.assertFalse(os.path.exists(req))
        self.assertIsNone(p2.poll())
        self.assertEqual(self.rj(os.path.join(self.d, "db", "state.json"))["supervisor"]["runtime"], V2)
        p2.send_signal(signal.SIGTERM)
        p2.wait(timeout=15)

    def test_default_table_has_update(self):
        e = {k: v for k, v in self.env.items() if k != "FLEET_NODE_TABLE"}
        r = subprocess.run([sys.executable, SUP, "status"], env=e, capture_output=True, text=True, timeout=30)
        self.assertIn("update", r.stdout)


class H_ReleaseJson(Sandbox):
    def test_validator(self):
        r = self.cmd("check-release", os.path.join(REPO, "release.json"))
        self.assertEqual(r.returncode, 0, r.stderr)
        good = json.load(open(os.path.join(REPO, "release.json")))
        bad = [
            {},
            dict(good, schema=2),
            dict(good, extra=1),
            dict(good, components={k: v for k, v in good["components"].items() if k != "codex"}),
            dict(good, components=dict(good["components"], claude={"artifact": "claude-{version}"})),
            dict(good, components=dict(good["components"], claude={"version": "1 2", "artifact": "x"})),
            dict(good, components=dict(good["components"], node={"version": "1"})),
            dict(good, components=dict(good["components"], supervisor={"script": "bin/other.py"})),
        ]
        for b in bad:
            r = subprocess.run([sys.executable, UPD, "check-release", "-"], input=json.dumps(b), env=self.env,
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 1, b)
        # status before any tick: not set up
        self.assertEqual(self.cmd("status", "--check").returncode, 2)


if __name__ == "__main__":
    # the BREAK-IT drill (node-update-half) builds its fixtures with the same code
    if len(sys.argv) > 1 and sys.argv[1] == "--fake-ccquota":
        with open(sys.argv[2], "w") as f:
            f.write(FAKE_CCQUOTA)
        os.chmod(sys.argv[2], 0o755)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--make-release":
        kw = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
        make_release(sys.argv[2], sys.argv[3], **kw)
        sys.exit(0)
    unittest.main(verbosity=2)
