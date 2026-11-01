#!/usr/bin/env python3
"""T1243: a pod's entry is a jump, never the pod's SSH server."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys


spec = importlib.util.spec_from_file_location("peerlink", Path(__file__).with_name("fleet-peerlink.py"))
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)
sys.path.insert(0, str(Path(__file__).parent))
import fleet_node_http


class PodRoute(unittest.TestCase):
    def test_jump_reaches_pod_through_peer_relay(self):
        route = {"name": "entry", "host": "203.0.113.9", "port": 22022,
                 "jump": "fleet-jump", "target": "u-abcd.fleet-workers.svc.cluster.local",
                 "target_port": 22}
        with patch.dict(os.environ, {"FLEET_REMOTE_SSH": ""}):
            self.assertEqual(pl.route_candidates("u-abcd", [route]),
                             [("u-abcd", 0, "peer-relay")])
            with tempfile.TemporaryDirectory() as tmp, \
                    patch.object(pl, "D", tmp), \
                    patch.object(pl, "master_check", return_value=(False, 0)), \
                    patch.object(pl, "peer_opts", return_value=(["-o", "HostKeyAlias=fleet-u-abcd"], "")), \
                    patch.object(pl.subprocess, "Popen") as popen:
                link = pl.Link("u-abcd", "alice")
                link.routes = [route]
                pl.Keeper().start(link, 1)
                argv = popen.call_args.args[0]
                self.assertEqual(argv[-3:], ["-l", "alice", "u-abcd"])
                proxy = next(a for a in argv if a.startswith("ProxyCommand="))
                self.assertIn(" peer-proxy u-abcd", proxy)
                self.assertIn("HostKeyAlias=fleet-u-abcd", argv)
                self.assertNotIn("203.0.113.9", argv)

    def test_direct_and_override_still_work(self):
        with patch.dict(os.environ, {"FLEET_REMOTE_SSH": "u-abcd=pod.example.com"}):
            self.assertEqual(pl.route_candidates("u-abcd", [{"jump": "fleet-jump"}]),
                             [("pod.example.com", 0, "pod.example.com")])
        with patch.dict(os.environ, {"FLEET_REMOTE_SSH": ""}):
            self.assertEqual(pl.route_candidates("mac-a", []), [("mac-a", 0, "mac-a")])

    def test_proxy_uses_node_auth_only_for_the_target(self):
        fc = pl.connect_mod()
        def copy(node, hub, token, *, opener):
            self.assertEqual(token, "")
            opener(node, hub, token)
            return 0
        with patch.object(fleet_node_http, "pair", return_value=("https://hub.example.com", "test-node")), \
                patch.object(fleet_node_http, "auth", return_value="FleetSig test") as auth, \
                patch.object(fc, "proxy", side_effect=copy), \
                patch.object(fc, "open_relay") as relay:
            self.assertEqual(pl.peer_proxy(["u-abcd"]), 0)
            auth.assert_called_once_with("GET", "https://hub.example.com/v1/node/peer-relay?node=u-abcd", "test-node")
            self.assertEqual(relay.call_args.kwargs,
                             {"path": "/v1/node/peer-relay", "headers": {"Authorization": "FleetSig test"}})
        with patch.object(fleet_node_http, "pair", return_value=None):
            self.assertEqual(pl.peer_proxy(["u-abcd"]), 1)

    def test_peer_proxy_never_uses_device_challenge(self):
        fc = pl.connect_mod()
        with patch.object(fc, "WS") as ws, patch.object(fc, "sign_nonce") as sign:
            ws.return_value.recv.return_value = (1, b'{"type":"challenge","nonce":"test"}')
            with self.assertRaises(fc.Refused):
                fc.open_relay("u-abcd", "https://hub.example.com", "", path="/v1/node/peer-relay")
            sign.assert_not_called()
            ws.return_value.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
