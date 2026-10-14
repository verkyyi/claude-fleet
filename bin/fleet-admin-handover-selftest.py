#!/usr/bin/env python3
"""fleet-admin-handover-selftest.py — the old admin agent's handover (issue #3725,
EPIC #3500 C15·b-4): bin/fleet-node-supervisor.py admin-handover (and the sweep that
runs it) + bin/fleet_admin_seat.py seat_connected. Driven by
bin/fleet-admin-handover-selftest.sh. A sandbox state / LaunchDaemons / passwd; the
hub a one-route server on 127.0.0.1 answering /v1/node/self.

  A  no old admin agent: nothing to do (0), no seat needed
  B  the seat's agent not connected (no token · the hub says not connected · the
     hub refuses the token): the old one stays (3), nothing moved
  C  connected, but the old agent's account-ops.json still holds an op (inflight,
     or a result in its outbox) or cannot be read: it stays (3); a tenant's
     (non-admin) agent is never this road's
  D  connected and its book empty (or none): booted out, its unit in the attic
     (kept, `attic restore` puts it back and the updater follows it again),
     admin-handover.json names it; a second run has nothing left (0)
  E  an op lands between the read and the bootout: put back (1)
  F  a unit that will not unload stays (1); the sweep does the handover too and
     records the waiting login (handover_waiting) for its 5-minute retry
  G  the book is found through the credential launcher's meta.json agent_argv
     --state, else the unit's own arguments, else <home>/.ccquota
"""
import http.server
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
SUP = os.path.join(BIN, "fleet-node-supervisor.py")
spec = importlib.util.spec_from_file_location("fns", SUP)
fns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fns)
TOK = "ccq_" + "A" * 43


