#!/usr/bin/env python3
"""#3135: only sandbox paths, bounded dummy processes, no real credentials.
The proxy fixture models exec + flock, not the credential service's logic.
"""
import importlib.util
import json
import os
import pwd
import signal
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

BIN = os.path.dirname(os.path.abspath(__file__))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BIN, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ct = module("core_tests", "fleet-node-core-selftest.py")
sup = module("supervisor", "fleet-node-supervisor.py")
core = module("node_core", "fleet-node-core.py")


class Orphans(ct.Sandbox):
    def setUp(self):
        super().setUp()
        self.pids = set()
        self.lib = os.path.join(self.d, "Application Support", "credsep")
        self.cred = os.path.join(self.d, "cred")
        self.run = os.path.join(self.d, "run", ".shared")
        for p in (self.lib, self.run, os.path.join(self.cred, ".shared")):
            os.makedirs(p)
        self.env.update(FLEET_CREDSEP_ROOT_BASE=self.cred,
                        FLEET_CREDSEP_RUN_BASE=os.path.dirname(self.run),
                        FLEET_CREDSEP_LIB=self.lib, FLEET_NODE_TICK="0.1",
                        FLEET_NODE_STRAY_SECS="0.2")
        with open(os.path.join(self.cred, ".shared.json"), "w") as f:
            json.dump({"user": pwd.getpwuid(os.getuid()).pw_name}, f)
        self.tenants = os.path.join(self.cred, ".shared", "tenants.json")
        with open(self.tenants, "w") as f:
            json.dump({"run": self.run, "state": os.path.dirname(self.tenants)}, f)
        self.proxy = os.path.join(self.lib, "fleet-cred-proxy.py")
        with open(self.proxy, "w") as f:
            f.write("import fcntl,json,os,signal,sys\n"
                    "signal.alarm(90)\n"
                    "d=json.load(open(sys.argv[-1]))\n"
                    "lock=open(d['state']+'/lock','w')\n"
                    "try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
                    "except BlockingIOError: sys.exit(0)\n"
                    "open(d['run']+'/pid','w').write(str(os.getpid()))\n"
                    "while True: signal.pause()\n")
        self.launcher = os.path.join(self.lib, "fleet-credsep-launch.py")
        with open(self.launcher, "w") as f:
            f.write("import os\nos.execv(%r, %r)\n" %
                    (sys.executable, [sys.executable, "-I", self.proxy, "serve", "--shared", self.tenants]))
        self.ent = {"name": "cred-proxy-shared", "cmd": [sys.executable, "-I", self.launcher, "shared"],
                    "reload": self.lib}
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump({"children": [self.ent], "tasks": [], "account": []}, f)

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        for pid in self.pids:
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass
        super().tearDown()

    def orphan(self, argv):
        r = subprocess.run([sys.executable, "-c",
                            "import subprocess,sys; p=subprocess.Popen(sys.argv[1:], "
                            "start_new_session=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,"
                            "stderr=subprocess.DEVNULL); print(p.pid)"] + argv,
                           capture_output=True, text=True, check=True)
        pid = int(r.stdout)
        self.pids.add(pid)
        return pid

    def holder(self):
        try:
            pid = int(open(os.path.join(self.run, "pid")).read())
            self.pids.add(pid)
            return pid
        except (OSError, ValueError):
            return None

    def start_sup(self):
        p = subprocess.Popen([sys.executable, os.path.join(self.bin, "fleet-node-supervisor.py"), "run"],
                             env=self.env, stdout=subprocess.DEVNULL,
                             stderr=open(os.path.join(self.d, "sup.err"), "a"))
        self.procs.append(p)
        return p

    def child(self):
        return (sup.read_json(os.path.join(self.state, "state.json"), {}).get("children") or {}).get(
            "cred-proxy-shared", {})

    def starts(self):
        return sup.read_json(os.path.join(self.state, "state.json"), {}).get("supervisor", {}).get("starts")

    def test_supervisor_adopts_exec_and_missing_book(self):
        old = self.orphan(self.ent["cmd"])
        self.assertTrue(ct.until(5, lambda: self.holder() == old))
        # No book: recover run/pid, then reload once (unknown old code/config).
        daemon = self.start_sup()
        self.assertTrue(ct.until(12, lambda: self.child().get("pid") == self.holder()
                                 and self.holder() not in (None, old)), self.child())
        pid = self.holder()
        for i in range(3):
            daemon.kill()
            daemon.wait()
            daemon = self.start_sup()
            self.assertTrue(ct.until(10, lambda: self.starts() == i + 2))
            self.assertEqual(self.holder(), pid)
            self.assertEqual(self.child().get("pid"), pid)
        self.assertIn("adopted child cred-proxy-shared", open(os.path.join(self.d, "sup.err")).read())
        daemon.terminate()
        daemon.wait(timeout=15)
        self.assertTrue(ct.until(5, lambda: not sup.pid_alive(pid)), "adopted proxy outlived stop")

    def test_core_recovers_shared_lock_three_times(self):
        old = self.orphan(self.ent["cmd"])
        self.assertTrue(ct.until(5, lambda: self.holder() == old))
        for _ in range(3):
            daemon = self.serve()
            r = self.req("machine", {"job": "cred-proxy-shared", "action": "start"})
            self.assertTrue(r.get("ok"), r)
            self.pids.add(r["pid"])
            self.assertTrue(ct.until(8, lambda: self.holder() == r["pid"]), "old proxy still owns lock")
            self.assertNotEqual(old, r["pid"])
            self.assertFalse(sup.pid_alive(old), "old lock holder still alive")
            old = r["pid"]
            daemon.kill()
            daemon.wait()
            os.unlink(self.env["FLEET_NODE_CORE_SOCK"])
        self.serve()
        r = self.req("machine", {"job": "cred-proxy-shared", "action": "stop"})
        self.assertTrue(r.get("stopped"), r)
        self.assertTrue(ct.until(5, lambda: not sup.pid_alive(old)))

    def test_stop_reaps_group_after_leader_exits(self):
        for owner in ("core", "supervisor"):
            with self.subTest(owner=owner):
                self.stop_tree(owner)

    def test_seated_supervisor_and_active_owner(self):
        pwfile = self.env["FLEET_NODE_PASSWD"]
        with open(pwfile) as f:
            pw = json.load(f)
        pw["_fleetnode"] = pw["alice"]
        with open(pwfile, "w") as f:
            json.dump(pw, f)
        self.serve()
        active = subprocess.Popen(self.ent["cmd"], start_new_session=True)
        self.procs.append(active)
        self.pids.add(active.pid)
        self.assertTrue(ct.until(5, lambda: self.holder() == active.pid))
        r = self.req("machine", {"job": "cred-proxy-shared", "action": "start"})
        self.assertIn("running", r.get("error", ""), r)
        self.assertIsNone(active.poll(), "an active owner's proxy was stopped")
        active.terminate()
        active.wait(timeout=5)
        old = self.orphan(self.ent["cmd"])
        self.assertTrue(ct.until(5, lambda: self.holder() == old))
        with mock.patch.dict(os.environ, self.env):
            sup.seat_layout(sup.Paths(), (os.getuid(), os.getgid()))
        self.env["FLEET_NODE_SEATED"] = "1"
        daemon = self.start_sup()
        self.assertTrue(ct.until(12, lambda: self.holder() not in (None, old) and self.child().get("pid")),
                        open(os.path.join(self.d, "sup.err")).read() + self.log())
        holder = self.holder()
        for i in range(3):
            daemon.kill()
            daemon.wait()
            daemon = self.start_sup()
            self.assertTrue(ct.until(10, lambda: self.starts() == i + 2))
            self.assertEqual(self.holder(), holder, "seat restart replaced the core's live proxy")
            self.assertIsNone(daemon.poll())
        daemon.terminate()
        daemon.wait(timeout=20)
        self.assertTrue(ct.until(5, lambda: not sup.pid_alive(holder)),
                        "seat shutdown did not reach core\n" + open(os.path.join(self.d, "sup.err")).read() + self.log())

    def stop_tree(self, owner):
        childfile = os.path.join(self.d, "grandchild")
        code = ("import os,signal,time\nsignal.alarm(60)\n"
                "if os.fork()==0:\n signal.alarm(60)\n signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                " open(%r,'w').write(str(os.getpid()))\n"
                " while True: time.sleep(1)\n"
                "while True: time.sleep(1)\n") % childfile
        p = subprocess.Popen([sys.executable, "-c", code], start_new_session=True)
        self.procs.append(p)
        self.pids.add(p.pid)
        self.assertTrue(ct.until(5, lambda: os.path.exists(childfile)))
        child = int(open(childfile).read())
        threading.Thread(target=p.wait, daemon=True).start()
        if owner == "core":
            core.stop_group(p.pid, grace=0.3)
        else:
            with mock.patch.dict(os.environ, self.env):
                daemon = sup.Supervisor(sup.Paths(), {"children": [], "tasks": []})
                daemon.procs["tree"] = p
                daemon.stop_children()
        p.wait(timeout=5)
        self.assertTrue(ct.until(5, lambda: not sup.pid_alive(child)), "grandchild survived group stop")
        os.unlink(childfile)

    def test_two_old_account_copies_three_restarts(self):
        path = os.path.join(self.home, "fleet-webhook.sh")
        with open(path, "w") as f:
            f.write("import signal\nsignal.alarm(90)\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                    "while True: signal.pause()\n")
        # A stubborn orphan also needs KILL. A separate active job with the
        # same script argument and another login's path must remain untouched.
        table = {"children": [], "tasks": [], "account": [
            {"name": "webhook", "keepalive": True, "argv": [sys.executable, path]}]}
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump(table, f)
        old = [self.orphan([sys.executable, path]) for _ in range(2)]
        other = os.path.join(self.d, "other-login", "fleet-webhook.sh")
        os.makedirs(os.path.dirname(other))
        with open(other, "w") as f:
            f.write("import signal\nsignal.alarm(90)\nwhile True: signal.pause()\n")
        untouched = self.orphan([sys.executable, other])
        decoy = self.orphan([sys.executable, "-c", "import signal; signal.alarm(90); signal.pause()", path])
        daemon = self.start_sup()

        def child():
            d = sup.read_json(os.path.join(self.state, "state.json"), {})
            pid = d.get("children", {}).get("alice/webhook", {}).get("pid")
            if pid:
                self.pids.add(pid)
            return pid

        pid = ct.until(10, child)
        self.assertTrue(pid)
        self.assertTrue(ct.until(5, lambda: all(not sup.pid_alive(x) for x in old)))
        for i in range(3):
            daemon.kill()
            daemon.wait()
            daemon = self.start_sup()
            self.assertTrue(ct.until(10, lambda: self.starts() == i + 2))
            self.assertEqual(child(), pid, "restart doubled the account unit")
            self.assertTrue(sup.pid_alive(untouched) and sup.pid_alive(decoy))
        daemon.terminate()
        daemon.wait(timeout=15)
        self.assertTrue(ct.until(5, lambda: not sup.pid_alive(pid)))

    def test_shared_identity_rejects_other_uid_path_and_stale_pid(self):
        old = self.orphan(self.ent["cmd"])
        self.assertTrue(ct.until(5, lambda: self.holder() == old))
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(sup.shared_proxy_pid(self.ent), old)
            with mock.patch.object(sup, "pid_uid", return_value=os.getuid() + 1):
                self.assertIsNone(sup.shared_proxy_pid(self.ent))
            with mock.patch.object(sup, "pid_cmd", return_value="python3 /other/fleet-cred-proxy.py serve --shared " + self.tenants):
                self.assertIsNone(sup.shared_proxy_pid(self.ent))
            with open(os.path.join(self.run, "pid"), "w") as f:
                f.write(str(os.getpid()))
            self.assertIsNone(sup.shared_proxy_pid(self.ent))
            self.assertTrue(sup.pid_alive(old))

    def test_process_identity_does_not_match_arguments(self):
        e = sup.account_entry({"name": "webhook", "argv": ["/bin/bash", "__HOME__/fleet-webhook.sh"],
                               "keepalive": True}, "alice", (501, 20, self.home), "/usr/local")
        path = os.path.join(self.home, "fleet-webhook.sh")
        self.assertTrue(sup.account_proc_is(e, "/bin/bash " + path))
        self.assertFalse(sup.account_proc_is(e, "/usr/bin/python3 /tmp/active-job.py " + path))
        self.assertFalse(sup.account_proc_is(e, "/bin/bash " + path + " --handler"))


if __name__ == "__main__":
    unittest.main()
