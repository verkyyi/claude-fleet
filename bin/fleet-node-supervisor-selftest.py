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
  G  the default (no table) is machine-level only: collect / base-sync deferred
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
        self.assertEqual(names, ["diskguard", "memguard", "orphans", "collect", "base-sync"])
        by = {x["name"]: x for x in t["tasks"]}
        self.assertEqual(by["collect"]["scope"], "account")
        self.assertEqual(by["base-sync"]["scope"], "account")
        self.assertEqual(by["diskguard"]["env"]["FLEET_ORPHAN_CPU_PCT"], "0", "orphans would run twice")
        self.assertEqual(by["orphans"]["env"]["FLEET_ORPHAN_ALL_USERS"], "1")
        for x in t["tasks"]:
            for a in x.get("cmd", []):
                if a.endswith(".sh"):
                    self.assertTrue(a.startswith(os.path.join(self.d, "rt", "bin")), a)
                    self.assertTrue(os.path.exists(os.path.join(BIN, os.path.basename(a))), a)
        self.assertEqual([c["name"] for c in t["children"]], ["cred-proxy-shared", "node-agent"])
        # the status of the default table on an empty machine is readable without root
        r = subprocess.run([sys.executable, SUP, "status"], env=e, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not installed", r.stdout)
        self.assertIn("deferred", r.stdout)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
