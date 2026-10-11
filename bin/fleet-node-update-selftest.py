#!/usr/bin/env python3
"""fleet-node-update-selftest.py — the machine's one updater in a sandbox (issue #2334).

Driven by bin/fleet-node-update-selftest.sh. Every path goes through the
FLEET_NODE_* seams; a fake ccquota "fetches" a release from a fixture directory
the way `ccquota release fetch --artifacts` lays one out (C7). Nothing touches
/Library, /var or a real login.

  A  a fresh machine: every part lands on the release (runtime, ccquota, claude,
     codex, tmux, the bootstrap cache, a managed account's links, the daemon) and
     `versions` says 各部件 = 发布版声明, and `versions --json` (issue #2798) the same
  B  an upgrade whose new Claude Code fails the doctor: the whole machine goes
     back — current, ccquota, every tool, the cache, the account links — and the
     version is skipped until the target moves
  C  an upgrade the daemon never restarted on is rolled back too; a good one commits
  D  killed half way: a stage without its mark is fetched again, a switch and a
     rollback cut short are finished — never half old, half new
  E  a release missing an artifact fails BEFORE anything switches, then backs off
  F  a running EPIC batch with work defers the switch, until the hold cap —
     one clock for the machine, whatever the target (issue #2843)
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
  N  the release key (issue #2843): status prints the pinned and the signer's
     fingerprints; a fetch that failed its signature check is a doctor FAIL
  P  a tool's helpers (issue #3017): staged beside it, linked beside every
     account's link (a hand-placed copy replaced), a release staged without
     them completed on the next tick — from its artifacts, else fetched again
  Q  an admin login's own ccquota agent (issue #3034): credsep's meta.json points
     it at <current>/bin/ccquota, it is kickstarted on the switch and the
     rollback (once a release), a tenant's record is untouched; the doctor's
     `admin-agent` row WARNs on an own older binary, never FAILs
  O  a stale fail (issue #2906): a torn read a later signed fetch outlived is
     no FAIL and rolls nothing back; a current one is a WARN; a rolled-back
     release is retried once its cause is gone, else after a doubling wait
"""
import base64
import filecmp
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
V9 = "9" * 40
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


# a ccquota that resumes (issue #2701): `-h` names --pinned/--cache; the flags
# land in $FAKE_REL/.argv, the cache's entries at start in .seeded; with
# $FAKE_REL/.cut present the fetch is cut half way (a .part left in the cache)
FAKE_CCQUOTA_RESUME = r"""#!/bin/bash
[ "$1" = release ] && [ "$2" = fetch ] || { echo "fake ccquota: $*" >&2; exit 2; }
shift 2
[ "$1" = -h ] && { echo "  -cache string" >&2; echo "  -pinned" >&2; exit 0; }
echo "$*" >> "$FAKE_REL/.argv"
cache="" prog=""
while [ "$#" -gt 2 ]; do
  case "$1" in --cache) cache=$2; shift ;; --progress) prog=$2; shift ;; esac
  shift
done
sha=$1 dest=$2
ls "$cache" > "$FAKE_REL/.seeded"
echo "release ${sha:0:12}: 4 artifacts" >> "$prog"
if [ -e "$FAKE_REL/.cut" ]; then
  rm -f "$FAKE_REL/.cut"
  head -c 1000 /dev/zero > "$cache/$(printf %064d 7).part"
  echo "  claude: 0.0 MB / 0.2 MB · 0.01 MB/s · eta 20s" >> "$prog"
  echo "artifact claude: no bytes for 30s" >&2
  exit 1
fi
[ -d "$FAKE_REL/$sha" ] || { echo "HTTP 404 no release $sha" >&2; exit 1; }
cp -R "$FAKE_REL/$sha" "$dest" || exit 1
echo '{"sha":"'"$sha"'"}'
"""


def sh256(b):
    return hashlib.sha256(b).hexdigest()


def wj(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f)


def make_release(rel, sha, claude="2.1.1", codex="0.154.0", tmux="3.7c", broken=(), drop=(), drill_fail=False,
                 sessions_log=None, sync_log=None, sync_fail=False, apply_log=None, ccquota_src=None, ccquota_says=None):
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
    if sync_log:
        # issue #2714: a fleet-install-sync.sh that records who ran it, from which
        # release, and follows the machine's release the way #2688's does (a
        # versions link switch) — or, sync_fail, refuses and moves nothing
        sc = os.path.join(d, "bin", "fleet-install-sync.sh")
        with open(sc, "w") as f:
            f.write('#!/bin/bash\necho "$1 $2|$HOME|$USER|${TMPDIR:+tmp}|$FLEET_NODE_ROOT|%s" >> %s\n' % (sha, sync_log))
            if sync_fail:
                f.write('echo "fleet-install-sync: refused tracked local changes" >&2\nexit 1\n')
            else:
                f.write('t=$(readlink "$FLEET_NODE_ROOT/current"); t=${t##*/}\n'
                        'mkdir -p "$HOME/.claude/fleet.versions/$t" && ln -sfn "$HOME/.claude/fleet.versions/$t" "$2"'
                        '\necho "fleet-install-sync: switched to $t"\n')
        os.chmod(sc, 0o755)
    # the version's own code beyond bin/ (issue #2774: a login's tree links each file)
    os.makedirs(os.path.join(d, "conf", "agent-defaults"))
    with open(os.path.join(d, "conf", "agent-defaults", "MARK"), "w") as f:
        f.write(sha + "\n")
    # the mod (issue #2964): a login tree must hold its own bytes, never links out
    os.makedirs(os.path.join(d, "mod", "fleet", ".claude-plugin"))
    os.makedirs(os.path.join(d, "mod", "fleet", "hooks"))
    with open(os.path.join(d, "mod", "fleet", ".claude-plugin", "plugin.json"), "w") as f:
        f.write('{"name": "fleet"}\n')
    with open(os.path.join(d, "mod", "fleet", "hooks", "register.ts"), "w") as f:
        f.write("// %s\n" % sha)
    if apply_log:
        # issue #2774: the version's fleet-install-apply.sh, recording how it was run
        ap = os.path.join(d, "bin", "fleet-install-apply.sh")
        with open(ap, "w") as f:
            f.write('#!/bin/bash\necho "$*|$HOME|%s" >> %s\necho "apply: ok — fixture %s"\n' % (sha, apply_log, sha[:7]))
        os.chmod(ap, 0o755)
    if drill_fail:
        open(os.path.join(d, "conf", "drill-fail"), "w").close()
    arts = {
        "ccquota-darwin-arm64": ccquota_says or 'echo "ccquota prod-%s"' % sha[:7],
        "claude-%s-darwin-arm64" % claude: 'echo "%s (Claude Code)"' % claude,
        "codex-%s-darwin-arm64" % codex: 'echo "codex-cli %s"' % codex,
        "tmux-%s-darwin-arm64" % tmux: 'echo "tmux %s"' % tmux,
    }
    # each tool's helpers (issue #3017), named the way release.json pins them
    for t, ver in (("claude", claude), ("codex", codex), ("tmux", tmux)):
        for h, a in sorted((c[t].get("helpers") or {}).items()):
            arts[a.replace("{version}", ver).replace("{os}", "darwin").replace("{arch}", "arm64")] = \
                'echo "%s %s"' % (h, ver)
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
    m = {"schema": 1, "sha": sha, "artifacts": man}
    if ccquota_src:
        m["ccquota_src"] = ccquota_src  # the commit's Go source, checked by the hub (issue #2930)
    wj(os.path.join(d, ".release", "manifest.json"), m)
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
            f.write("ed25519 %s\n" % base64.b64encode(b"\x01" * 32).decode())
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
        # --json: the machine link's 版本与更新 (issue #2798) — the release,
        # what each part answers, what release.json pins, the updater's record
        j = json.loads(self.cmd("versions", "--json").stdout)
        self.assertEqual(j["runtime"], V1)
        self.assertEqual(j["actual"]["claude"], "2.1.1")
        self.assertEqual(j["actual"]["codex"], "0.154.0")
        self.assertEqual(j["want"]["claude"], "2.1.1")
        self.assertTrue(j["update"].get("result"), j)
        self.assertRegex(j["update"].get("at", ""), r"^\d{4}-\d\d-\d\dT")
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