class Hub(object):
    """GET /v1/node/self: 401 unless the token; {"connected": <self.connected>}."""
    def __init__(self):
        self.connected, self.token = True, TOK
        hub = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != "/v1/node/self":
                    self.send_response(404); self.end_headers(); return
                if self.headers.get("Authorization", "") != "Bearer " + hub.token:
                    self.send_response(401); self.end_headers(); return
                body = json.dumps({"endpoint_id": "e1", "connected": hub.connected,
                                   "status": "online" if hub.connected else "offline"}).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(body)

            def log_message(self, *a):
                pass
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class Handover(unittest.TestCase):
    # launchd fixtures everywhere (the supervisor reads FLEET_NODE_LAUNCHCTL as
    # launchd even on Linux CI); HandoverSystemd below is the systemd road
    mac = True

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="fah.")
        self.hub = Hub()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_NODE_", "FLEET_ADMIN_", "FLEET_CREDSEP_"))}
        self.dd = os.path.join(self.d, "LaunchDaemons")
        self.st = os.path.join(self.d, "db")
        os.makedirs(self.dd)
        users = os.path.join(self.d, "Users")
        pw = {}
        for who in ("bob", "carol"):
            os.makedirs(os.path.join(users, who))
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": os.path.join(users, who)}
        pw["bob"].update(groups=["staff", "admin"])          # the machine's admin
        with open(os.path.join(self.d, "passwd.json"), "w") as f:
            json.dump(pw, f)
        self.lclog = os.path.join(self.d, "lc.log")
        self.stuck = os.path.join(self.d, "stuck.txt")
        open(self.stuck, "w").close()
        lc = self.script("launchctl", (
            'echo "$*" >> %s\n'
            '[ "$1" = print ] || exit 0\n'
            'grep -qxF "${2##*/}" %s && exit 0\n'
            'exit 113\n') % (self.lclog, self.stuck))
        sc = self.script("systemctl", (
            'echo "$*" >> %s\n'
            '[ "$1" = is-active ] || exit 0\n'
            'grep -qxF "${3}" %s && exit 0\n'
            'exit 3\n') % (self.lclog, self.stuck))
        self.env.update({
            "FLEET_NODE_STATE": self.st, "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_RUNTIME": os.path.join(self.d, "rt"), "FLEET_NODE_DAEMON_DIR": self.dd,
            "FLEET_NODE_USERS": users, "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_PASSWD": os.path.join(self.d, "passwd.json"), "FLEET_NODE_TEST": "1",
            "FLEET_NODE_LAUNCHCTL": lc, "FLEET_NODE_SYSTEMCTL": sc, "FLEET_NODE_BOOTOUT_WAIT": "0.3",
            "FLEET_CREDSEP_ROOT_BASE": os.path.join(self.d, "cred"),
            "FLEET_ADMIN_ROLE": subprocess.check_output(["id", "-un"], text=True).strip(),
        })
        if not self.mac:
            del self.env["FLEET_NODE_LAUNCHCTL"]
        with open(self.env["FLEET_NODE_TABLE"], "w") as f:
            json.dump({"children": [], "tasks": []}, f)
        # the seat: admin/ with admin.conf (hub=) and agent.token (root-ish 0640)
        self.adir = os.path.join(self.st, "admin")
        os.makedirs(self.adir)
        with open(os.path.join(self.adir, "admin.conf"), "w") as f:
            f.write("bin=/x\nhub=%s\n" % self.hub.url)
        self.put_token(TOK)

    def tearDown(self):
        self.hub.close()
        shutil.rmtree(self.d, ignore_errors=True)

    def script(self, name, body):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write("#!/bin/bash\n" + body)
        os.chmod(p, 0o755)
        return p

    def put_token(self, tok):
        p = os.path.join(self.adir, "agent.token")
        with open(p, "w") as f:
            f.write(tok + "\n")
        os.chmod(p, 0o640)

    def label(self, login):
        return "com.ccquota.agent.%s" % login if self.mac else "ccquota-agent-%s.service" % login

    def old_unit(self, login, argv=None):
        """The login's old agent unit; argv defaults to `ccquota agent --state <d>/<login>-state`."""
        argv = argv or ["/usr/local/bin/ccquota", "agent", "--state", os.path.join(self.d, login + "-state")]
        if self.mac:
            p = os.path.join(self.dd, self.label(login) + ".plist")
            with open(p, "wb") as f:
                plistlib.dump({"Label": self.label(login), "ProgramArguments": argv, "UserName": login}, f)
        else:
            p = os.path.join(self.dd, self.label(login))
            with open(p, "w") as f:
                f.write("[Service]\nUser=%s\nExecStart=%s\n" % (login, " ".join(argv)))
        return p

    def book(self, login, inflight=None, outbox=None, raw=None, state=None):
        d = state or os.path.join(self.d, login + "-state")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "account-ops.json"), "w") as f:
            f.write(raw if raw is not None else json.dumps({"seen": ["o1"], "inflight": inflight or {},
                                                            "outbox": outbox or {}}))

    def run_sup(self, *args, **kw):
        e = dict(self.env, **kw.pop("env", {}))
        return subprocess.run([sys.executable, SUP] + list(args), env=e, capture_output=True, text=True, timeout=60)

    def attic(self):
        return fns.read_json(os.path.join(self.st, "attic", "index.json"), [])

    def handed(self):
        return fns.read_json(os.path.join(self.st, "admin-handover.json"), {})

    # -- A
    def test_a_nothing_to_hand_over(self):
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("no old admin agent here", r.stdout)
        shutil.rmtree(self.adir)
        self.assertEqual(self.run_sup("admin-handover").returncode, 0, "no seat and no old agent is not waiting")

    # -- B
    def test_b_seat_not_connected(self):
        p = self.old_unit("bob")
        self.hub.connected = False
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn("not connected", r.stdout)
        self.assertTrue(os.path.isfile(p))
        self.hub.connected, self.hub.token = True, "ccq_other" + "B" * 40
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("HTTP 401", r.stdout)
        os.unlink(os.path.join(self.adir, "agent.token"))
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertTrue(os.path.isfile(p), "the old agent left before the seat's was connected")
        self.assertEqual(self.attic(), [])
        shutil.rmtree(self.adir)
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 3, "no seat at all: the old agent is the only one — it stays")
        self.assertTrue(os.path.isfile(p))

    # -- C
    def test_c_book_not_empty_or_unreadable(self):
        p = self.old_unit("bob")
        for kw, word in ((dict(inflight={"o2": {"op": "create", "login": "dave", "pid": 1}}), "inflight 1"),
                         (dict(outbox={"o1": {"type": "account_result"}}), "outbox 1"),
                         (dict(raw="{not json"), "cannot be read")):
            self.book("bob", **kw)
            r = self.run_sup("admin-handover")
            self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
            self.assertIn(word, r.stdout)
            self.assertTrue(os.path.isfile(p), "handed over with %s" % word)
        self.assertEqual(self.attic(), [])
        # a tenant's own agent (carol is no admin) is account adopt's, never this
        q = self.old_unit("carol")
        os.unlink(p)
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue(os.path.isfile(q))

    # -- D
    def test_d_handed_over_and_restored(self):
        p = self.old_unit("bob")
        self.book("bob")
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("handed over", r.stdout)
        self.assertFalse(os.path.exists(p), "the old unit is still in the unit directory")
        log = open(self.lclog).read()
        self.assertIn("bootout system/com.ccquota.agent.bob" if self.mac else "disable --now ccquota-agent-bob.service", log)
        a = self.attic()
        self.assertEqual(len(a), 1)
        self.assertTrue(a[0]["keep"], "an attic copy of the old agent must not be purged")
        self.assertEqual(a[0]["handover"], "bob")
        self.assertTrue(os.path.isfile(a[0]["dst"]))
        self.assertEqual(self.handed()["bob"]["attic"], a[0]["id"])
        self.assertEqual(set(self.handed()), {"bob"})
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 0)
        self.assertIn("no old admin agent here", r.stdout)
        r = self.run_sup("attic", "list")
        self.assertIn("old admin agent of bob", r.stdout)
        r = self.run_sup("attic", "restore", a[0]["id"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.isfile(p))
        self.assertEqual(self.handed(), {}, "restored, the updater must follow it again")

    def test_d_no_book_is_nothing_held(self):
        p = self.old_unit("bob")
        r = self.run_sup("admin-handover", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("would hand over", r.stdout)
        self.assertTrue(os.path.isfile(p), "--dry-run moved it")
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertFalse(os.path.exists(p))

    # -- E
    def test_e_op_arrives_while_stopping(self):
        p = self.old_unit("bob")
        self.book("bob")
        # the bootout itself writes an inflight op into the book: put back
        state = os.path.join(self.d, "bob-state", "account-ops.json")
        late = json.dumps({"inflight": {"o9": {"op": "create", "login": "erin"}}})
        lc = self.script("lc2", (
            'echo "$*" >> %s\n'
            'case "$1" in bootout) printf %%s %s > %s ;; disable) printf %%s %s > %s ;; print|is-active) exit 3 ;; esac\n'
            'exit 0\n') % (self.lclog, json.dumps(late), state, json.dumps(late), state))
        r = self.run_sup("admin-handover", env={"FLEET_NODE_LAUNCHCTL" if self.mac else "FLEET_NODE_SYSTEMCTL": lc})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("put back", r.stdout)
        self.assertTrue(os.path.isfile(p), "an op was cut off: the old agent must come back")
        self.assertEqual(self.attic(), [])
        self.assertEqual(self.handed(), {})

    # -- F
    def test_f_will_not_unload_and_the_sweep(self):
        p = self.old_unit("bob")
        with open(self.stuck, "w") as f:
            f.write(self.label("bob") + "\n")
        r = self.run_sup("admin-handover")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertTrue(os.path.isfile(p))
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("old admin agent of bob left running", r.stdout)
        st = fns.read_json(os.path.join(self.st, "state.json"), {})
        self.assertEqual(st["sweep"]["handover_waiting"], ["bob"])
        open(self.stuck, "w").close()
        r = self.run_sup("sweep")
        self.assertIn("handed over old admin agent", r.stdout)
        self.assertFalse(os.path.exists(p))
        st = fns.read_json(os.path.join(self.st, "state.json"), {})
        self.assertEqual(st["sweep"]["handover_waiting"], [])

    # -- G
    def test_g_where_the_book_is(self):
        home = os.path.join(self.d, "Users", "bob")
        # the unit's own arguments, --state=<dir>
        p = self.old_unit("bob", ["/x/ccquota", "agent", "--state=" + os.path.join(self.d, "s1")])
        self.book("bob", inflight={"a": {}}, state=os.path.join(self.d, "s1"))
        self.assertIn("inflight 1", self.run_sup("admin-handover").stdout)
        # the credential launcher's meta.json wins over the unit
        os.makedirs(os.path.join(self.d, "cred", "bob"))
        with open(os.path.join(self.d, "cred", "bob", "meta.json"), "w") as f:
            json.dump({"login": "bob", "agent_argv": ["/x/ccquota", "agent", "-state", os.path.join(self.d, "s2")]}, f)
        self.book("bob", outbox={"b": {}}, state=os.path.join(self.d, "s2"))
        self.assertIn("outbox 1", self.run_sup("admin-handover").stdout)
        # no --state anywhere: <home>/.ccquota
        with open(os.path.join(self.d, "cred", "bob", "meta.json"), "w") as f:
            json.dump({"login": "bob", "agent_argv": ["/x/ccquota", "agent"]}, f)
        self.book("bob", inflight={"c": {}, "d": {}}, state=os.path.join(home, ".ccquota"))
        self.assertIn("inflight 2", self.run_sup("admin-handover").stdout)
        self.assertTrue(os.path.isfile(p))


@unittest.skipIf(fns.MAC, "systemd: Linux only")
class HandoverSystemd(Handover):
    mac = False


if __name__ == "__main__":
    unittest.main(verbosity=1)
