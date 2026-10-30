#!/usr/bin/env python3
"""fleet-node-supervisor-selftest.py — the machine daemon in a sandbox (issue #2331).

Driven by bin/fleet-node-supervisor-selftest.sh. Every path goes through the
FLEET_NODE_* seams; nothing touches /Library, /var or a real login.

  A  a child killed is restarted within its backoff; quick deaths double it, capped
  B  every task runs as ONE copy (an overlong task is skipped, not doubled; a hand
     `tick` beside a running supervisor refuses)
  C  leftover plists move to the attic, come back with `attic restore`, purge after N days;
     a fleet plist outside expected.json's labels is booted out into the attic
  O  the sweep's removals on a managed machine (#2981): what goes, what stays
     named and why, a unit that will not unload, a running drill holding all of
     it, a legacy child taken over by the running daemon, the client shell
     retired by the sweep itself; the root core (#3857) and the admin seat's
     unit (#4118) never go
  D  the supervisor restarted (kill -9) keeps its state and ADOPTS a live child
  E  status: one line per item; --check 2 not installed · 0 ok · 1 stale/down
  F  root runs only a root-owned, non-writable script; the built-in table's shape
  G  the default (no table) machine half: diskguard / memguard / orphans / shared-dirs
  H  the account half (#2332): the table is the launchd templates; a task runs as
     its account (uid, HOME, USER, FLEET_CONF_DIR, its own log); one account's
     failure never touches another's; `account adopt` boots the old services out
     into the attic and `account release` puts them back, one command each; a
     service that will not unload puts every one back; expected.json narrows who runs;
     a lane the hub refuses is named (status, --check 3) and `adopt --rejoin` renews
     the login's token (issue #2501)
  I  the login-level register (#2525): `service add` (and bin/fleet-service.sh)
     writes a root 0600 entry; the daemon runs it as its login with its credential
     injected, its log in <log>/logins/<login>/; killed → back within 30 s; stop /
     start / restart / rm; `status --json` .services[]; a bad entry is named, never
     run; a login's services/ never restarts the node agent
  J  `service move` (#2528): two fake logins — after the move the entry, its
     paths[] (working + skill dir), its log and its credential are the new login's
     and none is left under the old; it runs as the new login, never both at once;
     a move onto an existing path refuses with nothing changed; `account release`
     of a login with entries left refuses 6 with the move line (--force passes)
  K  agent tasks (#2529): a fake clock at the slot → ONE spawner call with the
     session line (--no-repo --origin hub --print --name <window> --prompt …); a
     spawner failing every time → retried up to the limit, then `failed`, no more
     tries, an alert file; `service run` / `fleet task run --now` → one run at once;
     a done file decides ok vs failed; cron + tz slots; bad entries refused
  L  tenants (#2842): a taken-over login in the admin group or with sudo rules is
     named (`tenants --check` 1, the doctor's FAIL), a clean one passes (0), none
     taken over is no row (2); `account adopt` refuses such a login (5) with nothing
     moved; the daemon's tick writes the reading into state.json and a non-root
     reader's check carries it
  Q  root's reads in a login's places never wait on a FIFO; SIGUSR1 dumps the
     stacks of a live loop (#3084)
  P  the watchdog (#3079, #3086): a loop wedged in a blocking open() is ended
     within FLEET_NODE_WATCHDOG_SECS — the phase named, its stack in the log,
     `supervisor.wedged` for status, exit 70; status --check reads WEDGED (5)
     while it is stopped; a loop coming round stays up; a TCC.db open() that never
     returns (the FDA probe, a child) and a FIFO task log / state file stall nothing
  R  the entry port (#3070): off adds nothing (no child, no status line, no
     directory); the switch from the environment or machine.env; only a plain
     public key becomes a keys-file line; the config is 共同约定 2 line for line
  U  on demand (#3647): a service exiting 75 is `idle` — not restarted, not
     `down` — until its entry is rewritten; `service ensure --name webchat`
     registers it from the login's home, starts a stopped / idle one and waits for
     its socket's /healthz (`registered|started|running · ready`, or `not ready`
     after N tries); a name off the on-demand table is refused
  V  session units (#3671): a `session` unit runs only while its login has a
     session; a restart adopts an account unit (no second copy), an orphaned copy
     is stopped, an earlier daemon's running task is not doubled
  S  can the outside reach the entry port (#3072): `entry reach` posts the port, its
     host key, the global IPv6 (never a tunnel's, a temporary one), the LAN IPv4 with
     the default route's interface first (wired en0, not Wi-Fi), and the router's
     answer to the hub, writes reach.json 0644; the doctor's `public` row says
     连得上 / 连不上 + why (carrier NAT, the port to forward to which LAN address); a
     router that never answers or refuses costs seconds, never the report; the hub
     away keeps the last verdict; off / nobody's home = no row
  Y  the idle beat (#4359, EPIC #4354 共同约定 1 · 4): with every login's published
     working state idle for FLEET_NODE_IDLE_HOLD a task under the cap runs on its
     stretched clock (×3, at least 60 s; a table's idle_every; memguard only while
     memory is calm; `"idle": false`, a 300 s task unchanged); a login working, a
     stale row, a state change since the snapshot or a CI job puts every clock
     back at once — a fake clock, no wait; status's `idle` line says which
  X  the entry's state dir (#4161) loses its group / other write on every entry
     pass — `StrictModes yes` refuses a key under a writable dir (an emptyDir is
     0777); never widened, a sticky dir left
"""
import importlib.util
import json
import os
import plistlib
import atexit
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import traceback
from unittest import mock

BIN = os.path.dirname(os.path.abspath(__file__))
SUP = os.path.join(BIN, "fleet-node-supervisor.py")
spec = importlib.util.spec_from_file_location("fns", SUP)
fns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fns)


# A CLI call runs the supervisor's ~9k lines as a script, which Python never loads
# from bytecode: every `status` / `account …` compiled them again (~0.2 s, ~300
# calls a run). CLI = the same argv through a two-line loader that keeps the
# bytecode in a per-run cache — still `__main__`, its argv, path and file as a
# script's; its children are untouched (no environment set). The daemon started
# this way still reads `…/fleet-node-supervisor.py run` in ps (live_daemons' match).
_PYC = tempfile.mkdtemp(prefix="fns-pyc.")
atexit.register(shutil.rmtree, _PYC, True)
_LOADER = ("import os, sys, importlib.util as u\n"
           "sys.pycache_prefix = sys.argv[1]; p = sys.argv[2]; sys.argv = sys.argv[2:]\n"
           "sys.path[0] = os.path.dirname(p)\n"
           "s = u.spec_from_file_location('__main__', p); m = u.module_from_spec(s)\n"
           "sys.modules['__main__'] = m; s.loader.exec_module(m)\n")
CLI = [sys.executable, "-c", _LOADER, _PYC, SUP]


# an ssh-ed25519 public key's base64 (the entry's key lines, #3070)
ED25519_BLOB = __import__("base64").b64encode(b"\x00\x00\x00\x0bssh-ed25519" + b"\x00\x00\x00\x20" + b"k" * 32).decode()


def put(path, data, mode=None, append=False):
    """Write <data> (a str, else as JSON) to <path>, its directory made; <mode> chmods it."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a" if append else "w") as f:
        if isinstance(data, str):
            f.write(data)
        else:
            json.dump(data, f)
    if mode is not None:
        os.chmod(path, mode)
    return path


def slurp(path):
    """<path>'s text, or "" when it cannot be read."""
    try:
        with open(path) as f:
            return f.read()
    except (IOError, OSError):
        return ""


def until(secs, fn, step=0.05):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return fn()


class DiagnosticLog:
    """Bound the added failure evidence, including traceback and command output."""
    marker = "\n[diagnostic truncated: 65536-byte total limit]\n"

    def __init__(self, sink=None):
        self.left = 65536 - len(self.marker.encode())
        self.truncated = False
        self.sink = sys.stderr if sink is None else sink

    def write(self, text):
        data = text.encode("utf-8", errors="replace")
        kept = data[:self.left].decode("utf-8", errors="ignore")
        self.sink.write(kept)
        self.left -= len(kept.encode())
        if len(data) > len(kept.encode()) and not self.truncated:
            self.sink.write(self.marker)
            self.truncated = True
            self.left = 0
        return len(text)

    def flush(self):
        self.sink.flush()


def diagnostic_output(value):
    data = value if isinstance(value, bytes) else (value or "").encode("utf-8", errors="replace")
    text = data[:4096].decode("utf-8", errors="replace")
    return text + ("\n[command output truncated at 4096 bytes]" if len(data) > 4096 else "")


def diagnostic_files(sandbox, log, active_files=()):
    # The fixed paths take priority. Do not walk an unbounded log directory or
    # follow links; stop after 16 candidate files / 64 directory entries.
    names = ["sup.err", "sup.out", "launchctl.log", "stuck.txt", "db/state.json",
             "db/logins/alice/services/webchat.json"]
    names.extend(os.path.relpath(path, sandbox) for path in active_files)
    pending = [os.path.join(sandbox, "log")]
    seen = 0
    while pending and len(names) < 16 and seen < 64:
        directory = pending.pop()
        try:
            if not stat.S_ISDIR(os.lstat(directory).st_mode):
                continue
            with os.scandir(directory) as entries:
                for entry in entries:
                    seen += 1
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)
                    elif entry.is_file(follow_symlinks=False):
                        names.append(os.path.relpath(entry.path, sandbox))
                    if len(names) >= 16 or seen >= 64:
                        break
        except OSError as exc:
            print("supervisor-scan " + repr(exc), file=log)
    if pending or len(names) >= 16 or seen >= 64:
        print("[file enumeration truncated: 16 files / 64 entries]", file=log)
    for name in names:
        if log.truncated:
            break
        path = os.path.join(sandbox, name)
        print("supervisor-file " + path, file=log)
        try:
            # Recheck after open; NONBLOCK avoids blocking on a replaced FIFO.
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    print("[not a regular file]", file=log)
                    continue
                size = min(8192, log.left)
                data = source.read(size)
                print(data.decode("utf-8", errors="replace"), file=log)
                if os.fstat(source.fileno()).st_size > len(data):
                    print("[file truncated: read %d bytes, per-file limit 8192]" % len(data), file=log)
        except OSError as exc:
            print(repr(exc), file=log)


# Independent complete entries. Default four-way stride omits only these;
# all/explicit unittest names retain them. No runner or production selector change.
BOUNDED_CASES = {
    "O_SweepRemoves.test_a_core_gone_from_launchd_is_put_back": "core-recovery",
    "U_OnDemand.test_ensure_registers_starts_and_waits": "ensure-register",
    "U_OnDemand.test_ensure_after_idle": "ensure-idle",
    "U_OnDemand.test_ensure_after_stop": "ensure-stop",
}


def budget_module():
    if "supervisor_test_budget" not in sys.modules:
        spec = importlib.util.spec_from_file_location("supervisor_test_budget",
            os.path.join(BIN, "fleet-node-supervisor-selftest-budget.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
    return sys.modules["supervisor_test_budget"]


_STRIDE_DISCOVERY = False


def load_tests(loader, tests, pattern):
    # Unittest invokes this hook for module discovery, not explicit case names.
    # Keep selftest_part's original four-way stride over the remaining methods.
    if _STRIDE_DISCOVERY:
        import selftest_part
        return unittest.TestSuite(t for t in selftest_part._flat(tests)
            if ".".join(t.id().split(".")[-2:]) not in BOUNDED_CASES)
    return tests


def sweep(*dirs):
    """Kill every process of ours whose argv names one of <dirs> (issue #4360): a
    child the supervisor started, a planted stray copy, a grandchild — whatever the
    state file no longer names. A sandbox path is ours alone, so nothing else matches."""
    keys = set()
    for d in dirs:
        if d:
            keys.update({d.rstrip("/") + "/", os.path.realpath(d).rstrip("/") + "/"})
    if not keys:
        return
    out = subprocess.run(["ps", "-axo", "pid=,uid=,command="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        f = line.split(None, 2)
        if len(f) < 3 or not f[0].isdigit() or f[1] != str(os.getuid()):
            continue
        if int(f[0]) != os.getpid() and any(k in f[2] for k in keys):
            pids.append(int(f[0]))
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        if sig == signal.SIGTERM and pids:
            until(0.2, lambda: not any(fns.pid_alive(x) for x in pids), step=0.02)


class Sandbox(unittest.TestCase):
    def run(self, result=None):
        key = type(self).__name__ + "." + self._testMethodName
        if key not in BOUNDED_CASES:
            return super().run(result)
        mod = budget_module()
        self.budget = mod.ACTIVE or mod.Budget(mod.shared_now())
        self.procs, self.owned_hosts, self.owned_dirs = [], [], []
        self.diagnostic_calls, self.diagnostic_calls_omitted = [], 0
        self.diagnostic_stage = "before setUp"
        self.diagnostic_log = DiagnosticLog(getattr(self, "diagnostic_sink", None))
        self.cleanup_count = 0
        self.cleanup_complete = False
        self.first_exception = None
        # Register before even creating the first directory: unittest runs this
        # after a failed setUp too. The unchanged legacy tearDown is bypassed.
        self.addCleanup(self.cleanup_bounded)
        try:
            return super().run(result)
        finally:
            try:
                print("supervisor-entry " + json.dumps({"case": self.id(),
                    "elapsed": self.budget.elapsed(), "cleanup_complete": self.cleanup_complete,
                    "cleanup_count": self.cleanup_count}), file=sys.stderr, flush=True)
            finally:
                if mod.ACTIVE is None:
                    self.budget.close()

    def phase_call(self, phase, call):
        if not hasattr(self, "budget"):
            return call()
        self.diagnostic_stage = phase
        try:
            return call()
        except BaseException:
            failure = sys.exc_info()
            if self.first_exception is None:
                self.first_exception = failure[1]
            self.diagnose(failure)
            raise  # retain the exact original exception, including setUp failure

    def _callSetUp(self):
        return self.phase_call("setUp", super()._callSetUp)

    def _callTestMethod(self, method):
        return self.phase_call("body", lambda: super(Sandbox, self)._callTestMethod(method))

    def _callTearDown(self):
        return self.phase_call("tearDown", super()._callTearDown)

    def diagnose(self, failure):
        try:
            self.budget.arm(self.budget.DIAGNOSTIC, "diagnostic")
            log = self.diagnostic_log
            print("supervisor-diagnostic " + json.dumps({
                "case": self.id(), "stage": self.diagnostic_stage,
                "wall": time.time(), "elapsed": self.budget.elapsed(),
                "sandbox": getattr(self, "d", None),
                "supervisors": [{"pid": p.pid, "rc": p.poll()} for p in self.procs],
            }), file=log, flush=True)
            traceback.print_exception(*failure, file=log)
            print("supervisor-calls " + json.dumps({"calls": self.diagnostic_calls,
                "omitted": self.diagnostic_calls_omitted}), file=log, flush=True)
            if hasattr(self, "d"):
                recent = self.owned_hosts[-4:]
                diagnostic_files(self.d, log,
                    [item[key] for item in recent for key in ("stdout", "stderr")])
        except BaseException as diagnostic_error:
            # Even a diagnostic deadline must not replace the original error.
            print("[diagnostic incomplete: %s; original exception retained]"
                  % type(diagnostic_error).__name__, file=sys.stderr, flush=True)
        finally:
            self.budget.arm(self.budget.DIRECTORIES, "cleanup")

    def own_directory(self, **kwargs):
        with budget_module().registration():
            path = tempfile.mkdtemp(**kwargs)
            st = os.lstat(path)
            self.owned_dirs.append((path, st.st_dev, st.st_ino))
        return path

    def cleanup_bounded(self):
        self.cleanup_count += 1
        self.budget.arm(self.budget.DIRECTORIES, "terminate/join/directories")
        errors = []
        try:
            # Parent owns only these actual Popen handles. Each host reaps its
            # own direct children, including services with separate sessions.
            for item in self.owned_hosts:
                p = item["proc"]
                if p.poll() is None:
                    p.terminate()
            for item in self.owned_hosts:
                p = item["proc"]
                try:
                    p.wait(timeout=self.budget.left(self.budget.HOST_JOIN))
                except subprocess.TimeoutExpired:
                    # The host should have force-reaped at t=49. A missing
                    # receipt is a cleanup failure, never guessed via state PID.
                    p.kill()
                    p.wait(timeout=self.budget.left(self.budget.DIRECTORIES))
                    errors.append("host %s missed join deadline" % p.pid)
                mod = budget_module()
                joined_at = mod.shared_now()
                try:
                    with open(item["journal"]) as src:
                        receipt = json.load(src)
                    if (receipt.get("host") != p.pid or receipt.get("start") != self.budget.start
                            or not receipt.get("complete") or receipt.get("rc") != p.returncode):
                        raise AssertionError("wrong owner/incomplete child joins")
                    if receipt.get("rc") in (124, 125):
                        raise AssertionError("host exhausted budget or failed cleanup")
                    if item["daemon"] and p.returncode not in (0, 143):
                        raise AssertionError("supervisor exited unexpectedly: %s" % p.returncode)
                    mod.verify_host_clock(receipt, self.budget.start, item["dispatched_at"], joined_at)
                    kept = dict(receipt, parent_observation={"dispatched_at": item["dispatched_at"],
                                "joined_at": joined_at, "clock_identity": mod.clock_identity()})
                    record = "supervisor-owned-joined " + json.dumps(kept) + "\n"
                    # An essential receipt must survive in full before its
                    # sandbox is removed. Exhaustion retains that directory and
                    # fails; a truncated diagnostic is never a joined receipt.
                    if self.diagnostic_log.truncated or len(record.encode()) > self.diagnostic_log.left:
                        raise AssertionError("host receipt exceeds remaining evidence budget")
                    self.diagnostic_log.write(record)
                    self.diagnostic_log.flush()
                    if mod.ENVELOPE_RECORD is not None:
                        mod.ENVELOPE_RECORD.save_host(kept)
                except (OSError, ValueError, AssertionError) as exc:
                    errors.append("host %s: %s" % (p.pid, exc))
        except BaseException as exc:
            errors.append("cleanup exception: " + type(exc).__name__)
            # The original body/setUp error remains in unittest's result. One
            # last bounded cleanup phase cannot rearm an already expired 42s
            # diagnostic timer and replace that exception with another alarm.
            self.budget.arm(self.budget.FINISH, "cleanup failure evidence")
            traceback.print_exception(*sys.exc_info(), file=self.diagnostic_log)
            raise
        finally:
            # Removal is identity checked, including partial setUp's short home.
            # Do not delete evidence if a host may still be alive.
            if not errors and all(item["proc"].poll() is not None for item in self.owned_hosts):
                for path, device, inode in reversed(self.owned_dirs):
                    try:
                        st = os.lstat(path)
                        if (st.st_dev, st.st_ino) != (device, inode) or not stat.S_ISDIR(st.st_mode):
                            raise AssertionError("private directory identity changed: " + path)
                        shutil.rmtree(path)
                    except (OSError, AssertionError) as exc:
                        errors.append(str(exc))
            else:
                errors.append("ownership/join incomplete: private directories retained")
        self.budget.arm(self.budget.FINISH, "final result")
        self.cleanup_complete = not errors
        print("supervisor-cleanup " + json.dumps({"case": self.id(),
            "elapsed": self.budget.elapsed(), "errors": errors,
            "directories": [p for p, _, _ in self.owned_dirs]}), file=sys.stderr, flush=True)
        if budget_module().ENVELOPE_RECORD is not None:
            budget_module().ENVELOPE_RECORD.save_cleanup({"case": self.id(),
                "count": self.cleanup_count, "complete": self.cleanup_complete, "errors": errors,
                "hosts": len(self.owned_hosts), "at": budget_module().shared_now(),
                "directories": [{"path": p, "device": device, "inode": inode}
                                for p, device, inode in self.owned_dirs]})
        if errors:
            raise AssertionError("CLEANUP_INCOMPLETE: " + "; ".join(errors))

    def owned_host(self, args, env, out_name, err_name):
        mod = budget_module()
        journal = os.path.join(self.d, "owned-%d.json" % len(self.owned_hosts))
        env = dict(env, SUPERVISOR_TEST_JOURNAL=journal)
        out_path, err_path = os.path.join(self.d, out_name), os.path.join(self.d, err_name)
        # Files avoid a full pipe blocking a daemon or an unbounded communicate.
        with open(out_path, "a") as out, open(err_path, "a") as err:
            with mod.registration():
                dispatched_at = mod.shared_now()
                p = mod.launch(self.budget, self.procs,
                    mod.host_argv(self.budget.start, dispatched_at, args),
                    env=env, stdout=out, stderr=err)
                self.owned_hosts.append(dict(proc=p, journal=journal, stdout=out_path,
                    stderr=err_path, daemon=list(args) == ["run"], dispatched_at=dispatched_at))
        return p

    def wait_for(self, secs, fn):
        return self.budget.until(secs, fn) if hasattr(self, "budget") else until(secs, fn)

    def setUp(self):
        self.d = (self.own_directory(prefix="fns.") if hasattr(self, "budget")
                  else tempfile.mkdtemp(prefix="fns."))
        # nothing of the machine's own: no FLEET_NODE_* (and no entry switch, #3070)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_NODE_", "FLEET_ENTRY"))}
        self.env.update({
            "FLEET_NODE_STATE": os.path.join(self.d, "db"),
            "FLEET_NODE_LOG": os.path.join(self.d, "log"),
            "FLEET_NODE_RUNTIME": os.path.join(self.d, "rt"),
            "FLEET_NODE_DAEMON_DIR": os.path.join(self.d, "LaunchDaemons"),
            "FLEET_NODE_USERS": os.path.join(self.d, "Users"),
            "FLEET_NODE_TABLE": os.path.join(self.d, "table.json"),
            "FLEET_NODE_TICK": "0.1",
            "FLEET_NODE_LAUNCHCTL": "",
            "FLEET_NODE_TEST": "1",
        })
        os.makedirs(self.env["FLEET_NODE_DAEMON_DIR"])
        self.procs = []

    def front(self, script, login, *args, **env):
        """bin/<script> (fleet-service.sh / fleet-task.sh) as <login>, through the sandbox's supervisor."""
        fe = dict(dict(self.env, FLEET_NODE_SUPERVISOR=SUP, FLEET_SERVICE_SUDO="", FLEET_SERVICE_LOGIN=login), **env)
        return subprocess.run(["bash", os.path.join(BIN, script)] + list(args), env=fe, capture_output=True, text=True)

    def age_attic(self, days):
        """Every attic entry moved <days> days ago; -> the index."""
        idx_p = os.path.join(self.d, "db", "attic", "index.json")
        idx = json.load(open(idx_p))
        for e in idx:
            e["moved"] -= days * 86400
        return put(idx_p, idx) and idx

    def svc(self, *args, **kw):
        return self.run_sup("service", *args, **kw)

    def services(self):
        return {x["name"]: x for x in json.loads(self.run_sup("status", "--json").stdout)["services"]}

    def logins_dir(self, *envs):
        """db/logins (made), with <login>.env (a token line) for each of <envs>."""
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg, exist_ok=True)
        for who in envs:
            put(os.path.join(lg, who + ".env"), "CCQUOTA_TOKEN=x\n")
        return lg

    def node_agent(self, lg, cmd=None, requires=None, reload=None, hold=False, **kw):
        """The table: one node-agent child (na.sh sleeping unless <cmd>) that needs
        and reloads on logins/*.env; <hold>: account-ops books hold its reload."""
        c = dict(name="node-agent", cmd=cmd or [self.script("na.sh", "exec sleep 300\n")],
                 requires=requires or [os.path.join(lg, "*.env")], reload=reload or os.path.join(lg, "*.env"), **kw)
        if hold:
            c["hold"] = os.path.join(self.d, "db", "agent", "*", "account-ops.json")
        self.table(children=[c])

    def new_pid(self, name, old):
        """<name>'s pid once it is no longer <old>."""
        return until(10, lambda: (self.child(name).get("pid") or old) != old and self.child(name)["pid"])

    def held_book(self, who="grace"):
        """db/agent/<who>/account-ops.json naming a create run by a live pid -> (book, holder)."""
        holder = subprocess.Popen(["/bin/sleep", "300"])
        self.addCleanup(holder.kill)
        book = put(os.path.join(self.d, "db", "agent", who, "account-ops.json"),
                   {"inflight": {"op-1": {"op": "create", "login": "alice", "pid": holder.pid}}})
        return book, holder

    def passwd(self, homes, *subdirs, admin=()):
        """The sandbox passwd.json, named in the env: each login {login: home} with
        this uid, its home (+ <subdirs>) made; the logins in <admin> can sudo."""
        pw = {}
        for who, home in homes.items():
            for sub in subdirs or ("",):
                os.makedirs(os.path.join(home, sub), exist_ok=True)
            pw[who] = {"uid": os.getuid(), "gid": os.getgid(), "home": home}
            if who in admin:
                pw[who].update(groups=["staff", "admin"], sudo="(ALL) NOPASSWD: ALL")
        self.env["FLEET_NODE_PASSWD"] = put(os.path.join(self.d, "passwd.json"), pw)
        return pw

    def tearDown(self):
        if hasattr(self, "budget"):
            return  # early addCleanup owns all paths, also on failed setUp
        for p in self.procs:
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()
        st = self.state()
        for cs in (st.get("children") or {}).values():
            if cs.get("pid"):
                try:
                    os.kill(cs["pid"], signal.SIGKILL)
                except OSError:
                    pass
        sweep(self.d, getattr(self, "short", None))
        shutil.rmtree(self.d, ignore_errors=True)

    def table(self, children=(), tasks=()):
        put(self.env["FLEET_NODE_TABLE"], {"children": list(children), "tasks": list(tasks)})

    def script(self, name, body):
        p = os.path.join(self.d, name)
        put(p, "#!/bin/bash\n" + body, 0o755)
        return p

    def run_sup(self, *args, **kw):
        e = dict(self.env, **kw.pop("env", {}))
        begin = time.time()
        if hasattr(self, "budget"):
            seq = len(self.owned_hosts)
            p = self.owned_host(args, e, "cli-%d.out" % seq, "cli-%d.err" % seq)
            try:
                p.wait(timeout=min(60, self.budget.left()))
            except subprocess.TimeoutExpired as exc:
                self.record_diagnostic_call(dict(stage=self.diagnostic_stage, args=args,
                    begin=begin, end=time.time(), timeout=exc.timeout,
                    stdout_path=self.owned_hosts[-1]["stdout"], stderr_path=self.owned_hosts[-1]["stderr"]))
                raise budget_module().BudgetExceeded(
                    "FIXTURE_BUDGET_EXHAUSTED nested CLI/observation; incomplete") from exc
            streams = []
            for path in (self.owned_hosts[-1]["stdout"], self.owned_hosts[-1]["stderr"]):
                with open(path, "rb") as source:
                    data = source.read(65537)
                if len(data) > 65536:
                    raise AssertionError("CLI output exceeds test evidence limit: " + path)
                streams.append(data.decode("utf-8", errors="replace"))
            result = subprocess.CompletedProcess([sys.executable, SUP, *args], p.returncode, *streams)
            self.record_diagnostic_call(dict(stage=self.diagnostic_stage, args=args,
                begin=begin, end=time.time(), rc=result.returncode,
                stdout=diagnostic_output(result.stdout), stderr=diagnostic_output(result.stderr)))
            return result
        try:
            result = subprocess.run(CLI + list(args), env=e, capture_output=True,
                                    text=True, timeout=60)
        except subprocess.TimeoutExpired as exc:
            if hasattr(self, "diagnostic_calls"):
                self.record_diagnostic_call(dict(stage=self.diagnostic_stage, args=args,
                    begin=begin, end=time.time(), timeout=exc.timeout,
                    stdout=diagnostic_output(exc.stdout), stderr=diagnostic_output(exc.stderr)))
            raise
        if hasattr(self, "diagnostic_calls"):
            self.record_diagnostic_call(dict(stage=self.diagnostic_stage, args=args,
                begin=begin, end=time.time(), rc=result.returncode,
                stdout=diagnostic_output(result.stdout), stderr=diagnostic_output(result.stderr)))
        return result

    def record_diagnostic_call(self, call):
        if len(self.diagnostic_calls) < 16:
            self.diagnostic_calls.append(call)
        else:
            self.diagnostic_calls_omitted += 1

    def trace_stage(self, stage):
        self.diagnostic_stage = stage
        print("supervisor-stage " + json.dumps(dict(case=self.id(), stage=stage,
            wall=time.time(), sandbox=self.d,
            elapsed=self.budget.elapsed() if hasattr(self, "budget") else None)),
            file=sys.stderr, flush=True)

    def start(self, **extra):
        e = dict(self.env, **extra)
        if hasattr(self, "budget"):
            return self.owned_host(["run"], e, "sup.out", "sup.err")
        output = (open(os.path.join(self.d, "sup.out"), "a")
                  if hasattr(self, "diagnostic_calls") else subprocess.DEVNULL)
        try:
            p = subprocess.Popen(CLI + ["run"], env=e, stdout=output,
                                 stderr=open(os.path.join(self.d, "sup.err"), "a"))
        finally:
            if hasattr(output, "close"):
                output.close()
        self.procs.append(p)
        return p

    def state(self):
        return fns.read_json(os.path.join(self.d, "db", "state.json"), {})

    def child(self, name):
        return (self.state().get("children") or {}).get(name) or {}

    def task(self, name):
        return (self.state().get("tasks") or {}).get(name) or {}


class A_ChildRestart(Sandbox):
    def test_killed_child_comes_back_with_backoff(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}])
        self.start(FLEET_NODE_BACKOFF_RESET="30", FLEET_NODE_BACKOFF_MAX="2")
        pid1 = until(10, lambda: self.child("c").get("pid"))
        self.assertTrue(pid1, "the child never started")
        os.kill(pid1, signal.SIGKILL)
        t0 = time.time()
        pid2 = until(10, lambda: (self.child("c").get("pid") or 0) not in (0, pid1) and self.child("c")["pid"])
        self.assertTrue(pid2, "the killed child was not restarted")
        self.assertLess(time.time() - t0, 1 + 2 + 1.5, "restart took longer than the first backoff")
        c = self.child("c")
        self.assertEqual(c["restarts"], 1)
        self.assertEqual(c["fails"], 1)
        # quick deaths again: backoff doubles, capped at BACKOFF_MAX
        os.kill(pid2, signal.SIGKILL)
        until(10, lambda: self.child("c").get("fails") == 2)
        c = self.child("c")
        self.assertAlmostEqual(c["next_start"] - c["last_exit"], 2, delta=0.01)
        pid3 = until(10, lambda: (self.child("c").get("pid") or 0) not in (0, pid2) and self.child("c")["pid"])
        self.assertTrue(pid3)
        os.kill(pid3, signal.SIGKILL)
        until(10, lambda: self.child("c").get("fails") == 3)
        c = self.child("c")
        self.assertAlmostEqual(c["next_start"] - c["last_exit"], 2, delta=0.01, msg="backoff not capped")

    def test_legacy_daemon_owns_it(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"], "legacy": "com.claude-fleet.x"}])
        open(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.x.plist"), "w").close()
        self.start()
        until(5, lambda: self.child("c").get("status"))
        time.sleep(0.5)
        self.assertEqual(self.child("c").get("status"), "legacy")
        self.assertFalse(self.child("c").get("pid"), "started a second copy beside the legacy daemon")
        self.assertIn("legacy", self.run_sup("status").stdout)

    def test_sigterm_stops_children(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}])
        p = self.start()
        pid = until(10, lambda: self.child("c").get("pid"))
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=15)
        self.assertFalse(fns.pid_alive(pid), "a stopped supervisor left its child running")


