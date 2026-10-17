"""Opt-in acceptance envelope for exactly four O/U entries, not a suite runner.

Imported only by selftest-budget --outer/--outer-gate or its private context.
The ordinary discovery path does not import this module. No production code,
runner timeout, PATH, shadow bypass, or alarm handler is changed here.
"""
import contextlib
import hashlib
import json
import math
import os
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import traceback


CONTEXT = "SUPERVISOR_TEST_ENVELOPE"
CASES = {
    "fleet-node-supervisor-core-recovery": "O_SweepRemoves.test_a_core_gone_from_launchd_is_put_back",
    "fleet-node-supervisor-ensure-register": "U_OnDemand.test_ensure_registers_starts_and_waits",
    "fleet-node-supervisor-ensure-idle": "U_OnDemand.test_ensure_after_idle",
    "fleet-node-supervisor-ensure-stop": "U_OnDemand.test_ensure_after_stop",
}
JSON_LIMIT = 65536
LOG_LIMIT = 131072


class EnvelopeFailure(AssertionError):
    pass


class EnvelopeStop(BaseException):
    pass


def require(ok, message):
    if not ok:
        raise EnvelopeFailure(message)


def identity(path):
    st = os.lstat(path)
    require(stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid(), "not an owned real directory: " + path)
    return {"path": os.path.abspath(path), "device": st.st_dev, "inode": st.st_ino}


def same_directory(record):
    require(identity(record["path"]) == record, "private directory identity changed")


def absent(path):
    # ENOENT is evidence; permission/I/O failures must not look like absence.
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    return False


def group_absent(pgid):
    try:
        os.killpg(pgid, 0)  # observation only, never a cleanup selector
    except ProcessLookupError:
        return True
    return False


def source_hash(module):
    result = {}
    for name, path in (("budget", module.__file__), ("envelope", __file__)):
        with open(path, "rb") as src:
            data = src.read(262145)
        require(len(data) <= 262144, "test budget source exceeds fingerprint limit")
        result[name] = hashlib.sha256(data).hexdigest()
    return result


