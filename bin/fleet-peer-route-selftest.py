#!/usr/bin/env python3
# selftest-entry
"""The hub route client refuses missing, ambiguous, malformed and foreign IDs."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("route", Path(__file__).with_name("fleet-peer-route.py"))
route = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route)
FID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
FLEET = "11111111-2222-4333-8444-555555555555"


class Route(unittest.TestCase):
    def test_placed_before_inventory(self):
        def call(method, path):
            self.assertEqual((method, path), ("GET", "/v1/node/worker-route?id=" + FID))
            return 200, json.dumps(dict(worker_id=FLEET + "/" + FID, node="u-test", source="placement"))
        self.assertEqual(route.resolve(FID, call), FLEET + "/" + FID + "\tu-test")

    def test_visible_failures(self):
        for code, body, reason in [(404, {"reason": "closed"}, "closed"),
                                   (404, {"reason": "no_route"}, "no placed session"),
                                   (404, {}, "NOT_FOUND"), (409, {}, "AMBIGUOUS"),
                                   (503, {}, "UNAVAILABLE")]:
            with self.subTest(code=code, body=body), self.assertRaisesRegex(ValueError, reason):
                route.resolve(FID, lambda *args: (code, json.dumps(body)))
        def down(*args):
            raise route.fleet_node_http.Unreachable("do not expose internal connection details")
        with self.assertRaisesRegex(ValueError, "^UNAVAILABLE: hub route lookup failed; nothing sent$"):
            route.resolve(FID, down)

    def test_invalid_reply_cannot_redirect(self):
        for body in [{"worker_id": FLEET + "/" + FLEET}, {"worker_id": FID},
                     {"worker_id": FLEET + "/" + FID, "node": "host\nforged"}, [], "bad JSON"]:
            with self.subTest(body=body), self.assertRaisesRegex(ValueError, "INVALID_ROUTE"):
                route.resolve(FID, lambda *args: (200, json.dumps(body)))


if __name__ == "__main__":
    unittest.main()
