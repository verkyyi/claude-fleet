#!/usr/bin/env python3
"""Real authority CLI/spawners, loopback Hub and temporary git worktrees.

The recording tmux never executes a native agent or touches a live socket.
"""
import contextlib
import copy
import http.server
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

import fleet_repo_authority as authority
import fleet_view

BIN = Path(__file__).resolve().parent
REGISTERED = "ExampleOrg/Space"
CANONICAL = "exampleorg/space"
REPO_CASES = (REGISTERED, CANONICAL, REGISTERED.upper())


class CaseAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="authority-case-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.conf = self.root / "conf"
        self.repos = self.conf / "fleets/fixture/repos"
        self.repos.mkdir(parents=True)
        (self.repos.parent / "conf").write_text('FLEET_SESSION="fixture"\n')
        self.main = self.root / "Space"
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        self.windows = self.root / "windows"
        self.env = dict(HOME=str(self.root), PATH=str(self.fakebin) + ":" + os.environ["PATH"],
                        TMPDIR=str(self.root), FLEET_CONF_DIR=str(self.conf), FLEET_SKIP_GLOBAL_CONF="1",
                        FLEET_SESSION="fixture", FLEET_TASK_AUTHORITY="legacy",
                        FLEET_MAX_SESSIONS="0", FLEET_GLOBAL_MAX_SESSIONS="0",
                        FLEET_CODEX_READY_CHECK="0", FLEET_SPAWN_NODE="local",
                        FLEET_SPAWN_OVERLAP="0",
                        # Exercise real admission with fixture readings, never
                        # the runner's CPU/memory or its running agents (#4512).
                        FLEET_CPU_BUSY_PROBE_CMD="echo 0.20", FLEET_LOAD_PROBE_CMD="echo 0.04",
                        FLEET_MEM_PROBE_CMD="echo 1 66 5 0", FLEET_MEM_TOTAL_MB="16000",
                        FLEET_MEM_PS_CMD="true",
                        CCQUOTA_TOKEN="fixture-secret", WINDOW_LOG=str(self.windows))
        self.native_calls = self.root / "native-calls"
        self.env["NATIVE_LOG"] = str(self.native_calls)
        for agent in ("claude", "codex"):
            # The spawner inspects installed plugins; answer that read locally.
            # Any agent launch attempt fails and is asserted even if swallowed.
            self.stub(agent, '''if [ "$*" = 'plugin list --json' ]; then echo '[]'; exit 0; fi
echo "$0 $*" >> "$NATIVE_LOG"; exit 99
''')
        self.addCleanup(lambda: self.assertFalse(self.native_calls.exists(), "fixture executed a native agent"))
        self.command("git", "init", "-q", "-b", "master", str(self.main))
        self.command("git", "-C", str(self.main), "-c", "user.name=Fixture", "-c", "user.email=f@example.invalid",
                     "-c", "commit.gpgsign=false", "commit", "-qm", "fixture", "--allow-empty")
        self.overlay = self.repos / "ExampleOrg-Space.conf"
        self.overlay.write_text('FLEET_REPO="ExampleOrg/Space"\nFLEET_MAIN="%s"\n'
                                'FLEET_BASE_BRANCH="master"\nFLEET_FORGE="github"\n'
                                'FLEET_TICKETS="github"\nFLEET_LAND="github"\n' % self.main)
        (self.repos / ".order").write_text("ExampleOrg-Space\n")
        self.stub("tmux", '''if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "$1" in
 display-message) case "$*" in *-p*session_name*) echo fixture;; esac ;;
 new-window) printf '%s\\n' "$*" >> "$WINDOW_LOG"; echo '@9' ;;
esac
exit 0
''')
        self.stub("gh", '''case "$1 $2" in
 "issue view") echo 'Fixture issue' ;;
 "pr list") echo '0' ;;
esac
exit 0
''')
        self.mode, self.status, self.error = "legacy", 200, "fixture refusal"
        self.bad_json, self.freeze_on_finish = False, False
        self.requests = []
        owner = self

        class Hub(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append((self.path, None))
                if owner.freeze_on_finish and len(owner.requests) > 1:
                    owner.mode = "frozen"
                self.send_response(owner.status)
                self.end_headers()
                if owner.bad_json:
                    self.wfile.write(b"{invalid JSON")
                    return
                self.wfile.write(json.dumps(dict(mode=owner.mode, revision=0, error=owner.error,
                                                authority=dict(mode=owner.mode, revision=0))).encode())

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append((self.path, body))
                self.send_response(owner.status)
                self.end_headers()
                self.wfile.write(json.dumps(dict(mode=owner.mode, reservation=body.get("reservation"),
                                                error=owner.error)).encode())

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.env["CCQUOTA_HUB_URL"] = "http://127.0.0.1:%d" % self.server.server_port

    def stub(self, name, body):
        f = self.fakebin / name
        f.write_text("#!/bin/bash\n" + body)
        f.chmod(0o755)

    def run_command(self, *args):
        return subprocess.run(args, env=self.env, cwd=self.root, text=True, capture_output=True, timeout=30)

    def command(self, *args):
        result = self.run_command(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def assert_person_road(self):
        # Every read is the person's road (issue #4901); a repo travels only
        # where it names a start or narrows a list, and then canonically.
        self.assertTrue(self.requests)
        for path, _ in self.requests:
            self.assertTrue(path.startswith("/v1/fleet/authority"), path)
            self.assertTrue("repo=" not in path or "repo=exampleorg%2Fspace" in path, path)
            if "gate=1" in path:
                self.assertNotIn("repo=", path)
        starts = [path for path, _ in self.requests if path.startswith("/v1/fleet/authority/start")]
        self.assertTrue(all("repo=exampleorg%2Fspace" in path for path in starts))

    def cli(self, repo, *args):
        return self.run_command("python3", str(BIN / "fleet_repo_authority.py"), repo,
                                "--session", "fixture", *args)

    def test_gate_and_manifest_use_hub_identity_and_existing_overlay(self):
        before = self.overlay.read_bytes()
        for name in REPO_CASES:
            with self.subTest(repo=name):
                result = self.cli(name, "--gate")
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.cli(name, "--dry-run")
                self.assertEqual(result.returncode, 0, result.stderr)
                doc = json.loads(result.stdout)
                self.assertEqual(doc["repo"], CANONICAL)
                self.assertEqual(doc["scope"], "owner")
                self.assertEqual(doc["local"]["settings"], dict(FLEET_TASK_AUTHORITY=""))
        self.assert_person_road()
        self.assertEqual(before, self.overlay.read_bytes())
        self.assertEqual(sorted(p.name for p in self.repos.iterdir()), [".order", "ExampleOrg-Space.conf"])

    def test_panel_new_and_issue_start_keep_worktree_and_registration(self):
        before = self.overlay.read_bytes()
        for i, repo in enumerate(REPO_CASES):
            with self.subTest(repo=repo):
                rc, message = self.panel_new(repo)
                self.assertEqual(rc, 0, message)
                self.command("bash", str(BIN / "dash-issue-session.sh"), str(7 + i), "fixture", "--repo", repo,
                             "--origin", "hub", "--node", "local", "--agent", "claude")
                windows = self.windows.read_text()
                self.assertIn(str(self.root / ("Space-scratch-%d" % (i + 1))), windows)
                self.assertIn(str(self.root / ("Space-issue-%d" % (7 + i))), windows)
                self.assertIn(REGISTERED, windows)
                self.assertEqual(before, self.overlay.read_bytes())
        # A start is admitted by its window's ID (EPIC T497 C8): the person's
        # mode is read, nothing is reserved.
        self.assertFalse([body for _, body in self.requests if body])
        self.assert_person_road()

    def panel_new(self, repo):
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(fleet_view, "view_fleet", return_value="fixture"), \
                patch.object(fleet_view, "go", return_value=0), patch.object(fleet_view, "toast"), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            rc = fleet_view.go_new(None, "fixture@view-test", repo=repo, agent="claude")
        return rc, err.getvalue()

    def test_busy_cpu_still_refuses_panel_and_issue_without_window(self):
        # The train's exact failure reading: idle load does not excuse 95% CPU.
        self.env["FLEET_CPU_BUSY_PROBE_CMD"] = "echo 0.95"
        before = self.overlay.read_bytes()
        for repo in REPO_CASES:
            with self.subTest(repo=repo):
                panel_rc, message = self.panel_new(repo)
                result = self.run_command("bash", str(BIN / "dash-issue-session.sh"), "7", "fixture",
                                          "--repo", repo, "--origin", "hub", "--node", "local", "--agent", "claude")
                for rc, expected, output in ((panel_rc, 3, message), (result.returncode, 2, result.stderr)):
                    self.assertEqual(rc, expected, output)
                    self.assertIn("CPU busy 95% over FLEET_ADMIT_CPU_BUSY=0.8", output)
                    self.assertIn("load 0.04/core", output)
                self.assertFalse(self.windows.exists())
                self.assertEqual(before, self.overlay.read_bytes())
        self.assertFalse(any(body and body.get("action") == "reserve" for _, body in self.requests))

    def test_refusals_reach_panel_and_issue_without_secret_or_false_freeze(self):
        for mode, status, reason, expected in (("frozen", 200, "", "frozen"),
                ("legacy", 400, "invalid repo", "HTTP 400"),
                ("legacy", 401, "fixture-secret", "HTTP 401"),
                ("legacy", 403, "fixture-secret", "HTTP 403"),
                ("legacy", 503, "service unavailable", "HTTP 503"),
                ("unknown", 200, "", "unknown")):
            with self.subTest(status=status, mode=mode):
                self.mode, self.status, self.error = mode, status, reason
                for script, args in (("dash-raw-session.sh", ["fixture"]),
                                     ("dash-issue-session.sh", ["7", "fixture"])):
                    result = self.run_command("bash", str(BIN / script), *args, "--repo", REGISTERED,
                                              "--origin", "hub", "--node", "local", "--agent", "claude")
                    self.assertNotEqual(result.returncode, 0)
                    message = fleet_view.new_why(result.stderr, result.returncode)
                    self.assertIn(expected, message)
                    self.assertNotIn("fixture-secret", result.stderr + result.stdout)
                    if mode != "frozen":
                        self.assertNotIn("frozen", message)
                self.assertFalse(self.windows.exists())

    def test_panel_new_session_box_uses_real_raw_entry(self):
        # The 「新会话」 box's 开 (T652, EPIC T651 C1): ONE road, `do new` → go_new,
        # nothing typed. No client lease: the local adapter, which still has to
        # pass the real Hub authority gate.
        state = fleet_view.bolt_new(dict(last=REGISTERED, agent="claude", missing={}))
        state["repo"] = REGISTERED
        quick = type("Quick", (), {"__file__": str(BIN / "fleet-quickopen.py")})
        argv, _, _ = fleet_view.bolt_argv(quick, "test", "", state, "fixture draft")
        self.assertEqual(argv[2:4], ["do", "new"])
        self.assertEqual(argv[argv.index("--repo") + 1], REGISTERED)
        self.assertNotIn("--draft", argv)

        def open_new():
            err = io.StringIO()
            here = os.getcwd()
            os.chdir(self.root)
            try:
                with patch.dict(os.environ, self.env, clear=True), \
                        patch.object(fleet_view, "view_fleet", return_value="fixture"), \
                        patch.object(fleet_view, "go", return_value=0), \
                        patch.object(fleet_view, "toast"), contextlib.redirect_stderr(err):
                    rc = fleet_view.go_new(None, "test", repo=REGISTERED, agent="claude")
            finally:
                os.chdir(here)
            return rc, err.getvalue()
        rc, err = open_new()
        self.assertEqual(rc, 0, err)
        self.assertFalse([body for _, body in self.requests if body])
        self.assert_person_road()
        self.assertIn(str(self.root / "Space-scratch-1"), self.windows.read_text())
        before = self.windows.read_bytes()
        self.mode = "frozen"
        rc, err = open_new()
        self.assertNotEqual(rc, 0)
        self.assertIn("frozen", err)
        self.assertIn("drain/cutover", err)
        self.assertEqual(self.windows.read_bytes(), before)

    def test_malformed_unknown_and_cross_repo_fail_closed(self):
        for repo in ("../space", "exampleorg/..", "exampleorg/space/extra", " exampleorg/space", "https://github.com/exampleorg/space"):
            self.assertNotEqual(self.cli(repo, "--gate").returncode, 0, repo)
        self.assertEqual(self.requests, [])

    def test_aliases_and_added_repo_keep_existing_paths_and_keys(self):
        script = '. "$1/fleet-lib.sh"; r=$(fleet_target_repo fixture "$2") || exit; fleet_load_repo_conf fixture "$r" || exit; printf "%s\\t%s\\t%s" "$r" "$FLEET_MAIN" "$(fleet_issue_key fixture "$r" 7)"'
        before = self.command("bash", "-c", script, "_", str(BIN), CANONICAL)
        data = self.overlay.read_bytes()
        other = self.repos / "Other-Repo.conf"
        other.write_text('FLEET_REPO="Other/Repo"\nFLEET_MAIN="/unused"\n')
        self.assertEqual(before, self.command("bash", "-c", script, "_", str(BIN), REGISTERED.upper()))
        self.command("bash", str(BIN / "dash-raw-session.sh"), "fixture", "--repo", CANONICAL,
                     "--origin", "hub", "--node", "local", "--agent", "claude")
        self.command("bash", str(BIN / "dash-issue-session.sh"), "7", "fixture", "--repo", REGISTERED.upper(),
                     "--origin", "hub", "--node", "local", "--agent", "claude")
        self.assertIn(str(self.root / "Space-scratch-1"), self.windows.read_text())
        self.assertIn(str(self.root / "Space-issue-7"), self.windows.read_text())
        self.assertEqual(data, self.overlay.read_bytes())
        other.unlink()
        self.assertEqual(before, self.command("bash", "-c", script, "_", str(BIN), CANONICAL))
        # A duplicate identity never picks an arbitrary overlay, even an exact spelling.
        other.write_text('FLEET_REPO="EXAMPLEORG/SPACE"\n')
        self.assertNotEqual(self.run_command("bash", "-c", script, "_", str(BIN), REGISTERED).returncode, 0)

    def test_mixed_manifest_cas_repeat_and_repo_isolation(self):
        # The cutover is this login's person's (issue #4901): any spelling of a
        # repo, or none, moves the same row and writes fleet.conf [node] only —
        # every repo overlay stays byte for byte.
        state = dict(owner="alice", mode="legacy", revision=0)
        history, writes = {}, []
        other = self.repos / "Other-Repo.conf"
        other.write_text('FLEET_REPO="Other/Repo"\nFLEET_MAIN="/unused"\n')
        saved_other, saved_local = other.read_bytes(), self.overlay.read_bytes()
        login = self.conf / "fleet.conf"

        def api(method, path, body=None, query=None):
            if method == "POST":
                self.assertNotIn("repo", query or {})
            if method == "GET":
                return copy.deepcopy(state) if query.get("gate") else dict(authority=copy.deepcopy(state))
            writes.append(body)
            key = body["idempotency_key"]
            if key not in history:
                if body["expected_revision"] != state["revision"]:
                    raise authority.hubrest.Fail(1, "stale revision")
                state.update(revision=state["revision"] + 1,
                             mode={"freeze": "frozen", "apply": "hub", "rollback": "legacy"}[body["action"]])
                history[key] = copy.deepcopy(state)
            return history[key]

        def run(*args):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                authority.main(list(args))
            return json.loads(out.getvalue())

        def login_mode():
            return authority.login_settings()[0]["settings"]["FLEET_TASK_AUTHORITY"]

        with patch.dict(os.environ, self.env, clear=True), patch.object(authority.hubrest, "api", side_effect=api):
            file = self.root / "manifest.json"
            for action, spelled in (("freeze", REGISTERED), ("apply", None), ("freeze", CANONICAL), ("rollback", None)):
                file.write_text(json.dumps(run(*([spelled] if spelled else []), "--dry-run")))
                first = run(CANONICAL, "--" + action, "--manifest", str(file))
                self.assertEqual(first["result"], run("--" + action, "--manifest", str(file))["result"])
                self.assertEqual(login_mode(), state["mode"])
                self.assertEqual(other.read_bytes(), saved_other)
                self.assertEqual(self.overlay.read_bytes(), saved_local)
            doc = run("--dry-run")
            file.write_text(json.dumps(doc))
            saved_login = login.read_bytes()
            login.write_text(login.read_text() + 'FLEET_CONCURRENT_EDIT=1\n')
            count = len(writes)
            with self.assertRaisesRegex(ValueError, "settings changed"):
                run("--freeze", "--manifest", str(file))
            self.assertEqual(len(writes), count)
            login.write_bytes(saved_login)
            file.write_text(json.dumps(run("--dry-run")))
            state["revision"] += 1
            with self.assertRaisesRegex(authority.hubrest.Fail, "stale revision"):
                run("--freeze", "--manifest", str(file))
            self.assertEqual(login.read_bytes(), saved_login)
            for field, value in (("conf", str(self.root / "other-login/fleet.conf")), ("version", 1), ("scope", "repo")):
                file.write_text(json.dumps(dict(doc, **{field: value})))
                with self.assertRaisesRegex(ValueError, "fresh dry-run"):
                    run("--apply", "--manifest", str(file))

    def test_ticket_ref_match_is_exact(self):
        for ref in ("gh:other/space#7", "gh:exampleorg/space#8", "gh:exampleorg/space#07", "GH:exampleorg/space#7", "gh:../space#7"):
            with self.assertRaises((ValueError, authority.hubrest.Fail)):
                authority.match_ticket_ref(REGISTERED, "7", ref)
        self.assertEqual(authority.match_ticket_ref(REGISTERED, "7", "gh:exampleorg/space#7"), "gh")

    def test_no_spawner_hands_a_claim_to_the_finish_gate(self):
        # EPIC T497 C8: the finish gate asks the person's mode only — a spawner
        # hands it no launch binding, no dispatch, no reservation to carry.
        entries = {}
        for f in sorted(BIN.glob("*.sh")):
            if f.name.endswith("-selftest.sh") or f.name == "fleet-lib.sh":
                continue
            lines = f.read_text(errors="replace").splitlines()
            for i, line in enumerate(lines):
                if "fleet_repo_authority_guard" in line and "--finish" in line and not line.lstrip().startswith("#"):
                    entries.setdefault(f.name, []).append(" ".join(lines[max(0, i - 1):i + 1]))
        self.assertEqual(sorted(entries), ["dash-issue-session.sh", "dash-raw-session.sh"])
        for name, stmts in entries.items():
            for stmt in stmts:
                for retired in ("FLEET_ID_DISPATCH", "FLEET_LAUNCH", "FLEET_AUTHORITY_START"):
                    self.assertNotIn(retired, stmt, name)

    def test_unavailable_and_invalid_json_are_not_frozen(self):
        self.bad_json = True
        result = self.cli(REGISTERED, "--gate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not JSON", result.stderr)
        self.assertNotIn("frozen", result.stderr)
        self.env["CCQUOTA_HUB_URL"] = "http://127.0.0.1:1"
        result = self.run_command("bash", str(BIN / "dash-raw-session.sh"), "fixture", "--repo", REGISTERED,
                                  "--origin", "hub", "--node", "local", "--agent", "claude")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("入口不通", fleet_view.new_why(result.stderr, result.returncode))
        self.assertNotIn("frozen", result.stderr)
        self.assertFalse(self.windows.exists())
        with patch.object(authority.hubrest, "api", return_value=[]):
            with self.assertRaisesRegex(ValueError, "unknown"):
                authority.gate(REGISTERED, True)

    def test_freeze_between_initial_and_final_gate_never_opens_window(self):
        self.freeze_on_finish = True
        for script, args in (("dash-raw-session.sh", ["fixture"]),
                             ("dash-issue-session.sh", ["7", "fixture"])):
            self.requests.clear()
            self.mode = "legacy"
            result = self.run_command("bash", str(BIN / script), *args, "--repo", REGISTERED,
                                      "--origin", "hub", "--node", "local", "--agent", "claude")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("drain/cutover", fleet_view.new_why(result.stderr, result.returncode))
            self.assertEqual(len(self.requests), 2)
            self.assertTrue(all(body is None for _, body in self.requests))
            self.assertFalse(self.windows.exists())


if __name__ == "__main__":
    unittest.main()