class B_OneCopy(Sandbox):
    def test_overlong_task_is_not_doubled(self):
        mark = os.path.join(self.d, "inflight")
        dup = os.path.join(self.d, "dup")
        sh = self.script("t.sh", 'mkdir "%s" 2>/dev/null || touch "%s"; sleep 1; rmdir "%s"\n' % (mark, dup, mark))
        self.table(tasks=[{"name": "t", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        self.start()
        self.assertTrue(until(15, lambda: (self.task("t").get("runs") or 0) >= 2), "the task never ran twice")
        self.assertFalse(os.path.exists(dup), "two copies of one task ran at once")
        self.assertEqual(self.task("t").get("rc") if self.task("t").get("result") != "running" else 0, 0)

    def test_hand_tick_refuses_beside_supervisor(self):
        self.table(tasks=[])
        self.start()
        until(5, lambda: self.state().get("supervisor"))
        r = self.run_sup("tick")
        self.assertEqual(r.returncode, 3, r.stderr)
        # and a second `run` exits at once (one supervisor per machine)
        r2 = subprocess.run([sys.executable, SUP, "run"], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r2.returncode, 3)

    def test_tick_runs_due_tasks_and_records(self):
        sh = self.script("ok.sh", "exit 0\n")
        bad = self.script("bad.sh", "exit 7\n")
        self.table(tasks=[{"name": "ok", "cmd": ["/bin/bash", sh]}, {"name": "bad", "cmd": ["/bin/bash", bad]}])
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertEqual(self.task("ok")["result"], "ok")
        self.assertEqual(self.task("bad")["result"], "failed")
        self.assertEqual(self.task("bad")["rc"], 7)
        # not due again: a second tick does not rerun
        self.run_sup("tick")
        self.assertEqual(self.task("ok")["runs"], 1)

    def test_timeout_kills(self):
        sh = self.script("hang.sh", "sleep 60\n")
        self.table(tasks=[{"name": "h", "every": 100, "timeout": 0.5, "cmd": ["/bin/bash", sh]}])
        self.start()
        self.assertTrue(until(10, lambda: self.task("h").get("result") == "timeout"))


class C_Sweep(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.la = os.path.join(self.d, "Users", "alice", "Library", "LaunchAgents")
        os.makedirs(self.la)
        self.table()

    def touch(self, d, n, body=b"x"):
        p = os.path.join(d, n)
        with open(p, "wb") as f:
            f.write(body)
        return p

    def test_leftovers_move_and_restore(self):
        live = self.touch(self.dd, "com.claude-fleet.alice.collect.plist")
        bak = self.touch(self.dd, "com.claude-fleet.alice.collect.plist.bak-20260820", b"bak")
        pm = self.touch(self.la, "com.ccquota.agent.plist.pre-move")
        ret = self.touch(self.la, "com.claude-fleet.restore.plist.retired-20260901")
        other = self.touch(self.la, "com.apple.something.plist.bak")
        os.chmod(pm, 0o640)
        dry = self.run_sup("sweep", "--dry-run")
        self.assertEqual(dry.stdout.count("would move"), 3, dry.stdout)
        self.assertTrue(os.path.exists(bak))
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        for p in (bak, pm, ret):
            self.assertFalse(os.path.exists(p), p)
        for p in (live, other):
            self.assertTrue(os.path.exists(p), p)
        lst = self.run_sup("attic", "list").stdout.splitlines()
        self.assertEqual(len(lst), 3)
        ident = [x.split()[0] for x in lst if "pre-move" in x][0]
        self.assertEqual(self.run_sup("attic", "restore", ident).returncode, 0)
        self.assertTrue(os.path.exists(pm))
        self.assertEqual(os.stat(pm).st_mode & 0o777, 0o640)
        self.assertEqual(len(self.run_sup("attic", "list").stdout.splitlines()), 2)
        self.assertEqual(self.state()["sweep"]["moved"], 3)

    def test_purge_after_days(self):
        self.touch(self.dd, "com.claude-fleet.x.plist.bak")
        self.run_sup("sweep")
        idx = self.age_attic(8)
        self.assertIn("purged 1", self.run_sup("attic", "purge").stdout)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")
        self.assertFalse(os.path.exists(os.path.dirname(idx[0]["dst"])))

    def test_expected_labels_kept_extra_booted_out(self):
        """expected.json's labels stay; a fleet unit outside the expected set goes
        to the attic (issue #2981 — before, report only)."""
        self.touch(self.dd, "com.claude-fleet.old.collect.plist")
        self.touch(self.dd, "com.claude-fleet.keep.plist")
        os.makedirs(os.path.join(self.d, "db"))
        json.dump({"labels": ["com.claude-fleet.keep"]}, open(os.path.join(self.d, "db", "expected.json"), "w"))
        r = self.run_sup("sweep")
        self.assertIn("booted out %s" % os.path.join(self.dd, "com.claude-fleet.old.collect.plist"), r.stdout)
        self.assertNotIn("keep.plist", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.dd, "com.claude-fleet.old.collect.plist")))
        self.assertTrue(os.path.exists(os.path.join(self.dd, "com.claude-fleet.keep.plist")))

    def test_client_shell_only_taken_over_logins(self):
        """issue #2702: a TAKEN-OVER login (logins/<login>.env) still carrying the
        person's client (the shell's cache, a ~/.zshrc hook) is NAMED, never touched;
        the PATH line and a comment are no hook. Anyone not taken over — an admin, a
        local user — is not looked at: neither half names them, handwritten plists
        included."""
        users = os.path.join(self.d, "Users")
        for login in ("alice", "bob", "carol", "heidi"):
            os.makedirs(os.path.join(users, login, "Library", "LaunchAgents"), exist_ok=True)
        os.makedirs(os.path.join(users, "alice", ".cache", "claude-fleet", "shell", "bin"))
        with open(os.path.join(users, "bob", ".zshrc"), "w") as f:
            f.write("# >>> claude-fleet (bin/fleet-login-bootstrap.sh, issue #1165) >>>\n"
                    "[[ -r ~/.claude/fleet/shell/cw.zsh ]] && source ~/.claude/fleet/shell/cw.zsh\n"
                    "# <<< claude-fleet <<<\n")
        with open(os.path.join(users, "carol", ".zshrc"), "w") as f:      # no hook
            f.write('export PATH="$HOME/.local/bin:$PATH"  # claude-fleet: x\n'
                    "# source ~/.claude/fleet/shell/fleet-login.zsh\n")
        # heidi: an admin, never taken over — a shell, a hook, a hand-written agent
        os.makedirs(os.path.join(users, "heidi", ".cache", "claude-fleet", "shell"))
        put(os.path.join(users, "heidi", ".zshrc"), "source ~/.claude/fleet/shell/cw.zsh\n")
        for login in ("heidi", "alice"):
            with open(os.path.join(users, login, "Library", "LaunchAgents", "com.%s.ddns.plist" % login), "wb") as f:
                plistlib.dump({"Label": "com.%s.ddns" % login,
                               "ProgramArguments": [os.path.join(users, login, "bin", "ddns")]}, f)
        # nothing taken over: nobody is named
        r = self.run_sup("sweep", "--dry-run")
        self.assertNotIn("clientshell", r.stdout)
        self.assertNotIn("handwritten", r.stdout)
        lg = os.path.join(self.d, "db", "logins")
        os.makedirs(lg, exist_ok=True)
        for login in ("alice", "bob", "carol"):
            open(os.path.join(lg, login + ".env"), "w").close()
        r = self.run_sup("sweep")
        self.assertIn("clientshell (left in place): alice: ~/.cache/claude-fleet/shell — ", r.stdout)
        self.assertIn("clientshell (left in place): bob: ~/.zshrc 3 hook line(s)", r.stdout)
        self.assertIn("fleet-node-shell-retire.sh' --login bob", r.stdout)
        self.assertIn("runs as alice", r.stdout)
        self.assertNotIn("carol", r.stdout)
        self.assertNotIn("heidi", r.stdout)
        self.assertEqual(sorted(c["login"] for c in self.state()["sweep"]["clientshell"]), ["alice", "bob"])
        self.assertEqual([h["login"] for h in self.state()["sweep"]["handwritten"]], ["alice"])
        st = self.run_sup("status").stdout
        self.assertIn("clientshell alice", st)
        self.assertNotIn("heidi", st)
        self.assertTrue(os.path.isdir(os.path.join(users, "alice", ".cache", "claude-fleet", "shell")))   # named, not touched
        # status reads the homes NOW (issue #2991): retired by hand since the sweep,
        # the record still names them, status does not
        shutil.rmtree(os.path.join(users, "alice", ".cache", "claude-fleet", "shell"))
        put(os.path.join(users, "bob", ".zshrc"), 'export PATH="$HOME/.local/bin:$PATH"\n')
        self.assertEqual(len(self.state()["sweep"]["clientshell"]), 2)
        st = self.run_sup("status").stdout
        self.assertNotIn("clientshell", st)
        # ...and the fleet's header comments an older retire left behind are the same rule's lines
        with open(os.path.join(users, "bob", ".zshrc"), "a") as f:
            f.write("\n# cfguest:shell — claude-fleet helpers: cf (enter/attach a fleet), cw (worktree + window)\n\n"
                    "# claude-fleet login: banner (+ machine lines from intro.d, e.g. `vnc`), then an SSH login goes "
                    "straight into the fleet\n")
        self.assertIn("clientshell bob          bob: ~/.zshrc 2 hook line(s)", self.run_sup("status").stdout)
        # a home this process cannot read keeps the sweep's reading, marked with its time
        os.chmod(os.path.join(users, "carol"), 0)
        try:
            st = self.run_sup("status").stdout
        finally:
            os.chmod(os.path.join(users, "carol"), 0o755)
        self.assertNotIn("carol", st)          # never named by a sweep: nothing to keep


class O_SweepRemoves(Sandbox):
    """issue #2981: on a managed machine (expected.json) the sweep boots out and
    moves to the attic every fleet unit outside the expected set — a machine unit
    the daemon does not run, a taken-over login's left behind, a gone login's — and a child's old
    LaunchDaemon once the daemon can run that child itself; it leaves named a
    login that is not taken over (adopt is its road), a legacy child that could
    not start, a unit that will not unload, everything while a drill runs; each
    existing login's own credential proxy and keep-labels are expected, and so is
    every unit of an admin login (never taken over, #2842): its agent is the
    machine's admin node, the one that opens a newcomer's login (issue #2997 —
    the sweep had booted com.ccquota.agent.<admin> out on both machines). A managed
    machine's taken-over login carrying the client shell is retired by the sweep
    itself (--if-idle)."""
    def setUp(self):
        Sandbox.setUp(self)
        self.dd = self.env["FLEET_NODE_DAEMON_DIR"]
        users = os.path.join(self.d, "Users")
        self.passwd({w: os.path.join(users, w) for w in ("alice", "bob", "carol")},
                    os.path.join("Library", "LaunchAgents"), admin=("bob",))      # bob: the machine's admin
        os.makedirs(os.path.join(self.d, "db", "logins"))
        open(os.path.join(self.d, "db", "logins", "alice.env"), "w").close()        # alice: taken over
        json.dump({"role": "managed", "version": 0}, open(os.path.join(self.d, "db", "expected.json"), "w"))
        # launchctl: bootout logged; `print` says loaded only for a label in stuck.txt
        self.lclog = os.path.join(self.d, "launchctl.log")
        self.stuck = os.path.join(self.d, "stuck.txt")
        open(self.stuck, "w").close()
        self.env["FLEET_NODE_LAUNCHCTL"] = self.script("launchctl", (
            'echo "$*" >> %s\n'
            '[ "$1" = print ] || exit 0\n'
            'grep -qxF "${2##*/}" %s && exit 0\n'
            'exit 113\n') % (self.lclog, self.stuck))
        self.env["FLEET_NODE_BOOTOUT_WAIT"] = "0.3"
        self.env["FLEET_NODE_SWEEP_HOLD"] = "fns-hold-%d.sh" % os.getpid()
        self.la = {w: os.path.join(users, w, "Library", "LaunchAgents") for w in ("alice", "bob", "carol")}
        ok = self.script("child.sh", "exec sleep 300\n")
        self.table(children=[
            {"name": "c", "cmd": ["/bin/bash", ok], "legacy": "com.claude-fleet.c-legacy"},
            {"name": "w", "cmd": ["/bin/bash", ok], "legacy": "com.claude-fleet.w-legacy",
             "requires": [os.path.join(self.d, "nowhere")]}])

        if hasattr(self, "budget"):
            # Same fake contract and log, no shell/grep descendant to orphan on
            # an interrupted launchctl call. This is not production launchctl.
            with open(self.env["FLEET_NODE_LAUNCHCTL"], "w") as out:
                out.write("#!" + sys.executable + "\nimport sys\n"
                    + "with open(%r, 'a') as f: f.write(' '.join(sys.argv[1:]) + '\\n')\n" % self.lclog
                    + "if sys.argv[1] != 'print': sys.exit(0)\n"
                    + "with open(%r) as f: labels = f.read().splitlines()\n" % self.stuck
                    + "sys.exit(0 if sys.argv[2].split('/')[-1] in labels else 113)\n")

    def plist(self, d, label, **kw):
        p = os.path.join(d, label + ".plist")
        with open(p, "wb") as f:
            plistlib.dump(dict({"Label": label, "ProgramArguments": ["/bin/true"]}, **kw), f)
        return p

    def lay(self):
        dd, la = self.dd, self.la
        return {
            "node": self.plist(dd, "com.claude-fleet.node"),
            "core": self.plist(dd, "com.claude-fleet.node-core"),
            "own-proxy": self.plist(dd, "com.claude-fleet.credsep.alice"),
            "gone-proxy": self.plist(dd, "com.claude-fleet.credsep.ghost"),
            "machine": self.plist(dd, "com.claude-fleet.memguard"),
            "kept": self.plist(dd, "com.claude-fleet.mine"),
            "legacy-ok": self.plist(dd, "com.claude-fleet.c-legacy"),
            "legacy-waits": self.plist(dd, "com.claude-fleet.w-legacy"),
            "carol-daemon": self.plist(dd, "com.claude-fleet.carol.collect"),
            "bob-daemon": self.plist(dd, "com.claude-fleet.x", UserName="bob"),
            "bob-agent": self.plist(la["bob"], "com.claude-fleet.dispatch"),
            "bob-agent2": self.plist(la["bob"], "com.ccquota.agent.bob"),
            "bob-own": self.plist(la["bob"], "com.bob.ddns"),
            "alice-agent": self.plist(la["alice"], "com.claude-fleet.spinner"),
            "carol-agent": self.plist(la["carol"], "com.claude-fleet.dispatch"),
        }

    def test_removes_outside_the_expected_set(self):
        put(os.path.join(self.d, "db", "keep-labels"), "# mine\ncom.claude-fleet.mine\n")
        p = self.lay()
        gone = ("gone-proxy", "machine", "legacy-ok", "alice-agent")
        stay = ("node", "core", "own-proxy", "kept", "legacy-waits", "carol-daemon", "bob-own", "carol-agent",
                "bob-daemon", "bob-agent", "bob-agent2")
        dry = self.run_sup("sweep", "--dry-run")
        self.assertEqual(dry.stdout.count("would boot out"), len(gone), dry.stdout)
        for k in p:
            self.assertTrue(os.path.exists(p[k]), "dry run moved %s" % k)
        self.assertFalse(os.path.exists(self.lclog), "dry run called launchctl")
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        for k in gone:
            self.assertFalse(os.path.exists(p[k]), "%s left: %s" % (k, r.stdout))
        for k in stay:
            self.assertTrue(os.path.exists(p[k]), "%s moved: %s" % (k, r.stdout))
        self.assertNotIn("bob", r.stdout)     # the admin's units: expected, never named (#2997)
        self.assertIn("child c runs under com.claude-fleet.node", r.stdout)
        self.assertIn("launchd still runs child w: %s missing" % os.path.join(self.d, "nowhere"), r.stdout)
        self.assertIn("carol is not taken over — sudo fleet-node-supervisor.py account adopt carol", r.stdout)
        calls = open(self.lclog).read()
        uid = os.getuid()
        for t in ("bootout system/com.claude-fleet.memguard", "bootout system/com.claude-fleet.c-legacy",
                  "bootout gui/%d/com.claude-fleet.spinner" % uid):
            self.assertIn(t, calls)
        for t in ("carol", "com.ccquota.agent.bob", "com.claude-fleet.x", "com.claude-fleet.dispatch",
                  "com.claude-fleet.node-core"):
            self.assertNotIn(t, calls)
        sw = self.state()["sweep"]
        self.assertEqual((sw["removed"], sw["extra"]), (len(gone), 3))
        st = self.run_sup("status").stdout
        self.assertIn("removed %d (total %d) · extra 3 (left in place)" % (len(gone), len(gone)), st)
        self.assertIn("extra  com.claude-fleet.carol.collect", st)
        # the attic keeps them: a restore puts one back
        lst = self.run_sup("attic", "list").stdout.splitlines()
        self.assertEqual(len(lst), len(gone))
        ident = [x.split()[0] for x in lst if "memguard" in x][0]
        self.assertEqual(self.run_sup("attic", "restore", ident).returncode, 0)
        self.assertTrue(os.path.exists(p["machine"]))
        # a second sweep finds only what it leaves named (the restored one goes again)
        r = self.run_sup("sweep")
        self.assertEqual(r.stdout.count("booted out"), 1, r.stdout)

    def test_the_root_core_is_never_swept(self):
        """issue #3857: expected.json naming no labels (a managed machine's usual
        one) and the core's plist beside the daemon's — the sweep, which a seated
        daemon has the core itself run, booted the core out: it died mid-sweep,
        gone from launchd, its plist left. It is the machine's own unit."""
        p = self.plist(self.dd, "com.claude-fleet.node-core")
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(p), r.stdout)
        self.assertNotIn("node-core", r.stdout)
        self.assertFalse("node-core" in slurp(self.lclog),
                         "the sweep called launchctl on the core")
        # and the one place that boots a unit out refuses it, whoever asks
        self.assertIsInstance(fns._retire_unit(None, self.dd, p, "com.claude-fleet.node-core", [], "x", False), str)

    def test_the_admin_seat_unit_is_never_swept(self):
        """issue #4118: expected.json naming no labels and the admin seat's own
        unit (com.claude-fleet.admin-agent, UserName the role — #3724) beside the
        daemon's: its `_` UserName read as "a machine unit the daemon does not
        run", and the sweep booted it out minutes after `fleet node install` made
        it. The seat's unit stays; the same label under another UserName does not."""
        # the daemon under the launchctl seam is the macOS one on any CI box, so the role is
        # macOS's — not fns.SEAT_ADMIN_ROLE, which this (seamless) import read off the platform
        p = self.plist(self.dd, "com.claude-fleet.admin-agent", UserName="_fleetadmin")
        r = self.run_sup("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(p), r.stdout)
        self.assertNotIn("admin-agent", r.stdout)
        self.assertFalse("admin-agent" in slurp(self.lclog),
                         "the sweep called launchctl on the seat's agent")
        os.unlink(p)
        p = self.plist(self.dd, "com.claude-fleet.admin-agent")       # no UserName: root, not the seat
        r = self.run_sup("sweep")
        self.assertFalse(os.path.exists(p), r.stdout)

    def test_a_core_gone_from_launchd_is_put_back(self):
        """issue #3857: the core's plist installed, launchd holding no such job,
        its socket gone — an unseated (root) daemon bootstraps it back and says so
        once; status names how long it has been down."""
        self.plist(self.dd, "com.claude-fleet.node-core")
        self.env["FLEET_NODE_CORE_SOCK"] = os.path.join(self.d, "core.sock")
        self.env["FLEET_NODE_SWEEP_EVERY"] = "100000"
        self.trace_stage('O initial status')
        st = self.run_sup("status").stdout
        self.assertIn("core        NOT ANSWERING", st)
        self.trace_stage('O start supervisor')
        self.start()
        want = "bootstrap system %s" % os.path.join(self.dd, "com.claude-fleet.node-core.plist")
        self.trace_stage('O bootstrap within 10s')
        self.assertTrue(self.wait_for(10, lambda: want in slurp(self.lclog)),
                        "the daemon did not put the core back")
        self.trace_stage('O down_since within 5s')
        self.assertTrue(self.wait_for(5, lambda: (self.state().get("core") or {}).get("down_since")))
        self.trace_stage('O status reflects daemon')
        self.assertIn("(the daemon's word)", self.run_sup("status").stdout)
        self.trace_stage('O exactly one NOT ANSWERING warning')
        log = open(os.path.join(self.d, "sup.err")).read()
        self.assertEqual(log.count("core NOT ANSWERING"), 1, log)

    def test_one_that_will_not_unload_stays(self):
        p = self.plist(self.dd, "com.claude-fleet.memguard")
        put(self.stuck, "com.claude-fleet.memguard\n")
        r = self.run_sup("sweep")
        self.assertTrue(os.path.exists(p))
        self.assertIn("system/com.claude-fleet.memguard did not unload", r.stdout)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_a_running_drill_holds_every_removal(self):
        p = self.lay()
        drill = self.script(self.env["FLEET_NODE_SWEEP_HOLD"], "sleep 30\n")
        hp = subprocess.Popen(["/bin/bash", drill])
        try:
            until(5, lambda: subprocess.run(["pgrep", "-f", drill], capture_output=True).returncode == 0)
            r = self.run_sup("sweep")
            for k in p:
                self.assertTrue(os.path.exists(p[k]), "%s moved under a drill" % k)
            self.assertIn("held: pid %d runs %s" % (hp.pid, self.env["FLEET_NODE_SWEEP_HOLD"]), r.stdout)
            self.assertIn("held: pid %d" % hp.pid, self.run_sup("status").stdout)
        finally:
            hp.kill()
            hp.wait()
        r = self.run_sup("sweep")
        self.assertFalse(os.path.exists(p["alice-agent"]), r.stdout)

    def test_a_command_line_naming_the_drill_holds_nothing(self):
        """issue #2991: only a process RUNNING the drill holds the sweep — an ssh
        remote command, `pgrep -f`, `bash -c '… drill …'` merely name it."""
        p = self.lay()
        name = self.env["FLEET_NODE_SWEEP_HOLD"]
        decoys = [subprocess.Popen(["/bin/sh", "-c", "sleep 30; : %s --help" % name]),
                  subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", name, "--help"]),
                  subprocess.Popen(["/bin/bash", "-c", 'exec -a ssh "$0" -c "import time; time.sleep(30)" mini "$1" --help',
                                   sys.executable, name])]
        try:
            until(5, lambda: subprocess.run(["pgrep", "-f", name], capture_output=True).stdout.count(b"\n") >= 2)
            r = self.run_sup("sweep")
            self.assertNotIn("held", r.stdout)
            self.assertFalse(os.path.exists(p["alice-agent"]), r.stdout)
        finally:
            for d in decoys:
                d.kill()
                d.wait()

    def test_runs_script_rule(self):
        n = "fleet-hold-me.sh"
        for cmd in ("/bin/bash /Users/x/.claude/fleet/bin/%s --login t" % n, "/x/bin/%s" % n,
                    "env FOO=1 bash -x /a/%s" % n, "bash -- /a/%s" % n):
            self.assertTrue(fns.runs_script(cmd, n), cmd)
        for cmd in ("ssh mini %s --help" % n, "pgrep -f hold-me", "bash -c %s --help" % n,
                    "zsh -lc /a/%s" % n, "grep %s x" % n, "-zsh", "sshd: heidi@ttys001 %s" % n,
                    "/bin/bash /a/other.sh %s" % n):
            self.assertFalse(fns.runs_script(cmd, n), cmd)

    def test_legacy_child_taken_over_by_the_running_daemon(self):
        p = self.plist(self.dd, "com.claude-fleet.c-legacy")
        self.start(FLEET_NODE_SWEEP_EVERY="3600")
        until(10, lambda: self.child("c").get("pid"))
        self.assertFalse(os.path.exists(p), "the legacy definition is still installed")
        self.assertEqual(self.child("c").get("status"), "supervised")
        self.assertTrue(fns.pid_alive(self.child("c")["pid"]))
        self.assertEqual(self.child("w").get("status"), "waiting")

    def test_client_shell_retired_by_the_sweep(self):
        rt = os.path.join(self.d, "rt", "bin")
        os.makedirs(rt)
        shutil.copy(os.path.join(BIN, "fleet-node-shell-retire.sh"), rt)
        shutil.copy(SUP, rt)          # the retire script's one rule (shell-hooks, issue #2991)
        home = os.path.join(self.d, "Users", "alice")
        os.makedirs(os.path.join(home, ".cache", "claude-fleet", "shell", "bin"))
        put(os.path.join(home, ".zshrc"), "alias y=yazi\nsource ~/.claude/fleet/shell/cw.zsh\n")
        # carol is not taken over: hers is not the fleet's to touch
        os.makedirs(os.path.join(self.d, "Users", "carol", ".cache", "claude-fleet", "shell"))
        dry = self.run_sup("sweep", "--dry-run")
        self.assertIn("clientshell (would retire): alice", dry.stdout)
        self.assertTrue(os.path.isdir(os.path.join(home, ".cache", "claude-fleet", "shell")))
        r = self.run_sup("sweep")
        self.assertNotIn("clientshell", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(home, ".cache", "claude-fleet", "shell")))
        self.assertEqual(open(os.path.join(home, ".zshrc")).read(), "alias y=yazi\n")
        self.assertEqual(self.state()["sweep"]["clientshell"], [])
        self.assertNotIn("clientshell", self.run_sup("status").stdout)
        self.assertTrue(os.path.isdir(os.path.join(self.d, "Users", "carol", ".cache", "claude-fleet", "shell")))


class D_RestartKeepsState(Sandbox):
    def test_kill9_supervisor_keeps_state_and_adopts(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}],
                   tasks=[{"name": "t", "every": 0.2, "cmd": ["/bin/bash", sh]}])
        p = self.start()
        self.assertTrue(until(10, lambda: (self.task("t").get("runs") or 0) >= 3))
        cpid = self.child("c")["pid"]
        p.kill()
        p.wait()
        runs = self.task("t")["runs"]
        self.assertTrue(fns.pid_alive(cpid), "the child died with the supervisor")
        self.start(FLEET_NODE_BACKOFF_MAX="0.1")   # the adopted child killed below comes back at once
        self.assertTrue(until(10, lambda: (self.state().get("supervisor") or {}).get("starts") == 2))
        self.assertTrue(until(10, lambda: (self.task("t").get("runs") or 0) > runs))
        self.assertGreater(self.task("t")["runs"], runs, "task history lost across the restart")
        time.sleep(0.5)
        self.assertEqual(self.child("c")["pid"], cpid, "the live child was not adopted")
        self.assertEqual(self.child("c").get("restarts") or 0, 0)
        # an adopted child that then dies is still restarted
        os.kill(cpid, signal.SIGKILL)
        self.assertTrue(until(10, lambda: (self.child("c").get("pid") or 0) not in (0, cpid)))


