#!/usr/bin/env python3
"""Hermetic Hub/SSH-bridge tests. No live tmux, SSH, GitHub or model calls."""

import asyncio
import contextlib
import importlib.util
import io
from concurrent.futures import ThreadPoolExecutor
from importlib.metadata import PackageNotFoundError, version
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

BIN = Path(__file__).absolute().parent
REAL_TMUX = shutil.which("tmux")
sys.path.insert(0, str(BIN))
import fleet_control as control
import fleet_hub as hub_module
from fleet_config_write import revision, write
from fleet_hub_common import Fault, PROTOCOL, canonical, now, validate_write

try:
    HAS_MCP_SDK = version("mcp") == "2.2.0"
except PackageNotFoundError:
    HAS_MCP_SDK = False


class Sandbox:
    def __init__(self, root):
        self.root = Path(root)
        self.bin = self.root / "bin"
        self.bin.mkdir(parents=True)
        self.conf = self.root / "conf"
        self.fleet_conf = self.conf / "fleets/demo/conf"
        self.fleet_conf.parent.mkdir(parents=True)
        self.fleet_conf.write_text('FLEET_REPO="example/project"\nFLEET_MAIN="/fixture/project"\nFLEET_MAX_SESSIONS=3\n')
        for filename in ("fleet-control.py", "fleet_control.py", "fleet_hub_common.py", "fleet_config_write.py",
                         "fleet-lib.sh", "fleet-control-read.sh", "fleet-hub.py", "fleet_hub.py", "fleet_hub_mcp.py"):
            shutil.copy2(BIN / filename, self.bin / filename)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.script(self.tools / "tmux", '''#!/usr/bin/env python3
import os, pathlib, sys
root=pathlib.Path(os.environ["FLEET_CONF_DIR"])
if "has-session" in sys.argv: sys.exit(0)
if "list-windows" in sys.argv:
    data=root/"workers.tsv"
    if data.exists(): print(data.read_text(),end="")
    sys.exit(0)
sys.exit(9)
''')
        for filename in ("fleet-diskguard.sh", "fleet-quotaguard.sh", "fleet-codex-account.sh"):
            self.script(self.bin / filename, '''#!/bin/bash
[ ! -f "$FLEET_CONF_DIR/blocked" ]
''')
        self.script(self.bin / "dash-issue-session.sh", '''#!/bin/bash
printf '%s\\n' "$*" >> "$FLEET_CONF_DIR/spawn.calls"
printf '@12\\t%s\\t0\\t/fixture/issue-%s\\tdone\\tclaude\\ta1\\n' "$1" "$1" > "$FLEET_CONF_DIR/workers.tsv"
''')
        self.controller = control.Control(self.conf, self.bin)
        self.fleet_id = self.controller.inventory()[0]["fleet_id"]

    @staticmethod
    def script(path, value):
        path.write_text(value)
        path.chmod(0o755)

    def request(self, method, params, **extra):
        return dict(protocol=PROTOCOL, method=method, params=params,
                    machine_id=self.controller.machine_id, **extra)

    def rpc(self, method, params):
        return self.controller.dispatch(self.request(method, params))

    def wait(self, operation_id):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result = self.rpc("operation_get", {"operation_id": operation_id})
            if result["status"] not in ("accepted", "running"):
                return result
            time.sleep(0.025)
        raise AssertionError("fixture executor failed to finish")


class HubFixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="fleet-hub-selftest-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.node = Sandbox(self.root / "node")
        env = patch.dict(os.environ, PATH=str(self.node.tools) + os.pathsep + os.environ["PATH"])
        env.start()
        self.addCleanup(env.stop)
        self.hub = hub_module.Hub(self.root / "hub")
        self.rpc_calls = []
        self.offline = False

        def rpc(node, method, params):
            self.rpc_calls.append((method, params))
            if self.offline:
                raise Fault("UNAVAILABLE", "fixture offline")
            return self.node.rpc(method, params)

        self.rpc_patch = patch.object(self.hub, "rpc", side_effect=rpc)
        self.rpc_patch.start()
        self.addCleanup(self.rpc_patch.stop)
        self.registered = self.hub.register("MINI", ssh="mini-fixture")
        self.fleet = self.node.fleet_id
        self.grant = self.hub.grant("scheduler", [self.fleet], ["fleet:read", "worker:start", "config:write"],
                                    ["FLEET_MAX_SESSIONS"])
        self.token = self.grant["token"]

    def call(self, tool, params=None, token=None):
        return self.hub.call(tool, params or {}, token=token or self.token)

    def submit(self, key="request-1", issue=123):
        return self.call("worker_start", dict(fleet_id=self.fleet, idempotency_key=key, params={"issue": issue}))

    def cli(self, *argv):
        """Run the administrator CLI against this fixture's registry; returns (exit code, parsed stdout)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = hub_module.main(["--state-dir", str(self.hub.store.root), *argv])
        return code, json.loads(out.getvalue()) if out.getvalue().strip() else None


class HubTests(HubFixture):
    @unittest.skipUnless(REAL_TMUX, "tmux is not installed")
    def test_real_tmux_inventory_without_utf8_locale(self):
        session = "fleet-hub-selftest-" + uuid.uuid4().hex
        argv = [REAL_TMUX, "-L", session]
        env = dict(os.environ, LANG="C", LC_ALL="C",
                   PATH=str(Path(REAL_TMUX).parent) + os.pathsep + os.environ["PATH"])
        def tmux(*args):
            return subprocess.run([*argv, *args], env=env, check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        try:
            tmux("-f", "/dev/null", "new-session", "-d", "-s", session)
            for key, value in (("@raw", "1"), ("@worktree", "/fixture/中文"),
                               ("@claude_state", "done"), ("@cc_agent", "claude"), ("@wid", "a1")):
                tmux("set-option", "-w", "-t", "=" + session + ":", key, value)
            with patch.dict(os.environ, env):
                result = self.node.controller.workers({"name": session, "agent": "claude"})
            self.assertEqual(result["state"], "running")
            self.assertEqual(len(result["workers"]), 1)
            self.assertEqual(result["workers"][0]["worktree"], "/fixture/中文")
            self.assertEqual(result["workers"][0]["handle"], "a1")
        finally:
            subprocess.run([*argv, "kill-server"], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)

    def test_service_manifest_and_registry_migration(self):
        spec = importlib.util.spec_from_file_location("hub_service", BIN / "fleet-hub-service.py")
        service = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(service)
        manifest = service.launch_agent(self.root, self.root / "venv/bin/python", BIN / "fleet-hub.py",
                                        self.root / "state", "https://mini.example:8450/mcp", 8766)
        self.assertTrue(manifest["KeepAlive"])
        self.assertTrue(manifest["RunAtLoad"])
        self.assertIn("127.0.0.1", manifest["ProgramArguments"])
        self.assertNotIn("FLEET_HUB_TOKEN", manifest["EnvironmentVariables"])
        with self.assertRaises(ValueError):
            service.launch_agent(self.root, Path("python"), Path("hub"), self.root, "http://mini/mcp", 8766)
        reopened = hub_module.Hub(self.hub.store.root)
        self.assertEqual(reopened.nodes()[0]["id"], self.node.controller.machine_id)
        with reopened.store.connect() as db:
            self.assertIn("ssh_config", {r[1] for r in db.execute("PRAGMA table_info(nodes)")})
    def test_inventory_persistent_identity_and_same_name_on_another_machine(self):
        repeated = control.Control(self.node.conf, self.node.bin)
        self.assertEqual(repeated.inventory()[0]["fleet_id"], self.fleet)
        second = Sandbox(self.root / "second")
        self.assertNotEqual(second.fleet_id, self.fleet)
        data = self.call("fleet_list")
        self.assertEqual(data["fleets"][0]["machine_name"], "MINI")
        self.assertEqual(data["fleets"][0]["availability"], "fresh")
        self.assertNotIn("endpoint", canonical(data))

    def test_machine_pinning_and_strict_control_envelope(self):
        with self.assertRaisesRegex(Fault, "machine identity"):
            self.node.controller.dispatch(dict(protocol=PROTOCOL, method="fleet_status",
                                                machine_id=str(uuid.uuid4()), params={"fleet_id": self.fleet}))
        with self.assertRaises(Fault):
            self.node.controller.dispatch(self.node.request("discover", {}, shell="touch /bad"))
        with self.assertRaises(Fault):
            self.node.rpc("exec", {"command": "anything"})

    def test_permissions_revocation_expiry_and_no_cross_fleet_routing(self):
        reader = self.hub.grant("reader", [self.fleet], ["fleet:read"])
        before = len(self.rpc_calls)
        with self.assertRaises(Fault):
            self.call("worker_start", dict(fleet_id=self.fleet, idempotency_key="x", params={"issue": 1}), reader["token"])
        with self.assertRaises(Fault):
            self.call("fleet_status", {"fleet_id": str(uuid.uuid4())})
        self.assertEqual(len(self.rpc_calls), before)
        with self.hub.store.connect() as db:
            db.execute("UPDATE principals SET revoked=1 WHERE id=?", (self.grant["principal_id"],))
        with self.assertRaises(Fault):
            self.call("fleet_list")
        with self.hub.store.connect() as db:
            db.execute("UPDATE principals SET expires=0 WHERE id=?", (reader["principal_id"],))
        with self.assertRaises(Fault):
            self.call("fleet_list", token=reader["token"])

    def test_invalid_arguments_never_become_argv_or_configuration(self):
        for issue in (True, "12;touch /bad", -1, 0, 1.1):
            with self.subTest(issue=issue), self.assertRaises(Fault):
                self.submit(issue=issue)
        for params in ({"key": "FLEET_NOTIFY_CMD", "value": 1, "expected_revision": "a" * 64},
                       {"key": "FLEET_MAX_SESSIONS", "value": "$(touch /bad)", "expected_revision": "a" * 64},
                       {"key": "FLEET_MAX_SESSIONS", "value": 300, "expected_revision": "a" * 64}):
            with self.assertRaises(Fault):
                validate_write("config_set", params)
        self.assertFalse((self.node.conf / "spawn.calls").exists())

    def test_start_is_durable_and_idempotent_at_both_ends(self):
        first = self.submit()
        second = self.submit()
        self.assertEqual(first["operation_id"], second["operation_id"])
        self.assertEqual(self.node.wait(first["operation_id"])["status"], "succeeded")
        result = self.call("operation_get", {"operation_id": first["operation_id"]})
        self.assertEqual(result["result"]["workers"][0]["issue"], 123)
        self.assertEqual(len((self.node.conf / "spawn.calls").read_text().splitlines()), 1)
        with self.assertRaises(Fault):
            self.submit(issue=124)
        envelope = next(params for method, params in self.rpc_calls if method == "submit")
        self.node.rpc("submit", envelope)
        self.assertEqual(len((self.node.conf / "spawn.calls").read_text().splitlines()), 1)
        changed = dict(envelope, params={"issue": 125})
        with self.assertRaises(Fault):
            self.node.rpc("submit", changed)

    def test_concurrent_same_key_routes_once(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.submit(), range(4)))
        self.assertEqual(len({r["operation_id"] for r in results}), 1)
        self.node.wait(results[0]["operation_id"])
        self.assertEqual(sum(method == "submit" for method, _ in self.rpc_calls), 1)

    def test_lost_ack_reconciles_without_resubmitting(self):
        def lose_ack(node, method, params):
            result = self.node.rpc(method, params)
            if method == "submit":
                raise Fault("TIMEOUT", "lost acknowledgement")
            return result
        with patch.object(self.hub, "rpc", side_effect=lose_ack):
            first = self.submit()
            self.assertEqual(first["status"], "unknown")
            self.node.wait(first["operation_id"])
            self.assertEqual(self.submit()["operation_id"], first["operation_id"])
            result = self.call("operation_get", {"operation_id": first["operation_id"]})
            self.assertEqual(result["status"], "succeeded")
        self.assertEqual(len((self.node.conf / "spawn.calls").read_text().splitlines()), 1)

    def test_gates_block_starts_and_operation_reads_are_owner_scoped(self):
        (self.node.conf / "blocked").touch()
        started = self.submit()
        done = self.node.wait(started["operation_id"])
        self.assertEqual(done["status"], "failed")
        self.assertEqual(done["result"]["error"]["code"], "RESOURCE_GATE")
        self.assertFalse((self.node.conf / "spawn.calls").exists())
        reader = self.hub.grant("reader", [self.fleet], ["fleet:read"])
        with self.assertRaises(Fault):
            self.call("operation_get", {"operation_id": started["operation_id"]}, reader["token"])

    def test_offline_inventory_retains_last_observation(self):
        initial = self.call("fleet_list")["fleets"][0]
        self.offline = True
        offline = self.call("fleet_list")["fleets"][0]
        self.assertEqual(offline["availability"], "unreachable")
        self.assertEqual(offline["observed_at"], initial["observed_at"])
        self.assertTrue(offline["registered"])
        with self.assertRaises(Fault):
            self.call("fleet_status", {"fleet_id": self.fleet})

    def test_local_tmux_failure_is_unknown_but_absent_server_is_down(self):
        self.node.script(self.node.tools / "tmux", "#!/bin/sh\necho 'permission denied' >&2\nexit 1\n")
        with self.assertRaises(Fault):
            self.node.rpc("fleet_status", {"fleet_id": self.fleet})
        self.node.script(self.node.tools / "tmux", "#!/bin/sh\necho 'no server running on fixture' >&2\nexit 1\n")
        self.assertEqual(self.node.rpc("fleet_status", {"fleet_id": self.fleet})["state"], "down")

    def test_config_compare_and_set_and_key_grant(self):
        initial = self.call("config_get", {"fleet_id": self.fleet})
        params = {"key": "FLEET_MAX_SESSIONS", "value": 4, "expected_revision": initial["revision"]}
        started = self.call("config_set", dict(fleet_id=self.fleet, idempotency_key="config-1", params=params))
        self.assertEqual(self.node.wait(started["operation_id"])["status"], "succeeded")
        self.assertIn("FLEET_MAX_SESSIONS=4", self.node.fleet_conf.read_text())
        stale = self.call("config_set", dict(fleet_id=self.fleet, idempotency_key="config-2", params=dict(params, value=5)))
        done = self.node.wait(stale["operation_id"])
        self.assertEqual(done["status"], "failed")
        self.assertEqual(done["result"]["error"]["code"], "REVISION_CONFLICT")
        with self.assertRaises(Fault):
            self.call("config_set", dict(fleet_id=self.fleet, idempotency_key="config-3",
                                         params=dict(params, key="FLEET_AUTOFILL", value=1)))

    def test_config_writer_serializes_dashboard_and_remote_writers(self):
        path = self.root / "shared.conf"
        path.write_text('# preserved\n  FLEET_MAX_SESSIONS=1\nFLEET_AUTOFILL=0\n')
        rev = revision(path)
        def update(value):
            try:
                return write(path, "FLEET_MAX_SESSIONS", str(value), "int", rev)
            except ValueError:
                return "conflict"
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(update, (2, 3)))
        self.assertEqual(sorted(results), ["conflict", "updated"])
        self.assertEqual(path.read_text().count("FLEET_MAX_SESSIONS="), 1)
        self.assertIn("# preserved", path.read_text())
        self.assertIn("FLEET_AUTOFILL=0", path.read_text())

    def test_ssh_uses_fixed_command_pinned_identity_and_no_token_environment(self):
        self.rpc_patch.stop()
        node = self.hub.nodes()[0]
        node["ssh_config"] = "/private/fixture/ssh.conf"
        payload = {"protocol": PROTOCOL, "machine_id": node["id"], "result": {"ok": True}}
        with patch.object(hub_module, "run", return_value=(0, canonical(payload).encode(), b"")) as runner:
            with patch.dict(os.environ, FLEET_HUB_TOKEN="not-forwarded"):
                self.hub.rpc(node, "fleet_status", {"fleet_id": self.fleet})
            argv = runner.call_args.args[0]
            self.assertIn("StrictHostKeyChecking=yes", argv)
            self.assertIn("BatchMode=yes", argv)
            self.assertEqual(argv[:3], ["ssh", "-F", "/private/fixture/ssh.conf"])
            self.assertEqual(argv[-1], hub_module.REMOTE_COMMAND)
            self.assertNotIn("FLEET_HUB_TOKEN", runner.call_args.kwargs["env"])
            payload["machine_id"] = str(uuid.uuid4())
            runner.return_value = (0, canonical(payload).encode(), b"")
            with self.assertRaises(Fault):
                self.hub.rpc(node, "discover", {})

    def test_audit_records_denials_and_contains_no_secrets(self):
        with self.assertRaises(Fault):
            self.call("fleet_status", {"fleet_id": str(uuid.uuid4())})
        with self.hub.store.connect() as db:
            audit = [dict(r) for r in db.execute("SELECT * FROM audit")]
        self.assertEqual(audit[-1]["outcome"], "FORBIDDEN")
        self.assertNotIn(self.token, canonical(audit))
        self.assertNotIn(self.token.encode(), self.hub.store.path.read_bytes())

    def test_cli_grant_defaults_to_read_only_for_one_day(self):
        # Issue #833: the default grant is the minimum usable one; writes and a longer life are explicit.
        code, issued = self.cli("grant", "minimal", "--fleet", self.fleet)
        self.assertEqual(code, 0)
        self.assertEqual(issued["policy"], {"fleets": [self.fleet], "scopes": ["fleet:read"], "config_keys": []})
        self.assertAlmostEqual(issued["expires_at"], now() + 24 * 3600, delta=120)
        with self.assertRaises(Fault):
            self.call("worker_start", dict(fleet_id=self.fleet, idempotency_key="min", params={"issue": 1}), issued["token"])
        code, wider = self.cli("grant", "scheduler-2", "--fleet", self.fleet, "--scope", "worker:start", "--ttl-hours", "720")
        self.assertEqual((code, wider["policy"]["scopes"]), (0, ["fleet:read", "worker:start"]))
        self.assertAlmostEqual(wider["expires_at"], now() + 720 * 3600, delta=120)

    def test_principals_lists_state_scopes_usage_and_no_secrets(self):
        # Issue #833: one grant per Agent — audit separates them, revoking one leaves the other, and
        # `principals` shows every grant's scopes, Fleet count, expiry and last call without its hash.
        reader = self.hub.grant("reader", [self.fleet], ["fleet:read"], ttl_hours=2)
        self.call("fleet_list", {"refresh": False})
        for _ in range(2):
            self.call("fleet_list", {"refresh": False}, reader["token"])
        with self.hub.store.connect() as db:
            actors = [r[0] for r in db.execute("SELECT actor FROM audit WHERE action='fleet_list' ORDER BY id")]
        self.assertEqual(actors, [self.grant["principal_id"], reader["principal_id"], reader["principal_id"]])
        code, listed = self.cli("principals")
        self.assertEqual(code, 0)
        rows = {row["name"]: row for row in listed}
        self.assertEqual(set(rows), {"scheduler", "reader"})
        self.assertEqual(rows["scheduler"]["scopes"], ["config:write", "fleet:read", "worker:start"])
        self.assertEqual(rows["scheduler"]["config_keys"], ["FLEET_MAX_SESSIONS"])
        self.assertEqual((rows["reader"]["scopes"], rows["reader"]["fleets"], rows["reader"]["fleet_ids"]),
                         (["fleet:read"], 1, [self.fleet]))
        self.assertEqual((rows["reader"]["state"], rows["reader"]["auth"], rows["reader"]["calls"], rows["scheduler"]["calls"]),
                         ("active", "token", 2, 1))
        self.assertRegex(rows["reader"]["last_call_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertRegex(rows["reader"]["expires_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertLess(rows["reader"]["expires_at"], rows["scheduler"]["expires_at"])
        text = canonical(listed)
        for secret in (self.token, reader["token"], hub_module.digest(self.token), "token_hash"):
            self.assertNotIn(secret, text)
        # Never called → visible as idle; expired → still listed, marked; revoked → hidden unless --all.
        idle = self.hub.grant("idle", [self.fleet], ["fleet:read"])
        with self.hub.store.connect() as db:
            db.execute("UPDATE principals SET expires=1 WHERE id=?", (idle["principal_id"],))
        code, listed = self.cli("principals")
        rows = {row["name"]: row for row in listed}
        self.assertEqual((rows["idle"]["state"], rows["idle"]["calls"], rows["idle"]["last_call_at"]), ("expired", 0, None))
        self.assertEqual(listed[0]["name"], "idle")
        self.assertEqual(self.cli("revoke", reader["principal_id"]), (0, {"revoked": True}))
        with self.assertRaises(Fault):
            self.call("fleet_list", {"refresh": False}, reader["token"])
        self.call("fleet_list", {"refresh": False})
        self.assertEqual({row["name"] for row in self.cli("principals")[1]}, {"scheduler", "idle"})
        rows = {row["name"]: row for row in self.cli("principals", "--all")[1]}
        self.assertEqual((rows["reader"]["state"], rows["reader"]["calls"], rows["scheduler"]["calls"]), ("revoked", 2, 2))


@unittest.skipUnless(HAS_MCP_SDK, "optional MCP SDK 2.2.0 is not installed")
class MCPTests(HubFixture):
    def test_private_http_grants_are_per_request_and_revocable(self):
        from starlette.testclient import TestClient
        from fleet_hub_mcp import grant_token_app, request_grant_token
        reader = self.hub.grant("http-reader", [self.fleet], ["fleet:read"])
        app = grant_token_app(self.hub, "https://mini.example:8450/mcp")
        read = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "fleet_list", "arguments": {"refresh": False}}}
        config = self.call("config_get", {"fleet_id": self.fleet})
        change = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "config_set", "arguments": {"fleet_id": self.fleet, "key": "FLEET_MAX_SESSIONS",
                "value": 5, "expected_revision": config["revision"], "idempotency_key": "http-config"}}}
        with TestClient(app, base_url="https://mini.example:8450") as client:
            headers = {"Accept": "application/json, text/event-stream"}
            self.assertEqual(client.post("/mcp", json=read, headers=headers).status_code, 401)
            headers["Authorization"] = "Bearer " + reader["token"]
            self.assertIn(self.fleet, client.post("/mcp", json=read, headers=headers).text)
            denied = client.post("/mcp", json=change, headers=headers)
            self.assertTrue(denied.json()["result"]["isError"])
            headers["Authorization"] = "Bearer " + self.token
            submitted = client.post("/mcp", json=change, headers=headers).json()["result"]["structuredContent"]
            self.assertEqual(self.node.wait(submitted["operation_id"])["status"], "succeeded")
            self.assertIsNone(request_grant_token.get())
            headers["Authorization"] = "Bearer " + reader["token"]
            self.assertTrue(client.post("/mcp", json=change, headers=headers).json()["result"]["isError"])
            with self.hub.store.connect() as db:
                db.execute("UPDATE principals SET revoked=1 WHERE id=?", (reader["principal_id"],))
            self.assertEqual(client.post("/mcp", json=read, headers=headers).status_code, 401)
            # Issue #833: 401 lands only on the revoked grant; the sibling grant is untouched.
            headers["Authorization"] = "Bearer " + self.token
            self.assertEqual(client.post("/mcp", json=read, headers=headers).status_code, 200)
        with self.hub.store.connect() as db:
            actors = {r[0] for r in db.execute("SELECT actor FROM audit WHERE action='fleet_list'")}
        self.assertEqual(actors, {self.grant["principal_id"], reader["principal_id"]})
        states = {row["name"]: row["state"] for row in self.hub.principals(include_revoked=True)}
        self.assertEqual((states["http-reader"], states["scheduler"]), ("revoked", "active"))

    def test_stdio_protocol_tools_and_live_revocation(self):
        from mcp import ClientSession, StdioServerParameters, stdio_client
        # The SDK client connects to a real child server using the local bridge.
        with self.hub.store.connect() as db:
            db.execute("UPDATE nodes SET transport='local',conf_dir=?", (str(self.node.conf),))
        async def scenario():
            params = StdioServerParameters(command=sys.executable,
                        args=[str(self.node.bin / "fleet-hub.py"), "--state-dir", str(self.hub.store.root), "serve"],
                        env={"PATH": os.environ["PATH"], "FLEET_HUB_TOKEN": self.token})
            async with stdio_client(params) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    await session.initialize()
                    names = {tool.name for tool in (await session.list_tools()).tools}
                    self.assertEqual(names, {"fleet_list", "fleet_status", "config_get", "config_set", "worker_start", "operation_get"})
                    response = await session.call_tool("fleet_list", {"refresh": True})
                    self.assertFalse(response.is_error)
                    self.assertIn(self.fleet, canonical(response.model_dump()))
                    config = await session.call_tool("config_get", {"fleet_id": self.fleet})
                    values = config.structured_content
                    changed = await session.call_tool("config_set", {"fleet_id": self.fleet,
                        "key": "FLEET_MAX_SESSIONS", "value": 6, "expected_revision": values["revision"], "idempotency_key": "mcp-config"})
                    self.assertFalse(changed.is_error)
                    operation_id = changed.structured_content["operation_id"]
                    for _ in range(80):
                        result = await session.call_tool("operation_get", {"operation_id": operation_id})
                        if result.structured_content["status"] not in ("accepted", "running", "pending"):
                            break
                        await asyncio.sleep(0.05)
                    self.assertEqual(result.structured_content["status"], "succeeded")
                    self.assertIn("FLEET_MAX_SESSIONS=6", self.node.fleet_conf.read_text())
                    bad = await session.call_tool("worker_start", {"fleet_id": self.fleet, "issue": "123;bad", "idempotency_key": "bad"})
                    self.assertTrue(bad.is_error)
                    with self.hub.store.connect() as db:
                        db.execute("UPDATE principals SET revoked=1 WHERE id=?", (self.grant["principal_id"],))
                    denied = await session.call_tool("fleet_list", {"refresh": False})
                    self.assertTrue(denied.is_error)
        asyncio.run(scenario())

    def test_oauth_claims_audience_scopes_and_http_boundary(self):
        import jwt
        from cryptography.hazmat.primitives.asymmetric import rsa
        from starlette.testclient import TestClient
        from fleet_hub_mcp import JWTVerifier, http_security, make_server
        issuer, resource = "https://issuer.test", "https://hub.test/mcp"
        self.hub.grant("oauth-agent", [self.fleet], ["fleet:read", "worker:start"],
                       oauth_issuer=issuer, oauth_subject="operator", oauth_client="agent-client")
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        verifier = JWTVerifier(self.hub, issuer, issuer + "/keys", resource)
        public = type("SigningKey", (), {"key": key.public_key()})()
        claims = dict(iss=issuer, aud=resource, sub="operator", client_id="agent-client", scope="fleet:read",
                      exp=int(now()) + 300, iat=int(now()))
        token = jwt.encode(claims, key, algorithm="RS256")
        with patch.object(verifier.keys, "get_signing_key_from_jwt", return_value=public):
            self.assertIsNotNone(asyncio.run(verifier.verify_token(token)))
            for changes in ({"aud": "other"}, {"iss": "https://other.test"}, {"sub": "impostor"}, {"exp": int(now()) - 1}):
                invalid = jwt.encode(dict(claims, **changes), key, algorithm="RS256")
                self.assertIsNone(asyncio.run(verifier.verify_token(invalid)))
        with self.assertRaises(Fault):
            self.hub.call("worker_start", dict(fleet_id=self.fleet, idempotency_key="oauth", params={"issue": 1}),
                          oauth=(issuer, "operator", "agent-client"), token_scopes=["fleet:read"])
        with patch("fleet_hub_mcp.JWTVerifier", return_value=verifier), patch.object(verifier.keys, "get_signing_key_from_jwt", return_value=public):
            server = make_server(self.hub, oauth=dict(issuer=issuer, jwks_url=issuer + "/keys", resource_url=resource))
            app = server.streamable_http_app(stateless_http=True, json_response=True, transport_security=http_security(resource))
            with TestClient(app, base_url="https://hub.test") as client:
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}}
                headers = {"Accept": "application/json, text/event-stream"}
                self.assertEqual(client.post("/mcp", json=init, headers=headers).status_code, 401)
                headers["Authorization"] = "Bearer " + token
                self.assertEqual(client.post("/mcp", json=init, headers=headers).status_code, 200)
                read = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
                    "name": "fleet_list", "arguments": {"refresh": False}}}
                response = client.post("/mcp", json=read, headers=headers)
                self.assertEqual(response.status_code, 200)
                self.assertIn(self.fleet, response.text)
                start = {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                    "name": "worker_start", "arguments": {"fleet_id": self.fleet, "issue": 3, "idempotency_key": "http-1"}}}
                response = client.post("/mcp", json=start, headers=headers)
                self.assertTrue(response.json()["result"]["isError"])
                headers["Origin"] = "https://untrusted.test"
                self.assertEqual(client.post("/mcp", json=init, headers=headers).status_code, 403)


if __name__ == "__main__":
    unittest.main(verbosity=2)