class P_Helpers(Sandbox):
    """issue #3017: codex runs every shell command through codex-code-mode-host,
    which it looks for beside the path it was started from (~/.local/bin)."""
    H = "codex-code-mode-host"

    def hbin(self):
        return os.path.join(self.root, "current", "tools", "bin", self.H)

    def test_stage_and_account_link(self):
        self.install(V1)
        self.assertEqual(self.out(self.H), self.H + " 0.154.0")
        # in the tools cache beside codex, and the release links it
        self.assertEqual(os.path.dirname(os.path.realpath(self.hbin())),
                         os.path.dirname(os.path.realpath(os.path.join(self.root, "current", "tools", "bin", "codex"))))
        acct = os.path.join(self.home, ".local", "bin", self.H)
        self.assertEqual(os.readlink(acct), self.hbin())
        self.assertEqual(subprocess.run([acct], capture_output=True, text=True).stdout.strip(), self.H + " 0.154.0")
        r = self.cmd("doctor").stdout
        self.assertRegex(r, r"PASS\s+account")
        self.assertNotRegex(r, r"WARN\s+helper")
        self.assertIn(self.H + "-0.154.0-darwin-arm64",
                      self.cmd("pinned-artifacts", os.path.join(REPO, "release.json")).stdout.split())
        # a copy put there by hand is drift, and becomes the release's link
        os.remove(acct)
        with open(acct, "w") as f:
            f.write("#!/bin/sh\necho by-hand\n")
        self.assertRegex(self.cmd("doctor").stdout, r"WARN\s+account.*%s" % self.H)
        self.tick(V1)
        self.assertEqual(os.readlink(acct), self.hbin())
        # the account's own codex (a regular file): its helper is its own too
        cx = os.path.join(self.home, ".local", "bin", "codex")
        os.remove(cx)
        os.remove(acct)
        open(cx, "w").write("mine")
        open(acct, "w").write("mine too")
        self.tick(V1)
        self.assertEqual(open(acct).read(), "mine too")

    def test_release_staged_without_it_is_completed(self):
        # what an updater from before helpers left: the release, no helper beside codex
        self.install(V1)
        os.remove(self.hbin())
        r = self.cmd("doctor")
        self.assertRegex(r.stdout, r"WARN\s+helper\s+codex without its helper " + self.H)
        self.assertNotRegex(r.stdout, r"FAIL")
        fetches = lambda: open(os.path.join(self.rel, ".fetched")).read().split().count(V1)
        fetched = fetches()
        self.tick(V1)
        self.assertEqual(self.out(self.H), self.H + " 0.154.0")
        self.assertEqual(fetches(), fetched, "fetched with the artifact here")
        # its fetch never brought the helper either (a --pinned fetch of the old
        # list): fetched again, the release left as it was
        os.remove(self.hbin())
        os.remove(os.path.join(self.root, V1, ".release", "artifacts", self.H + "-0.154.0-darwin-arm64"))
        self.tick(V1)
        self.assertEqual(self.out(self.H), self.H + " 0.154.0")
        self.assertEqual(fetches(), fetched + 1)
        self.assertEqual([e for e in os.listdir(self.root) if e.startswith(".helpers")], [])
        self.assertNotRegex(self.cmd("doctor").stdout, r"WARN\s+(helper|account)")
        # the hub cannot serve it: noted, tried again only after the retry wait
        os.remove(self.hbin())
        os.rename(os.path.join(self.rel, V1), os.path.join(self.rel, "gone"))
        self.tick(V1)
        self.tick(V1)
        self.assertEqual(fetches(), fetched + 2)
        self.assertEqual(self.current(), V1)


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

    def test_ccquota_not_the_releases_is_rolled_back(self):
        # issue #2930: a release whose ccquota was built from other Go source
        # than its commit's (the hub image's of the day) fails its own doctor
        src = "a" * 64
        self.release(V1, ccquota_src=src, ccquota_says='echo "ccquota prod-%s"; echo "src %s"' % (V1[:7], src))
        self.tick(V1)
        self.daemon_on(V1)
        self.assertEqual(self.tick(V1)["result"], "committed")
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+ccquota\b.*Go source aaaaaaaaaaaa")
        self.release(V2, ccquota_src="b" * 64, ccquota_says='echo "ccquota prod-old1234"; echo "src %s"' % src)
        self.tick(V2)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertIn("ccquota", st["reason"])
        self.assertEqual(self.current(), V1)

    def test_ccquota_of_another_commit_warns_on_an_old_release(self):
        # a release from before #2930 names no source: another commit's build is
        # a WARN (its Go may be the same), never a rollback
        self.release(V1, ccquota_says='echo "ccquota prod-343c92b"')
        self.tick(V1)
        self.daemon_on(V1)
        self.assertEqual(self.tick(V1)["result"], "committed")
        out = self.cmd("doctor").stdout
        self.assertRegex(out, r"WARN\s+ccquota\b.*prod-343c92b.*%s" % V1[:12])

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
    def test_no_hold_by_default(self):
        """issue #2934: a batch with work does not hold the machine unless the
        person turned the hold on — a new stable switches at once, and status
        says the hold is off."""
        self.install(V1)
        lib = os.path.join(self.d, "lib.sh")
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo "active epic=2329 live=1"; return 0; }\n')
        self.release(V2)
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib)
        self.assertEqual(st["phase"], "switched", st)
        self.assertNotIn("hold", st)
        self.assertNotIn("hold released", open(os.path.join(self.d, "log", "update.log")).read())
        self.assertIn("hold    off", self.cmd("status").stdout)

    def test_batch_with_work_defers_until_the_cap(self):
        self.install(V1)
        lib = os.path.join(self.d, "lib.sh")
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo "active epic=2329 conf=$FLEET_CONF_DIR"; return 0; }\n')
        self.release(V2)
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="7200")
        self.assertEqual(st["result"], "deferred", st)
        self.assertIn("alice", st["reason"])
        self.assertIn(os.path.join(self.home, ".config", "claude-fleet"), st["reason"])
        self.assertEqual(self.current(), V1)
        # past the cap the tick goes on
        st["hold"]["since"] -= 7300
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="7200")
        self.assertEqual(st["phase"], "switched", st)
        self.assertIn("hold released", open(os.path.join(self.d, "log", "update.log")).read())
        # an idle batch (fleet_epic_holding rc 1) never holds
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo idle; return 1; }\n')
        self.daemon_on(V2)
        self.tick(V2, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="7200")
        self.release(V3)
        self.assertEqual(self.tick(V3, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="7200")["phase"],
                         "switched")


    def test_one_clock_for_the_machine(self):
        """issue #2843: a new stable, or another batch taking over the hold, does
        not restart the clock — past the cap the machine moves, and each holding
        batch's EPIC gets one note as its login."""
        self.install(V1)
        mark = os.path.join(self.d, "mark-2770")
        with open(mark, "w") as f:
            f.write("epic: 2770\nrepo: o/r\n")
        lib = os.path.join(self.d, "lib.sh")
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { printf "active\\t%s\\tepic=2770 live=1\\n" "%s"; return 0; }\n' % (mark, mark))
        notes = os.path.join(self.d, "notes.log")
        note = os.path.join(self.d, "note.sh")
        with open(note, "w") as f:
            f.write('echo "note $*" >> %s; while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cat "$2" >> %s; shift; done\n'
                    % (notes, notes))
        self.release(V2)
        self.env["FLEET_EPIC_HOLD_CAP_SECS"] = "7200"   # the hold is opt-in (#2934)
        st = self.tick(V2, FLEET_NODE_UPDATE_LIB=lib)
        self.assertEqual(st["result"], "deferred", st)
        since = st["hold"]["since"]
        self.assertIn("held 0m of 120m", st["reason"])
        # stable moves on while the batches hold: the clock does not start over
        self.release(V3)
        st = self.tick(V3, FLEET_NODE_UPDATE_LIB=lib)
        self.assertEqual(st["result"], "deferred", st)
        self.assertEqual(st["hold"]["since"], since, "a new target restarted the machine's hold clock")
        # the doctor's install row says what the hold is for
        r = self.cmd("doctor")
        self.assertIn("one clock for the machine", r.stdout)
        self.assertIn("fleet.versions/<sha>", r.stdout)
        r = self.cmd("status")
        self.assertIn("hold    EPIC batches since", r.stdout)
        # two hours on (the state's clock moved back), the machine moves
        st["hold"]["since"] = since - 7300
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        st = self.tick(V3, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_NOTE_CMD="sh " + note)
        self.assertEqual(st["phase"], "switched", st)
        self.assertNotIn("hold", st)
        log = open(os.path.join(self.d, "log", "update.log")).read()
        self.assertIn("hold released", log)
        self.assertIn("one clock for the machine", log)
        said = open(notes).read()
        self.assertEqual(len([l for l in said.splitlines() if l.startswith("note ")]), 1, said)
        self.assertIn("note 2770 --repo o/r --note --from fleet --body-file", said)
        self.assertIn("fleet.versions/<sha>", said)
        self.assertIn("hold note on o/r#2770 as alice: posted", log)


