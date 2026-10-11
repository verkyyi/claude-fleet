#!/usr/bin/env python3
"""fleet-ci-runner.py — the machine's one test runner (claude-fleet#3144, EPIC #3139 C5).

A GitHub Actions runner on a managed Mac, for the MERGED TRAIN only, that gives
way to the sessions working on the same machine. The machine daemon
(bin/fleet-node-supervisor.py) runs `loop` as its `ci-runner` child, as root, and
only while <state>/ci.env exists — no ci.env, nothing runs and nothing changes.

Every FLEET_CI_EVERY seconds (20) the loop:

  1. reads ci.env (root's, 0600 — anything else is refused): a GitHub App that may
     manage this repo's runners and nothing else (Administration: write) — its id,
     installation id and private key file (root's 0600); each beat that mints signs
     a JWT with `openssl dgst -sha256 -sign` and trades it for an hour's
     installation token — or, as the fallback, FLEET_CI_TOKEN, a fine-grained
     token with the same one permission. Key, JWT and tokens live in this
     process's memory only — never an argv, a file, a log or the runner's
     environment;
  2. with no runner up, asks whether the machine has room for one (yield): the
     kernel's memory pressure at warn or worse · free memory under a floor plus
     one session plus the runner (the admission sum) · load per core over
     FLEET_CI_LOAD_MAX · every heavy slot (bin/fleet-heavy.sh) held or a run
     queued for one. Any of them ⇒ `paused:<why>`, nothing minted, ask again next
     beat;
  3. makes sure the test login exists (FLEET_CI_LOGIN, fleet-ci): created once by
     sysadminctl, NOT an admin, shell /usr/bin/false, home 0700 — and refuses to
     run while the login can do what an admin can (the tenant rule, #2842);
  4. makes sure the runner (conf/ci-runner.lock: version + SHA-256 per platform)
     is unpacked in the root runtime's tools cache, <root>/tools/actions-runner/<sha>;
  5. mints ONE just-in-time runner config from GitHub (generate-jitconfig: labels
     self-hosted · macOS · ARM64 · fleet-ci, ephemeral by nature — one job, then gone),
     copies the cached runner into a fresh <home>/runner owned by the login, and
     starts `run.sh` demoted to the login, `nice 10`, its environment built from
     nothing (no FLEET_*, no CCQUOTA_*, no gh token; the JIT config rides
     ACTIONS_RUNNER_INPUT_JITCONFIG, never argv), with
     ACTIONS_RUNNER_HOOK_JOB_STARTED = bin/fleet-ci-job-gate.sh: a job that is
     not the train's (a pull_request, another branch, another workflow) is
     refused before any of its steps runs;
  6. while it waits for a job (`idle`) and the machine gets tight, takes it down
     and deregisters it; while a job runs (`busy`, a Runner.Worker under it) lets
     it finish (FLEET_CI_MAX_SECS caps it); when it exits, empties <home>/runner
     and kills whatever the login still runs. One runner at a time
     (FLEET_CI_RUNNERS: 0 = paused, otherwise 1).

Its word — state idle | busy | paused | error | off, why, runs, last — is
<state>/ci-runner.json (0644, no secret), which the daemon copies into
state.json `ci_runner` (status line, the node program's heartbeat → the hub's
GET /v1/fleet/ci-runners) and `status --check` reads for the doctor's
`ci-runner` row.

Usage:
  fleet-ci-runner.py loop                 the daemon's child (root)
  fleet-ci-runner.py status [--check|--json]
                                          the word; --check: 0 ok (idle / busy /
                                          paused) · 1 WARN (error / off) · 2 no ci.env

ci.env keys (each also from the environment, which wins — a test's seam):
  FLEET_CI_APP_ID · FLEET_CI_APP_INSTALLATION_ID · FLEET_CI_APP_KEY_FILE
                        the GitHub App (preferred; the key file root's 0600)
  FLEET_CI_TOKEN        a fine-grained token (the fallback; one of the two required)
  FLEET_CI_REPO         owner/name (default verkyyi/claude-fleet)
  FLEET_CI_LOGIN        the test login (fleet-ci)
  FLEET_CI_RUNNERS      0 = paused · 1 (default; more is 1)
  FLEET_CI_WORKFLOWS    the workflow files a job may come from (release-train.yml)
  FLEET_CI_LABELS       extra labels (space separated) beside self-hosted · <OS> · <arch> · fleet-ci
  FLEET_CI_EVERY        seconds between beats (20)
  FLEET_CI_MAX_SECS     a job's cap (10800) · FLEET_CI_IDLE_SECS an idle runner's (3600)
  FLEET_CI_LOAD_MAX     load per core above which it yields (0.75)
  FLEET_CI_FREE_PCT     the floor, % of RAM never handed out (10, at least 2048 MB)
  FLEET_CI_SESSION_MB   one more session's room kept free (1536)
  FLEET_CI_RUNNER_MB    what a test run takes (4096)
Seams (tests): FLEET_CI_API (GitHub's API base), FLEET_CI_LOCK, FLEET_CI_PRESSURE,
FLEET_CI_MEM ("<avail_mb> <total_mb>"), FLEET_CI_WORKER_PAT, FLEET_CI_SYSADMINCTL.
"""
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("fleet_node_supervisor", os.path.join(HERE, "fleet-node-supervisor.py"))
sup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sup)

