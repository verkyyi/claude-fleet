#!/usr/bin/env python3
# selftest-entry
"""A message to a session that has just finished a turn is put in ONCE (task M6WH).

The session gate's legacy-deliver admits a relay's words under its delivery id and,
holding the session's lock, runs _fleet_agent_deliver_native (bin/fleet-lib.sh); a
window whose Stop hook left @sleep_evidence goes on to bin/fleet_worker_life.py
deliver. That step used to call the WHOLE fleet_agent_deliver — back into the gate,
a second admission under a fresh id, blocked on the lock the first one held until
its 20 s bound ran out: the first came back «returned» (the hub retried it) and the
second went in when the lock freed — the same words twice, in the field from
one machine to another, both ways. Its put-in is now the adapter's own
(_fleet_agent_deliver_native): one admission, one copy.
Drives: bin/fleet_worker_life.py, bin/fleet-lib.sh."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_worker_life as life  # noqa: E402


class DeliverOnce(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="sleep-once-"))
        self.log = self.tmp / "calls"
        fake = self.tmp / "bin"
        fake.mkdir()
        # The two roads, as names: the gate's whole road and the adapter's put-in.
        (fake / "fleet-lib.sh").write_text(
            'fleet_agent_deliver() { echo "gate $1 $(printf %s "$3")" >> "$FAKE_LOG"; return 0; }\n'
            '_fleet_agent_deliver_native() { echo "native $1 $(printf %s "$3")" >> "$FAKE_LOG"; return 0; }\n')
        w = life.Worker.__new__(life.Worker)
        w.session, w.window, w.pane = "t", "@9", "%9"
        w.directory = self.tmp / "sleep"
        w.lockfile = w.directory / "window-9.lock"
        self.stamps = []
        w.inspect = lambda: {"session_id": "sid-1"}
        w.stamp = lambda k, v: self.stamps.append((k, v))
        self.w = w

    def run_deliver(self, text):
        with patch.object(life, "BIN", self.tmp / "bin"), patch.dict(os.environ, {"FAKE_LOG": str(self.log)}):
            self.w.deliver(text)
        return self.log.read_text().splitlines()

    def test_put_in_once_by_the_adapter_never_the_gate_again(self):
        calls = self.run_deliver("hello")
        self.assertEqual(calls, ["native %9 hello"], "never back into fleet_agent_deliver (the gate)")
        self.assertIn(("@sleep_evidence", ""), self.stamps, "the evidence is cleared before the put-in")
        self.assertEqual(list((self.w.directory / "inbox-window-9").glob("*.json")), [], "a delivered record is gone")

    def test_native_does_not_reenter_the_gate(self):
        # _fleet_agent_deliver_native is what the gate itself runs under its lock;
        # its only way on to this step must not lead back to fleet_agent_deliver.
        src = (BIN / "fleet_worker_life.py").read_text()
        body = src[src.index("    def deliver(self,text):"):src.index("    def inbox(self):")]
        self.assertNotIn(" fleet_agent_deliver ", body.replace('"', " ").replace(";", " "))
        self.assertIn("_fleet_agent_deliver_native", body)


if __name__ == "__main__":
    unittest.main()