class N_ReleaseKey(Sandbox):
    def test_key_fingerprints_and_a_signature_failure(self):
        """issue #2843: status prints the pinned key's and the current release's
        signer's fingerprints; a fetch that failed its signature check is a doctor
        FAIL, not only a backoff in update.log."""
        self.install(V1)
        r = self.cmd("status")
        self.assertRegex(r.stdout, r"key     pinned [0-9a-f]{16} · current release signed by ")
        r = self.cmd("doctor")
        self.assertRegex(r.stdout, r"PASS  key +pinned [0-9a-f]{16}")
        st = self.state()
        st.update(result="backoff", failed={V2: {"at": int(time.time()) + 5,
                                                 "reason": "fetch: ccquota: signature does not match the pinned key"}})
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        r = self.cmd("doctor")
        self.assertIn("FAIL  key", r.stdout)
        self.assertIn("failed its signature check", r.stdout)
        r = self.cmd("status", "--check")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("failed its signature check", r.stdout)


TORN = ("fetch: ccquota: signature does not match the pinned key")


class O_TornReadPast(Sandbox):
    """issue #2906: macmini's updater from before #2843 left one torn read in
    `failed` after the stages that followed it landed; every new release's
    doctor read it as a new key FAIL, rolled back, and skipped the sha forever."""

    def stale_failure(self, at):
        st = self.state()
        st["failed"] = {V9: {"at": at, "reason": TORN}}
        self.wj(os.path.join(self.d, "db", "update.json"), st)

    def test_outlived_torn_read_does_not_roll_back(self):
        self.install(V1)
        self.stale_failure(int(time.time()) - 3600)          # before V1's stage landed
        self.assertRegex(self.cmd("doctor").stdout, r"PASS  key")
        self.assertEqual(self.cmd("status", "--check").returncode, 0)
        self.release(V2, claude="2.1.2")
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched", st)
        st["baseline"] = []                                  # the old version's doctor had no key row
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "committed", st)
        self.assertEqual(self.current(), V2)

    def test_fresh_torn_read_is_a_warn(self):
        import http.server
        import threading
        key = "ed25519 %s\n" % base64.b64encode(b"\x01" * 32).decode()

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(key.encode())

            def log_message(self, *a):
                pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        self.install(V1)
        with open(os.path.join(self.d, "db", "machine.env"), "w") as f:
            f.write("CCQUOTA_HUB_URL=http://127.0.0.1:%d\n" % srv.server_address[1])
        self.stale_failure(int(time.time()) + 5)             # after every landed stage: still current
        r = self.cmd("doctor")
        self.assertIn("WARN  key", r.stdout)
        self.assertIn("a torn read", r.stdout)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_skip_is_retried(self):
        self.install(V1, claude="2.1.1")
        self.release(V2, claude="2.1.9", broken=("claude-",))
        self.tick(V2)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertEqual(st["skip"][V2]["tries"], 1)
        self.assertEqual(st["skip"][V2]["rows"], ["claude"])
        self.daemon_on(V1)
        st = self.tick(V2)
        self.assertEqual(st["result"], "skipped", st)
        self.assertIn("retried at", st["reason"])
        # the skip ran out: tried again, rolled back again, the wait doubles
        st["skip"][V2]["at"] -= 21601
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched", st)
        self.daemon_on(V2)
        st = self.tick(V2)
        self.assertEqual(st["result"], "rolled-back", st)
        self.assertEqual(st["skip"][V2]["tries"], 2)
        st["skip"][V2]["at"] -= 21601                        # 6h is not 12h
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        self.daemon_on(V1)
        self.assertEqual(self.tick(V2)["result"], "skipped")
        # 0 = the pre-#2906 rule: until the target moves
        st = self.state()
        st["skip"][V2]["at"] -= 10 ** 7
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        self.assertEqual(self.tick(V2, FLEET_NODE_UPDATE_SKIP_RETRY="0")["result"], "skipped")

    def test_skip_retried_once_the_torn_read_is_past(self):
        """macmini's 336f12c5: skipped for a key FAIL whose cause is gone."""
        self.install(V1)
        self.release(V2, claude="2.1.2")
        st = self.state()
        st["skip"] = {V2: {"at": int(time.time()), "reason": "new FAIL: key %s failed its signature check "
                                                           "2026-10-10T00:17:46Z against pinned f82f: a torn read" % V9[:12]}}
        st["failed"] = {V9: {"at": int(time.time()) - 3600, "reason": TORN}}
        self.wj(os.path.join(self.d, "db", "update.json"), st)
        st = self.tick(V2)
        self.assertEqual(st["phase"], "switched", st)
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "committed")
        self.assertIn("its cause is gone", open(os.path.join(self.d, "log", "update.log")).read())


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
            dict(good, client_reload="later"),
            # a tool's helpers (issue #3017): {file name: artifact}, never a path or a tool's name
            dict(good, components=dict(good["components"], codex=dict(good["components"]["codex"], helpers=["x"]))),
            dict(good, components=dict(good["components"], codex=dict(good["components"]["codex"],
                                                                      helpers={"../x": "x-{version}"}))),
            dict(good, components=dict(good["components"], codex=dict(good["components"]["codex"],
                                                                      helpers={"claude": "x-{version}"}))),
            dict(good, components=dict(good["components"], codex=dict(good["components"]["codex"],
                                                                      helpers={"h": "a/b"}))),
        ]
        # how a running client takes it (issue #2737): hot or restart pass
        for ok in (dict(good, client_reload="hot"), dict(good, client_reload="restart")):
            r = subprocess.run([sys.executable, UPD, "check-release", "-"], input=json.dumps(ok), env=self.env,
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr)
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

    def test_every_round_syncs_the_pool(self):
        """issue #2850: each round also runs `machine pool-sync` — the hub's manifest
        is asked (here a hub that does not answer: noted, the pool left alone)."""
        with open(os.path.join(self.d, "db", "machine.env"), "w") as f:
            f.write("CCQUOTA_HUB_URL=http://127.0.0.1:9\nCCQUOTA_TOKEN=mtok\n")
        self.install(V1)
        rec = os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], ".pool-sync.json")
        with open(rec) as f:
            st = json.load(f)
        self.assertTrue(st.get("tried") and "manifest" in st.get("error", ""), st)
        self.assertNotIn("mtok", open(rec).read())

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

    def test_supervised_restart_writes_no_definition(self):
        """issue #2981: once the daemon's sweep retired launchd's definition and
        the daemon runs the proxy, a credsep restart (install / join / leave /
        purge) is a stamp in LIB — which the child's `reload` watches — never a
        definition beside it; while launchd still runs it, the definition stays
        credsep's."""
        snip = ("import importlib.util, os, sys\n"
                "s = importlib.util.spec_from_file_location('c', sys.argv[1]); m = importlib.util.module_from_spec(s)\n"
                "s.loader.exec_module(m)\n"
                "print(m.shared_supervised(), m.shared_service())\n"
                "m.shared_restart()\n")
        run = lambda: subprocess.run([sys.executable, "-c", snip, os.path.join(BIN, "fleet-credsep.py")],
                                     env=self.env, capture_output=True, text=True, timeout=30)
        os.makedirs(os.path.join(self.d, "db"), exist_ok=True)
        self.wj(os.path.join(self.d, "db", "state.json"), {"children": {"cred-proxy-shared": {"status": "supervised"}}})
        r = run()
        self.assertEqual(r.stdout.split(), ["True", "False"], r.stderr)
        self.assertFalse(os.path.exists(self.svc), "a definition beside the daemon's child")
        self.assertTrue(os.path.exists(os.path.join(self.lib, ".restart")), r.stderr)
        first = open(os.path.join(self.lib, ".restart")).read()
        time.sleep(0.01)
        run()
        self.assertNotEqual(open(os.path.join(self.lib, ".restart")).read(), first, "a second restart wrote nothing new")
        # launchd's definition still installed: credsep's own road, as before
        with open(self.svc, "w") as f:
            f.write("legacy\n")
        r = run()
        self.assertEqual(r.stdout.split()[0], "False", r.stderr)

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
    """issues #2688, #2774: a managed login's ~/.claude/fleet is on the doctor —
    PASS only when it is a tree LINKED to the release; an own copy (even of the
    same sha), one behind, or an unreadable one WARNs (never FAIL: no rollback);
    no row without one."""
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
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: ~/.claude/fleet at %s but its own copy \(link\), "
                                   r"not linked to the runtime" % V1[:12])
        self.wj(os.path.join(vers, V1, ".fleet-linked"), {"sha": V1, "root": self.root, "at": 1})
        r = self.cmd("doctor")
        self.assertRegex(r.stdout, r"PASS\s+install\s+alice: ~/.claude/fleet linked to the release " + V1[:12])
        # linked, but into another root: not the machine's
        self.wj(os.path.join(vers, V1, ".fleet-linked"), {"sha": V1, "root": "/elsewhere", "at": 1})
        self.assertRegex(self.cmd("doctor").stdout, r"WARN\s+install\s+alice")
        os.remove(live)
        os.symlink(os.path.join(vers, V2), live)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: ~/.claude/fleet at %s \(link\), the release is %s"
                         % (V2[:12], V1[:12]))
        self.assertIn("fleet-node-update.py' follow alice", r.stdout)
        # the plain directory a bootstrap left behind, no git: unreadable, still a WARN
        os.remove(live)
        os.makedirs(live)
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: ~/.claude/fleet \(plain directory\) — its version is unreadable")