STATES = ("idle", "busy", "paused", "error", "off")
GATE = os.path.join(HERE, "fleet-ci-job-gate.sh")


def now():
    return time.time()


def log(msg):
    sys.stderr.write("%s ci-runner: %s\n" % (sup.iso(now()), msg))
    sys.stderr.flush()


def test_mode():
    return os.environ.get("FLEET_NODE_TEST") == "1"


# --------------------------------------------------------------- config -------
class Cfg(object):
    pass


def _num(v, default, lo=None):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return default
    return default if lo is not None and x < lo else x


def read_cfg(paths):
    """(Cfg, "") or (None, why). ci.env is root's 0600 and parsed, never sourced."""
    path = sup.ci_env_path(paths)
    try:
        st = os.lstat(path)
    except OSError:
        return None, "no ci.env"
    if not test_mode() and (st.st_uid != 0 or st.st_mode & 0o077 or not os.path.isfile(path)):
        return None, "ci.env must be a root-owned 0600 file (%s)" % path
    f = sup._env_file(path, 0) or {}

    def get(k, d=""):
        return os.environ.get(k) or f.get(k) or d

    c = Cfg()
    # a GitHub App first (its key file root's 0600), the fine-grained token second
    c.app_id, c.inst_id = get("FLEET_CI_APP_ID"), get("FLEET_CI_APP_INSTALLATION_ID")
    c.key_file, c.token = get("FLEET_CI_APP_KEY_FILE"), get("FLEET_CI_TOKEN")
    if c.app_id or c.inst_id or c.key_file:
        if not (c.app_id.isdigit() and c.inst_id.isdigit() and c.key_file):
            return None, "ci.env names a GitHub App but not all of FLEET_CI_APP_ID / _INSTALLATION_ID / _KEY_FILE"
        try:
            kst = os.stat(c.key_file)
        except OSError as e:
            return None, "FLEET_CI_APP_KEY_FILE: %s" % e
        if not test_mode() and (kst.st_uid != 0 or kst.st_mode & 0o077):
            return None, "FLEET_CI_APP_KEY_FILE must be a root-owned 0600 file (%s)" % c.key_file
        c.token = ""
    elif not c.token:
        return None, "ci.env has neither a GitHub App (FLEET_CI_APP_*) nor FLEET_CI_TOKEN"
    c.repo = get("FLEET_CI_REPO", "verkyyi/claude-fleet")
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", c.repo):
        return None, "FLEET_CI_REPO %r is not owner/name" % c.repo
    c.login = get("FLEET_CI_LOGIN", sup.CI_DEFAULT_LOGIN)
    if not sup.LOGIN_RE.match(c.login):
        return None, "FLEET_CI_LOGIN %r is not a login name" % c.login
    c.runners = min(int(_num(get("FLEET_CI_RUNNERS", "1"), 1, 0)), 1)
    c.workflows = get("FLEET_CI_WORKFLOWS", "release-train.yml").split()
    base = ["self-hosted", "macOS" if sys.platform == "darwin" else "Linux",
            {"arm64": "ARM64", "aarch64": "ARM64"}.get(platform.machine().lower(), "X64"), "fleet-ci"]
    c.labels = base + [l for l in get("FLEET_CI_LABELS").split() if l not in base]
    c.every = _num(get("FLEET_CI_EVERY", "20"), 20, 0.2)
    c.max_secs = _num(get("FLEET_CI_MAX_SECS", "10800"), 10800, 1)
    c.idle_secs = _num(get("FLEET_CI_IDLE_SECS", "3600"), 3600, 1)
    c.load_max = _num(get("FLEET_CI_LOAD_MAX", "0.75"), 0.75, 0)
    c.free_pct = _num(get("FLEET_CI_FREE_PCT", "10"), 10, 0)
    c.session_mb = _num(get("FLEET_CI_SESSION_MB", "1536"), 1536, 0)
    c.runner_mb = _num(get("FLEET_CI_RUNNER_MB", "4096"), 4096, 0)
    c.api = get("FLEET_CI_API", "https://api.github.com").rstrip("/")  # dist-ok: GitHub's Actions API — the runner is GitHub's, not the fleet's code
    return c, ""


