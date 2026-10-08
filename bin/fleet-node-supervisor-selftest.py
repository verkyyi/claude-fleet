#!/usr/bin/env python3
"""fleet-node-supervisor-selftest.py — the machine daemon in a sandbox (issue #2331).

Driven by bin/fleet-node-supervisor-selftest.sh. Every path goes through the
FLEET_NODE_* seams; nothing touches /Library, /var or a real login.

  A  a child killed is restarted within its backoff; quick deaths double it, capped
  B  every task runs as ONE copy (an overlong task is skipped, not doubled; a hand
     `tick` beside a running supervisor refuses)
  C  leftover plists move to the attic, come back with `attic restore`, purge after N days;
     a fleet plist expected.json does not name is reported, never moved
  D  the supervisor restarted (kill -9) keeps its state and ADOPTS a live child
  E  status: one line per item; --check 2 not installed · 0 ok · 1 stale/down
  F  root runs only a root-owned, non-writable script; the built-in table's shape
  G  the default (no table) machine half: diskguard / memguard / orphans
  H  the account half (#2332): the table is the launchd templates; a task runs as
     its account (uid, HOME, USER, FLEET_CONF_DIR, its own log); one account's
     failure never touches another's; `account adopt` boots the old services out
     into the attic and `account release` puts them back, one command each; a
     service that will not unload puts every one back; expected.json narrows who runs
"""
import importlib.util
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
SUP = os.path.join(BIN, "fleet-node-supervisor.py")
spec = importlib.util.spec_from_file_location("fns", SUP)
fns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fns)


def until(secs, fn, step=0.05):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return fn()


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fns.")
        self.env = dict(os.environ)
        for k in list(self.env):
            if k.startswith("FLEET_NODE_"):
                del self.env[k]
        self.env.update({
            "FLEET_NODE_STATE": os.path.join(self.d, "db"),
            "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_RUNTIME": os.path.join(self.d, "rt"),
            "FLEET_NODE_DAEMON_DIR": os.path.join(self.d, "LaunchDaemons"),
            "FLEET_NODE_USERS": os.path.join(self.d, "Users"),
            "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_TICK": "0.1",
            "FLEET_NODE_LAUNCHCTL": "",
            "FLEET_NODE_TEST": "1",
        })
        os.makedirs(self.env["FLEET_NODE_DAEMON_DIR"])
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        st = self.state()
        for cs in (st.get("children") or {}).values():
            if cs.get("pid"):
                try:
                    os.kill(cs["pid"], signal.SIGKILL)
                except OSError:
                    pass
        shutil.rmtree(self.d, ignore_errors=True)

    def table(self, children=(), tasks=()):
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump({"children": list(children), "tasks": list(tasks)}, f)

    def script(self, name, body):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write("#!/bin/bash\n" + body)
        os.chmod(p, 0o755)
        return p

    def run_sup(self, *args, **kw):
        e = dict(self.env, **kw.pop("env", {}))
        return subprocess.run([sys.executable, SUP] + list(args), env=e, capture_output=True,
                              text=True, timeout=60)

    def start(self, **extra):
        e = dict(self.env, **extra)
        p = subprocess.Popen([sys.executable, SUP, "run"], env=e, stdout=subprocess.DEVNULL,
                             stderr=open(os.path.join(self.d, "sup.err"), "a"))
        self.procs.append(p)
        return p

    def state(self):
        return fns.read_json(os.path.join(self.d, "db", "state.json"), {})

    def child(self, name):
        return (self.state().get("children") or {}).get(name) or {}

    def task(self, name):
        return (self.state().get("tasks") or {}).get(name) or {}


class A_ChildRestart(Sandbox):
    def test_killed_child_comes_back_with_backoff(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}])
        self.start(FLEET_NODE_BACKOFF_RESET="30", FLEET_NODE_BACKOFF_MAX="2")
        pid1 = until(10, lambda: self.child("c").get("pid"))
        self.assertTrue(pid1, "the child never started")
        os.kill(pid1, signal.SIGKILL)
        t0 = time.time()
        pid2 = until(10, lambda: (self.child("c").get("pid") or 0) not in (0, pid1) and self.child("c")["pid"])
        self.assertTrue(pid2, "the killed child was not restarted")
        self.assertLess(time.time() - t0, 1 + 2 + 1.5, "restart took longer than the first backoff")
        c = self.child("c")
        self.assertEqual(c["restarts"], 1)
        self.assertEqual(c["fails"], 1)
        # quick deaths again: backoff doubles, capped at BACKOFF_MAX
        os.kill(pid2, signal.SIGKILL)
        until(10, lambda: self.child("c").get("fails") == 2)
        c = self.child("c")
        self.assertAlmostEqual(c["next_start"] - c["last_exit"], 2, delta=0.01)
        pid3 = until(10, lambda: (self.child("c").get("pid") or 0) not in (0, pid2) and self.child("c")["pid"])
        self.assertTrue(pid3)
        os.kill(pid3, signal.SIGKILL)
        until(10, lambda: self.child("c").get("fails") == 3)
        c = self.child("c")
        self.assertAlmostEqual(c["next_start"] - c["last_exit"], 2, delta=0.01, msg="backoff not capped")

    def test_legacy_daemon_owns_it(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"], "legacy": "com.claude-fleet.x"}])
        open(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.x.plist"), "w").close()
        self.start()
        until(5, lambda: self.child("c").get("status"))
        time.sleep(0.5)
        self.assertEqual(self.child("c").get("status"), "legacy")
        self.assertFalse(self.child("c").get("pid"), "started a second copy beside the legacy daemon")
        self.assertIn("legacy", self.run_sup("status").stdout)

    def test_sigterm_stops_children(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}])
        p = self.start()
        pid = until(10, lambda: self.child("c").get("pid"))
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=15)
        self.assertFalse(fns.pid_alive(pid), "a stopped supervisor left its child running")


