#!/usr/bin/env python3
"""Opt-in native plugin probe: isolated homes, fixture MCP, no model or live configuration."""
import argparse
import contextlib
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


def probe_package(binary, client_type, fleet_root, role_checks=False):
    """Load the unmodified shipping package without trusting hooks or starting a turn."""
    checks = []
    plugin_id = "fleet-orchestrate@claude-fleet"

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    with tempfile.TemporaryDirectory(prefix="fleet-package-cli-", dir="/tmp") as temporary, contextlib.ExitStack() as cleanup:
        root = Path(temporary).resolve()
        home = root / "home"
        codex_home = home / ".codex"
        codex_home.mkdir(parents=True)
        configuration = codex_home / "config.toml"
        configuration.write_text(
            'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
            '[features]\ndaemon_auto_start=false\nhooks=true\nremote_plugin=false\n'
            '[model_providers.offline]\nname="offline"\nbase_url="http://127.0.0.1:9/v1"\n'
            'wire_api="responses"\nrequires_openai_auth=false\n', encoding="utf-8")
        fixture_bin = root / "fleet-bin"
        fixture_bin.mkdir()
        shutil.copyfile(fleet_root / "bin/fleet-mcp.py", fixture_bin / "fleet-mcp.py")
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
            "CODEX_HOME": str(codex_home), "TMPDIR": str(root),
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_CACHE_HOME": str(home / ".cache"),
            "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "TMUX": str(root / "unused.sock") + ",0,0", "TMUX_PANE": "%999999",
            "FLEET_CONF_DIR": str(root / "fleet-conf"), "FLEET_SESSION": "fixture-only-session",
            "FLEET_WORKER_CRED": "fixture-only-malformed", "FLEET_MCP_BIN": str(fixture_bin),
        }
        if role_checks:
            tmux_binary = shutil.which("tmux")
            check(bool(tmux_binary), "native role probe requires tmux")
            socket = root / "fixture-fleet"

            def fixture_tmux(*arguments):
                result = subprocess.run([tmux_binary, "-S", str(socket), *arguments],
                                        env=environment, capture_output=True, text=True, timeout=5)
                if result.returncode:
                    raise AssertionError("isolated tmux failed: " + result.stderr[-500:])
                return result.stdout.strip()

            cleanup.callback(subprocess.run, [tmux_binary, "-S", str(socket), "kill-server"],
                             env=environment, capture_output=True, timeout=5)
            fixture_tmux("-f", "/dev/null", "new-session", "-d", "-s", "fixture-fleet",
                         "-n", "scratch-1", "sleep 120")
            fixture_pane = fixture_tmux("display-message", "-p", "#{pane_id}")
            fixture_window = fixture_tmux("display-message", "-p", "#{window_id}")
            fixture_fid = "11111111-1111-4111-8111-111111111111"
            for option, value in (("@fleet_id", fixture_fid), ("@cc_agent", "codex"), ("@fleet_role", "worker")):
                fixture_tmux("set-window-option", "-t", fixture_window, option, value)
            environment.update(TMUX=str(socket) + ",0,0", TMUX_PANE=fixture_pane, FLEET_SESSION="fixture-fleet")
            for name in ("fleet-lib.sh", "fleet-role-take.sh"):
                shutil.copy2(fleet_root / "bin" / name, fixture_bin / name)
                (fixture_bin / name).chmod(0o700)
            minted = subprocess.run([sys.executable, str(fixture_bin / "fleet-mcp.py"), "--cred", "mint"],
                                    env=environment, cwd=root, capture_output=True, text=True, timeout=10)
            check(minted.returncode == 0 and minted.stdout.startswith("fwc1."), "fixture credential minted by real Fleet code")
            environment["FLEET_WORKER_CRED"] = minted.stdout.strip()
        market = root / "market"
        plugin = market / "plugins/fleet-orchestrate"
        shutil.copytree(fleet_root / "plugins/fleet-orchestrate", plugin)
        (market / ".claude-plugin").mkdir()
        (market / ".claude-plugin/marketplace.json").write_text(json.dumps({
            "name": "claude-fleet", "owner": {"name": "Fixture"},
            "plugins": [{"name": "fleet-orchestrate", "source": "./plugins/fleet-orchestrate",
                         "description": "Candidate package acceptance"}]}), encoding="utf-8")
        manifest = json.loads((plugin / ".codex-plugin/plugin.json").read_text())

        def execute(*arguments):
            child = subprocess.Popen([binary, *arguments], env=environment, cwd=root,
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = child.communicate(timeout=25)
            except subprocess.TimeoutExpired:
                stop(child)
                child.communicate(timeout=5)
                raise AssertionError("native package CLI exceeded 25 seconds")
            check(child.returncode == 0, "CLI " + " ".join(arguments[:3]) +
                  (": " + stderr[-1000:] if child.returncode else ""))
            return stdout

        version = execute("--version").strip()
        execute("plugin", "marketplace", "add", str(market), "--json")
        execute("plugin", "add", plugin_id, "--json")
        installed = json.loads(execute("plugin", "list", "--marketplace", "claude-fleet", "--json"))
        check(len(installed["installed"]) == 1 and installed["installed"][0]["enabled"],
              "actual package installed and enabled")
        endpoint = root / "backend.sock"
        with (root / "backend.log").open("w", encoding="utf-8") as log:
            backend = subprocess.Popen([binary, "app-server", "--listen", "unix://" + str(endpoint)],
                                       env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                       stdout=log, stderr=log, start_new_session=True)
            client = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists() and backend.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                check(endpoint.exists() and backend.poll() is None, "owned package backend ready")
                client = client_type("unix://" + str(endpoint), timeout=5)
                skills = client.call("skills/list", {"cwds": [str(root)], "forceReload": True})
                names = {skill["name"] for entry in skills["data"] for skill in entry["skills"]
                         if skill.get("pluginId") == plugin_id and skill["enabled"]}
                check("fleet-orchestrate:fleet-orchestrate" in names, "actual orchestration skill discovered")
                hooks = client.call("hooks/list", {"cwds": [str(root)]})
                hook_report = hooks
                hooks = [hook for entry in hooks["data"] for hook in entry["hooks"]
                         if hook.get("pluginId") == plugin_id]
                if hooks or any(entry.get("warnings") or entry.get("errors") for entry in hook_report["data"]):
                    raise AssertionError("Claude-only hooks loaded or hook configuration failed: " + json.dumps(hook_report))
                check(True, "explicit empty native hooks suppress Claude-only default file without warnings")
                native = client.call("thread/start", {"cwd": str(root), "model": "probe",
                                                     "approvalPolicy": "never", "sandbox": "read-only"})
                status = client.call("mcpServerStatus/list", {})
                servers = [entry for entry in status["data"] if entry["name"] == "fleet-orch"]
                # The dispatch group ships with the core (issue #4334): the launcher mounts
                # conf/mcp-orch.json where @agent_spawn is 1 — the package carries none.
                check(not [entry for entry in servers if entry.get("pluginId") == plugin_id],
                      "native package mounts no dispatch tools (the core's launcher does)")
                check((root / "logs/mcp-calls.log").is_file(), "audit remains in temporary directory")
                check("# >>> fleet plugins" not in configuration.read_text() and
                      not any((codex_home / "skills").glob("fleet-*")),
                      "no legacy MCP block or Fleet skill links generated")
                check("trusted_hash" not in configuration.read_text(), "no hook trust written")
            finally:
                try:
                    if client is not None:
                        client.close()
                finally:
                    stop(backend)
        return {"version": version, "package_version": manifest["version"], "checks": checks, "role_checks": role_checks,
                "manifest_sha256": hashlib.sha256((plugin / ".codex-plugin/plugin.json").read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--fleet-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--mcp-env", choices=("all", "bare", "allowlist", "expanded"), default="all")
    parser.add_argument("--retire-bridge", action="store_true", help="also exercise candidate bridge retirement in the temporary home")
    parser.add_argument("--package", action="store_true", help="test the unmodified fleet-orchestrate package instead of fixtures")
    parser.add_argument("--package-role", action="store_true", help="test the package with real role scripts and credentials on isolated tmux")
    arguments = parser.parse_args()
    if arguments.package_role:
        arguments.package = True
    if arguments.package and (arguments.retire_bridge or arguments.mcp_env != "all"):
        parser.error("--package cannot be combined with fixture options")
    binary = shutil.which(arguments.codex)
    if not binary:
        parser.error("native Codex binary required; not a default CI test")
    client_type = runpy.run_path(str(arguments.fleet_root / "bin/fleet-codex-rpc.py"))["Client"]
    modes = ("bare", "allowlist", "expanded") if arguments.mcp_env == "all" else (arguments.mcp_env,)
    reports = ([probe_package(str(Path(binary).resolve()), client_type, arguments.fleet_root.resolve(), arguments.package_role)]
               if arguments.package else
               [probe(str(Path(binary).resolve()), client_type, mode, arguments.fleet_root.resolve(), arguments.retire_bridge)
                for mode in modes])
    print(json.dumps({"scope": "isolated native plugins, fixture tool calls and Fleet credential refusal; no model or live changes",
                      "runs": reports, "passed": sum(len(report["checks"]) for report in reports)}, indent=2))


if __name__ == "__main__":
    main()