class D2_NoGapRestart(Sandbox):
    """T595: the shared credential proxy restarted on every release, and for its
    seconds every session's request was ECONNREFUSED."""

    def runtime(self, sha):
        d = os.path.join(self.d, sha)
        os.makedirs(d, exist_ok=True)
        rt = self.env["FLEET_NODE_RUNTIME"]
        if os.path.lexists(rt):
            os.unlink(rt)
        os.symlink(d, rt)

    def test_release_restart_leaves_a_kept_child_for_the_next_daemon(self):
        a, b = "a" * 40, "b" * 40
        self.runtime(a)
        self.table(children=[{"name": "k", "cmd": ["/bin/sleep", "300"], "keep_on_restart": True},
                             {"name": "n", "cmd": ["/bin/sleep", "301"]}])
        p = self.start()
        kpid = until(10, lambda: self.child("k").get("pid"))
        npid = until(10, lambda: self.child("n").get("pid"))
        self.assertTrue(kpid and npid)
        self.runtime(b)
        put(os.path.join(self.d, "db", "update-restart.json"), {"to": b})
        p.wait(timeout=30)
        self.assertTrue(fns.pid_alive(kpid), "the kept child went down with the daemon's release restart")
        self.assertFalse(fns.pid_alive(npid), "a child without keep_on_restart was left running")
        self.assertEqual(self.child("k").get("pid"), kpid, "the kept child's pid was not left for the next daemon")
        self.start()
        self.assertTrue(until(10, lambda: (self.state().get("supervisor") or {}).get("starts") == 2))
        time.sleep(0.5)
        self.assertEqual(self.child("k")["pid"], kpid, "the next daemon did not adopt the kept child")
        self.assertEqual(self.child("k").get("restarts") or 0, 0)
        self.assertIn("left running (pid %d)" % kpid, open(os.path.join(self.d, "sup.err")).read())

    def test_reload_starts_the_new_copy_before_the_old_one_goes(self):
        r = os.path.join(self.d, "lib")
        os.makedirs(r)
        pids = os.path.join(self.d, "pids")
        # each copy books itself; an old one goes ~1 s after a newer one came (its drain)
        sh = self.script("h.sh", 'echo "$$ ${FLEET_CRED_HANDOFF:-}" >> %s\n'
                                 'while sleep 0.1; do [ "$(tail -1 %s | cut -d" " -f1)" = "$$" ] '
                                 '|| { sleep 1; exit 0; }; done\n' % (pids, pids))
        self.table(children=[{"name": "h", "cmd": [sh], "reload": r, "handoff": True,
                              "env": {"FLEET_CRED_HANDOFF": "1"}}])
        self.start()
        pid1 = until(10, lambda: self.child("h").get("pid"))
        self.assertTrue(pid1)
        put(os.path.join(r, "fleet-cred-proxy.py"), "new bytes\n")
        pid2 = self.new_pid("h", pid1)
        self.assertTrue(pid2, "the reload started no new copy")
        self.assertTrue(fns.pid_alive(pid1), "the old copy was stopped before the new one took over")
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid1)), "the old copy never went")
        log = os.path.join(self.d, "sup.err")
        self.assertTrue(until(5, lambda: "pid %d drained and exited" % pid1 in open(log).read()))
        self.assertEqual([l.split()[1:] for l in open(pids).read().splitlines()], [["1"], ["1"]],
                         "the handoff switch did not reach the child")
        self.assertTrue(fns.pid_alive(pid2))
        self.assertEqual(self.child("h").get("restarts") or 0, 0, "the old copy's exit counted as a death")

    def test_a_daemon_restarted_mid_drain_still_books_the_old_copy(self):
        # T640: the draining list lived in memory only — a release restart while the
        # old copy drained lost it, and its «drained and exited» line never came
        a, b = "a" * 40, "b" * 40
        self.runtime(a)
        r = os.path.join(self.d, "lib")
        os.makedirs(r)
        pids = os.path.join(self.d, "pids")
        gate = os.path.join(self.d, "go")
        # an old copy drains until the test says it may go (the gate file)
        sh = self.script("h.sh", 'echo "$$" >> %s\n'
                                 'while sleep 0.1; do [ "$(tail -1 %s)" = "$$" ] '
                                 '|| { while [ ! -e %s ]; do sleep 0.1; done; exit 0; }; done\n' % (pids, pids, gate))
        self.table(children=[{"name": "h", "cmd": [sh], "reload": r, "handoff": True, "keep_on_restart": True}])
        p = self.start()
        pid1 = until(10, lambda: self.child("h").get("pid"))
        self.assertTrue(pid1)
        put(os.path.join(r, "fleet-cred-proxy.py"), "new bytes\n")
        self.assertTrue(self.new_pid("h", pid1), "the reload started no new copy")
        booked = until(10, lambda: [x["pid"] for x in self.state().get("retiring") or []])
        self.assertEqual(booked, [pid1], "the draining copy was not booked in state.json")
        self.runtime(b)
        put(os.path.join(self.d, "db", "update-restart.json"), {"to": b})
        p.wait(timeout=30)
        self.assertTrue(fns.pid_alive(pid1), "the draining copy went down with the daemon's restart")
        self.assertEqual([x["pid"] for x in self.state().get("retiring") or []], [pid1],
                         "the restart dropped the draining copy's booking")
        self.start()
        log = os.path.join(self.d, "sup.err")
        self.assertTrue(until(10, lambda: "pid %d still draining since an earlier daemon" % pid1 in open(log).read()),
                        "the next daemon did not read the booking back")
        put(gate, "")
        self.assertTrue(until(10, lambda: "pid %d drained and exited" % pid1 in open(log).read()),
                        "no «drained and exited» line once the old copy went")
        self.assertTrue(until(10, lambda: not self.state().get("retiring")), "the booking was never cleared")

    def test_a_booked_copy_gone_before_the_daemon_came_up_is_said_and_dropped(self):
        st = self.state()
        dead = subprocess.Popen(["/bin/sleep", "0"])
        dead.wait()
        st["retiring"] = [{"name": "h", "pid": dead.pid, "since": time.time() - 5, "cmd": "/bin/sleep 300"}]
        put(os.path.join(self.d, "db", "state.json"), st)
        self.table(children=[])
        self.start()
        log = os.path.join(self.d, "sup.err")
        self.assertTrue(until(10, lambda: "pid %d drained and exited (before this daemon came up" % dead.pid
                              in open(log).read()))
        self.assertTrue(until(10, lambda: not self.state().get("retiring")))


class E_Status(Sandbox):
    def test_check_codes_and_lines(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}, {"name": "later", "cmd": [], "note": "C5"}],
                   tasks=[{"name": "t", "cmd": ["/bin/bash", sh]}, {"name": "acct", "scope": "account", "note": "C4"}])
        self.assertEqual(self.run_sup("status", "--check").returncode, 2)
        p = self.start()
        until(10, lambda: self.task("t").get("result") == "ok")
        r = self.run_sup("status")
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].startswith("supervisor  ok"), r.stdout)
        self.assertTrue(any(l.startswith("child  c ") and "running pid" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("child  later") and "not yet (C5)" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("task   t ") and " ok rc=0" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("task   acct") and "deferred" in l for l in lines), r.stdout)
        self.assertTrue(any(l.startswith("sweep") for l in lines), r.stdout)
        self.assertEqual(self.run_sup("status", "--check").returncode, 0)
        js = json.loads(self.run_sup("status", "--json").stdout)
        self.assertEqual(js["health"], 0)
        p.kill()
        p.wait()
        r = self.run_sup("status", "--check")
        self.assertEqual(r.returncode, 1)
        self.assertIn("DOWN", r.stdout)
        # issue #3100: launchd restarted it, the new one never wrote a heartbeat —
        # alive and silent is WEDGED, not DOWN (another root's daemon is not ours)
        ps = os.path.join(self.d, "ps.txt")
        put(ps, "4242 1 /usr/bin/python3 -I /elsewhere/current/bin/fleet-node-supervisor.py run\n")
        seam = {"FLEET_NODE_PS_CMD": ps, "FLEET_NODE_HEARTBEAT_STALE": "0"}
        self.assertEqual(self.run_sup("status", "--check", env=seam).returncode, 1)
        with open(ps, "a") as f:
            f.write("4343 1 /usr/bin/python3 -I %s/bin/fleet-node-supervisor.py run\n" % self.env["FLEET_NODE_RUNTIME"])
            f.write("4444 4343 /usr/bin/python3 -I %s/bin/fleet-node-supervisor.py run\n" % self.env["FLEET_NODE_RUNTIME"])
        r = self.run_sup("status", "--check", env=seam)
        self.assertEqual(r.returncode, 5, r.stdout)
        self.assertIn("WEDGED — pid 4343 alive but it never wrote a heartbeat", r.stdout)


