#!/usr/bin/env python3
# selftest-entry
"""Retired Parent paths cannot deliver; old payloads and own results stay readable."""
import importlib.util
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

BIN = Path(__file__).resolve().parent


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="parent-retirement-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.conf = self.root / "conf"
        self.sock = "parent-retired-" + uuid.uuid4().hex[:10]
        self.fleet = self.conf / "fleets" / self.sock
        self.fleet.mkdir(parents=True)
        (self.fleet / "conf").write_text("")
        self.env = {k:v for k,v in os.environ.items()
                    if not k.startswith(("FLEET_", "CCQUOTA_")) and k not in ("TMUX", "TMUX_PANE")}
        self.env.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.conf), FLEET_SKIP_GLOBAL_CONF="1")
        self.book = self.fleet / "delivery.ndjson"
        self.q = self.fleet / "peer-queue"

    def run_cmd(self, *args, **kwargs):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=10, **kwargs)

    def queue(self, action, *args, **kwargs):
        return self.run_cmd("bash", str(BIN / "fleet-peer-queue.sh"), action, "-L", self.sock, *args, **kwargs)

    def rows(self):
        return [json.loads(l) for l in self.book.read_text().splitlines()]

    def test_old_entrypoints_return_immediately_without_writes(self):
        entries = [("bash", "fleet-await.sh", "7", "--timeout", "7200"),
                   ("bash", "fleet-await.sh", "--task", "T42"),
                   ("bash", "fleet-children.sh", "--json"),
                   ("bash", "fleet-children-flush.sh", "--force"),
                   ("bash", "fleet-report-delivery.sh", "_local", "/missing"),
                   (sys.executable, "fleet_report_delegation.py", "deliver", "/missing"),
                   (sys.executable, "fleet_report_delegation.py", "grant"),
                   (sys.executable, "fleet-peer-hand.py", "hand", "--book", "/missing"),
                   (sys.executable, "fleet_task_control.py", "receive", "--file", "/missing"),
                   (sys.executable, "fleet_task_control.py", "children", "--task", "T42"),
                   (sys.executable, "fleet_task_control.py", "await", "--task", "T42")]
        before = sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))
        for exe, name, *args in entries:
            with self.subTest(name=name, args=args):
                p = self.run_cmd(exe, str(BIN / name), *args)
                self.assertIn("RETIRED", p.stdout + p.stderr)
                self.assertNotEqual(p.returncode, 75)
                if name != "fleet-children-flush.sh":
                    self.assertNotEqual(p.returncode, 0)
        self.assertEqual(sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*")), before)

    def test_old_queue_payload_preserved_and_failed_once(self):
        self.q.mkdir()
        originals = {}
        for kind in ("report", "delegated_report"):
            data = dict(rid=kind, kind=kind, to_fid=str(uuid.uuid4()), to_key="scratch-1", to="old-parent",
                        created=1, text="full original \n 中文", delegation={"original": "untouched"})
            path = self.q / (kind + ".json")
            originals[path] = json.dumps(data, ensure_ascii=False).encode()
            path.write_bytes(originals[path])
        p = self.queue("drain")
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        for path, raw in originals.items():
            self.assertFalse(path.exists())
            self.assertEqual(Path(str(path)+".retired").read_bytes(), raw)
        self.assertEqual([r["state"] for r in self.rows()], ["FAILED", "FAILED"])
        before = self.book.read_bytes()
        self.assertEqual(self.queue("drain").returncode, 0)
        self.assertEqual(self.book.read_bytes(), before)
        self.assertFalse((self.conf / "global").exists())

    def test_new_report_put_fails_and_preserves_full_words(self):
        for kind in ("report", "delegated_report"):
            p = self.queue("put", "--kind", kind, "--rid", kind, "--to-key", "scratch-9",
                           input="original " * 2000)
            self.assertEqual(p.returncode, 2, p.stdout+p.stderr)
            self.assertIn("RETIRED", p.stdout)
        self.assertFalse(list(self.q.glob("*.json")))
        archived = [json.loads(p.read_text()) for p in self.q.glob("*.retired")]
        self.assertEqual(len(archived), 2)
        self.assertTrue(all(r["text"] == "original " * 2000 for r in archived))
        self.assertTrue(all(r["state"] == "FAILED" for r in self.rows()))

    def test_old_hub_queue_and_receipts_never_become_reminders(self):
        for kind in ("report", "child_report", "delegated_report"):
            row = dict(rid=kind, kind=kind, state="QUEUED", ts=1, via="hub", report={"summary":"kept"})
            with self.book.open("a") as stream:
                stream.write(json.dumps(row)+"\n")
        p = self.queue("stale", "--secs", "1")
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual([r["state"] for r in self.rows()][-3:], ["FAILED"]*3)
        before = self.book.read_bytes()
        self.assertEqual(self.queue("stale", "--secs", "1").returncode, 0)
        self.assertEqual(self.book.read_bytes(), before)
        p = self.queue("note", "--kind", "child_report", "--rid", "child_report", "--state", "EXPIRED")
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(self.rows()[-1]["state"], "FAILED")
        self.assertFalse((self.conf / "global").exists())

    def test_late_receipt_and_drain_preserve_settled_report_history(self):
        self.q.mkdir()
        for kind in ("report", "child_report", "delegated_report"):
            for state in ("DELIVERED", "FAILED", "EXPIRED", "HANDED"):
                rid = kind + state
                with self.book.open("a") as stream:
                    stream.write(json.dumps(dict(rid=rid, kind=kind, state=state, ts=1))+"\n")
                raw = json.dumps(dict(rid=rid, kind=kind, created=1, text="original words"))
                (self.q / (rid+".json")).write_text(raw)
        before = self.book.read_bytes()
        for row in self.rows():
            p = self.queue("note", "--kind", "child_report", "--rid", row["rid"], "--state", "EXPIRED")
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(self.queue("drain").returncode, 0)
        self.assertEqual(self.queue("stale", "--secs", "1").returncode, 0)
        self.assertEqual(self.book.read_bytes(), before)
        self.assertEqual(len(list(self.q.glob("*.retired"))), 12)

    def test_concurrent_retirement_writes_one_terminal_row(self):
        self.q.mkdir()
        for i in range(8):
            row = dict(rid=str(i), kind="report", state="QUEUED", ts=1, via="hub")
            with self.book.open("a") as stream:
                stream.write(json.dumps(row)+"\n")
            (self.q / (str(i)+".json")).write_text(json.dumps(dict(row, text="payload", created=1)))
        calls = [("stale", "--secs", "1"), ("drain",)] * 2
        calls += [("note", "--kind", "child_report", "--rid", str(i), "--state", "DELIVERED") for i in range(8)]
        with ThreadPoolExecutor(max_workers=6) as pool:
            outcomes = list(pool.map(lambda args: self.queue(*args), calls))
        self.assertTrue(all(p.returncode == 0 for p in outcomes), [(p.returncode, p.stderr) for p in outcomes])
        for i in range(8):
            settled = [r for r in self.rows() if r["rid"] == str(i) and r["state"] != "QUEUED"]
            self.assertEqual([r["state"] for r in settled], ["FAILED"])

    def test_retired_archive_never_overwrites_previous_evidence(self):
        self.q.mkdir()
        path = self.q / "old.json"
        archived = self.q / "old.json.retired"
        archived.write_bytes(b"previous bytes")
        current = json.dumps(dict(rid="old", kind="report", text="new evidence", created=1)).encode()
        path.write_bytes(current)
        p = self.queue("drain")
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual(archived.read_bytes(), b"previous bytes")
        self.assertFalse(path.exists())
        extra = list(self.q.glob("old.json.retired.*"))
        self.assertEqual(len(extra), 1)
        self.assertEqual(extra[0].read_bytes(), current)

    def test_message_queue_still_delivers_through_existing_adapter(self):
        # Only this private tmux socket is touched. Replace the final agent
        # adapter with a file sink, keeping real identity lookup and queue flow.
        p = self.run_cmd("tmux", "-L", self.sock, "-f", "/dev/null", "new-session", "-d", "-s", self.sock, "sleep 60")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.addCleanup(lambda: self.run_cmd("tmux", "-L", self.sock, "kill-server"))
        fid = str(uuid.uuid4())
        self.run_cmd("tmux", "-L", self.sock, "set-window-option", "-t", self.sock+":0", "@fleet_id", fid)
        p = self.queue("put", "--kind", "message", "--rid", "message-1", "--to-fid", fid, input="hello peer")
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        shadow = self.root / "bin"
        shadow.mkdir()
        for f in BIN.iterdir():
            if f.name != "fleet-lib.sh":
                (shadow/f.name).symlink_to(f)
        (shadow/"fleet-lib.sh").write_text('. "'+str(BIN/'fleet-lib.sh')+'"\n'
            'fleet_agent_deliver() { printf "%s" "$3" >> "$FLEET_CONF_DIR/delivered"; }\n')
        p = self.run_cmd("bash", str(shadow/"fleet-peer-queue.sh"), "drain", "-L", self.sock)
        self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        self.assertEqual((self.conf/"delivered").read_text(), "hello peer")
        self.assertEqual(self.rows()[-1]["state"], "DELIVERED")
        self.assertFalse(list(self.q.glob("*.json")))
        self.assertEqual(self.queue("wait", "--rid", "message-1", "--secs", "0").returncode, 0)

    def test_delegation_history_is_read_only(self):
        absent = self.run_cmd(sys.executable, str(BIN/"fleet_report_delegation.py"), "audit")
        self.assertEqual(absent.returncode, 0, absent.stderr)
        self.assertEqual(json.loads(absent.stdout), [])
        path = self.conf / "report-delegation/audit.ndjson"
        self.assertFalse(path.parent.exists())
        path.parent.mkdir()
        raw = b'{"action":"grant","id":"old","parent":"p","target":"t"}\n'
        path.write_bytes(raw)
        for cmd in ("audit", "show"):
            p = self.run_cmd(sys.executable, str(BIN/"fleet_report_delegation.py"), cmd)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(json.loads(p.stdout)[0]["id"], "old")
            self.assertEqual(path.read_bytes(), raw)

    def test_new_mcp_list_hides_old_handlers_without_removing_them(self):
        for group in ("core", "orch"):
            p = self.run_cmd(sys.executable, str(BIN/"fleet-mcp.py"), "--group", group, "--list")
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse(set(p.stdout.splitlines()) & {"report", "await", "children"})
        p = self.run_cmd(sys.executable, str(BIN/"fleet-mcp.py"), "--probe")
        self.assertTrue({"report", "await", "children"} <= set(json.loads(p.stdout)["tools"]))
        for name, args in (("await", '{"issue":7}'), ("children", '{}')):
            p = self.run_cmd(sys.executable, str(BIN/"fleet-mcp.py"), "--call", name, args)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("RETIRED", p.stdout+p.stderr)


if __name__ == "__main__":
    unittest.main()
