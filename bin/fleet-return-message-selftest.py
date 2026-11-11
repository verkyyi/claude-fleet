#!/usr/bin/env python3
# selftest-entry
"""Cross-machine replies reach the native inbox; queued/failed receipts stay visible.

Reuse the isolated socket and inbox fixtures from the agent delivery selftest.
No live fleet, hub, agent, credentials or other person's window is used.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
import uuid

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("delivery_fixture", BIN / "fleet-agent-deliver-selftest.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@unittest.skipUnless(fixture.TMUX, "tmux unavailable")
class ReturnMessage(unittest.TestCase):
    def setUp(self):
        self.r = fixture.Rig(self, "claude")
        self.addCleanup(self.r.close)
        self.r.env.update(FLEET_SKIP_GLOBAL_CONF="1", CCQUOTA_FLEET="1")
        self.fid = str(uuid.uuid4())
        self.r.opt("@fleet_id", self.fid)
        self.r.opt("@norepo", "1")
        self.run_cmd("python3", "-c", "import fleet_control,sys; fleet_control.Control(sys.argv[1]).inventory()", str(self.r.conf))
        p = self.run_cmd("bash", "-c", '. "$1/fleet-lib.sh"; fleet_uuid "$2"', "-", str(BIN), self.r.label)
        self.local = p.stdout.strip() + "/" + self.fid
        self.remote_fid = str(uuid.uuid4())
        self.remote = str(uuid.uuid4()) + "/" + self.remote_fid

    def run_cmd(self, *argv, input=None, check=True):
        p = subprocess.run(argv, input=input, text=True, capture_output=True,
                           env=self.r.env, cwd=BIN, timeout=30)
        if check:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def deliver(self, relay):
        return self.run_cmd("bash", str(BIN / "fleet-hub-node.sh"), "deliver",
                            input=json.dumps(relay), check=False)

    def message(self, suffix="reply"):
        return dict(id=self.remote + "#" + suffix, kind="message", **{"from": self.remote},
                    to=self.local, from_node="remote-node", payload=dict(text="return result evidence"))

    def receipt(self, suffix, status, detail):
        rid = self.local + "#" + suffix
        p = self.deliver(dict(id=rid, kind="receipt", **{"from": self.remote}, to=self.local,
                              payload=dict(rid=rid, kind="message", to=self.remote, status=status, detail=detail)))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return self.run_cmd("bash", str(BIN / "fleet-peer-queue.sh"), "wait", "-L", self.r.label,
                            "--rid", rid, "--secs", "0", check=False)

    def test_remote_reply_reaches_native_inbox_after_recipient_rename(self):
        self.r.tm("rename-window", "-t", self.r.win, "renamed-recipient")
        p = self.deliver(self.message())
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("sent →", p.stderr)
        self.assertTrue(self.r.landed("return result evidence"))
        self.assertIn("[from " + self.remote_fid + " on remote-node]", self.r.inbox.got[-1])
        # Hub retries the same envelope after a lost acknowledgment: one inbox copy.
        p = self.deliver(self.message())
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(len(self.r.inbox.got), 1)

    def test_unready_inbox_is_queued_then_replayed(self):
        self.r.inbox.close()
        p = self.deliver(self.message("held"))
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("queued at ", p.stderr)
        p = self.receipt("held", "delivered", p.stderr.strip())
        self.assertEqual((p.returncode, p.stdout.strip()), (3, "QUEUED"))
        self.r.inbox = fixture.Inbox(str(self.r.root / "inbox.sock"))
        p = self.r.drain()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertTrue(self.r.landed("return result evidence"))

    def test_failed_and_expired_receipts_are_not_success(self):
        for status in ("failed", "expired"):
            p = self.receipt(status, status, "recipient unavailable")
            self.assertEqual((p.returncode, p.stdout.strip()), (1, status.upper()))
        book = self.r.conf / "fleets" / self.r.label / "delivery.ndjson"
        self.assertIn("recipient unavailable", book.read_text())

    def test_new_remote_window_not_yet_live_is_retryable(self):
        msg = self.message("not-live")
        msg["to"] = self.local.split("/")[0] + "/" + str(uuid.uuid4())
        p = self.deliver(msg)
        self.assertEqual(p.returncode, 75, p.stdout + p.stderr)
        self.assertIn("no live window here", p.stderr)
        self.assertEqual(self.r.inbox.got, [])


if __name__ == "__main__":
    unittest.main()
