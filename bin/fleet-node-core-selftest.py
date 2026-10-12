#!/usr/bin/env python3
"""fleet-node-core-selftest.py — the root core in a sandbox (issue #3555, EPIC #3500 C13).

Driven by bin/fleet-node-core-selftest.sh. A real `fleet-node-core.py serve` on a
socket in a temp dir (FLEET_NODE_TEST=1: the peer is this uid, a login is this uid
under a fake passwd); nothing touches /var, /Library or a real login.

  A  the wire: not JSON, an extra key, an op outside the table, a wrong arg type,
     an arg too many — each {"refused"}, nothing runs, one log line apiece
  B  the peer: a core that takes another uid cuts us off before reading (log line);
     the socket is 0660
  C  run-as starts a job of the account table as its login and answers its exit on
     the same connection; one copy per (login, job); stop-as stops it; a job name
     outside the table / an unmanaged login is refused; `call --follow` exits with
     the job's rc and a TERM to it stops the job
  D  exec-as runs a file under <current>/bin as the login (rc + output); an argv[0]
     elsewhere (/bin/sh, a link out of bin/) is refused
  E  kill: a job of the core's, or a managed login's process; pid ≤ 1 and an
     unmanaged uid's process are refused
  F  memguard / power run their one script; a level / profile outside the list is refused
  G  switch: a release signed with the machine's key, every file as listed → current
     moves, .prev = old; a tampered file, another key, an unlisted file → refused,
     current stays, the staged copy kept; rollback goes back to .prev
  H  more refusals in a minute than FLEET_NODE_CORE_ALERT_N → ONE alert file
  I  the clients: available() false with FLEET_NODE_CORE=0, false for a sandbox that
     named no socket; the updater's as_login goes through exec-as when a core answers
  J  verify_release on a staged tree: tools links into <root>/tools by artifact digest
     (a helper beside its tool), bin/ccquota = its artifact
  K  the seat's ops (#3668): machine start / stop / held / hup by a NAME in the core's
     own table — a child and a task, one copy, the stand-in's TERM stops it, a root
     process the old daemon left is found by its command and stopped; a name outside
     the table, a job with its own op, an action outside the list, an extra key are
     refused; sweep / entry / report answer, a kind outside the list is refused
  L  the peer is re-read per connection: no seat ⇒ root only; the seat made ⇒ it is
     taken at once, with no restart of the core (its book kept)
  M  the seated daemon (FLEET_NODE_SEATED=1): its machine child runs as the core's
     job (op=machine in the core's log), state.json through <state>/state.json's
     link into node/; the handover — a root daemon told seat-handover.json exits
     leaving its child up, and the seat adopts it (nothing restarts); seat_layout's
     modes: the register shared 0750/0640, creds/ and a .env untouched
"""
import base64
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
import fleet_ed25519  # noqa: E402

CORE_FILES = ("fleet-node-core.py", "fleet_node_core.py", "fleet_ed25519.py", "fleet-node-supervisor.py",
              "fleet-node-update.py")
SECRET = hashlib.sha256(b"fleet-node-core-selftest").digest()
OTHER = hashlib.sha256(b"someone else").digest()


def until(secs, fn, step=0.05):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return fn()


