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
  N  the seated updater (#3670): `tick` as the seat stages into <state>/staging (no
     root cache, no signature), the core copies it, fills <root>/tools from the
     staged.json map, verifies, signs bin/ccquota with the machine identity (fake
     codesign / security / openssl), switches; `update outside` links the login,
     the next tick commits and `update prune` runs as root; a refused switch keeps
     current and the evidence; a step outside the list, a staged.json naming a
     non-artifact, a staged ccquota that is not the artifact — refused, nothing
     signed; install-state / sessions run as the login
  O  the node program on the seat (#3669): exec-as with the caller's three fds runs
     the job on them ({"ok","pid"}, then {"exit"}), the caller going away stops it;
     fds on another op, or not three, are refused; a "seat_agent" machine job is never
     started by the core while the switch is on (stop only; off = the core's, as before); `install --seat --agent`'s switch hands
     machine.env / logins/*.env / agent/ over and back, update-now moves into node/;
     the seated daemon runs that job ITSELF with --core <sock>, and a root copy it
     finds is stopped through the core before its own starts
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
REPO = os.path.dirname(BIN)
sys.path.insert(0, BIN)
import fleet_ed25519  # noqa: E402

CORE_FILES = ("fleet-node-core.py", "fleet_node_core.py", "fleet_ed25519.py", "fleet-node-supervisor.py",
              "fleet-node-update.py", "fleet_node_codesign.py")
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
        with open(os.path.join(self.state, "machine.env"), "w") as f:
            f.write("CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_NODE_TOKEN=secret\n")
        with open(os.path.join(self.state, "update.json"), "w") as f:
            f.write('{"phase": "idle"}\n')
        self.serve()
        lay = subprocess.run([sys.executable, "-c", "import importlib.util, sys; sp = importlib.util.spec_from_file_location"
                              "('s', sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); "
                              "m.seat_layout(m.Paths(), m.seat_ident())", os.path.join(self.bin, "fleet-node-supervisor.py")],
                             env=self.env, capture_output=True, text=True)
        self.assertEqual(lay.returncode, 0, lay.stderr)
        mode = lambda *p: stat.S_IMODE(os.stat(os.path.join(self.state, *p)).st_mode)
        self.assertTrue(os.path.islink(os.path.join(self.state, "state.json")))
        # the updater's files go with it (#3670): links into node/, its staging, the hub's address
        for n in ("update.json", "update-restart.json", "fetch.progress"):
            self.assertEqual(os.readlink(os.path.join(self.state, n)), os.path.join("node", n))
        self.assertEqual(json.load(open(os.path.join(self.state, "node", "update.json"))), {"phase": "idle"})
        self.assertEqual(mode("staging"), 0o770)
        self.assertEqual(open(os.path.join(self.state, "hub-url")).read(), "https://hub.example\n")
        self.assertEqual(mode("hub-url"), 0o644)
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


FAKE_FETCH = """#!/bin/sh
# ccquota release fetch … <sha> <dest> — a copy of $FAKE_REL/<sha>
[ "$1 $2" = "release fetch" ] || exit 2
for a; do :; done
dest=$a
sha=$(eval echo \\${$(($#-1))})
[ -d "$FAKE_REL/$sha" ] || { echo "no release $sha" >&2; exit 1; }
cp -R "$FAKE_REL/$sha" "$dest"
"""

FAKE_CODESIGN = """#!/bin/sh
# --force --sign … <file>: marks it; --verify … <file>: the mark is there
for a; do :; done
echo "$*" >> "$FAKE_SIGN_LOG"
case "$*" in
  *--force*) [ -e "$FAKE_SIGN_FAIL" ] && exit 1; printf 'SIGNED\\n' >> "$a" ;;
  *--verify*) tail -1 "$a" | grep -q '^SIGNED$' ;;
esac
"""


class N_SeatedUpdate(Sandbox):
    A = "a" * 40
    B = "b" * 40

    def setUp(self):
        Sandbox.setUp(self)
        write_pub(os.path.join(self.state, "release.pub"))
        self.rel = os.path.join(self.d, "rel")
        spec = importlib.util.spec_from_file_location("fnu_n", os.path.join(self.bin, "fleet-node-update.py"))
        saved = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(self.env)
            self.fnu = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.fnu)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        with open(os.path.join(REPO, "release.json"), "rb") as f:
            self.spec_bytes = f.read()
        self.names = self.fnu.pinned_artifacts(json.loads(self.spec_bytes.decode()), ["darwin-arm64"])
        self.signed_release(self.root, self.A)
        os.symlink(os.path.join(self.root, self.A), os.path.join(self.root, "current"))
        self.signed_release(self.rel, self.B)
        fake = os.path.join(self.d, "ccquota")
        with open(fake, "w") as f:
            f.write(FAKE_FETCH)
        os.chmod(fake, 0o755)
        # the seat reads the hub's address root copied out of machine.env
        with open(os.path.join(self.state, "hub-url"), "w") as f:
            f.write("https://hub.invalid\n")
        tools = os.path.join(self.d, "cs")
        os.makedirs(tools)
        for n, body in (("codesign", FAKE_CODESIGN), ("security", "#!/bin/sh\nexit 0\n"), ("openssl", "#!/bin/sh\nexit 0\n")):
            with open(os.path.join(tools, n), "w") as f:
                f.write(body)
            os.chmod(os.path.join(tools, n), 0o755)
        idd = os.path.join(self.state, "codesign")
        os.makedirs(idd)
        for n, b in (("identity.json", json.dumps({"sha1": "f" * 40, "cn": "fleet test"})),
                     ("identity.keychain-db", "k"), ("keychain.pass", "p")):
            with open(os.path.join(idd, n), "w") as f:
                f.write(b)
        self.signlog = os.path.join(self.d, "sign.log")
        self.env.update({
            "FLEET_NODE_CODESIGN_FORCE": "1",
            "FLEET_NODE_CODESIGN_CODESIGN": os.path.join(tools, "codesign"),
            "FLEET_NODE_CODESIGN_SECURITY": os.path.join(tools, "security"),
            "FLEET_NODE_CODESIGN_OPENSSL": os.path.join(tools, "openssl"),
            "FAKE_SIGN_LOG": self.signlog, "FAKE_SIGN_FAIL": os.path.join(self.d, "sign.fail"),
            "FAKE_REL": self.rel,
            "FLEET_NODE_CREDSEP_WAIT": "0",
            "FLEET_CREDSEP_ROOT_BASE": os.path.join(self.d, "cred"),
            "FLEET_BOOTSTRAP_CACHE": "off",
        })

    def signed_release(self, where, sha):
        files = {"release.json": self.spec_bytes}
        for n in CORE_FILES:
            with open(os.path.join(BIN, n), "rb") as f:
                files["bin/" + n] = f.read()
        arts = {n: ("#!/bin/sh\necho %s %s\n" % (n, sha[:7])).encode() for n in self.names}
        return make_release(where, sha, files, artifacts=arts)

    def tick(self, **extra):
        e = dict(self.env, FLEET_NODE_SEATED="1", FLEET_NODE_CCQUOTA=os.path.join(self.d, "ccquota"),
                 FLEET_NODE_UPDATE_TARGET=self.B, FLEET_NODE_UPDATE_PLATFORM="darwin-arm64",
                 FLEET_NODE_UPDATE_SETTLE="0", FLEET_NODE_UPDATE_LIB=os.path.join(self.d, "no-lib.sh"), **extra)
        r = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-update.py"), "tick"], env=e,
                           capture_output=True, text=True, timeout=120)
        try:
            with open(os.path.join(self.state, "update.json")) as f:
                return r, json.load(f)
        except IOError:
            return r, {}

    def cur(self):
        return os.path.basename(os.readlink(os.path.join(self.root, "current")))

    def test_seated_tick_switches_through_the_core(self):
        self.serve()
        r, st = self.tick()
        self.assertEqual((r.returncode, st.get("phase")), (0, "switched"), r.stdout + r.stderr + self.log())
        self.assertEqual(self.cur(), self.B)
        rel = os.path.join(self.root, self.B)
        self.assertFalse(os.path.exists(os.path.join(self.state, "staging", self.B)), "staging left behind")
        self.assertFalse([e for e in os.listdir(self.root) if e.startswith(".incoming")], "the core's copy left")
        # the tools the seat could not write: the core filled the cache from the staged map
        claude = [n for n in self.names if n.startswith("claude-")][0]
        out = subprocess.run([os.path.join(rel, "tools", "bin", "claude")], capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), "%s %s" % (claude, self.B[:7]))
        helper = os.path.join(rel, "tools", "bin", "codex-code-mode-host")
        self.assertTrue(os.path.isfile(os.path.realpath(helper)), "the helper did not land in the cache")
        self.assertTrue(os.path.realpath(helper).startswith(os.path.realpath(os.path.join(self.root, "tools")) + os.sep))
        # ccquota: the artifact, signed by the core (the seat signs nothing)
        cq = open(os.path.join(rel, "bin", "ccquota")).read()
        self.assertTrue(cq.endswith("SIGNED\n"), cq)
        self.assertEqual(open(self.signlog).read().count("--force"), 1, open(self.signlog).read())
        # the root half: update outside linked the login's tools
        self.assertIn("op=update", self.log())
        link = os.path.join(self.home, ".local", "bin", "claude")
        self.assertEqual(os.readlink(link), os.path.join(self.root, "current", "tools", "bin", "claude"))
        # a re-check of the signed release (the rollback's) takes the identity's signature
        r2 = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-core.py"), "verify", rel],
                            env=self.env, capture_output=True, text=True)
        self.assertEqual(r2.stdout.strip(), "ok", r2.stdout + r2.stderr)
        # the verify: committed, and prune ran as root through the core
        with open(os.path.join(self.state, "state.json"), "w") as f:
            json.dump({"supervisor": {"pid": os.getpid(), "heartbeat": time.time(), "runtime": self.B}}, f)
        r, st = self.tick()
        self.assertEqual(st.get("result"), "committed", r.stdout + r.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.state, "update-root.json")))
        self.assertGreaterEqual(self.log().count("op=update"), 3, self.log())

    def test_sign_failure_refuses_the_switch(self):
        self.serve()
        open(os.path.join(self.d, "sign.fail"), "w").close()
        r, st = self.tick()
        self.assertEqual(st.get("result"), "failed", r.stdout + r.stderr)
        self.assertIn("codesign", st.get("reason", ""))
        self.assertEqual(self.cur(), self.A)
        self.assertTrue(os.path.isdir(os.path.join(self.state, "staging", self.B)), "evidence gone")
        self.assertFalse(os.path.exists(os.path.join(self.root, self.B)))

    def test_seated_no_core_switches_nothing(self):
        r, _ = self.tick()
        self.assertEqual(r.returncode, 1)
        self.assertIn("root core does not answer", r.stderr)
        self.assertEqual(self.cur(), self.A)

    def stage_by_hand(self):
        """What a fooled seat could put in staging: B fetched, its map written."""
        d = os.path.join(self.state, "staging", self.B)
        shutil.copytree(os.path.join(self.rel, self.B), d)
        return d

    def test_seat_cannot_steer_the_root_half(self):
        self.serve()
        for args in ({"step": "rm -rf /"}, {"step": "outside", "argv": ["sh"]}, {"step": "../x"}):
            self.assertIn("refused", self.req("update", args), args)
        # a staged.json naming a file that is no artifact of the release
        d = self.stage_by_hand()
        h = hashlib.sha256(open(os.path.join(d, ".release", "artifacts", self.names[1]), "rb").read()).hexdigest()
        with open(os.path.join(d, ".release", "staged.json"), "w") as f:
            json.dump({"tools": {"claude/%s/claude" % h: "../../../etc/passwd"}}, f)
        r = self.req("switch", {"sha": self.B})
        self.assertIn("not an artifact", r.get("why", ""), r)
        with open(os.path.join(d, ".release", "staged.json"), "w") as f:
            json.dump({"tools": {"claude/../../x/claude": self.names[1]}}, f)
        self.assertIn("refused", self.req("switch", {"sha": self.B}))
        self.assertFalse(os.path.exists(os.path.join(self.root, "tools")), "a refused stage wrote the root cache")
        # a ccquota of the seat's own making: refused, and never signed
        with open(os.path.join(d, ".release", "staged.json"), "w") as f:
            f.write("{}")
        os.makedirs(os.path.join(d, "bin"), exist_ok=True)
        with open(os.path.join(d, "bin", "ccquota"), "w") as f:
            f.write("#!/bin/sh\necho mine\n")
        r = self.req("switch", {"sha": self.B})
        self.assertIn("bin/ccquota", r.get("why", ""), r)
        self.assertFalse(os.path.exists(self.signlog) and "--force" in open(self.signlog).read(), "the core signed it")
        self.assertEqual(self.cur(), self.A)

    def test_login_side_commands(self):
        e = dict(self.env, USER="alice")
        r = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-update.py"), "install-state", self.root],
                           env=e, capture_output=True, text=True)
        self.assertEqual(json.loads(r.stdout), {"exists": False, "linked": None, "escapes": False, "at": None})
        r = subprocess.run([sys.executable, os.path.join(self.bin, "fleet-node-update.py"), "sessions", "save", "../x"],
                           env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
class O_SeatAgent(Sandbox):
    def tool(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as f:
            f.write("#!/bin/bash\n" + body)
        os.chmod(path, 0o755)
        return path

    def stream(self, op, args, fds):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(30)
        s.connect(self.env["FLEET_NODE_CORE_SOCK"])
        line = (json.dumps({"op": op, "args": args}) + "\n").encode()
        s.sendmsg([line], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, b"".join(fd.to_bytes(4, sys.byteorder) for fd in fds))])
        return s

    @staticmethod
    def replies(s, n):
        buf, out = b"", []
        while len(out) < n:
            got = s.recv(4096)
            if not got:
                break
            buf += got
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                out.append(json.loads(line.decode()))
        return out

    def test_exec_as_on_the_callers_fds(self):
        self.serve()
        tool = self.tool("fleet-cat.sh", 'echo "as $USER $PWD"; cat; echo oops >&2; exit 4\n')
        i_r, i_w = os.pipe()
        o_r, o_w = os.pipe()
        e_r, e_w = os.pipe()
        s = self.stream("exec-as", {"login": "alice", "argv": [tool]}, [i_r, o_w, e_w])
        for fd in (i_r, o_w, e_w):
            os.close(fd)
        os.write(i_w, b"hello\n")
        os.close(i_w)
        r = self.replies(s, 2)
        s.close()
        self.assertTrue(r and r[0].get("ok") and r[0].get("pid"), r)
        self.assertEqual(r[1:], [{"exit": 4}], r)
        out = os.fdopen(o_r).read()
        self.assertEqual(out, "as alice %s\nhello\n" % os.path.realpath(self.home), out)
        self.assertEqual(os.fdopen(e_r).read(), "oops\n")
        self.assertIn("(stream)", self.log())
        # the same three on another op, or two on exec-as: refused, nothing ran
        nul = [os.open(os.devnull, os.O_RDWR) for _ in range(3)]
        for op, args, fds in (("kill", {"pid": 1}, nul), ("exec-as", {"login": "alice", "argv": [tool]}, nul[:2])):
            s = self.stream(op, args, fds)
            r = self.replies(s, 1)
            s.close()
            self.assertIn("refused", r[0], (op, r))
            self.assertIn("descriptor", r[0]["why"])
        # bin/ only, as without fds
        s = self.stream("exec-as", {"login": "alice", "argv": ["/bin/sh", "-c", "id"]}, nul)
        self.assertIn("refused", self.replies(s, 1)[0])
        s.close()
        for fd in nul:
            os.close(fd)

    def test_caller_gone_stops_the_job(self):
        self.serve()
        tool = self.tool("fleet-wait.sh", "exec sleep 60\n")
        nul = [os.open(os.devnull, os.O_RDWR) for _ in range(3)]
        s = self.stream("exec-as", {"login": "alice", "argv": [tool]}, nul)
        for fd in nul:
            os.close(fd)
        pid = self.replies(s, 1)[0]["pid"]
        alive = lambda: subprocess.call(["kill", "-0", str(pid)], stderr=subprocess.DEVNULL) == 0
        self.assertTrue(alive())
        s.close()
        self.assertTrue(until(15, lambda: not alive()), "the job outlived its caller")

    def seat_table(self):
        self.agent_args = os.path.join(self.d, "agent.args")
        agent = self.tool("fleet-agentish.sh", 'echo "$*" >> %s; trap "exit 0" TERM; while :; do sleep 0.2; done\n'
                          % self.agent_args)
        self.agent_cmd = ["/bin/bash", agent]
        with open(os.path.join(self.d, "table.json"), "w") as f:
            json.dump({"children": [{"name": "node-agent", "cmd": self.agent_cmd, "seat_agent": True}],
                       "tasks": [], "account": []}, f)

    def seat_passwd(self):
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        pw["_fleetnode"] = pw["fleetnode"] = {"uid": os.getuid(), "gid": os.getgid(), "home": "/var/empty"}
        with open(self.env["FLEET_NODE_PASSWD"], "w") as f:
            json.dump(pw, f)

    def test_seat_job_is_never_the_cores(self):
        self.seat_table()
        self.seat_passwd()
        self.serve()
        # the switch off (#3668's seat): still the core's job, started as root
        r = self.req("machine", {"job": "node-agent", "action": "start"})
        self.assertTrue(r.get("ok"), r)
        self.assertEqual(self.req("machine", {"job": "node-agent", "action": "stop"}).get("ok"), True)
        with open(os.path.join(self.state, "seat-agent"), "w") as f:
            f.write("{}\n")
        r = self.req("machine", {"job": "node-agent", "action": "start"})
        self.assertIn("refused", r)
        self.assertIn("runs as the seat", r["why"])
        self.assertEqual(self.req("machine", {"job": "node-agent", "action": "stop"}).get("ok"), True)

    def sup_py(self, code):
        r = subprocess.run([sys.executable, "-c", "import importlib.util, json, os, sys; "
                            "sp = importlib.util.spec_from_file_location('s', sys.argv[1]); "
                            "m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); p = m.Paths(); " + code,
                            os.path.join(self.bin, "fleet-node-supervisor.py")],
                           env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_switch_hands_the_token_files_over(self):
        self.seat_passwd()
        os.makedirs(os.path.join(self.state, "logins"))
        os.makedirs(os.path.join(self.state, "agent", "alice"))
        for f, m in (("machine.env", 0o644), (os.path.join("logins", "alice.env"), 0o640)):
            with open(os.path.join(self.state, f), "w") as fh:
                fh.write("CCQUOTA_TOKEN=x\n")
            os.chmod(os.path.join(self.state, f), m)
        os.chmod(os.path.join(self.state, "agent"), 0o755)
        self.assertEqual(self.sup_py("print(m.seat_agent_on(p), m.update_now_path(p))"),
                         "False %s" % os.path.join(self.state, "update-now"))
        self.assertEqual(self.sup_py("print(m.seat_agent_switch(p, True), m.seat_agent_on(p))"), "True True")
        mode = lambda *q: stat.S_IMODE(os.stat(os.path.join(self.state, *q)).st_mode)
        self.assertEqual((mode("machine.env"), mode("logins", "alice.env"), mode("agent")), (0o600, 0o600, 0o700))
        self.assertEqual(self.sup_py("print(m.update_now_path(p))"), os.path.join(self.state, "node", "update-now"))
        self.assertIn("--core %s" % self.env["FLEET_NODE_CORE_SOCK"],
                      self.sup_py("print(' '.join(m.seat_agent_cmd(['ccquota', 'agent', '--machine'])))"))
        self.assertEqual(self.sup_py("print(m.seat_agent_switch(p, False), m.seat_agent_on(p), m.update_now_path(p))"),
                         "True False %s" % os.path.join(self.state, "update-now"))
        self.assertFalse(os.path.exists(os.path.join(self.state, "seat-agent")))
        # no seat account: never on, whatever the marker says
        with open(os.path.join(self.state, "seat-agent"), "w") as f:
            f.write("{}\n")
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        del pw["_fleetnode"], pw["fleetnode"]
        with open(self.env["FLEET_NODE_PASSWD"], "w") as f:
            json.dump(pw, f)
        self.assertEqual(self.sup_py("print(m.seat_agent_on(p))"), "False")

    def test_seated_daemon_runs_the_node_program_itself(self):
        self.seat_table()
        self.seat_passwd()
        self.serve()
        # the root copy an older daemon left (the core finds it by its command)
        stray = subprocess.Popen(self.agent_cmd, start_new_session=True)
        self.procs.append(stray)
        self.assertTrue(until(10, lambda: os.path.exists(self.agent_args)))
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(stray.pid)], capture_output=True, text=True).stdout.strip()
        with open(os.path.join(self.state, "state.json"), "w") as f:
            json.dump({"children": {"node-agent": {"pid": stray.pid, "cmd": cmd}}}, f)
        self.sup_py("m.seat_layout(p, m.seat_ident()); m.seat_agent_switch(p, True)")
        seat = M_Seated.sup(self, ["run"], {"FLEET_NODE_SEATED": "1"})
        self.procs.append(seat)
        err = lambda: open(os.path.join(self.d, "sup.err")).read()
        self.assertTrue(until(20, lambda: stray.poll() is not None), "the root copy was not stopped: " + err())
        self.assertTrue(until(20, lambda: "the seat runs it now" in err()), err())
        self.assertTrue(until(20, lambda: "--core %s" % self.env["FLEET_NODE_CORE_SOCK"]
                              in open(self.agent_args).read()), err())
        self.assertNotIn('"action": "start"', self.log())   # never asked of the core
        seat.send_signal(signal.SIGTERM)
        seat.wait(timeout=30)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--make-release":
        # the BREAK-IT drill's seam: <root> <sha> [other] — a release under the
        # selftest key (or another key) + the key's release.pub beside it
        root, sha = sys.argv[2], sys.argv[3]
        make_release(root, sha, {"bin/x": sha.encode() + b"\n"},
                     secret=OTHER if sys.argv[4:5] == ["other"] else SECRET)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--make-staged":
        # the seat-stage drill's seam (#3670): <dir> <sha> — a release with a claude
        # and a ccquota artifact under the selftest key; prints the claude digest
        d = make_release(sys.argv[2], sys.argv[3], {"bin/x": b"x\n"},
                         artifacts={"claude-1-darwin-arm64": b"#!/bin/sh\necho claude\n",
                                    "ccquota-darwin-arm64": b"#!/bin/sh\necho ccquota\n"})
        print(hashlib.sha256(b"#!/bin/sh\necho claude\n").hexdigest())
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--write-pub":
        write_pub(sys.argv[2])
        sys.exit(0)
    unittest.main(verbosity=1)