class L_ClientShell(Sandbox):
    """issue #2702: ONE `shell` row over the taken-over logins only — PASS when none
    carries the person's client here, WARN (never FAIL: no rollback) naming the login + the retire command. A
    home the doctor can read is read NOW (issue #2991: the last sweep's word goes stale once a retire ran); one
    it cannot read keeps the last sweep's record, marked with its time."""
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
        st["sweep"] = {"clientshell": [{"login": "alice", "cache": True, "zshrc": 3}], "last": 1791663924}
        with open(sp, "w") as f:
            json.dump(st, f)
        # alice's home readable and clean: the record is stale, the row reads her home now
        home = os.path.join(self.d, "Users", "alice")
        os.makedirs(home, exist_ok=True)
        with open(os.path.join(home, ".zshrc"), "w") as f:
            f.write("export PATH=x\n")
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+shell\s")
        # a home it cannot read: the record stands, with its time
        os.chmod(home, 0)
        try:
            r = self.cmd("doctor")
        finally:
            os.chmod(home, 0o755)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+shell\s+alice: ~/.cache/claude-fleet/shell · ~/.zshrc 3 hook line\(s\)")
        self.assertIn("fleet-node-shell-retire.sh' --login alice", r.stdout)
        self.assertIn("(read at 2026-10-10T20:25:24Z — this login cannot read that home now)", r.stdout)
        self.assertIn("托管登录 1 个，其余账号不在清单内不扫", r.stdout)
        # read now: one fleet header comment left behind by an older retire counts
        with open(os.path.join(home, ".zshrc"), "w") as f:
            f.write("export PATH=x\n\n# cfguest:shell — claude-fleet helpers: cf, cw\n")
        self.assertRegex(self.cmd("doctor").stdout, r"WARN\s+shell\s+alice: ~/.zshrc 1 hook line\(s\)")
        # a login the record names that is not taken over (an admin) is not the fleet's
        os.remove(os.path.join(self.d, "db", "logins", "alice.env"))
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+shell\s")