def make_release(root, sha, files, secret=SECRET, artifacts=None):
    """<root>/<sha>/ — `files` {path: bytes} under the signed manifest (+ artifacts
    {name: bytes} in .release/artifacts/), signed with `secret`."""
    d = os.path.join(root, sha)
    man = {"schema": 1, "sha": sha, "files": [], "artifacts": []}
    for p, b in sorted(files.items()):
        full = os.path.join(d, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(b)
        man["files"].append({"path": p, "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)})
    for n, b in sorted((artifacts or {}).items()):
        full = os.path.join(d, ".release", "artifacts", n)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(b)
        man["artifacts"].append({"name": n, "sha256": hashlib.sha256(b).hexdigest(), "size": len(b)})
    mb = json.dumps(man, indent=2).encode()
    os.makedirs(os.path.join(d, ".release"), exist_ok=True)
    with open(os.path.join(d, ".release", "manifest.json"), "wb") as f:
        f.write(mb)
    with open(os.path.join(d, ".release", "manifest.sig"), "w") as f:
        f.write(base64.b64encode(fleet_ed25519.sign(secret, mb)).decode() + "\n")
    return d


def write_pub(path, secret=SECRET):
    with open(path, "w") as f:
        f.write("ed25519 %s\n" % base64.b64encode(fleet_ed25519.public_key(secret)).decode())


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fnc.")
        self.root = os.path.join(self.d, "root")
        self.state = os.path.join(self.d, "db")
        self.rt = os.path.join(self.root, "rt")
        self.bin = os.path.join(self.rt, "bin")
        os.makedirs(self.bin)
        os.makedirs(self.state)
        for n in CORE_FILES:
            shutil.copy(os.path.join(BIN, n), self.bin)   # copies: exec-as resolves argv[0] for real
        self.home = os.path.join(self.d, "Users", "alice")
        os.makedirs(self.home)
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump({"alice": {"uid": os.getuid(), "gid": os.getgid(), "home": self.home}}, f)
        self.accounts({"alice": {"managed": True}})
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("FLEET_")}
        self.env.update({
            "FLEET_NODE_TEST": "1", "FLEET_NODE_STATE": self.state, "FLEET_NODE_ROOT": self.root,
            "FLEET_NODE_RUNTIME": self.rt, "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_CORE_SOCK": os.path.join(self.d, "core.sock"),
            "FLEET_NODE_CORE_LOG": os.path.join(self.d, "core.log"),
            "FLEET_NODE_CORE_PEER_UID": str(os.getuid()),
            "FLEET_NODE_PASSWD": os.path.join(self.d, "passwd.json"),
            "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_USERS": os.path.join(self.d, "Users"),
            "FLEET_NODE_DAEMON_DIR": os.path.join(self.d, "LaunchDaemons"),
        })
        with open(os.path.join(self.home, "probe.sh"), "w") as f:
            f.write("#!/bin/bash\necho uid=$(id -u) user=$USER home=$HOME\n"
                    "[ -f %s/probe.long ] && exec sleep 60\nexit $(cat %s/probe.rc 2>/dev/null || echo 0)\n"
                    % (self.d, self.d))
        self.table([{"name": "probe", "every": 60, "out": "__HOME__/probe.out", "err": "__HOME__/probe.err",
                     "argv": ["/bin/bash", "__HOME__/probe.sh"], "env": {}}])
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        shutil.rmtree(self.d, ignore_errors=True)

    def accounts(self, a):
        with open(os.path.join(self.state, "accounts.json"), "w") as f:
            json.dump(a, f)

    def table(self, units):
        with open(os.path.join(self.d, "table.json"), "w") as f:
            json.dump({"children": [], "tasks": [], "account": units}, f)

    def serve(self, **extra):
        e = dict(self.env, **extra)
        p = subprocess.Popen([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "serve"], env=e,
                             stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.d, "core.err"), "a"))
        self.procs.append(p)
        self.assertTrue(until(10, lambda: os.path.exists(self.env["FLEET_NODE_CORE_SOCK"])), "the core never listened")
        return p

    def raw(self, line):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(30)
        s.connect(self.env["FLEET_NODE_CORE_SOCK"])
        s.sendall(line)
        buf = b""
        while b"\n" not in buf:
            try:
                got = s.recv(4096)
            except ConnectionResetError:   # Linux: closed with our request unread = cut off
                got = b""
            if not got:
                break
            buf += got
        s.close()
        return json.loads(buf.decode()) if buf.strip() else None

    def req(self, op, args):
        return self.raw((json.dumps({"op": op, "args": args}) + "\n").encode())

    def call(self, *args, **kw):
        return subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "call"] + list(args),
                              env=dict(self.env, **kw.get("env", {})), capture_output=True, text=True, timeout=60)

    def log(self):
        try:
            return open(self.env["FLEET_NODE_CORE_LOG"]).read()
        except IOError:
            return ""