class Records:
    def __init__(self, module, directory):
        self.m, self.directory = module, directory

    @contextlib.contextmanager
    def opened_directory(self):
        fd = None
        try:
            same_directory(self.directory)
            with self.m.registration():
                fd = os.open(self.directory["path"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            st = os.fstat(fd)
            require((st.st_dev, st.st_ino) == (self.directory["device"], self.directory["inode"]),
                    "receipt directory changed during open")
            yield fd
        finally:
            if fd is not None:
                os.close(fd)

    def write(self, name, value):
        require("/" not in name and name not in ("", ".", ".."), "invalid receipt name")
        data = (json.dumps(value, sort_keys=True) + "\n").encode()
        require(len(data) <= JSON_LIMIT, "receipt exceeds byte limit")
        with self.opened_directory() as dfd:
            fd = None
            try:
                with self.m.registration():
                    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
                offset = 0
                while offset < len(data):
                    written = os.write(fd, data[offset:])
                    require(written > 0, "receipt write made no progress")
                    offset += written
            finally:
                if fd is not None:
                    os.close(fd)
        return {"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    def read(self, name):
        require("/" not in name and name not in ("", ".", ".."), "invalid receipt name")
        with self.opened_directory() as dfd:
            fd = None
            try:
                with self.m.registration():
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
                require(stat.S_ISREG(os.fstat(fd).st_mode), "receipt is not regular")
                data = os.read(fd, JSON_LIMIT + 1)
            finally:
                if fd is not None:
                    os.close(fd)
        require(len(data) <= JSON_LIMIT, "receipt truncated/oversized")
        return json.loads(data), data


def read_request(module, path, case=None):
    require(os.path.isabs(path), "context path must be absolute")
    directory = identity(os.path.dirname(path))
    require(os.path.basename(path) == "request.json", "unexpected context filename")
    records = Records(module, directory)
    request, _ = records.read("request.json")
    require(request.get("version") == 1 and request.get("records") == directory, "context directory mismatch")
    require(request.get("entry") in CASES, "not an O/U single-entry request")
    require(case is None or CASES[request["entry"]] == case, "entry/case mismatch")
    require(request.get("clock") == module.clock_identity(), "context clock/interpreter mismatch")
    require(request.get("source_hash") == source_hash(module), "helper source changed after outer launch")
    start = request.get("start")
    require(type(start) in (int, float) and math.isfinite(start) and 0 <= start <= module.ENTERED,
            "invalid/future common origin")
    same_directory(request["workspace"])
    same_directory(request["temporary"])
    return request, records


def gate(module, path):
    # The parent retains Popen/PGID and writes request.json BEFORE releasing us.
    # No runner, shadow, tmux directory, or fixture exists before this byte.
    require(os.read(0, 1) == b"G", "outer launch gate not released")
    request, _ = read_request(module, path)
    require(os.environ.get(CONTEXT) == path, "gate context mismatch")
    require(request["runner_pid"] == os.getpid() == os.getpgrp(), "outer group owner mismatch")
    require(module.shared_now() < request["start"] + module.Budget.WORK, "prelude budget already exhausted")
    source_dir = os.path.dirname(os.path.abspath(module.__file__))
    os.execvp("bash", ["bash", os.path.join(source_dir, "run-selftests.sh"), request["entry"]])


class EntryRecords:
    def __init__(self, module, request, records):
        self.module, self.request, self.records = module, request, records
        self.hosts, self.host_bytes = [], 0
        self.cleanup = None

    def begin(self):
        m, q = self.module, self.request
        shadow = identity(os.environ["FLEET_SELFTEST_ROOT"])
        tmux_dir = identity(os.environ["TMUX_TMPDIR"])
        require(os.path.realpath(os.path.dirname(shadow["path"])) == os.path.realpath(q["temporary"]["path"]),
                "shadow did not use this invocation's TMPDIR")
        require(os.path.basename(shadow["path"]).startswith("fleet-selftest-root."), "wrong shadow shape")
        require(os.path.realpath(os.path.dirname(tmux_dir["path"])) == os.path.realpath("/tmp")
                and os.path.basename(tmux_dir["path"]).startswith("selftest-tt."), "wrong runner tmux directory")
        require(os.getpid() == os.getpgrp(), "entry is not in the original runner's separate group")
        supervisor_pid = os.getppid()
        supervisor_pgid = os.getpgid(supervisor_pid)
        require(supervisor_pgid == q["runner_pgid"] == q["runner_pid"], "wrong original supervisor group")
        self.records.write("entry-start.json", {"token": q["token"], "start": q["start"],
            "entered": m.ENTERED, "recorded_at": m.shared_now(), "clock": m.clock_identity(),
            "case": CASES[q["entry"]], "pid": os.getpid(), "pgid": os.getpgrp(),
            "supervisor_pid": supervisor_pid, "supervisor_pgid": supervisor_pgid,
            "shadow": shadow, "tmux_tmpdir": tmux_dir})
        # Save the actual runner resources even when the body can no longer start.
        require(m.shared_now() < q["start"] + m.Budget.WORK, "shared body budget exhausted before setup")

    def save_host(self, receipt):
        encoded = (json.dumps(receipt, sort_keys=True) + "\n").encode()
        require(len(self.hosts) < 128 and self.host_bytes + len(encoded) <= JSON_LIMIT,
                "persistent host receipt budget exhausted")
        record = self.records.write("host-%03d.json" % len(self.hosts), receipt)
        self.hosts.append(record)
        self.host_bytes += record["bytes"]

    def save_cleanup(self, receipt):
        require(self.cleanup is None, "duplicate fixture cleanup receipt")
        self.cleanup = self.records.write("fixture-cleanup.json", receipt)


def entry(module, case):
    """Adopt T0 only under the opt-in, exact single-entry context."""
    request, records = read_request(module, os.environ[CONTEXT], case)
    recorder = EntryRecords(module, request, records)
    module.ENVELOPE_RECORD = recorder
    primary, tb, code, clock_error = None, None, 0, None
    try:
        recorder.begin()
        module.ACTIVE = module.Budget(request["start"])
        module.sys.modules["supervisor_test_budget"] = module.sys.modules[module.__name__]
        source = os.path.join(os.path.dirname(module.__file__), "fleet-node-supervisor-selftest.py")
        sys.argv = [source, case]
        module.runpy.run_path(source, run_name="__main__")
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else int(exc.code is not None)
    except BaseException as exc:
        primary, tb, code = exc, exc.__traceback__, 1
    finally:
        if module.ACTIVE is not None:
            try:
                module.ACTIVE.close()
            except BaseException as exc:
                clock_error = repr(exc)[:2048]
                if primary is None:
                    primary, tb = exc, exc.__traceback__
                code = code or 1
        clock = None if module.ACTIVE is None else module.ACTIVE.clock.close_receipt
        try:
            records.write("entry-final.json", {"token": request["token"], "start": request["start"],
                "pid": os.getpid(), "case": case, "rc": code,
                "primary_exception": None if primary is None else repr(primary)[:2048],
                "clock": clock, "clock_close_error": clock_error,
                "hosts": recorder.hosts, "cleanup": recorder.cleanup, "ended": module.shared_now()})
            require(module.shared_now() <= request["start"] + module.Budget.FINISH,
                    "entry receipt completed after its shared deadline")
        except BaseException as exc:
            if primary is None:
                primary, tb = exc, exc.__traceback__
            code = code or 1
        module.ENVELOPE_RECORD = None
    if primary is not None:
        raise primary.with_traceback(tb)
    return code


class Outer:
    def __init__(self, module, entry_name, evidence):
        self.m, self.entry, self.evidence = module, entry_name, os.path.abspath(evidence)
        self.start = module.ENTERED
        self.proc = self.workspace = self.temporary = self.records = self.clock = None
        self.workspace_allocated = self.temporary_allocated = None
        self.selector = self.log = None
        self.received, self.eof, self.gate_released = 0, False, False
        self.gate_release_attempted = False
        self.log_truncated = False
        self.owned_directories_removed = False
        self.signals, self.errors, self.saved_handlers = [], [], {}
        self.request = None
        self.failure_cleanup = False
        self.term = None
        self.runner_waits, self.cleanup_notices = [], []

    def left(self, limit):
        return max(0.0, self.start + limit - self.m.shared_now())

    def expired(self, phase):
        if self.failure_cleanup:
            # Already nonzero. An old notification may be delivered during
            # teardown, but is never permission to shorten TERM's grace.
            if len(self.cleanup_notices) < 8:
                self.cleanup_notices.append({"phase": phase, "at": self.m.shared_now()})
            return
        self.m.raise_after_registration(EnvelopeStop("outer deadline: " + phase))

    def stop(self, signum, frame):
        self.m.raise_after_registration(EnvelopeStop("outer signal %d" % signum))

    def prepare(self):
        require(self.left(40) > 0, "outer startup exhausted shared body budget")
        require(not os.environ.get(CONTEXT), "nested envelope refused")
        require(not os.environ.get("FLEET_SELFTEST_ROOT") and not os.environ.get("FLEET_SELFTEST_NO_SHADOW"),
                "envelope requires the normal shadow prelude")
        require(os.environ.get("FLEET_SELFTEST_TEST_TIMEOUT") == "240", "normal runner limit must remain240")
        self.clock = self.m.WallDeadline(self.expired)
        self.clock.arm(self.start + 53, "normal runner through exit")
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            self.saved_handlers[sig] = signal.getsignal(sig)
            signal.signal(sig, self.stop)
        with self.m.registration():
            os.mkdir(self.evidence, 0o700)  # existing evidence refuses a rerun/overwrite
            self.records = Records(self.m, identity(self.evidence))
        with self.m.registration():
            path = tempfile.mkdtemp(prefix="ou-budget.", dir="/tmp")
            self.workspace_allocated = path
            self.workspace = identity(path)
        with self.m.registration():
            path = os.path.join(self.workspace["path"], "tmp")
            os.mkdir(path, 0o700)
            self.temporary_allocated = path
            self.temporary = identity(path)
        self.records.write("outer-prepared.json", {"start": self.start, "clock": self.m.clock_identity(),
            "outer_pid": os.getpid(), "workspace": self.workspace, "temporary": self.temporary,
            "prepared_at": self.m.shared_now()})
        with self.m.registration():
            self.log = open(os.path.join(self.evidence, "runner.log"), "x+b")
            self.selector = selectors.DefaultSelector()
        request_path = os.path.join(self.evidence, "request.json")
        env = dict(os.environ, TMPDIR=self.temporary["path"] + os.sep)
        env[CONTEXT] = request_path
        dispatched = self.m.shared_now()
        with self.m.registration():
            self.proc = subprocess.Popen([sys.executable, self.m.__file__, "--outer-gate", request_path],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True)
        require(os.getpgid(self.proc.pid) == self.proc.pid, "outer Popen group mismatch")
        self.request = {"version": 1, "start": self.start, "token": os.urandom(16).hex(),
            "clock": self.m.clock_identity(), "source_hash": source_hash(self.m), "entry": self.entry,
            "runner_pid": self.proc.pid, "runner_pgid": self.proc.pid, "dispatched_at": dispatched,
            "workspace": self.workspace, "temporary": self.temporary, "records": self.records.directory}
        self.records.write("request.json", self.request)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        require(self.left(40) > 0, "budget exhausted before releasing registered Popen")
        with self.m.registration():
            self.gate_release_attempted = True
            self.proc.stdin.write(b"G")
            self.proc.stdin.flush()
            self.gate_released = True
            self.proc.stdin.close()

    def drain(self, seconds, discard=False):
        if self.eof or self.selector is None:
            self.m.time.sleep(max(0, min(0.05, seconds)))
            return
        for key, _ in self.selector.select(timeout=max(0, min(0.1, seconds))):
            data = os.read(key.fd, 4096)
            if not data:
                self.eof = True
                self.selector.unregister(key.fileobj)
                return
            if discard:
                return
            kept = data[:max(0, LOG_LIMIT - self.received)]
            self.log.write(kept)
            self.log.flush()
            self.received += len(kept)
            if len(kept) != len(data):
                self.log_truncated = True
                raise EnvelopeFailure("runner output truncated at131072 bytes; evidence incomplete")

    def wait_normal(self):
        while self.proc.poll() is None or not self.eof:
            require(self.left(53) > 0, "normal runner did not complete before shared53")
            self.drain(self.left(53))
        self.proc.wait(timeout=0)  # actual owned child wait, not a receipt-only assertion
        require(self.proc.returncode == 0, "normal runner returned %s" % self.proc.returncode)
        self.clock.arm(self.start + 55, "outer verification and owned directory cleanup")

    def protected_entry_absent(self):
        # Outer TERM completion is NOT proof of when Perl forwarded TERM.
        # Once the gate might have opened, do not kill a still-forwarding/
        # waiting Perl on an elapsed-time assumption. Observe only the exact
        # entry group from this invocation; absence is not a descendant join.
        if not self.gate_release_attempted:
            return {"gate_held": True, "entry_group": "not launched by gate"}
        require(self.request is not None and self.records is not None,
                "KILL refused: released runner has no ownership context")
        begin, _ = self.records.read("entry-start.json")
        require(begin.get("token") == self.request["token"]
                and begin.get("start") == self.start
                and begin.get("case") == CASES[self.entry]
                and begin.get("clock") == self.m.clock_identity()
                and type(begin.get("pid")) is int and begin["pid"] > 1
                and begin.get("pid") == begin.get("pgid")
                and begin.get("supervisor_pgid") == self.proc.pid,
                "KILL refused: original entry ownership unverified")
        observed_at = self.m.shared_now()
        gone = group_absent(begin["pgid"])
        result = {"gate_held": False, "entry_pgid": begin["pgid"],
                  "observed_at": observed_at, "entry_group_absent": gone}
        return result

    def send_group(self, sig):
        # Popen pins this leader while it is our live child. Never signal a
        # recorded/stale per-entry/service PID or a group after its leader left.
        require(sig in (signal.SIGTERM, signal.SIGKILL), "unsupported outer signal")
        event = {"signal": sig, "owner": "retained outer Popen",
                 "pgid": None if self.proc is None else self.proc.pid,
                 "before": None, "after": None, "result": "not sent"}
        self.signals.append(event)
        try:
            if self.proc is None or self.proc.poll() is not None:
                event["result"] = "no live owned leader"
                return
            if sig == signal.SIGKILL:
                term = self.term
                require(term is not None and term.get("result") == "sent"
                        and term["pgid"] == self.proc.pid,
                        "KILL refused: successful owned TERM receipt missing")
                before, after = term["before"], term["after"]
                require(all(type(t) in (int, float) and math.isfinite(t) for t in (before, after))
                        and self.start <= before <= after, "KILL refused: invalid TERM timestamps")
                event["earliest_kill"] = after + 5
                event["eligibility_checked_at"] = self.m.shared_now()
                require(event["eligibility_checked_at"] >= event["earliest_kill"],
                        "KILL refused: full five seconds since TERM completion not elapsed")
                event["protected_entry"] = self.protected_entry_absent()
                require(event["protected_entry"].get("gate_held") is True
                        or event["protected_entry"].get("entry_group_absent") is True,
                        "KILL refused: original Perl may still be forwarding/waiting for its entry group")
            else:
                require(self.term is None, "owned TERM must not be retried/restart grace")
                self.term = event
            # Keep the syscall and actual send bracket together even if our
            # notification arrives here. Kernel SIGALRM is never touched.
            with self.m.registration():
                if self.proc.poll() is not None:
                    event["result"] = "leader exited before send"
                    return
                require(os.getpgid(self.proc.pid) == self.proc.pid, "owned runner group changed")
                event["before"] = self.m.shared_now()
                os.killpg(self.proc.pid, sig)
                event["result"] = "sent"
                event["after"] = self.m.shared_now()
                if sig == signal.SIGTERM:
                    event["grace_deadline"] = event["after"] + 5
        except ProcessLookupError:
            event["result"] = "group absent before send"
        except BaseException as exc:
            event["error"] = repr(exc)[:512]
            raise

    def failure_join_deadline(self):
        # This is failure-only reaping allowance, not renewed work time or a
        # <60 guarantee. A late TERM keeps all five seconds and may overrun.
        deadline = self.start + 59
        if self.term is not None and self.term.get("result") == "sent":
            after = self.term.get("after")
            if type(after) in (int, float) and math.isfinite(after):
                deadline = max(deadline, after + 6)
        return deadline

    def wait_owned(self):
        if self.proc is None:
            return
        receipt = {"pid": self.proc.pid, "started": self.m.shared_now(),
                   "deadline": self.failure_join_deadline(), "joined": False}
        self.runner_waits.append(receipt)
        try:
            receipt["rc"] = self.proc.wait(timeout=max(0, receipt["deadline"] - self.m.shared_now()))
            receipt["joined"] = True
        except BaseException as exc:
            receipt["error"] = repr(exc)[:512]
            raise
        finally:
            receipt["ended"] = self.m.shared_now()

    def stop_owned(self):
        # TERM reaches the original Perl supervisors, which TERM their own
        # per-entry groups and retain their original five-second grace/backstop.
        # This wait is not evidence that separately grouped descendants joined.
        try:
            try:
                self.send_group(signal.SIGTERM)
            except BaseException as exc:
                self.errors.append("owned TERM: " + repr(exc)[:512])
            if self.records is not None:
                try:
                    self.records.write("outer-term.json", self.term)
                except BaseException as exc:
                    self.errors.append("TERM persistence: " + repr(exc)[:512])
            # No proven TERM completion => no timed KILL. Still wait on the
            # retained child; never invent a grace start or probe other PIDs.
            if self.term is None or "grace_deadline" not in self.term:
                return
            end = self.term["grace_deadline"]
            discard, drain_broken = False, False
            while self.proc is not None and self.proc.poll() is None and self.m.shared_now() < end:
                try:
                    if drain_broken:
                        self.m.time.sleep(min(0.05, max(0, end - self.m.shared_now())))
                    else:
                        self.drain(end - self.m.shared_now(), discard=discard)
                except BaseException as exc:
                    if len(self.errors) < 32:
                        self.errors.append("grace drain/notification: " + repr(exc)[:512])
                    drain_broken = discard
                    discard = True  # logging failure never shortens grace
            self.send_group(signal.SIGKILL)
        except BaseException as exc:
            self.errors.append("owned stop: " + repr(exc)[:512])
        finally:
            # Even an ownership/log/clock failure still attempts this exact
            # Popen wait; it never goes through a second signal/KILL route.
            self.wait_owned()

    def verify(self):
        q = self.request
        self.log.flush()
        self.log.seek(0)
        raw_log = self.log.read(LOG_LIMIT + 1)
        require(not self.log_truncated and self.eof and len(raw_log) == self.received <= LOG_LIMIT,
                "runner log incomplete/truncated")
        lines = raw_log.decode("utf-8", errors="replace").splitlines()
        name = self.entry + "-selftest.sh"
        headers = [line for line in lines if line.startswith("=== ") and line.endswith(" ===")]
        terminals = [line for line in lines if re.match(r"^(PASS  |FAIL  |TIMEOUT |FLAKY |QUARANTINE )", line)]
        require(headers == ["=== " + name + " ==="] and len(terminals) == 1
                and re.fullmatch(r"PASS +" + re.escape(name) + r" +[0-9]+(?:\.[0-9]+)?s", terminals[0])
                and lines.count("1 test(s): 1 passed, 0 failed") == 1
                and len([line for line in lines if re.fullmatch(r"Ran 1 test in [0-9.]+s", line)]) == 1
                and lines.count("OK") == 1, "normal runner lacks one complete passing entry/case")
        begin, _ = self.records.read("entry-start.json")
        end, _ = self.records.read("entry-final.json")
        cleanup, raw = self.records.read("fixture-cleanup.json")
        require(begin.get("token") == end.get("token") == q["token"], "entry context token mismatch")
        require(begin.get("start") == end.get("start") == self.start, "entry reset its origin")
        require(begin.get("clock") == self.m.clock_identity(), "entry clock identity mismatch")
        require(begin.get("case") == end.get("case") == CASES[self.entry], "wrong case result")
        require(begin.get("pid") == begin.get("pgid") == end.get("pid"), "entry group identity mismatch")
        require(begin.get("supervisor_pgid") == q["runner_pgid"], "original supervisor ancestry mismatch")
        require(end.get("rc") == 0 and end.get("primary_exception") is None
                and end.get("clock_close_error") is None, "entry failed or incomplete")
        clock = end.get("clock")
        require(isinstance(clock, dict) and clock.get("pid") == end["pid"] and clock.get("joined") is True
                and clock.get("error") is None and clock.get("thread_error") is None,
                "parent clock missing or not joined")
        require(clock.get("clock") == self.m.clock_identity()
                and clock.get("join_deadline") == self.start + 53, "parent clock deadline/identity mismatch")
        first, last = clock["external_alarm_at_start"], clock["external_alarm_at_close"]
        require(first.get("handler") == "SIG_DFL" and first.get("interval") == 0
                and clock.get("external_handler_still_default") is True and last[1] == 0
                and 0 < last[0] <= first["remaining"] <= 255,
                "original per-entry one-shot alarm missing/changed")
        stamps = [self.start, q["dispatched_at"], begin["entered"], begin["recorded_at"],
                  first["sampled_before"], first["sampled_after"], clock["external_close_sampled_before"],
                  clock["external_close_sampled_after"], clock["ended"], end["ended"], self.m.shared_now()]
        require(all(type(t) in (int, float) and math.isfinite(t) for t in stamps)
                and stamps == sorted(stamps) and end["ended"] <= self.start + 53,
                "parent timestamp/deadline mismatch")
        require(end.get("cleanup") == {"name": "fixture-cleanup.json", "bytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest()}, "cleanup receipt mismatch")
        require(cleanup.get("count") == 1 and cleanup.get("complete") is True and cleanup.get("errors") == [],
                "fixture cleanup incomplete")
        hosts = end.get("hosts")
        require(isinstance(hosts, list) and 0 < len(hosts) <= 128, "host receipt list missing")
        require(cleanup.get("hosts") == len(hosts), "not every owned host has a preserved receipt")
        total = 0
        for index, ref in enumerate(hosts):
            require(ref["name"] == "host-%03d.json" % index, "host receipt sequence mismatch")
            host, data = self.records.read(ref["name"])
            total += len(data)
            require(ref["bytes"] == len(data) and ref["sha256"] == hashlib.sha256(data).hexdigest()
                    and total <= JSON_LIMIT, "host receipt bytes/hash mismatch")
            observation = host["parent_observation"]
            self.m.verify_host_clock(host, self.start, observation["dispatched_at"], observation["joined_at"])
            require(host.get("complete") is True and host.get("rc") not in (124, 125), "host cleanup failed")
        require(group_absent(begin["pgid"]) and group_absent(self.proc.pid),
                "known runner/entry group still exists; no broad cleanup attempted")
        for resource in [begin["shadow"], begin["tmux_tmpdir"], *cleanup["directories"]]:
            require(absent(resource["path"]), "known directory still exists: " + resource["path"])
        same_directory(self.temporary)
        with os.scandir(self.temporary["path"]) as children:
            require(next(children, None) is None, "private TMPDIR has unaccounted residue")
        return {"entry_pid": begin["pid"], "host_receipts": len(hosts), "host_bytes": total,
                "runner_log_sha256": hashlib.sha256(raw_log).hexdigest(), "unique_header_and_terminal": True,
                "known_groups_absent": True, "recorded_directories_absent": True}

    def run(self):
        failure, verification, rc = None, None, 1
        try:
            self.prepare()
            self.wait_normal()
            verification = self.verify()
            # Only these exact empty owned directories; never rmtree /tmp or
            # infer the runner's absolute tmux directory from a filename glob.
            for directory in (self.temporary, self.workspace):
                same_directory(directory)
                os.rmdir(directory["path"])
            self.owned_directories_removed = True
            require(self.left(55) > 0, "outer success target exceeded")
            rc = 0
        except BaseException as exc:
            self.failure_cleanup = True
            failure = {"type": type(exc).__name__, "message": str(exc)[:2048],
                       "traceback": "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[-4096:]}
            for sig in self.saved_handlers:
                signal.signal(sig, signal.SIG_IGN)  # keep the first failure while collecting cleanup evidence
            # No fixed58/58.5 rearm and no exception-to-KILL fallback. All KILL
            # requests go through successful TERM + actual full grace + entry
            # absence checks. Log/clock/ownership errors remain failures.
            try:
                self.stop_owned()
            except BaseException as cleanup_error:
                self.errors.append("owned runner cleanup: " + repr(cleanup_error)[:512])
        finally:
            for resource in (None if self.proc is None else self.proc.stdin,
                             None if self.proc is None else self.proc.stdout, self.selector, self.log):
                if resource is not None:
                    try:
                        resource.close()
                    except BaseException as exc:
                        self.errors.append("close: " + repr(exc)[:512])
                        rc = 1
            if self.clock is not None:
                try:
                    self.clock.close(self.start + 55 if rc == 0 else self.failure_join_deadline() + 0.5)
                except BaseException as exc:
                    self.errors.append("outer clock: " + repr(exc)[:512])
                    rc = 1
            for sig, handler in self.saved_handlers.items():
                signal.signal(sig, handler)
        result = {"start": self.start, "ended": self.m.shared_now(), "rc": rc, "failure": failure,
            "errors": self.errors, "verification": verification, "clock": None if self.clock is None else self.clock.close_receipt,
            "runner_pid": None if self.proc is None else self.proc.pid,
            "runner_rc": None if self.proc is None else self.proc.returncode,
            "runner_joined": self.proc is not None and self.proc.returncode is not None,
            "gate_release_attempted": self.gate_release_attempted,
            "gate_released": self.gate_released, "signals": self.signals, "log_bytes": self.received,
            "failure_runner_waits": self.runner_waits, "cleanup_notices": self.cleanup_notices,
            "failure_join_deadline": self.failure_join_deadline() if self.failure_cleanup else None,
            "log_eof": self.eof, "log_truncated": self.log_truncated,
            "workspace": self.workspace, "temporary": self.temporary,
            "allocated_paths": [self.workspace_allocated, self.temporary_allocated],
            "owned_directories_removed": self.owned_directories_removed,
            "runner_resources": "VERIFIED" if verification is not None else "UNKNOWN_OR_UNVERIFIED; retain all existing evidence/workspace",
            "evidence_directory": self.evidence,
            "scope": "all known receipts required; missing entry-start means runner resources UNKNOWN, not absent",
            "rc_scope": "candidate return before final persistence/output; actual exit and real are external receipts",
            "verdict": "COMPLETE_PENDING_EXTERNAL_TIME" if rc == 0 else "FAIL_OR_INCOMPLETE"}
        if self.records is not None:
            self.records.write("outer-final.json", result)
        require(self.m.shared_now() < self.start + (55 if rc == 0 else 60),
                "outer final evidence exceeded budget; external real still required")
        print("supervisor-envelope-result " + json.dumps({"rc": rc, "verdict": result["verdict"],
            "evidence": self.evidence, "elapsed": self.m.shared_now() - self.start}), flush=True)
        return rc


def outer(module, args):
    require(len(args) == 3 and args[0] in CASES and args[1] == "--evidence",
            "usage: --outer <one O/U entry> --evidence <new private directory>")
    return Outer(module, args[0], args[2]).run()


if __name__ == "__main__":
    raise SystemExit("use selftest-budget.py --outer through the normal shard/time command")
