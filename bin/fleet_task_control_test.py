#!/usr/bin/env python3
"""Isolated task consumers. No GitHub or production process access."""
import unittest
import fleet_task_control as control

class TaskControlTests(unittest.TestCase):
    def test_unavailable_is_unknown(self):
        self.assertEqual(control.verdict(None), "UNKNOWN")
        self.assertEqual(control.verdict(dict(state="running", outcome="")), "WAITING")
        self.assertEqual(control.verdict(dict(state="succeeded", outcome="succeeded")), "SUCCEEDED")
        self.assertEqual(control.verdict(dict(state="done", outcome="")), "WAITING")

if __name__ == "__main__":
    unittest.main()