class A_Wire(Sandbox):
    def test_outside_the_table_is_refused(self):
        self.serve()
        marker = os.path.join(self.d, "ran")
        cases = [b"not json\n",
                 b'["exec-as"]\n',
                 json.dumps({"op": "exec", "args": {"argv": ["/bin/sh", "-c", "touch " + marker]}}).encode() + b"\n",
                 json.dumps({"op": "kill", "args": {"pid": 2}, "as": "root"}).encode() + b"\n",
                 json.dumps({"op": "kill", "args": {"pid": "2"}}).encode() + b"\n",
                 json.dumps({"op": "kill", "args": {"pid": True}}).encode() + b"\n",
                 json.dumps({"op": "power", "args": {"profile": "spotlight-off", "argv": ["x"]}}).encode() + b"\n",
                 json.dumps({"op": "read-file", "args": {"path": "/etc/sudoers"}}).encode() + b"\n",
                 json.dumps({"op": "rollback"}).encode() + b"\n"]
        for c in cases:
            r = self.raw(c)
            self.assertIn("refused", r, c)
        self.assertFalse(os.path.exists(marker), "a refused request ran something")
        self.assertEqual(self.log().count("refused:"), len(cases), self.log())
        self.assertIn("op=read-file", self.log())


class B_Peer(Sandbox):
    def test_another_uid_is_cut_off(self):
        self.serve(FLEET_NODE_CORE_PEER_UID=str(os.getuid() + 4242))
        mode = stat.S_IMODE(os.stat(self.env["FLEET_NODE_CORE_SOCK"]).st_mode)
        self.assertEqual(mode, 0o660)
        r = self.req("rollback", {})
        self.assertIsNone(r, "a stranger got an answer")
        self.assertTrue(until(5, lambda: "is not the node daemon's" in self.log()), self.log())


class C_RunAs(Sandbox):
    def test_run_as_stop_as(self):
        self.serve()
        with open(os.path.join(self.d, "probe.rc"), "w") as f:
            f.write("3\n")
        r = self.call("run-as", json.dumps({"login": "alice", "job": "probe"}), "--follow")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        out = open(os.path.join(self.home, "probe.out")).read()
        self.assertIn("uid=%d user=alice home=%s" % (os.getuid(), self.home), out)
        self.assertIn("op=run-as", self.log())
        # one copy: a long one running, a second start answers running
        open(os.path.join(self.d, "probe.long"), "w").close()
        p = subprocess.Popen([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "call", "run-as",
                              json.dumps({"login": "alice", "job": "probe"}), "--follow"], env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(p)
        first = json.loads(p.stdout.readline().decode())
        self.assertTrue(first.get("ok") and first.get("pid"), first)
        self.assertEqual(self.req("run-as", {"login": "alice", "job": "probe"}).get("error"), "running")
        # TERM to the stand-in stops the job, and the stand-in ends
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=20)
        self.assertTrue(until(10, lambda: not os.path.exists("/proc/%d" % first["pid"]) and
                              subprocess.call(["kill", "-0", str(first["pid"])], stderr=subprocess.DEVNULL) != 0))
        self.assertEqual(self.req("stop-as", {"login": "alice", "job": "probe"}), {"ok": True, "stopped": False})

    def test_outside_the_account_table(self):
        self.serve()
        self.assertIn("refused", self.req("run-as", {"login": "alice", "job": "/bin/sh"}))
        self.assertIn("refused", self.req("run-as", {"login": "alice", "job": "svc:nope"}))
        self.accounts({"alice": {"managed": False}})
        self.assertIn("refused", self.req("run-as", {"login": "alice", "job": "probe"}))
        self.assertIn("refused", self.req("run-as", {"login": "root", "job": "probe"}))


