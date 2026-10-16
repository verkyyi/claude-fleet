#!/usr/bin/env python3
"""Opt-in native Codex lifecycle probe; no credentials, real model, or live Fleet socket."""
import argparse
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--fleet-root", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    binary = shutil.which(arguments.codex)
    if not binary:
        parser.error("native Codex binary is required; this probe is not a default CI test")
    binary = str(Path(binary).resolve())
    requests = []
    checks = []
    runs = []

    def check(condition, name):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            requests.append({"path": self.path, "authorization_present": bool(self.headers.get("Authorization"))})
            body = json.dumps({"error": {"message": "offline lifecycle probe: inference disabled",
                                        "type": "invalid_request_error"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    report = {"scope": "isolated native CLI lifecycle only; not model, MCP, Fleet admission or panel acceptance"}
    try:
        with tempfile.TemporaryDirectory(prefix="fleet-native-cli-") as temporary:
            root = Path(temporary).resolve()
            home = root / "home"
            codex_home = home / ".codex"
            codex_home.mkdir(parents=True)
            environment = {
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
                "CODEX_HOME": str(codex_home), "XDG_CONFIG_HOME": str(home / ".config"),
                "XDG_CACHE_HOME": str(home / ".cache"), "TMPDIR": str(root),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_AUTHOR_NAME": "Fleet fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "Fleet fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            }

            def git(*values):
                return subprocess.run(["git", *map(str, values)], env=environment, capture_output=True,
                                      text=True, timeout=15, check=True).stdout.strip()

            base = root / "repository"
            git("init", "--quiet", base)
            (base / "tracked.txt").write_text("original\n", encoding="utf-8")
            git("-C", base, "add", "tracked.txt")
            git("-C", base, "commit", "--quiet", "-m", "fixture")
            report["version"] = subprocess.run([binary, "--version"], env=environment, text=True,
                                               capture_output=True, check=True, timeout=10).stdout.strip()
            config = ('model = "probe"\nmodel_provider = "offline_probe"\n'
                      'approval_policy = "never"\nsandbox_mode = "read-only"\n'
                      '[features]\ndaemon_auto_start = false\n'
                      '[model_providers.offline_probe]\nname = "offline lifecycle probe"\n'
                      'base_url = "http://127.0.0.1:%s/v1"\nwire_api = "responses"\n'
                      'requires_openai_auth = false\nrequest_max_retries = 0\nstream_max_retries = 0\n'
                      '[projects.%s]\ntrust_level = "trusted"\n') % (server.server_port, json.dumps(str(base)))
            (codex_home / "config.toml").write_text(config, encoding="utf-8")

            def execute(name, options, cwd):
                started = time.monotonic()
                child = subprocess.Popen([binary, "exec", "--json", *options], env=environment,
                                         cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True, start_new_session=True)
                timed_out = False
                try:
                    stdout, stderr = child.communicate(timeout=40)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        stdout, stderr = child.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        stdout, stderr = child.communicate()
                events = []
                for line in stdout.splitlines():
                    try:
                        events.append(json.loads(line))
                    except ValueError:
                        pass
                identifiers = {event["thread_id"] for event in events if event.get("type") == "thread.started"}
                runs.append({"name": name, "exit_code": child.returncode, "timed_out": timed_out,
                             "seconds_including_expected_failure": round(time.monotonic() - started, 3),
                             "event_types": [event.get("type") for event in events],
                             "stderr": stderr[-2000:].replace(str(root), "<fixture>")})
                check(not timed_out, name + ": bounded exit")
                check(child.returncode == 1 and any(event.get("type") == "turn.failed" and
                      "offline lifecycle probe: inference disabled" in json.dumps(event) for event in events),
                      name + ": only the intentional inference rejection ends the turn")
                check(len(identifiers) == 1, name + ": exact native session ID")
                return identifiers.pop()

            def metadata(identifier):
                found = []
                for path in codex_home.glob("sessions/**/*.jsonl"):
                    with path.open(encoding="utf-8") as stream:
                        for line in stream:
                            record = json.loads(line)
                            payload = record.get("payload", {})
                            if record.get("type") == "session_meta" and payload.get("id") == identifier:
                                found.append(payload)
                check(len(found) == 1, "unique native metadata for " + identifier)
                return found[0]

            def worktrees():
                result = git("-C", base, "worktree", "list", "--porcelain", "-z")
                return {Path(field[len("worktree "):]).resolve() for field in result.split("\0")
                        if field.startswith("worktree ")}

            prompt = "Offline lifecycle probe. Do not run tools."
            original_id = execute("create", ["--worktree", "--cd", str(base), prompt], base)
            original = metadata(original_id)
            worktree = Path(original["cwd"]).resolve()
            check(worktree != base and worktrees() == {base, worktree}, "native creation owns exactly one linked worktree")
            check(worktree.is_relative_to(codex_home), "native worktree stays in the isolated account home")
            common = Path(git("-C", worktree, "rev-parse", "--git-common-dir"))
            check((worktree / common).resolve() == base / ".git", "native directory belongs to the expected Git repository")
            (worktree / "tracked.txt").write_text("uncommitted fixture work\n", encoding="utf-8")
            resumed_id = execute("resume", ["resume", original_id, prompt], worktree)
            check(resumed_id == original_id and worktrees() == {base, worktree}, "resume keeps native identity and does not allocate a second worktree")
            check(Path(metadata(resumed_id)["cwd"]).resolve() == worktree, "resume keeps recorded native cwd")
            fork_id = execute("fork", ["fork", original_id, "--worktree", prompt], worktree)
            fork = metadata(fork_id)
            fork_worktree = Path(fork["cwd"]).resolve()
            check(fork_id != original_id and fork_worktree not in (base, worktree), "native fork has distinct session and worktree identities")
            check(worktrees() == {base, worktree, fork_worktree}, "fork adds only its own native worktree")
            check((worktree / "tracked.txt").read_text(encoding="utf-8") == "uncommitted fixture work\n",
                  "exit, resume and fork preserve original uncommitted work")
            check((base / "tracked.txt").read_text(encoding="utf-8") == "original\n", "base content remains unchanged")
            check(len(requests) == 3 and all(not request["authorization_present"] for request in requests),
                  "all three inference attempts terminate at the credential-free loopback fixture")
            environment["FLEET_MAIN"] = str(base)
            environment["FLEET_CONF_DIR"] = str(home / "fleet-conf")
            payload = {"tool_name": "apply_patch", "cwd": str(worktree),
                       "tool_input": {"command": "*** Begin Patch\n*** Update File: tracked.txt\n@@\n-old\n+new\n*** End Patch"}}
            guarded = subprocess.run([sys.executable, str(arguments.fleet_root / "hooks/base-readonly-guard.py")],
                                     env=environment, cwd=worktree, input=json.dumps(payload), text=True,
                                     capture_output=True, timeout=10)
            check(guarded.returncode == 0, "actual native Codex worktree does not require weakening the base guard")
            incompatible = subprocess.run([binary, "--remote", "unix://" + str(root / "absent.sock"),
                                           "--worktree"], env=environment, stdin=subprocess.DEVNULL,
                                          capture_output=True, text=True, timeout=10)
            check(incompatible.returncode != 0 and "only supported for local sessions" in incompatible.stderr,
                  "native worktree rejects Fleet's remote-TUI combination before connecting")
            schema_root = root / "protocol"
            generated = subprocess.run([binary, "app-server", "generate-json-schema", "--experimental",
                                        "--out", str(schema_root)], env=environment, capture_output=True,
                                       text=True, timeout=30)
            check(generated.returncode == 0, "target binary exports its own app-server protocol")
            report["app_server_protocol"] = {
                "worktree_schema_names": sorted(path.name for path in schema_root.rglob("*.json")
                                                if "worktree" in path.name.lower()),
                "thread_start_worktree_fields": {},
            }
            for schema_path in schema_root.rglob("ThreadStartParams.json"):
                properties = json.loads(schema_path.read_text(encoding="utf-8")).get("properties", {})
                report["app_server_protocol"]["thread_start_worktree_fields"] = {
                    key: value for key, value in properties.items() if "worktree" in key.lower() or key == "cwd"}
            report.update(result="pass", native_cwd=str(worktree).replace(str(root), "<fixture>"),
                          fork_cwd=str(fork_worktree).replace(str(root), "<fixture>"),
                          original_session=original_id, fork_session=fork_id)
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
        report.update(result="fail", error=str(error))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    report.update(checks=checks, runs=runs, loopback_requests=requests)
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report.get("result") == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
