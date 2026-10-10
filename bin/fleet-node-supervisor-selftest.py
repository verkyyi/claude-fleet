#!/usr/bin/env python3
"""fleet-node-supervisor-selftest.py — the machine daemon in a sandbox (issue #2331).

Driven by bin/fleet-node-supervisor-selftest.sh. Every path goes through the
FLEET_NODE_* seams; nothing touches /Library, /var or a real login.

  A  a child killed is restarted within its backoff; quick deaths double it, capped
  B  every task runs as ONE copy (an overlong task is skipped, not doubled; a hand
     `tick` beside a running supervisor refuses)
  C  leftover plists move to the attic, come back with `attic restore`, purge after N days;
     a fleet plist outside expected.json's labels is booted out into the attic
  O  the sweep's removals on a managed machine (#2981): what goes, what stays
     named and why, a unit that will not unload, a running drill holding all of
     it, a legacy child taken over by the running daemon, the client shell
     retired by the sweep itself
  D  the supervisor restarted (kill -9) keeps its state and ADOPTS a live child
  E  status: one line per item; --check 2 not installed · 0 ok · 1 stale/down
  F  root runs only a root-owned, non-writable script; the built-in table's shape
  G  the default (no table) machine half: diskguard / memguard / orphans / shared-dirs
  H  the account half (#2332): the table is the launchd templates; a task runs as
     its account (uid, HOME, USER, FLEET_CONF_DIR, its own log); one account's
     failure never touches another's; `account adopt` boots the old services out
     into the attic and `account release` puts them back, one command each; a
     service that will not unload puts every one back; expected.json narrows who runs;
     a lane the hub refuses is named (status, --check 3) and `adopt --rejoin` renews
     the login's token (issue #2501)
  I  the login-level register (#2525): `service add` (and bin/fleet-service.sh)
     writes a root 0600 entry; the daemon runs it as its login with its credential
     injected, its log in <log>/logins/<login>/; killed → back within 30 s; stop /
     start / restart / rm; `status --json` .services[]; a bad entry is named, never
     run; a login's services/ never restarts the node agent
  J  `service move` (#2528): two fake logins — after the move the entry, its
     paths[] (working + skill dir), its log and its credential are the new login's
     and none is left under the old; it runs as the new login, never both at once;
     a move onto an existing path refuses with nothing changed; `account release`
     of a login with entries left refuses 6 with the move line (--force passes)
  K  agent tasks (#2529): a fake clock at the slot → ONE spawner call with the
     session line (--no-repo --origin hub --print --name <window> --prompt …); a
     spawner failing every time → retried up to the limit, then `failed`, no more
     tries, an alert file; `service run` / `fleet task run --now` → one run at once;
     a done file decides ok vs failed; cron + tz slots; bad entries refused
  L  tenants (#2842): a taken-over login in the admin group or with sudo rules is
     named (`tenants --check` 1, the doctor's FAIL), a clean one passes (0), none
     taken over is no row (2); `account adopt` refuses such a login (5) with nothing
     moved; the daemon's tick writes the reading into state.json and a non-root
     reader's check carries it
"""
import importlib.util
import json
import os
import plistlib
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

    def test_expected_labels_kept_extra_booted_out(self):
        """expected.json's labels stay; a fleet unit outside the expected set goes
        to the attic (issue #2981 — before, report only)."""
        self.touch(self.dd, "com.claude-fleet.old.collect.plist")
        self.touch(self.dd, "com.claude-fleet.keep.plist")
        os.makedirs(os.path.join(self.d, "db"))
        json.dump({"labels": ["com.claude-fleet.keep"]}, open(os.path.join(self.d, "db", "expected.json"), "w"))
        r = self.run_sup("sweep")
        self.assertIn("booted out %s" % os.path.join(self.dd, "com.claude-fleet.old.collect.plist"), r.stdout)
        self.assertNotIn("keep.plist", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.dd, "com.claude-fleet.old.collect.plist")))
        self.assertTrue(os.path.exists(os.path.join(self.dd, "com.claude-fleet.keep.plist")))

    def test_client_shell_only_taken_over_logins(self):
        """issue #2702: a TAKEN-OVER login (logins/<login>.env) still carrying the
        person's client (the shell's cache, a ~/.zshrc hook) is NAMED, never touched;
        the PATH line and a comment are no hook. Anyone not taken over — an admin, a
        local user — is not looked at: neither half names them, handwritten plists
        included."""
        users = os.path.join(self.d, "Users")
        for login in ("alice", "bob", "carol", "verkyyi"):
            os.makedirs(os.path.join(users, login, "Library", "LaunchAgents"), exist_ok=True)
        os.makedirs(os.path.join(users, "alice", ".cache", "claude-fleet", "shell", "bin"))
        with open(os.path.join(users, "bob", ".zshrc"), "w") as f:
            f.write("# >>> claude-fleet (bin/fleet-login-bootstrap.sh, issue #1165) >>>\n"
                    "[[ -r ~/.claude/fleet/shell/cw.zsh ]] && source ~/.claude/fleet/shell/cw.zsh\n"
                    "# <<< claude-fleet <<<\n")
        with open(os.path.join(users, "carol", ".zshrc"), "w") as f:      # no hook
            f.write('export PATH="$HOME/.local/bin:$PATH"  # claude-fleet: x\n'
                    "# source ~/.claude/fleet/shell/fleet-login.zsh\n")
        # verkyyi: an admin, never taken over — a shell, a hook, a hand-written agent
        os.makedirs(os.path.join(users, "verkyyi", ".cache", "claude-fleet", "shell"))
        with open(os.path.join(users, "verkyyi", ".zshrc"), "w") as f:
            f.write("source ~/.claude/fleet/shell/cw.zsh\n")
        for login in ("verkyyi", "alice"):
            with open(os.path.join(users, login, "Library", "LaunchAgents", "com.%s.ddns.plist" % login), "wb") as f:
                plistlib.dump({"Label": "com.%s.ddns" % login,
                               "ProgramArguments": [os.path.join(users, login, "bin", "ddns")]}, f)
        # nothing taken over: nobody is named
        r = self.run_sup("sweep", "--dry-run")
        self.assertNotIn("clientshell", r.stdout)
        self.assertNotIn("handwritten", r.stdout)
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg, exist_ok=True)
        for login in ("alice", "bob", "carol"):
            open(os.path.join(lg, login + ".env"), "w").close()
        r = self.run_sup("sweep")
        self.assertIn("clientshell (left in place): alice: ~/.cache/claude-fleet/shell — ", r.stdout)
        self.assertIn("clientshell (left in place): bob: ~/.zshrc 3 hook line(s)", r.stdout)
        self.assertIn("fleet-node-shell-retire.sh' --login bob", r.stdout)
        self.assertIn("runs as alice", r.stdout)
        self.assertNotIn("carol", r.stdout)
        self.assertNotIn("verkyyi", r.stdout)
        self.assertEqual(sorted(c["login"] for c in self.state()["sweep"]["clientshell"]), ["alice", "bob"])
        self.assertEqual([h["login"] for h in self.state()["sweep"]["handwritten"]], ["alice"])
        st = self.run_sup("status").stdout
        self.assertIn("clientshell alice", st)
        self.assertNotIn("verkyyi", st)
        self.assertTrue(os.path.isdir(os.path.join(users, "alice", ".cache", "claude-fleet", "shell")))   # named, not touched
        # status reads the homes NOW (issue #2991): retired by hand since the sweep,
        # the record still names them, status does not
        shutil.rmtree(os.path.join(users, "alice", ".cache", "claude-fleet", "shell"))
        with open(os.path.join(users, "bob", ".zshrc"), "w") as f:
            f.write('export PATH="$HOME/.local/bin:$PATH"\n')
        self.assertEqual(len(self.state()["sweep"]["clientshell"]), 2)
        st = self.run_sup("status").stdout
        self.assertNotIn("clientshell", st)
        # ...and the fleet's header comments an older retire left behind are the same rule's lines
        with open(os.path.join(users, "bob", ".zshrc"), "a") as f:
            f.write("\n# cfguest:shell — claude-fleet helpers: cf (enter/attach a fleet), cw (worktree + window)\n\n"
                    "# claude-fleet login: banner (+ machine lines from intro.d, e.g. `vnc`), then an SSH login goes "
                    "straight into the fleet\n")
        self.assertIn("clientshell bob          bob: ~/.zshrc 2 hook line(s)", self.run_sup("status").stdout)
        # a home this process cannot read keeps the sweep's reading, marked with its time
        os.chmod(os.path.join(users, "carol"), 0)
        try:
            st = self.run_sup("status").stdout
        finally:
            os.chmod(os.path.join(users, "carol"), 0o755)
        self.assertNotIn("carol", st)          # never named by a sweep: nothing to keep


