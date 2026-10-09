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
  I  credsep's root-owned code copy and the shared credential proxy follow `current`
     (issue #2435): after a switch the copy's sha is the release's and the proxy
     (the daemon's child, played by a fake that reports the copy it loaded) runs
     it; a rollback puts both back; a launchd-owned proxy (legacy) is restarted
     by `machine refresh`; a tick on the current release heals a drifted copy; a
     switch made by an updater that did not know (the first version carrying
     this) is not rolled back by its own new doctor row; the doctor's `credsep`
     row FAILs on a stale copy and on a proxy still on the old code
"""
import hashlib
import json
import os
import pwd
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
CREDSEP_CODE = ("fleet-cred-proxy.py", "fleet-credsep-launch.py", "fleet-credsep.py")

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


def make_release(rel, sha, claude="2.1.1", codex="0.154.0", tmux="3.7c", broken=(), drop=(), drill_fail=False,
                 sessions_log=None):
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
    # the credential proxy's code, different bytes per release (issue #2435)
    for f in CREDSEP_CODE:
        with open(os.path.join(BIN, f), "rb") as src:
            b = src.read()
        if f != "fleet-credsep.py":
            b += ("\n# release %s\n" % sha).encode()
        with open(os.path.join(d, "bin", f), "wb") as dst:
            dst.write(b)
    if sessions_log:
        # issue #2484: a fleet-sessions-snapshot.sh that records who ran it, from which release
        sc = os.path.join(d, "bin", "fleet-sessions-snapshot.sh")
        with open(sc, "w") as f:
            f.write('#!/bin/bash\necho "$1|$HOME|${TMPDIR:+tmp}|%s" >> %s\n'
                    '[ "$1" = restore ] && printf "back\\toc\\tissue-1\\t/w\\n"\nexit 0\n' % (sha, sessions_log))
        os.chmod(sc, 0o755)
    if drill_fail:
        os.makedirs(os.path.join(d, "conf"))
        open(os.path.join(d, "conf", "drill-fail"), "w").close()
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
            # credsep's root paths (issue #2435): no shared proxy unless a case writes its record
            "FLEET_CREDSEP_ROOT_BASE": os.path.join(self.d, "cred", "db"),
            "FLEET_CREDSEP_RUN_BASE": os.path.join(self.d, "cred", "run"),
            "FLEET_CREDSEP_LOG_BASE": os.path.join(self.d, "cred", "log"),
            "FLEET_CREDSEP_LIB": os.path.join(self.d, "cred", "lib"),
            "FLEET_CREDSEP_DAEMON_DIR": os.path.join(self.d, "LaunchDaemons"),
            "FLEET_CREDSEP_ROLE": pwd.getpwuid(os.geteuid()).pw_name,
            "FLEET_CREDSEP_SVC": "0",
            "FLEET_CREDSEP_TEST": "1",
            "FLEET_NODE_CREDSEP_WAIT": "0",
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
    def test_drill_fail_marker_rolls_back(self):
        # issue #2336: the drill's rollback release fails its own doctor
        self.install(V1)
        self.release(V2, drill_fail=True)
        self.tick(V2)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertIn("drill", st["reason"])
        self.assertEqual(self.current(), V1)
        self.assertNotIn("drill", self.cmd("doctor").stdout)

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


FAKE_PROXY = r"""import hashlib, os, sys, time
# the shared credential proxy, played: it reports the copy it loaded, as the real
# one writes <run>/version from the launcher's hash of <LIB>/fleet-cred-proxy.py
lib, run = sys.argv[1], sys.argv[2]
os.makedirs(run, exist_ok=True)
v = hashlib.sha256(open(os.path.join(lib, "fleet-cred-proxy.py"), "rb").read()).hexdigest()[:12]
for n, x in (("pid", os.getpid()), ("version", v)):
    with open(os.path.join(run, n + ".tmp"), "w") as f:
        f.write("%s\n" % x)
    os.replace(os.path.join(run, n + ".tmp"), os.path.join(run, n))
time.sleep(3600)
"""


class I_Credsep(Sandbox):
    """credsep's code copy + the shared proxy follow `current` (issue #2435)."""

    def setUp(self):
        Sandbox.setUp(self)
        self.lib = self.env["FLEET_CREDSEP_LIB"]
        self.run = os.path.join(self.env["FLEET_CREDSEP_RUN_BASE"], ".shared")
        self.svc = os.path.join(self.env["FLEET_CREDSEP_DAEMON_DIR"], "com.claude-fleet.cred-proxy-shared.plist"
                                if sys.platform == "darwin" else "claude-fleet-cred-proxy-shared.service")
        os.makedirs(self.lib)
        os.makedirs(self.env["FLEET_CREDSEP_ROOT_BASE"])
        self.wj(os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], ".shared.json"),
                {"shared": True, "user": self.env["FLEET_CREDSEP_ROLE"], "port": 18923, "run": self.run,
                 "lib": self.lib, "version": "", "logins": [], "since": "2026-10-08T00:00:00Z"})

    def code(self, path):
        with open(path, "rb") as f:
            return sh256(f.read())

    def copies_on(self, sha):
        for f in CREDSEP_CODE[:2]:
            self.assertEqual(self.code(os.path.join(self.lib, f)), self.code(os.path.join(self.rel, sha, "bin", f)),
                             "%s in LIB is not %s's" % (f, sha[:4]))

    def want(self, sha):
        return self.code(os.path.join(self.rel, sha, "bin", "fleet-cred-proxy.py"))[:12]

    def live(self):
        try:
            with open(os.path.join(self.run, "version")) as f:
                v = f.read().strip()
            with open(os.path.join(self.run, "pid")) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            return v, pid
        except (OSError, ValueError):
            return None, None

    def wait_live(self, want, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            v, pid = self.live()
            if v == want:
                return pid
            time.sleep(0.1)
        self.fail("the proxy never ran %s (it runs %s)" % (want, self.live()[0]))

    def sup(self):
        e = dict(self.env, FLEET_NODE_TICK="0.1")
        p = subprocess.Popen([sys.executable, SUP, "run"], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(p)
        return p

    def log(self):
        try:
            with open(os.path.join(self.d, "log", "update.log")) as f:
                return f.read()
        except OSError:
            return ""

    def doctor(self, **extra):
        r = subprocess.run([sys.executable, UPD, "doctor"], env=dict(self.env, **extra), capture_output=True, text=True,
                           timeout=60)
        rows = [l.split(None, 2) for l in r.stdout.splitlines() if l.split()[1:2] == ["credsep"]]
        return rows[0][0] + " " + rows[0][2] if rows else None

    def test_supervised_proxy_follows_switch_and_rollback(self):
        """The daemon's child: the copy follows, the proxy runs it — no service definition of our own."""
        fake = os.path.join(self.d, "fake-proxy.py")
        with open(fake, "w") as f:
            f.write(FAKE_PROXY)
        for x in CREDSEP_CODE[:2]:      # what machine install left (an older checkout's copy)
            shutil.copy(os.path.join(BIN, x), os.path.join(self.lib, x))
        self.wj(self.env["FLEET_NODE_TABLE"], {"children": [
            {"name": "cred-proxy-shared", "cmd": [sys.executable, fake, self.lib, self.run], "reload": self.lib}],
            "tasks": []})
        self.env["FLEET_NODE_CREDSEP_WAIT"] = "10"
        for s, kw in ((V1, {}), (V2, {"claude": "2.1.2"}), (V3, {"claude": "2.1.3", "drill_fail": True})):
            self.release(s, **kw)
        p = self.sup()
        old = self.wait_live(self.code(os.path.join(BIN, "fleet-cred-proxy.py"))[:12])
        pid = old
        for s in (V1, V2):
            self.assertEqual(self.tick(s)["phase"], "switched")
            self.copies_on(s)
            self.assertEqual(p.wait(timeout=15), 0)     # current moved: the daemon goes, launchd brings it back
            p = self.sup()
            new = self.wait_live(self.want(s))
            self.assertNotEqual(new, pid, "the proxy was not restarted")
            pid = new
            st = self.tick(s)
            self.assertEqual(st["result"], "committed", st)
            self.assertTrue(self.doctor().startswith("PASS"), self.doctor())
        # V3 fails its doctor: the copy and the proxy go back to V2 with every other part
        self.assertEqual(self.tick(V3)["phase"], "switched")
        self.copies_on(V3)
        self.assertEqual(p.wait(timeout=15), 0)
        p = self.sup()
        self.wait_live(self.want(V3))
        st = self.tick(V3)
        self.assertEqual(st["result"], "rolled-back", st)
        self.copies_on(V2)
        self.assertEqual(p.wait(timeout=15), 0)
        p = self.sup()
        self.assertNotEqual(self.wait_live(self.want(V2)), pid, "the rolled-back proxy is the old process")
        self.assertFalse(os.path.exists(self.svc), "refresh wrote a service definition beside the daemon's child")
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=15)

    def test_legacy_proxy_is_restarted_and_drift_healed(self):
        """launchd still runs the proxy (its plist is there): machine refresh restarts it."""
        with open(self.svc, "w") as f:
            f.write("legacy\n")
        self.install(V1)
        self.copies_on(V1)
        self.install(V2, claude="2.1.2")
        self.copies_on(V2)
        self.assertIn("credsep: shared: refreshed, restarted", self.log())
        # a copy changed by hand (or an admin's own checkout) is put back on the next tick
        with open(os.path.join(self.lib, "fleet-cred-proxy.py"), "w") as f:
            f.write("# someone else's\n")
        self.assertEqual(self.tick(V2)["result"], "current")
        self.copies_on(V2)
        # switched by an updater that did not refresh the copy (the version before this
        # one): the new verify refreshes before it judges — no rollback on its own row
        self.release(V3, claude="2.1.3")
        self.assertEqual(self.tick(V3)["phase"], "switched")
        for x in CREDSEP_CODE[:2]:
            shutil.copy(os.path.join(self.rel, V2, "bin", x), os.path.join(self.lib, x))
        self.daemon_on(V3)
        st = self.tick(V3)
        self.assertEqual(st["result"], "committed", st)
        self.copies_on(V3)

    def test_doctor_row(self):
        with open(self.svc, "w") as f:
            f.write("legacy\n")
        self.install(V1)
        self.assertTrue(self.doctor().startswith("WARN"), self.doctor())     # no version file to read
        with open(os.path.join(self.run if os.path.isdir(self.run) else (os.makedirs(self.run) or self.run),
                               "pid"), "w") as f:
            f.write("%d\n" % os.getpid())
        with open(os.path.join(self.run, "version"), "w") as f:
            f.write(self.want(V1) + "\n")
        self.assertTrue(self.doctor().startswith("PASS"), self.doctor())
        with open(os.path.join(self.run, "version"), "w") as f:
            f.write("0123456789ab\n")
        self.assertTrue(self.doctor().startswith("FAIL"), self.doctor())
        self.assertIn("0123456789ab", self.doctor())
        with open(os.path.join(self.lib, "fleet-credsep-launch.py"), "a") as f:
            f.write("# edited\n")
        d = self.doctor()
        self.assertTrue(d.startswith("FAIL") and "fleet-credsep-launch.py" in d, d)
        # no shared proxy on the machine: no row at all
        os.remove(os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], ".shared.json"))
        self.assertIsNone(self.doctor())

    def test_default_table_reloads_on_lib(self):
        e = dict(os.environ, FLEET_CREDSEP_LIB=self.lib)
        out = subprocess.run([sys.executable, "-c", "import importlib.util, json, sys\n"
                              "s = importlib.util.spec_from_file_location('s', sys.argv[1]); m = importlib.util.module_from_spec(s)\n"
                              "s.loader.exec_module(m); p = m.Paths()\n"
                              "print(json.dumps([c for c in m.default_table(p)['children'] if c['name'] == 'cred-proxy-shared'][0]))",
                              SUP], env=e, capture_output=True, text=True, timeout=30)
        c = json.loads(out.stdout)
        self.assertEqual(c.get("reload"), self.lib, out.stderr)


