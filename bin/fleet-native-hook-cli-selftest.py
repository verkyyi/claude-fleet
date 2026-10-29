#!/usr/bin/env python3
"""Opt-in native hook trust probe; reviewed fixture only, inference rejected locally."""
import argparse
import contextlib
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import runpy
import select
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time


HOOK_SCRIPT = '''import json, os, sys
from pathlib import Path
payload = json.load(sys.stdin)
result = {"event": payload.get("hook_event_name"), "source": payload.get("source"),
          "session_id": payload.get("session_id"),
          "environment": {name: os.environ.get(name) for name in
              ("PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT", "PLUGIN_DATA", "CLAUDE_PLUGIN_DATA", "FLEET_SESSION")}}
Path(sys.argv[1] + "." + payload["session_id"]).write_text(json.dumps(result))
'''

DENY_SCRIPT = '''import json, sys
from pathlib import Path
payload = json.load(sys.stdin)
Path(sys.argv[1]).write_text(json.dumps(payload))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
    "permissionDecision": "deny", "permissionDecisionReason": sys.argv[2]}}))
'''

CAPTURE_SCRIPT = '''import json, sys
from pathlib import Path
payload = json.load(sys.stdin)
Path(sys.argv[1] + "." + payload["session_id"]).write_text(json.dumps(payload))
'''


