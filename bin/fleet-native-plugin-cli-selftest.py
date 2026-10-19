#!/usr/bin/env python3
# bin-inventory: 人工入口 — 显式运行的原生插件探针，docs/dev/NATIVE-AGENT-BOUNDARY.md
"""Opt-in native plugin probe: isolated homes, fixture MCP, no model or live configuration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ENVIRONMENT_NAMES = (
    "TMUX", "TMUX_PANE", "FLEET_CONF_DIR", "FLEET_SESSION",
    "FLEET_WORKER_CRED", "FLEET_MCP_BIN", "FLEET_MCP_ORCH",
)
MCP_FIXTURE = '''import json, os, sys, time
from pathlib import Path
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fixture", "version": "1"}}
        Path(sys.argv[1]).write_text(json.dumps({name: os.environ.get(name) for name in sys.argv[2:]}))
    elif method == "tools/list":
        result = {"tools": [{"name": name, "description": "Offline fixture",
                             "inputSchema": {"type": "object", "properties": {}}}
                            for name in ("echo", "slow")]}
    elif method == "tools/call":
        if request.get("params", {}).get("name") == "slow":
            time.sleep(2.5)
            Path(sys.argv[1] + ".slow-finished").write_text("finished")
        result = {"content": [{"type": "text", "text": "fixture-tool-result"}]}
    elif method == "resources/list":
        result = {"resources": []}
    elif method == "resources/templates/list":
        result = {"resourceTemplates": []}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
'''


def stop(child):
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)


def probe(binary, client_type, mode, fleet_root, retire_bridge=False):
    checks = []

    def check(condition, name):
        if not condition:
            raise AssertionError(mode + ": " + name)
        checks.append(name)

    with tempfile.TemporaryDirectory(prefix="fleet-plugin-cli-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        codex_home = home / ".codex"
        codex_home.mkdir(parents=True)
        (codex_home / "config.toml").write_text(
            'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
            '[features]\ndaemon_auto_start=false\nhooks=true\n'
            '[model_providers.offline]\nname="offline"\nbase_url="http://127.0.0.1:9/v1"\n'
            'wire_api="responses"\nrequires_openai_auth=false\n', encoding="utf-8")
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "CODEX_HOME": str(codex_home), "TMPDIR": str(root),
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_CACHE_HOME": str(home / ".cache"),
            "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        }
        fixture_values = {name: "fixture-only-" + name.lower() for name in ENVIRONMENT_NAMES}
        fixture_bin = root / "fleet-bin"
        fixture_bin.mkdir()
        shutil.copyfile(fleet_root / "bin/fleet-mcp.py", fixture_bin / "fleet-mcp.py")
        fixture_values.update(TMUX=str(root / "unused.sock") + ",0,0", TMUX_PANE="%999999",
                              FLEET_CONF_DIR=str(root / "fleet-conf"), FLEET_MCP_BIN=str(fixture_bin))
        environment.update(fixture_values)
        market = root / "market"
        plugin = market / "plugins/native-fixture"
        for directory in (market / ".claude-plugin", plugin / ".claude-plugin",
                          plugin / "skills/fixture-skill", plugin / "commands", plugin / "hooks"):
            directory.mkdir(parents=True)
        (market / ".claude-plugin/marketplace.json").write_text(json.dumps({
            "name": "fleet-probe", "owner": {"name": "Fixture"},
            "plugins": [{"name": "native-fixture", "source": "./plugins/native-fixture",
                         "description": "Offline fixture"}]}), encoding="utf-8")
        (plugin / ".claude-plugin/plugin.json").write_text(json.dumps({
            "name": "native-fixture", "version": "0.1.0", "description": "Offline fixture"}), encoding="utf-8")
        (plugin / "skills/fixture-skill/SKILL.md").write_text(
            "---\nname: fixture-skill\ndescription: Offline fixture\n---\nDo not run tools.\n", encoding="utf-8")
        (plugin / "commands/fixture-command.md").write_text(
            "---\ndescription: Offline command fixture\n---\nDo not run tools.\n", encoding="utf-8")
        marker = root / "hook-executed"
        command = "printf fixture > " + shlex.quote(str(marker))
        (plugin / "hooks/hooks.json").write_text(json.dumps({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": command}]}]}}), encoding="utf-8")
        stub = root / "fixture-mcp.py"
        stub.write_text(MCP_FIXTURE, encoding="utf-8")
        observed = root / "mcp-env.json"
        server = {"command": sys.executable, "args": [str(stub), str(observed), *ENVIRONMENT_NAMES],
                  "tool_timeout_sec": 1}
        if mode == "allowlist":
            server["env_vars"] = list(ENVIRONMENT_NAMES)
        elif mode == "expanded":
            server["env"] = {name: "${" + name + "}" for name in ENVIRONMENT_NAMES}
        servers = {"fixture-native-mcp": server}
        if mode == "allowlist":
            source = fleet_root / "conf/mcp-orch.json"
            fleet_server = json.loads(source.read_text())["mcpServers"]["fleet-orch"]
            fleet_server.update(env_vars=list(ENVIRONMENT_NAMES), tool_timeout_sec=5)
            servers["fleet-orch"] = fleet_server
        (plugin / ".mcp.json").write_text(json.dumps({"mcpServers": servers}), encoding="utf-8")

        def run_command(command, label):
            child = subprocess.Popen(command, env=environment, cwd=root,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = child.communicate(timeout=25)
            except subprocess.TimeoutExpired:
                stop(child)
                child.communicate(timeout=5)
                raise AssertionError(label + " exceeded 25 seconds")
            if child.returncode:
                raise AssertionError(stderr[-1000:])
            check(child.returncode == 0, label)
            return stdout

        def execute(*arguments):
            return run_command([binary, *arguments], "CLI " + " ".join(arguments[:3]))

        def bridge(*arguments):
            return run_command([sys.executable, str(fleet_root / "bin/fleet-codex-plugins.py"), *arguments,
                                "--root", str(market), "--claude", str(root / "claude-fixture"),
                                "--cache", "", "--codex-home", str(codex_home)], "bridge " + " ".join(arguments))

        def assert_absent(label, *flags):
            endpoint = root / (label + ".sock")
            with (root / (label + ".log")).open("w", encoding="utf-8") as log:
                backend = subprocess.Popen([binary, *flags, "app-server", "--listen", "unix://" + str(endpoint)],
                                           env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                           stdout=log, stderr=log, start_new_session=True)
                client = None
                try:
                    deadline = time.monotonic() + 10
                    while not endpoint.exists() and backend.poll() is None and time.monotonic() < deadline:
                        time.sleep(.05)
                    check(endpoint.exists() and backend.poll() is None, label + " backend ready")
                    client = client_type("unix://" + str(endpoint), timeout=5)
                    skills = client.call("skills/list", {"cwds": [str(root)], "forceReload": True})
                    plugin_skills = [skill for entry in skills["data"] for skill in entry["skills"]
                                     if skill.get("pluginId") == "native-fixture@fleet-probe"]
                    config = client.call("config/read", {"cwd": str(root), "includeLayers": False})
                    plugins = config.get("config", {}).get("plugins", {})
                    check(plugins.get("native-fixture@fleet-probe", {}).get("enabled") is False
                          if label == "disabled" else "native-fixture@fleet-probe" not in plugins,
                          label + " effective native configuration")
                    check(not plugin_skills or label == "disabled" and
                          all(skill.get("enabled") is False for skill in plugin_skills),
                          label + " has no enabled skills: " + json.dumps(
                              [{"name": skill["name"], "enabled": skill.get("enabled")} for skill in plugin_skills]))
                    hooks = client.call("hooks/list", {"cwds": [str(root)]})
                    check(not any(hook.get("pluginId") == "native-fixture@fleet-probe"
                                  for entry in hooks["data"] for hook in entry["hooks"]), label + " hooks absent")
                    servers = client.call("mcpServerStatus/list", {})
                    check(not any(server.get("pluginId") == "native-fixture@fleet-probe"
                                  for server in servers["data"]), label + " MCP absent")
                finally:
                    try:
                        if client is not None:
                            client.close()
                    finally:
                        stop(backend)

        version = execute("--version").strip()
        execute("plugin", "marketplace", "add", str(market), "--json")
        execute("plugin", "add", "native-fixture@fleet-probe", "--json")
        installed = json.loads(execute("plugin", "list", "--marketplace", "fleet-probe", "--json"))
        check(len(installed["installed"]) == 1 and installed["installed"][0]["enabled"], "native plugin enabled")
        if retire_bridge:
            native_config = (codex_home / "config.toml").read_text()
            records = home / ".claude/plugins"
            records.mkdir(parents=True)
            (records / "installed_plugins.json").write_text(json.dumps({"plugins": {"native-fixture@fleet-probe": []}}))
            listed = root / "claude-list.json"
            listed.write_text(json.dumps([{"id": "native-fixture@fleet-probe", "enabled": True,
                                           "installPath": str(plugin)}]))
            fake = root / "claude-fixture"
            fake.write_text("#!/bin/sh\n[ \"$1 $2 $3\" = 'plugin list --json' ] || exit 1\nexec cat " +
                            shlex.quote(str(listed)) + "\n")
            fake.chmod(0o700)
            bridge("sync")
            linked = codex_home / "skills/fleet-plugin-fixture-skill"
            adapter = codex_home / "skills/fleet-plugin-fixture-command/SKILL.md"
            check(linked.is_symlink() and adapter.is_file(), "actual legacy bridge creates skill artifacts")
            check("# >>> fleet plugins" in (codex_home / "config.toml").read_text(), "actual legacy bridge creates MCP block")
            override = root / "fleet-conf/agent-overrides.json"
            override.parent.mkdir(parents=True, exist_ok=True)
            override.write_text('["codex.plugins"]\n')
            check(not bridge("dirs").strip(), "retired bridge supplies no hook directories")
            preview = bridge("retire")
            check("preview only" in preview and linked.is_symlink() and adapter.is_file(), "retirement preview leaves artifacts")
            bridge("retire", "--apply")
            check(not linked.is_symlink() and not adapter.exists(), "retirement removes legacy skills")
            check((codex_home / "config.toml").read_text() == native_config, "retirement preserves exact native configuration")
            bridge("sync")
            check(not linked.is_symlink() and not adapter.exists(), "legacy sync cannot revive retired skills")
        endpoint = root / "native.sock"
        with (root / "server.log").open("w", encoding="utf-8") as log:
            backend = subprocess.Popen([binary, "app-server", "--listen", "unix://" + str(endpoint)],
                                       env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
            client = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists() and backend.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                check(endpoint.exists() and backend.poll() is None, "owned backend ready")
                client = client_type("unix://" + str(endpoint), timeout=5)
                skills = client.call("skills/list", {"cwds": [str(root)], "forceReload": True})
                names = {skill["name"] for entry in skills["data"] for skill in entry["skills"]
                         if skill.get("pluginId") == "native-fixture@fleet-probe" and skill["enabled"]}
                check("native-fixture:fixture-skill" in names, "native skill discovered")
                check("native-fixture:source-command-fixture-command" in names, "native command converted")
                hooks = client.call("hooks/list", {"cwds": [str(root)]})
                hooks = [hook for entry in hooks["data"] for hook in entry["hooks"]
                         if hook.get("pluginId") == "native-fixture@fleet-probe"]
                check(len(hooks) == 1 and hooks[0]["trustStatus"] == "untrusted", "plugin hook requires trust")
                native = client.call("thread/start", {"cwd": str(root), "model": "probe",
                                                     "approvalPolicy": "never", "sandbox": "read-only"})
                check(bool(native["thread"]["id"]), "fixture thread created without model turn")
                status = client.call("mcpServerStatus/list", {})
                servers = [entry for entry in status["data"] if entry["name"] == "fixture-native-mcp"]
                check(len(servers) == 1 and servers[0].get("serverInfo", {}).get("name") == "fixture",
                      "native plugin MCP handshake")
                deadline = time.monotonic() + 5
                while not observed.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                check(observed.exists(), "MCP environment captured")
                expected = (fixture_values if mode == "allowlist" else
                            {name: "${" + name + "}" if mode == "expanded" else None for name in ENVIRONMENT_NAMES})
                check(json.loads(observed.read_text()) == expected, "environment semantics: " + mode)
                check(not marker.exists(), "untrusted hook marker absent")
                def call_tool(name):
                    return client.call("mcpServer/tool/call", {"threadId": native["thread"]["id"],
                                       "server": "fixture-native-mcp", "tool": name, "arguments": {}})
                result = call_tool("echo")
                check(not result.get("isError") and result["content"][0]["text"] == "fixture-tool-result",
                      "native MCP tool call")
                try:
                    result = call_tool("slow")
                    failure = json.dumps(result) if result.get("isError") else ""
                except ValueError as error:
                    failure = str(error)
                check("timed out" in failure.lower() or "timeout" in failure.lower(),
                      "plugin tool_timeout_sec enforced")
                completed = Path(str(observed) + ".slow-finished")
                deadline = time.monotonic() + 5
                while not completed.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                check(completed.exists(), "serial fixture slow call finished")
                result = call_tool("echo")
                check(not result.get("isError") and result["content"][0]["text"] == "fixture-tool-result",
                      "native MCP remains usable after tool timeout")
                if mode == "allowlist":
                    fleet_status = [entry for entry in status["data"] if entry["name"] == "fleet-orch"]
                    check(len(fleet_status) == 1 and fleet_status[0].get("serverInfo") is not None,
                          "actual Fleet MCP starts through native plugin with shell path expansion")
                    check(len(fleet_status[0]["tools"]) == 7, "actual Fleet orchestration tool list preserved")
                    result = client.call("mcpServer/tool/call", {"threadId": native["thread"]["id"],
                                         "server": "fleet-orch", "tool": "children", "arguments": {}})
                    refused = " ".join(part.get("text", "") for part in result["content"])
                    check(result.get("isError") and "credential is malformed" in refused and "Nothing ran" in refused,
                          "actual Fleet MCP refuses fixture credential before tool execution")
                    audit = root / "logs/mcp-calls.log"
                    check(audit.exists() and "via=badcred" in audit.read_text(), "MCP audit stays in fixture directory")
            finally:
                try:
                    if client is not None:
                        client.close()
                finally:
                    stop(backend)
        assert_absent("disabled", "-c", "plugins.native-fixture@fleet-probe.enabled=false")
        installed = json.loads(execute("plugin", "list", "--marketplace", "fleet-probe", "--json"))
        check(len(installed["installed"]) == 1 and installed["installed"][0]["enabled"],
              "one-off native disable does not mutate installation")
        execute("plugin", "remove", "native-fixture@fleet-probe", "--json")
        installed = json.loads(execute("plugin", "list", "--marketplace", "fleet-probe", "--json"))
        check(not installed["installed"], "fixture plugin removed")
        check("native-fixture@fleet-probe" not in (codex_home / "config.toml").read_text(),
              "native uninstall removes plugin config rather than leaving a tombstone")
        assert_absent("removed")
        if retire_bridge:
            bridge("sync")
            check(not linked.is_symlink() and not adapter.exists(), "native uninstall does not revive legacy skills")
            check("# >>> fleet plugins" not in (codex_home / "config.toml").read_text(), "native uninstall does not revive legacy MCP")
            check(not bridge("dirs").strip(), "native uninstall does not revive legacy hooks")
            assert_absent("removed-again")
        report = {"version": version, "mode": mode, "checks": checks, "bridge_retirement": retire_bridge}
        if retire_bridge:
            report["bridge_sha256"] = hashlib.sha256((fleet_root / "bin/fleet-codex-plugins.py").read_bytes()).hexdigest()
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--fleet-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--mcp-env", choices=("all", "bare", "allowlist", "expanded"), default="all")
    parser.add_argument("--retire-bridge", action="store_true", help="also exercise candidate bridge retirement in the temporary home")
    arguments = parser.parse_args()
    binary = shutil.which(arguments.codex)
    if not binary:
        parser.error("native Codex binary required; not a default CI test")
    client_type = runpy.run_path(str(arguments.fleet_root / "bin/fleet-codex-rpc.py"))["Client"]
    modes = ("bare", "allowlist", "expanded") if arguments.mcp_env == "all" else (arguments.mcp_env,)
    # --package / --package-role probed the shipped fleet-orchestrate Codex package;
    # it left with the role seats (issue #4340), and with it that probe.
    reports = [probe(str(Path(binary).resolve()), client_type, mode, arguments.fleet_root.resolve(), arguments.retire_bridge)
               for mode in modes]
    print(json.dumps({"scope": "isolated native plugins, fixture tool calls and Fleet credential refusal; no model or live changes",
                      "runs": reports, "passed": sum(len(report["checks"]) for report in reports)}, indent=2))


if __name__ == "__main__":
    main()