class K_LoginInstall(Sandbox):
    """issue #2688: a managed login's own ~/.claude/fleet is on the doctor — PASS at
    the release, WARN (never FAIL: no rollback) behind it or unreadable, no row
    without one."""
    def test_login_install_row(self):
        self.install(V1, claude="2.1.1")
        self.assertNotRegex(self.cmd("doctor").stdout, r"\binstall\b")
        vers = os.path.join(self.home, ".claude", "fleet.versions")
        for sha in (V1, V2):
            os.makedirs(os.path.join(vers, sha))
        live = os.path.join(self.home, ".claude", "fleet")
        os.symlink(os.path.join(vers, V1), live)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"PASS\s+install\s+alice: ~/.claude/fleet at the release " + V1[:12])
        os.remove(live)
        os.symlink(os.path.join(vers, V2), live)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: ~/.claude/fleet at %s \(link\), the release is %s"
                         % (V2[:12], V1[:12]))
        self.assertIn("fleet-install-sync.sh' --root " + live, r.stdout)
        # the plain directory a bootstrap left behind, no git: unreadable, still a WARN
        os.remove(live)
        os.makedirs(live)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: ~/.claude/fleet \(plain directory\) — its version is unreadable")


class L_ClientShell(Sandbox):
    """issue #2702: ONE `shell` row over the taken-over logins only — PASS when none
    carries the person's client here, WARN (never FAIL: no rollback) naming the login + the retire command; a
    non-root doctor reads the last sweep's record (other homes are not its to read)."""
    def test_shell_row(self):
        self.install(V1, claude="2.1.1")
        r = self.cmd("doctor")
        self.assertRegex(r.stdout, r"PASS\s+shell\s+no taken-over login carries the client shell or a login hook · "
                                   r"托管登录 0 个，其余账号不在清单内不扫")
        os.makedirs(os.path.join(self.d, "db", "logins"), exist_ok=True)
        open(os.path.join(self.d, "db", "logins", "alice.env"), "w").close()
        sp = os.path.join(self.d, "db", "state.json")
        with open(sp) as f:
            st = json.load(f)
        st["sweep"] = {"clientshell": [{"login": "alice", "cache": True, "zshrc": 3}]}
        with open(sp, "w") as f:
            json.dump(st, f)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+shell\s+alice: ~/.cache/claude-fleet/shell · ~/.zshrc 3 hook line\(s\)")
        self.assertIn("fleet-node-shell-retire.sh' --login alice", r.stdout)
        self.assertIn("托管登录 1 个，其余账号不在清单内不扫", r.stdout)
        # a login the record names that is not taken over (an admin) is not the fleet's
        os.remove(os.path.join(self.d, "db", "logins", "alice.env"))
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+shell\s")