class B_OneCopy(Sandbox):
    def test_overlong_task_is_not_doubled(self):
        mark = os.path.join(self.d, "inflight")
        dup = os.path.join(self.d, "dup")
        sh = self.script("t.sh", 'mkdir "%s" 2>/dev/null || touch "%s"; sleep 1; rmdir "%s"\n' % (mark, dup, mark))
        self.table(tasks=[{"name": "t", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        self.start()
        self.assertTrue(until(15, lambda: (self.task("t").get("runs") or 0) >= 2), "the task never ran twice")
        self.assertFalse(os.path.exists(dup), "two copies of one task ran at once")
        self.assertEqual(self.task("t").get("rc") if self.task("t").get("result") != "running" else 0, 0)

    def test_hand_tick_refuses_beside_supervisor(self):
        self.table(tasks=[])
        self.start()
        until(5, lambda: self.state().get("supervisor"))
        r = self.run_sup("tick")
        self.assertEqual(r.returncode, 3, r.stderr)
        # and a second `run` exits at once (one supervisor per machine)
        r2 = subprocess.run([sys.executable, SUP, "run"], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r2.returncode, 3)

    def test_tick_runs_due_tasks_and_records(self):
        sh = self.script("ok.sh", "exit 0\n")
        bad = self.script("bad.sh", "exit 7\n")
        self.table(tasks=[{"name": "ok", "cmd": ["/bin/bash", sh]}, {"name": "bad", "cmd": ["/bin/bash", bad]}])
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertEqual(self.task("ok")["result"], "ok")
        self.assertEqual(self.task("bad")["result"], "failed")
        self.assertEqual(self.task("bad")["rc"], 7)
        # not due again: a second tick does not rerun
        self.run_sup("tick")
        self.assertEqual(self.task("ok")["runs"], 1)

    def test_timeout_kills(self):
        sh = self.script("hang.sh", "sleep 60\n")
        self.table(tasks=[{"name": "h", "every": 100, "timeout": 0.5, "cmd": ["/bin/bash", sh]}])
        self.start()
        self.assertTrue(until(10, lambda: self.task("h").get("result") == "timeout"))


class C_Sweep(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.la = os.path.join(self.d, "Users", "alice", "Library", "LaunchAgents")
        os.makedirs(self.la)
        self.table()

    def touch(self, d, n, body=b"x"):
        p = os.path.join(d, n)
        with open(p, "wb") as f:
            f.write(body)
        return p

    def test_leftovers_move_and_restore(self):
        live = self.touch(self.dd, "com.claude-fleet.alice.collect.plist")
        bak = self.touch(self.dd, "com.claude-fleet.alice.collect.plist.bak-20260820", b"bak")
        pm = self.touch(self.la, "com.ccquota.agent.plist.pre-move")
        ret = self.touch(self.la, "com.claude-fleet.restore.plist.retired-20260901")
        other = self.touch(self.la, "com.apple.something.plist.bak")
        os.chmod(pm, 0o640)
        dry = self.run_sup("sweep", "--dry-run")
        self.assertEqual(dry.stdout.count("would move"), 3, dry.stdout)
        self.assertTrue(os.path.exists(bak))
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        for p in (bak, pm, ret):
            self.assertFalse(os.path.exists(p), p)
        for p in (live, other):
            self.assertTrue(os.path.exists(p), p)
        lst = self.run_sup("attic", "list").stdout.splitlines()
        self.assertEqual(len(lst), 3)
        ident = [x.split()[0] for x in lst if "pre-move" in x][0]
        self.assertEqual(self.run_sup("attic", "restore", ident).returncode, 0)
        self.assertTrue(os.path.exists(pm))
        self.assertEqual(os.stat(pm).st_mode & 0o777, 0o640)
        self.assertEqual(len(self.run_sup("attic", "list").stdout.splitlines()), 2)
        self.assertEqual(self.state()["sweep"]["moved"], 3)

    def test_purge_after_days(self):
        self.touch(self.dd, "com.claude-fleet.x.plist.bak")
        self.run_sup("sweep")
        idx_p = os.path.join(self.d, "db", "attic", "index.json")
        idx = json.load(open(idx_p))
        idx[0]["moved"] -= 8 * 86400
        json.dump(idx, open(idx_p, "w"))
        self.assertIn("purged 1", self.run_sup("attic", "purge").stdout)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")
        self.assertFalse(os.path.exists(os.path.dirname(idx[0]["dst"])))

    def test_extra_reported_never_moved(self):
        self.touch(self.dd, "com.claude-fleet.old.collect.plist")
        self.touch(self.dd, "com.claude-fleet.keep.plist")
        json.dump({"labels": ["com.claude-fleet.keep"]}, open(os.path.join(self.d, "db.expected.json"), "w"))
        os.makedirs(os.path.join(self.d, "db"))
        shutil.move(os.path.join(self.d, "db.expected.json"), os.path.join(self.d, "db", "expected.json"))
        r = self.run_sup("sweep")
        self.assertIn("extra (not in expected.json, left in place)", r.stdout)
        self.assertIn("old.collect", r.stdout)
        self.assertNotIn("keep.plist", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(self.dd, "com.claude-fleet.old.collect.plist")))


class D_RestartKeepsState(Sandbox):
    def test_kill9_supervisor_keeps_state_and_adopts(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}],
                   tasks=[{"name": "t", "every": 0.2, "cmd": ["/bin/bash", sh]}])
        p = self.start()
        self.assertTrue(until(10, lambda: (self.task("t").get("runs") or 0) >= 3))
        cpid = self.child("c")["pid"]
        p.kill()
        p.wait()
        runs = self.task("t")["runs"]
        self.assertTrue(fns.pid_alive(cpid), "the child died with the supervisor")
        self.start()
        self.assertTrue(until(10, lambda: (self.state().get("supervisor") or {}).get("starts") == 2))
        self.assertTrue(until(10, lambda: (self.task("t").get("runs") or 0) > runs))
        self.assertGreater(self.task("t")["runs"], runs, "task history lost across the restart")
        time.sleep(0.5)
        self.assertEqual(self.child("c")["pid"], cpid, "the live child was not adopted")
        self.assertEqual(self.child("c").get("restarts") or 0, 0)
        # an adopted child that then dies is still restarted
        os.kill(cpid, signal.SIGKILL)
        self.assertTrue(until(10, lambda: (self.child("c").get("pid") or 0) not in (0, cpid)))


class E_Status(Sandbox):
    def test_check_codes_and_lines(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}, {"name": "later", "cmd": [], "note": "C5"}],
                   tasks=[{"name": "t", "cmd": ["/bin/bash", sh]}, {"name": "acct", "scope": "account", "note": "C4"}])
        self.assertEqual(self.run_sup("status", "--check").returncode, 2)
        p = self.start()
        until(10, lambda: self.task("t").get("result") == "ok")
        r = self.run_sup("status")
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].startswith("supervisor  ok"), r.stdout)
        self.assertTrue(any(l.startswith("child  c ") and "running pid" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("child  later") and "not yet (C5)" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("task   t ") and " ok rc=0" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("task   acct") and "deferred" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("sweep") for l in lines), r.stdout)
        self.assertEqual(self.run_sup("status", "--check").returncode, 0)
        js = json.loads(self.run_sup("status", "--json").stdout)
        self.assertEqual(js["health"], 0)
        p.kill()
        p.wait()
        r = self.run_sup("status", "--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("DOWN", r.stdout)


class F_Trust(Sandbox):
    def test_root_trust(self):
        sh = self.script("w.sh", "exit 0\n")
        self.assertTrue(fns.trusted(sh, as_root=False))
        self.assertFalse(fns.trusted(sh, as_root=True), "a login-owned script passed the root check")
        self.assertFalse(fns.trusted(os.path.join(self.d, "nope"), as_root=False))
        self.assertTrue(fns.trusted("/bin/sh", as_root=True))

    def test_install_writes_plist(self):
        os.makedirs(os.path.join(self.d, "rt", "bin"))
        shutil.copy(SUP, os.path.join(self.d, "rt", "bin", "fleet-node-supervisor.py"))
        r = self.run_sup("install")
        self.assertEqual(r.returncode, 0, r.stderr)
        import plistlib
        pl = plistlib.load(open(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.node.plist"), "rb"))
        self.assertEqual(pl["Label"], "com.claude-fleet.node")
        self.assertTrue(pl["KeepAlive"])
        self.assertEqual(pl["ProgramArguments"][-1], "run")
        self.assertTrue(pl["ProgramArguments"][2].startswith(os.path.join(self.d, "rt")))
        self.assertFalse(pl["StandardErrorPath"].startswith("/Users/"))
        self.assertEqual(self.run_sup("uninstall").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.node.plist")))


class G_DefaultTable(Sandbox):
    def test_default_table(self):
        e = dict(self.env)
        del e["FLEET_NODE_TABLE"]
        os.environ.update({k: v for k, v in e.items() if k.startswith("FLEET_NODE_")})
        try:
            t = fns.default_table(fns.Paths())
        finally:
            for k in list(os.environ):
                if k.startswith("FLEET_NODE_"):
                    del os.environ[k]
        names = [x["name"] for x in t["tasks"]]
        self.assertEqual(names, ["diskguard", "memguard", "orphans", "update"])
        by = {x["name"]: x for x in t["tasks"]}
        self.assertIsNone(t["account"], "the account table is the runtime's templates")
        self.assertEqual(by["diskguard"]["env"]["FLEET_ORPHAN_CPU_PCT"], "0", "orphans would run twice")
        self.assertEqual(by["orphans"]["env"]["FLEET_ORPHAN_ALL_USERS"], "1")
        for x in t["tasks"]:
            for a in x.get("cmd", []):
                if a.endswith(".sh") or a.endswith(".py"):
                    self.assertTrue(a.startswith(os.path.join(self.d, "rt", "bin")), a)
                    self.assertTrue(os.path.exists(os.path.join(BIN, os.path.basename(a))), a)
        self.assertEqual([c["name"] for c in t["children"]], ["cred-proxy-shared", "node-agent"])
        # the status of the default table on an empty machine is readable without root
        r = subprocess.run([sys.executable, SUP, "status"], env=e, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not installed", r.stdout)
        # C5 (#2333): the one node program, from the root runtime, waiting until
        # the machine has its token and its logins directory.
        na = t["children"][1]
        self.assertEqual(na["cmd"][0], os.path.join(self.d, "rt", "bin", "ccquota"))
        self.assertEqual(na["cmd"][1:3], ["agent", "--machine"])
        self.assertIn("node-agent", r.stdout)
        self.assertIn("waiting", r.stdout)
        self.assertIn("machine.env", r.stdout)
        self.assertIn(os.path.join("logins", "*.env"), r.stdout, "an empty logins/ must not count (#2421)")

    def test_all_users_orphans(self):
        dg = open(os.path.join(BIN, "fleet-diskguard.sh")).read()
        self.assertIn('[ "${FLEET_ORPHAN_ALL_USERS:-0}" = 1 ] && me=\'*\'', dg)
        self.assertIn('if (me!="*" && $3!=me) next;', dg)
        dgp = os.path.join(BIN, "fleet-diskguard.sh")
        self.assertEqual(subprocess.run(["bash", "-n", dgp]).returncode, 0, "fleet-diskguard.sh no longer parses")
        r = subprocess.run(["bash", dgp, "--orphans"], env=dict(os.environ, FLEET_ORPHAN_ALL_USERS="1"),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("syntax error", r.stderr)


FAKE_LC = """#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5
           # slow: launchd still tears it down for <n> more prints (issue #2336)
           if [ -e "$d/slow/$l" ]; then cp "$d/slow/$l" "$d/tearing-$l"; else rm -f "$d/loaded/$l"; fi ;;
  bootstrap) l=$(basename "$3" .plist); [ -e "$d/tearing-$l" ] && exit 5
             # busy: launchd refuses <n> more bootstraps of it (still tearing the old copy down)
             if [ -e "$d/busy/$l" ]; then n=$(cat "$d/busy/$l"); if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$d/busy/$l"; exit 5; fi; fi
             touch "$d/loaded/$l" ;;
  print) l="${2##*/}"
         if [ -e "$d/tearing-$l" ]; then n=$(cat "$d/tearing-$l"); n=$((n - 1))
           if [ "$n" -le 0 ]; then rm -f "$d/tearing-$l" "$d/loaded/$l"; exit 1; fi
           echo "$n" >"$d/tearing-$l"; exit 0; fi
         [ -e "$d/loaded/$l" ] ;;
esac
"""


class H_Accounts(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.lc = os.path.join(self.d, "lc")
        for x in ("loaded", "stuck", "slow", "busy"):
            os.makedirs(os.path.join(self.lc, x))
        lcs = os.path.join(self.d, "launchctl")
        with open(lcs, "w") as f:
            f.write(FAKE_LC)
        os.chmod(lcs, 0o755)
        pw = {}
        for who in ("alice", "bob"):
            home = os.path.join(self.d, "Users", who)
            os.makedirs(os.path.join(home, ".claude", "fleet", "bin"))
            os.makedirs(os.path.join(home, "Library", "LaunchAgents"))
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": home}
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump(pw, f)
        self.env.update({"FLEET_NODE_PASSWD": os.path.join(self.d, "passwd.json"),
                         "FLEET_NODE_LAUNCHCTL": lcs, "FAKE_LC": self.lc,
                         "FLEET_NODE_BOOTOUT_WAIT": "2"})

    def home(self, who):
        return os.path.join(self.d, "Users", who)

    def acct_script(self, who, name, body):
        p = os.path.join(self.home(who), ".claude", "fleet", "bin", name)
        with open(p, "w") as f:
            f.write("#!/bin/bash\n" + body)
        os.chmod(p, 0o755)

    def plist(self, path, label):
        import plistlib
        with open(path, "wb") as f:
            plistlib.dump({"Label": label, "ProgramArguments": ["/bin/true"]}, f)
        open(os.path.join(self.lc, "loaded", label), "w").close()

    def acct_table(self, *units):
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump({"children": [], "tasks": [], "account": list(units)}, f)

    def lclog(self):
        try:
            return open(os.path.join(self.lc, "log")).read()
        except IOError:
            return ""

    def test_table_is_the_templates(self):
        os.makedirs(os.path.join(self.d, "rt"))
        os.symlink(os.path.join(os.path.dirname(BIN), "launchd"), os.path.join(self.d, "rt", "launchd"))
        os.environ.update({k: v for k, v in self.env.items() if k.startswith("FLEET_NODE_")})
        try:
            units = {u["name"]: u for u in fns.account_units(fns.Paths())}
        finally:
            for k in list(os.environ):
                if k.startswith("FLEET_NODE_"):
                    del os.environ[k]
        import glob as g
        tmpl = set(os.path.basename(x)[len("com.claude-fleet."):-len(".plist.tmpl")]
                   for x in g.glob(os.path.join(os.path.dirname(BIN), "launchd", "*.plist.tmpl")))
        self.assertEqual(set(units), tmpl - {"memguard"}, "every template but the machine's is an account unit")
        for need in ("dispatch", "issue-bridge", "pr-refresh", "ledger-watch", "quotawatch", "sleep", "cleanup",
                     "worktree-autoclean", "spinner", "webhook", "collect", "install-sync", "base-sync"):
            self.assertIn(need, units)
        self.assertTrue(units["spinner"].get("keepalive") and units["webhook"].get("keepalive"))
        self.assertEqual(units["issue-bridge"]["every"], 15)
        self.assertEqual(units["install-sync"]["every"], 1800)
        self.assertEqual(units["worktree-autoclean"]["every"], 3600)
        self.assertEqual(units["spinner"]["env"].get("SPIN_INTERVAL"), "0.12")
        self.assertEqual(units["diskguard"]["env"]["FLEET_ORPHAN_CPU_PCT"], "0", "orphans would run twice")
        e = fns.account_entry(units["dispatch"], "alice", (501, 20, "/Users/alice"), "/opt/homebrew")
        self.assertEqual(e["script"], "/Users/alice/.claude/fleet/bin/fleet-dispatch.sh")
        self.assertTrue(e["env"]["PATH"].startswith("/Users/alice/.local/bin:/opt/homebrew/bin"))
        self.assertEqual(e["env"]["FLEET_CONF_DIR"], "/Users/alice/.config/claude-fleet")
        self.assertEqual(e["cmd"][4], "/dev/null")
        self.assertEqual(e["cmd"][5], "/Users/alice/.claude/fleet/logs/dispatch.launchd.log")
        self.assertNotIn("__HOME__", json.dumps(e))

    def test_runs_as_account_and_isolated(self):
        self.acct_script("alice", "probe.sh",
                         'echo "uid=$(id -u) home=$HOME user=$USER conf=$FLEET_CONF_DIR pwd=$(pwd -P) '
                         'path=$PATH acct=$FLEET_NODE_ACCOUNT"\n')
        self.acct_script("bob", "probe.sh", "echo bob-broke >&2; exit 4\n")
        self.acct_script("alice", "keep.sh", "exec sleep 300\n")
        self.acct_table(
            {"name": "probe", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/probe.sh"], "every": 0.2,
             "env": {"PATH": "__HOME__/.local/bin:/usr/bin:/bin"},
             "out": "__HOME__/probe.out", "err": "__HOME__/probe.err"},
            {"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": True})
        for who in ("alice", "bob"):
            r = self.run_sup("account", "adopt", who)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.start()
        out = os.path.join(self.home("alice"), "probe.out")
        self.assertTrue(until(10, lambda: (self.task("alice/probe").get("runs") or 0) >= 3
                              and (self.task("bob/probe").get("runs") or 0) >= 3))
        line = open(out).read().splitlines()[-1]
        h = os.path.realpath(self.home("alice"))
        self.assertIn("uid=%d " % os.getuid(), line)
        self.assertIn("home=%s " % self.home("alice"), line)
        self.assertIn("user=alice ", line)
        self.assertIn("conf=%s/.config/claude-fleet " % self.home("alice"), line)
        self.assertIn("pwd=%s " % h, line)
        self.assertIn("path=%s/.local/bin:" % self.home("alice"), line)
        self.assertIn("acct=alice", line)
        self.assertIn("bob-broke", open(os.path.join(self.home("bob"), "probe.err")).read())
        # one account's failure is its own
        self.assertEqual(self.task("bob/probe")["rc"], 4)
        self.assertEqual(self.task("alice/probe")["result"], "ok")
        self.assertTrue(until(5, lambda: self.child("alice/keep").get("pid")), "alice's KeepAlive unit never started")
        self.assertEqual(self.child("bob/keep").get("status"), "missing %s/.claude/fleet/bin/keep.sh" % self.home("bob"))
        st = self.run_sup("status").stdout
        self.assertIn("account alice             2/2 ok", st)
        self.assertIn("account bob", st)
        self.assertIn("probe failed", st)
        # no root-owned log in a login's directory: the task log is the daemon's own
        self.assertTrue(os.path.exists(os.path.join(self.d, "log", "accounts", "alice.log")))
        # release: our copies stop, the account is no longer run
        kpid = self.child("alice/keep")["pid"]
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(fns.pid_alive(kpid), "release left the account's KeepAlive unit running")
        runs = self.task("alice/probe")["runs"]
        time.sleep(0.8)
        self.assertLessEqual(self.task("alice/probe")["runs"], runs + 1, "a released account still runs")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("account", "manages", "bob").returncode, 0)

    def test_needs_root_for_another_uid(self):
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        pw["carol"] = {"uid": os.getuid() + 1, "gid": os.getgid(), "home": self.home("alice")}
        pw["toor"] = {"uid": 0, "gid": 0, "home": self.home("alice")}
        json.dump(pw, open(self.env["FLEET_NODE_PASSWD"], "w"))
        self.acct_script("alice", "p.sh", "exit 0\n")
        self.acct_table({"name": "p", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/p.sh"], "every": 60})
        for who in ("carol", "toor"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertTrue(self.task("carol/p")["result"].startswith("needs root"))
        self.assertEqual(self.task("toor/p")["result"], "refused — uid 0")
        self.assertFalse(self.task("carol/p").get("runs"))

    def test_adopt_moves_old_services_and_release_restores(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.plist(os.path.join(la, "com.claude-fleet.spinner.plist"), "com.claude-fleet.spinner")
        self.plist(os.path.join(dd, "com.claude-fleet.alice.collect.plist"), "com.claude-fleet.alice.collect")
        self.plist(os.path.join(dd, "com.claude-fleet.bob.collect.plist"), "com.claude-fleet.bob.collect")
        self.plist(os.path.join(dd, "com.claude-fleet.node.plist"), "com.claude-fleet.node")
        os.chmod(os.path.join(la, "com.claude-fleet.spinner.plist"), 0o640)
        self.acct_table()
        self.assertIn("would boot out", self.run_sup("account", "adopt", "alice", "--dry-run").stdout)
        self.assertTrue(os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("3 service(s)", r.stdout)
        self.assertEqual(sorted(os.listdir(la)), [], "a per-account LaunchAgent is still there")
        self.assertFalse(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.bob.collect.plist")), "bob's was touched")
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.node.plist")))
        log = self.lclog()
        self.assertIn("bootout gui/%d/com.claude-fleet.dispatch" % os.getuid(), log)
        self.assertIn("bootout system/com.claude-fleet.alice.collect", log)
        self.assertNotIn("bob", log)
        self.assertEqual(sorted(os.listdir(os.path.join(self.lc, "loaded"))),
                         ["com.claude-fleet.bob.collect", "com.claude-fleet.node"])
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 0)
        lst = self.run_sup("attic", "list").stdout
        self.assertEqual(lst.count("(account alice, kept)"), 3, lst)
        # kept past the attic's days: a purge never takes an adopted account's way back
        idx_p = os.path.join(self.d, "db", "attic", "index.json")
        idx = json.load(open(idx_p))
        for e in idx:
            e["moved"] -= 30 * 86400
        json.dump(idx, open(idx_p, "w"))
        self.assertIn("purged 0", self.run_sup("attic", "purge").stdout)
        # one command back
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("3 service(s) put back", r.stdout)
        self.assertEqual(sorted(os.listdir(la)), ["com.claude-fleet.dispatch.plist", "com.claude-fleet.spinner.plist"])
        self.assertEqual(os.stat(os.path.join(la, "com.claude-fleet.spinner.plist")).st_mode & 0o777, 0o640)
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertIn("bootstrap system %s" % os.path.join(dd, "com.claude-fleet.alice.collect.plist"), self.lclog())
        self.assertIn("com.claude-fleet.dispatch", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_slow_unload_is_waited_for(self):
        # m4 (issue #2336): a KeepAlive daemon is still loaded right after its bootout
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        for u in ("collect", "webhook"):
            self.plist(os.path.join(dd, "com.claude-fleet.alice.%s.plist" % u), "com.claude-fleet.alice.%s" % u)
            open(os.path.join(self.lc, "loaded", "com.claude-fleet.alice.%s" % u), "w").close()
        with open(os.path.join(self.lc, "slow", "com.claude-fleet.alice.webhook"), "w") as f:
            f.write("3\n")
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("did not unload", r.stderr)
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 0)

    def test_put_back_waits_for_the_teardown(self):
        # the put-back's bootstrap of a job launchd is still tearing down is retried
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        for u in ("a-webhook", "b-collect"):
            self.plist(os.path.join(dd, "com.claude-fleet.alice.%s.plist" % u), "com.claude-fleet.alice.%s" % u)
            open(os.path.join(self.lc, "loaded", "com.claude-fleet.alice.%s" % u), "w").close()
        with open(os.path.join(self.lc, "busy", "com.claude-fleet.alice.a-webhook"), "w") as f:
            f.write("2\n")
        open(os.path.join(self.lc, "stuck", "com.claude-fleet.alice.b-collect"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        loaded = os.listdir(os.path.join(self.lc, "loaded"))
        self.assertIn("com.claude-fleet.alice.a-webhook", loaded, "the put-back left the slow one unloaded")

    def test_stuck_service_puts_everything_back(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        for u in ("a-cleanup", "b-dispatch", "c-sleep"):
            self.plist(os.path.join(la, "com.claude-fleet.%s.plist" % u), "com.claude-fleet.%s" % u)
        open(os.path.join(self.lc, "stuck", "com.claude-fleet.b-dispatch"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("did not unload", r.stderr)
        self.assertEqual(len(os.listdir(la)), 3, "a half migration left the account without services")
        self.assertEqual(len(os.listdir(os.path.join(self.lc, "loaded"))), 3, "a booted-out service was not reloaded")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_expected_accounts_narrow(self):
        self.acct_script("alice", "p.sh", "exit 0\n")
        self.acct_script("bob", "p.sh", "exit 0\n")
        self.acct_table({"name": "p", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/p.sh"], "every": 60})
        for who in ("alice", "bob"):
            self.run_sup("account", "adopt", who)
        with open(os.path.join(self.d, "db", "expected.json"), "w") as f:
            json.dump({"accounts": ["alice", {"name": "dave"}]}, f)
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertEqual(self.task("alice/p")["result"], "ok")
        self.assertFalse(self.task("bob/p"), "an account the expected state drops still ran")
        self.assertIn("not in expected.json", self.run_sup("status").stdout)

    # -- the login's own node agent (#2387) -------------------------------------
    def agent_plist(self, who, env, gui=False):
        import plistlib
        if gui:
            path, label = os.path.join(self.home(who), "Library", "LaunchAgents", "com.ccquota.agent.plist"), \
                "com.ccquota.agent"
        else:
            path, label = os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.ccquota.agent.%s.plist" % who), \
                "com.ccquota.agent.%s" % who
        with open(path, "wb") as f:
            plistlib.dump({"Label": label, "ProgramArguments": ["/bin/true"], "EnvironmentVariables": env}, f)
        open(os.path.join(self.lc, "loaded", label), "w").close()
        return path

    def node_env(self, path, body):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o600)

    def login_env(self, who):
        p = os.path.join(self.d, "db", "logins", who + ".env")
        if not os.path.exists(p):
            return None, None
        kv = {}
        for line in open(p):
            if line.strip() and not line.startswith("#"):
                k, _, v = line.rstrip("\n").partition("=")
                kv[k] = v
        return kv, os.stat(p).st_mode & 0o777

    def test_adopt_moves_node_agent_and_release_restores(self):
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1",
                                        "FLEET_CONF_DIR": conf, "PATH": "/usr/bin", "HOME": "/nope"})
        self.node_env(os.path.join(conf, "node.env"),
                      "# x\nCCQUOTA_HUB_URL=https://hub.invalid\nexport CCQUOTA_TOKEN='tok-alice-1'\nFLEET_X=1\n")
        self.agent_plist("bob", {"CCQUOTA_TOKEN": "tok-bob"})
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice", "--dry-run")
        self.assertIn("would boot out system/com.ccquota.agent.alice", r.stdout)
        self.assertIn("logins/alice.env (0600) with CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_CONF_DIR", r.stdout)
        self.assertNotIn("tok-alice", r.stdout + r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None), "a dry run wrote the env")
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("tok-alice", r.stdout + r.stderr, "adopt printed the token")
        kv, mode = self.login_env("alice")
        self.assertEqual(mode, 0o600)
        self.assertEqual(kv, {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1",
                              "FLEET_CONF_DIR": conf, "CCQUOTA_TOKEN": "tok-alice-1"})
        self.assertEqual(os.stat(os.path.join(self.d, "db", "logins")).st_mode & 0o777, 0o700)
        self.assertFalse(os.path.exists(ap), "the old agent is still installed")
        self.assertNotIn("com.ccquota.agent.alice", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertIn("com.ccquota.agent.bob", os.listdir(os.path.join(self.lc, "loaded")), "bob's agent was touched")
        self.assertIn("(account alice, kept)", self.run_sup("attic", "list").stdout)
        # adopting again changes nothing
        self.assertIn("already managed", self.run_sup("account", "adopt", "alice").stdout)
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None), "release left logins/alice.env")
        self.assertTrue(os.path.exists(ap))
        self.assertIn("bootstrap system %s" % ap, self.lclog())
        self.assertIn("com.ccquota.agent.alice", os.listdir(os.path.join(self.lc, "loaded")))

    def test_agent_that_will_not_unload_puts_everything_back(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {"FLEET_CONF_DIR": conf})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-alice\n")
        open(os.path.join(self.lc, "stuck", "com.ccquota.agent.alice"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("did not unload", r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None))
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        self.assertIn("com.claude-fleet.dispatch", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_agent_with_no_token_moves_nothing(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        ap = self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid"})
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no CCQUOTA_TOKEN", r.stderr)
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        self.assertEqual(self.lclog(), "", "something was booted out")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)

    def test_credsep_login_reads_the_store(self):
        cred = os.path.join(self.d, "cred")
        for who, mode in (("alice", "shared"), ("bob", "own")):
            os.makedirs(os.path.join(cred, who))
            json.dump({"login": who, "mode": mode}, open(os.path.join(cred, who, "meta.json"), "w"))
            self.node_env(os.path.join(cred, who, "node.env"), "CCQUOTA_TOKEN=tok-%s\nCCQUOTA_HUB_URL=https://h\n" % who)
            self.agent_plist(who, {"CCQUOTA_FLEET": "1"}, gui=(who == "bob"))
        # the login's own conf dir is not where a separated login's token is
        self.node_env(os.path.join(self.home("alice"), ".config", "claude-fleet", "node.env"), "CCQUOTA_TOKEN=wrong\n")
        self.acct_table()
        e = {"FLEET_CREDSEP_ROOT_BASE": cred, "FLEET_CREDSEP_RUN_BASE": "/run/fc"}
        for who in ("alice", "bob"):
            r = self.run_sup("account", "adopt", who, env=e)
            self.assertEqual(r.returncode, 0, r.stderr)
        kv, _ = self.login_env("alice")
        self.assertEqual(kv["CCQUOTA_TOKEN"], "tok-alice")
        self.assertEqual(kv["CCQUOTA_FLEET_CRED_STORE"], "/run/fc/.shared/ctl.sock")
        kv, _ = self.login_env("bob")
        self.assertEqual(kv["CCQUOTA_FLEET_CRED_STORE"], "/run/fc/bob/ctl.sock")
        self.assertIn("bootout gui/%d/com.ccquota.agent" % os.getuid(), self.lclog())
        self.assertFalse(os.path.exists(os.path.join(self.home("bob"), "Library", "LaunchAgents",
                                                     "com.ccquota.agent.plist")))

    def test_credsep_store_owned_by_the_role_account(self):
        # m4 (issue #2336): the store's node.env is _fleetcred's, not root's —
        # the owner check (forced on here) must take the role account
        import getpass
        cred = os.path.join(self.d, "cred")
        os.makedirs(os.path.join(cred, "alice"))
        json.dump({"login": "alice", "mode": "shared"}, open(os.path.join(cred, "alice", "meta.json"), "w"))
        self.node_env(os.path.join(cred, "alice", "node.env"), "CCQUOTA_TOKEN=tok-alice\n")
        self.agent_plist("alice", {"CCQUOTA_FLEET": "1"})
        self.acct_table()
        e = {"FLEET_CREDSEP_ROOT_BASE": cred, "FLEET_CREDSEP_RUN_BASE": "/run/fc", "FLEET_NODE_OWNER_CHECK": "1",
             "FLEET_CREDSEP_ROLE": "no-such-role-account"}
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(r.returncode, 1, "a store file of an unknown owner was read")
        self.assertIn("no CCQUOTA_TOKEN", r.stderr)
        e["FLEET_CREDSEP_ROLE"] = getpass.getuser()
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice")

    def test_adopted_before_moves_the_agent_left_behind(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-a\n")
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(ap))
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-a")
        self.assertEqual(len(json.load(open(os.path.join(self.d, "db", "accounts.json")))["alice"]["attic"]), 2)
        self.assertEqual(self.run_sup("account", "release", "alice").returncode, 0)
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))

    def test_node_agent_restarts_when_logins_change(self):
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg)
        self.table(children=[{"name": "node-agent", "cmd": [self.script("na.sh", "exec sleep 300\n")],
                              "requires": [lg], "reload": lg}])
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        time.sleep(0.3)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted with nothing changed")
        with open(os.path.join(lg, "alice.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        pid2 = until(10, lambda: (self.child("node-agent").get("pid") or pid) != pid and self.child("node-agent")["pid"])
        self.assertTrue(pid2, "logins/ changed and the node agent kept its old tenants")
        self.assertTrue(until(3, lambda: not fns.pid_alive(pid)), "the old node agent is still running")

    def test_node_agent_waits_for_a_login(self):
        # #2421: an empty logins/ made ccquota exit 1 once a minute (restarts 47);
        # the daemon waits until one <login>.env is in it, and stops it again
        # when the last one goes.
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg)
        self.table(children=[{"name": "node-agent", "cmd": [self.script("na.sh", "exec sleep 300\n")],
                              "requires": [os.path.join(lg, "*.env")], "reload": lg}])
        self.start()
        self.assertTrue(until(10, lambda: self.child("node-agent").get("status") == "waiting"))
        time.sleep(0.5)
        self.assertFalse(self.child("node-agent").get("pid"), "started on an empty logins/")
        self.assertFalse(self.child("node-agent").get("restarts"))
        r = self.run_sup("status")
        self.assertIn("waiting — %s missing" % os.path.join(lg, "*.env"), r.stdout)
        env = os.path.join(lg, "alice.env")
        with open(env, "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid, "a login arrived and the node agent did not start")
        os.unlink(env)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid)), "the last login left and it kept running")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("status") == "waiting"))

    def test_adopt_refuses_unknown(self):
        r = self.run_sup("account", "adopt", "nobody-here")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