class F_Trust(Sandbox):
    def test_root_trust(self):
        sh = self.script("w.sh", "exit 0\n")
        self.assertTrue(fns.trusted(sh, as_root=False))
        self.assertFalse(fns.trusted(sh, as_root=True), "a login-owned script passed the root check")
        self.assertFalse(fns.trusted(os.path.join(self.d, "nope"), as_root=False))
        self.assertTrue(fns.trusted("/bin/sh", as_root=True))

    def test_install_writes_plist(self):
        os.makedirs(os.path.join(self.d, "rt", "bin"))
        shutil.copy(SUP, os.path.join(self.d, "rt", "bin", "fleet-node-supervisor.py"))
        r = self.run_sup("install")
        self.assertEqual(r.returncode, 0, r.stderr)
        pl = plistlib.load(open(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.node.plist"), "rb"))
        self.assertEqual(pl["Label"], "com.claude-fleet.node")
        self.assertTrue(pl["KeepAlive"])
        self.assertEqual(pl["ProgramArguments"][-1], "run")
        self.assertTrue(pl["ProgramArguments"][2].startswith(os.path.join(self.d, "rt")))
        self.assertFalse(pl["StandardErrorPath"].startswith("/Users/"))
        self.assertEqual(self.run_sup("uninstall").returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.claude-fleet.node.plist")))


class G_DefaultTable(Sandbox):
    def test_linux_node_agent_starts_with_no_login(self):
        """#4010: a Linux machine that opens its own logins runs its node program
        with none — the hub's first create comes down that very link; with account
        ops off it waits for a logins/*.env as before; a Mac's table is unchanged."""
        db = os.path.join(self.d, "db")
        os.makedirs(os.path.join(db, "logins"))
        menv = os.path.join(db, "machine.env")
        with mock.patch.dict(os.environ), mock.patch.object(fns, "MAC", fns.MAC):
            os.environ["FLEET_NODE_STATE"] = db
            os.environ.pop("FLEET_NODE_TABLE", None)

            def agent():
                return [x for x in fns.default_table(fns.Paths())["children"] if x["name"] == "node-agent"][0]
            fns.MAC = True
            self.assertTrue(all(isinstance(r, str) for r in agent()["requires"]), "a Mac's requirements unchanged")
            fns.MAC = False
            put(menv, "CCQUOTA_TOKEN=t\n")
            self.assertTrue(fns.requires_missing(agent()), "account ops off: waits for a login")
            put(menv, "CCQUOTA_TOKEN=t\nFLEET_NODE_ACCOUNT_OPS=1\n")
            self.assertEqual(fns.requires_missing(agent()), [], "account ops on: runs with none")
            put(menv, "CCQUOTA_TOKEN=t\nFLEET_NODE_ACCOUNT_OPS=0\n")
            open(os.path.join(db, "logins", "alice.env"), "w").close()
            self.assertEqual(fns.requires_missing(agent()), [], "a login: runs, as ever")

    def test_default_table(self):
        e = dict(self.env)
        del e["FLEET_NODE_TABLE"]
        with mock.patch.dict(os.environ, {k: v for k, v in e.items() if k.startswith("FLEET_NODE_")}):
            t = fns.default_table(fns.Paths())
        names = [x["name"] for x in t["tasks"]]
        self.assertEqual(names, ["diskguard", "memguard", "trial-guard", "orphans", "shared-dirs", "machine-reading"]
                         + (["spotlight", "wallpaper"] if fns.MAC else []) + ["update", "credsep-enforce"])
        by = {x["name"]: x for x in t["tasks"]}
        # #4607: every fleet login separated by the daemon itself, root's job
        self.assertEqual(by["credsep-enforce"]["cmd"][-2:], ["machine", "enforce"])
        self.assertTrue(by["credsep-enforce"]["cmd"][-3].endswith("/fleet-credsep.py"))
        self.assertNotIn("seat", by["credsep-enforce"], "root's job, never the seat's")
        # WACK C4: the trial guard is root's too (the machine's token, the core's op)
        self.assertEqual(by["trial-guard"]["cmd"][-1], "tick")
        self.assertTrue(by["trial-guard"]["cmd"][-2].endswith("/fleet-trial-guard.py"))
        self.assertNotIn("seat", by["trial-guard"], "root's job, never the seat's")
        self.assertIsNone(t["account"], "the account table is the runtime's templates")
        self.assertEqual(by["diskguard"]["env"]["FLEET_ORPHAN_CPU_PCT"], "0", "orphans would run twice")
        self.assertEqual(by["orphans"]["env"]["FLEET_ORPHAN_ALL_USERS"], "1")
        for x in t["tasks"]:
            for a in x.get("cmd", []):
                if a.endswith(".sh") or a.endswith(".py"):
                    self.assertTrue(a.startswith(os.path.join(self.d, "rt", "bin")), a)
                    self.assertTrue(os.path.exists(os.path.join(BIN, os.path.basename(a))), a)
        self.assertEqual([c["name"] for c in t["children"]], ["cred-proxy-shared", "node-agent"])
        # the status of the default table on an empty machine is readable without root
        r = subprocess.run([sys.executable, SUP, "status"], env=e, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not installed", r.stdout)
        self.assertIn("update", r.stdout)       # the updater is a task of the default table (#2334)
        # C5 (#2333): the one node program, from the root runtime, waiting until
        # the machine has its token and its logins directory.
        na = t["children"][1]
        self.assertEqual(na["cmd"][0], os.path.join(self.d, "rt", "bin", "ccquota"))
        self.assertEqual(na["cmd"][1:3], ["agent", "--machine"])
        self.assertIn("node-agent", r.stdout)
        self.assertIn("waiting", r.stdout)
        self.assertIn("machine.env", r.stdout)
        self.assertIn(os.path.join("logins", "*.env"), r.stdout, "an empty logins/ must not count (#2421)")

    def test_all_users_orphans(self):
        dg = open(os.path.join(BIN, "fleet-diskguard.sh")).read()
        self.assertIn('[ "${FLEET_ORPHAN_ALL_USERS:-0}" = 1 ] && me=\'*\'', dg)
        self.assertIn('if (me!="*" && $3!=me) next;', dg)
        dgp = os.path.join(BIN, "fleet-diskguard.sh")
        self.assertEqual(subprocess.run(["bash", "-n", dgp]).returncode, 0, "fleet-diskguard.sh no longer parses")
        r = subprocess.run(["bash", dgp, "--orphans"], env=dict(os.environ, FLEET_ORPHAN_ALL_USERS="1"),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("syntax error", r.stderr)


FAKE_LC = """#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5
           # slow: launchd still tears it down for <n> more prints (issue #2336)
           if [ -e "$d/slow/$l" ]; then cp "$d/slow/$l" "$d/tearing-$l"; else rm -f "$d/loaded/$l"; fi ;;
  bootstrap) l=$(basename "$3" .plist); [ -e "$d/tearing-$l" ] && exit 5
             # busy: launchd refuses <n> more bootstraps of it (still tearing the old copy down)
             if [ -e "$d/busy/$l" ]; then n=$(cat "$d/busy/$l"); if [ "$n" -gt 0 ]; then echo $((n - 1)) >"$d/busy/$l"; exit 5; fi; fi
             touch "$d/loaded/$l" ;;
  print) l="${2##*/}"
         if [ -e "$d/tearing-$l" ]; then n=$(cat "$d/tearing-$l"); n=$((n - 1))
           if [ "$n" -le 0 ]; then rm -f "$d/tearing-$l" "$d/loaded/$l"; exit 1; fi
           echo "$n" >"$d/tearing-$l"; exit 0; fi
         [ -e "$d/loaded/$l" ] ;;
esac
"""


class H_Accounts(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.lc = os.path.join(self.d, "lc")
        for x in ("loaded", "stuck", "slow", "busy"):
            os.makedirs(os.path.join(self.lc, x))
        lcs = os.path.join(self.d, "launchctl")
        put(lcs, FAKE_LC, 0o755)
        self.passwd({w: os.path.join(self.d, "Users", w) for w in ("alice", "bob")},
                    os.path.join(".claude", "fleet", "bin"), os.path.join("Library", "LaunchAgents"))
        self.env.update({"FLEET_NODE_LAUNCHCTL": lcs, "FAKE_LC": self.lc,
                         "FLEET_NODE_BOOTOUT_WAIT": "2"})

    def home(self, who):
        return os.path.join(self.d, "Users", who)

    def acct_script(self, who, name, body):
        p = os.path.join(self.home(who), ".claude", "fleet", "bin", name)
        put(p, "#!/bin/bash\n" + body, 0o755)

    def plist(self, path, label):
        with open(path, "wb") as f:
            plistlib.dump({"Label": label, "ProgramArguments": ["/bin/true"]}, f)
        open(os.path.join(self.lc, "loaded", label), "w").close()

    def acct_table(self, *units):
        put(self.env["FLEET_NODE_TABLE"], {"children": [], "tasks": [], "account": list(units)})

    def lclog(self):
        return slurp(os.path.join(self.lc, "log"))

    def test_table_is_the_templates(self):
        os.makedirs(os.path.join(self.d, "rt"))
        os.symlink(os.path.join(os.path.dirname(BIN), "launchd"), os.path.join(self.d, "rt", "launchd"))
        with mock.patch.dict(os.environ, {k: v for k, v in self.env.items() if k.startswith("FLEET_NODE_")}):
            units = {u["name"]: u for u in fns.account_units(fns.Paths())}
        import glob as g
        tmpl = set(os.path.basename(x)[len("com.claude-fleet."):-len(".plist.tmpl")]
                   for x in g.glob(os.path.join(os.path.dirname(BIN), "launchd", "*.plist.tmpl")))
        self.assertEqual(set(units) - set(fns.ACCOUNT_BUILTIN), tmpl - {"memguard"},
                         "every template but the machine's is an account unit")
        # no per-login proxy (issue #4674): its template is gone; cred-relay is built in
        self.assertNotIn("cred-proxy", units)
        self.assertEqual(units["cred-relay"]["argv"][-1], "relay-tick")
        # the autofill dispatcher's template is gone (issue #3120): no account
        # runs it, and nothing keeps a unit the runtime no longer carries
        self.assertNotIn("dispatch", units)
        for need in ("ledger-watch", "reconcile", "cleanup",
                     "worktree-autoclean", "spinner", "collect", "install-sync", "base-sync"):
            self.assertIn(need, units)
        # the GitHub daemons left with issue #4899
        for gone in ("issue-bridge", "pr-refresh", "webhook"):
            self.assertNotIn(gone, units)
        self.assertTrue(units["spinner"].get("keepalive"))
        self.assertEqual(units["install-sync"]["every"], 1800)
        self.assertEqual(units["worktree-autoclean"]["every"], 3600)
        self.assertEqual(units["spinner"]["env"].get("SPIN_INTERVAL"), "0.12")
        self.assertEqual(units["diskguard"]["env"]["FLEET_ORPHAN_CPU_PCT"], "0", "orphans would run twice")
        e = fns.account_entry(units["base-sync"], "alice", (501, 20, "/Users/alice"), "/opt/homebrew")
        self.assertEqual(e["script"], "/Users/alice/.claude/fleet/bin/fleet-base-sync.sh")
        self.assertTrue(e["env"]["PATH"].startswith("/Users/alice/.local/bin:/opt/homebrew/bin"))
        self.assertEqual(e["env"]["FLEET_CONF_DIR"], "/Users/alice/.config/claude-fleet")
        self.assertEqual(e["cmd"][4], "/dev/null")
        self.assertEqual(e["cmd"][5], "/Users/alice/.config/claude-fleet/logs/base-sync.launchd.log")   # the login's records (#4668)
        self.assertNotIn("__HOME__", json.dumps(e))
        # The locale (issue #3514): the plists say en_US.UTF-8, which a slim Linux
        # image lacks — there every account unit gets C.UTF-8; macOS keeps its own.
        unit = dict(units["base-sync"], env=dict(units["base-sync"].get("env") or {},
                                                 LANG="en_US.UTF-8", LC_ALL="en_US.UTF-8"))
        for plat, want in (("linux", "C.UTF-8"), ("darwin", "en_US.UTF-8")):
            with mock.patch.object(fns, "NODE_LANG", "en_US.UTF-8" if plat == "darwin" else "C.UTF-8"):
                e = fns.account_entry(unit, "alice", (501, 20, "/Users/alice"), "/opt/homebrew")
                self.assertEqual((e["env"]["LANG"], e["env"]["LC_ALL"]), (want, want), plat)

    def test_shared_proxy_login_keeps_no_resident_launcher(self):
        # issue #4674: no login runs a proxy of its own — the account table has no
        # `cred-proxy` (an old table's row is None, never run); a login on the
        # machine's shared proxy has its relay pass kept by `cred-relay`, run only
        # when the shared proxy asks (issue #3561: no clock); a login not on it has
        # no `cred-relay` either
        old = {"name": "cred-proxy", "keepalive": True, "out": "/dev/null", "err": "/dev/null",
               "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/fleet-cred-proxy.sh", "run"], "env": {}}
        unit = fns.cred_relay_unit()
        self.assertIn("cred-relay", fns.ACCOUNT_BUILTIN)
        for who, rec in (("alice", {"separated": True, "shared": True, "run": "/var/run/fleet-cred/.shared"}),
                         ("bob", None)):
            conf = os.path.join(self.home(who), ".config", "claude-fleet")
            os.makedirs(conf, exist_ok=True)
            if rec:
                put(os.path.join(conf, "credsep.json"), rec)
        for who in ("alice", "bob"):
            self.assertIsNone(fns.account_unit_for(old, self.home(who)), "no per-login proxy, for anyone")
        a = fns.account_entry(fns.account_unit_for(unit, self.home("alice")), "alice",
                              (501, 20, self.home("alice")), "/opt/homebrew")
        self.assertNotIn("keepalive", a, "a shared-proxy login keeps no resident launcher")
        self.assertEqual(a["name"], "alice/cred-relay")
        self.assertNotIn("every", a, "cred-relay runs on request, never on a clock (#3561)")
        self.assertEqual(a["want"], "/var/run/fleet-cred/.shared/relay-want.alice")
        self.assertEqual(a["cmd"][-1], "relay-tick")
        # due only on a request newer than the last one run
        want = os.path.join(self.home("alice"), "relay-want.alice")
        a["want"] = want
        fake = type("S", (), {"state": {"tasks": {}}})()
        due = lambda: fns.Supervisor.task_due(fake, a, time.time())
        self.assertFalse(due(), "no request, not due — however long it has been")
        put(want, "used 1\n")
        self.assertTrue(due(), "a request is due at once")
        fake.state["tasks"][a["name"]] = {"want_seen": fns.want_stamp(want), "last_start": 0}
        self.assertFalse(due(), "a request already run is not run again")
        os.utime(want, ns=(fns.want_stamp(want) + 10 ** 9, fns.want_stamp(want) + 10 ** 9))
        self.assertTrue(due(), "a new request is due")
        self.assertNotIn("want", unit, "the table's unit is not changed in place")
        self.assertIsNone(fns.account_unit_for(unit, self.home("bob")), "not on the shared proxy: no cred-relay")
        # an unreadable record is not shared: still none
        put(os.path.join(self.home("bob"), ".config", "claude-fleet", "credsep.json"), "{not json")
        self.assertIsNone(fns.account_unit_for(unit, self.home("bob")))

    def test_runs_as_account_and_isolated(self):
        self.acct_script("alice", "probe.sh",
                         'echo "uid=$(id -u) home=$HOME user=$USER conf=$FLEET_CONF_DIR pwd=$(pwd -P) '
                         'path=$PATH acct=$FLEET_NODE_ACCOUNT"\n')
        self.acct_script("bob", "probe.sh", "echo bob-broke >&2; exit 4\n")
        self.acct_script("alice", "keep.sh", "exec sleep 300\n")
        self.acct_table(
            {"name": "probe", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/probe.sh"], "every": 0.2,
             "env": {"PATH": "__HOME__/.local/bin:/usr/bin:/bin"},
             "out": "__HOME__/probe.out", "err": "__HOME__/probe.err"},
            {"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": True})
        for who in ("alice", "bob"):
            r = self.run_sup("account", "adopt", who)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.start()
        out = os.path.join(self.home("alice"), "probe.out")
        self.assertTrue(until(10, lambda: (self.task("alice/probe").get("runs") or 0) >= 3
                              and (self.task("bob/probe").get("runs") or 0) >= 3))
        line = open(out).read().splitlines()[-1]
        h = os.path.realpath(self.home("alice"))
        self.assertIn("uid=%d " % os.getuid(), line)
        self.assertIn("home=%s " % self.home("alice"), line)
        self.assertIn("user=alice ", line)
        self.assertIn("conf=%s/.config/claude-fleet " % self.home("alice"), line)
        self.assertIn("pwd=%s " % h, line)
        self.assertIn("path=%s/.local/bin:" % self.home("alice"), line)
        self.assertIn("acct=alice", line)
        self.assertIn("bob-broke", open(os.path.join(self.home("bob"), "probe.err")).read())
        # one account's failure is its own
        self.assertEqual(self.task("bob/probe")["rc"], 4)
        # a 0.2 s task reads `running` half the time: wait for a finished run
        self.assertTrue(until(5, lambda: self.task("alice/probe").get("result") == "ok"), self.task("alice/probe"))
        self.assertTrue(until(5, lambda: self.child("alice/keep").get("pid")), "alice's KeepAlive unit never started")
        self.assertEqual(self.child("bob/keep").get("status"), "missing %s/.claude/fleet/bin/keep.sh" % self.home("bob"))
        st = self.run_sup("status").stdout
        self.assertIn("account alice             2/2 ok", st)
        self.assertIn("account bob", st)
        self.assertIn("probe failed", st)
        # no root-owned log in a login's directory: the task log is the daemon's own
        self.assertTrue(os.path.exists(os.path.join(self.d, "log", "accounts", "alice.log")))
        # release: our copies stop, the account is no longer run
        kpid = self.child("alice/keep")["pid"]
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        # release waits for execution to end, not the daemon's next reap.
        # kill(0) still succeeds for a zombie (#4044); Z_ForgetZombie pins
        # live/zombie/gone and unreadable-ps behavior without a timing retry.
        self.assertFalse(fns.pid_alive(kpid) and kpid not in fns._zombies([kpid]),
                         "release left the account's KeepAlive unit running")
        runs = self.task("alice/probe")["runs"]
        time.sleep(0.8)
        self.assertLessEqual(self.task("alice/probe")["runs"], runs + 1, "a released account still runs")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("account", "manages", "bob").returncode, 0)

    def test_account_dev_consent(self):
        """issue #2779: `account dev <login> on|off` is root's consent to the
        login's developer mode — only for a managed login, read back by the bare form."""
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        self.assertEqual(self.run_sup("account", "dev", "alice").returncode, 1)
        self.assertEqual(self.run_sup("account", "dev", "bob", "on").returncode, 1, "bob is not managed")
        r = self.run_sup("account", "dev", "alice", "on")
        self.assertEqual(r.returncode, 0, r.stderr)
        acc = json.load(open(os.path.join(self.d, "db", "accounts.json")))
        self.assertTrue(acc["alice"].get("dev") and acc["alice"].get("managed"))
        self.assertIn("alice: dev on since", self.run_sup("account", "dev", "alice").stdout)
        self.assertEqual(self.run_sup("account", "dev", "alice", "off").returncode, 0)
        self.assertNotIn("dev", json.load(open(os.path.join(self.d, "db", "accounts.json")))["alice"])
        self.assertEqual(self.run_sup("account", "dev", "alice", "maybe").returncode, 2)

    def test_needs_root_for_another_uid(self):
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        pw["carol"] = {"uid": os.getuid() + 1, "gid": os.getgid(), "home": self.home("alice")}
        pw["toor"] = {"uid": 0, "gid": 0, "home": self.home("alice")}
        json.dump(pw, open(self.env["FLEET_NODE_PASSWD"], "w"))
        self.acct_script("alice", "p.sh", "exit 0\n")
        self.acct_table({"name": "p", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/p.sh"], "every": 60})
        for who in ("carol", "toor"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertTrue(self.task("carol/p")["result"].startswith("needs root"))
        self.assertEqual(self.task("toor/p")["result"], "refused — uid 0")
        self.assertFalse(self.task("carol/p").get("runs"))

    def test_adopt_moves_old_services_and_release_restores(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.plist(os.path.join(la, "com.claude-fleet.spinner.plist"), "com.claude-fleet.spinner")
        self.plist(os.path.join(dd, "com.claude-fleet.alice.collect.plist"), "com.claude-fleet.alice.collect")
        self.plist(os.path.join(dd, "com.claude-fleet.bob.collect.plist"), "com.claude-fleet.bob.collect")
        self.plist(os.path.join(dd, "com.claude-fleet.node.plist"), "com.claude-fleet.node")
        os.chmod(os.path.join(la, "com.claude-fleet.spinner.plist"), 0o640)
        self.acct_table()
        self.assertIn("would boot out", self.run_sup("account", "adopt", "alice", "--dry-run").stdout)
        self.assertTrue(os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("3 service(s)", r.stdout)
        self.assertEqual(sorted(os.listdir(la)), [], "a per-account LaunchAgent is still there")
        self.assertFalse(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.bob.collect.plist")), "bob's was touched")
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.node.plist")))
        log = self.lclog()
        self.assertIn("bootout gui/%d/com.claude-fleet.dispatch" % os.getuid(), log)
        self.assertIn("bootout system/com.claude-fleet.alice.collect", log)
        self.assertNotIn("bob", log)
        self.assertEqual(sorted(os.listdir(os.path.join(self.lc, "loaded"))),
                         ["com.claude-fleet.bob.collect", "com.claude-fleet.node"])
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 0)
        lst = self.run_sup("attic", "list").stdout
        self.assertEqual(lst.count("(account alice, kept)"), 3, lst)
        # kept past the attic's days: a purge never takes an adopted account's way back
        self.age_attic(30)
        self.assertIn("purged 0", self.run_sup("attic", "purge").stdout)
        # one command back
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("3 service(s) put back", r.stdout)
        self.assertEqual(sorted(os.listdir(la)), ["com.claude-fleet.dispatch.plist", "com.claude-fleet.spinner.plist"])
        self.assertEqual(os.stat(os.path.join(la, "com.claude-fleet.spinner.plist")).st_mode & 0o777, 0o640)
        self.assertTrue(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertIn("bootstrap system %s" % os.path.join(dd, "com.claude-fleet.alice.collect.plist"), self.lclog())
        self.assertIn("com.claude-fleet.dispatch", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_forget_stops_tasks_and_never_loads_back(self):
        # issue #2924: a login being deleted — the daemon lets go of it and loads nothing back
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.acct_script("alice", "keep.sh", "exec sleep 300\n")
        self.acct_table({"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": True})
        for who in ("alice", "bob"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.start()
        self.assertTrue(until(5, lambda: self.child("alice/keep").get("pid")), "alice's KeepAlive unit never started")
        kpid = self.child("alice/keep")["pid"]
        r = self.run_sup("account", "forget", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 service(s) left in the attic", r.stdout)
        # ended is ended, reaped or not (#4044): the daemon reaps its child on its next tick
        self.assertFalse(fns.pid_alive(kpid) and kpid not in fns._zombies([kpid]),
                         "forget left the account's KeepAlive unit running")
        a = json.load(open(os.path.join(self.d, "db", "accounts.json")))
        self.assertNotIn("alice", a)
        self.assertTrue(a["bob"]["managed"])
        self.assertEqual(os.listdir(la), [], "forget put a service back")
        self.assertNotIn("bootstrap", self.lclog())
        lst = self.run_sup("attic", "list").stdout
        self.assertNotIn("kept", lst)
        self.age_attic(30)
        self.assertIn("purged 1", self.run_sup("attic", "purge").stdout)
        r = self.run_sup("account", "forget", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("nothing", r.stdout)

    def test_release_of_a_gone_login_loads_nothing(self):
        # issue #2924: release of a login no longer on the machine put its node
        # agent's LaunchDaemon back, loaded for nobody — now it only forgets it
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        self.plist(os.path.join(dd, "com.claude-fleet.alice.collect.plist"), "com.claude-fleet.alice.collect")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        pw = json.load(open(self.env["FLEET_NODE_PASSWD"]))
        del pw["alice"]
        json.dump(pw, open(self.env["FLEET_NODE_PASSWD"], "w"))
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not a login on this machine", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(dd, "com.claude-fleet.alice.collect.plist")))
        self.assertNotIn("bootstrap", self.lclog())
        self.assertNotIn("alice", json.load(open(os.path.join(self.d, "db", "accounts.json"))))

    def test_slow_unload_is_waited_for(self):
        # mac-a (issue #2336): a KeepAlive daemon is still loaded right after its bootout
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        for u in ("collect", "webhook"):
            self.plist(os.path.join(dd, "com.claude-fleet.alice.%s.plist" % u), "com.claude-fleet.alice.%s" % u)
        put(os.path.join(self.lc, "slow", "com.claude-fleet.alice.webhook"), "3\n")
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("did not unload", r.stderr)
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 0)

    def test_put_back_waits_for_the_teardown(self):
        # the put-back's bootstrap of a job launchd is still tearing down is retried
        dd = self.env["FLEET_NODE_DAEMON_DIR"]
        for u in ("a-webhook", "b-collect"):
            self.plist(os.path.join(dd, "com.claude-fleet.alice.%s.plist" % u), "com.claude-fleet.alice.%s" % u)
        put(os.path.join(self.lc, "busy", "com.claude-fleet.alice.a-webhook"), "2\n")
        open(os.path.join(self.lc, "stuck", "com.claude-fleet.alice.b-collect"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        loaded = os.listdir(os.path.join(self.lc, "loaded"))
        self.assertIn("com.claude-fleet.alice.a-webhook", loaded, "the put-back left the slow one unloaded")

    def test_stuck_service_puts_everything_back(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        for u in ("a-cleanup", "b-dispatch", "c-sleep"):
            self.plist(os.path.join(la, "com.claude-fleet.%s.plist" % u), "com.claude-fleet.%s" % u)
        open(os.path.join(self.lc, "stuck", "com.claude-fleet.b-dispatch"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("did not unload", r.stderr)
        self.assertEqual(len(os.listdir(la)), 3, "a half migration left the account without services")
        self.assertEqual(len(os.listdir(os.path.join(self.lc, "loaded"))), 3, "a booted-out service was not reloaded")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_expected_accounts_narrow(self):
        self.acct_script("alice", "p.sh", "exit 0\n")
        self.acct_script("bob", "p.sh", "exit 0\n")
        self.acct_table({"name": "p", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/p.sh"], "every": 60})
        for who in ("alice", "bob"):
            self.run_sup("account", "adopt", who)
        put(os.path.join(self.d, "db", "expected.json"), {"accounts": ["alice", {"name": "dave"}]})
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.assertEqual(self.task("alice/p")["result"], "ok")
        self.assertFalse(self.task("bob/p"), "an account the expected state drops still ran")
        self.assertIn("not in expected.json", self.run_sup("status").stdout)

    # -- the login's own node agent (#2387) -------------------------------------
    def agent_plist(self, who, env, gui=False):
        if gui:
            path, label = os.path.join(self.home(who), "Library", "LaunchAgents", "com.ccquota.agent.plist"), \
                "com.ccquota.agent"
        else:
            path, label = os.path.join(self.env["FLEET_NODE_DAEMON_DIR"], "com.ccquota.agent.%s.plist" % who), \
                "com.ccquota.agent.%s" % who
        with open(path, "wb") as f:
            plistlib.dump({"Label": label, "ProgramArguments": ["/bin/true"], "EnvironmentVariables": env}, f)
        open(os.path.join(self.lc, "loaded", label), "w").close()
        return path

    def node_env(self, path, body):
        put(path, body, 0o600)

    def login_env(self, who):
        p = os.path.join(self.d, "db", "logins", who + ".env")
        if not os.path.exists(p):
            return None, None
        kv = {}
        for line in open(p):
            if line.strip() and not line.startswith("#"):
                k, _, v = line.rstrip("\n").partition("=")
                kv[k] = v
        return kv, os.stat(p).st_mode & 0o777

    def test_adopt_moves_node_agent_and_release_restores(self):
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1",
                                        "FLEET_CONF_DIR": conf, "PATH": "/usr/bin", "HOME": "/nope"})
        self.node_env(os.path.join(conf, "node.env"),
                      "# x\nCCQUOTA_HUB_URL=https://hub.invalid\nexport CCQUOTA_TOKEN='tok-alice-1'\nFLEET_X=1\n")
        self.agent_plist("bob", {"CCQUOTA_TOKEN": "tok-bob"})
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice", "--dry-run")
        self.assertIn("would boot out system/com.ccquota.agent.alice", r.stdout)
        self.assertIn("logins/alice.env (0600) with CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_CONF_DIR", r.stdout)
        self.assertNotIn("tok-alice", r.stdout + r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None), "a dry run wrote the env")
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("tok-alice", r.stdout + r.stderr, "adopt printed the token")
        kv, mode = self.login_env("alice")
        self.assertEqual(mode, 0o600)
        self.assertEqual(kv, {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1",
                              "FLEET_CONF_DIR": conf, "CCQUOTA_TOKEN": "tok-alice-1"})
        self.assertEqual(os.stat(os.path.join(self.d, "db", "logins")).st_mode & 0o777, 0o700)
        self.assertFalse(os.path.exists(ap), "the old agent is still installed")
        self.assertNotIn("com.ccquota.agent.alice", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertIn("com.ccquota.agent.bob", os.listdir(os.path.join(self.lc, "loaded")), "bob's agent was touched")
        self.assertIn("(account alice, kept)", self.run_sup("attic", "list").stdout)
        # adopting again changes nothing
        self.assertIn("already managed", self.run_sup("account", "adopt", "alice").stdout)
        r = self.run_sup("account", "release", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None), "release left logins/alice.env")
        self.assertTrue(os.path.exists(ap))
        self.assertIn("bootstrap system %s" % ap, self.lclog())
        self.assertIn("com.ccquota.agent.alice", os.listdir(os.path.join(self.lc, "loaded")))

    def test_agent_that_will_not_unload_puts_everything_back(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {"FLEET_CONF_DIR": conf})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-alice\n")
        open(os.path.join(self.lc, "stuck", "com.ccquota.agent.alice"), "w").close()
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("did not unload", r.stderr)
        self.assertEqual(self.login_env("alice"), (None, None))
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        self.assertIn("com.claude-fleet.dispatch", os.listdir(os.path.join(self.lc, "loaded")))
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)
        self.assertEqual(self.run_sup("attic", "list").stdout, "")

    def test_agent_with_no_token_moves_nothing(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        ap = self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid"})
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no CCQUOTA_TOKEN", r.stderr)
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))
        self.assertEqual(self.lclog(), "", "something was booted out")
        self.assertEqual(self.run_sup("account", "manages", "alice").returncode, 1)

    def cred_store(self, who, body, mode="shared"):
        """<who>'s credsep store (meta.json + a 0600 node.env holding <body>) -> the env naming it."""
        cred = os.path.join(self.d, "cred")
        put(os.path.join(cred, who, "meta.json"), {"login": who, "mode": mode})
        self.node_env(os.path.join(cred, who, "node.env"), body)
        return {"FLEET_CREDSEP_ROOT_BASE": cred, "FLEET_CREDSEP_RUN_BASE": "/run/fc"}

    def test_credsep_login_reads_the_store(self):
        for who, mode in (("alice", "shared"), ("bob", "own")):
            e = self.cred_store(who, "CCQUOTA_TOKEN=tok-%s\nCCQUOTA_HUB_URL=https://h\n" % who, mode)
            self.agent_plist(who, {"CCQUOTA_FLEET": "1"}, gui=(who == "bob"))
        # the login's own conf dir is not where a separated login's token is
        self.node_env(os.path.join(self.home("alice"), ".config", "claude-fleet", "node.env"), "CCQUOTA_TOKEN=wrong\n")
        self.acct_table()
        for who in ("alice", "bob"):
            r = self.run_sup("account", "adopt", who, env=e)
            self.assertEqual(r.returncode, 0, r.stderr)
        kv, _ = self.login_env("alice")
        self.assertEqual(kv["CCQUOTA_TOKEN"], "tok-alice")
        self.assertEqual(kv["CCQUOTA_FLEET_CRED_STORE"], "/run/fc/.shared/ctl.sock")
        kv, _ = self.login_env("bob")
        self.assertEqual(kv["CCQUOTA_FLEET_CRED_STORE"], "/run/fc/bob/ctl.sock")
        self.assertIn("bootout gui/%d/com.ccquota.agent" % os.getuid(), self.lclog())
        self.assertFalse(os.path.exists(os.path.join(self.home("bob"), "Library", "LaunchAgents",
                                                     "com.ccquota.agent.plist")))

    def test_recycled_login_with_a_kept_token_adopts_from_the_store(self):
        # issue #4195: a recycle kept the login's node token — no agent plist was
        # set up again (no join), the token is only in the credsep store — and
        # adopt serves it from there with nothing to boot out; no store token ⇒
        # nothing to adopt, as before
        e = self.cred_store("alice", "CCQUOTA_TOKEN=tok-kept\nCCQUOTA_HUB_URL=https://h\n")
        cred = e["FLEET_CREDSEP_ROOT_BASE"]
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("tok-kept", r.stdout + r.stderr, "adopt printed the token")
        kv, mode = self.login_env("alice")
        self.assertEqual(mode, 0o600)
        self.assertEqual(kv, {"CCQUOTA_TOKEN": "tok-kept", "CCQUOTA_HUB_URL": "https://h", "CCQUOTA_FLEET_CREDS": "1",
                              "CCQUOTA_FLEET_CRED_STORE": "/run/fc/.shared/ctl.sock"})
        self.assertNotIn("bootout", self.lclog(), "a kept token has no agent to boot out")
        self.assertIn("already managed", self.run_sup("account", "adopt", "alice", env=e).stdout)
        os.unlink(os.path.join(cred, "alice", "node.env"))
        self.run_sup("account", "forget", "alice", env=e)
        self.assertEqual(self.login_env("alice"), (None, None))
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(self.login_env("alice"), (None, None), "a store with no token was adopted")

    def test_store_login_leases_its_credentials(self):
        # issue #3276 (the Mac half of #3211): a login with a credential store
        # leases its accounts — node-join's node.env never says so, so the
        # login's settings must; a value the store already holds is kept, a
        # login with no store gets nothing; an older logins/<login>.env is
        # backfilled once, the other lines as they were
        stores = {"alice": "CCQUOTA_TOKEN=tok-alice\nCCQUOTA_FLEET_COMPUTE=0\n",
                  "bob": "CCQUOTA_TOKEN=tok-bob\nCCQUOTA_FLEET_CREDS=store-only\n"}
        for who, body in stores.items():
            e = self.cred_store(who, body)
            self.agent_plist(who, {"CCQUOTA_FLEET": "1"})
        self.acct_table()
        for who in ("alice", "bob"):
            r = self.run_sup("account", "adopt", who, env=e)
            self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.login_env("alice")[0].get("CCQUOTA_FLEET_CREDS"), "1")
        self.assertEqual(self.login_env("bob")[0].get("CCQUOTA_FLEET_CREDS"), "store-only")

        # an older adopt: alice's settings without the line, bob's own and
        # carol (no store) — only alice's is rewritten
        logins = os.path.join(self.d, "db", "logins")
        old = "CCQUOTA_FLEET=1\nCCQUOTA_FLEET_CRED_STORE=/run/fc/.shared/ctl.sock\nCCQUOTA_TOKEN=tok-alice\n"
        self.node_env(os.path.join(logins, "alice.env"), old)
        self.node_env(os.path.join(logins, "carol.env"), "CCQUOTA_TOKEN=tok-carol\n")
        past = time.time() - 600
        for who in ("alice", "bob", "carol"):
            os.utime(os.path.join(logins, who + ".env"), (past, past))
        with mock.patch.dict(os.environ):
            os.environ.update({k: v for k, v in self.env.items() if k.startswith("FLEET_")})
            os.environ.update(e)
            fixed = fns.logins_creds_backfill(fns.Paths())
            again = fns.logins_creds_backfill(fns.Paths(), settle=0)
        self.assertEqual(fixed, ["alice"])
        self.assertEqual(again, [], "a second pass rewrote again")
        kv = self.login_env("alice")[0]
        self.assertEqual(kv.get("CCQUOTA_FLEET_CREDS"), "1")
        self.assertEqual(kv.get("CCQUOTA_TOKEN"), "tok-alice")
        self.assertEqual(kv.get("CCQUOTA_FLEET_CRED_STORE"), "/run/fc/.shared/ctl.sock")
        self.assertEqual(self.login_env("bob")[0].get("CCQUOTA_FLEET_CREDS"), "store-only")
        self.assertNotIn("CCQUOTA_FLEET_CREDS", self.login_env("carol")[0])

    def test_credsep_store_owned_by_the_role_account(self):
        # mac-a (issue #2336): the store's node.env is _fleetcred's, not root's —
        # the owner check (forced on here) must take the role account
        import getpass
        e = dict(self.cred_store("alice", "CCQUOTA_TOKEN=tok-alice\n"), FLEET_NODE_OWNER_CHECK="1",
                 FLEET_CREDSEP_ROLE="no-such-role-account")
        self.agent_plist("alice", {"CCQUOTA_FLEET": "1"})
        self.acct_table()
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(r.returncode, 1, "a store file of an unknown owner was read")
        self.assertIn("no CCQUOTA_TOKEN", r.stderr)
        e["FLEET_CREDSEP_ROLE"] = getpass.getuser()
        r = self.run_sup("account", "adopt", "alice", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice")

    def test_refused_lane_is_named_and_rejoin_renews_the_token(self):
        # issue #2501: the hub refused alice's lane (her token was reissued away)
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        self.agent_plist("alice", {"CCQUOTA_HUB_URL": "https://hub.invalid", "FLEET_CONF_DIR": conf})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-alice-1\n")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        lane = os.path.join(self.d, "db", "agent", "alice", "lane.json")
        os.makedirs(os.path.dirname(lane))
        why = "unrecognised enrollment token for login alice: this login re-registered with the hub"
        json.dump({"state": "refused", "code": "WRONG_LOGIN", "why": why, "since": "2026-10-08T17:41:12Z"}, open(lane, "w"))
        r = self.run_sup("status")
        self.assertTrue(any(l.startswith("lane   alice") and "令牌失效" in l and "account adopt alice --rejoin" in l
                            and why in l for l in r.stdout.splitlines()), r.stdout)
        self.start()
        r = until(10, lambda: (lambda x: x if x.returncode == 3 else None)(self.run_sup("status", "--check")))
        self.assertTrue(r, "status --check never said 3 for a refused lane")
        self.assertIn("令牌失效 · 需要 relogin: alice", r.stdout)
        self.assertEqual(self.state().get("lanes", {}).get("alice", {}).get("why"), why, "state.json has no copy")

        # --rejoin: alice's device key asks the hub (a fake fleet-login.py here)
        seen = os.path.join(self.d, "seen")
        fake = os.path.join(self.d, "fake-login.py")
        with open(fake, "w") as f:
            f.write("import json, os, sys\n"
                    "a = sys.argv[1:]\n"
                    "open(%r, 'w').write(' '.join(a[:3]) + ' HOME=' + os.environ.get('HOME', '') + ' USER=' + os.environ.get('USER', ''))\n"
                    "if os.path.exists(%r):\n"
                    "    sys.stderr.write('fleet login: 没拿到节点通行证（HTTP 409）：machine_managed\\n'); sys.exit(1)\n"
                    "json.dump({'token': 'tok-alice-2', 'endpoint_id': 'ep_a'}, open(a[a.index('--out') + 1], 'w'))\n"
                    % (seen, seen + ".refuse"))
        e = {"FLEET_NODE_LOGIN_PY": fake}
        r = self.run_sup("account", "adopt", "alice", "--rejoin", "--dry-run", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("would ask https://hub.invalid", r.stdout)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice-1", "a dry run renewed")
        open(seen + ".refuse", "w").close()
        r = self.run_sup("account", "adopt", "alice", "--rejoin", env=e)
        os.remove(seen + ".refuse")
        self.assertEqual(r.returncode, 1)
        self.assertIn("machine_managed", r.stderr)
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-alice-1", "a refused pass wrote a token")
        r = self.run_sup("account", "adopt", "alice", "--rejoin", env=e)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("tok-alice", r.stdout + r.stderr, "rejoin printed the token")
        self.assertEqual(open(seen).read(), "node-pass --hub https://hub.invalid HOME=%s USER=alice" % self.home("alice"))
        kv, mode = self.login_env("alice")
        self.assertEqual((kv["CCQUOTA_TOKEN"], kv["CCQUOTA_HUB_URL"], mode), ("tok-alice-2", "https://hub.invalid", 0o600))

        # the tenant's next welcome removes lane.json: the line and the 3 go
        os.remove(lane)
        self.assertTrue(until(10, lambda: self.run_sup("status", "--check").returncode == 0))
        self.assertNotIn("lane   alice", self.run_sup("status").stdout)

    def test_rejoin_needs_a_managed_or_separated_login(self):
        self.acct_table()
        r = self.run_sup("account", "adopt", "bob", "--rejoin", env={"FLEET_NODE_LOGIN_PY": "/bin/false"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("no hub URL", r.stderr)

    def test_adopted_before_moves_the_agent_left_behind(self):
        la = os.path.join(self.home("alice"), "Library", "LaunchAgents")
        self.plist(os.path.join(la, "com.claude-fleet.dispatch.plist"), "com.claude-fleet.dispatch")
        self.acct_table()
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        conf = os.path.join(self.home("alice"), ".config", "claude-fleet")
        ap = self.agent_plist("alice", {})
        self.node_env(os.path.join(conf, "node.env"), "CCQUOTA_TOKEN=tok-a\n")
        r = self.run_sup("account", "adopt", "alice")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.exists(ap))
        self.assertEqual(self.login_env("alice")[0]["CCQUOTA_TOKEN"], "tok-a")
        self.assertEqual(len(json.load(open(os.path.join(self.d, "db", "accounts.json")))["alice"]["attic"]), 2)
        self.assertEqual(self.run_sup("account", "release", "alice").returncode, 0)
        self.assertTrue(os.path.exists(ap) and os.path.exists(os.path.join(la, "com.claude-fleet.dispatch.plist")))

    def test_node_agent_restarts_when_logins_change(self):
        lg = self.logins_dir()
        self.node_agent(lg, requires=[lg], reload=lg)
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        time.sleep(0.3)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted with nothing changed")
        put(os.path.join(lg, "alice.env"), "CCQUOTA_TOKEN=x\n")
        pid2 = self.new_pid("node-agent", pid)
        self.assertTrue(pid2, "logins/ changed and the node agent kept its old tenants")
        self.assertTrue(until(3, lambda: not fns.pid_alive(pid)), "the old node agent is still running")

    def test_node_agent_adopted_still_reloads_on_a_new_login(self):
        # #3136: the supervisor restarted (an update) and adopted the live node
        # agent; a live adopted child skipped the reload check, so the login
        # opened that same second never got its node — until the agent exited.
        lg = self.logins_dir("grace")
        # a plain argv: adopt matches the live process's command line to the one recorded
        self.node_agent(lg, cmd=["/bin/sleep", "300"])
        p = self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        p.kill()
        p.wait()
        self.assertTrue(fns.pid_alive(pid), "the node agent died with the supervisor")
        self.start()
        self.assertTrue(until(10, lambda: (self.state().get("supervisor") or {}).get("starts") == 2))
        time.sleep(0.5)
        self.assertEqual(self.child("node-agent")["pid"], pid, "the live node agent was not adopted")
        put(os.path.join(lg, "drill.env"), "CCQUOTA_TOKEN=y\n")
        pid2 = self.new_pid("node-agent", pid)
        self.assertTrue(pid2, "an adopted node agent kept its old tenants after a new login")
        self.assertTrue(until(3, lambda: not fns.pid_alive(pid)), "the adopted node agent is still running")

    def test_node_agent_reload_waits_for_an_account_op(self):
        # #2918: opening a login writes its logins/<login>.env half way through
        # the create the node agent runs — the restart cut that very create off.
        # While a tenant's book names an op running (by a live pid) the reload
        # waits; once it is done the agent starts again on the new logins/.
        lg = self.logins_dir("grace")
        book, _ = self.held_book()
        self.node_agent(lg, hold=True)
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        put(os.path.join(lg, "alice.env"), "CCQUOTA_TOKEN=y\n")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("reload_held_since")),
                        "the reload was not held by the op running")
        time.sleep(0.6)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted mid account op")
        self.assertTrue(fns.pid_alive(pid))
        put(book, {"outbox": {"op-1": {"type": "account_result", "op_id": "op-1"}}})
        pid2 = self.new_pid("node-agent", pid)
        self.assertTrue(pid2, "the op ended and the node agent kept its old tenants")
        self.assertFalse(self.child("node-agent").get("reload_held_since"))

    def test_node_agent_reload_held_by_its_script_without_a_book(self):
        # #2927: the release's ccquota predated the book (prod-343c92b under
        # stable 003e89bb), so it wrote none and nothing held — the restart cut
        # the create off and the hub's re-ask ran it again into exit 3. The
        # account script running under the node agent holds the reload too.
        lg = self.logins_dir("grace")
        flag = os.path.join(self.d, "op-done")
        login_new = self.script("fleet-login-new.sh", "while [ ! -e %s ]; do sleep 0.1; done\n" % flag)
        self.node_agent(lg, cmd=[self.script("na.sh", "/bin/sh %s & wait; exec sleep 300\n" % login_new)],
                        hold=True, hold_argv=["fleet-login-new.sh"])
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        put(os.path.join(lg, "alice.env"), "CCQUOTA_TOKEN=y\n")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("reload_held_since")),
                        "a create running under the node agent did not hold the reload (no book)")
        time.sleep(0.6)
        self.assertEqual(self.child("node-agent")["pid"], pid, "restarted mid account op")
        open(flag, "w").close()
        pid2 = self.new_pid("node-agent", pid)
        self.assertTrue(pid2, "the script ended and the node agent kept its old tenants")

    def test_node_agent_reload_hold_has_a_cap(self):
        # a book from a dead process holds nothing; a live one at most
        # FLEET_NODE_RELOAD_HOLD seconds
        lg = self.logins_dir("grace")
        _, holder = self.held_book()
        self.node_agent(lg, hold=True)
        self.start(FLEET_NODE_RELOAD_HOLD="1")
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        put(os.path.join(lg, "alice.env"), "CCQUOTA_TOKEN=y\n")
        pid2 = self.new_pid("node-agent", pid)
        self.assertTrue(pid2, "a hold past its cap kept the old tenants")
        holder.kill()
        holder.wait()
        put(os.path.join(lg, "bob.env"), "CCQUOTA_TOKEN=z\n")
        pid3 = self.new_pid("node-agent", pid2)
        self.assertTrue(pid3, "a dead process's book held the reload")

    def test_node_agent_waits_for_a_login(self):
        # #2421: an empty logins/ made ccquota exit 1 once a minute (restarts 47);
        # the daemon waits until one <login>.env is in it, and stops it again
        # when the last one goes.
        lg = self.logins_dir()
        self.node_agent(lg, reload=lg)
        self.start()
        self.assertTrue(until(10, lambda: self.child("node-agent").get("status") == "waiting"))
        time.sleep(0.5)
        self.assertFalse(self.child("node-agent").get("pid"), "started on an empty logins/")
        self.assertFalse(self.child("node-agent").get("restarts"))
        r = self.run_sup("status")
        self.assertIn("waiting — %s missing" % os.path.join(lg, "*.env"), r.stdout)
        env = os.path.join(lg, "alice.env")
        put(env, "CCQUOTA_TOKEN=x\n")
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid, "a login arrived and the node agent did not start")
        os.unlink(env)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid)), "the last login left and it kept running")
        self.assertTrue(until(10, lambda: self.child("node-agent").get("status") == "waiting"))

    def test_adopt_refuses_unknown(self):
        r = self.run_sup("account", "adopt", "nobody-here")
        self.assertEqual(r.returncode, 2)


class I_Services(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.home = os.path.join(self.d, "Users", "alice")
        self.passwd({"alice": self.home})
        self.table()
        self.svc_sh = self.script("svc.sh", 'echo "up uid=$(id -u) home=$HOME user=$USER svc=$FLEET_SERVICE '
                                  'tok=${TOKEN:-none} mode=$MODE"\necho oops >&2\nexec sleep 300\n')
        self.key = "svc:alice/watch"


    def log(self):
        return slurp(os.path.join(self.d, "log", "logins", "alice", "watch.log"))

    def test_register_run_restart_stop_rm(self):
        r = subprocess.run(CLI + ["service", "cred", "set", "--login", "alice", "--name", "TOKEN"],
                           env=self.env, input="s3cret\n", capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("s3cret", r.stdout + r.stderr)
        r = self.svc("add", "--login", "alice", "--name", "watch", "--env", "MODE=prod", "--cred", "TOKEN",
                     "--", "/bin/bash", self.svc_sh)
        self.assertEqual(r.returncode, 0, r.stderr)
        f = os.path.join(self.d, "db", "logins", "alice", "services", "watch.json")
        self.assertEqual(os.stat(f).st_mode & 0o777, 0o600)
        ent = json.load(open(f))
        self.assertEqual((ent["login"], ent["kind"], ent["state"]), ("alice", "service", "enabled"))
        self.assertEqual(ent["creds"], ["TOKEN"])
        self.assertNotIn("s3cret", open(f).read(), "a credential value in the entry")
        self.start(FLEET_NODE_BACKOFF_MAX="0.1")   # the kill below: back at once, not after 1 s
        pid = until(10, lambda: self.child(self.key).get("pid"))
        self.assertTrue(pid, "the service never started")
        self.assertTrue(until(5, lambda: "up uid=" in self.log()), "no log in <log>/logins/alice/")
        line = [l for l in self.log().splitlines() if l.startswith("up ")][-1]
        self.assertIn("uid=%d home=%s user=alice svc=watch tok=s3cret mode=prod" % (os.getuid(), self.home), line)
        self.assertIn("oops", self.log(), "stderr not in the log")
        st = self.services()["watch"]
        self.assertEqual((st["status"], st["pid"], st["login"]), ("running", pid, "alice"))
        self.assertEqual(st["creds"], ["TOKEN"])
        self.assertIn("MODE", st["env_keys"])
        self.assertEqual(st["last_line"], "oops")
        self.assertNotIn("s3cret", json.dumps(self.state()), "a credential value in state.json")
        self.assertIn("service alice/watch", self.run_sup("status").stdout)
        # killed: back within 30 s
        os.kill(pid, signal.SIGKILL)
        t0 = time.time()
        pid2 = until(30, lambda: (self.child(self.key).get("pid") or pid) != pid and self.child(self.key)["pid"])
        self.assertTrue(pid2, "the killed service was not restarted")
        self.assertLess(time.time() - t0, 30)
        self.assertEqual(self.child(self.key)["restarts"], 1)
        # restart: a new process; stop: none; start: back
        self.assertEqual(self.svc("restart", "--login", "alice", "--name", "watch").returncode, 0)
        pid3 = until(10, lambda: (self.child(self.key).get("pid") or pid2) != pid2 and self.child(self.key)["pid"])
        self.assertTrue(pid3, "restart did not start it again")
        self.assertTrue(until(5, lambda: not fns.pid_alive(pid2)))
        self.assertEqual(self.svc("stop", "--login", "alice", "--name", "watch").returncode, 0)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid3)), "stop left it running")
        self.assertTrue(until(20, lambda: self.services()["watch"]["status"] == "stopped"))
        time.sleep(0.5)
        self.assertFalse(fns.pid_alive(self.child(self.key).get("pid")), "a stopped service came back")
        self.assertEqual(self.svc("start", "--login", "alice", "--name", "watch").returncode, 0)
        pid4 = until(10, lambda: self.child(self.key).get("pid"))
        self.assertTrue(pid4, "start did not bring it back")
        # rm: stopped, the row gone; the log stays
        self.assertEqual(self.svc("rm", "--login", "alice", "--name", "watch").returncode, 0)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid4)), "rm left it running")
        self.assertTrue(until(10, lambda: self.key not in (self.state().get("children") or {})))
        self.assertNotIn("watch", self.services())
        self.assertTrue(os.path.exists(os.path.join(self.d, "log", "logins", "alice", "watch.log")))

    def test_missing_credential_waits(self):
        r = self.svc("add", "--login", "alice", "--name", "watch", "--cred", "TOKEN", "--", "/bin/bash", self.svc_sh)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not stored yet", r.stdout)
        self.start()
        self.assertTrue(until(10, lambda: self.child(self.key).get("status") == "missing credential TOKEN"))
        self.assertFalse(self.child(self.key).get("pid"))
        subprocess.run(CLI + ["service", "cred", "set", "--login", "alice", "--name", "TOKEN"],
                       env=self.env, input="v\n", capture_output=True, text=True)
        self.assertTrue(until(10, lambda: self.child(self.key).get("pid")), "the credential arrived, no start")

    def test_bad_entries_refused(self):
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "Bad/Name", "--", "/bin/true").returncode, 2)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "x", "--", "true").returncode, 2)
        self.assertEqual(self.svc("add", "--login", "nobody-here", "--name", "x", "--", "/bin/true").returncode, 1)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "x").returncode, 2)
        # a hand-written entry that lies about its login is named, never run
        d = os.path.join(self.d, "db", "logins", "alice", "services")
        os.makedirs(d)
        put(os.path.join(d, "evil.json"), {"name": "evil", "login": "root", "kind": "service", "exec": ["/bin/sleep", "300"]})
        self.assertEqual(self.run_sup("tick").returncode, 0)
        self.start()
        time.sleep(1)
        self.assertFalse(self.child("svc:alice/evil").get("pid"))
        self.assertFalse(self.child("svc:root/evil").get("pid"))
        row = self.services()["evil"]
        self.assertEqual(row["status"], "invalid")
        self.assertIn("login root", row["why"])
        self.assertIn("INVALID", self.run_sup("status").stdout)

    def test_front_registers_through_the_supervisor(self):
        def front(*args, **env):
            return self.front("fleet-service.sh", "alice", *args, MYMODE="dev", **env)
        r = front("add", "watch", "--env-key", "MYMODE", "--", "sleep", "300")
        self.assertEqual(r.returncode, 0, r.stderr)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "alice", "services", "watch.json")))
        self.assertTrue(os.path.isabs(ent["exec"][0]) and ent["exec"][1:] == ["300"], ent["exec"])
        self.assertEqual(ent["env"], {"MYMODE": "dev"})
        self.assertIn("alice/watch", front("ls").stdout)
        r = front("rm", "watch")
        self.assertEqual(r.returncode, 0, r.stderr)
        # no passwordless sudo: the line an admin runs
        fake = self.script("nosudo", "exit 1\n")
        r = front("stop", "watch", FLEET_SERVICE_SUDO=fake)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("service stop --login alice --name watch", r.stderr)

    def test_services_do_not_restart_the_node_agent(self):
        self.node_agent(self.logins_dir("alice"))
        self.start()
        pid = until(10, lambda: self.child("node-agent").get("pid"))
        self.assertTrue(pid)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "watch", "--", "/bin/sleep", "300").returncode, 0)
        self.assertTrue(until(10, lambda: self.child(self.key).get("pid")))
        time.sleep(0.5)
        self.assertEqual(self.child("node-agent")["pid"], pid, "a service restarted the node agent")