class J_Sessions(Sandbox):
    """issue #2484: every managed account's sessions are pinned before the switch
    (the target release's fleet-sessions-snapshot.sh save, demoted, its own HOME and
    TMPDIR) and brought back after it — committed or rolled back."""
    def log(self):
        p = os.path.join(self.d, "sessions.log")
        return open(p).read().splitlines() if os.path.exists(p) else []

    def test_save_before_restore_after(self):
        L = os.path.join(self.d, "sessions.log")
        self.install(V1, sessions_log=L)
        self.assertEqual(self.log(), ["save|%s|tmp|%s" % (self.home, V1), "restore|%s|tmp|%s" % (self.home, V1)])
        self.assertIn("sessions restore alice: rc 0 1 back", open(os.path.join(self.env["FLEET_NODE_LOG"], "update.log")).read())
        # a version that fails its doctor: pinned by V2's, brought back by V1's
        self.release(V2, claude="2.1.9", broken=("claude-",), sessions_log=L)
        self.tick(V2)
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "rolled-back")
        self.assertEqual(self.log()[2:], ["save|%s|tmp|%s" % (self.home, V2), "restore|%s|tmp|%s" % (self.home, V1)])

    def test_off_and_absent(self):
        L = os.path.join(self.d, "sessions.log")
        self.release(V1, sessions_log=L)
        st = self.tick(V1, FLEET_NODE_UPDATE_SESSIONS="0")
        self.assertEqual(st["phase"], "switched", st)
        self.assertEqual(self.log(), [])
        self.daemon_on(V1)
        self.assertEqual(self.tick(V1, FLEET_NODE_UPDATE_SESSIONS="0")["result"], "committed")
        self.assertEqual(self.log(), [])
        # a release without the script (older than #2484): nothing run, nothing broken
        self.release(V2)
        self.tick(V2)
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "committed")
        self.assertEqual(self.log(), [])


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
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-sessions":
        # BREAK-IT node-update-sessions: pinned before the switch, back after
        unittest.main(argv=[sys.argv[0], "J_Sessions.test_save_before_restore_after"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-credsep":
        # BREAK-IT credsep-stale-after-switch: the supervised case, switch + rollback
        unittest.main(argv=[sys.argv[0], "I_Credsep.test_supervised_proxy_follows_switch_and_rollback"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-login-install":
        # BREAK-IT managed-login-install-stale: the doctor half
        unittest.main(argv=[sys.argv[0], "K_LoginInstall"], verbosity=1)
    unittest.main(verbosity=2)