# --------------------------------------------------------------- yield --------
def _seam(name):
    """A test seam's value; `@<path>` reads it from a file (changed mid-run)."""
    v = os.environ.get(name)
    if v and v.startswith("@"):
        try:
            with open(v[1:]) as fh:
                return fh.read().strip()
        except OSError:
            return None
    return v


def mem_reading():
    """(pressure 1|2|4, avail_mb, total_mb) — 1 / None when the platform will not say."""
    pr = _seam("FLEET_CI_PRESSURE")
    mem = _seam("FLEET_CI_MEM")
    pressure, avail, total = 1, None, None
    if pr:
        pressure = int(_num(pr, 1))
    elif sys.platform == "darwin":
        try:
            pressure = int(subprocess.check_output(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                                                   stderr=subprocess.DEVNULL, timeout=5).strip() or 1)
        except (OSError, subprocess.SubprocessError, ValueError):
            pressure = 1
    if mem:
        a, _, t = mem.partition(" ")
        return pressure, _num(a, None), _num(t, None)
    if sys.platform == "darwin":
        try:
            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=5).strip()) / 1048576.0
            out = subprocess.check_output(["vm_stat"], timeout=5).decode("utf-8", "replace")
            page = int(re.search(r"page size of (\d+)", out).group(1))
            pages = 0
            for k in ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"):
                m = re.search(r"^%s:\s+(\d+)" % k, out, re.M)
                pages += int(m.group(1)) if m else 0
            avail = pages * page / 1048576.0
        except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
            pass
    else:
        try:
            with open("/proc/meminfo") as fh:
                mi = dict((l.split(":")[0], l.split()[1]) for l in fh if ":" in l)
            total, avail = int(mi["MemTotal"]) / 1024.0, int(mi["MemAvailable"]) / 1024.0
        except (OSError, KeyError, ValueError, IndexError):
            pass
    return pressure, avail, total


def heavy_reading():
    """(held, slots, waiting) off fleet-heavy.sh --status, or None."""
    try:
        out = subprocess.check_output(["/bin/bash", os.path.join(HERE, "fleet-heavy.sh"), "--status"],
                                      stderr=subprocess.DEVNULL, timeout=20).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"heavy: (\d+)/(\d+) held · (\d+) waiting", out)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


def tight(c):
    """Why the machine has no room for a test run now, or ""."""
    pressure, avail, total = mem_reading()
    if pressure >= 2:
        return "memory: pressure %s" % {2: "warn", 4: "critical"}.get(pressure, pressure)
    if avail is not None and total:
        floor = max(total * c.free_pct / 100.0, 2048)
        need = floor + c.session_mb + c.runner_mb
        if avail < need:
            return "admission: %d MB free, a run needs %d (floor %d + a session %d + the run %d)" % (
                avail, need, floor, c.session_mb, c.runner_mb)
    try:
        l1, n = os.getloadavg()[0], os.cpu_count() or 1
        if l1 / n > c.load_max:
            return "load: %.2f/core > %.2f" % (l1 / n, c.load_max)
    except OSError:
        pass
    h = heavy_reading()
    if h and (h[0] >= h[1] or h[2] > 0):
        return "heavy: %d/%d slots held, %d waiting" % h
    return ""