class O_SweepRemoves(Sandbox):
    """issue #2981: on a managed machine (expected.json) the sweep boots out and
    moves to the attic every fleet unit outside the expected set — a machine unit
    the daemon does not run, a taken-over login's left behind, a gone login's — and a child's old
    LaunchDaemon once the daemon can run that child itself; it leaves named a
    login that is not taken over (adopt is its road), a legacy child that could
    not start, a unit that will not unload, everything while a drill runs; each
    existing login's own credential proxy and keep-labels are expected, and so is
    every unit of an admin login (never taken over, #2842): its agent is the
    machine's admin node, the one that opens a newcomer's login (issue #2997 —
    the sweep had booted com.ccquota.agent.<admin> out on both machines). A managed
    machine's taken-over login carrying the client shell is retired by the sweep
    itself (--if-idle)."""
    def setUp(self):
        Sandbox.setUp(self)
        self.dd = self.env["FLEET_NODE_DAEMON_DIR"]
        users = os.path.join(self.d, "Users")
        pw = {}
        for who in ("alice", "bob", "carol"):
            home = os.path.join(users, who)
            os.makedirs(os.path.join(home, "Library", "LaunchAgents"))
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": home}
        pw["bob"].update(groups=["staff", "admin"], sudo="(ALL) NOPASSWD: ALL")     # the machine's admin
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump(pw, f)
        self.env["FLEET_NODE_PASSWD"] = os.path.join(self.d, "passwd.json")
        os.makedirs(os.path.join(self.d, "db", "logins"))
        open(os.path.join(self.d, "db", "logins", "alice.env"), "w").close()        # alice: taken over
        json.dump({"role": "managed", "version": 0}, open(os.path.join(self.d, "db", "expected.json"), "w"))
        # launchctl: bootout logged; `print` says loaded only for a label in stuck.txt
        self.lclog = os.path.join(self.d, "launchctl.log")
        self.stuck = os.path.join(self.d, "stuck.txt")
        open(self.stuck, "w").close()
        self.env["FLEET_NODE_LAUNCHCTL"] = self.script("launchctl", (
            'echo "$*" >> %s\n'
            '[ "$1" = print ] || exit 0\n'
            'grep -qxF "${2##*/}" %s && exit 0\n'
            'exit 113\n') % (self.lclog, self.stuck))
        self.env["FLEET_NODE_BOOTOUT_WAIT"] = "0.3"
        self.env["FLEET_NODE_SWEEP_HOLD"] = "fns-hold-%d.sh" % os.getpid()
        self.la = {w: os.path.join(users, w, "Library", "LaunchAgents") for w in ("alice", "bob", "carol")}
        ok = self.script("child.sh", "exec sleep 300\n")
        self.table(children=[
            {"name": "c", "cmd": ["/bin/bash", ok], "legacy": "com.claude-fleet.c-legacy"},
            {"name": "w", "cmd": ["/bin/bash", ok], "legacy": "com.claude-fleet.w-legacy",
             "requires": [os.path.join(self.d, "nowhere")]}])

    def plist(self, d, label, **kw):
        p = os.path.join(d, label + ".plist")
        with open(p, "wb") as f:
            plistlib.dump(dict({"Label": label, "ProgramArguments": ["/bin/true"]}, **kw), f)
        return p

    def lay(self):
        dd, la = self.dd, self.la
        return {
            "node": self.plist(dd, "com.claude-fleet.node"),
            "own-proxy": self.plist(dd, "com.claude-fleet.credsep.alice"),
            "gone-proxy": self.plist(dd, "com.claude-fleet.credsep.ghost"),
            "machine": self.plist(dd, "com.claude-fleet.memguard"),
            "kept": self.plist(dd, "com.claude-fleet.mine"),
            "legacy-ok": self.plist(dd, "com.claude-fleet.c-legacy"),
            "legacy-waits": self.plist(dd, "com.claude-fleet.w-legacy"),
            "carol-daemon": self.plist(dd, "com.claude-fleet.carol.collect"),
            "bob-daemon": self.plist(dd, "com.claude-fleet.x", UserName="bob"),
            "bob-agent": self.plist(la["bob"], "com.claude-fleet.dispatch"),
            "bob-agent2": self.plist(la["bob"], "com.ccquota.agent.bob"),
            "bob-own": self.plist(la["bob"], "com.bob.ddns"),
            "alice-agent": self.plist(la["alice"], "com.claude-fleet.spinner"),
            "carol-agent": self.plist(la["carol"], "com.claude-fleet.dispatch"),
        }

    def test_removes_outside_the_expected_set(self):
        with open(os.path.join(self.d, "db", "keep-labels"), "w") as f:
            f.write("# mine\ncom.claude-fleet.mine\n")
        p = self.lay()
        gone = ("gone-proxy", "machine", "legacy-ok", "alice-agent")
        stay = ("node", "own-proxy", "kept", "legacy-waits", "carol-daemon", "bob-own", "carol-agent",
                "bob-daemon", "bob-agent", "bob-agent2")
        dry = self.run_sup("sweep", "--dry-run")
        self.assertEqual(dry.stdout.count("would boot out"), len(gone), dry.stdout)
        for k in p:
            self.assertTrue(os.path.exists(p[k]), "dry run moved %s" % k)
        self.assertFalse(os.path.exists(self.lclog), "dry run called launchctl")
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        for k in gone:
            self.assertFalse(os.path.exists(p[k]), "%s left: %s" % (k, r.stdout))
        for k in stay:
            self.assertTrue(os.path.exists(p[k]), "%s moved: %s" % (k, r.stdout))
        self.assertNotIn("bob", r.stdout)     # the admin's units: expected, never named (#2997)
        self.assertIn("child c runs under com.claude-fleet.node", r.stdout)
        self.assertIn("launchd still runs child w: %s missing" % os.path.join(self.d, "nowhere"), r.stdout)
        self.assertIn("carol is not taken over — sudo fleet-node-supervisor.py account adopt carol", r.stdout)
        calls = open(self.lclog).read()
        uid = os.getuid()
        for t in ("bootout system/com.claude-fleet.memguard", "bootout system/com.claude-fleet.c-legacy",
                  "bootout gui/%d/com.claude-fleet.spinner" % uid):
            self.assertIn(t, calls)
        for t in ("carol", "com.ccquota.agent.bob", "com.claude-fleet.x", "com.claude-fleet.dispatch"):
            self.assertNotIn(t, calls)
        sw = self.state()["sweep"]
        self.assertEqual((sw["removed"], sw["extra"]), (len(gone), 3))
        st = self.run_sup("status").stdout
        self.assertIn("removed %d (total %d) · extra 3 (left in place)" % (len(gone), len(gone)), st)
        self.assertIn("extra  com.claude-fleet.carol.collect", st)
        # the attic keeps them: a restore puts one back
        lst = self.run_sup("attic", "list").stdout.splitlines()
        self.assertEqual(len(lst), len(gone))
        ident = [x.split()[0] for x in lst if "memguard" in x][0]
        self.assertEqual(self.run_sup("attic", "restore", ident).returncode, 0)
        self.assertTrue(os.path.exists(p["machine"]))
        # a second sweep finds only what it leaves named (the restored one goes again)
        r = self.run_sup("sweep")
        self.assertEqual(r.stdout.count("booted out"), 1, r.stdout)

    def test_one_that_will_not_unload_stays(self):
        p = self.plist(self.dd, "com.claude-fleet.memguard")
        with open(self.stuck, "w") as f:
            f.write("com.claude-fleet.memguard\n")
        r = self.run_sup("sweep")
        self.assertTrue(os.path.exists(p))
        self.assertIn("system/com.claude-fleet.memguard did not unload", r.stdout)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_a_running_drill_holds_every_removal(self):
        p = self.lay()
        drill = self.script(self.env["FLEET_NODE_SWEEP_HOLD"], "sleep 30\n")
        hp = subprocess.Popen(["/bin/bash", drill])
        try:
            until(5, lambda: subprocess.run(["pgrep", "-f", drill], capture_output=True).returncode == 0)
            r = self.run_sup("sweep")
            for k in p:
                self.assertTrue(os.path.exists(p[k]), "%s moved under a drill" % k)
            self.assertIn("held: pid %d runs %s" % (hp.pid, self.env["FLEET_NODE_SWEEP_HOLD"]), r.stdout)
            self.assertIn("held: pid %d" % hp.pid, self.run_sup("status").stdout)
        finally:
            hp.kill()
            hp.wait()
        r = self.run_sup("sweep")
        self.assertFalse(os.path.exists(p["alice-agent"]), r.stdout)

    def test_a_command_line_naming_the_drill_holds_nothing(self):
        """issue #2991: only a process RUNNING the drill holds the sweep — an ssh
        remote command, `pgrep -f`, `bash -c '… drill …'` merely name it."""
        p = self.lay()
        name = self.env["FLEET_NODE_SWEEP_HOLD"]
        decoys = [subprocess.Popen(["/bin/sh", "-c", "sleep 30; : %s --help" % name]),
                  subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", name, "--help"]),
                  subprocess.Popen(["/bin/bash", "-c", 'exec -a ssh "$0" -c "import time; time.sleep(30)" mini "$1" --help',
                                   sys.executable, name])]
        try:
            until(5, lambda: subprocess.run(["pgrep", "-f", name], capture_output=True).stdout.count(b"\n") >= 2)
            r = self.run_sup("sweep")
            self.assertNotIn("held", r.stdout)
            self.assertFalse(os.path.exists(p["alice-agent"]), r.stdout)
        finally:
            for d in decoys:
                d.kill()
                d.wait()

    def test_runs_script_rule(self):
        n = "fleet-onboard-drill.sh"
        for cmd in ("/bin/bash /Users/x/.claude/fleet/bin/%s --login t" % n, "/x/bin/%s" % n,
                    "env FOO=1 bash -x /a/%s" % n, "bash -- /a/%s" % n):
            self.assertTrue(fns.runs_script(cmd, n), cmd)
        for cmd in ("ssh mini %s --help" % n, "pgrep -f onboard-drill", "bash -c %s --help" % n,
                    "zsh -lc /a/%s" % n, "grep %s x" % n, "-zsh", "sshd: verkyyi@ttys001 %s" % n,
                    "/bin/bash /a/other.sh %s" % n):
            self.assertFalse(fns.runs_script(cmd, n), cmd)

    def test_legacy_child_taken_over_by_the_running_daemon(self):
        p = self.plist(self.dd, "com.claude-fleet.c-legacy")
        self.start(FLEET_NODE_SWEEP_EVERY="3600")
        until(10, lambda: self.child("c").get("pid"))
        self.assertFalse(os.path.exists(p), "the legacy definition is still installed")
        self.assertEqual(self.child("c").get("status"), "supervised")
        self.assertTrue(fns.pid_alive(self.child("c")["pid"]))
        self.assertEqual(self.child("w").get("status"), "waiting")

    def test_client_shell_retired_by_the_sweep(self):
        rt = os.path.join(self.d, "rt", "bin")
        os.makedirs(rt)
        shutil.copy(os.path.join(BIN, "fleet-node-shell-retire.sh"), rt)
        shutil.copy(SUP, rt)          # the retire script's one rule (shell-hooks, issue #2991)
        home = os.path.join(self.d, "Users", "alice")
        os.makedirs(os.path.join(home, ".cache", "claude-fleet", "shell", "bin"))
        with open(os.path.join(home, ".zshrc"), "w") as f:
            f.write("alias y=yazi\nsource ~/.claude/fleet/shell/cw.zsh\n")
        # carol is not taken over: hers is not the fleet's to touch
        os.makedirs(os.path.join(self.d, "Users", "carol", ".cache", "claude-fleet", "shell"))
        dry = self.run_sup("sweep", "--dry-run")
        self.assertIn("clientshell (would retire): alice", dry.stdout)
        self.assertTrue(os.path.isdir(os.path.join(home, ".cache", "claude-fleet", "shell")))
        r = self.run_sup("sweep")
        self.assertNotIn("clientshell", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(home, ".cache", "claude-fleet", "shell")))
        self.assertEqual(open(os.path.join(home, ".zshrc")).read(), "alias y=yazi\n")
        self.assertEqual(self.state()["sweep"]["clientshell"], [])
        self.assertNotIn("clientshell", self.run_sup("status").stdout)
        self.assertTrue(os.path.isdir(os.path.join(self.d, "Users", "carol", ".cache", "claude-fleet", "shell")))


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
        self.assertEqual(names, ["diskguard", "memguard", "orphans", "shared-dirs", "update"])
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

    def test_forget_stops_tasks_and_never_loads_back(self):
        # issue #2924: a login being deleted — the daemon lets go of it and loads nothing back
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.acct_script("alice", "keep.sh", "exec sleep 300\n")
        self.acct_table({"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": True})
        for who in ("alice", "bob"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.start()
        self.assertTrue(until(5, lambda: self.child("alice/keep").get("pid")), "alice's KeepAlive unit never started")
        kpid = self.child("alice/keep")["pid"]
        r = self.run_sup("account", "forget", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 service(s) left in the attic", r.stdout)
        self.assertFalse(fns.pid_alive(kpid), "forget left the account's KeepAlive unit running")
        a = json.load(open(os.path.join(self.d, "db", "accounts.json")))
        self.assertNotIn("alice", a)
        self.assertTrue(a["bob"]["managed"])
        self.assertEqual(os.listdir(la), [], "forget put a service back")
        self.assertNotIn("bootstrap", self.lclog())
        lst = self.run_sup("attic", "list").stdout
        self.assertNotIn("kept", lst)
        idx_p = os.path.join(self.d, "db", "attic", "index.json")
        idx = json.load(open(idx_p))
        for e in idx:
            e["moved"] -= 30 * 86400
        json.dump(idx, open(idx_p, "w"))
        self.assertIn("purged 1", self.run_sup("attic", "purge").stdout)
        r = self.run_sup("account", "forget", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("nothing", r.stdout)

    def test_release_of_a_gone_login_loads_nothing(self):
        # issue #2924: release of a login no longer on the machine put its node
        # agent's LaunchDaemon back, loaded for nobody — now it only forgets it
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.plist(os.path.join(dd, "com.claude-fleet.alice.collect.plist"), "com.claude-fleet.alice.collect")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        del pw["alice"]
        json.dump(pw, open(self.env["FLEET_NODE_PASSWD"], "w"))
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not a login on this machine", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertNotIn("bootstrap", self.lclog())
        self.assertNotIn("alice", json.load(open(os.path.join(self.d, "db", "accounts.json"))))

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

    def test_refused_lane_is_named_and_rejoin_renews_the_token(self):
        # issue #2501: the hub refused alice's lane (her token was reissued away)
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid", "FLEET_CONF_DIR": conf})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-alice-1\n")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        lane = os.path.join(self.d, "db", "agent", "alice", "lane.json")
        os.makedirs(os.path.dirname(lane))
        why = "unrecognised enrollment token for login alice: this login re-registered with the hub"
        json.dump({"state": "refused", "code": "WRONG_LOGIN", "why": why, "since": "2026-10-08T17:41:12Z"}, open(lane, "w"))
        r = self.run_sup("status")
        self.assertTrue(any(l.startswith("lane   alice") and "令牌失效" in l and "account adopt alice --rejoin" in l
                            and why in l for l in r.stdout.splitlines()), r.stdout)
        self.start()
        r = until(10, lambda: (lambda x: x if x.returncode == 3 else None)(self.run_sup("status", "--check")))
        self.assertTrue(r, "status --check never said 3 for a refused lane")
        self.assertIn("令牌失效 · 需要 relogin: alice", r.stdout)
        self.assertEqual(self.state().get("lanes", {}).get("alice", {}).get("why"), why, "state.json has no copy")

        # --rejoin: alice's device key asks the hub (a fake fleet-login.py here)
        seen = os.path.join(self.d, "seen")
        fake = os.path.join(self.d, "fake-login.py")
        with open(fake, "w") as f:
            f.write("import json, os, sys\n"
                    "a = sys.argv[1:]\n"
                    "open(%r, 'w').write(' '.join(a[:3]) + ' HOME=' + os.environ.get('HOME', '') + ' USER=' + os.environ.get('USER', ''))\n"
                    "if os.path.exists(%r):\n"
                    "    sys.stderr.write('fleet login: 没拿到节点通行证（HTTP 409）：machine_managed\\n'); sys.exit(1)\n"
                    "json.dump({'token': 'tok-alice-2', 'endpoint_id': 'ep_a'}, open(a[a.index('--out') + 1], 'w'))\n"
                    % (seen, seen + ".refuse"))
        e = {"FLEET_NODE_LOGIN_PY": fake}
        r = self.run_sup("account", "adopt", "alice", "--rejoin", "--dry-run", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would ask https://hub.invalid", r.stdout)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice-1", "a dry run renewed")
        open(seen + ".refuse", "w").close()
        r = self.run_sup("account", "adopt", "alice", "--rejoin", env=e)
        os.remove(seen + ".refuse")
        self.assertEqual(r.returncode, 1)
        self.assertIn("machine_managed", r.stderr)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice-1", "a refused pass wrote a token")
        r = self.run_sup("account", "adopt", "alice", "--rejoin", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("tok-alice", r.stdout + r.stderr, "rejoin printed the token")
        self.assertEqual(open(seen).read(), "node-pass --hub https://hub.invalid HOME=%s USER=alice" % self.home("alice"))
        kv, mode = self.login_env("alice")
        self.assertEqual((kv["CCQUOTA_TOKEN"], kv["CCQUOTA_HUB_URL"], mode), ("tok-alice-2", "https://hub.invalid", 0o600))

        # the tenant's next welcome removes lane.json: the line and the 3 go
        os.remove(lane)
        self.assertTrue(until(10, lambda: self.run_sup("status", "--check").returncode == 0))
        self.assertNotIn("lane   alice", self.run_sup("status").stdout)

    def test_rejoin_needs_a_managed_or_separated_login(self):
        self.acct_table()
        r = self.run_sup("account", "adopt", "bob", "--rejoin", env={"FLEET_NODE_LOGIN_PY": "/bin/false"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("no hub URL", r.stderr)

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

    def test_node_agent_reload_waits_for_an_account_op(self):
        # #2918: opening a login writes its logins/<login>.env half way through
        # the create the node agent runs — the restart cut that very create off.
        # While a tenant's book names an op running (by a live pid) the reload
        # waits; once it is done the agent starts again on the new logins/.
        lg = os.path.join(self.d, "db", "logins")
        ag = os.path.join(self.d, "db", "agent", "verky")
        os.makedirs(lg)
        os.makedirs(ag)
        with open(os.path.join(lg, "verky.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        book = os.path.join(ag, "account-ops.json")
        holder = subprocess.Popen(["/bin/sleep", "300"])
        self.addCleanup(holder.kill)
        with open(book, "w") as f:
            json.dump({"inflight": {"op-1": {"op": "create", "login": "alice", "pid": holder.pid}}}, f)
        self.table(children=[{"name": "node-agent", "cmd": [self.script("na.sh", "exec sleep 300\n")],
                              "requires": [os.path.join(lg, "*.env")], "reload": os.path.join(lg, "*.env"),
                              "hold": os.path.join(self.d, "db", "agent", "*", "account-ops.json")}])
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        with open(os.path.join(lg, "alice.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=y\n")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("reload_held_since")),
                        "the reload was not held by the op running")
        time.sleep(0.6)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted mid account op")
        self.assertTrue(fns.pid_alive(pid))
        with open(book, "w") as f:
            json.dump({"outbox": {"op-1": {"type": "account_result", "op_id": "op-1"}}}, f)
        pid2 = until(10, lambda: (self.child("node-agent").get("pid") or pid) != pid and self.child("node-agent")["pid"])
        self.assertTrue(pid2, "the op ended and the node agent kept its old tenants")
        self.assertFalse(self.child("node-agent").get("reload_held_since"))

    def test_node_agent_reload_held_by_its_script_without_a_book(self):
        # #2927: the release's ccquota predated the book (prod-343c92b under
        # stable 003e89bb), so it wrote none and nothing held — the restart cut
        # the create off and the hub's re-ask ran it again into exit 3. The
        # account script running under the node agent holds the reload too.
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg)
        with open(os.path.join(lg, "verky.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        flag = os.path.join(self.d, "op-done")
        login_new = self.script("fleet-login-new.sh", "while [ ! -e %s ]; do sleep 0.1; done\n" % flag)
        self.table(children=[{"name": "node-agent",
                              "cmd": [self.script("na.sh", "/bin/sh %s & wait; exec sleep 300\n" % login_new)],
                              "requires": [os.path.join(lg, "*.env")], "reload": os.path.join(lg, "*.env"),
                              "hold": os.path.join(self.d, "db", "agent", "*", "account-ops.json"),
                              "hold_argv": ["fleet-login-new.sh"]}])
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        with open(os.path.join(lg, "alice.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=y\n")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("reload_held_since")),
                        "a create running under the node agent did not hold the reload (no book)")
        time.sleep(0.6)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted mid account op")
        open(flag, "w").close()
        pid2 = until(10, lambda: (self.child("node-agent").get("pid") or pid) != pid and self.child("node-agent")["pid"])
        self.assertTrue(pid2, "the script ended and the node agent kept its old tenants")

    def test_node_agent_reload_hold_has_a_cap(self):
        # a book from a dead process holds nothing; a live one at most
        # FLEET_NODE_RELOAD_HOLD seconds
        lg = os.path.join(self.d, "db", "logins")
        ag = os.path.join(self.d, "db", "agent", "verky")
        os.makedirs(lg)
        os.makedirs(ag)
        with open(os.path.join(lg, "verky.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        holder = subprocess.Popen(["/bin/sleep", "300"])
        self.addCleanup(holder.kill)
        with open(os.path.join(ag, "account-ops.json"), "w") as f:
            json.dump({"inflight": {"op-1": {"op": "create", "login": "alice", "pid": holder.pid}}}, f)
        self.table(children=[{"name": "node-agent", "cmd": [self.script("na.sh", "exec sleep 300\n")],
                              "requires": [os.path.join(lg, "*.env")], "reload": os.path.join(lg, "*.env"),
                              "hold": os.path.join(self.d, "db", "agent", "*", "account-ops.json")}])
        self.start(FLEET_NODE_RELOAD_HOLD="1")
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        with open(os.path.join(lg, "alice.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=y\n")
        pid2 = until(10, lambda: (self.child("node-agent").get("pid") or pid) != pid and self.child("node-agent")["pid"])
        self.assertTrue(pid2, "a hold past its cap kept the old tenants")
        holder.kill()
        holder.wait()
        with open(os.path.join(lg, "bob.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=z\n")
        pid3 = until(10, lambda: (self.child("node-agent").get("pid") or pid2) != pid2 and self.child("node-agent")["pid"])
        self.assertTrue(pid3, "a dead process's book held the reload")

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


class I_Services(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.home = os.path.join(self.d, "Users", "alice")
        os.makedirs(self.home)
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump({"alice": {"uid": os.getuid(), "gid": os.getgid(), "home": self.home}}, f)
        self.env["FLEET_NODE_PASSWD"] = os.path.join(self.d, "passwd.json")
        self.table()
        self.svc_sh = self.script("svc.sh", 'echo "up uid=$(id -u) home=$HOME user=$USER svc=$FLEET_SERVICE '
                                  'tok=${TOKEN:-none} mode=$MODE"\necho oops >&2\nexec sleep 300\n')
        self.key = "svc:alice/watch"

    def svc(self, *args, **kw):
        return self.run_sup("service", *args, **kw)

    def services(self):
        r = self.run_sup("status", "--json")
        return {x["name"]: x for x in json.loads(r.stdout)["services"]}

    def log(self):
        try:
            return open(os.path.join(self.d, "log", "logins", "alice", "watch.log")).read()
        except IOError:
            return ""

    def test_register_run_restart_stop_rm(self):
        r = subprocess.run([sys.executable, SUP, "service", "cred", "set", "--login", "alice", "--name", "TOKEN"],
                           env=self.env, input="s3cret\n", capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("s3cret", r.stdout + r.stderr)
        r = self.svc("add", "--login", "alice", "--name", "watch", "--env", "MODE=prod", "--cred", "TOKEN",
                     "--", "/bin/bash", self.svc_sh)
        self.assertEqual(r.returncode, 0, r.stderr)
        f = os.path.join(self.d, "db", "logins", "alice", "services", "watch.json")
        self.assertEqual(os.stat(f).st_mode & 0o777, 0o600)
        ent = json.load(open(f))
        self.assertEqual((ent["login"], ent["kind"], ent["state"]), ("alice", "service", "enabled"))
        self.assertEqual(ent["creds"], ["TOKEN"])
        self.assertNotIn("s3cret", open(f).read(), "a credential value in the entry")
        self.start()
        pid = until(10, lambda: self.child(self.key).get("pid"))
        self.assertTrue(pid, "the service never started")
        self.assertTrue(until(5, lambda: "up uid=" in self.log()), "no log in <log>/logins/alice/")
        line = [l for l in self.log().splitlines() if l.startswith("up ")][-1]
        self.assertIn("uid=%d home=%s user=alice svc=watch tok=s3cret mode=prod" % (os.getuid(), self.home), line)
        self.assertIn("oops", self.log(), "stderr not in the log")
        st = self.services()["watch"]
        self.assertEqual((st["status"], st["pid"], st["login"]), ("running", pid, "alice"))
        self.assertEqual(st["creds"], ["TOKEN"])
        self.assertIn("MODE", st["env_keys"])
        self.assertEqual(st["last_line"], "oops")
        self.assertNotIn("s3cret", json.dumps(self.state()), "a credential value in state.json")
        self.assertIn("service alice/watch", self.run_sup("status").stdout)
        # killed: back within 30 s
        os.kill(pid, signal.SIGKILL)
        t0 = time.time()
        pid2 = until(30, lambda: (self.child(self.key).get("pid") or pid) != pid and self.child(self.key)["pid"])
        self.assertTrue(pid2, "the killed service was not restarted")
        self.assertLess(time.time() - t0, 30)
        self.assertEqual(self.child(self.key)["restarts"], 1)
        # restart: a new process; stop: none; start: back
        self.assertEqual(self.svc("restart", "--login", "alice", "--name", "watch").returncode, 0)
        pid3 = until(10, lambda: (self.child(self.key).get("pid") or pid2) != pid2 and self.child(self.key)["pid"])
        self.assertTrue(pid3, "restart did not start it again")
        self.assertTrue(until(5, lambda: not fns.pid_alive(pid2)))
        self.assertEqual(self.svc("stop", "--login", "alice", "--name", "watch").returncode, 0)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid3)), "stop left it running")
        self.assertTrue(until(20, lambda: self.services()["watch"]["status"] == "stopped"))
        time.sleep(0.5)
        self.assertFalse(fns.pid_alive(self.child(self.key).get("pid")), "a stopped service came back")
        self.assertEqual(self.svc("start", "--login", "alice", "--name", "watch").returncode, 0)
        pid4 = until(10, lambda: self.child(self.key).get("pid"))
        self.assertTrue(pid4, "start did not bring it back")
        # rm: stopped, the row gone; the log stays
        self.assertEqual(self.svc("rm", "--login", "alice", "--name", "watch").returncode, 0)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid4)), "rm left it running")
        self.assertTrue(until(10, lambda: self.key not in (self.state().get("children") or {})))
        self.assertNotIn("watch", self.services())
        self.assertTrue(os.path.exists(os.path.join(self.d, "log", "logins", "alice", "watch.log")))

    def test_missing_credential_waits(self):
        r = self.svc("add", "--login", "alice", "--name", "watch", "--cred", "TOKEN", "--", "/bin/bash", self.svc_sh)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not stored yet", r.stdout)
        self.start()
        self.assertTrue(until(10, lambda: self.child(self.key).get("status") == "missing credential TOKEN"))
        self.assertFalse(self.child(self.key).get("pid"))
        subprocess.run([sys.executable, SUP, "service", "cred", "set", "--login", "alice", "--name", "TOKEN"],
                       env=self.env, input="v\n", capture_output=True, text=True)
        self.assertTrue(until(10, lambda: self.child(self.key).get("pid")), "the credential arrived, no start")

    def test_bad_entries_refused(self):
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "Bad/Name", "--", "/bin/true").returncode, 2)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "x", "--", "true").returncode, 2)
        self.assertEqual(self.svc("add", "--login", "nobody-here", "--name", "x", "--", "/bin/true").returncode, 1)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "x").returncode, 2)
        # a hand-written entry that lies about its login is named, never run
        d = os.path.join(self.d, "db", "logins", "alice", "services")
        os.makedirs(d)
        with open(os.path.join(d, "evil.json"), "w") as f:
            json.dump({"name": "evil", "login": "root", "kind": "service", "exec": ["/bin/sleep", "300"]}, f)
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.start()
        time.sleep(1)
        self.assertFalse(self.child("svc:alice/evil").get("pid"))
        self.assertFalse(self.child("svc:root/evil").get("pid"))
        row = self.services()["evil"]
        self.assertEqual(row["status"], "invalid")
        self.assertIn("login root", row["why"])
        self.assertIn("INVALID", self.run_sup("status").stdout)

    def test_front_registers_through_the_supervisor(self):
        fe = dict(self.env, FLEET_NODE_SUPERVISOR=SUP, FLEET_SERVICE_SUDO="", FLEET_SERVICE_LOGIN="alice",
                  MYMODE="dev")
        front = os.path.join(BIN, "fleet-service.sh")
        r = subprocess.run(["bash", front, "add", "watch", "--env-key", "MYMODE", "--", "sleep", "300"],
                           env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "alice", "services", "watch.json")))
        self.assertTrue(os.path.isabs(ent["exec"][0]) and ent["exec"][1:] == ["300"], ent["exec"])
        self.assertEqual(ent["env"], {"MYMODE": "dev"})
        self.assertIn("alice/watch", subprocess.run(["bash", front, "ls"], env=fe, capture_output=True,
                                                    text=True).stdout)
        r = subprocess.run(["bash", front, "rm", "watch"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        # no passwordless sudo: the line an admin runs
        fake = self.script("nosudo", "exit 1\n")
        r = subprocess.run(["bash", front, "stop", "watch"], env=dict(fe, FLEET_SERVICE_SUDO=fake),
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("service stop --login alice --name watch", r.stderr)

    def test_services_do_not_restart_the_node_agent(self):
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg)
        with open(os.path.join(lg, "alice.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\n")
        self.table(children=[{"name": "node-agent", "cmd": [self.script("na.sh", "exec sleep 300\n")],
                              "requires": [os.path.join(lg, "*.env")], "reload": os.path.join(lg, "*.env")}])
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "watch", "--", "/bin/sleep", "300").returncode, 0)
        self.assertTrue(until(10, lambda: self.child(self.key).get("pid")))
        time.sleep(0.5)
        self.assertEqual(self.child("node-agent")["pid"], pid, "a service restarted the node agent")


class J_ServiceMove(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.ha = os.path.join(self.d, "Users", "verkyyi")
        self.hb = os.path.join(self.d, "Users", "verky")
        for h in (self.ha, self.hb):
            os.makedirs(h)
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump({"verkyyi": {"uid": os.getuid(), "gid": os.getgid(), "home": self.ha},
                       "verky": {"uid": os.getuid(), "gid": os.getgid(), "home": self.hb}}, f)
        self.env["FLEET_NODE_PASSWD"] = os.path.join(self.d, "passwd.json")
        self.table()
        # the daily-report case: a working dir with its script + logs, a skill dir
        self.work = os.path.join(self.ha, "daily-report")
        self.skill = os.path.join(self.ha, ".claude", "skills", "daily-report")
        os.makedirs(os.path.join(self.work, "logs"))
        os.makedirs(self.skill)
        with open(os.path.join(self.skill, "SKILL.md"), "w") as f:
            f.write("daily report\n")
        self.run_sh = os.path.join(self.work, "run.sh")
        with open(self.run_sh, "w") as f:
            f.write('#!/bin/bash\necho "up home=$HOME user=$USER tok=${BARK_KEY:-none} out=$OUT"\n'
                    'echo run >> "$OUT/run.log"\nexec sleep 300\n')
        os.chmod(self.run_sh, 0o755)
        r = subprocess.run([sys.executable, SUP, "service", "cred", "set", "--login", "verkyyi", "--name",
                            "BARK_KEY"], env=self.env, input="k3y\n", capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_sup("service", "add", "--login", "verkyyi", "--name", "daily-report", "--cred", "BARK_KEY",
                         "--env", "OUT=%s/logs" % self.work, "--path", self.work, "--path", self.skill,
                         "--", "/bin/bash", self.run_sh)
        self.assertEqual(r.returncode, 0, r.stderr)

    def reg(self, login):
        return os.path.join(self.d, "db", "logins", login, "services", "daily-report.json")

    def svclog(self, login):
        return os.path.join(self.d, "log", "logins", login, "daily-report.log")

    def read(self, f):
        try:
            return open(f).read()
        except IOError:
            return ""

    def test_move_carries_everything_and_runs_as_the_new_login(self):
        self.start()
        pa = until(10, lambda: self.child("svc:verkyyi/daily-report").get("pid"))
        self.assertTrue(pa, "never ran as the old login")
        self.assertTrue(until(5, lambda: "home=%s" % self.ha in self.read(self.svclog("verkyyi"))))
        r = self.run_sup("service", "move", "--login", "verkyyi", "--name", "daily-report", "--to", "verky")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("moved verkyyi/daily-report → verky/daily-report", r.stdout)
        self.assertFalse(fns.pid_alive(pa), "the old copy still runs")
        # the entry
        self.assertFalse(os.path.exists(self.reg("verkyyi")), "the old entry is left")
        ent = json.load(open(self.reg("verky")))
        self.assertEqual(os.stat(self.reg("verky")).st_mode & 0o777, 0o600)
        nwork = os.path.join(self.hb, "daily-report")
        nskill = os.path.join(self.hb, ".claude", "skills", "daily-report")
        self.assertEqual((ent["login"], ent["state"]), ("verky", "enabled"))
        self.assertEqual(ent["exec"], ["/bin/bash", os.path.join(nwork, "run.sh")])
        self.assertEqual(ent["paths"], [nwork, nskill])
        self.assertEqual(ent["env"]["OUT"], os.path.join(nwork, "logs"))
        self.assertEqual(ent["moved_from"]["login"], "verkyyi")
        # the directories
        self.assertTrue(os.path.isfile(os.path.join(nwork, "run.sh")))
        self.assertTrue(os.path.isfile(os.path.join(nskill, "SKILL.md")))
        self.assertIn("run", self.read(os.path.join(nwork, "logs", "run.log")), "the job's own log did not move")
        self.assertFalse(os.path.exists(self.work), "the working dir is left in the old home")
        self.assertFalse(os.path.exists(self.skill), "the skill dir is left in the old home")
        # the log and the credential
        self.assertFalse(os.path.exists(self.svclog("verkyyi")), "the log is left under the old login")
        self.assertIn("home=%s" % self.ha, self.read(self.svclog("verky")), "the log's history did not move")
        creds = os.path.join(self.d, "db", "logins")
        self.assertFalse(os.path.exists(os.path.join(creds, "verkyyi", "creds", "BARK_KEY")))
        self.assertEqual(self.read(os.path.join(creds, "verky", "creds", "BARK_KEY")), "k3y\n")
        # and it runs as the new login
        pb = until(10, lambda: self.child("svc:verky/daily-report").get("pid"))
        self.assertTrue(pb, "it did not start under the new login")
        self.assertTrue(until(5, lambda: "up home=%s user=verky tok=k3y out=%s/logs" % (self.hb, nwork)
                              in self.read(self.svclog("verky"))), self.read(self.svclog("verky")))
        self.assertTrue(until(10, lambda: "svc:verkyyi/daily-report" not in (self.state().get("children") or {})))
        rows = json.loads(self.run_sup("service", "ls", "--json").stdout)
        self.assertEqual([(x["login"], x["name"]) for x in rows], [("verky", "daily-report")])
        # nothing left to stop a release / a removal of the old login
        self.assertEqual(os.listdir(os.path.dirname(self.reg("verkyyi"))), [])

    def test_move_refuses_onto_an_existing_path(self):
        os.makedirs(os.path.join(self.hb, ".claude", "skills", "daily-report"))
        r = self.run_sup("service", "move", "--login", "verkyyi", "--name", "daily-report", "--to", "verky")
        self.assertEqual(r.returncode, 1)
        self.assertIn("already exists", r.stderr)
        self.assertTrue(os.path.exists(self.reg("verkyyi")) and not os.path.exists(self.reg("verky")))
        self.assertEqual(json.load(open(self.reg("verkyyi")))["state"], "enabled")
        self.assertTrue(os.path.isdir(self.work) and os.path.isdir(self.skill))
        self.assertEqual(self.run_sup("service", "move", "--login", "verkyyi", "--name", "daily-report",
                                      "--to", "verkyyi").returncode, 2)
        self.assertEqual(self.run_sup("service", "move", "--login", "verkyyi", "--name", "nope",
                                      "--to", "verky").returncode, 1)

    def test_a_stopped_entry_moves_stopped(self):
        self.assertEqual(self.run_sup("service", "stop", "--login", "verkyyi", "--name", "daily-report").returncode, 0)
        r = self.run_sup("service", "move", "--login", "verkyyi", "--name", "daily-report", "--to", "verky")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.load(open(self.reg("verky")))["state"], "stopped")

    def test_release_refuses_while_entries_are_left(self):
        with open(os.path.join(self.d, "db", "accounts.json"), "w") as f:
            json.dump({"verkyyi": {"managed": True, "since": 1}}, f)
        r = self.run_sup("account", "release", "verkyyi")
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("service move --login verkyyi --name daily-report --to", r.stderr)
        self.assertTrue(json.load(open(os.path.join(self.d, "db", "accounts.json")))["verkyyi"]["managed"],
                        "a refused release changed the account")
        os.makedirs(os.path.join(self.d, "db", "attic"))
        r = self.run_sup("account", "release", "verkyyi", "--force")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_front_moves_your_own(self):
        fe = dict(self.env, FLEET_NODE_SUPERVISOR=SUP, FLEET_SERVICE_SUDO="", FLEET_SERVICE_LOGIN="verkyyi")
        front = os.path.join(BIN, "fleet-service.sh")
        r = subprocess.run(["bash", front, "move", "daily-report"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        r = subprocess.run(["bash", front, "move", "daily-report", "--to", "verky"], env=fe,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.reg("verky")))
class K_AgentTasks(Sandbox):
    DAY = "2026-10-10"

    def setUp(self):
        Sandbox.setUp(self)
        self.home = os.path.join(self.d, "Users", "alice")
        os.makedirs(self.home)
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump({"alice": {"uid": os.getuid(), "gid": os.getgid(), "home": self.home}}, f)
        self.clock = os.path.join(self.d, "clock")
        self.env.update(FLEET_NODE_PASSWD=os.path.join(self.d, "passwd.json"), FLEET_NODE_CLOCK=self.clock)
        self.table()
        self.calls = os.path.join(self.d, "calls")
        # the login's spawner: one line per call (its argv), the receipt on stdout
        self.spawner = os.path.join(self.d, "spawn.sh")
        self.spawner_rc(0)
        self.set_clock("06:59:50")

    def set_clock(self, hms, day=None):
        import calendar
        y, m, d = (int(x) for x in (day or self.DAY).split("-"))
        h, mi, se = (int(x) for x in hms.split(":"))
        with open(self.clock, "w") as f:
            f.write("%d\n" % calendar.timegm((y, m, d, h, mi, se)))

    def spawner_rc(self, rc):
        with open(self.spawner, "w") as f:
            f.write('#!/bin/bash\nprintf "%%s|" "$@" >> "$CALLS"; echo >> "$CALLS"\n'
                    '[ -n "${MAKE:-}" ] && : > "$MAKE"\n'
                    'echo "@7\tdaily\t\tfid"\nexit %d\n' % rc)
        os.chmod(self.spawner, 0o755)

    def add(self, *extra, **env_):
        e = ["--env", "FLEET_TASK_SPAWN=%s" % self.spawner, "--env", "CALLS=%s" % self.calls]
        for k, v in env_.items():
            e += ["--env", "%s=%s" % (k, v)]
        return self.run_sup("service", "add", "--kind", "task", "--login", "alice", "--name", "daily",
                            "--at", "07:00", "--tz", "UTC", "--fleet", "fns-sandbox", "--prompt", "/daily-report {date}",
                            *(e + list(extra)))

    def ncalls(self):
        try:
            return [l for l in open(self.calls).read().splitlines() if l]
        except IOError:
            return []

    def row(self):
        return [r for r in json.loads(self.run_sup("status", "--json").stdout)["services"]
                if r["name"] == "daily"][0]

    def agent(self):
        return (self.state().get("agent_tasks") or {}).get("alice/daily") or {}

    def test_slot_fires_once(self):
        self.spawner_rc(0)
        r = self.add()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("next run %s 07:00" % self.DAY, r.stdout)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "alice", "services", "daily.json")))
        self.assertEqual((ent["kind"], ent["schedule"], ent["retries"]), ("task", {"at": "07:00", "tz": "UTC"}, 2))
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "a run before its slot")
        self.assertEqual(self.row()["status"], "scheduled")
        self.set_clock("07:00:05")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        time.sleep(1.5)
        calls = self.ncalls()
        self.assertEqual(len(calls), 1, calls)
        self.assertEqual(calls[0], "--no-repo|--origin|hub|--print|--name|daily-%s|--prompt|/daily-report %s|fns-sandbox|"
                         % (self.DAY, self.DAY))
        row = self.row()
        self.assertEqual((row["status"], row["last_result"], row["last_window"]), ("ok", "ok", "daily-" + self.DAY))
        self.assertEqual(fns.task_time(row["next_run"], row["schedule"]), "2026-10-11 07:00")
        self.assertTrue(row["last_run"])
        log = open(os.path.join(self.d, "log", "logins", "alice", "daily.log")).read()
        self.assertIn("opened @7 (daily-%s) in fleet fns-sandbox" % self.DAY, log)
        runs = json.load(open(os.path.join(self.d, "db", "logins", "alice", "runs", "daily.json")))["runs"]
        self.assertEqual([(x["slot"], x["attempt"], x["rc"]) for x in runs], [(self.DAY, 1, 0)])
        st = self.run_sup("service", "ls", "--login", "alice", "--kind", "task").stdout
        self.assertIn("上次 %s 07:00 ok · 下次 2026-10-11 07:00" % self.DAY, st)
        # the next day's slot: one more, a new window name
        self.set_clock("07:00:01", "2026-10-11")
        self.assertTrue(until(10, lambda: len(self.ncalls()) == 2), self.ncalls())
        self.assertIn("--name|daily-2026-10-11|", self.ncalls()[1])

    def test_failures_exhaust_then_alert(self):
        self.spawner_rc(2)        # at capacity, every time
        self.assertEqual(self.add("--retries", "1", "--retry-delay", "0").returncode, 0)
        self.set_clock("07:00:05")
        self.start()
        self.assertTrue(until(15, lambda: self.agent().get("state") == "failed"), self.agent())
        time.sleep(1.5)
        calls = self.ncalls()
        self.assertEqual(len(calls), 2, calls)
        self.assertIn("--name|daily-%s|" % self.DAY, calls[0])
        self.assertIn("--name|daily-%s-2|" % self.DAY, calls[1], "a retry reuses the failed window's name")
        ap = os.path.join(self.d, "db", "logins", "alice", "alerts", "daily.json")
        self.assertTrue(os.path.exists(ap), "no alert file")
        al = json.load(open(ap))
        self.assertEqual((al["attempts"], al["slot"]), (2, self.DAY))
        self.assertIn("did not open", al["why"])
        row = self.row()
        self.assertEqual((row["status"], row["alert"]), ("failed", ap))
        self.assertIn("task    alice/daily", self.run_sup("status").stdout)
        # a success later clears the alert
        self.spawner_rc(0)
        self.assertEqual(self.run_sup("service", "run", "--login", "alice", "--name", "daily").returncode, 0)
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        self.assertFalse(os.path.exists(ap), "the alert outlived a good run")

    def test_run_now_through_the_front(self):
        self.spawner_rc(0)
        self.set_clock("12:00:00")
        fe = dict(self.env, FLEET_NODE_SUPERVISOR=SUP, FLEET_SERVICE_SUDO="", FLEET_SERVICE_LOGIN="alice")
        front = os.path.join(BIN, "fleet-task.sh")
        r = subprocess.run(["bash", front, "add", "daily", "--at", "07:00", "--tz", "UTC", "--fleet", "fns-sandbox",
                            "--prompt", "hi", "--env", "FLEET_TASK_SPAWN=%s" % self.spawner,
                            "--env", "CALLS=%s" % self.calls], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "a slot earlier than the entry ran")
        r = subprocess.run(["bash", front, "run", "daily"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2, "run without --now")
        r = subprocess.run(["bash", front, "run", "daily", "--now"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(until(10, lambda: len(self.ncalls()) == 1), self.ncalls())
        self.assertIn("--name|daily-2026-10-10-now1200|", self.ncalls()[0], "a manual run took the slot's window")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"))
        time.sleep(1)
        self.assertEqual(len(self.ncalls()), 1)
        ls = subprocess.run(["bash", front, "ls"], env=fe, capture_output=True, text=True).stdout
        self.assertIn("alice/daily", ls)
        self.assertIn("下次 %s 07:00" % "2026-10-11", ls)
        # a service has no run; a stopped task does not run
        r = subprocess.run(["bash", front, "stop", "daily"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run(["bash", front, "run", "daily", "--now"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        r = subprocess.run(["bash", front, "rm", "daily"], env=fe, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(until(10, lambda: "alice/daily" not in (self.state().get("agent_tasks") or {})))

    def test_schedule_moves_the_slot(self):
        # issue #2527: a new schedule moves the next slot, and a slot it skipped
        # over (passed before the change) is never caught up
        self.spawner_rc(0)
        self.set_clock("05:00:00")
        self.assertEqual(self.add().returncode, 0)
        self.set_clock("08:00:00")
        fe = dict(self.env, FLEET_NODE_SUPERVISOR=SUP, FLEET_SERVICE_SUDO="", FLEET_SERVICE_LOGIN="alice")
        front = os.path.join(BIN, "fleet-task.sh")
        r = subprocess.run(["bash", front, "schedule", "daily", "--at", "07:30"], env=fe,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("daily 07:30 UTC, next run 2026-10-11 07:30", r.stdout, "the tz was not kept")
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "the slot the change skipped over ran")
        row = self.row()
        self.assertEqual(fns.task_time(row["next_run"], row["schedule"]), "2026-10-11 07:30")
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "daily",
                                      "--at", "7pm").returncode, 2, "a bad schedule was written")
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "daily",
                                      "--cron", "0 6 * * 1-5", "--tz", "Asia/Shanghai").returncode, 0)
        self.assertEqual(self.row()["schedule"], {"cron": "0 6 * * 1-5", "tz": "Asia/Shanghai"})
        self.assertEqual(self.run_sup("service", "add", "--login", "alice", "--name", "s", "--", "/bin/sleep",
                                      "300").returncode, 0)
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "s",
                                      "--at", "07:00").returncode, 2, "a service has no schedule")

    def test_done_file_decides(self):
        self.spawner_rc(0)
        out = os.path.join(self.home, "out-{date}.md")
        self.assertEqual(self.add("--done-file", out, "--retries", "0", MAKE=out.replace("{date}", self.DAY))
                         .returncode, 0)
        self.set_clock("07:00:05")
        self.start()
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        # the next slot's file is never made: the session ends without it → failed
        self.set_clock("07:00:05", "2026-10-11")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "failed"), self.agent())
        self.assertIn("without its output", self.agent()["last_error"])

    def test_task_moves_with_its_login(self):
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump({"alice": {"uid": os.getuid(), "gid": os.getgid(), "home": self.home},
                       "bob": {"uid": os.getuid(), "gid": os.getgid(),
                               "home": os.path.join(self.d, "Users", "bob")}}, f)
        os.makedirs(os.path.join(self.d, "Users", "bob"))
        self.assertEqual(self.add("--done-file", os.path.join(self.home, "out-{date}.md")).returncode, 0)
        r = self.run_sup("service", "move", "--login", "alice", "--name", "daily", "--to", "bob")
        self.assertEqual(r.returncode, 0, r.stderr)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "bob", "services", "daily.json")))
        self.assertEqual((ent["kind"], ent["exec"]), ("task", None))
        self.assertEqual(ent["done_when"]["file"], os.path.join(self.d, "Users", "bob", "out-{date}.md"))

    def test_bad_entries_refused(self):
        base = ["service", "add", "--kind", "task", "--login", "alice", "--name", "t"]
        self.assertEqual(self.run_sup(*base, "--at", "07:00").returncode, 2, "no prompt")
        self.assertEqual(self.run_sup(*base, "--prompt", "x").returncode, 2, "no schedule")
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "7pm").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--cron", "* * *").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--tz", "Mars/Olympus").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--retries", "99").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--", "/bin/true").returncode, 2)
        self.assertEqual(self.run_sup("service", "add", "--login", "alice", "--name", "s", "--", "/bin/sleep",
                                      "300").returncode, 0)
        self.assertEqual(self.run_sup("service", "run", "--login", "alice", "--name", "s").returncode, 2,
                         "run is a task's")

    def test_slots(self):
        import calendar
        t = calendar.timegm((2026, 10, 10, 6, 59, 50))       # a Saturday
        self.assertEqual(fns.task_slot({"cron": "30 6 * * 1-5", "tz": "UTC"}, t, 1)[1], "2026-10-12")
        self.assertEqual(fns.task_slot({"cron": "30 6 * * 1-5", "tz": "UTC"}, t, -1)[1], "2026-10-09")
        n = fns.task_slot({"at": "07:00", "tz": "Asia/Shanghai"}, t, 1)[0]
        self.assertEqual(n, calendar.timegm((2026, 10, 10, 23, 0, 0)))
        self.assertEqual(fns.task_slot({"cron": "0 9 1 * *", "tz": "UTC"}, t, 1)[1], "2026-11-01")