class J_ServiceMove(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.ha = os.path.join(self.d, "Users", "heidi")
        self.hb = os.path.join(self.d, "Users", "grace")
        self.passwd({"heidi": self.ha, "grace": self.hb})
        self.table()
        # the daily-report case: a working dir with its script + logs, a skill dir
        self.work = os.path.join(self.ha, "daily-report")
        self.skill = os.path.join(self.ha, ".claude", "skills", "daily-report")
        os.makedirs(os.path.join(self.work, "logs"))
        os.makedirs(self.skill)
        put(os.path.join(self.skill, "SKILL.md"), "daily report\n")
        self.run_sh = os.path.join(self.work, "run.sh")
        with open(self.run_sh, "w") as f:
            f.write('#!/bin/bash\necho "up home=$HOME user=$USER tok=${BARK_KEY:-none} out=$OUT"\n'
                    'echo run >> "$OUT/run.log"\nexec sleep 300\n')
        os.chmod(self.run_sh, 0o755)
        r = subprocess.run([sys.executable, SUP, "service", "cred", "set", "--login", "heidi", "--name",
                            "BARK_KEY"], env=self.env, input="k3y\n", capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_sup("service", "add", "--login", "heidi", "--name", "daily-report", "--cred", "BARK_KEY",
                         "--env", "OUT=%s/logs" % self.work, "--path", self.work, "--path", self.skill,
                         "--", "/bin/bash", self.run_sh)
        self.assertEqual(r.returncode, 0, r.stderr)

    def reg(self, login):
        return os.path.join(self.d, "db", "logins", login, "services", "daily-report.json")

    def svclog(self, login):
        return os.path.join(self.d, "log", "logins", login, "daily-report.log")

    read = staticmethod(slurp)

    def test_move_carries_everything_and_runs_as_the_new_login(self):
        self.start()
        pa = until(10, lambda: self.child("svc:heidi/daily-report").get("pid"))
        self.assertTrue(pa, "never ran as the old login")
        self.assertTrue(until(5, lambda: "home=%s" % self.ha in self.read(self.svclog("heidi"))))
        r = self.run_sup("service", "move", "--login", "heidi", "--name", "daily-report", "--to", "grace")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("moved heidi/daily-report → grace/daily-report", r.stdout)
        self.assertFalse(fns.pid_alive(pa), "the old copy still runs")
        # the entry
        self.assertFalse(os.path.exists(self.reg("heidi")), "the old entry is left")
        ent = json.load(open(self.reg("grace")))
        self.assertEqual(os.stat(self.reg("grace")).st_mode & 0o777, 0o600)
        nwork = os.path.join(self.hb, "daily-report")
        nskill = os.path.join(self.hb, ".claude", "skills", "daily-report")
        self.assertEqual((ent["login"], ent["state"]), ("grace", "enabled"))
        self.assertEqual(ent["exec"], ["/bin/bash", os.path.join(nwork, "run.sh")])
        self.assertEqual(ent["paths"], [nwork, nskill])
        self.assertEqual(ent["env"]["OUT"], os.path.join(nwork, "logs"))
        self.assertEqual(ent["moved_from"]["login"], "heidi")
        # the directories
        self.assertTrue(os.path.isfile(os.path.join(nwork, "run.sh")))
        self.assertTrue(os.path.isfile(os.path.join(nskill, "SKILL.md")))
        self.assertIn("run", self.read(os.path.join(nwork, "logs", "run.log")), "the job's own log did not move")
        self.assertFalse(os.path.exists(self.work), "the working dir is left in the old home")
        self.assertFalse(os.path.exists(self.skill), "the skill dir is left in the old home")
        # the log and the credential
        self.assertFalse(os.path.exists(self.svclog("heidi")), "the log is left under the old login")
        self.assertIn("home=%s" % self.ha, self.read(self.svclog("grace")), "the log's history did not move")
        creds = os.path.join(self.d, "db", "logins")
        self.assertFalse(os.path.exists(os.path.join(creds, "heidi", "creds", "BARK_KEY")))
        self.assertEqual(self.read(os.path.join(creds, "grace", "creds", "BARK_KEY")), "k3y\n")
        # and it runs as the new login
        pb = until(10, lambda: self.child("svc:grace/daily-report").get("pid"))
        self.assertTrue(pb, "it did not start under the new login")
        self.assertTrue(until(5, lambda: "up home=%s user=grace tok=k3y out=%s/logs" % (self.hb, nwork)
                              in self.read(self.svclog("grace"))), self.read(self.svclog("grace")))
        self.assertTrue(until(10, lambda: "svc:heidi/daily-report" not in (self.state().get("children") or {})))
        rows = json.loads(self.run_sup("service", "ls", "--json").stdout)
        self.assertEqual([(x["login"], x["name"]) for x in rows], [("grace", "daily-report")])
        # nothing left to stop a release / a removal of the old login
        self.assertEqual(os.listdir(os.path.dirname(self.reg("heidi"))), [])

    def test_move_refuses_onto_an_existing_path(self):
        os.makedirs(os.path.join(self.hb, ".claude", "skills", "daily-report"))
        r = self.run_sup("service", "move", "--login", "heidi", "--name", "daily-report", "--to", "grace")
        self.assertEqual(r.returncode, 1)
        self.assertIn("already exists", r.stderr)
        self.assertTrue(os.path.exists(self.reg("heidi")) and not os.path.exists(self.reg("grace")))
        self.assertEqual(json.load(open(self.reg("heidi")))["state"], "enabled")
        self.assertTrue(os.path.isdir(self.work) and os.path.isdir(self.skill))
        self.assertEqual(self.run_sup("service", "move", "--login", "heidi", "--name", "daily-report",
                                      "--to", "heidi").returncode, 2)
        self.assertEqual(self.run_sup("service", "move", "--login", "heidi", "--name", "nope",
                                      "--to", "grace").returncode, 1)

    def test_a_stopped_entry_moves_stopped(self):
        self.assertEqual(self.run_sup("service", "stop", "--login", "heidi", "--name", "daily-report").returncode, 0)
        r = self.run_sup("service", "move", "--login", "heidi", "--name", "daily-report", "--to", "grace")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.load(open(self.reg("grace")))["state"], "stopped")

    def test_release_refuses_while_entries_are_left(self):
        put(os.path.join(self.d, "db", "accounts.json"), {"heidi": {"managed": True, "since": 1}})
        r = self.run_sup("account", "release", "heidi")
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("service move --login heidi --name daily-report --to", r.stderr)
        self.assertTrue(json.load(open(os.path.join(self.d, "db", "accounts.json")))["heidi"]["managed"],
                        "a refused release changed the account")
        os.makedirs(os.path.join(self.d, "db", "attic"))
        r = self.run_sup("account", "release", "heidi", "--force")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_front_moves_your_own(self):
        self.assertEqual(self.front("fleet-service.sh", "heidi", "move", "daily-report").returncode, 2)
        r = self.front("fleet-service.sh", "heidi", "move", "daily-report", "--to", "grace")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.reg("grace")))