class M_FollowInstall(Sandbox):
    """issue #2774 (EPIC #2770 C4; #2714 before it): every managed login's
    ~/.claude/fleet IS the release — a real directory tree whose files link into
    <root>/<sha>/, `$BIN/..` still the login's own dir, logs/ from .shared/,
    under 1 MB — moved WITH the machine: the switch links every login, the
    rollback takes them back, a tick at the release reclaims one pointed at an
    own copy by hand (BREAK-IT managed-login-own-copy) unless an EPIC batch with
    work holds it. The version's apply runs --tree-from <old> --tree-to <new>.
    `release-install` makes it an own copy again (a checkout of one
    `fleet-release:` commit). A retired <root>/<sha> a login still links into is
    not pruned. A client-shell mirror pinned to a version dir follows the link."""
    V0 = "a" * 40

    def setUp(self):
        Sandbox.setUp(self)
        self.A = os.path.join(self.d, "apply.log")
        self.bob = os.path.join(self.d, "Users", "bob")
        os.makedirs(self.bob)
        self.wj(self.env["FLEET_NODE_PASSWD"], {
            "alice": {"uid": os.geteuid(), "gid": os.getegid(), "home": self.home},
            "bob": {"uid": os.geteuid(), "gid": os.getegid(), "home": self.bob}})
        self.wj(os.path.join(self.d, "db", "accounts.json"),
                {"alice": {"managed": True, "since": 1}, "bob": {"managed": True, "since": 1}})
        # alice: install-sync's versions layout, with logs/ in .shared; bob: a plain bootstrap copy
        vers = os.path.join(self.home, ".claude", "fleet.versions")
        os.makedirs(os.path.join(vers, self.V0, "bin"))
        os.makedirs(os.path.join(vers, ".shared", "logs"))
        open(os.path.join(vers, ".shared", "logs", "old.log"), "w").close()
        os.symlink("../.shared/logs", os.path.join(vers, self.V0, "logs"))
        os.symlink(os.path.join(vers, self.V0), self.live("alice"))
        os.makedirs(os.path.join(self.bob, ".claude", "fleet", "bin"))
        os.makedirs(os.path.join(self.bob, ".claude", "fleet", "epic-pages"))

    def homeof(self, who):
        return self.home if who == "alice" else self.bob

    def live(self, who):
        return os.path.join(self.homeof(who), ".claude", "fleet")

    def at(self, who):
        """The release <who>'s install links to, or None."""
        live = self.live(who)
        try:
            m = self.rj(os.path.join(os.path.realpath(live), ".fleet-linked"))
        except (IOError, OSError, ValueError):
            return None
        return m["sha"] if os.path.islink(live) else None

    def applies(self):
        if not os.path.exists(self.A):
            return []
        with open(self.A) as f:
            return f.read().splitlines()

    def assert_linked(self, who, sha):
        live = self.live(who)
        self.assertEqual(self.at(who), sha)
        real = os.path.realpath(live)
        self.assertEqual(os.path.dirname(real), os.path.realpath(live + ".versions"))
        f = os.path.join(live, "bin", "fleet-node-update.py")
        self.assertTrue(os.path.islink(f))
        self.assertEqual(os.readlink(f), os.path.join(self.root, sha, "bin", "fleet-node-update.py"))
        # directories are real: $BIN/.. is the login's dir, not the runtime
        self.assertFalse(os.path.islink(os.path.join(real, "bin")))
        self.assertFalse(os.path.islink(os.path.join(real, "conf", "agent-defaults")))
        self.assertEqual(os.path.realpath(os.path.join(live, "bin", "..")), real)
        with open(os.path.join(live, "conf", "agent-defaults", "MARK")) as fh:
            self.assertEqual(fh.read().strip(), sha)
        self.assert_mod_real(real, sha)
        self.assertFalse(os.path.lexists(os.path.join(real, ".release")))
        self.assertFalse(os.path.lexists(os.path.join(real, "tools")))
        size = 0
        for d, _, fs in os.walk(real):
            size += sum(os.lstat(os.path.join(d, n)).st_size for n in fs)
        self.assertLess(size, 1 << 20)

    def assert_mod_real(self, real, sha):
        """issue #2964: nothing under mod/ resolves outside the login's tree —
        Claude Code refuses a plugin file that does ("Path escapes plugin directory")."""
        mod = os.path.join(real, "mod")
        seen = 0
        for d, _, fs in os.walk(mod):
            for n in fs:
                q = os.path.join(d, n)
                self.assertTrue(os.path.realpath(q).startswith(os.path.realpath(real) + os.sep),
                                "%s escapes the tree → %s" % (q, os.path.realpath(q)))
                seen += 1
        self.assertGreater(seen, 0)
        with open(os.path.join(mod, "fleet", "hooks", "register.ts")) as fh:
            self.assertEqual(fh.read().strip(), "// " + sha)

    def test_mod_is_copied_and_healed(self):
        """BREAK-IT managed-login-mod-escapes (issue #2964): a new tree copies mod/;
        a tree built before (its mod/ files links into the runtime) is healed in
        place by the next link-tree — the next tick at the release, or `follow`."""
        self.release(V1)
        self.tick(V1)
        real = os.path.realpath(self.live("alice"))
        self.assert_mod_real(real, V1)
        self.assertTrue(os.path.islink(os.path.join(real, "bin", "fleet-node-update.py")))
        # the pre-#2964 shape: every mod file a link into <root>/<sha>
        for rel in (("mod", "fleet", "hooks", "register.ts"), ("mod", "fleet", ".claude-plugin", "plugin.json")):
            q = os.path.join(real, *rel)
            os.remove(q)
            os.symlink(os.path.join(self.root, V1, *rel), q)
        self.daemon_on(V1)
        self.tick(V1)
        self.assertEqual(os.path.realpath(self.live("alice")), real)
        self.assert_mod_real(real, V1)
        self.assertRegex(open(os.path.join(self.env["FLEET_NODE_LOG"], "update.log")).read(),
                         r"install alice: %s → %s · rc 0 · at %s" % (V1[:12], V1[:12], V1[:12]))
        # healed: the next tick runs nothing for it
        n = open(os.path.join(self.env["FLEET_NODE_LOG"], "update.log")).read().count("install alice:")
        self.tick(V1)
        self.assertEqual(open(os.path.join(self.env["FLEET_NODE_LOG"], "update.log")).read().count("install alice:"), n)

    def test_switch_links_every_login(self):
        self.release(V1, apply_log=self.A)
        st = self.tick(V1)
        self.assertEqual(st["phase"], "switched", st)
        for who in ("alice", "bob"):
            self.assert_linked(who, V1)
        # alice's logs/ is the shared one, reached through the login's own dir
        logs = os.path.join(self.live("alice"), "logs")
        self.assertEqual(os.readlink(logs), os.path.join("..", ".shared", "logs"))
        self.assertTrue(os.path.exists(os.path.join(logs, "old.log")))
        # bob's plain copy was adopted: its epic-pages/ moved into .shared
        bv = self.live("bob") + ".versions"
        self.assertTrue(os.path.isdir(os.path.join(bv, ".shared", "epic-pages")))
        self.assertTrue(os.path.isdir(os.path.join(self.live("bob"), "epic-pages")))
        self.assertEqual(open(os.path.join(self.live("alice") + ".versions", ".prev")).read().strip(), self.V0)
        # the version's apply ran in tree mode, once per login
        runs = self.applies()
        self.assertEqual(len(runs), 2, runs)
        a = [r for r in runs if r.split("|")[1] == self.home][0]
        self.assertIn("--tree-from %s --tree-to %s --root %s --from %s --to %s" % (
            os.path.realpath(os.path.join(self.live("alice") + ".versions", self.V0)),
            os.path.join(self.live("alice") + ".versions", V1),
            self.live("alice"), self.V0, V1), a)
        self.assertRegex(open(os.path.join(self.env["FLEET_NODE_LOG"], "update.log")).read(),
                         r"install alice: %s → %s · rc 0 · linked %s → %s" % (self.V0[:12], V1[:12], self.V0[:12], V1[:12]))
        self.daemon_on(V1)
        self.assertEqual(self.tick(V1)["result"], "committed")
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+install\s+alice: ~/.claude/fleet linked to the release")
        # at the release: a tick costs one read, nothing runs
        self.assertEqual(self.tick(V1)["result"], "current")
        self.assertEqual(len(self.applies()), 2)

    def test_rollback_moves_logins_back(self):
        self.install(V1, apply_log=self.A)
        self.release(V2, claude="2.1.9", broken=("claude-",), apply_log=self.A)
        self.tick(V2)
        for who in ("alice", "bob"):
            self.assertEqual(self.at(who), V2)
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "rolled-back")
        for who in ("alice", "bob"):
            self.assert_linked(who, V1)
        self.assertIn("--tree-to %s " % os.path.join(self.live("alice") + ".versions", V1),
                      "".join(r for r in self.applies() if V2 + "|" not in r and "--to " + V1 in r))

    def test_own_copy_is_reclaimed(self):
        """BREAK-IT managed-login-own-copy: pointed back at an own old copy by hand,
        WARN on the doctor, linked again on the next tick — unless a batch holds it
        (only with the hold turned on, #2934)."""
        self.install(V1)
        own = os.path.join(self.live("alice") + ".versions", "own-old")
        os.makedirs(os.path.join(own, "bin"))
        os.remove(self.live("alice"))
        os.symlink(own, self.live("alice"))
        r = self.cmd("doctor")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertRegex(r.stdout, r"WARN\s+install\s+alice: .*the updater links it to the runtime every tick")
        lib = os.path.join(self.d, "lib.sh")
        with open(lib, "w") as f:
            f.write('fleet_epic_holding() { echo "active epic=2770"; return 0; }\n')
        st = self.tick(V1, FLEET_NODE_UPDATE_LIB=lib, FLEET_EPIC_HOLD_CAP_SECS="7200")
        self.assertIn("install alice: not linked to %s yet — an EPIC batch with work" % V1[:12], st["reason"])
        self.assertEqual(os.path.realpath(self.live("alice")), os.path.realpath(own))
        self.tick(V1)
        self.assert_linked("alice", V1)
        self.assertRegex(self.cmd("doctor").stdout, r"PASS\s+install\s+alice")

    def test_follow_now_and_off(self):
        self.release(V1)
        self.tick(V1, FLEET_NODE_UPDATE_FOLLOW="0")
        self.assertIsNone(self.at("alice"), "moved with FLEET_NODE_UPDATE_FOLLOW=0")
        # `account adopt`'s kick: at once
        r = self.cmd("follow", "alice")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assert_linked("alice", V1)
        self.assertIsNone(self.at("bob"))
        # no install at all: nothing to follow
        shutil.rmtree(os.path.join(self.bob, ".claude"))
        self.daemon_on(V1)
        self.tick(V1)
        self.assertFalse(os.path.lexists(self.live("bob")))

    def test_release_install_is_an_own_copy(self):
        self.install(V1)
        r = self.cmd("release-install", "alice")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        live = self.live("alice")
        real = os.path.realpath(live)
        self.assertEqual(os.path.basename(real), V1 + "-own")
        f = os.path.join(live, "bin", "fleet-node-update.py")
        self.assertFalse(os.path.islink(f))
        self.assertTrue(filecmp.cmp(f, UPD, shallow=False))
        self.assertTrue(os.path.isdir(os.path.join(real, ".git")))
        sub = subprocess.run(["git", "-C", live, "log", "-1", "--format=%s"], capture_output=True, text=True)
        self.assertEqual(sub.stdout.strip(), "fleet-release: %s seq=0" % V1)
        self.assertTrue(os.path.exists(os.path.join(live, "logs", "old.log")))
        self.assertEqual(self.cmd("release-install", "alice").stdout.strip(),
                         "own copy already — ~/.claude/fleet is not linked to a runtime")

    def test_linked_release_is_not_pruned(self):
        keep = {"FLEET_NODE_UPDATE_KEEP_SECS": "0", "FLEET_INSTALL_VERSIONS_KEEP_SECS": "0"}
        for sha in (V1, V2, V3):
            self.release(sha)
            self.assertEqual(self.tick(sha, **keep)["phase"], "switched")
            self.daemon_on(sha)
            self.assertEqual(self.tick(sha, **keep)["result"], "committed")
            if sha == V2:
                # V1 retired, .prev is V2's — but the logins' .prev tree still links V1
                self.assertEqual(self.state()["retired"].get(V1) is not None, True)
                self.assertTrue(os.path.isdir(os.path.join(self.root, V1)), "pruned while a login links it")
        self.assertFalse(os.path.isdir(os.path.join(self.root, V1)), "kept after no login links it")
        self.assertFalse(os.path.lexists(os.path.join(self.live("alice") + ".versions", V1)))

    def test_pinned_shell_mirror_follows_the_link(self):
        sb = os.path.join(self.home, ".cache", "claude-fleet", "shell", "bin")
        sc = os.path.join(self.home, ".cache", "claude-fleet", "shell", "conf")
        os.makedirs(sb)
        os.makedirs(sc)
        vers = os.path.join(self.home, ".claude", "fleet.versions")
        os.symlink(os.path.join(vers, self.V0, "bin", "fleet-shell.sh"), os.path.join(sb, "fleet-shell.sh"))
        os.symlink(os.path.join(vers, self.V0, "conf", "fleet-palette.conf"), os.path.join(sc, "fleet-palette.conf"))
        os.symlink("/elsewhere/x.sh", os.path.join(sb, "x.sh"))
        self.install(V1)
        live = self.live("alice")
        self.assertEqual(os.readlink(os.path.join(sb, "fleet-shell.sh")), os.path.join(live, "bin", "fleet-shell.sh"))
        self.assertEqual(os.readlink(os.path.join(sc, "fleet-palette.conf")),
                         os.path.join(live, "conf", "fleet-palette.conf"))
        self.assertEqual(os.readlink(os.path.join(sb, "x.sh")), "/elsewhere/x.sh")


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


