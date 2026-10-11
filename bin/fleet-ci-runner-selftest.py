#!/usr/bin/env python3
"""fleet-ci-runner-selftest.py — the machine's test runner, sandboxed (issue #3144).

Driven by bin/fleet-ci-runner-selftest.sh; bin/fleet-break-it-ci-selftest.sh runs
its `drill <name>` mode. Nothing touches GitHub, /var or a real login: GitHub's
API is a server on 127.0.0.1, the runner a fake archive (file://, its SHA-256 in
a sandbox lock), the test login a FLEET_NODE_PASSWD entry.

  A  off: no ci.env ⇒ no child, no `ci_runner` in state.json, no status line,
     `status --check` 2; a ci.env ⇒ the child, its word in state.json, the line,
     the login among the tenants; a stale word reads `off`
  B  ci.env: neither credential ⇒ error; a half-named App ⇒ error; FLEET_CI_RUNNERS=0
     ⇒ paused, nothing minted
  C  the App: a JWT openssl signed with the App key verifies against its public
     key (RS256, iss, exp ≤ 10 min); the installation token it buys is what the
     runner calls carry; it is in no file, log or argv
  D  one run end to end: the archive checked against the lock (a wrong pin ⇒ not
     unpacked, error); one JIT runner minted with fleet-ci; run.sh started nice 10
     in a fresh <home>/runner, its environment built from nothing (the JIT config
     only in ACTIONS_RUNNER_INPUT_JITCONFIG, no FLEET_* / CCQUOTA_* / GH_TOKEN /
     credential, the gate hook set); idle → busy (a Runner.Worker) → the run
     counted, <home>/runner gone, a new runner minted
  E  yield: memory pressure ⇒ paused, nothing minted; the idle runner taken down
     and deregistered when pressure arrives; back to idle when it goes; a full
     heavy-slot table ⇒ paused heavy
  F  the gate: a pull_request, another branch, another workflow, another repo, a
     missing context — refused (exit 1, no step runs); the train's push runs
  G  an admin login is refused (error, nothing minted); SIGTERM takes the runner
     down, deregisters it and says off
"""
import base64
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest

BIN = os.path.dirname(os.path.abspath(__file__))
CI = os.path.join(BIN, "fleet-ci-runner.py")
SUP = os.path.join(BIN, "fleet-node-supervisor.py")
GATE = os.path.join(BIN, "fleet-ci-job-gate.sh")
_s = importlib.util.spec_from_file_location("fns", SUP)
fns = importlib.util.module_from_spec(_s)
_s.loader.exec_module(fns)

TOKEN = "github_pat_SELFTESTSECRET0123456789"
INST = "ghs_SELFTESTINSTALLATION0123"


def until(secs, fn, step=0.1):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return fn()


class FakeGitHub(object):
    """generate-jitconfig · runners DELETE · app access_tokens; every request kept."""

    def __init__(self):
        self.reqs = []
        self.n = 0
        gh = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, code, obj=None):
                b = json.dumps(obj).encode() if obj is not None else b""
                self.send_response(code)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def _do(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(n) if n else b""
                gh.reqs.append({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization", ""),
                                "body": json.loads(body) if body else None})
                if self.command == "POST" and self.path.endswith("/generate-jitconfig"):
                    gh.n += 1
                    return self._reply(201, {"runner": {"id": 1000 + gh.n},
                                             "encoded_jit_config": "JITCONFIG-%d" % gh.n})
                if self.command == "POST" and "/access_tokens" in self.path:
                    return self._reply(201, {"token": INST, "expires_at": time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600))})
                if self.command == "DELETE":
                    return self._reply(204)
                return self._reply(404, {"message": "no"})

            do_POST = do_DELETE = do_GET = _do

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def jits(self):
        return [r for r in self.reqs if r["path"].endswith("/generate-jitconfig")]

    def deletes(self):
        return [r for r in self.reqs if r["method"] == "DELETE"]

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