class L_Tenants(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        pw = {}
        for who in ("alice", "bob"):
            home = os.path.join(self.d, "Users", who)
            os.makedirs(os.path.join(home, "Library", "LaunchAgents"))
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": home}
        pw["bob"].update(groups=["staff", "admin"], sudo="(ALL) NOPASSWD: ALL")
        self.pw = os.path.join(self.d, "passwd.json")
        with open(self.pw, "w") as f:
            json.dump(pw, f)
        self.env["FLEET_NODE_PASSWD"] = self.pw
        self.logins = os.path.join(self.d, "db", "logins")
        os.makedirs(self.logins)

    def take(self, who):
        open(os.path.join(self.logins, who + ".env"), "w").close()

    def test_check_codes(self):
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 2, "nobody taken over: no row — " + r.stdout + r.stderr)
        self.take("alice")
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("none admin or sudo-capable: alice", r.stdout)
        self.take("bob")
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("bob: admin 组, sudo -l: (ALL) NOPASSWD: ALL", r.stdout)
        self.assertNotIn("alice", r.stdout)
        js = json.loads(self.run_sup("tenants", "--json").stdout)
        self.assertEqual(sorted(js["bad"]), ["bob"])

    def test_adopt_refuses_an_admin(self):
        ag = os.path.join(self.d, "Users", "bob", "Library", "LaunchAgents", "com.claude-fleet.x.plist")
        with open(ag, "wb") as f:
            plistlib.dump({"Label": "com.claude-fleet.x", "ProgramArguments": ["/bin/true"]}, f)
        r = self.run_sup("account", "adopt", "bob")
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertIn("refusing to adopt bob", r.stderr)
        self.assertTrue(os.path.exists(ag), "a refused adopt moved a service")
        self.assertFalse(fns.read_json(os.path.join(self.d, "db", "accounts.json"), {}).get("bob"))

    def test_tick_writes_the_reading(self):
        self.table()
        self.take("bob")
        self.assertEqual(self.run_sup("tick").returncode, 0)
        t = self.state().get("tenants") or {}
        self.assertEqual(t.get("bad", {}).get("bob"), ["admin 组", "sudo -l: (ALL) NOPASSWD: ALL"])
        self.assertTrue(t.get("complete"))

    def test_non_root_reader_carries_the_daemons_reading(self):
        keep = fns.tenant_privileges, fns.tenant_logins
        try:
            fns.tenant_logins = lambda paths: ["alice", "bob"]
            fns.tenant_privileges = lambda login: ([], False)       # groups clean, sudo unreadable
            cur = fns.tenants_now(None, {"tenants": {"at": 5, "bad": {"bob": ["sudo -l: x"], "gone": ["y"]}}})
            self.assertEqual(cur["bad"], {"bob": ["sudo -l: x"]})
            self.assertEqual(cur["daemon_at"], 5)
            self.assertFalse(cur["complete"])
        finally:
            fns.tenant_privileges, fns.tenant_logins = keep