class D_ExecAs(Sandbox):
    def test_exec_as_bin_only(self):
        self.serve()
        tool = os.path.join(self.bin, "fleet-probe.sh")
        with open(tool, "w") as f:
            f.write('#!/bin/bash\necho "as $USER $HOME $1"; exit 5\n')
        os.chmod(tool, 0o755)
        r = self.req("exec-as", {"login": "alice", "argv": [tool, "hi"]})
        self.assertEqual((r.get("ok"), r.get("rc")), (True, 5), r)
        self.assertIn("as alice %s hi" % self.home, r["out"])
        self.assertIn("refused", self.req("exec-as", {"login": "alice", "argv": ["/bin/sh", "-c", "id"]}))
        out = os.path.join(self.d, "outside.sh")
        with open(out, "w") as f:
            f.write("#!/bin/sh\nid\n")
        os.symlink(out, os.path.join(self.bin, "escape.sh"))
        self.assertIn("refused", self.req("exec-as", {"login": "alice", "argv": [os.path.join(self.bin, "escape.sh")]}))
        self.assertIn("refused", self.req("exec-as", {"login": "alice", "argv": []}))


class E_Kill(Sandbox):
    def test_kill_scope(self):
        self.serve()
        p = subprocess.Popen(["sleep", "60"])
        self.procs.append(p)
        self.assertIn("refused", self.req("kill", {"pid": 1}))
        self.accounts({})
        self.assertIn("refused", self.req("kill", {"pid": p.pid}), "an unmanaged uid's process was killed")
        self.assertIsNone(p.poll())
        self.accounts({"alice": {"managed": True}})
        r = self.req("kill", {"pid": p.pid})
        self.assertEqual(r.get("ok"), True, r)
        self.assertIsNotNone(p.wait(timeout=10))


class F_Fixed(Sandbox):
    def test_memguard_power(self):
        for n in ("fleet-memguard.sh", "fleet-spotlight.sh"):
            with open(os.path.join(self.bin, n), "w") as f:
                f.write('#!/bin/bash\necho "%s $* ${FLEET_MEM_SPIKE_ACTION:-kill}" >> %s/fixed.log\n'
                        % (n, self.d))
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.serve()
        self.assertEqual(self.req("memguard", {"level": "once"}).get("rc"), 0)
        self.assertEqual(self.req("memguard", {"level": "report"}).get("rc"), 0)
        self.assertEqual(self.req("power", {"profile": "spotlight-off"}).get("rc"), 0)
        self.assertIn("refused", self.req("memguard", {"level": "kill-all"}))
        self.assertIn("refused", self.req("power", {"profile": "shutdown"}))
        got = open(os.path.join(self.d, "fixed.log")).read().splitlines()
        self.assertEqual(got, ["fleet-memguard.sh --once kill", "fleet-memguard.sh --once report",
                               "fleet-spotlight.sh off --tick kill"])