class K_AgentTasks(Sandbox):
    DAY = "2026-10-10"

    def setUp(self):
        Sandbox.setUp(self)
        self.home = os.path.join(self.d, "Users", "alice")
        self.passwd({"alice": self.home})
        self.clock = os.path.join(self.d, "clock")
        self.env.update(FLEET_NODE_CLOCK=self.clock)
        self.table()
        self.calls = os.path.join(self.d, "calls")
        # the login's spawner: one line per call (its argv), the receipt on stdout
        self.spawner = os.path.join(self.d, "spawn.sh")
        self.spawner_rc(0)
        self.set_clock("06:59:50")

    def set_clock(self, hms, day=None):
        import calendar
        y, m, d = (int(x) for x in (day or self.DAY).split("-"))
        h, mi, se = (int(x) for x in hms.split(":"))
        put(self.clock, "%d\n" % calendar.timegm((y, m, d, h, mi, se)))

    def spawner_rc(self, rc):
        with open(self.spawner, "w") as f:
            f.write('#!/bin/bash\nprintf "%%s|" "$@" >> "$CALLS"; echo >> "$CALLS"\n'
                    '[ -n "${MAKE:-}" ] && : > "$MAKE"\n'
                    'echo "@7\tdaily\t\tfid"\nexit %d\n' % rc)
        os.chmod(self.spawner, 0o755)

    def add(self, *extra, **env_):
        e = ["--env", "FLEET_TASK_SPAWN=%s" % self.spawner, "--env", "CALLS=%s" % self.calls]
        for k, v in env_.items():
            e += ["--env", "%s=%s" % (k, v)]
        return self.run_sup("service", "add", "--kind", "task", "--login", "alice", "--name", "daily",
                            "--at", "07:00", "--tz", "UTC", "--fleet", "fns-sandbox", "--prompt", "/daily-report {date}",
                            *(e + list(extra)))

    def ncalls(self):
        return [l for l in slurp(self.calls).splitlines() if l]

    def row(self):
        return self.services()["daily"]

    def agent(self):
        return (self.state().get("agent_tasks") or {}).get("alice/daily") or {}

    def test_slot_fires_once(self):
        self.spawner_rc(0)
        r = self.add()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("next run %s 07:00" % self.DAY, r.stdout)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "alice", "services", "daily.json")))
        self.assertEqual((ent["kind"], ent["schedule"], ent["retries"]), ("task", {"at": "07:00", "tz": "UTC"}, 2))
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "a run before its slot")
        self.assertEqual(self.row()["status"], "scheduled")
        self.set_clock("07:00:05")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        time.sleep(1.5)
        calls = self.ncalls()
        self.assertEqual(len(calls), 1, calls)
        self.assertEqual(calls[0], "--no-repo|--origin|hub|--source|schedule|--reap-origin|probe|--reap|done:15m|--print|--name|daily-%s|--prompt|/daily-report %s|fns-sandbox|"
                         % (self.DAY, self.DAY))
        row = self.row()
        self.assertEqual((row["status"], row["last_result"], row["last_window"]), ("ok", "ok", "daily-" + self.DAY))
        self.assertEqual(fns.task_time(row["next_run"], row["schedule"]), "2026-10-11 07:00")
        self.assertTrue(row["last_run"])
        log = open(os.path.join(self.d, "log", "logins", "alice", "daily.log")).read()
        self.assertIn("opened @7 (daily-%s) in fleet fns-sandbox" % self.DAY, log)
        runs = json.load(open(os.path.join(self.d, "db", "logins", "alice", "runs", "daily.json")))["runs"]
        self.assertEqual([(x["slot"], x["attempt"], x["rc"]) for x in runs], [(self.DAY, 1, 0)])
        st = self.run_sup("service", "ls", "--login", "alice", "--kind", "task").stdout
        self.assertIn("上次 %s 07:00 ok · 下次 2026-10-11 07:00" % self.DAY, st)
        # the next day's slot: one more, a new window name
        self.set_clock("07:00:01", "2026-10-11")
        self.assertTrue(until(10, lambda: len(self.ncalls()) == 2), self.ncalls())
        self.assertIn("--name|daily-2026-10-11|", self.ncalls()[1])

    def test_agent_choice_front_registry_daemon_and_reschedule(self):
        front = lambda *args: self.front("fleet-task.sh", "alice", *args)
        args = ("add", "daily", "--at", "07:00", "--tz", "UTC", "--fleet", "fns-sandbox", "--prompt", "hi",
                "--env", "FLEET_TASK_SPAWN=%s" % self.spawner, "--env", "CALLS=%s" % self.calls,
                "--env", "FLEET_AGENT=codex")
        self.assertEqual(front(*(args + ("--agent", "invalid"))).returncode, 2)
        r = front(*(args + ("--agent", "claude")))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.row()["agent"], "claude")
        self.start()
        self.set_clock("07:00:05")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        self.assertIn("--agent|claude|", self.ncalls()[0])
        self.assertIn("Agent claude", front("ls").stdout)
        self.assertEqual(front("schedule", "daily", "--agent", "invalid").returncode, 2)
        self.assertEqual(self.row()["agent"], "claude")
        r = front("schedule", "daily", "--agent", "codex")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.row()["schedule"], {"at":"07:00", "tz":"UTC"})
        r = front("schedule", "daily", "--at", "08:00")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.row()["agent"], "codex", "schedule edit lost the explicit agent")
        self.set_clock("08:00:05")
        self.assertTrue(until(10, lambda: len(self.ncalls()) == 2), self.ncalls())
        self.assertIn("--agent|codex|", self.ncalls()[1])

    def test_failures_exhaust_then_alert(self):
        self.spawner_rc(2)        # at capacity, every time
        self.assertEqual(self.add("--retries", "1", "--retry-delay", "0").returncode, 0)
        self.set_clock("07:00:05")
        self.start()
        self.assertTrue(until(15, lambda: self.agent().get("state") == "failed"), self.agent())
        time.sleep(1.5)
        calls = self.ncalls()
        self.assertEqual(len(calls), 2, calls)
        self.assertIn("--name|daily-%s|" % self.DAY, calls[0])
        self.assertIn("--name|daily-%s-2|" % self.DAY, calls[1], "a retry reuses the failed window's name")
        ap = os.path.join(self.d, "db", "logins", "alice", "alerts", "daily.json")
        self.assertTrue(os.path.exists(ap), "no alert file")
        al = json.load(open(ap))
        self.assertEqual((al["attempts"], al["slot"]), (2, self.DAY))
        self.assertIn("did not open", al["why"])
        row = self.row()
        self.assertEqual((row["status"], row["alert"]), ("failed", ap))
        self.assertIn("task    alice/daily", self.run_sup("status").stdout)
        # a success later clears the alert
        self.spawner_rc(0)
        self.assertEqual(self.run_sup("service", "run", "--login", "alice", "--name", "daily").returncode, 0)
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        self.assertFalse(os.path.exists(ap), "the alert outlived a good run")

    def test_run_now_through_the_front(self):
        self.spawner_rc(0)
        self.set_clock("12:00:00")
        def front(*args):
            return self.front("fleet-task.sh", "alice", *args)
        r = front("add", "daily", "--at", "07:00", "--tz", "UTC", "--fleet", "fns-sandbox", "--prompt", "hi",
                  "--env", "FLEET_TASK_SPAWN=%s" % self.spawner, "--env", "CALLS=%s" % self.calls)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "a slot earlier than the entry ran")
        r = front("run", "daily")
        self.assertEqual(r.returncode, 2, "run without --now")
        r = front("run", "daily", "--now")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(until(10, lambda: len(self.ncalls()) == 1), self.ncalls())
        self.assertIn("--name|daily-2026-10-10-now1200|", self.ncalls()[0], "a manual run took the slot's window")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"))
        time.sleep(1)
        self.assertEqual(len(self.ncalls()), 1)
        ls = front("ls").stdout
        self.assertIn("alice/daily", ls)
        self.assertIn("下次 %s 07:00" % "2026-10-11", ls)
        # a service has no run; a stopped task does not run
        r = front("stop", "daily")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = front("run", "daily", "--now")
        self.assertEqual(r.returncode, 1)
        r = front("rm", "daily")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(until(10, lambda: "alice/daily" not in (self.state().get("agent_tasks") or {})))

    def test_schedule_moves_the_slot(self):
        # issue #2527: a new schedule moves the next slot, and a slot it skipped
        # over (passed before the change) is never caught up
        self.spawner_rc(0)
        self.set_clock("05:00:00")
        self.assertEqual(self.add().returncode, 0)
        self.set_clock("08:00:00")
        r = self.front("fleet-task.sh", "alice", "schedule", "daily", "--at", "07:30")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("daily 07:30 UTC, next run 2026-10-11 07:30", r.stdout, "the tz was not kept")
        self.start()
        time.sleep(1.5)
        self.assertEqual(self.ncalls(), [], "the slot the change skipped over ran")
        row = self.row()
        self.assertEqual(fns.task_time(row["next_run"], row["schedule"]), "2026-10-11 07:30")
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "daily",
                                      "--at", "7pm").returncode, 2, "a bad schedule was written")
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "daily",
                                      "--cron", "0 6 * * 1-5", "--tz", "Asia/Shanghai").returncode, 0)
        self.assertEqual(self.row()["schedule"], {"cron": "0 6 * * 1-5", "tz": "Asia/Shanghai"})
        self.assertEqual(self.run_sup("service", "add", "--login", "alice", "--name", "s", "--", "/bin/sleep",
                                      "300").returncode, 0)
        self.assertEqual(self.run_sup("service", "schedule", "--login", "alice", "--name", "s",
                                      "--at", "07:00").returncode, 2, "a service has no schedule")

    def test_done_file_decides(self):
        self.spawner_rc(0)
        out = os.path.join(self.home, "out-{date}.md")
        self.assertEqual(self.add("--done-file", out, "--retries", "0", MAKE=out.replace("{date}", self.DAY))
                         .returncode, 0)
        self.set_clock("07:00:05")
        self.start()
        self.assertTrue(until(10, lambda: self.agent().get("state") == "ok"), self.agent())
        # the next slot's file is never made: the session ends without it → failed
        self.set_clock("07:00:05", "2026-10-11")
        self.assertTrue(until(10, lambda: self.agent().get("state") == "failed"), self.agent())
        self.assertIn("without its output", self.agent()["last_error"])

    def test_task_moves_with_its_login(self):
        self.passwd({"alice": self.home, "bob": os.path.join(self.d, "Users", "bob")})
        self.assertEqual(self.add("--done-file", os.path.join(self.home, "out-{date}.md")).returncode, 0)
        r = self.run_sup("service", "move", "--login", "alice", "--name", "daily", "--to", "bob")
        self.assertEqual(r.returncode, 0, r.stderr)
        ent = json.load(open(os.path.join(self.d, "db", "logins", "bob", "services", "daily.json")))
        self.assertEqual((ent["kind"], ent["exec"]), ("task", None))
        self.assertEqual(ent["done_when"]["file"], os.path.join(self.d, "Users", "bob", "out-{date}.md"))

    def test_bad_entries_refused(self):
        base = ["service", "add", "--kind", "task", "--login", "alice", "--name", "t"]
        self.assertEqual(self.run_sup(*base, "--at", "07:00").returncode, 2, "no prompt")
        self.assertEqual(self.run_sup(*base, "--prompt", "x").returncode, 2, "no schedule")
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "7pm").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--cron", "* * *").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--tz", "Mars/Olympus").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--retries", "99").returncode, 2)
        self.assertEqual(self.run_sup(*base, "--prompt", "x", "--at", "07:00", "--", "/bin/true").returncode, 2)
        self.assertEqual(self.run_sup("service", "add", "--login", "alice", "--name", "s", "--", "/bin/sleep",
                                      "300").returncode, 0)
        self.assertEqual(self.run_sup("service", "run", "--login", "alice", "--name", "s").returncode, 2,
                         "run is a task's")

    def test_slots(self):
        import calendar
        t = calendar.timegm((2026, 10, 10, 6, 59, 50))       # a Saturday
        self.assertEqual(fns.task_slot({"cron": "30 6 * * 1-5", "tz": "UTC"}, t, 1)[1], "2026-10-12")
        self.assertEqual(fns.task_slot({"cron": "30 6 * * 1-5", "tz": "UTC"}, t, -1)[1], "2026-10-09")
        n = fns.task_slot({"at": "07:00", "tz": "Asia/Shanghai"}, t, 1)[0]
        self.assertEqual(n, calendar.timegm((2026, 10, 10, 23, 0, 0)))
        self.assertEqual(fns.task_slot({"cron": "0 9 1 * *", "tz": "UTC"}, t, 1)[1], "2026-11-01")



class L_Tenants(Sandbox):
    def setUp(self):
        Sandbox.setUp(self)
        self.passwd({w: os.path.join(self.d, "Users", w) for w in ("alice", "bob")},
                    os.path.join("Library", "LaunchAgents"), admin=("bob",))
        self.pw = self.env["FLEET_NODE_PASSWD"]
        self.logins = os.path.join(self.d, "db", "logins")
        os.makedirs(self.logins)

    def take(self, who):
        open(os.path.join(self.logins, who + ".env"), "w").close()

    def test_check_codes(self):
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 2, "nobody taken over: no row — " + r.stdout + r.stderr)
        self.take("alice")
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("none admin or sudo-capable: alice", r.stdout)
        self.take("bob")
        r = self.run_sup("tenants", "--check")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("bob: admin 组, sudo -l: (ALL) NOPASSWD: ALL", r.stdout)
        self.assertNotIn("alice", r.stdout)
        js = json.loads(self.run_sup("tenants", "--json").stdout)
        self.assertEqual(sorted(js["bad"]), ["bob"])

    def test_adopt_refuses_an_admin(self):
        ag = os.path.join(self.d, "Users", "bob", "Library", "LaunchAgents", "com.claude-fleet.x.plist")
        with open(ag, "wb") as f:
            plistlib.dump({"Label": "com.claude-fleet.x", "ProgramArguments": ["/bin/true"]}, f)
        r = self.run_sup("account", "adopt", "bob")
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertIn("refusing to adopt bob", r.stderr)
        self.assertTrue(os.path.exists(ag), "a refused adopt moved a service")
        self.assertFalse(fns.read_json(os.path.join(self.d, "db", "accounts.json"), {}).get("bob"))

    def test_tick_writes_the_reading(self):
        self.table()
        self.take("bob")
        self.assertEqual(self.run_sup("tick").returncode, 0)
        t = self.state().get("tenants") or {}
        self.assertEqual(t.get("bad", {}).get("bob"), ["admin 组", "sudo -l: (ALL) NOPASSWD: ALL"])
        self.assertTrue(t.get("complete"))

    def test_non_root_reader_carries_the_daemons_reading(self):
        keep = fns.tenant_privileges, fns.tenant_logins
        try:
            fns.tenant_logins = lambda paths: ["alice", "bob"]
            fns.tenant_privileges = lambda login: ([], False)       # groups clean, sudo unreadable
            cur = fns.tenants_now(None, {"tenants": {"at": 5, "bad": {"bob": ["sudo -l: x"], "gone": ["y"]}}})
            self.assertEqual(cur["bad"], {"bob": ["sudo -l: x"]})
            self.assertEqual(cur["daemon_at"], 5)
            self.assertFalse(cur["complete"])
        finally:
            fns.tenant_privileges, fns.tenant_logins = keep


class M_UpdateVerifySoon(Sandbox):
    """A switched release is verified once its settle passed, not on the update
    task's next 5-minute slot (issue #2973: 「正在更新（switched）」 for minutes)."""
    def test_verify_due_after_settle(self):
        db = os.path.join(self.d, "db")
        os.makedirs(db)
        p = type("P", (), {"state": db})()
        uj = os.path.join(db, "update.json")
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "no update.json is never due")
        put(uj, {"phase": "idle", "switched_at": 900})
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "an idle updater waits for its slot")
        put(uj, {"phase": "switched", "switched_at": 990})
        self.assertFalse(fns.update_verify_due(p, 1000, 100), "inside the settle: not yet")
        put(uj, {"phase": "switched", "switched_at": 960})
        self.assertTrue(fns.update_verify_due(p, 1000, 100), "settle passed: verify now")
        self.assertFalse(fns.update_verify_due(p, 1000, 10), "the task ran 10 s ago: no busy loop")


class N_FullDiskAccess(Sandbox):
    """The daemon reads whether its chain holds Full Disk Access, and the status
    line names what to grant (issue #2973: the hub's removes, dscl refused)."""
    def reading(self, mode):
        db = os.path.join(self.d, "TCC.db")
        if os.path.exists(db):
            os.remove(db)
        if mode is not None:
            put(db, "x")
            os.chmod(db, mode)
        os.environ["FLEET_NODE_TCC_DB"] = db
        try:
            return fns.fda_reading()
        finally:
            del os.environ["FLEET_NODE_TCC_DB"]
            if os.path.exists(db):
                os.chmod(db, 0o600)

    def test_reading(self):
        self.assertIs(self.reading(0o600)["ok"], True)
        self.assertIs(self.reading(None)["ok"], None, "no TCC database: nothing to tell")
        if os.geteuid() != 0:   # root reads a 000 file; macOS's TCC is what stops it there
            self.assertIs(self.reading(0o000)["ok"], False)
        self.assertTrue(self.reading(0o600)["program"].startswith("/"))

    def test_line(self):
        self.assertEqual(fns.fda_line({}), "")
        self.assertEqual(fns.fda_line({"fda": {"ok": True}}), "")
        self.assertEqual(fns.fda_line({"fda": {"ok": None}}), "")
        line = fns.fda_line({"fda": {"ok": False, "program": "/x/Python"}})
        self.assertIn("完全磁盘访问", line)
        self.assertIn("/x/Python", line)
        self.assertIn("kickstart -k system/com.claude-fleet.node", line)