class M_UpdateVerifySoon(Sandbox):
    """A switched release is verified once its settle passed, not on the update
    task's next 5-minute slot (issue #2973: 「正在更新（switched）」 for minutes)."""
    def test_verify_due_after_settle(self):
        db = os.path.join(self.d, "db")
        os.makedirs(db)
        p = type("P", (), {"state": db})()
        uj = os.path.join(db, "update.json")
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "no update.json is never due")
        with open(uj, "w") as f:
            json.dump({"phase": "idle", "switched_at": 900}, f)
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "an idle updater waits for its slot")
        with open(uj, "w") as f:
            json.dump({"phase": "switched", "switched_at": 990}, f)
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "inside the settle: not yet")
        with open(uj, "w") as f:
            json.dump({"phase": "switched", "switched_at": 960}, f)
        self.assertTrue(fns.update_verify_due(p, 1000, 100), "settle passed: verify now")
        self.assertFalse(fns.update_verify_due(p, 1000, 10), "the task ran 10 s ago: no busy loop")


class N_FullDiskAccess(Sandbox):
    """The daemon reads whether its chain holds Full Disk Access, and the status
    line names what to grant (issue #2973: the hub's removes, dscl refused)."""
    def reading(self, mode):
        db = os.path.join(self.d, "TCC.db")
        if os.path.exists(db):
            os.remove(db)
        if mode is not None:
            with open(db, "w") as f:
                f.write("x")
            os.chmod(db, mode)
        os.environ["FLEET_NODE_TCC_DB"] = db
        try:
            return fns.fda_reading()
        finally:
            del os.environ["FLEET_NODE_TCC_DB"]
            if os.path.exists(db):
                os.chmod(db, 0o600)

    def test_reading(self):
        self.assertIs(self.reading(0o600)["ok"], True)
        self.assertIs(self.reading(None)["ok"], None, "no TCC database: nothing to tell")
        if os.geteuid() != 0:   # root reads a 000 file; macOS's TCC is what stops it there
            self.assertIs(self.reading(0o000)["ok"], False)
        self.assertTrue(self.reading(0o600)["program"].startswith("/"))

    def test_line(self):
        self.assertEqual(fns.fda_line({}), "")
        self.assertEqual(fns.fda_line({"fda": {"ok": True}}), "")
        self.assertEqual(fns.fda_line({"fda": {"ok": None}}), "")
        line = fns.fda_line({"fda": {"ok": False, "program": "/x/Python"}})
        self.assertIn("完全磁盘访问", line)
        self.assertIn("/x/Python", line)
        self.assertIn("kickstart -k system/com.claude-fleet.node", line)


if __name__ == "__main__":
    unittest.main(verbosity=2)