# The fake runner: records what it was handed, waits for `go`, then — like the
# real one — runs the job-started hook and the job's step only when the hook
# says yes, the step as a child named Runner.Worker; then exits (one job).
RUN_SH = r"""#!/bin/bash
env > "$HOME/seen.env"
ps -o nice= -p $$ | tr -d ' ' > "$HOME/seen.nice"
pwd > "$HOME/seen.pwd"
while [ ! -e "$HOME/go" ]; do sleep 0.1; done
. "$HOME/go"   # the job's GITHUB_* context
rm -f "$HOME/go"
if "$ACTIONS_RUNNER_HOOK_JOB_STARTED" > "$HOME/hook.out" 2>&1; then
  /bin/sh -c 'sleep 1.5; : Runner.Worker'
  touch "$HOME/step-ran"
else
  touch "$HOME/step-refused"
fi
exit 0
"""


def fake_archive(path):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, body, mode in (("run.sh", RUN_SH, 0o755), ("bin/Runner.Listener", "#!/bin/sh\n", 0o755)):
            b = body.encode()
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode = len(b), mode
            t.addfile(ti, io.BytesIO(b))
    with open(path, "wb") as f:
        f.write(buf.getvalue())
    return hashlib.sha256(buf.getvalue()).hexdigest()


def plat():
    import platform
    m = platform.machine().lower()
    return "%s-%s" % (platform.system().lower(), {"x86_64": "amd64", "aarch64": "arm64"}.get(m, m))