class G_Switch(Sandbox):
    A = "a" * 40
    B = "b" * 40

    def setUp(self):
        Sandbox.setUp(self)
        write_pub(os.path.join(self.state, "release.pub"))
        make_release(self.root, self.A, {"bin/x": b"old\n"})
        os.symlink(os.path.join(self.root, self.A), os.path.join(self.root, "current"))

    def cur(self):
        return os.path.basename(os.readlink(os.path.join(self.root, "current")))

    def test_signed_switch_and_rollback(self):
        self.serve()
        make_release(os.path.join(self.state, "staging"), self.B, {"bin/x": b"new\n"})
        r = self.req("switch", {"sha": self.B})
        self.assertEqual(r, {"ok": True, "from": self.A, "to": self.B})
        self.assertEqual(self.cur(), self.B)
        self.assertEqual(os.path.basename(os.readlink(os.path.join(self.root, ".prev"))), self.A)
        self.assertFalse(os.path.exists(os.path.join(self.state, "staging", self.B)), "staging moved in")
        self.assertEqual(self.req("rollback", {}), {"ok": True, "from": self.B, "to": self.A})
        self.assertEqual(self.cur(), self.A)

    def refused_switch(self, why):
        r = self.req("switch", {"sha": self.B})
        self.assertIn("refused", r, why)
        self.assertEqual(self.cur(), self.A, "current moved on " + why)
        self.assertTrue(os.path.isdir(os.path.join(self.state, "staging", self.B)), "evidence gone: " + why)
        return r

    def test_tampered(self):
        self.serve()
        d = make_release(os.path.join(self.state, "staging"), self.B, {"bin/x": b"new\n"})
        with open(os.path.join(d, "bin", "x"), "wb") as f:
            f.write(b"evil\n")
        self.assertIn("digest", self.refused_switch("a tampered file")["why"])

    def test_other_key(self):
        self.serve()
        make_release(os.path.join(self.state, "staging"), self.B, {"bin/x": b"new\n"}, secret=OTHER)
        self.assertIn("signature", self.refused_switch("another key")["why"])

    def test_unlisted_file(self):
        self.serve()
        d = make_release(os.path.join(self.state, "staging"), self.B, {"bin/x": b"new\n"})
        with open(os.path.join(d, "bin", "planted.sh"), "w") as f:
            f.write("#!/bin/sh\n")
        self.assertIn("not in the signed manifest", self.refused_switch("an unlisted file")["why"])

    def test_wrong_sha_and_missing(self):
        self.serve()
        make_release(os.path.join(self.state, "staging"), self.B, {"bin/x": b"new\n"})
        os.rename(os.path.join(self.state, "staging", self.B), os.path.join(self.state, "staging", "c" * 40))
        self.assertIn("refused", self.req("switch", {"sha": "c" * 40}))
        self.assertIn("refused", self.req("switch", {"sha": "../../etc"}))
        self.assertEqual(self.cur(), self.A)


class H_Alert(Sandbox):
    def test_one_alert(self):
        self.serve(FLEET_NODE_CORE_ALERT_N="3")
        for _ in range(8):
            self.req("nope", {})
        alert = os.path.join(self.state, "core", "alert.json")
        self.assertTrue(os.path.exists(alert))
        self.assertEqual(self.log().count("ALERT"), 1, self.log())
        self.assertEqual(json.load(open(alert))["last"], "nope")


class I_Clients(Sandbox):
    def test_available_and_as_login(self):
        self.serve()
        spec = importlib.util.spec_from_file_location("fnu_core", os.path.join(self.bin, "fleet-node-update.py"))
        saved = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(self.env)
            fnu = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fnu)
            self.assertTrue(fnu.fns.core.available())
            os.environ["FLEET_NODE_CORE"] = "0"
            self.assertFalse(fnu.fns.core.available())
            del os.environ["FLEET_NODE_CORE"]
            sock = os.environ.pop("FLEET_NODE_CORE_SOCK")
            self.assertFalse(fnu.fns.core.available(), "a sandbox reached the machine's socket")
            os.environ["FLEET_NODE_CORE_SOCK"] = sock
            rc, out, err = fnu.as_login("alice", ["no-such-command"])
            self.assertNotEqual(rc, 0)
            self.assertIn("exec-as", self.log(), "as_login did not go through the core")
        finally:
            os.environ.clear()
            os.environ.update(saved)


class J_Staged(Sandbox):
    def test_staged_products(self):
        sha = "d" * 40
        tool = b"tool-bytes"
        helper = b"helper-bytes"
        cq = b"ccquota-bytes"
        d = make_release(self.root, sha, {"bin/x": b"x"},
                         artifacts={"claude-1-darwin-arm64": tool, "claude-helper-1-darwin-arm64": helper,
                                    "ccquota-darwin-arm64": cq})
        h = hashlib.sha256(tool).hexdigest()
        td = os.path.join(self.root, "tools", "claude", h)
        os.makedirs(td)
        for n, b in (("claude", tool), ("claude-helper", helper)):
            with open(os.path.join(td, n), "wb") as f:
                f.write(b)
        os.makedirs(os.path.join(d, "tools", "bin"))
        for n in ("claude", "claude-helper"):
            os.symlink(os.path.join(td, n), os.path.join(d, "tools", "bin", n))
        with open(os.path.join(d, "bin", "ccquota"), "wb") as f:
            f.write(cq)
        with open(os.path.join(d, ".release", "staged.json"), "w") as f:
            f.write("{}")
        write_pub(os.path.join(self.state, "release.pub"))
        r = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "verify", d],
                           env=self.env, capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "ok"), r.stderr)
        with open(os.path.join(td, "claude-helper"), "wb") as f:
            f.write(b"swapped")
        r = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "verify", d],
                           env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("tools/bin/claude-helper", r.stdout)