# --------------------------------------------------------------- the login ----
def ensure_login(c):
    """((uid, gid, home), "") or (None, why). Never an admin."""
    ident = sup.account_ident(c.login)
    if ident is None:
        if test_mode() or os.geteuid() != 0:
            return None, "no login %s (the daemon creates it as root)" % c.login
        if sys.platform == "darwin":
            cmds = [[os.environ.get("FLEET_CI_SYSADMINCTL", "/usr/sbin/sysadminctl"), "-addUser", c.login,
                     "-fullName", "fleet CI", "-shell", "/usr/bin/false"],
                    ["/usr/sbin/createhomedir", "-c", "-u", c.login]]
        else:
            cmds = [["useradd", "-m", "-s", "/usr/sbin/nologin", "-c", "fleet CI", c.login]]
        for cmd in cmds:
            r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
            log("%s → rc %d %s" % (" ".join(cmd[:3]), r.returncode, r.stdout.decode("utf-8", "replace")[-200:].strip()))
        ident = sup.account_ident(c.login)
        if ident is None:
            return None, "could not create login %s (see the log)" % c.login
        try:
            os.chmod(ident[2], 0o700)
        except OSError:
            pass
        if sys.platform == "darwin":
            subprocess.run(["dscl", ".", "-create", "/Users/" + c.login, "IsHidden", "1"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        log("created login %s uid %d" % (c.login, ident[0]))
    why, _ = sup.tenant_privileges(c.login)
    if why:
        return None, "login %s can do what only an admin may (%s) — refused" % (c.login, ", ".join(why))
    return ident, ""


# --------------------------------------------------------------- the runner ---
def platform_id():
    osn = platform.system().lower()
    m = platform.machine().lower()
    return "%s-%s" % (osn, {"x86_64": "amd64", "aarch64": "arm64"}.get(m, m))


def lock_entry():
    """(sha256, url) for this platform, or (None, why)."""
    path = os.environ.get("FLEET_CI_LOCK") or os.path.join(HERE, "..", "conf", "ci-runner.lock")
    plat = platform_id()
    try:
        with open(path) as fh:
            for line in fh:
                f = line.split()
                if len(f) == 3 and f[0] == plat and re.match(r"^[0-9a-f]{64}$", f[1]):
                    return f[1], f[2]
    except OSError as e:
        return None, "%s: %s" % (path, e)
    return None, "%s has no line for %s" % (path, plat)


def tools_root():
    return os.path.join(sup.env("FLEET_NODE_ROOT", sup.DEFAULT_ROOT), "tools", "actions-runner")


def runner_tree():
    """(the cached runner's directory, "") or (None, why). Fetched once per pin,
    checked against its SHA-256 before a byte is unpacked."""
    sha, url = lock_entry()
    if sha is None:
        return None, url
    d = os.path.join(tools_root(), sha)
    if os.path.exists(os.path.join(d, ".ok")):
        return d, ""
    os.makedirs(tools_root(), exist_ok=True)
    part = d + ".partial"
    shutil.rmtree(part, ignore_errors=True)
    os.makedirs(part)
    arc = os.path.join(part, ".archive")
    h = hashlib.sha256()
    try:
        with urllib.request.urlopen(url, timeout=300) as r, open(arc, "wb") as out:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                h.update(b)
                out.write(b)
    except (OSError, urllib.error.URLError) as e:
        shutil.rmtree(part, ignore_errors=True)
        return None, "fetching the runner (%s): %s" % (url, e)
    if h.hexdigest() != sha:
        shutil.rmtree(part, ignore_errors=True)
        return None, "the runner archive is %s, the lock pins %s — not unpacked" % (h.hexdigest()[:12], sha[:12])
    try:
        with tarfile.open(arc) as t:
            for m in t.getmembers():
                if m.name.startswith("/") or ".." in m.name.split("/") or m.isdev():
                    raise tarfile.TarError("unsafe member %r" % m.name)
            t.extractall(part)
    except (tarfile.TarError, OSError) as e:
        shutil.rmtree(part, ignore_errors=True)
        return None, "unpacking the runner: %s" % e
    os.unlink(arc)
    for top, dirs, files in os.walk(part):
        for n in dirs + files:
            p = os.path.join(top, n)
            if not os.path.islink(p):
                os.chmod(p, os.stat(p).st_mode & ~0o022)
    open(os.path.join(part, ".ok"), "w").close()
    shutil.rmtree(d, ignore_errors=True)
    os.rename(part, d)
    os.chmod(d, 0o755)
    log("runner %s unpacked at %s" % (sha[:12], d))
    return d, ""


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def app_jwt(c):
    """The App's RS256 JWT (iat −60 s, exp +9 min), signed by `openssl dgst
    -sha256 -sign` — macOS's python3 has no RSA of its own. The key stays in its
    file (only its path is an argv); the signing input goes in on stdin."""
    t = int(now())
    head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64url(json.dumps({"iat": t - 60, "exp": t + 540, "iss": c.app_id}, separators=(",", ":")).encode())
    msg = ("%s.%s" % (head, body)).encode()
    r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", c.key_file], input=msg,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if r.returncode != 0 or not r.stdout:
        raise OSError("openssl could not sign with the App key: %s" % r.stderr.decode("utf-8", "replace")[:160].strip())
    return "%s.%s" % (msg.decode(), b64url(r.stdout))


_INSTALL = {}   # (app, installation) -> (token, expires epoch): this process's memory only


def bearer(c):
    """What the API calls carry: the App's installation token (minted from a JWT,
    kept until 5 minutes before it expires), else the fine-grained token."""
    if not c.app_id:
        return c.token
    key = (c.app_id, c.inst_id)
    tok, exp = _INSTALL.get(key, ("", 0))
    if tok and now() < exp - 300:
        return tok
    code, js = _call(c.api, "POST", "/app/installations/%s/access_tokens" % c.inst_id, app_jwt(c))
    if code != 201 or not js.get("token"):
        raise OSError("GitHub refused the App installation token: HTTP %s %s" % (code, (js.get("message") or "")[:160]))
    try:
        exp = time.mktime(time.strptime(js.get("expires_at", ""), "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except ValueError:
        exp = now() + 3600
    _INSTALL[key] = (js["token"], exp)
    return js["token"]


def api(c, method, path, body=None):
    """(HTTP status, parsed JSON or {}) — the credential only ever in the header."""
    try:
        tok = bearer(c)
    except OSError as e:
        return 0, {"message": str(e)}
    return _call(c.api, method, path, tok, body)


def _call(base, method, path, tok, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers={
        "Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json",
        "User-Agent": "claude-fleet-ci-runner"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read() or b"{}")
        except ValueError:
            msg = {}
        return e.code, msg if isinstance(msg, dict) else {}
    except (OSError, urllib.error.URLError, ValueError) as e:
        return 0, {"message": str(e)}


def kill_login(ident):
    """Whatever the test login still runs: root only, never our own uid."""
    if ident and os.geteuid() == 0 and ident[0] not in (0, os.geteuid()) and not test_mode():
        subprocess.run(["pkill", "-KILL", "-u", str(ident[0])],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


def clone(src, dst):
    cmd = ["cp", "-cR", src, dst] if sys.platform == "darwin" else ["cp", "-a", src, dst]
    if subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        shutil.rmtree(dst, ignore_errors=True)
        subprocess.check_call(["cp", "-R", src, dst])


def chown_tree(top, uid, gid):
    if os.geteuid() != 0:
        return
    for d, dirs, files in os.walk(top):
        for n in [d] + [os.path.join(d, x) for x in dirs + files]:
            try:
                os.lchown(n, uid, gid)
            except OSError:
                pass


class Run(object):
    """One minted runner: its process, its GitHub id, when it started, whether it
    took a job."""

    def __init__(self, proc, runner_id, name, ident, rundir, logfile):
        self.proc, self.id, self.name, self.ident = proc, runner_id, name, ident
        self.rundir, self.logfile = rundir, logfile
        self.started = now()
        self.busy_since = None

    def busy(self):
        pat = os.environ.get("FLEET_CI_WORKER_PAT", "Runner.Worker")
        return any(pat in cmd for cmd in sup.descendant_cmds(self.proc.pid))

    def stop(self):
        for sig, wait in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                os.killpg(self.proc.pid, sig)
            except OSError:
                pass
            try:
                self.proc.wait(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                continue


class Loop(object):
    def __init__(self, paths):
        self.p = paths
        self.book_path = sup.ci_book_path(paths)
        old = sup.read_json(self.book_path, {}) or {}
        self.book = {"state": "off", "why": "starting", "since": now(), "at": now(),
                     "runs": old.get("runs") or {"total": 0, "failed": 0}, "last": old.get("last")}
        self.run = None
        self.ident = None
        self.next_try = 0
        self.fails = 0
        self.stopping = False

    # -- the word
    def say(self, state, why="", **kw):
        if state != self.book.get("state") or why != self.book.get("why"):
            if state != self.book.get("state"):
                self.book["since"] = now()
            log("%s%s" % (state, (" — " + why) if why else ""))
        self.book.update(state=state, why=why, at=now(), **kw)
        sup.write_json(self.book_path, self.book, 0o644)

    def backoff(self, why):
        self.fails += 1
        self.next_try = now() + min(60 * 2 ** (self.fails - 1), 900)
        self.say("error", why)

    # -- one runner
    def mint(self, c, ident, tree):
        uid, gid, home = ident
        rundir = os.path.join(home, "runner")
        shutil.rmtree(rundir, ignore_errors=True)
        clone(tree, rundir)
        for x in ("_work", "_diag", "tmp"):
            os.makedirs(os.path.join(rundir, x), exist_ok=True)
        os.chmod(rundir, 0o700)
        chown_tree(rundir, uid, gid)
        name = "fleet-ci-%s-%d" % (socket.gethostname().split(".")[0].lower(), int(now()))
        code, js = api(c, "POST", "/repos/%s/actions/runners/generate-jitconfig" % c.repo,
                       {"name": name, "runner_group_id": 1, "labels": c.labels, "work_folder": "_work"})
        jit = js.get("encoded_jit_config") if code == 201 else None
        if not jit:
            shutil.rmtree(rundir, ignore_errors=True)
            return None, "GitHub refused the runner config: HTTP %s %s" % (code, (js.get("message") or "")[:160])
        rid = (js.get("runner") or {}).get("id")
        env = {"HOME": home, "USER": c.login, "LOGNAME": c.login, "SHELL": "/bin/bash", "LANG": "en_US.UTF-8",
               "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
               "TMPDIR": os.path.join(rundir, "tmp"),
               "ACTIONS_RUNNER_INPUT_JITCONFIG": jit,
               "ACTIONS_RUNNER_HOOK_JOB_STARTED": GATE,
               "CI_GATE_REPO": c.repo, "CI_GATE_REF": "refs/heads/master",
               "CI_GATE_EVENTS": "push workflow_dispatch schedule",
               "CI_GATE_WORKFLOWS": " ".join(c.workflows)}
        logdir = os.path.join(self.p.log, "ci-runner")
        os.makedirs(logdir, exist_ok=True)
        os.chmod(logdir, 0o700)
        logfile = os.path.join(logdir, "%s.log" % name)
        fh = open(logfile, "ab")
        demote = sup.demote(c.login, uid, gid, rundir)

        def pre():
            # nice 10 itself, not +10: a parent already at a negative nice (a CI
            # runner's own service) would leave os.nice(10) at 0 (issue #3219)
            os.setpriority(os.PRIO_PROCESS, 0, 10)
            demote()

        try:
            proc = subprocess.Popen([os.path.join(rundir, "run.sh")], cwd=rundir, env=env,
                                    stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                                    start_new_session=True, close_fds=True, preexec_fn=pre)
        except OSError as e:
            fh.close()
            self.deregister(c, rid)
            shutil.rmtree(rundir, ignore_errors=True)
            return None, "starting the runner: %s" % e
        fh.close()
        log("runner %s (id %s) up pid %d — %s" % (name, rid, proc.pid, ", ".join(c.labels)))
        return Run(proc, rid, name, ident, rundir, logfile), ""

    def deregister(self, c, rid):
        if c is not None and rid:
            code, js = api(c, "DELETE", "/repos/%s/actions/runners/%s" % (c.repo, rid))
            if code not in (204, 404):
                log("could not deregister runner %s: HTTP %s %s" % (rid, code, js.get("message") or ""))

    def finish(self, c, rc, why=""):
        r, self.run = self.run, None
        took = r.busy_since is not None
        secs = int(now() - (r.busy_since or r.started))
        runs = self.book.setdefault("runs", {"total": 0, "failed": 0})
        if took:
            runs["total"] = (runs.get("total") or 0) + 1
            if rc:
                runs["failed"] = (runs.get("failed") or 0) + 1
            self.book["last"] = {"at": now(), "rc": rc, "secs": secs, "runner": r.name}
        if not took or why:
            self.deregister(c, r.id)
        shutil.rmtree(r.rundir, ignore_errors=True)
        kill_login(r.ident)
        log("runner %s ended rc=%s after %ss%s%s" % (r.name, rc, secs, " (a job)" if took else " (no job)",
                                                   (" — " + why) if why else ""))
        if not took and not why:
            # it ended without a job and not because we stopped it: GitHub refused
            # the config, the runner crashed — never mint again at once
            self.backoff("the runner exited rc=%s before any job (log %s)" % (rc, r.logfile))

    # -- one beat
    def step(self):
        c, err = read_cfg(self.p)
        if c is None:
            if self.run:
                self.run.stop()
                self.finish(None, self.run.proc.returncode, why=err)
            self.say("error", err)
            return 20
        if self.run:
            rc = self.run.proc.poll()
            if rc is not None:
                self.finish(c, rc)
            elif self.run.busy():
                if self.run.busy_since is None:
                    self.run.busy_since = now()
                if now() - self.run.busy_since > c.max_secs:
                    self.run.stop()
                    self.finish(c, self.run.proc.returncode, why="the job ran past FLEET_CI_MAX_SECS")
                else:
                    self.say("busy", "a job since %s" % sup.iso(self.run.busy_since), login=c.login)
                    return c.every
            else:
                why = tight(c)
                if why or c.runners == 0 or now() - self.run.started > c.idle_secs:
                    self.run.stop()
                    self.finish(c, self.run.proc.returncode, why=why or "idle past FLEET_CI_IDLE_SECS"
                                if c.runners else "FLEET_CI_RUNNERS=0")
                    if why or c.runners == 0:
                        self.say("paused", why or "FLEET_CI_RUNNERS=0", login=c.login)
                        return c.every
                else:
                    self.say("idle", "waiting for a job as %s" % self.run.name, login=c.login)
                    return c.every
        if self.run is None and now() < self.next_try:
            return min(c.every, self.next_try - now())
        if c.runners == 0:
            self.say("paused", "FLEET_CI_RUNNERS=0", login=c.login)
            return c.every
        why = tight(c)
        if why:
            self.say("paused", why, login=c.login)
            return c.every
        ident, err = ensure_login(c)
        if ident is None:
            self.backoff(err)
            return c.every
        self.ident = ident
        tree, err = runner_tree()
        if tree is None:
            self.backoff(err)
            return c.every
        self.run, err = self.mint(c, ident, tree)
        if self.run is None:
            self.backoff(err)
            return c.every
        self.fails = 0
        self.say("idle", "waiting for a job as %s" % self.run.name, login=c.login)
        return c.every

    def main(self):
        lk = os.open(os.path.join(self.p.state, "ci-runner.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("another loop holds the lock — exiting")
            return 3

        def on_signal(*_):
            self.stopping = True

        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(s, on_signal)
        # a loop killed outright left its runner and <home>/runner behind
        c, _ = read_cfg(self.p)
        if c is not None:
            ident = sup.account_ident(c.login)
            if ident:
                kill_login(ident)
                shutil.rmtree(os.path.join(ident[2], "runner"), ignore_errors=True)
        while not self.stopping:
            try:
                wait = self.step()
            except Exception as e:  # one bad beat must never end the loop
                log("beat failed: %r" % e)
                self.say("error", "beat failed: %s" % e)
                wait = 20
            end = now() + max(wait, 0.2)
            while not self.stopping and now() < end:
                time.sleep(0.2)
        if self.run:
            c, _ = read_cfg(self.p)
            self.run.stop()
            self.finish(c, self.run.proc.returncode, why="the daemon stopped the loop")
        self.say("off", "stopped")
        return 0


def status(paths, rest):
    s = sup.ci_summary(paths)
    if "--json" in rest:
        print(json.dumps(s, indent=1, sort_keys=True))
        return 0
    if s is None:
        if "--check" in rest:
            print("no ci.env — no test runner on this machine")
            return 2
        print("ci-runner  none (no %s)" % sup.ci_env_path(paths))
        return 0
    line = sup.ci_line(paths)
    if "--check" in rest:
        print(line.split(None, 1)[1] if line else "")
        return 0 if s.get("state") in ("idle", "busy", "paused") else 1
    print(line)
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    paths = sup.Paths()
    if cmd == "loop":
        return Loop(paths).main()
    if cmd == "status":
        return status(paths, argv[2:])
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    print("usage: fleet-ci-runner.py loop | status [--check|--json]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