class Box(object):
    """One sandbox machine: state / log / tools dirs, a fake login, a ci.env."""

    def __init__(self, groups=()):
        self.d = tempfile.mkdtemp(prefix="fci.")
        self.gh = FakeGitHub()
        self.home = os.path.join(self.d, "Users", "fleet-ci")
        os.makedirs(self.home)
        self.state = os.path.join(self.d, "db")
        os.makedirs(self.state)
        arc = os.path.join(self.d, "runner.tgz")
        self.sha = fake_archive(arc)
        self.lock = os.path.join(self.d, "ci-runner.lock")
        self.pin(self.sha, "file://" + arc)
        passwd = os.path.join(self.d, "passwd.json")
        with open(passwd, "w") as f:
            json.dump({"fleet-ci": {"uid": os.getuid(), "gid": os.getgid(), "home": self.home,
                                    "groups": list(groups)}}, f)
        self.pressure = os.path.join(self.d, "pressure")
        self.set_pressure(1)
        self.heavy = os.path.join(self.d, "heavy")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_", "CCQUOTA_"))}
        self.env.update({
            "FLEET_NODE_TEST": "1", "FLEET_NODE_STATE": self.state,
            "FLEET_NODE_LOG": os.path.join(self.d, "log"), "FLEET_NODE_ROOT": os.path.join(self.d, "root"),
            "FLEET_NODE_RUNTIME": os.path.join(self.d, "root", "current"),
            "FLEET_NODE_PASSWD": passwd, "FLEET_CI_API": self.gh.url, "FLEET_CI_LOCK": self.lock,
            "FLEET_CI_PRESSURE": "@" + self.pressure, "FLEET_CI_MEM": "64000 128000",
            "FLEET_CI_LOAD_MAX": "1000", "FLEET_CI_EVERY": "0.3", "FLEET_HEAVY_DIR": self.heavy,
            "GH_TOKEN": "gh-should-never-reach", "CCQUOTA_TOKEN": "cq-should-never-reach",
            "FLEET_CONF_DIR": "/should/never/reach"})
        self.proc = None

    def pin(self, sha, url):
        with open(self.lock, "w") as f:
            f.write("# test\n%s  %s  %s\n" % (plat(), sha, url))

    def set_pressure(self, n):
        with open(self.pressure, "w") as f:
            f.write(str(n))

    def ci_env(self, text):
        p = os.path.join(self.state, "ci.env")
        with open(p, "w") as f:
            f.write(text)
        os.chmod(p, 0o600)

    def book(self):
        return fns.read_json(os.path.join(self.state, "ci-runner.json"), {}) or {}

    def wait_state(self, st, secs=15):
        return until(secs, lambda: self.book().get("state") == st)

    def start(self, **kw):
        e = dict(self.env, **kw)
        self.proc = subprocess.Popen([sys.executable, CI, "loop"], env=e, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        return self.proc

    def go(self, **ctx):
        base = {"GITHUB_REPOSITORY": "verkyyi/claude-fleet", "GITHUB_EVENT_NAME": "push",
                "GITHUB_REF": "refs/heads/master",
                "GITHUB_WORKFLOW_REF": "verkyyi/claude-fleet/.github/workflows/release-train.yml@refs/heads/master"}
        base.update(ctx)
        with open(os.path.join(self.home, "go"), "w") as f:
            f.write("".join("export %s=%s\n" % (k, json.dumps(v)) for k, v in base.items()))

    def stop(self):
        out = ""
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                out = self.proc.communicate(timeout=30)[0].decode("utf-8", "replace")
            except subprocess.TimeoutExpired:
                self.proc.kill()
        elif self.proc:
            out = self.proc.communicate()[0].decode("utf-8", "replace")
        return out

    def close(self):
        self.stop()
        self.gh.close()
        shutil.rmtree(self.d, ignore_errors=True)

    def status(self, *a):
        return subprocess.run([sys.executable, CI, "status"] + list(a), env=self.env,
                              capture_output=True, text=True, timeout=30)


class T(unittest.TestCase):
    def setUp(self):
        self.box = Box()

    def tearDown(self):
        self.box.close()

    # A ---------------------------------------------------------------------------
    def test_a_off_adds_nothing(self):
        b = self.box
        old = dict(os.environ)
        os.environ.update({k: v for k, v in b.env.items() if k.startswith("FLEET_NODE_")})
        try:
            p = fns.Paths()
            sup = fns.Supervisor(p, {"children": [], "tasks": [], "account": []})
            self.assertNotIn("ci-runner", [c["name"] for c in sup.all_children()])
            sup.ensure_dirs()
            sup.save(force=True)
            self.assertNotIn("ci_runner", fns.read_json(p.state_file, {}))
            self.assertFalse(any(l.startswith("ci-runner") for l in fns.status_lines(p, sup.table, {})[1]))
            self.assertNotIn("fleet-ci", fns.tenant_logins(p))
            self.assertEqual(b.status("--check").returncode, 2)
            # on: the child, the word, the line, the tenant
            b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
            child = [c for c in sup.all_children() if c["name"] == "ci-runner"]
            self.assertEqual(len(child), 1)
            self.assertTrue(child[0]["cmd"][-2].endswith("bin/fleet-ci-runner.py"))
            self.assertEqual(child[0]["requires"], [fns.ci_env_path(p)])
            sup.save(force=True)
            self.assertEqual(fns.read_json(p.state_file, {})["ci_runner"]["state"], "off")
            fns.write_json(fns.ci_book_path(p), {"state": "paused", "why": "load: 0.90/core > 0.75",
                                                 "at": time.time(), "login": "fleet-ci",
                                                 "runs": {"total": 2, "failed": 1}})
            sup.save(force=True)
            self.assertEqual(fns.read_json(p.state_file, {})["ci_runner"]["state"], "paused")
            line = [l for l in fns.status_lines(p, sup.table, {})[1] if l.startswith("ci-runner")]
            self.assertTrue(line and "paused — load" in line[0] and "runs 2 (1 failed)" in line[0], line)
            r = b.status("--check")
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("paused", r.stdout)
            self.assertIn("fleet-ci", fns.tenant_logins(p))
            # stale ⇒ off ⇒ WARN
            fns.write_json(fns.ci_book_path(p), {"state": "idle", "at": time.time() - 999})
            self.assertEqual(fns.ci_summary(p)["state"], "off")
            self.assertEqual(b.status("--check").returncode, 1)
        finally:
            os.environ.clear()
            os.environ.update(old)

    # B ---------------------------------------------------------------------------
    def test_b_config(self):
        b = self.box
        b.ci_env("FLEET_CI_REPO=verkyyi/claude-fleet\n")
        b.start()
        self.assertTrue(b.wait_state("error"))
        self.assertIn("neither a GitHub App", b.book().get("why", ""))
        b.stop()
        b.ci_env("FLEET_CI_APP_ID=12\n")
        b.start()
        self.assertTrue(until(10, lambda: "not all of" in (b.book().get("why") or "")))
        b.stop()
        b.ci_env("FLEET_CI_TOKEN=%s\nFLEET_CI_RUNNERS=0\n" % TOKEN)
        b.start()
        self.assertTrue(b.wait_state("paused"))
        self.assertEqual(b.book()["why"], "FLEET_CI_RUNNERS=0")
        time.sleep(1)
        self.assertEqual(b.gh.jits(), [])

    # C ---------------------------------------------------------------------------
    def test_c_app(self):
        b = self.box
        key = os.path.join(b.d, "app.pem")
        pub = os.path.join(b.d, "app.pub")
        subprocess.check_call(["openssl", "genrsa", "-out", key, "2048"], stderr=subprocess.DEVNULL)
        subprocess.check_call(["openssl", "rsa", "-in", key, "-pubout", "-out", pub], stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
        old = dict(os.environ)
        os.environ.update(b.env)
        try:
            spec = importlib.util.spec_from_file_location("fci", CI)
            fci = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fci)
            c = fci.Cfg()
            c.app_id, c.key_file = "4242", key
            jwt = fci.app_jwt(c)
        finally:
            os.environ.clear()
            os.environ.update(old)
        h, body, sig = jwt.split(".")
        pad = lambda s: base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        self.assertEqual(json.loads(pad(h)), {"alg": "RS256", "typ": "JWT"})
        claims = json.loads(pad(body))
        self.assertEqual(claims["iss"], "4242")
        self.assertLessEqual(claims["exp"] - claims["iat"], 600)
        sf = os.path.join(b.d, "sig")
        with open(sf, "wb") as f:
            f.write(pad(sig))
        v = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sf],
                           input=("%s.%s" % (h, body)).encode(), capture_output=True)
        self.assertEqual(v.returncode, 0, v.stdout + v.stderr)
        # the loop: the App buys an installation token, the runner calls carry it
        b.ci_env("FLEET_CI_APP_ID=4242\nFLEET_CI_APP_INSTALLATION_ID=77\nFLEET_CI_APP_KEY_FILE=%s\n" % key)
        b.start()
        self.assertTrue(b.wait_state("idle"), b.book())
        toks = [r for r in b.gh.reqs if "/access_tokens" in r["path"]]
        self.assertEqual(toks[0]["path"], "/app/installations/77/access_tokens")
        self.assertTrue(toks[0]["auth"].startswith("Bearer ey"))
        self.assertEqual(b.gh.jits()[0]["auth"], "Bearer " + INST)
        out = b.stop()
        self.assertNotIn(INST, out)
        self.assertNotIn(INST, json.dumps(b.book()))
        self.assertNotIn(INST, open(os.path.join(b.home, "seen.env")).read() if os.path.exists(
            os.path.join(b.home, "seen.env")) else "")

    # D ---------------------------------------------------------------------------
    def test_d_one_run(self):
        b = self.box
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        b.pin("0" * 64, "file://" + os.path.join(b.d, "runner.tgz"))
        b.start()
        self.assertTrue(until(10, lambda: "not unpacked" in (b.book().get("why") or "")), b.book())
        self.assertEqual(b.gh.jits(), [])
        b.stop()
        b.pin(b.sha, "file://" + os.path.join(b.d, "runner.tgz"))
        b.start()
        self.assertTrue(b.wait_state("idle"), b.book())
        self.assertTrue(until(10, lambda: os.path.exists(os.path.join(b.home, "seen.env"))))
        jit = b.gh.jits()[0]
        self.assertEqual(jit["auth"], "Bearer " + TOKEN)
        self.assertEqual(jit["path"], "/repos/verkyyi/claude-fleet/actions/runners/generate-jitconfig")
        self.assertEqual(jit["body"]["labels"][0], "self-hosted")
        self.assertEqual(jit["body"]["labels"][-1], "fleet-ci")
        self.assertIn(jit["body"]["labels"][1], ("macOS", "Linux"))
        self.assertEqual(jit["body"]["runner_group_id"], 1)
        envs = dict(l.split("=", 1) for l in open(os.path.join(b.home, "seen.env")).read().splitlines() if "=" in l)
        self.assertEqual(envs["ACTIONS_RUNNER_INPUT_JITCONFIG"], "JITCONFIG-1")
        self.assertEqual(envs["ACTIONS_RUNNER_HOOK_JOB_STARTED"], GATE)
        self.assertEqual(envs["HOME"], b.home)
        self.assertEqual(envs["CI_GATE_WORKFLOWS"], "release-train.yml")
        leaked = [k for k in envs if k.startswith(("FLEET_", "CCQUOTA_")) or k in ("GH_TOKEN", "GITHUB_TOKEN")]
        self.assertEqual(leaked, [])
        self.assertNotIn(TOKEN, open(os.path.join(b.home, "seen.env")).read())
        self.assertEqual(open(os.path.join(b.home, "seen.nice")).read().strip(), "10")
        self.assertEqual(open(os.path.join(b.home, "seen.pwd")).read().strip(),
                         os.path.realpath(os.path.join(b.home, "runner")))
        tools = os.path.join(b.d, "root", "tools", "actions-runner", b.sha)
        self.assertTrue(os.path.exists(os.path.join(tools, ".ok")))
        os.unlink(os.path.join(b.home, "seen.env"))
        b.go()
        self.assertTrue(b.wait_state("busy"), b.book())
        self.assertTrue(until(15, lambda: (b.book().get("runs") or {}).get("total") == 1), b.book())
        self.assertTrue(os.path.exists(os.path.join(b.home, "step-ran")))
        self.assertTrue(until(10, lambda: len(b.gh.jits()) == 2), b.gh.reqs)
        self.assertTrue(b.wait_state("idle"))
        self.assertEqual(b.book()["last"]["rc"], 0)
        out = b.stop()
        self.assertEqual(b.book()["state"], "off")
        self.assertFalse(os.path.exists(os.path.join(b.home, "runner")))
        self.assertTrue(b.gh.deletes(), "the idle runner was not deregistered at stop")
        for blob in (out, json.dumps(b.book())) + tuple(
                open(os.path.join(dp, f), errors="replace").read()
                for dp, _, fs in os.walk(os.path.join(b.d, "log")) for f in fs):
            self.assertNotIn(TOKEN, blob)
            self.assertNotIn("JITCONFIG-", blob)

    # E ---------------------------------------------------------------------------
    def test_e_yield(self):
        b = self.box
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        b.set_pressure(2)
        b.start()
        self.assertTrue(b.wait_state("paused"))
        self.assertEqual(b.book()["why"], "memory: pressure warn")
        time.sleep(1)
        self.assertEqual(b.gh.jits(), [])
        b.set_pressure(1)
        self.assertTrue(b.wait_state("idle"), b.book())
        b.set_pressure(4)
        self.assertTrue(b.wait_state("paused"), b.book())
        self.assertIn("critical", b.book()["why"])
        self.assertTrue(until(10, lambda: b.gh.deletes()), "the idle runner was not deregistered")
        self.assertFalse(os.path.exists(os.path.join(b.home, "runner")))
        b.set_pressure(1)
        self.assertTrue(b.wait_state("idle"))
        b.stop()
        # admission: too little free memory
        b.start(FLEET_CI_MEM="5000 16384")
        self.assertTrue(b.wait_state("paused"))
        self.assertTrue(b.book()["why"].startswith("admission:"), b.book())
        b.stop()

    def test_e_heavy(self):
        b = self.box
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        hold = subprocess.Popen(["/bin/bash", os.path.join(BIN, "fleet-heavy.sh"), "--slots", "1", "--",
                                 "sleep", "30"], env=dict(b.env, FLEET_HEAVY_SLOTS="1"))
        try:
            self.assertTrue(until(10, lambda: "1/1 held" in subprocess.run(
                ["/bin/bash", os.path.join(BIN, "fleet-heavy.sh"), "--status"],
                env=dict(b.env, FLEET_HEAVY_SLOTS="1"), capture_output=True, text=True).stdout))
            b.start(FLEET_HEAVY_SLOTS="1")
            self.assertTrue(b.wait_state("paused"), b.book())
            self.assertTrue(b.book()["why"].startswith("heavy: 1/1"), b.book())
        finally:
            hold.kill()
            hold.wait()

    # F ---------------------------------------------------------------------------
    def test_f_gate(self):
        good = {"CI_GATE_REPO": "o/r", "CI_GATE_WORKFLOWS": "release-train.yml",
                "GITHUB_REPOSITORY": "o/r", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/master",
                "GITHUB_WORKFLOW_REF": "o/r/.github/workflows/release-train.yml@refs/heads/master"}

        def gate(**over):
            e = {"PATH": "/usr/bin:/bin"}
            e.update(good)
            e.update(over)
            e = {k: v for k, v in e.items() if v is not None}
            return subprocess.run(["/bin/bash", GATE], env=e, capture_output=True, text=True).returncode

        self.assertEqual(gate(), 0)
        self.assertEqual(gate(GITHUB_EVENT_NAME="workflow_dispatch"), 0)
        for bad in ({"GITHUB_EVENT_NAME": "pull_request"}, {"GITHUB_EVENT_NAME": "pull_request_target"},
                    {"GITHUB_HEAD_REF": "evil"}, {"GITHUB_REF": "refs/heads/evil"},
                    {"GITHUB_REF": "refs/pull/1/merge"}, {"GITHUB_REPOSITORY": "x/r"},
                    {"GITHUB_WORKFLOW_REF": "o/r/.github/workflows/selftests.yml@refs/heads/master"},
                    {"GITHUB_WORKFLOW_REF": None}, {"GITHUB_EVENT_NAME": None},
                    {"CI_GATE_REPO": None}, {"CI_GATE_WORKFLOWS": None}):
            self.assertEqual(gate(**bad), 1, bad)

    # G ---------------------------------------------------------------------------
    def test_g_admin_refused(self):
        self.box.close()
        self.box = b = Box(groups=("staff", "admin"))
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        b.start()
        self.assertTrue(b.wait_state("error"))
        self.assertIn("only an admin may", b.book()["why"])
        time.sleep(1)
        self.assertEqual(b.gh.jits(), [])