class P_Watchdog(Sandbox):
    """A loop that stops coming round (issues #3079, #3086: mac-d's wedged in an
    open() of TCC.db, every task with it) says where, records it, and exits for
    launchd to restart; status reads WEDGED meanwhile; a blocking path is gone."""

    def fifo(self, name):
        f = os.path.join(self.d, name)
        os.mkfifo(f)
        return f

    def test_wedged_loop_exits_naming_its_phase(self):
        sh = self.script("w.sh", "exit 0\n")
        self.table(tasks=[{"name": "w", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        p = self.start(FLEET_NODE_WATCHDOG_SECS="1", FLEET_NODE_TEST_HANG="fda:" + self.fifo("hang"))
        try:
            rc = p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.fail("a wedged loop was never ended by the watchdog")
        self.assertEqual(rc, 70, "the watchdog's exit must read as a failure (launchd's KeepAlive restarts it)")
        err = open(os.path.join(self.d, "sup.err")).read()
        self.assertIn("watchdog: the main loop has not come round", err)
        self.assertIn("«fda»", err)
        self.assertIn("in at", err, "no stack of where the loop stuck:\n" + err[-2000:])
        w = self.state()["supervisor"]["wedged"]
        self.assertEqual(w["phase"], "fda")
        out = self.run_sup("status").stdout
        self.assertIn("watchdog    restarted it", out)
        self.assertIn("«fda»", out)

    def test_status_reads_wedged_while_the_loop_is_stopped(self):
        sh = self.script("w.sh", "exit 0\n")
        self.table(tasks=[{"name": "w", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        # the first pass saves, then its sleep never returns
        p = self.start(FLEET_NODE_WATCHDOG_SECS="0", FLEET_NODE_TEST_HANG="sleep:" + self.fifo("hang"))
        try:
            self.assertTrue(until(10, lambda: (self.state().get("supervisor") or {}).get("heartbeat")))
            time.sleep(1.5)
            r = self.run_sup("status", "--check", env={"FLEET_NODE_HEARTBEAT_STALE": "1"})
            self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
            self.assertIn("WEDGED", r.stdout)
            self.assertIn("kickstart -k system/com.claude-fleet.node", r.stdout)
        finally:
            # its loop sits in an open() a SIGTERM never ends: tearDown would wait 10 s for it
            p.kill()
            p.wait()

    def test_off_and_healthy_loop_stay_up(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(tasks=[{"name": "ok", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        p = self.start(FLEET_NODE_WATCHDOG_SECS="1")
        self.assertTrue(until(10, lambda: (self.task("ok").get("runs") or 0) >= 3), "the task never ran")
        time.sleep(1.5)
        self.assertIsNone(p.poll(), "a loop coming round every tick was ended by the watchdog")

    def test_tcc_open_that_never_returns_stalls_nothing(self):
        """mac-d 2026-10-11: the TCC database's open() never returned. The probe
        is a child now: the loop runs on, the probe is killed and reads unknown."""
        sh = self.script("ok.sh", "exit 0\n")
        self.table(tasks=[{"name": "ok", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        p = self.start(FLEET_NODE_WATCHDOG_SECS="2", FLEET_NODE_TCC_DB=self.fifo("TCC.db"),
                       FLEET_NODE_FDA_TIMEOUT="1")
        self.assertTrue(until(10, lambda: (self.task("ok").get("runs") or 0) >= 3), "the task never ran")
        f = until(10, lambda: self.state().get("fda"))
        self.assertTrue(f, "no FDA reading recorded")
        self.assertIsNone(f["ok"], "an unanswered probe is «unknown», never «no access»")
        self.assertEqual(f.get("timeout"), 1)
        n = self.task("ok")["runs"]
        self.assertTrue(until(5, lambda: self.task("ok")["runs"] > n + 3), "the loop stopped after the probe")
        self.assertIsNone(p.poll(), "the daemon died")
        self.assertIn("did not return in 1s", open(os.path.join(self.d, "sup.err")).read())

    def test_tcc_stuck_is_a_machine_failure(self):
        """mac-d 2026-10-11 (issue #3167): an unanswered TCC dialog wedged sandboxd and
        every user delete failed. Probe timeouts in a row count up; at
        FLEET_NODE_TCC_STUCK the check says so (exit 6) with the way out; an answer resets it."""
        self.table(tasks=[])
        self.start(FLEET_NODE_WATCHDOG_SECS="5", FLEET_NODE_TCC_DB=self.fifo("TCC.db"),
                   FLEET_NODE_FDA_TIMEOUT="1", FLEET_NODE_TENANT_EVERY="0")
        f = until(15, lambda: (self.state().get("fda") or {}).get("stuck", 0) >= 2 and self.state()["fda"])
        self.assertTrue(f, "consecutive probe timeouts were not counted: %r" % self.state().get("fda"))
        self.assertIsNone(f["ok"])
        r = self.run_sup("status", "--check")
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("TCC", r.stdout)
        self.assertIn("killall -9 sandboxd", r.stdout)
        self.assertIn("TCC is stuck", open(os.path.join(self.d, "sup.err")).read())
        self.assertEqual(fns.tcc_stuck_line({"fda": {"ok": None, "stuck": 1}}), "")
        self.assertEqual(fns.tcc_stuck_line({"fda": {"ok": False}}), "")

    def test_fifo_task_log_does_not_block(self):
        sh = self.script("w.sh", "exit 0\n")
        self.table(tasks=[{"name": "w", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        os.makedirs(os.path.join(self.d, "log", "tasks"))
        os.mkfifo(os.path.join(self.d, "log", "tasks", "w.log"))   # an open() that would never return
        p = self.start(FLEET_NODE_WATCHDOG_SECS="2")
        self.assertTrue(until(10, lambda: (self.task("w").get("runs") or 0) >= 2), "the task never ran")
        self.assertIsNone(p.poll())
        self.assertTrue(os.path.isfile(os.path.join(self.d, "log", "tasks", "w.log")))
        self.assertTrue(os.path.exists(os.path.join(self.d, "log", "tasks", "w.log.not-a-file")))

    def test_read_json_of_a_fifo_is_the_default(self):
        f = self.fifo("x.json")
        t0 = time.time()
        self.assertEqual(fns.read_json(f, {"d": 1}), {"d": 1})
        self.assertLess(time.time() - t0, 1)



class Q_RootReads(Sandbox):
    """Root's reads in a login's places never wait (issue #3084): a FIFO answers at
    once (refused); a symlink only when asked to follow; `kill -USR1` tells which
    read a live loop is in — its stacks in the log, the loop going on."""

    def test_open_ro(self):
        f = os.path.join(self.d, "f")
        put(f, "A=1\n")
        os.mkfifo(os.path.join(self.d, "fifo"))
        os.symlink(f, os.path.join(self.d, "ln"))
        with os.fdopen(fns.open_ro(f)) as fh:
            self.assertEqual(fh.read(), "A=1\n")
        t0 = time.time()
        with self.assertRaises(OSError):
            fns.open_ro(os.path.join(self.d, "fifo"))
        self.assertLess(time.time() - t0, 2, "a FIFO held the read")
        with self.assertRaises(OSError):
            fns.open_ro(os.path.join(self.d, "ln"))
        os.close(fns.open_ro(os.path.join(self.d, "ln"), follow=True))
        self.assertIsNone(fns._env_file(os.path.join(self.d, "fifo"), os.getuid()))
        self.assertEqual(fns.log_tail(os.path.join(self.d, "fifo")), [])
        self.assertEqual(fns._plist_label(os.path.join(self.d, "fifo")), "")
        self.assertEqual(fns._env_file(f, os.getuid()), {"A": "1"})

    def test_sigusr1_dumps_stacks_and_stays_up(self):
        sh = self.script("ok.sh", "exit 0\n")
        self.table(tasks=[{"name": "ok", "every": 0.1, "cmd": ["/bin/bash", sh]}])
        p = self.start()
        self.assertTrue(until(10, lambda: (self.task("ok").get("runs") or 0) >= 1), "the task never ran")
        p.send_signal(signal.SIGUSR1)
        err = os.path.join(self.d, "sup.err")

        def text():
            with open(err) as f:
                return f.read()
        self.assertTrue(until(5, lambda: "most recent call first" in text()), "no stack after SIGUSR1")
        # the dump is written thread by thread: wait for the main thread's, not one read
        self.assertTrue(until(5, lambda: "in run" in text()), text())
        n = self.task("ok").get("runs") or 0
        self.assertTrue(until(5, lambda: (self.task("ok").get("runs") or 0) > n), "the loop stopped after SIGUSR1")
        self.assertIsNone(p.poll())


class R_Entry(Sandbox):
    """The entry port (#3070): off is byte for byte as before; the switch comes
    from the environment or machine.env; only a plain public key becomes a line."""

    def test_off_adds_nothing(self):
        self.table(children=[{"name": "c", "cmd": ["/bin/sleep", "300"]}])
        self.start()
        until(10, lambda: self.child("c").get("pid"))
        time.sleep(0.5)
        out = self.run_sup("status").stdout
        self.assertFalse([l for l in out.splitlines() if l.startswith("entry")], out)
        self.assertNotIn("entry", self.state().get("children") or {})
        self.assertFalse(os.path.exists(os.path.join(self.d, "db", "entry")))
        self.assertEqual(self.run_sup("entry", "status", "--check").returncode, 2)
        self.assertEqual(self.run_sup("entry", "pull").returncode, 3)
        self.assertEqual(self.run_sup("entry", "ensure").returncode, 3)
        self.assertFalse(os.path.exists(os.path.join(self.d, "db", "entry")))

    def test_switch_from_machine_env(self):
        os.makedirs(os.path.join(self.d, "db"))
        put(os.path.join(self.d, "db", "machine.env"), "CCQUOTA_TOKEN=t\nFLEET_ENTRY=1\nFLEET_ENTRY_PORT=22123\n")
        with mock.patch.dict(os.environ):
            os.environ.update(FLEET_NODE_STATE=os.path.join(self.d, "db"), FLEET_NODE_TEST="1")
            os.environ.pop("FLEET_ENTRY", None)
            os.environ.pop("FLEET_ENTRY_PORT", None)
            self.assertEqual(fns.entry_settings(fns.Paths())[:2], (True, 22123))
            os.environ["FLEET_ENTRY"] = "0"           # the environment wins
            self.assertFalse(fns.entry_settings(fns.Paths())[0])
            c = fns.entry_child(fns.Paths())
            self.assertEqual(c["cmd"][-2:], ["-f", os.path.join(self.d, "db", "entry", "sshd_config")])
            self.assertEqual(c["reload_signal"], "HUP")
            agent = [x for x in fns.default_table(fns.Paths())["children"] if x["name"] == "node-agent"][0]
            self.assertIn(os.path.join(self.d, "db", "machine.env"), agent["reload"],
                          "the node program restarts when machine.env (its token, FLEET_ENTRY) changes")

    def test_key_lines(self):
        blob = ED25519_BLOB
        ok = fns.entry_key_line({"type": "ssh-ed25519", "b64": blob, "fp": "SHA256:abc"})
        self.assertEqual(ok, "ssh-ed25519 %s fleet:SHA256:abc\n" % blob)
        for bad in ({"type": "ssh-dss", "b64": blob, "fp": "x"},                    # not a kind the entry takes
                    {"type": "ssh-rsa", "b64": blob, "fp": "x"},                    # the blob says ed25519
                    {"type": "ssh-ed25519", "b64": blob + " command=\"sh\"", "fp": "x"},
                    {"type": "ssh-ed25519", "b64": blob, "fp": "x\nssh-ed25519 AAAA"},
                    {"type": "command=\"x\" ssh-ed25519", "b64": blob, "fp": "x"},
                    "ssh-ed25519 %s" % blob):
            self.assertIsNone(fns.entry_key_line(bad), bad)

    def test_old_sshd_is_never_started(self):
        """An sshd without PerSourcePenalties (OpenSSH < 9.8) is not put on the
        internet: no config, the book and the doctor's row say what is missing."""
        sshd = self.script("sshd", 'case "$1" in -t) exit 0 ;; -T) printf "passwordauthentication no\\n'
                           'kbdinteractiveauthentication no\\npermitrootlogin no\\nauthenticationmethods publickey\\n" ;; esac\n')
        me = __import__("pwd").getpwuid(os.getuid()).pw_name
        db = os.path.join(self.d, "db")
        os.makedirs(os.path.join(db, "logins"))
        open(os.path.join(db, "logins", me + ".env"), "w").close()
        put(os.path.join(self.d, "passwd"), {me: {"uid": os.getuid(), "gid": os.getgid(), "home": self.d}})
        blob = ED25519_BLOB
        lst = os.path.join(self.d, "list.json")
        with open(lst, "w") as f:
            json.dump({"version": 1, "logins": {me: {"person": "gh:1", "keys": [
                {"type": "ssh-ed25519", "b64": blob, "fp": "SHA256:x"}]}}}, f)
        env = {"FLEET_ENTRY": "1", "FLEET_ENTRY_SSHD": sshd, "FLEET_NODE_PASSWD": os.path.join(self.d, "passwd"),
               "FLEET_ENTRY_DSEDITGROUP": ""}
        r = self.run_sup("entry", "apply", lst, env=env)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("lacks PerSourcePenalties", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(db, "entry", "sshd_config")), "an old sshd got a config")
        c = self.run_sup("entry", "status", "--check", env=env)
        self.assertEqual(c.returncode, 1)
        self.assertIn("PerSourcePenalties", c.stdout)

    def test_config_is_the_convention(self):
        ep = fns.EntryPaths(fns.Paths())
        cfg = fns.entry_config(ep, 22022, ["bob", "alice"])
        for line in ("Port 22022", "AllowUsers alice bob", "AuthenticationMethods publickey",
                     "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no",
                     "AuthorizedKeysFile %s/%%u" % ep.keys, "PermitUserRC no", "PermitUserEnvironment no",
                     "ExposeAuthInfo yes", "AcceptEnv LANG LC_*", "MaxAuthTries 3", "LoginGraceTime 20", "MaxStartups 10:30:60",
                     "HostKey %s" % ep.hostkey):
            self.assertIn(line + "\n", cfg)
        self.assertNotIn(".ssh", "".join(l for l in cfg.splitlines(True) if not l.startswith("#")))
        self.assertNotIn("PerSourcePenalties", cfg, "the system default, never weakened here")

    def test_dispatch_once_the_runtime_carries_it(self):
        # issue #3071 (C5): the ForceCommand is the runtime's fleet-entry.sh, only
        # once the runtime has it — before that the config is #3070's, byte for byte
        with mock.patch.dict(os.environ):
            rt = os.path.join(self.d, "rt")
            os.makedirs(os.path.join(rt, "bin"))
            os.environ.update(FLEET_NODE_RUNTIME=rt, FLEET_NODE_STATE=os.path.join(self.d, "db"))
            os.environ.pop("FLEET_NODE_TEST", None)
            paths = fns.Paths()
            ep = fns.EntryPaths(paths)
            bare = fns.entry_config(ep, 22022, ["alice"], paths)
            self.assertNotIn("ForceCommand", bare)
            self.assertNotIn("SetEnv", bare)
            self.assertIn("Subsystem sftp internal-sftp\n", bare)
            self.assertEqual(bare, fns.entry_config(ep, 22022, ["alice"]))
            open(os.path.join(rt, "bin", "fleet-entry.sh"), "w").close()
            os.environ["FLEET_ENTRY_TEST_SETENV"] = "FLEET_ENTRY_VIEW=/x"   # not a test run: ignored
            cfg = fns.entry_config(ep, 22022, ["alice"], paths)
            self.assertIn("ForceCommand /bin/bash %s\n" % os.path.join(rt, "bin", "fleet-entry.sh"), cfg)
            self.assertIn("SetEnv FLEET_ENTRY_BOOK=%s\n" % ep.book, cfg)
            self.assertEqual(len([l for l in cfg.splitlines() if l.startswith("SetEnv")]), 1)
            sftp = [l for l in cfg.splitlines() if l.startswith("Subsystem sftp ")][0]
            if any(os.access(x, os.X_OK) for x in fns.ENTRY_SFTP_SERVERS):
                self.assertTrue(sftp.endswith("/sftp-server"), sftp)
            self.assertNotIn("DisableForwarding", cfg)

    def test_audit_lines(self):
        # issue #3071 (共同约定 11): what the listener logged, one line each, no key text
        book = {"logins": {"alice": {"person": "gh:1"}}}
        text = ("Connection from 1.2.3.4 port 5 on 0.0.0.0 port 22022\n"
                "Accepted publickey for alice from 1.2.3.4 port 5 ssh2: ED25519 SHA256:abc\n"
                "Failed publickey for alice from 6.6.6.6 port 7 ssh2: ED25519 SHA256:bad\n"
                "Invalid user mallory from 6.6.6.6 port 8\n"
                "User bob from 6.6.6.6 not allowed because not listed in AllowUsers\n")
        out = fns.entry_audit_lines(text, book, "mac-d", 100, 0)
        self.assertEqual([(d["login"], d["source_ip"], d["fp"], d["result"]) for d in out], [
            ("alice", "1.2.3.4", "SHA256:abc", "ok"), ("alice", "6.6.6.6", "SHA256:bad", "denied: key"),
            ("mallory", "6.6.6.6", "", "denied: no such login"), ("bob", "6.6.6.6", "", "denied: not on the entry")])
        self.assertEqual(out[0]["person"], "gh:1")
        self.assertEqual(out[0]["machine"], "mac-d")
        ids = [d["id"] for d in out]
        self.assertEqual(len(set(ids)), 4, "each line its own id (its byte offset)")
        self.assertEqual(ids[0], str(100 + len(text.splitlines(True)[0])))


class S_EntryReach(Sandbox):
    """Can the outside reach the entry port (#3072, EPIC #3067 C6)."""

    def check_reach(self, rc, *words):
        """`entry reach --check` exits <rc> and says each of <words>."""
        c = self.run_sup("entry", "reach", "--check")
        self.assertEqual(c.returncode, rc, c.stdout)
        for w in words:
            self.assertIn(w, c.stdout)
        return c

    def setUp(self):
        super(S_EntryReach, self).setUp()
        import http.server
        import socketserver
        import threading
        db = os.path.join(self.d, "db")
        os.makedirs(os.path.join(db, "entry"))
        self.posts, self.answer = [], {"code": 200, "body": {}}
        t = self

        class Hub(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                t.posts.append({"path": self.path, "auth": self.headers.get("Authorization"),
                                "body": json.loads(self.rfile.read(n).decode())})
                b = json.dumps(t.answer["body"]).encode()
                self.send_response(t.answer["code"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def log_message(self, *a):
                pass
        self.hub = socketserver.TCPServer(("127.0.0.1", 0), Hub)
        threading.Thread(target=self.hub.serve_forever, daemon=True).start()
        self.hub_port = self.hub.server_address[1]
        self.write_env()
        put(os.path.join(db, "entry", "ssh_host_ed25519_key.pub"), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk root@mac-d\n")
        fns.write_json(os.path.join(db, "entry", "state.json"), {"on": True, "allow": ["grace"], "version": 3})
        self.sshd = subprocess.Popen(["/bin/sleep", "300"])     # stands in for the entry sshd
        self.procs.append(self.sshd)
        fns.write_json(os.path.join(db, "state.json"), {"children": {"entry": {"pid": self.sshd.pid}}})
        ifs = os.path.join(self.d, "ifaddrs")
        with open(ifs, "w") as f:
            # Wi-Fi listed first: the hint must still name the default route's (wired) address
            f.write("en1 192.168.1.200/24\nen0 192.168.1.249/24\nen0 2408:8207:1:2::9/64 autoconf secured\n"
                    "en0 2408:8207:1:2:abcd::1/64 autoconf temporary\nen0 fe80::1/64\n"
                    "utun3 100.101.1.2/32\nutun3 fd7a:115c::1/48\nlo0 127.0.0.1/8\n")
        # a router that answers NAT-PMP from 127.0.0.1
        import socket
        import struct
        self.router = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.router.bind(("127.0.0.1", 0))
        self.router_ext = "100.77.0.3"

        def serve():
            while True:
                try:
                    data, src = self.router.recvfrom(64)
                except OSError:
                    return
                if data[:2] == b"\x00\x00":
                    self.router.sendto(struct.pack("!BBHI", 0, 128, 0, 1) + socket.inet_aton(self.router_ext), src)
                elif len(data) >= 12 and data[1] == 2:
                    ip_ = struct.unpack("!H", data[4:6])[0]
                    self.router.sendto(struct.pack("!BBHIHHI", 0, 130, 0, 1, ip_, ip_, 7200), src)
        threading.Thread(target=serve, daemon=True).start()
        self.env.update(FLEET_ENTRY_IFADDRS=ifs, FLEET_ENTRY_GATEWAY="127.0.0.1", FLEET_ENTRY_DEFAULT_IF="en0",
                        FLEET_ENTRY_NATPMP_PORT=str(self.router.getsockname()[1]), FLEET_ENTRY_SSDP="off",
                        FLEET_ENTRY_KEYSCAN="off")   # the port as this machine answers it: per test (T702)

    def tearDown(self):
        self.hub.shutdown()
        self.hub.server_close()
        self.router.close()
        super(S_EntryReach, self).tearDown()

    def write_env(self, extra=""):
        with open(os.path.join(self.d, "db", "machine.env"), "w") as f:
            f.write("CCQUOTA_HUB_URL=http://127.0.0.1:%d\nCCQUOTA_TOKEN=tok-m\nFLEET_ENTRY=1\n%s"
                    % (self.hub_port, extra))

    def reach_json(self):
        return fns.read_json(os.path.join(self.d, "db", "entry", "reach.json"), None)

    def test_unreachable_says_why_and_where_to_forward(self):
        self.answer["body"] = {"checked_at": "2026-10-10T00:00:00Z", "source": "100.77.0.3", "no_public": "cgnat",
                               "addrs": [{"addr": "2408:8207:1:2::9", "family": "ipv6", "port": 22022, "via": "ipv6",
                                          "reachable": False, "reason": "timeout"}]}
        r = self.run_sup("entry", "reach")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(len(self.posts), 1)
        p = self.posts[0]
        self.assertEqual(p["path"], "/v1/node/entry-reach")
        self.assertEqual(p["auth"], "Bearer tok-m")
        b = p["body"]
        self.assertEqual((b["port"], b["listening"]), (22022, True))
        self.assertTrue(b["host_key"].startswith("ssh-ed25519 AAAA") and "root@" not in b["host_key"], b["host_key"])
        self.assertEqual(b["v6"], ["2408:8207:1:2::9"], "a tunnel's, a temporary or a link-local IPv6 was reported")
        self.assertEqual(b["lan"], ["192.168.1.249", "192.168.1.200"], "the default route's interface goes first")
        self.assertNotIn("entry_port", b, "no entry= route, yet an entry port was reported")
        self.assertEqual(b["portmap"], {"method": "natpmp", "external_ip": "100.77.0.3", "external_port": 22022})
        f = os.path.join(self.d, "db", "entry", "reach.json")
        self.assertEqual(os.stat(f).st_mode & 0o777, 0o644)
        with open(f) as fh:
            self.assertNotIn("tok-m", fh.read())
        c = self.check_reach(1, "外面连不上", "[2408:8207:1:2::9]:22022 超时", "这台没有公网地址", "100.77.0.3",
                             "在路由器上把公网 TCP 22022 转发到 192.168.1.249:22022")
        self.assertNotIn("·  ·", c.stdout)

    def test_entry_route_port(self):
        """The router forwards a public port of its own to the entry (the login's
        entry= route, mac-d's :22123); public= is the system sshd's and is not read."""
        os.makedirs(os.path.join(self.d, "db", "logins"))
        with open(os.path.join(self.d, "db", "logins", "grace.env"), "w") as f:
            f.write("CCQUOTA_TOKEN=x\nCCQUOTA_FLEET_NODE_ROUTES=public=ssh.minihaowan.com:22023,"
                    "entry=ssh.minihaowan.com:22123,lan=192.168.1.249\n")
        self.answer["body"] = {"checked_at": "x", "source": "198.51.100.213", "addrs": [
            {"addr": "198.51.100.213", "family": "ipv4", "port": 22123, "via": "source",
             "reachable": False, "reason": "refused"}]}
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        b = self.posts[0]["body"]
        self.assertEqual((b["entry_host"], b["entry_port"], b["port"]), ("ssh.minihaowan.com", 22123, 22022))
        self.assertNotIn("public_port", b)
        self.check_reach(1, "198.51.100.213:22123 被拒", "在路由器上把公网 TCP 22123 转发到 192.168.1.249:22022")

    def test_public_route_alone_is_not_the_entry(self):
        put(os.path.join(self.d, "db", "machine.env"), "CCQUOTA_FLEET_NODE_ROUTES=public=ssh.minihaowan.com:22023\n", append=True)
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        self.assertNotIn("entry_port", self.posts[0]["body"], "public= (the system sshd) was taken for the entry")

    def test_reachable_passes(self):
        self.answer["body"] = {"checked_at": "2026-10-10T00:00:00Z", "source": "203.0.114.7",
                               "addrs": [{"addr": "203.0.114.7", "family": "ipv4", "port": 22022, "via": "source",
                                          "reachable": True},
                                         {"addr": "2408:8207:1:2::9", "family": "ipv6", "port": 22022,
                                          "via": "ipv6", "reachable": False, "reason": "hostkey"}]}
        self.router_ext = "203.0.114.7"
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        self.check_reach(0, "外面连得上：203.0.114.7:22022（IPv4）", "连不上：[2408:8207:1:2::9]:22022 钥匙不符",
                         "路由器已开端口（NATPMP → 22022）")

    def test_router_silent_or_refusing_never_stops_the_report(self):
        self.router.close()             # nothing answers NAT-PMP any more
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        t0 = time.time()
        r = self.run_sup("entry", "reach")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertLess(time.time() - t0, 10, "a silent router held the report")
        self.assertEqual(len(self.posts), 1, "the report was not sent")
        pm = self.posts[0]["body"]["portmap"]
        self.assertTrue(pm.get("error") and "external_ip" not in pm, pm)
        c = self.run_sup("entry", "reach", "--check")
        self.assertEqual(c.returncode, 1)
        self.assertIn("路由器没自动开端口", c.stdout)

    def test_hub_away_keeps_the_last_verdict(self):
        self.answer["body"] = {"checked_at": "x", "addrs": [{"addr": "203.0.114.7", "family": "ipv4",
                                                             "port": 22022, "reachable": True}]}
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        self.answer["code"] = 503
        r = self.run_sup("entry", "reach")
        self.assertEqual(r.returncode, 1)
        j = self.reach_json()
        self.assertTrue(j["error"].startswith("the hub: 503"), j)
        self.assertEqual(j["verdict"]["addrs"][0]["addr"], "203.0.114.7")
        c = self.run_sup("entry", "reach", "--check")
        self.assertEqual(c.returncode, 0, c.stdout)
        self.assertIn("这次没报上：the hub: 503", c.stdout)
        # twenty minutes on with no new answer: stale is a WARN
        j["verdict_at"] = time.time() - 1300
        fns.write_json(os.path.join(self.d, "db", "entry", "reach.json"), j)
        c = self.run_sup("entry", "reach", "--check")
        self.assertEqual(c.returncode, 1)
        self.assertIn("结果过期", c.stdout)

    def test_portmap_off_asks_no_router(self):
        self.write_env("FLEET_ENTRY_PORTMAP=off\n")
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        self.assertNotIn("portmap", self.posts[0]["body"])

    def fake_port(self, key, holder=None):
        """What answers on 127.0.0.1:22022: ssh-keyscan prints <key>, lsof names
        <holder> (pid, command) as the listener (T702)."""
        scan, lsof = os.path.join(self.d, "keyscan"), os.path.join(self.d, "lsof")
        put(scan, "#!/bin/sh\n" + ("echo \"[127.0.0.1]:22022 %s\"\n" % key if key else "") + "exit 0\n", 0o755)
        if holder:
            put(lsof, "#!/bin/sh\necho p%s\n" % holder, 0o755)
        else:
            put(lsof, "#!/bin/sh\nexit 1\n", 0o755)
        self.env.update(FLEET_ENTRY_KEYSCAN=scan, FLEET_ENTRY_LSOF=lsof)

    def own_key(self):
        with open(os.path.join(self.d, "db", "entry", "ssh_host_ed25519_key.pub")) as f:
            return " ".join(f.read().split()[:2])

    def test_listening_is_what_answers_the_port(self):
        """T702: the child's pid alone said "not listening" while a listener an
        earlier daemon left held the port with the entry's own key — and "deaf"
        made the hub dial nothing. Now: the entry's key on the port is listening,
        whatever the pid; another key there is not, and who holds it is said."""
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        self.sshd.kill()
        self.sshd.wait()
        stray = subprocess.Popen(["/bin/sleep", "300"])
        self.procs.append(stray)
        self.fake_port(self.own_key(), stray.pid)
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        b = self.posts[-1]["body"]
        self.assertTrue(b["listening"], b)
        self.assertTrue(b.get("held_by", "").startswith("pid %d:" % stray.pid), b)
        self.check_reach(1, "被另一个程序占着", "pid %d" % stray.pid)
        # another program's key on the port: not the entry, not listening
        self.fake_port("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherOtherOtherOtherOtherOtherOtherOther0")
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        b = self.posts[-1]["body"]
        self.assertFalse(b["listening"], b)
        self.assertIn("another program", b.get("held_by", ""), b)
        self.assertNotIn("portmap", b, "the router was asked to forward to a port the entry does not hold")

    def test_own_child_on_the_port_says_nothing_more(self):
        """The daemon's own child answering with the entry's key: listening, no held_by."""
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        self.fake_port(self.own_key(), self.sshd.pid)
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        b = self.posts[-1]["body"]
        self.assertTrue(b["listening"], b)
        self.assertNotIn("held_by", b)
        # nothing answers yet (a listener still starting): the child's pid decides, as before
        self.fake_port("")
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        self.assertTrue(self.posts[-1]["body"]["listening"])

    def test_off_or_nobody_home_is_no_row(self):
        fns.write_json(os.path.join(self.d, "db", "entry", "state.json"), {"on": True, "allow": []})
        self.answer["body"] = {"checked_at": "x", "addrs": []}
        self.assertEqual(self.run_sup("entry", "reach").returncode, 0)
        b = self.posts[0]["body"]
        self.assertFalse(b["listening"])
        self.assertNotIn("portmap", b, "nothing listens, yet the router was asked to forward")
        self.assertEqual(self.run_sup("entry", "reach", "--check").returncode, 2)
        put(os.path.join(self.d, "db", "machine.env"), "CCQUOTA_TOKEN=t\n")
        self.assertEqual(self.run_sup("entry", "reach").returncode, 3)
        self.assertEqual(self.run_sup("entry", "reach", "--check").returncode, 2)


class T_RootCore(H_Accounts):
    """The same account half with the root core answering (#3555, EPIC #3500 C13):
    every account job and the core-held machine tasks go through it — the daemon's
    child only asks (`fleet-node-core.py call … --follow`), the core runs the job as
    its login; release stops it through the core. Without a core (every other case
    here) it is the old road, byte for byte."""
    CORE = ("fleet-node-core.py", "fleet_node_core.py", "fleet_ed25519.py", "fleet-release-verify.py", "fleet-node-supervisor.py")

    def setUp(self):
        H_Accounts.setUp(self)
        rt_bin = os.path.join(self.d, "rt", "bin")
        os.makedirs(rt_bin, exist_ok=True)
        for n in self.CORE:
            shutil.copy(os.path.join(BIN, n), rt_bin)
        self.env.update({"FLEET_NODE_CORE_SOCK": os.path.join(self.d, "core.sock"),
                         "FLEET_NODE_CORE_LOG": os.path.join(self.d, "core.log"),
                         "FLEET_NODE_CORE_PEER_UID": str(os.getuid())})
        core = subprocess.Popen([sys.executable, os.path.join(rt_bin, "fleet-node-core.py"), "serve"], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.d, "core.err"), "a"))
        self.procs.append(core)
        self.assertTrue(until(10, lambda: os.path.exists(self.env["FLEET_NODE_CORE_SOCK"])), "no core")

    def corelog(self):
        return slurp(os.path.join(self.d, "core.log"))

    def test_account_half_through_the_core(self):
        H_Accounts.test_runs_as_account_and_isolated(self)
        log = self.corelog()
        self.assertIn("op=run-as", log, "no account job went through the core")
        # the only refusal allowed: a start racing the release (alice no longer managed)
        for line in log.splitlines():
            if "refused" in line:
                self.assertIn("is not managed here", line, log)
        self.assertTrue(until(10, lambda: "op=stop-as" in self.corelog()), "release did not stop the job through the core")
        st = self.run_sup("status").stdout
        self.assertIn("core        serving", st)

    def test_machine_task_through_the_core(self):
        rt_bin = os.path.join(self.d, "rt", "bin")
        put(os.path.join(rt_bin, "fleet-memguard.sh"), "#!/bin/bash\necho \"mg $*\" >> %s/mg.log\n" % self.d, 0o755)
        fail = self.script("fail.sh", "exit 1\n")
        self.table(tasks=[{"name": "memguard", "every": 0.2, "cmd": ["/bin/bash", fail],
                           "core": {"op": "memguard", "args": {"level": "once"}}}])
        self.start()
        self.assertTrue(until(10, lambda: (self.task("memguard").get("runs") or 0) >= 2), self.task("memguard"))
        self.assertTrue(until(5, lambda: self.task("memguard").get("rc") == 0), "the core's answer is the task's rc")
        self.assertIn("mg --once", open(os.path.join(self.d, "mg.log")).read())
        self.assertIn("op=memguard", self.corelog())
        # FLEET_NODE_CORE=0: the old road — the table's own cmd (here: exit 1)
        for p in self.procs[1:]:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=10)
        self.start(FLEET_NODE_CORE="0")
        runs = self.task("memguard").get("runs") or 0
        self.assertTrue(until(10, lambda: (self.task("memguard").get("runs") or 0) >= runs + 2))
        self.assertEqual(self.task("memguard").get("rc"), 1, "FLEET_NODE_CORE=0 still asked the core")



class U_OnDemand(Sandbox):
    """The chat service on demand (issue #3647, EPIC #3642 C5): an exit with
    SVC_IDLE_RC is `idle` — not restarted, not `down` — until its entry changes;
    `service ensure --name webchat` registers it from the login's home, starts a
    stopped / idle one, and waits for its socket's /healthz."""

    def setUp(self):
        Sandbox.setUp(self)
        # a unix socket path is ≤ 104 bytes: the home lives under a short /tmp dir
        self.short = (self.own_directory(prefix="fw.", dir="/tmp") if hasattr(self, "budget")
                      else tempfile.mkdtemp(prefix="fw.", dir="/tmp"))
        self.home = os.path.join(self.short, "alice")
        self.passwd({"alice": self.home})
        self.table()

    def tearDown(self):
        Sandbox.tearDown(self)
        if not hasattr(self, "budget"):
            shutil.rmtree(self.short, ignore_errors=True)


    def test_idle_exit_stays_off_until_its_entry_changes(self):
        sh = self.script("idle.sh", "echo up; sleep 0.3; exit %d\n" % fns.SVC_IDLE_RC)
        self.assertEqual(self.svc("add", "--login", "alice", "--name", "nap", "--", "/bin/bash", sh).returncode, 0)
        self.start()
        key = "svc:alice/nap"
        self.assertTrue(until(10, lambda: self.child(key).get("idle")), "an idle exit was not marked idle")
        st = self.services()["nap"]
        self.assertEqual(st["status"], "idle", st)
        r0 = self.child(key).get("restarts") or 0
        time.sleep(1.5)
        self.assertFalse(fns.pid_alive(self.child(key).get("pid")), "an idle service was started again")
        self.assertEqual(self.child(key).get("restarts") or 0, r0)
        self.assertEqual(self.services()["nap"]["status"], "idle")
        # a rewrite (service start) brings it back
        started = self.child(key).get("started")
        self.assertEqual(self.svc("start", "--login", "alice", "--name", "nap").returncode, 0)
        self.assertTrue(until(10, lambda: (self.child(key).get("started") or 0) != started),
                        "start did not bring an idle service back")

    def stub_webchat(self):
        """Answer /healthz until the test requests an idle exit (75)."""
        b = os.path.join(self.home, ".claude", "fleet", "bin")
        os.makedirs(b)
        p = os.path.join(b, "fleet-webchat.sh")
        with open(os.path.join(b, "serve.py"), "w") as f:
            f.write(r"""
import os, socket, sys
d = os.path.join(os.environ["HOME"], ".config", "claude-fleet", "webchat")
os.makedirs(d, 0o700, exist_ok=True)
s = os.path.join(d, "chat.sock")
try: os.unlink(s)
except OSError: pass
l = socket.socket(socket.AF_UNIX); l.bind(s); l.listen(4); l.settimeout(0.2)
idle = os.path.join(d, "idle")
while not os.path.exists(idle):
    try: c, _ = l.accept()
    except socket.timeout: continue
    c.recv(512); c.sendall(b"HTTP/1.0 200 OK\r\n\r\n{}"); c.close()
os.unlink(idle); os.unlink(s); sys.exit(75)
""")
        with open(p, "w") as f:
            import shlex
            f.write('#!/bin/bash\n[ "$1" = serve ] || exit 2\nexec %s -I %s\n'
                    % (shlex.quote(sys.executable), shlex.quote(os.path.join(b, "serve.py"))))
        os.chmod(p, 0o755)
        return p, os.path.join(self.home, ".config", "claude-fleet", "webchat", "idle")

    def registered_webchat(self):
        p, idle = self.stub_webchat()
        self.start()
        self.trace_stage("U registered ready (3 tries)")
        r = self.svc("ensure", "--login", "alice", "--name", "webchat", "--wait", "3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)  # U2; real prerequisite in each scene
        self.assertIn("registered · ready", r.stdout)  # U3
        ent = json.load(open(os.path.join(self.d, "db", "logins", "alice", "services", "webchat.json")))
        self.assertEqual(ent["exec"], [p, "serve"])  # U4
        self.assertEqual(ent["paths"], [os.path.join(self.home, ".config", "claude-fleet", "webchat")])  # U5
        self.assertEqual(ent["state"], "enabled")  # U6
        return idle

    def test_pod_ensure(self):
        """No test-mode root bypass: the pod's own login registers and runs svc."""
        self.stub_webchat()
        uid = os.geteuid() or 501
        ident = (uid, os.getgid(), self.home)
        env = dict(self.env, FLEET_NODE_TEST="0", FLEET_NODE_PROFILE="user-pod",
                   FLEET_POD_LOGIN="alice", FLEET_NODE_ENSURE_SECS="3")
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(fns, "MAC", False), \
                mock.patch.object(fns.os, "geteuid", return_value=uid), \
                mock.patch.object(fns, "account_ident", return_value=ident):
            paths = fns.Paths()
            # Keep the production pod child table. Its machine files are absent,
            # so only the newly registered service is eligible to start.
            sup = fns.Supervisor(paths, fns.default_table(paths))
            sup.ensure_dirs()
            healthy = fns._sock_healthy

            def tick(sock):
                sup.tend_children()
                return healthy(sock)

            try:
                with mock.patch.object(fns, "_sock_healthy", side_effect=tick):
                    self.assertEqual(fns.service_ensure(paths, "alice", "webchat", 1), 0)
                child = sup.procs["svc:alice/webchat"]
                self.assertIsNone(child.poll())
                self.assertEqual(set(sup.procs), {"svc:alice/webchat"})
                self.assertEqual(fns.service_ensure(paths, "alice", "webchat", 1), 0)
                self.assertEqual(sup.procs["svc:alice/webchat"].pid, child.pid)
                # An env flag alone grants nothing: target and effective UID
                # must both identify the pod's own login.
                self.assertEqual(fns.service_ensure(paths, "bob", "webchat", 0), 1)
                with mock.patch.object(fns.os, "geteuid", return_value=uid + 1):
                    self.assertEqual(fns.service_ensure(paths, "alice", "webchat", 0), 1)
                with mock.patch.dict(os.environ, {"FLEET_NODE_PROFILE": ""}):
                    self.assertEqual(fns.service_ensure(paths, "alice", "webchat", 0), 1)
                self.assertFalse(os.path.exists(fns.service_dir(paths, "bob")))
            finally:
                for name in list(sup.procs):
                    sup.stop_one(name)

    def running_webchat(self):
        idle = self.registered_webchat()
        self.trace_stage("U running ready (3 tries)")
        r = self.svc("ensure", "--login", "alice", "--name", "webchat", "--wait", "3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)  # U7
        self.assertIn("running · ready", r.stdout, r.stderr)  # U8
        return idle

    def test_ensure_registers_starts_and_waits(self):
        self.trace_stage("U reject unknown name")
        self.assertEqual(self.svc("ensure", "--login", "alice", "--name", "sms").returncode, 2,
                         "a name off the on-demand table was ensured")  # U1
        self.running_webchat()

    def idle_restarted_webchat(self):
        # This is a real prefix of each caller's own service history, not a
        # result borrowed from the independent idle entry or a prewritten state.
        idle = self.running_webchat()
        # #3737: explicit exit, not a fixed service lifetime racing ensure.
        self.trace_stage("U request exit 75 and await idle")
        with open(idle, "w"):
            pass
        self.assertTrue(self.wait_for(15, lambda: self.services()["webchat"]["status"] == "idle"),
                        self.services())  # U9; original diagnostic status query retained
        self.assertEqual(self.child("svc:alice/webchat").get("last_rc"), fns.SVC_IDLE_RC)  # U10
        # Also retain a real no-autostart interval before explicit ensure.
        before = self.child("svc:alice/webchat").get("restarts") or 0
        time.sleep(1.5)
        self.assertFalse(fns.pid_alive(self.child("svc:alice/webchat").get("pid")))
        self.assertEqual(self.child("svc:alice/webchat").get("restarts") or 0, before)
        self.assertEqual(self.services()["webchat"]["status"], "idle")
        self.trace_stage("U idle restart ready (3 tries)")
        r = self.svc("ensure", "--login", "alice", "--name", "webchat", "--wait", "3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)  # U11
        self.assertIn("started · ready", r.stdout)  # U12

    def test_ensure_after_idle(self):
        self.idle_restarted_webchat()

    def test_ensure_after_stop(self):
        # Stop the service AFTER its real exit75/idle/ensure restart, in this
        # same sandbox and daemon. A fresh registered service is not equivalent.
        self.idle_restarted_webchat()
        self.trace_stage("U explicit stop and await stopped")
        self.assertEqual(self.svc("stop", "--login", "alice", "--name", "webchat").returncode, 0)  # U13
        self.assertTrue(self.wait_for(15, lambda: self.services()["webchat"]["status"] == "stopped"))  # U14
        ent_path = os.path.join(self.d, "db", "logins", "alice", "services", "webchat.json")
        self.assertEqual(json.load(open(ent_path))["state"], "stopped")
        self.trace_stage("U stopped restart ready (3 tries)")
        r = self.svc("ensure", "--login", "alice", "--name", "webchat", "--wait", "3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)  # U15
        self.assertIn("started · ready", r.stdout, r.stderr)  # U16
        self.assertEqual(json.load(open(ent_path))["state"], "enabled")

    def test_start_races_a_service_call(self):
        # #3648: `service ensure` made db/ between the daemon's look and its make —
        # the daemon died on FileExistsError and nothing ever started webchat
        with mock.patch.dict(os.environ, {k: v for k, v in self.env.items() if k.startswith("FLEET_NODE_")}):
            paths = fns.Paths()
        os.makedirs(paths.state, exist_ok=True)
        sup = fns.Supervisor.__new__(fns.Supervisor)
        sup.seated, sup.p = False, paths
        real = fns.os.path.isdir
        fns.os.path.isdir = lambda d: False  # every dir "appears" after the look
        try:
            sup.ensure_dirs()
        finally:
            fns.os.path.isdir = real
        self.assertTrue(os.path.isdir(os.path.join(paths.state, "tmp")))

    def test_ensure_not_ready(self):
        b = os.path.join(self.home, ".claude", "fleet", "bin")
        os.makedirs(b)
        put(os.path.join(b, "fleet-webchat.sh"), "#!/bin/bash\nexec sleep 300\n", 0o755)
        self.start()
        r = self.svc("ensure", "--login", "alice", "--name", "webchat", "--wait", "2",
                     env={"FLEET_NODE_ENSURE_SECS": "1"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("not ready after 2 tries", r.stderr)

class V_SessionUnits(H_Accounts):
    """A login with no session keeps no session-only process, and a restart never
    doubles one (issue #3671, EPIC #3500 C14): a `session` unit runs only while the
    login's published count is above 0 (none / stale = runs, as before); an account
    unit an earlier daemon started is adopted after its wrapper exec'd; an orphaned
    copy of one is stopped; an earlier daemon's still-running task is not run a
    second time beside it."""

    def setUp(self):
        H_Accounts.setUp(self)
        self.sd = os.path.join(self.d, "sessions")
        os.makedirs(self.sd)
        # the count read every 0.2 s, not the daemon's 5: a case waits for each change it makes
        self.env.update({"FLEET_MACHINE_SESSIONS_DIR": self.sd, "FLEET_NODE_SESSION_HOLD": "0",
                         "FLEET_NODE_STRAY_SECS": "0.5", "FLEET_NODE_SESSION_READ_SECS": "0.2"})

    def count(self, who, n, age=0):
        put(os.path.join(self.sd, who), "%d %d\n" % (n, int(time.time()) - age))

    def copies(self, who, script):
        out = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="]).decode()
        return [l.split() for l in out.splitlines()
                if os.path.join(self.home(who), ".claude", "fleet", "bin", script) in l and "/bin/bash" in l]

    def test_session_unit_runs_only_with_a_session(self):
        # the table's class reaches the account entry (#3671)
        os.makedirs(os.path.join(self.d, "rt", "conf"))
        put(os.path.join(self.d, "rt", "conf", "node-tasks.tsv"), "spin\tunit\tsession\tx\n")
        self.assertEqual(fns.table_session_units(os.path.join(self.d, "rt")), {"spin"})
        loop = "while :; do sleep 1; done\n"
        os.makedirs(os.path.join(self.home("carol"), ".claude", "fleet", "bin"))
        os.makedirs(os.path.join(self.home("carol"), "Library", "LaunchAgents"))
        for who in ("alice", "bob", "carol"):
            self.acct_script(who, "spin.sh", loop)
            self.acct_script(who, "keep.sh", loop)
        self.acct_table(
            {"name": "spin", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/spin.sh"], "keepalive": True,
             "session": True},
            {"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": True})
        with open(os.path.join(self.d, "passwd.json")) as f:
            pw = json.load(f)
        pw["carol"] = dict(pw["alice"], home=self.home("carol"))
        put(os.path.join(self.d, "passwd.json"), pw)
        for who in ("alice", "bob", "carol"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.count("alice", 0)
        self.count("bob", 2)
        self.count("carol", 0, age=900)   # a stale count is no count: it runs
        self.start()
        self.assertTrue(until(10, lambda: self.child("alice/keep").get("pid") and self.child("bob/spin").get("pid")
                              and self.child("carol/spin").get("pid")), self.state().get("children"))
        self.assertTrue(until(5, lambda: self.child("alice/spin").get("status") == fns.NO_SESSION),
                        self.child("alice/spin"))
        self.assertFalse(self.child("alice/spin").get("pid"), "a login with no session runs its session unit")
        self.assertEqual(self.copies("alice", "spin.sh"), [])
        self.assertIn("account alice             2/2 ok", self.run_sup("status").stdout,
                      "a session unit kept off is not a failure")
        # a session opens: it starts (the count is read every FLEET_NODE_SESSION_READ_SECS); it closes: it stops
        self.count("alice", 1)
        self.assertTrue(until(10, lambda: self.child("alice/spin").get("pid")), "never started with a session")
        pid = self.child("alice/spin")["pid"]
        self.count("alice", 0)
        self.assertTrue(until(10, lambda: not fns.pid_alive(pid)), "kept running with no session")
        self.assertTrue(until(5, lambda: self.child("alice/spin").get("status") == fns.NO_SESSION),
                        self.child("alice/spin"))
        # the switch off: every one runs
        self.procs[-1].send_signal(signal.SIGTERM)
        self.procs[-1].wait(timeout=15)
        self.start(FLEET_NODE_SESSION_UNITS="0")
        self.assertTrue(until(10, lambda: self.child("alice/spin").get("pid")), "FLEET_NODE_SESSION_UNITS=0 still gates")

    def test_spare_login_runs_no_github_job(self):
        # issue #4231: the GitHub loops (issue-bridge, pr-refresh — class `worker`)
        # are interval TASKS; a spare login with no session ran both every 15 s
        rt = os.path.join(self.d, "rt")
        os.makedirs(rt)
        root = os.path.dirname(BIN)
        for x in ("launchd", "conf"):
            os.symlink(os.path.join(root, x), os.path.join(rt, x))
        with mock.patch.dict(os.environ):
            os.environ.update({k: v for k, v in self.env.items() if k.startswith("FLEET_NODE_")})
            os.environ["FLEET_NODE_RUNTIME"] = rt
            units = {u["name"]: u for u in fns.account_units(fns.Paths())}
        # the shipped GitHub loops left with issue #4899: no class-worker unit is left
        self.assertEqual(fns.table_worker_units(rt), set())
        for other in ("collect", "diskguard", "cleanup", "install-sync"):
            self.assertFalse(units[other].get("session"), "%s must run with no session" % other)
        self.assertFalse(units["spinner"].get("asleep"), "a session unit counts the awake ones only")
        # the daemon: alice has no session (spare), bob's only worker is asleep
        # (third field), carol has one awake — the GitHub task runs for bob and carol
        os.makedirs(os.path.join(self.home("carol"), ".claude", "fleet", "bin"))
        os.makedirs(os.path.join(self.home("carol"), "Library", "LaunchAgents"))
        with open(os.path.join(self.d, "passwd.json")) as f:
            pw = json.load(f)
        pw["carol"] = dict(pw["alice"], home=self.home("carol"))
        put(os.path.join(self.d, "passwd.json"), pw)
        for who in ("alice", "bob", "carol"):
            self.acct_script(who, "gh-loop.sh", 'echo x >> "$HOME/gh-runs"\n')
            self.acct_script(who, "collect.sh", 'echo x >> "$HOME/collect-runs"\n')
        self.acct_table(
            {"name": "gh", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/gh-loop.sh"], "every": 0.3,
             "session": True, "asleep": True},
            {"name": "collect", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/collect.sh"], "every": 0.3})
        for who in ("alice", "bob", "carol"):
            self.assertEqual(self.run_sup("account", "adopt", who).returncode, 0)
        self.count("alice", 0)
        put(os.path.join(self.sd, "bob"), "0 %d 1\n" % int(time.time()))
        self.count("carol", 1)
        self.start()
        runs = lambda who, what: os.path.exists(os.path.join(self.home(who), what))
        self.assertTrue(until(10, lambda: runs("bob", "gh-runs") and runs("carol", "gh-runs")
                              and runs("alice", "collect-runs")), self.state().get("tasks"))
        self.assertTrue(until(5, lambda: self.task("alice/gh").get("result") == fns.NO_SESSION),
                        self.task("alice/gh"))
        time.sleep(1)
        self.assertFalse(runs("alice", "gh-runs"), "a spare login with no session ran its GitHub job")
        # a worker opens on the spare login: its GitHub job starts
        self.count("alice", 1)
        self.assertTrue(until(10, lambda: runs("alice", "gh-runs")), "never ran once the login had a session")

    def test_restart_adopts_and_strays_stop(self):
        self.acct_script("alice", "keep.sh", "while :; do sleep 1; done\n")
        self.acct_table({"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"],
                         "keepalive": True})
        self.assertEqual(self.run_sup("account", "adopt", "alice").returncode, 0)
        sup = self.start()
        pid = until(10, lambda: self.child("alice/keep").get("pid"))
        self.assertTrue(pid)
        self.assertTrue(until(5, lambda: len(self.copies("alice", "keep.sh")) == 1))
        # the daemon dies hard (a watchdog exit, kill -9): its child lives on
        sup.kill()
        sup.wait()
        self.start()
        time.sleep(2)
        self.assertEqual(self.child("alice/keep").get("pid"), pid, "the live unit was not adopted")
        self.assertEqual([c[0] for c in self.copies("alice", "keep.sh")], [str(pid)],
                         "a restart started a second copy beside the first")
        # a copy an older daemon left behind (an orphan, PPID 1) is stopped
        script = os.path.join(self.home("alice"), ".claude", "fleet", "bin", "keep.sh")
        subprocess.run(["/bin/bash", "-c", '"$1" "$2" </dev/null >/dev/null 2>&1 &', "_", "/bin/bash", script],
                       start_new_session=True)
        stray = until(5, lambda: [c for c in self.copies("alice", "keep.sh") if c[0] != str(pid)])
        self.assertTrue(stray, "the stray never started")
        if stray[0][1] != "1":
            self.skipTest("orphans are not reparented to pid 1 here (a subreaper)")
        self.assertTrue(until(10, lambda: [c[0] for c in self.copies("alice", "keep.sh")] == [str(pid)]),
                        "the orphaned copy still runs: %s" % self.copies("alice", "keep.sh"))
        self.assertTrue(fns.pid_alive(pid), "the sweep stopped the unit it tends")

    def test_earlier_daemons_task_not_doubled(self):
        slow = self.script("slow.sh", 'echo $$ >> "%s/runs"; sleep 4\n' % self.d)
        self.table(tasks=[{"name": "slow", "cmd": ["/bin/bash", slow], "every": 0.2, "timeout": 30}])
        sup = self.start()
        self.assertTrue(until(10, lambda: os.path.exists(os.path.join(self.d, "runs"))))
        until(5, lambda: self.task("slow").get("pid"))
        sup.kill()
        sup.wait()
        self.start()
        time.sleep(2)
        with open(os.path.join(self.d, "runs")) as f:
            runs = f.read().split()
        self.assertEqual(len(runs), 1, "a second copy started beside the earlier daemon's run: %s" % runs)
        self.assertTrue(until(10, lambda: len(open(os.path.join(self.d, "runs")).read().split()) >= 2),
                        "once the earlier run ended the task never ran again")


# T_RootCore / V_SessionUnits run only their own cases; the rest of H_Accounts is the no-core road
for _cls in (T_RootCore, V_SessionUnits):
    for _n in dir(H_Accounts):
        if _n.startswith("test_") and _n not in _cls.__dict__:
            setattr(_cls, _n, None)


class Z_ForgetZombie(unittest.TestCase):
    """A run that ended but is not reaped yet (stat Z) is not «running»: a
    recycle's forget never waits for the daemon's tick to reap it (#4044)."""

    @staticmethod
    def drill_probe():
        # Exercise the assertion used by linux-remove-task-running, independently
        # of the supervisor's own liveness reader (bin/fleet-break-it-node-selftest.sh).
        with open(os.path.join(os.path.dirname(__file__), "fleet-break-it-node-selftest.sh")) as f:
            body = f.read().split("_forget_task_running() {", 1)[1].split("\n}", 1)[0]
        return "set -uo pipefail\n_forget_task_running() {" + body + "\n}\n"

    def test_drill_reaped_between_reads(self):
        """#4448: reap a real child AFTER kill(0) but BEFORE ps reads it."""
        p = subprocess.Popen(["sleep", "30"])
        probe = subprocess.Popen(["bash", "-c", self.drill_probe() + '''
ps() {
  printf 'before-ps\\n' >&3
  read -r -t 5 proceed || return 2
  command ps "$@"
}
_forget_task_running "$1" 3>&1
''', "probe", str(p.pid)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, universal_newlines=True)
        try:
            self.assertEqual(probe.stdout.readline(), "before-ps\n")
            # kill(0) succeeded for this exact pid. Reap it before allowing the
            # real ps to run: no scheduling luck, retries or added sleep.
            p.kill()
            p.wait(timeout=5)
            out, err = probe.communicate("continue\n", timeout=5)
            self.assertEqual(probe.returncode, 1, (out, err, "a reaped task is not running"))
        finally:
            p.kill()
            p.wait()
            if probe.poll() is None:
                probe.kill()
            probe.communicate()

    def test_drill_live_zombie_and_gone(self):
        p = subprocess.Popen(["sleep", "30"])

        def check(want, ps_override=""):
            r = subprocess.run(["bash", "-c", self.drill_probe() + ps_override
                                + '\n_forget_task_running "$1"', "probe", str(p.pid)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            self.assertEqual(r.returncode, want, r.stderr)
        try:
            self.assertEqual(fns._zombies([p.pid]), set())
            check(0)                           # a live task still fails the drill
            check(0, "ps() { return 1; }")    # an unreadable ps never proves exit
            p.kill()
            self.assertTrue(until(5, lambda: fns._zombies([p.pid]) == {p.pid}), "a killed, unreaped child reads as a zombie")
            # a zombie is not running (the daemon's own reads)
            with mock.patch.object(fns, "read_json", return_value={"tasks": {"bob/job": {"pid": p.pid}}}):
                paths = mock.Mock(state_file="/nonexistent")
                self.assertFalse(fns._account_running(paths, "bob"))
                self.assertEqual(fns._account_pids(paths, "bob"), [])
            check(1)                           # exited, awaiting the parent's reap
            p.wait(timeout=5)
            check(1)                           # already gone before the first read
        finally:
            p.kill()
            p.wait()

    def test_reaped_between_reads_is_not_running(self):
        """#4278: the run is reaped between _account_pids' kill(0) and the ps —
        ps lists nothing and exits 1; the gone pid must not stay «running»."""
        p = subprocess.Popen(["sleep", "30"])
        p.kill()
        p.wait()                                     # reaped: the pid is gone
        real = fns.pid_alive
        calls = []

        def alive(pid):                              # the first read predates the reap
            calls.append(pid)
            return True if len(calls) == 1 else real(pid)
        st = {"tasks": {"bob/job": {"pid": p.pid}}}
        with mock.patch.object(fns, "read_json", return_value=st), mock.patch.object(fns, "pid_alive", alive):
            paths = mock.Mock(state_file="/nonexistent")
            self.assertEqual(fns._account_pids(paths, "bob"), [])
        self.assertEqual(len(calls), 2, "the unlisted pid is re-asked of kill(0)")

    def test_unlisted_but_alive_stays_running(self):
        """An unlisted pid kill(0) still answers for (EPERM, a ps that lists
        nothing) is never taken for ended — only a re-read that says gone is."""
        err = subprocess.CalledProcessError(1, ["ps"], output="")
        with mock.patch.object(fns.subprocess, "check_output", side_effect=err), \
                mock.patch.object(fns, "pid_alive", return_value=True):
            self.assertEqual(fns._zombies([4242]), set())
        with mock.patch.object(fns.subprocess, "check_output", side_effect=OSError("no ps")), \
                mock.patch.object(fns, "pid_alive", return_value=False):
            self.assertEqual(fns._zombies([4242]), set(), "a ps that cannot run decides nothing")


class Y_IdleBeat(unittest.TestCase):
    """The idle beat in-process with a fake clock: no daemon, no real wait."""

    def setUp(self):
        import pwd
        self.d = tempfile.mkdtemp(prefix="fns-idle.")
        self.me = pwd.getpwuid(os.getuid()).pw_name
        self.sess = os.path.join(self.d, "sessions")
        os.makedirs(self.sess)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("FLEET_NODE_", "FLEET_MACHINE_"))}
        env.update({"FLEET_NODE_STATE": os.path.join(self.d, "db"), "FLEET_NODE_LOG": os.path.join(self.d, "log"),
                    "FLEET_NODE_RUNTIME": os.path.join(self.d, "rt"), "FLEET_NODE_TEST": "1",
                    "FLEET_MACHINE_SESSIONS_DIR": self.sess, "FLEET_NODE_MEM_CALM": "1"})
        self.patch = mock.patch.dict(os.environ, env, clear=True)
        self.patch.start()
        os.makedirs(env["FLEET_NODE_STATE"])
        self.sup = fns.Supervisor(fns.Paths(), {"children": [], "tasks": []})

    def tearDown(self):
        self.patch.stop()
        shutil.rmtree(self.d, ignore_errors=True)

    def publish(self, working=0, count=1, ts=None, touch_after=False):
        ts = time.time() if ts is None else ts
        mark = os.path.join(self.sess, ".idle-" + self.me)
        open(mark, "a").close()
        act = os.lstat(mark).st_mtime_ns
        with open(os.path.join(self.sess, self.me), "w") as f:
            f.write("%d %d\nidle-v1 %s\n" % (count, ts, json.dumps(
                {"ts": ts, "working": working, "unknown": False, "changed": 0, "activity": act})))
        if touch_after:
            os.utime(mark, ns=(act + 10 ** 9, act + 10 ** 9))

    def every(self, tk, t):
        return self.sup.task_every(tk, t)

    def test_idle_stretches_and_busy_restores(self):
        bridge = {"name": "issue-bridge", "every": 15, "account": "x"}
        mem = {"name": "memguard", "every": 10}
        reading = {"name": "machine-reading", "every": 15, "idle_every": 45}
        keep = {"name": "pinned", "every": 10, "idle": False}
        slow = {"name": "update", "every": 300}
        minute = {"name": "diskguard", "every": 60}
        self.publish(working=0)
        t0 = time.time()
        # idle, but not yet for FLEET_NODE_IDLE_HOLD (120 s): the normal clocks
        self.assertEqual(self.every(bridge, t0), 15)
        self.assertEqual(self.sup.state["idle"]["idle"], True)
        t = t0 + 121
        self.assertEqual(self.every(bridge, t), 60)
        self.assertEqual(self.every(minute, t), 180)
        self.assertEqual(self.every(reading, t), 45)
        self.assertEqual(self.every(keep, t), 10)
        self.assertEqual(self.every(slow, t), 300)
        self.assertEqual(self.every(mem, t), 60)
        # task_due follows the stretched clock
        self.sup.state["tasks"]["issue-bridge"] = {"last_start": t - 20}
        self.assertFalse(self.sup.task_due(bridge, t))
        self.sup.state["tasks"]["issue-bridge"] = {"last_start": t - 61}
        self.assertTrue(self.sup.task_due(bridge, t))
        lines = fns.status_lines(fns.Paths(), {"children": [], "tasks": []}, self.sup.state)[1]
        self.assertTrue(any(l.startswith("idle  yes") for l in lines), lines)
        # memory not calm: memguard keeps its 10 s
        os.environ["FLEET_NODE_MEM_CALM"] = "0"
        self.sup.calm_at = 0
        self.assertEqual(self.every(mem, t + 1), 10)
        os.environ["FLEET_NODE_MEM_CALM"] = "1"
        # a login starts working: every clock back at the next read (≤ 5 s)
        self.publish(working=2)
        t2 = t + 6
        self.assertEqual(self.every(bridge, t2), 15)
        self.assertIn("working: 2", self.sup.state["idle"]["why"])
        self.assertTrue(any(l.startswith("idle  no — working") for l in fns.status_lines(
            fns.Paths(), {"children": [], "tasks": []}, self.sup.state)[1]))
        # idle again: the hold starts over
        self.publish(working=0)
        t3 = t2 + 6
        self.assertEqual(self.every(bridge, t3), 15)
        self.assertEqual(self.every(bridge, t3 + 121), 60)

    def test_unknown_is_never_idle(self):
        t0 = time.time()
        cases = [
            ("stale row", lambda: self.publish(ts=time.time() - 400)),
            ("activity since snapshot", lambda: self.publish(touch_after=True)),
            ("sessions without a record", lambda: open(os.path.join(self.sess, self.me), "w").write(
                "2 %d\n" % time.time())),
        ]
        for i, (what, make) in enumerate(cases):
            make()
            self.sup.idle_read_at = 0
            self.assertEqual(self.every({"name": "b", "every": 15}, t0 + 1000 * (i + 1)), 15, what)
            self.assertTrue(self.sup.state["idle"]["why"].startswith("unknown"), (what, self.sup.state["idle"]))
        # an empty inventory is idle (no login has a session to work in)
        os.unlink(os.path.join(self.sess, self.me))
        self.sup.idle_read_at = 0
        self.every({"name": "b", "every": 15}, t0 + 5000)
        self.assertEqual(self.every({"name": "b", "every": 15}, t0 + 5200), 60)
        # a CI job is busy
        st = os.environ["FLEET_NODE_STATE"]
        put(os.path.join(st, "ci.env"), "FLEET_CI_TOKEN=x\n")
        fns.write_json(os.path.join(st, "ci-runner.json"), {"state": "busy", "at": time.time()}, 0o644)
        self.assertEqual(self.every({"name": "b", "every": 15}, t0 + 5206), 15)
        self.assertEqual(self.sup.state["idle"]["why"], "ci: a job running")

    def test_off_switch(self):
        self.publish(working=0)
        os.environ["FLEET_NODE_IDLE_BACKOFF"] = "0"
        t0 = time.time()
        self.every({"name": "b", "every": 15}, t0)
        self.assertEqual(self.every({"name": "b", "every": 15}, t0 + 500), 15)
        self.assertNotIn("idle", self.sup.state)


class X_EntryStateDir(unittest.TestCase):
    """#4161: an entry's state dir mounted as an emptyDir is 0777; with
    `StrictModes yes` sshd refuses every key under it. Each pass takes its group
    / other write away; the keys dir stays 0755."""

    def test_world_writable_state_dir_is_closed(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        st = os.path.join(d, "db")
        os.mkdir(st)
        os.chmod(st, 0o777)
        fns._entry_state_dir(st)
        self.assertEqual(os.stat(st).st_mode & 0o7777, 0o755)
        os.chmod(st, 0o700)                     # never widened
        fns._entry_state_dir(st)
        self.assertEqual(os.stat(st).st_mode & 0o7777, 0o700)
        os.chmod(st, 0o1777)                    # a sticky dir is someone else's (/tmp)
        fns._entry_state_dir(st)
        self.assertEqual(os.stat(st).st_mode & 0o7777, 0o1777)
        os.chmod(st, 0o755)
        new = os.path.join(d, "new")
        fns._entry_state_dir(new)
        self.assertEqual(os.stat(new).st_mode & 0o7777, 0o755)

    def test_converge_closes_it(self):
        src = open(SUP).read()
        i = src.index("def entry_converge(")
        self.assertIn("_entry_state_dir(paths.state)", src[i:i + 1200],
                      "entry_converge no longer closes the state dir before the keys")


if __name__ == "__main__":
    import selftest_part  # SELFTEST_PART=K/N runs one slice of the cases (issue #2694)
    if os.environ.get("SELFTEST_PART", "all") not in ("", "all") and len(sys.argv) == 1:
        _STRIDE_DISCOVERY = True
    # each part's cases as two processes at once: they mostly wait on a daemon's
    # tick, each in a sandbox of its own
    selftest_part.fan_out(2)
    selftest_part.main()