class L_ResumableFetch(Sandbox):
    """issue #2701: a ccquota that resumes is asked for the pinned artifacts only,
    into <root>/.fetch seeded with what the machine has; a cut fetch keeps its
    bytes and is not backed off — the next tick finishes it."""

    def setUp(self):
        Sandbox.setUp(self)
        cq = os.path.join(self.d, "ccquota-resume")
        with open(cq, "w") as f:
            f.write(FAKE_CCQUOTA_RESUME)
        os.chmod(cq, 0o755)
        self.env["FLEET_NODE_CCQUOTA"] = cq

    def test_pinned_cached_and_resumed(self):
        cache = os.path.join(self.root, ".fetch")
        self.release(V1)
        self.assertEqual(self.tick(V1)["phase"], "switched")
        with open(os.path.join(self.rel, ".argv")) as f:
            argv = f.read().split()
        for flag in ("--artifacts", "--pinned", "--cache", "--progress"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--platform") + 1], "darwin-arm64")
        self.assertEqual(argv[argv.index("--cache") + 1], cache)
        self.assertFalse(os.path.exists(cache), "the fetch cache outlived a whole stage")
        self.daemon_on(V1)
        self.assertEqual(self.tick(V1)["result"], "committed")

        # V2 pins the same claude / codex / tmux: the cache starts with them
        self.release(V2)
        open(os.path.join(self.rel, ".cut"), "w").close()
        st = self.tick(V2)
        self.assertEqual(st["result"], "failed")
        self.assertNotIn(V2, st.get("failed") or {}, "a fetch that moved was backed off")
        with open(os.path.join(self.rel, ".seeded")) as f:
            seeded = f.read().split()
        man = self.rj(os.path.join(self.root, "current", ".release", "manifest.json"))
        for a in man["artifacts"]:
            self.assertIn(a["sha256"], seeded, "%s was not seeded into the fetch cache" % a["name"])
        self.assertTrue(any(n.endswith(".part") for n in os.listdir(cache)), "the cut fetch's bytes are gone")
        out = self.cmd("status").stdout
        self.assertIn("fetch   claude: 0.0 MB / 0.2 MB", out)

        st = self.tick(V2)   # no FLEET_NODE_UPDATE_RETRY: a backoff would say `backoff`
        self.assertEqual(st["phase"], "switched", st)
        self.assertEqual(os.path.basename(os.readlink(os.path.join(self.root, "current"))), V2)

    def test_old_ccquota_keeps_the_old_argv(self):
        self.env["FLEET_NODE_CCQUOTA"] = os.path.join(self.d, "ccquota")
        self.release(V1)
        self.assertEqual(self.tick(V1)["phase"], "switched")
        self.assertFalse(os.path.exists(os.path.join(self.root, ".fetch")))


class Q_AdminAgent(Sandbox):
    """issue #3034: a login NOT taken over (an admin — its agent is the machine's
    admin node, the one that opens new logins) whose ccquota agent the credential
    launcher starts runs the RELEASE's ccquota: its credsep meta.json's
    agent_argv[0] → <current>/bin/ccquota and the agent kickstarted on every
    switch and rollback (once per release, never per tick); a taken-over login's
    record is left alone; the doctor's `admin-agent` row WARNs while it runs an
    own older binary or was not restarted, PASSes after, and is never a FAIL."""

    def setUp(self):
        Sandbox.setUp(self)
        self.lc = os.path.join(self.d, "launchctl.log")
        fake = os.path.join(self.d, "launchctl")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\necho "$*" >> %s\n' % self.lc)
        os.chmod(fake, 0o755)
        self.env["FLEET_NODE_LAUNCHCTL"] = fake
        self.own = os.path.join(self.d, "Users", "verky", ".local", "bin", "ccquota")
        os.makedirs(os.path.dirname(self.own))
        with open(self.own, "w") as f:
            f.write("#!/bin/sh\necho ccquota prod-e715029\n")
        os.chmod(self.own, 0o755)
        self.meta("verky", self.own)
        self.meta("alice", self.own)     # taken over: the machine program's tenant

    def meta(self, login, prog):
        d = os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], login)
        if not os.path.isdir(d):
            os.makedirs(d)
        mp = os.path.join(d, "meta.json")
        self.wj(mp, {"login": login, "agent": {"kind": "launchd-system", "path": "/x.plist",
                                               "label": "com.ccquota.agent.%s" % login},
                     "agent_argv": [prog, "agent", "--state", "/s"], "path": "/usr/bin:/bin"})
        os.chmod(mp, 0o600)

    def argv0(self, login):
        return self.rj(os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], login, "meta.json"))["agent_argv"][0]

    def kicks(self):
        try:
            return [l.strip() for l in open(self.lc) if "kickstart" in l]
        except IOError:
            return []

    def rows(self):
        r = self.cmd("doctor")
        return [l for l in r.stdout.splitlines() if "admin-agent" in l]

    def test_follows_switch_and_rollback(self):
        cq = os.path.join(self.root, "current", "bin", "ccquota")
        self.install(V1)
        self.assertEqual(self.argv0("verky"), cq)
        self.assertEqual(self.argv0("alice"), self.own)            # a tenant is never touched
        self.assertEqual(self.kicks(), ["kickstart -k system/com.ccquota.agent.verky"])
        self.assertEqual(oct(os.stat(os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], "verky", "meta.json")).st_mode
                             & 0o777), "0o600")
        rows = self.rows()
        self.assertEqual(len(rows), 1, rows)
        self.assertIn("PASS", rows[0])
        self.assertIn(V1[:12], rows[0])
        self.tick(V1)                                              # at the release: no second restart
        self.assertEqual(len(self.kicks()), 1)
        # a new release: the agent restarts onto it with the switch
        self.release(V2)
        self.assertEqual(self.tick(V2)["phase"], "switched")
        self.assertEqual(len(self.kicks()), 2)
        self.assertEqual(self.state()["admin_agents"]["verky"]["sha"], V2)
        # a release whose claude fails the doctor rolls back — the agent with it
        V3 = "3" * 40
        self.daemon_on(V2)
        self.assertEqual(self.tick(V2)["result"], "committed")
        self.release(V3, claude="2.1.9", broken=("claude-",))
        self.tick(V3)
        self.daemon_on(V3)
        self.assertEqual(self.tick(V3)["result"], "rolled-back")
        self.assertEqual(self.current(), V2)
        self.assertEqual(len(self.kicks()), 4)                     # onto V3, back onto V2
        self.assertEqual(self.state()["admin_agents"]["verky"]["sha"], V2)

    def test_own_old_binary_is_warned_then_repointed(self):
        self.install(V1)
        self.meta("verky", self.own)                               # credsep install / a hand put it back
        rows = self.rows()
        self.assertTrue(rows and "WARN" in rows[0] and "prod-e715029" in rows[0], rows)
        self.assertFalse(any("FAIL" in l and "admin-agent" in l for l in self.cmd("doctor").stdout.splitlines()))
        self.tick(V1)
        self.assertEqual(self.argv0("verky"), os.path.join(self.root, "current", "bin", "ccquota"))
        self.assertEqual(len(self.kicks()), 2)
        self.assertIn("PASS", self.rows()[0])

    def test_no_admin_agent_no_row(self):
        shutil.rmtree(os.path.join(self.env["FLEET_CREDSEP_ROOT_BASE"], "verky"))
        self.install(V1)
        self.assertEqual(self.kicks(), [])
        self.assertEqual(self.rows(), [])


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
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-torn-read":
        # BREAK-IT node-update-stale-fail (issue #2906): an outlived torn read rolls nothing back
        unittest.main(argv=[sys.argv[0], "O_TornReadPast"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-helpers":
        # BREAK-IT codex-helper-missing (issue #3017): staged, linked, completed
        unittest.main(argv=[sys.argv[0], "P_Helpers"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-credsep":
        # BREAK-IT credsep-stale-after-switch: the supervised case, switch + rollback
        unittest.main(argv=[sys.argv[0], "I_Credsep.test_supervised_proxy_follows_switch_and_rollback"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-admin-agent":
        # BREAK-IT admin-agent-stale (issue #3034): an admin's own agent follows the release
        unittest.main(argv=[sys.argv[0], "Q_AdminAgent"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-fetch":
        # BREAK-IT release-fetch-slow: the updater half
        unittest.main(argv=[sys.argv[0], "L_ResumableFetch"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-login-install":
        # BREAK-IT managed-login-install-stale: the doctor half
        unittest.main(argv=[sys.argv[0], "K_LoginInstall"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-login-own-copy":
        # BREAK-IT managed-login-own-copy (issue #2774): reclaimed; moved and rolled back with the machine
        unittest.main(argv=[sys.argv[0], "M_FollowInstall.test_own_copy_is_reclaimed",
                            "M_FollowInstall.test_switch_links_every_login",
                            "M_FollowInstall.test_rollback_moves_logins_back"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-login-mod":
        # BREAK-IT managed-login-mod-escapes (issue #2964): the mod is copied, an old tree healed
        unittest.main(argv=[sys.argv[0], "M_FollowInstall.test_mod_is_copied_and_healed",
                            "M_FollowInstall.test_switch_links_every_login"], verbosity=1)
    if len(sys.argv) > 1 and sys.argv[1] == "--drill-login-follow":
        # BREAK-IT managed-login-install-predates: the updater moves a login whose
        # own install-sync cannot (issue #2714)
        unittest.main(argv=[sys.argv[0], "M_FollowInstall"], verbosity=1)
    unittest.main(verbosity=2)