class K_Machine(Sandbox):
    def machine_table(self):
        for n, body in (("fleet-loop.sh", "trap 'exit 0' TERM; echo up; while :; do sleep 0.2; done\n"),
                        ("fleet-once.sh", "echo once $(id -u) HOME=$HOME; exit 4\n")):
            with open(os.path.join(self.bin, n), "w") as f:
                f.write("#!/bin/bash\n" + body)
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.loop = ["/bin/bash", os.path.join(self.bin, "fleet-loop.sh")]
        with open(os.path.join(self.d, "table.json"), "w") as f:
            json.dump({"children": [{"name": "looper", "cmd": self.loop}],
                       "tasks": [{"name": "once", "every": 60, "cmd": ["/bin/bash", os.path.join(self.bin, "fleet-once.sh")]},
                                 {"name": "memguard", "every": 10, "cmd": ["/bin/true"],
                                  "core": {"op": "memguard", "args": {"level": "once"}}}],
                       "account": []}, f)

    def test_machine_ops(self):
        self.machine_table()
        self.serve()
        r = self.call("machine", json.dumps({"job": "once", "action": "start"}), "--follow")
        self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
        self.assertIn("once %d HOME=%s" % (os.getuid(), os.path.join(self.state, "home")),
                      open(os.path.join(self.d, "log", "tasks", "once.log")).read())
        p = subprocess.Popen([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "call", "machine",
                              json.dumps({"job": "looper", "action": "start"}), "--follow"], env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(p)
        first = json.loads(p.stdout.readline().decode())
        self.assertTrue(first.get("ok") and first.get("pid"), first)
        self.assertEqual(self.req("machine", {"job": "looper", "action": "start"}).get("error"), "running")
        self.assertEqual(self.req("machine", {"job": "looper", "action": "held"}), {"ok": True, "held": ""})
        self.assertIn("refused", self.req("machine", {"job": "looper", "action": "hup"}))
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=20)
        self.assertTrue(until(10, lambda: subprocess.call(["kill", "-0", str(first["pid"])],
                                                          stderr=subprocess.DEVNULL) != 0), "the job outlived its stand-in")
        # what the root daemon left: found by its command, never by a pid it is handed
        left = subprocess.Popen(self.loop, stdout=subprocess.DEVNULL, start_new_session=True)
        self.procs.append(left)
        time.sleep(0.3)
        r = self.req("machine", {"job": "looper", "action": "start"})
        self.assertEqual((r.get("error"), r.get("pid")), ("running (left by the root daemon)", left.pid), r)
        r = self.req("machine", {"job": "looper", "action": "stop"})
        self.assertEqual((r.get("ok"), r.get("strays")), (True, 1), r)
        self.assertIsNotNone(left.wait(timeout=10))
        marker = os.path.join(self.d, "ran")
        for args in ({"job": "/bin/sh", "action": "start"}, {"job": "nope", "action": "start"},
                     {"job": "memguard", "action": "start"}, {"job": "looper", "action": "exec"},
                     {"job": "looper", "action": "start", "argv": ["touch", marker]}, {"job": "looper"}):
            self.assertIn("refused", self.req("machine", args), args)
        self.assertFalse(os.path.exists(marker))

    def test_sweep_entry_report(self):
        self.machine_table()
        self.serve()
        r = self.req("sweep", {})
        self.assertTrue(r.get("ok") and isinstance(r.get("result"), dict), r)
        self.assertEqual(self.req("entry", {}), {"ok": True, "result": None, "audit": None})
        t = self.req("report", {"kind": "table"})
        self.assertEqual([c["name"] for c in t["table"]["children"]], ["looper"], t)
        self.assertIn("ok", self.req("report", {"kind": "fda"}).get("reading", {}))
        self.assertIn("bad", self.req("report", {"kind": "tenants"}).get("reading", {}))
        self.assertIsInstance(self.req("report", {"kind": "lanes"}).get("reading"), dict)
        for line in ({"op": "report", "args": {"kind": "file:/etc/sudoers"}}, {"op": "sweep", "args": {"dry": True}},
                     {"op": "entry", "args": {"keys": "ssh-ed25519 AAAA"}}):
            self.assertIn("refused", self.raw((json.dumps(line) + "\n").encode()), line)