# --------------------------------------------------------------- drills ----------
def drill_pr_code():
    """A pull_request job aimed at fleet-ci: the runner gets it, its steps never run."""
    b = Box()
    try:
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        b.start()
        if not b.wait_state("idle"):
            return "no runner came up: %s" % b.book()
        b.go(GITHUB_EVENT_NAME="pull_request", GITHUB_HEAD_REF="contributor-branch",
             GITHUB_REF="refs/pull/7/merge",
             GITHUB_WORKFLOW_REF="verkyyi/claude-fleet/.github/workflows/release-train.yml@refs/pull/7/merge")
        if not until(15, lambda: os.path.exists(os.path.join(b.home, "step-refused"))
                     or os.path.exists(os.path.join(b.home, "step-ran"))):
            return "the fake runner never took the job"
        if os.path.exists(os.path.join(b.home, "step-ran")):
            return "a pull_request job's step RAN on the machine"
        said = open(os.path.join(b.home, "hook.out")).read()
        if "refused" not in said or "pull request" not in said:
            return "refused without saying why: %r" % said
        return ""
    finally:
        b.close()


def drill_hogs(wait_secs, already=False):
    """Under load (the caller runs this inside fleet-loadgen.sh): no runner minted,
    the doctor's check says paused. `already`: the box was too busy for the load
    generator (its exit 3) — the load already there is the load."""
    b = Box()
    try:
        n = os.cpu_count() or 1
        base = os.getloadavg()[0]
        limit = (base * 0.8 if already else base + 0.25) / n
        if not until(wait_secs, lambda: os.getloadavg()[0] / n > limit, step=1):
            return "the load never rose (%.2f → %.2f, limit %.2f/core)" % (base, os.getloadavg()[0], limit)
        b.ci_env("FLEET_CI_TOKEN=%s\n" % TOKEN)
        b.start(FLEET_CI_LOAD_MAX="%.4f" % limit)
        if not b.wait_state("paused"):
            return "no pause under load: %s" % b.book()
        if not (b.book().get("why") or "").startswith("load:"):
            return "paused, but not for load: %s" % b.book()
        time.sleep(1)
        if b.gh.jits():
            return "a runner was minted under load"
        r = b.status("--check")
        if r.returncode != 0 or "paused" not in r.stdout or "load" not in r.stdout:
            return "the doctor's check did not say paused (rc %d): %s" % (r.returncode, r.stdout)
        print("SAID %s" % r.stdout.strip())
        return ""
    finally:
        b.close()


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "drill":
        why = (drill_pr_code() if sys.argv[2] == "pr-code"
               else drill_hogs(float(sys.argv[3]) if len(sys.argv) > 3 else 60, sys.argv[2] == "hogs-already"))
        print("FAIL %s" % why if why else "OK")
        sys.exit(1 if why else 0)
    unittest.main(verbosity=2)