def stop(child):
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--fleet-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--probe-bypass", action="store_true", help="also test the launcher's hook-trust bypass against an untrusted fixture")
    parser.add_argument("--remote-tui", action="store_true", help="exercise an actual remote TUI on an owned PTY instead of embedded exec")
    parser.add_argument("--managed-system-dir", type=Path, help="empty temporary directory already bind-mounted at /etc/codex in an isolated GitHub-hosted CI namespace")
    arguments = parser.parse_args()
    binary = shutil.which(arguments.codex)
    if not binary:
        parser.error("native Codex required; not a default CI test")
    binary = str(Path(binary).resolve())
    system_directory = None
    if arguments.managed_system_dir:
        if (sys.platform != "linux" or os.geteuid() == 0 or os.environ.get("GITHUB_ACTIONS") != "true"
                or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
            parser.error("system directory mode requires a non-root process in disposable GitHub-hosted Linux CI")
        try:
            system_directory = arguments.managed_system_dir.resolve(strict=True)
            namespace = os.stat("/proc/self/ns/mnt").st_ino
            parent_namespace = int(os.environ.get("FLEET_NATIVE_PARENT_MOUNT_NS", "0"))
            if (system_directory.parent != Path("/tmp") or not system_directory.name.startswith("fleet-managed-system-")
                    or system_directory.stat().st_uid != os.geteuid() or any(system_directory.iterdir())
                    or not system_directory.samefile("/etc/codex") or not parent_namespace or namespace == parent_namespace):
                parser.error("managed system fixture must be empty, owned, temporary and bind-mounted in a separate mount namespace")
        except (OSError, ValueError) as error:
            parser.error("invalid managed system fixture: " + str(error))
    managed_probe = bool(system_directory)
    client_type = runpy.run_path(str(arguments.fleet_root / "bin/fleet-codex-rpc.py"))["Client"]
    requests, checks = [], []
    tool_fixture = {"active": False, "requests": []}
    managed_hook_count = 1

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    def hook_result(path, identifiers):
        result = Path(str(path) + "." + identifiers[0]) if len(identifiers) == 1 else None
        return json.loads(result.read_text()) if result is not None and result.exists() else None

    def clear_hook_results(path):
        for result in path.parent.glob(path.name + ".*"):
            result.unlink()

    def phase_requests(offset, identifiers, expected, phase):
        current = requests[offset:]
        primary = [request for request in current if not request["native_title"]]
        titles = [request for request in current if request["native_title"]]
        check(len(primary) == expected, phase + " exact primary request count: " + json.dumps(current))
        check(all(request["thread_id"] in identifiers for request in primary), phase + " requests belong to the exact native thread")
        check(len(titles) <= (1 if expected else 0)
              and all(request["thread_id"] and request["thread_id"] not in identifiers for request in titles),
              phase + " at most one separately identified native title request")
        return primary

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            metadata = json.loads(request.get("client_metadata", {}).get("x-codex-turn-metadata", "{}"))
            output_format = request.get("text", {}).get("format", {})
            title_schema = output_format.get("schema", {})
            native_title = (metadata.get("thread_source") == "thread_title" and not request.get("tools")
                            and output_format.get("type") == "json_schema" and title_schema.get("required") == ["title"]
                            and set(title_schema.get("properties", {})) == {"title"})
            requests.append({"path": self.path, "authorization": bool(self.headers.get("Authorization")),
                             "request_kind": metadata.get("request_kind"), "turn_id": metadata.get("turn_id"),
                             "thread_id": self.headers.get("thread-id"), "thread_source": metadata.get("thread_source"),
                             "native_title": native_title,
                             "generate": request.get("generate"),
                             "input_hash": hashlib.sha256(json.dumps(request.get("input"), sort_keys=True).encode()).hexdigest(),
                             "input_types": [{"type": item.get("type"), "role": item.get("role")}
                                             for item in request.get("input", [])],
                             "keys": sorted(request), "header_names": sorted(self.headers.keys())})
            if tool_fixture["active"] and not native_title:
                tool_fixture["requests"].append(request)
                sequence = len(tool_fixture["requests"])
                if sequence == 1:
                    if tool_fixture.get("patch"):
                        item = {"type": "custom_tool_call", "id": "fc_fixture", "call_id": "call_fixture", "name": "exec",
                                "input": "text(await tools.apply_patch(" + json.dumps(tool_fixture["patch"]) + "));"}
                    else:
                        item = {"type": "function_call", "id": "fc_fixture", "call_id": "call_fixture", "name": "exec_command",
                                "arguments": json.dumps({"cmd": tool_fixture["command"], "max_output_tokens": 100})}
                else:
                    item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                            "content": [{"type": "output_text", "text": "fixture complete", "annotations": []}]}
                response = {"id": "resp_fixture_" + str(sequence), "object": "response", "status": "completed",
                            "output": [item], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
                events = [{"type": "response.created", "response": dict(response, status="in_progress", output=[])},
                          {"type": "response.output_item.added", "output_index": 0, "item": item},
                          {"type": "response.output_item.done", "output_index": 0, "item": item},
                          {"type": "response.completed", "response": response}]
                body = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n" for event in events).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            body = b'{"error":{"message":"offline hook probe; inference disabled"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    endpoint = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
    threading.Thread(target=endpoint.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="fleet-hook-native-", dir="/tmp") as temporary:
            root = Path(temporary).resolve()
            home = root / "home"
            codex_home = home / ".codex"
            codex_home.mkdir(parents=True)
            (codex_home / "config.toml").write_text(
                'model="probe"\nmodel_provider="offline"\napproval_policy="never"\nsandbox_mode="read-only"\n'
                '[features]\ndaemon_auto_start=false\nhooks=true\nremote_plugin=false\n'
                '[model_providers.offline]\nname="offline"\n'
                f'base_url="http://127.0.0.1:{endpoint.server_port}/v1"\n'
                'wire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n',
                encoding="utf-8")
            if arguments.remote_tui:
                with (codex_home / "config.toml").open("a", encoding="utf-8") as config:
                    config.write('\n[projects.' + json.dumps(str(root)) + ']\ntrust_level="trusted"\n')
            environment = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home), "CODEX_HOME": str(codex_home),
                "TMPDIR": str(root), "XDG_CONFIG_HOME": str(home / ".config"), "XDG_CACHE_HOME": str(home / ".cache"),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0",
                "FLEET_SESSION": "fixture-session",
            }
            managed_marker = root / "managed-result.json"
            if managed_probe:
                system = system_directory
                managed = root / "managed"
                managed.mkdir()
                (managed / "hook.py").write_text(HOOK_SCRIPT, encoding="utf-8")
                (system / "requirements.toml").write_text(
                    '[features]\nhooks=true\n[hooks]\nmanaged_dir=' + json.dumps(str(managed)) + '\n'
                    '[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\ntype="command"\ncommand='
                    + json.dumps("python3 " + str(managed / "hook.py") + " " + str(managed_marker)) + '\n',
                    encoding="utf-8")
                mapping_marker = "fleet-probe-" + root.name
                (system / mapping_marker).write_text("fixture-only", encoding="utf-8")
                environment["RUST_LOG"] = "codex_hooks=debug"
                check(Path("/etc/codex", mapping_marker).read_text() == "fixture-only",
                      "private kernel mount exposes the fixture without PRoot")
            market = root / "market"
            plugin = market / "plugins/native-hook-fixture"
            for directory in (market / ".claude-plugin", plugin / ".claude-plugin", plugin / "hooks"):
                directory.mkdir(parents=True)
            (market / ".claude-plugin/marketplace.json").write_text(json.dumps({
                "name": "fleet-hook-probe", "owner": {"name": "Fixture"}, "plugins": [{
                    "name": "native-hook-fixture", "source": "./plugins/native-hook-fixture", "description": "Offline fixture"}]}))
            (plugin / ".claude-plugin/plugin.json").write_text(json.dumps({
                "name": "native-hook-fixture", "version": "0.1.0", "description": "Offline fixture"}))
            (plugin / "hook.py").write_text(HOOK_SCRIPT, encoding="utf-8")
            marker = root / "hook-result.json"
            hook_command = 'python3 "${CLAUDE_PLUGIN_ROOT}/hook.py" ' + str(marker)
            (plugin / "hooks/hooks.json").write_text(json.dumps({"hooks": {"SessionStart": [{
                "hooks": [{"type": "command", "command": hook_command}]}]}}))

            def command(*values):
                child = subprocess.Popen([binary, *values], env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                try:
                    stdout, stderr = child.communicate(timeout=25)
                except BaseException:
                    stop(child)
                    child.communicate(timeout=5)
                    raise
                return child.returncode, stdout, stderr

            @contextlib.contextmanager
            def client(stage, extra_flags=()):
                socket = root / (stage + ".sock")
                with (root / (stage + ".log")).open("w", encoding="utf-8") as log:
                    child = subprocess.Popen([binary, *extra_flags, "app-server", "--listen", "unix://" + str(socket)],
                                             env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                             stdout=log, stderr=log, start_new_session=True)
                    rpc = None
                    try:
                        deadline = time.monotonic() + 10
                        while not socket.exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(.05)
                        check(socket.exists() and child.poll() is None, stage + " owned backend ready")
                        rpc = client_type("unix://" + str(socket), timeout=5)
                        yield rpc
                    finally:
                        try:
                            if rpc is not None:
                                rpc.close()
                        finally:
                            stop(child)

            def fixture_hook(rpc):
                entries = rpc.call("hooks/list", {"cwds": [str(root)]})["data"]
                if managed_probe:
                    managed_hooks = [hook for entry in entries for hook in entry["hooks"] if hook.get("isManaged")]
                    check(len(managed_hooks) == managed_hook_count
                          and all(hook["source"] == "system" and hook["trustStatus"] == "managed" for hook in managed_hooks),
                          "system requirements hook has managed trust independently of plugin: "
                          + json.dumps([{key: hook.get(key) for key in ("source", "isManaged", "trustStatus")}
                                        for entry in entries for hook in entry["hooks"]]))
                hooks = [hook for entry in entries for hook in entry["hooks"]
                         if hook.get("pluginId") == "native-hook-fixture@fleet-hook-probe"]
                check(len(hooks) == 1 and not hooks[0]["isManaged"], "exactly one non-managed fixture hook")
                return hooks[0]

            def remote_turn(phase, flags, expected_status="failed"):
                stage = "turn-" + phase
                with client(stage) as rpc:
                    existing_ids = {thread["id"] for thread in rpc.call("thread/list", {"limit": 100})["data"]}
                    descriptor, slave = pty.openpty()
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 130, 0, 0))
                    child = None
                    output = bytearray()
                    try:
                        child = subprocess.Popen(
                            [sys.executable, "-c",
                             "import fcntl,os,sys,termios; fcntl.ioctl(0,termios.TIOCSCTTY,0); os.execv(sys.argv[1],sys.argv[1:])",
                             binary, "--remote", "unix://" + str(root / (stage + ".sock")),
                             "--no-alt-screen", *flags, "Run only the offline fixture's test command." if tool_fixture["active"]
                             else "Offline hook probe; inference is disabled. Do not run tools."],
                            env=dict(environment, TERM="xterm-256color"), cwd=root,
                            stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                        os.close(slave)
                        slave = None
                        deadline = time.monotonic() + 45
                        while time.monotonic() < deadline and child.poll() is None:
                            readable, _, _ = select.select([descriptor], [], [], .1)
                            if readable:
                                chunk = os.read(descriptor, 65536)
                                output.extend(chunk)
                                if b"\x1b[6n" in chunk:
                                    os.write(descriptor, b"\x1b[1;1R")
                                if b"\x1b[c" in chunk:
                                    os.write(descriptor, b"\x1b[?1;2c")
                            if b"Hooks need review" in output and b"trusting" in output:
                                return {"review_required": True, "thread_id": None}
                            if len(requests) > before:
                                threads = rpc.call("thread/list", {"limit": 10})["data"]
                                for thread in threads:
                                    if thread["id"] in existing_ids or thread.get("cwd") != str(root):
                                        continue
                                    loaded = rpc.call("thread/read", {"threadId": thread["id"], "includeTurns": True})["thread"]
                                    turns = loaded.get("turns", [])
                                    if turns and turns[-1].get("status") == expected_status:
                                        return {"review_required": False, "thread_id": thread["id"]}
                        raise AssertionError(phase + " remote TUI reached neither review nor " + expected_status + " turn: "
                                             + output[-1500:].decode(errors="replace"))
                    finally:
                        os.close(descriptor)
                        if child is not None:
                            try:
                                child.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                stop(child)
                        if slave is not None:
                            os.close(slave)

            result, version, _stderr = command("--version")
            check(result == 0, "native CLI version")
            for values in (("plugin", "marketplace", "add", str(market), "--json"),
                           ("plugin", "add", "native-hook-fixture@fleet-hook-probe", "--json")):
                result, _stdout, stderr = command(*values)
                check(result == 0, "native install: " + stderr[-300:] if result else "native install")
            report = {"scope": "offline native hook fixtures; no real model or credentials, not panel acceptance",
                      "version": version.strip(), "remote_tui": arguments.remote_tui,
                      "managed_mapping": "mount-namespace" if system_directory else False, "phases": []}
            if arguments.probe_bypass:
                inline = 'hooks.SessionStart=[{hooks=[{type="command",command="printf isolated-core-hook"}]}]'
                with client("inline-classification", ("-c", inline)) as rpc:
                    entries = rpc.call("hooks/list", {"cwds": [str(root)]})["data"]
                    inline_hooks = [hook for entry in entries for hook in entry["hooks"]
                                    if hook.get("source") == "sessionFlags"]
                    check(len(inline_hooks) == 1, "inline session hook source identified independently of plugin")
                    check(not inline_hooks[0]["isManaged"] and inline_hooks[0]["trustStatus"] == "untrusted",
                          "CLI hook configuration is not administrator-managed trust")
                    report["inline_hook"] = {key: inline_hooks[0][key] for key in ("source", "isManaged", "trustStatus")}
            trusted_hash = None
            phases = ("untrusted", "bypassed", "trusted", "changed") if arguments.probe_bypass else ("untrusted", "trusted", "changed")
            if arguments.remote_tui and arguments.probe_bypass:
                phases = ("bypassed", "untrusted", "trusted", "changed")
            for phase in phases:
                if phase == "changed":
                    installed = codex_home / "plugins/cache/fleet-hook-probe/native-hook-fixture/0.1.0/hooks/hooks.json"
                    content = json.loads(installed.read_text())
                    content["hooks"]["SessionStart"][0]["hooks"][0]["command"] += " changed"
                    installed.write_text(json.dumps(content))
                with client(phase) as rpc:
                    hook = fixture_hook(rpc)
                    if phase == "trusted":
                        trusted_hash = hook["currentHash"]
                        rpc.call("config/value/write", {"keyPath": "hooks.state", "mergeStrategy": "upsert",
                                 "value": {hook["key"]: {"trusted_hash": trusted_hash}}})
                    elif phase in ("untrusted", "bypassed"):
                        check(hook["trustStatus"] == "untrusted", "install does not grant hook trust")
                    else:
                        check(hook["trustStatus"] == "modified" and hook["currentHash"] != trusted_hash,
                              "changed definition requires fresh native review")
                with client(phase + "-verify") as rpc:
                    hook = fixture_hook(rpc)
                    check(hook["trustStatus"] == {"untrusted": "untrusted", "bypassed": "untrusted", "trusted": "trusted", "changed": "modified"}[phase],
                          phase + " trust persists across native backend restart")
                clear_hook_results(marker)
                clear_hook_results(managed_marker)
                before = len(requests)
                flags = ["--dangerously-bypass-hook-trust"] if phase == "bypassed" else []
                review_required = False
                if arguments.remote_tui:
                    outcome = remote_turn(phase, flags)
                    review_required = outcome["review_required"]
                    identifiers = [outcome["thread_id"]] if outcome["thread_id"] else []
                    check(review_required == (phase in ("untrusted", "changed")),
                          phase + " remote review gate matches native trust")
                    check(review_required or bool(identifiers), phase + " remote turn failure has exact native identity")
                else:
                    result, stdout, _stderr = command(*flags, "exec", "--json", "--skip-git-repo-check",
                                                       "Offline hook probe; inference is disabled. Do not run tools.")
                    events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
                    identifiers = [event["thread_id"] for event in events if event.get("type") == "thread.started"]
                    check(result != 0 and any(event.get("type") == "turn.failed" for event in events),
                          phase + " inference intentionally fails: " + json.dumps({"exit": result, "stderr": _stderr[-1500:], "stdout": stdout[-1500:]}))
                phase_requests(before, identifiers, 0 if review_required else 1, phase)
                observed = hook_result(marker, identifiers)
                if managed_probe:
                    managed_observed = hook_result(managed_marker, identifiers)
                    if review_required:
                        check(not list(managed_marker.parent.glob(managed_marker.name + ".*")),
                              phase + " review blocks session before either hook executes")
                    else:
                        check(managed_observed is not None and managed_observed["event"] == "SessionStart"
                              and identifiers == [managed_observed["session_id"]],
                              phase + " managed hook executes on exact native thread independently of plugin trust: "
                              + json.dumps({"managed": managed_observed, "plugin": observed, "thread_ids": identifiers,
                                            "completed_phases": report["phases"],
                                            "hook_logs": [line[-1500:] for path in (codex_home / "log").glob("*.log")
                                                          for line in path.read_text(errors="replace").splitlines() if "hook" in line.lower()][-10:],
                                            "native_stderr": _stderr[-1500:] if not arguments.remote_tui else "remote TUI"}))
                if phase in ("trusted", "bypassed"):
                    check(observed is not None and observed["event"] == "SessionStart" and observed["source"] == "startup",
                          phase + " native SessionStart executes")
                    check(identifiers == [observed["session_id"]], "hook identifies the actual native thread")
                    inherited = observed["environment"]
                    installed_root = str(codex_home / "plugins/cache/fleet-hook-probe/native-hook-fixture/0.1.0")
                    check(inherited["PLUGIN_ROOT"] == inherited["CLAUDE_PLUGIN_ROOT"] == installed_root, "native plugin root aliases agree")
                    check(inherited["PLUGIN_DATA"] == inherited["CLAUDE_PLUGIN_DATA"] and bool(inherited["PLUGIN_DATA"]), "native plugin data aliases agree")
                    check(inherited["FLEET_SESSION"] == "fixture-session", "native hook inherits fixture Fleet session")
                else:
                    check(not list(marker.parent.glob(marker.name + ".*")), phase + " hook does not execute")
                report["phases"].append({"phase": phase, "trust": hook["trustStatus"], "executed": observed is not None,
                                         "review_required": review_required})
                if managed_probe:
                    report["phases"][-1]["managed_executed"] = managed_observed is not None
            if managed_probe:
                with client("tool-fixture-trust") as rpc:
                    hook = fixture_hook(rpc)
                    rpc.call("config/value/write", {"keyPath": "hooks.state", "mergeStrategy": "upsert",
                             "value": {hook["key"]: {"trusted_hash": hook["currentHash"]}}})
                tool_marker = root / "tool-executed"
                deny_marker = root / "denied-tool.json"
                (managed / "deny.py").write_text(DENY_SCRIPT, encoding="utf-8")
                tool_fixture.update(active=True, command="printf native-guard-canary > " + shlex.quote(str(tool_marker)))
                report["tool_phases"] = []
                reason = "fixture-managed-denial-v1"
                base_requirements = (system / "requirements.toml").read_text()
                guard_source = (arguments.fleet_root / "hooks/bash-guard.py").read_bytes()
                (managed / "bash-guard.py").write_bytes(guard_source)
                check((managed / "bash-guard.py").read_bytes() == guard_source, "real Fleet guard copied without modification")
                repository = root / "git-fixture"
                remote = root / "local-remote.git"
                worktree = root / "scratch-fixture"
                alias = root / "base-alias"
                patch_capture = root / "patch-capture.json"
                base_guard_source = (arguments.fleet_root / "hooks/base-readonly-guard.py").read_bytes()
                (managed / "base-readonly-guard.py").write_bytes(base_guard_source)
                (managed / "studio-guard.py").write_bytes((arguments.fleet_root / "hooks/studio-guard.py").read_bytes())
                (managed.parent / "bin").mkdir(exist_ok=True)
                (managed.parent / "bin/fleet_studio.py").write_bytes((arguments.fleet_root / "bin/fleet_studio.py").read_bytes())
                (managed / "capture.py").write_text(CAPTURE_SCRIPT, encoding="utf-8")
                check((managed / "base-readonly-guard.py").read_bytes() == base_guard_source,
                      "real Fleet base-readonly guard copied without modification")
                generated_requirements = subprocess.run(
                    ["bash", str(arguments.fleet_root / "bin/fleet-hooks-emit.sh"), "--target", "codex-managed",
                     "--managed-dir", str(managed), "--python", str(Path(sys.executable).resolve())],
                    env=environment, cwd=root, stdin=subprocess.DEVNULL, capture_output=True,
                    text=True, timeout=10, check=True).stdout
                session_fixture = "[[hooks.SessionStart]]" + base_requirements.split("[[hooks.SessionStart]]", 1)[1]
                generated_with_fixture = generated_requirements + session_fixture
                report["managed_renderer"] = "fleet-hooks-emit.sh --target codex-managed"

                def git(*values):
                    return subprocess.run(["git", *values], env=environment, cwd=root, stdin=subprocess.DEVNULL,
                                          capture_output=True, text=True, timeout=10, check=True).stdout.strip()

                git("init", "--initial-branch=fixture", str(repository))
                git("init", "--bare", str(remote))
                (repository / "guarded.txt").write_text("original\n", encoding="utf-8")
                git("-C", str(repository), "add", "guarded.txt")
                git("-C", str(repository), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Owned native guard fixture")
                fixture_commit = git("-C", str(repository), "rev-parse", "HEAD")
                git("-C", str(repository), "worktree", "add", "--detach", str(worktree), fixture_commit)
                alias.symlink_to(repository, target_is_directory=True)
                environment["FLEET_MAIN"] = str(repository)
                environment["FLEET_CONF_DIR"] = str(home / "fleet-conf")
                force_push = "cd " + shlex.quote(str(repository)) + " && git push --force " + shlex.quote(str(remote))
                add_base = "*** Add File: git-fixture/patch-canary\n+patched\n"
                add_worktree = "*** Add File: scratch-fixture/patch-canary\n+patched\n"
                patch_phases = {
                    "patch-control": add_base,
                    "patch-deny": add_base,
                    "patch-local-disable": add_base,
                    "patch-symlink": "*** Add File: base-alias/patch-canary\n+patched\n",
                    "patch-update": "*** Update File: git-fixture/guarded.txt\n@@\n-original\n+patched\n",
                    "patch-delete": "*** Delete File: git-fixture/guarded.txt\n",
                    "patch-move": "*** Update File: scratch-fixture/guarded.txt\n*** Move to: git-fixture/moved.txt\n@@\n-original\n+patched\n",
                    "patch-batch": add_worktree + add_base,
                    "patch-allow": add_worktree,
                }
                for phase in ("allow-control", "deny", "local-disable", "updated-guard",
                              "fleet-control", "fleet-deny", "fleet-local-disable", "fleet-allow", *patch_phases):
                    real_guard_phase = phase.startswith("fleet-")
                    patch_phase = phase in patch_phases
                    if phase == "deny":
                        managed_hook_count = 2
                        with (system / "requirements.toml").open("a", encoding="utf-8") as config:
                            config.write('[[hooks.PreToolUse]]\nmatcher="^Bash$"\n[[hooks.PreToolUse.hooks]]\n'
                                         'type="command"\ncommand=' + json.dumps("python3 " + str(managed / "deny.py")
                                         + " " + str(deny_marker) + " " + reason) + '\n')
                    elif phase == "updated-guard":
                        previous_reason = reason
                        reason = "fixture-managed-denial-v2"
                        config = system / "requirements.toml"
                        config.write_text(config.read_text().replace(previous_reason, reason), encoding="utf-8")
                    elif phase in ("fleet-control", "patch-control"):
                        managed_hook_count = 1
                        (system / "requirements.toml").write_text(base_requirements, encoding="utf-8")
                    elif phase == "fleet-deny":
                        managed_hook_count = 3
                        (system / "requirements.toml").write_text(generated_with_fixture, encoding="utf-8")
                    elif phase == "patch-deny":
                        managed_hook_count = 4
                        (system / "requirements.toml").write_text(generated_with_fixture, encoding="utf-8")
                        with (system / "requirements.toml").open("a", encoding="utf-8") as config:
                            config.write('[[hooks.PreToolUse]]\nmatcher="^apply_patch$"\n[[hooks.PreToolUse.hooks]]\n'
                                         'type="command"\ncommand='
                                         + json.dumps("python3 " + str(managed / "capture.py") + " " + str(patch_capture)) + '\n')
                    if real_guard_phase:
                        git("--git-dir=" + str(remote), "update-ref", "-d", "refs/heads/main")
                        destination = "fixture-feature" if phase == "fleet-allow" else "main"
                        tool_fixture["command"] = force_push + " HEAD:refs/heads/" + destination
                    if patch_phase:
                        tool_fixture["patch"] = "*** Begin Patch\n" + patch_phases[phase] + "*** End Patch\n"
                        for checkout in (repository, worktree):
                            (checkout / "patch-canary").unlink(missing_ok=True)
                        clear_hook_results(patch_capture)
                    with client("tool-" + phase + "-verify") as rpc:
                        fixture_hook(rpc)
                    for marker_path in (tool_marker, deny_marker):
                        marker_path.unlink(missing_ok=True)
                    clear_hook_results(managed_marker)
                    clear_hook_results(marker)
                    tool_fixture["requests"] = []
                    before = len(requests)
                    flags = ["-c", 'sandbox_mode="danger-full-access"']
                    if patch_phase:
                        flags += ["-c", 'model="gpt-6.1-sol"']
                    if phase in ("local-disable", "fleet-local-disable", "patch-local-disable"):
                        flags += ["-c", "features.hooks=false"]
                    if arguments.remote_tui:
                        outcome = remote_turn("tool-" + phase, flags, expected_status="completed")
                        check(not outcome["review_required"] and bool(outcome["thread_id"]), phase + " actual remote turn completes")
                        identifiers = [outcome["thread_id"]]
                    else:
                        result, stdout, stderr = command(*flags, "exec", "--json", "--skip-git-repo-check",
                                                        "Run only the offline fixture's test command.")
                        events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
                        check(result == 0 and any(event.get("type") == "turn.completed" for event in events),
                              phase + " actual native tool turn completes: " + stderr[-1500:])
                        identifiers = [event["thread_id"] for event in events if event.get("type") == "thread.started"]
                    phase_requests(before, identifiers, 2, phase)
                    first_request = tool_fixture["requests"][0]
                    if patch_phase:
                        offered = first_request.get("tools", []) + [tool for item in first_request.get("input", [])
                                  if item.get("type") == "additional_tools" for tool in item.get("tools", [])]
                        check(any(tool.get("type") == "namespace" and tool.get("name") == "functions"
                                  and any(child.get("type") == "custom" and child.get("name") == "exec"
                                          and "apply_patch(input: string)" in child.get("description", "")
                                          for child in tool.get("tools", [])) for tool in offered),
                              phase + " native runtime offers code mode with the real apply_patch tool")
                    else:
                        check(any(tool.get("name") == "exec_command" for tool in first_request.get("tools", [])),
                              phase + " native runtime offers the tool being tested")
                    managed_observed = hook_result(managed_marker, identifiers)
                    plugin_observed = hook_result(marker, identifiers)
                    check(managed_observed is not None and plugin_observed is not None
                          and identifiers == [managed_observed["session_id"]] == [plugin_observed["session_id"]],
                          phase + " managed and trusted plugin hooks execute on the actual tool thread")
                    outputs = [json.dumps(item.get("output", ""), ensure_ascii=False)
                               for request in tool_fixture["requests"] for item in request.get("input", [])
                               if item.get("type") in ("function_call_output", "custom_tool_call_output")
                               and item.get("call_id") == "call_fixture"]
                    if patch_phase:
                        denied = phase not in ("patch-control", "patch-allow")
                        check((repository / "guarded.txt").read_text() == "original\n"
                              and (worktree / "guarded.txt").read_text() == "original\n"
                              and not (repository / "moved.txt").exists(), phase + " tracked base and worktree files remain intact")
                        if denied:
                            check(not (repository / "patch-canary").exists() and not (worktree / "patch-canary").exists(),
                                  phase + " denied patch leaves no partial writes")
                            check(any("base-readonly-guard.py" in output and "edit-read-only" in output for output in outputs),
                                  phase + " native code mode returns the real base-readonly denial")
                        else:
                            target = repository if phase == "patch-control" else worktree
                            other = worktree if phase == "patch-control" else repository
                            check((target / "patch-canary").read_text() == "patched\n" and not (other / "patch-canary").exists(),
                                  phase + " actual native patch writes only its permitted target")
                        captured = hook_result(patch_capture, identifiers)
                        if phase == "patch-control":
                            check(captured is None, "patch control has no base-readonly or observer hook")
                        else:
                            check(captured is not None and captured["hook_event_name"] == "PreToolUse"
                                  and captured["tool_name"] == "apply_patch" and bool(captured["tool_use_id"])
                                  and identifiers == [captured["session_id"]] and captured["cwd"] == str(root)
                                  and captured["tool_input"]["command"] == tool_fixture["patch"],
                                  phase + " nested native patch hook carries the exact root thread, cwd and patch")
                        report["tool_phases"].append({"phase": phase, "executed": not denied, "denied": denied,
                                                     "guard_sha256": hashlib.sha256(base_guard_source).hexdigest()})
                    elif real_guard_phase:
                        refs = git("--git-dir=" + str(remote), "for-each-ref", "--format=%(objectname) %(refname)")
                        denied = phase in ("fleet-deny", "fleet-local-disable")
                        if denied:
                            check(not refs, phase + " actual Fleet guard prevents the owned local force-push")
                            check(any("BLOCKED by" in output and "force-push targeting the base branch" in output
                                      for output in outputs), phase + " native tool result carries the real Fleet exit-2 denial")
                        else:
                            check(refs == fixture_commit + " refs/heads/" + destination,
                                  phase + " native tool really pushes the fixture commit to the owned local remote")
                            check(not any("BLOCKED by" in output for output in outputs), phase + " allowed native tool is not denied")
                        report["tool_phases"].append({"phase": phase, "executed": not denied, "denied": denied,
                                                     "guard_sha256": hashlib.sha256(guard_source).hexdigest()})
                    elif phase == "allow-control":
                        check(tool_marker.read_text() == "native-guard-canary" and not deny_marker.exists(),
                              "positive control executes the exact harmless write without a deny hook")
                    else:
                        denied = json.loads(deny_marker.read_text())
                        check(not tool_marker.exists(), phase + " managed hook prevents the write despite fixture full-access mode")
                        check(denied["tool_name"] == "Bash" and denied["tool_use_id"] == "call_fixture"
                              and identifiers == [denied["session_id"]] and denied["tool_input"]["command"] == tool_fixture["command"],
                              phase + " managed hook receives the exact native tool and thread")
                        check(any(reason in output for output in outputs), phase + " native loop receives the current managed denial reason")
                    if not real_guard_phase and not patch_phase:
                        report["tool_phases"].append({"phase": phase, "executed": tool_marker.exists(), "denied": deny_marker.exists()})
            check(all(not request["authorization"] for request in requests), "no authorization sent to fixture endpoint")
            report.update(checks=checks, passed=len(checks), request_kinds=[
                {key: request[key] for key in ("request_kind", "thread_source", "native_title", "generate")} for request in requests])
            print(json.dumps(report, indent=2))
    finally:
        endpoint.shutdown()
        endpoint.server_close()


if __name__ == "__main__":
    main()