class L_PeerPerConnection(Sandbox):
    def test_seat_taken_at_once(self):
        env = {k: v for k, v in self.env.items() if k != "FLEET_NODE_CORE_PEER_UID"}
        self.env = env
        self.serve()
        self.assertIsNone(self.req("report", {"kind": "lanes"}), "no seat: anyone but root was answered")
        pw = json.load(open(env["FLEET_NODE_PASSWD"]))
        pw["_fleetnode"] = {"uid": os.getuid(), "gid": os.getgid(), "home": "/var/empty"}
        pw["fleetnode"] = pw["_fleetnode"]
        with open(env["FLEET_NODE_PASSWD"], "w") as f:
            json.dump(pw, f)
        self.assertEqual(self.req("report", {"kind": "lanes"}).get("ok"), True, self.log())
        self.assertEqual(len(self.procs), 1)
        self.assertIsNone(self.procs[0].poll(), "the core restarted")


class M_Seated(Sandbox):
    def sup(self, args, extra=None, **kw):
        e = dict(self.env, FLEET_NODE_TICK="0.2", FLEET_NODE_LAUNCHCTL="", FLEET_NODE_WATCHDOG_SECS="0",
                 FLEET_NODE_TENANT_EVERY="100000", FLEET_NODE_SWEEP_EVERY="100000", **(extra or {}))
        return subprocess.Popen([sys.executable, os.path.join(self.bin, "fleet-node-supervisor.py")] + args, env=e,
                                stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.d, "sup.err"), "a"), **kw)

    def st(self):
        try:
            return json.load(open(os.path.join(self.state, "state.json")))
        except (IOError, ValueError):
            return {}

    def test_seated_daemon_and_handover(self):
        K_Machine.machine_table(self)
        with open(os.path.join(self.d, "table.json")) as f:
            t = json.load(f)
        t["tasks"] = []
        with open(os.path.join(self.d, "table.json"), "w") as f:
            json.dump(t, f)
        # a root daemon (no seat) runs the child itself
        root = self.sup(["run"])
        self.procs.append(root)
        pid = until(15, lambda: (self.st().get("children", {}).get("looper") or {}).get("pid"))
        self.assertTrue(pid, open(os.path.join(self.d, "sup.err")).read())
        # the handover: the root daemon goes, its child stays
        with open(os.path.join(self.state, "seat-handover.json"), "w") as f:
            json.dump({"at": time.time()}, f)
        root.send_signal(signal.SIGTERM)
        root.wait(timeout=20)
        self.assertEqual(subprocess.call(["kill", "-0", str(pid)], stderr=subprocess.DEVNULL), 0,
                         "the handover stopped the child")
        os.remove(os.path.join(self.state, "seat-handover.json"))
        # the layout, then the seat comes up and adopts it — no restart
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        pw["_fleetnode"] = {"uid": os.getuid(), "gid": os.getgid(), "home": "/var/empty"}
        pw["fleetnode"] = pw["_fleetnode"]
        with open(self.env["FLEET_NODE_PASSWD"], "w") as f:
            json.dump(pw, f)
        sd = os.path.join(self.state, "logins", "alice", "services")
        os.makedirs(os.path.join(self.state, "logins", "alice", "creds"))
        os.makedirs(sd)
        with open(os.path.join(sd, "web.json"), "w") as f:
            f.write("{}\n")
        with open(os.path.join(self.state, "logins", "alice.env"), "w") as f:
            f.write("CCQUOTA_NODE_TOKEN=x\n")
        for d, m in ((os.path.join(self.state, "logins"), 0o700), (os.path.join(self.state, "logins", "alice"), 0o700),
                     (os.path.join(self.state, "logins", "alice", "creds"), 0o700), (sd, 0o700)):
            os.chmod(d, m)
        os.chmod(os.path.join(sd, "web.json"), 0o600)
        os.chmod(os.path.join(self.state, "logins", "alice.env"), 0o600)
        self.serve()
        lay = subprocess.run([sys.executable, "-c", "import importlib.util, sys; sp = importlib.util.spec_from_file_location"
                              "('s', sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); "
                              "m.seat_layout(m.Paths(), m.seat_ident())", os.path.join(self.bin, "fleet-node-supervisor.py")],
                             env=self.env, capture_output=True, text=True)
        self.assertEqual(lay.returncode, 0, lay.stderr)
        mode = lambda *p: stat.S_IMODE(os.stat(os.path.join(self.state, *p)).st_mode)
        self.assertTrue(os.path.islink(os.path.join(self.state, "state.json")))
        self.assertEqual((mode("logins"), mode("logins", "alice"), mode("logins", "alice", "services"),
                          mode("logins", "alice", "services", "web.json"), mode("logins", "alice", "creds"),
                          mode("logins", "alice.env"), mode("logins", "alice", "runs")),
                         (0o750, 0o750, 0o750, 0o640, 0o700, 0o600, 0o770))
        seat = self.sup(["run"], {"FLEET_NODE_SEATED": "1"})
        self.procs.append(seat)
        self.assertTrue(until(15, lambda: "adopted child looper pid %d" % pid in open(os.path.join(self.d, "sup.err")).read()),
                        open(os.path.join(self.d, "sup.err")).read())
        # it dies: the seat starts it again — through the core, as a machine job
        os.kill(pid, signal.SIGTERM)
        self.assertTrue(until(20, lambda: "op=machine" in self.log() and "ok pid" in self.log()), self.log())
        self.assertTrue(os.path.isfile(os.path.join(self.state, "node", "state.json")))
        self.assertTrue(until(10, lambda: (self.st().get("children", {}).get("looper") or {}).get("status") == "supervised"))
        # the seat asks the core for a login's job: it needs no root to name one
        spec = importlib.util.spec_from_file_location("fns_seat", os.path.join(self.bin, "fleet-node-supervisor.py"))
        fns = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fns)
        other = {"uid": os.getuid() + 7, "script": None}
        self.assertIsNone(fns.account_runnable(other, True))
        if os.getuid() != 0:
            self.assertIn("needs root", fns.account_runnable(other))
        seat.send_signal(signal.SIGTERM)
        seat.wait(timeout=30)
        # the seat's stop took the core's job with it (a TERM to its stand-in)
        self.assertTrue(until(10, lambda: "op=machine args=" in self.log() and
                              subprocess.run(["pgrep", "-f", "fleet-loop.sh"], capture_output=True).returncode != 0),
                        "the core's job outlived the seat's stop")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--make-release":
        # the BREAK-IT drill's seam: <root> <sha> [other] — a release under the
        # selftest key (or another key) + the key's release.pub beside it
        root, sha = sys.argv[2], sys.argv[3]
        make_release(root, sha, {"bin/x": sha.encode() + b"\n"},
                     secret=OTHER if sys.argv[4:5] == ["other"] else SECRET)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--write-pub":
        write_pub(sys.argv[2])
        sys.exit(0)
    unittest.main(verbosity=1)
