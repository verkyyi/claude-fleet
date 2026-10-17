#!/usr/bin/env python3
"""Only the original controlled setup failure, under its two unchanged shards.

Not a discovered selftest, not a business entry and not an arbitrary runner.
The outer /usr/bin/time must include this interpreter's startup and exit too.
"""
import time
import sys
ENTERED = time.clock_gettime(time.CLOCK_MONOTONIC)

import hashlib
import importlib.util
import json
import math
import os
import selectors
import signal
import subprocess
import tempfile
import traceback

CONTEXT = "SUPERVISOR_COUNTEREXAMPLE_CONTEXT"
TARGET = "--cleanup-counterexample"


def budget_module():
    name = "supervisor_test_budget"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name,
            os.path.join(os.path.dirname(__file__), "fleet-node-supervisor-selftest-budget.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


M = budget_module()
E = M.envelope_module()  # Reuse reviewed bounded records, ownership and grace.
require = E.require


def hashes(m):
    names = ("fleet-node-supervisor-selftest-budget.py", "fleet-node-supervisor-selftest.py",
             "fleet-node-supervisor-selftest-envelope.py", os.path.basename(__file__), "fleet-shard-run.sh")
    result = {}
    for name in names:
        with open(os.path.join(os.path.dirname(m.__file__), name), "rb") as src:
            data = src.read(262145)
        require(len(data) <= 262144, "counterexample source exceeds fingerprint limit")
        result[name] = hashlib.sha256(data).hexdigest()
    return result


def read_request(m, path):
    require(not os.environ.get(E.CONTEXT), "business and counterexample contexts cannot coexist")
    require(os.path.isabs(path) and os.path.basename(path) == "request.json", "invalid counterexample context")
    records = E.Records(m, E.identity(os.path.dirname(path)))
    q, _ = records.read("request.json")
    require(q.get("version") == 1 and q.get("target") == TARGET and q.get("records") == records.directory,
            "counterexample context/target mismatch")
    require(q.get("clock") == m.clock_identity() and q.get("sources") == hashes(m), "clock/source mismatch")
    start = q.get("start")
    require(type(start) in (float, int) and math.isfinite(start) and 0 <= start <= m.ENTERED,
            "counterexample origin invalid/future")
    E.same_directory(q["workspace"])
    E.same_directory(q["temporary"])
    require(os.environ.get(CONTEXT) == path, "counterexample environment mismatch")
    return q, records


def gate(m, path, stage):
    require(stage in ("outer", "inner"), "only two fixed counterexample launch stages")
    if stage == "outer":
        require(os.read(0, 1) == b"G", "counterexample gate not released")
    q, records = read_request(m, path)
    require(os.getpid() == os.getpgrp(), "counterexample stage is not its own group")
    require(m.shared_now() < q["start"] + m.Budget.WORK, "counterexample preparation exhausted work budget")
    shard = os.path.join(os.path.dirname(m.__file__), "fleet-shard-run.sh")
    if stage == "outer":
        require(os.getpid() == q["runner_pid"], "counterexample outer Popen mismatch")
        log = os.path.join(records.directory["path"], "shard480.log")
        argv = ["bash", shard, "--budget", "480", "--retries", "0", "--log", log, "--",
                sys.executable, m.__file__, "--counterexample-gate", path, "inner"]
    else:
        require(os.getpgid(os.getppid()) == q["runner_pid"], "not a child of this outer shard")
        records.write("inner-launch.json", {"token": q["token"], "start": q["start"],
            "pid": os.getpid(), "pgid": os.getpgrp(), "parent_perl": os.getppid(),
            "outer_group": q["runner_pid"], "at": m.shared_now()})
        log = os.path.join(records.directory["path"], "shard240.log")
        argv = ["bash", shard, "--budget", "240", "--retries", "0", "--log", log, "--",
                sys.executable, m.__file__, TARGET]
    require(E.absent(log), "counterexample shard log already occupied")
    os.execvp("bash", argv)


class CounterRecords(E.EntryRecords):
    def __init__(self, m, q, records):
        super().__init__(m, q, records)
        self.expected = self.control = self.control_start = None

    def begin(self):
        m, q = self.module, self.request
        inner, _ = self.records.read("inner-launch.json")
        require(inner["token"] == q["token"] and inner["start"] == q["start"]
                and inner["outer_group"] == q["runner_pid"]
                and inner["pid"] == inner["pgid"] == os.getpgid(os.getppid()),
                "counterexample inner shard ownership mismatch")
        require(os.getpid() == os.getpgrp() and os.getpid() != inner["pid"], "wrong counterexample entry group")
        require(os.path.realpath(os.environ["TMPDIR"]) == os.path.realpath(q["temporary"]["path"]),
                "counterexample lost private TMPDIR")
        self.records.write("counterexample-start.json", {"token": q["token"], "start": q["start"],
            "target": TARGET, "clock": m.clock_identity(), "entered": m.ENTERED,
            "pid": os.getpid(), "pgid": os.getpgrp(), "parent_perl": os.getppid(),
            "inner_group": inner["pgid"], "at": m.shared_now(),
            "scope": "original double shard, no normal-runner shadow/tmux-dir/255 alarm"})
        require(m.shared_now() < q["start"] + m.Budget.WORK, "budget exhausted before counterexample setup")

    def save_control_start(self, value):
        require(E.identity(value["directory"]["path"]) == value["directory"]
                and os.path.realpath(os.path.dirname(value["directory"]["path"]))
                    == os.path.realpath(self.request["temporary"]["path"]),
                "control directory is not this invocation's private child")
        self.control_start = self.records.write("control-start.json", value)

    def save_expected(self, value, diagnostic):
        data = diagnostic.encode()
        require(len(data) <= E.JSON_LIMIT, "actual diagnostic exceeds65536")
        fd = None
        try:
            with self.records.opened_directory() as directory:
                with self.module.registration():
                    fd = os.open("diagnostic.log", os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
                offset = 0
                while offset < len(data):
                    count = os.write(fd, data[offset:])
                    require(count > 0, "diagnostic persistence made no progress")
                    offset += count
        finally:
            if fd is not None:
                os.close(fd)
        self.expected = self.records.write("expected-setup.json", dict(value, diagnostic={
            "name": "diagnostic.log", "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}))

    def save_control(self, value):
        self.control = self.records.write("control-final.json", value)


def entry(m, case):
    require(case == TARGET, "counterexample context cannot select business cases")
    q, records = read_request(m, os.environ[CONTEXT])
    recorder = CounterRecords(m, q, records)
    m.ENVELOPE_RECORD = recorder
    failure, clock_error, code = None, None, 2
    try:
        recorder.begin()
        m.ACTIVE = m.Budget(q["start"])
        sys.modules["supervisor_test_budget"] = m
        source = os.path.join(os.path.dirname(m.__file__), "fleet-node-supervisor-selftest.py")
        sys.argv = [source, TARGET]
        namespace = m.runpy.run_path(source, run_name="supervisor_counterexample")
        observed = namespace["budget_cleanup_counterexample"]()
        require(observed == 1 and recorder.expected is not None and recorder.control is not None,
                "counterexample did not finish its expected failure/control cleanup")
        code = 1
    except BaseException as exc:
        failure = {"type": type(exc).__name__, "message": str(exc)[:2048],
                   "traceback": "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[-4096:]}
    finally:
        if m.ACTIVE is not None:
            try:
                m.ACTIVE.close()
            except BaseException as exc:
                clock_error, code = repr(exc)[:2048], 2
        clock = None if m.ACTIVE is None else m.ACTIVE.clock.close_receipt
        try:
            require(m.shared_now() <= q["start"] + m.Budget.FINISH, "counterexample final receipt late")
        except BaseException as exc:
            if failure is None:
                failure = {"type": type(exc).__name__, "message": str(exc)}
            code = 2
        final = {"token": q["token"], "start": q["start"], "target": TARGET, "pid": os.getpid(),
            "rc": code, "failure": failure, "clock": clock, "clock_close_error": clock_error,
            "hosts": recorder.hosts, "cleanup": recorder.cleanup, "expected": recorder.expected,
            "control_start": recorder.control_start, "control": recorder.control, "ended": m.shared_now()}
        try:
            records.write("counterexample-final.json", final)
            print("counterexample-final " + json.dumps(final), flush=True)
        finally:
            m.ENVELOPE_RECORD = None
    return code  # 1 only after original function + control finally + clock close


class CounterOuter(E.Outer):
    def __init__(self, m, evidence):
        super().__init__(m, TARGET, evidence)
        self.start = ENTERED  # Before budget/envelope imports and both shards.

    def prepare(self):
        require(not os.environ.get(CONTEXT) and not os.environ.get(E.CONTEXT), "nested acceptance context")
        require(not os.environ.get("FLEET_SELFTEST_ROOT") and not os.environ.get("FLEET_SELFTEST_NO_SHADOW"),
                "counterexample uses its original double-shard route, not a shadow bypass")
        require(self.left(40) > 0, "counterexample outer preparation expired")
        self.clock = self.m.WallDeadline(self.expired)
        self.clock.arm(self.start + 53, "counterexample and both shard exits")
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            self.saved_handlers[sig] = signal.getsignal(sig)
            signal.signal(sig, self.stop)
        with self.m.registration():
            os.mkdir(self.evidence, 0o700)
            self.records = E.Records(self.m, E.identity(self.evidence))
        with self.m.registration():
            self.workspace_allocated = tempfile.mkdtemp(prefix="ce-budget.", dir="/tmp")
            self.workspace = E.identity(self.workspace_allocated)
        with self.m.registration():
            self.temporary_allocated = os.path.join(self.workspace["path"], "tmp")
            os.mkdir(self.temporary_allocated, 0o700)
            self.temporary = E.identity(self.temporary_allocated)
        self.records.write("outer-prepared.json", {"start": self.start, "clock": self.m.clock_identity(),
            "outer_pid": os.getpid(), "workspace": self.workspace, "temporary": self.temporary,
            "prepared_at": self.m.shared_now()})
        with self.m.registration():
            self.log = open(os.path.join(self.evidence, "runner.log"), "x+b")
            self.selector = selectors.DefaultSelector()
        path = os.path.join(self.evidence, "request.json")
        env = dict(os.environ, TMPDIR=self.temporary["path"] + os.sep)
        env[CONTEXT] = path
        dispatched = self.m.shared_now()
        with self.m.registration():
            self.proc = subprocess.Popen([sys.executable, self.m.__file__, "--counterexample-gate", path, "outer"],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        require(os.getpgid(self.proc.pid) == self.proc.pid, "counterexample Popen group changed")
        self.request = {"version": 1, "target": TARGET, "start": self.start, "token": os.urandom(16).hex(),
            "clock": self.m.clock_identity(), "sources": hashes(self.m), "runner_pid": self.proc.pid,
            "runner_pgid": self.proc.pid, "dispatched_at": dispatched, "records": self.records.directory,
            "workspace": self.workspace, "temporary": self.temporary}
        self.records.write("request.json", self.request)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        require(self.left(40) > 0, "counterexample budget expired before releasing gate")
        with self.m.registration():
            self.gate_release_attempted = True
            self.proc.stdin.write(b"G")
            self.proc.stdin.flush()
            self.gate_released = True
            self.proc.stdin.close()

    def wait_normal(self):
        while self.proc.poll() is None or not self.eof:
            require(self.left(53) > 0, "counterexample/shards exceeded shared53")
            self.drain(self.left(53))
        self.proc.wait(timeout=0)
        require(self.proc.returncode == 1, "expected actual shard exit1, got %s" % self.proc.returncode)
        self.clock.arm(self.start + 55, "counterexample receipt verification and final cleanup")

    def protected_entry_absent(self):
        if not self.gate_release_attempted:
            return {"gate_held": True}
        inner, _ = self.records.read("inner-launch.json")
        begin, _ = self.records.read("counterexample-start.json")
        q = self.request
        require(inner["token"] == begin["token"] == q["token"]
                and inner["start"] == begin["start"] == self.start
                and inner["outer_group"] == self.proc.pid
                and type(inner["pid"]) is int and inner["pid"] > 1
                and inner["pid"] == inner["pgid"] == begin["inner_group"]
                and type(begin["pid"]) is int and begin["pid"] > 1
                and begin["pid"] == begin["pgid"] and begin["clock"] == self.m.clock_identity(),
                "KILL refused: exact two-shard ownership missing")
        groups = [{"pgid": n, "absent": E.group_absent(n)} for n in (inner["pgid"], begin["pgid"])]
        return {"gate_held": False, "entry_group_absent": all(g["absent"] for g in groups),
                "groups": groups, "observed_at": self.m.shared_now()}

    def blob(self, name, limit):
        fd = None
        try:
            with self.records.opened_directory() as directory:
                with self.m.registration():
                    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
                require(E.stat.S_ISREG(os.fstat(fd).st_mode), "non-regular evidence file")
                data = os.read(fd, limit + 1)
        finally:
            if fd is not None:
                os.close(fd)
        require(len(data) <= limit, "oversized/truncated evidence: " + name)
        return data

    def referenced(self, ref, name):
        require(isinstance(ref, dict) and ref.get("name") == name, "missing/wrong receipt: " + name)
        value, raw = self.records.read(name)
        require(ref["bytes"] == len(raw) and ref["sha256"] == hashlib.sha256(raw).hexdigest(), "receipt hash mismatch")
        return value

    def verify(self):
        q = self.request
        begin, _ = self.records.read("counterexample-start.json")
        end, _ = self.records.read("counterexample-final.json")
        inner, _ = self.records.read("inner-launch.json")
        require(begin["token"] == end["token"] == inner["token"] == q["token"]
                and begin["start"] == end["start"] == inner["start"] == self.start, "counterexample context reset")
        require(begin["target"] == end["target"] == TARGET and begin["clock"] == self.m.clock_identity(), "wrong counterexample")
        require(begin["pid"] == begin["pgid"] == end["pid"] and begin["inner_group"] == inner["pid"] == inner["pgid"]
                and inner["outer_group"] == self.proc.pid, "counterexample ownership mismatch")
        require(end["rc"] == 1 and end["failure"] is None and end["clock_close_error"] is None,
                "actual failure is not the expected controlled setup failure")
        clock = end["clock"]
        require(clock["pid"] == end["pid"] and clock["clock"] == self.m.clock_identity()
                and clock["joined"] is True and clock["error"] is None and clock["thread_error"] is None
                and clock["join_deadline"] == self.start + 53, "counterexample clock not fully joined")
        require(clock["external_alarm_at_start"]["remaining"] == 0
                and clock["external_alarm_at_start"]["interval"] == 0
                and clock["external_alarm_at_start"]["handler"] == "SIG_DFL"
                and clock["external_alarm_at_close"] == [0, 0]
                and clock["external_handler_still_default"] is True, "unexpected inherited timer in original double-shard route")
        stamps = [self.start, q["dispatched_at"], inner["at"], begin["entered"], begin["at"],
                  clock["external_alarm_at_start"]["sampled_before"], clock["external_alarm_at_start"]["sampled_after"],
                  clock["external_close_sampled_before"], clock["external_close_sampled_after"], clock["ended"], end["ended"]]
        require(all(type(t) in (int, float) and math.isfinite(t) for t in stamps)
                and stamps == sorted(stamps) and end["ended"] <= self.start + 53, "counterexample clock sequence/deadline invalid")
        expected = self.referenced(end["expected"], "expected-setup.json")
        require(expected["case_exit"] == 1 and expected["setup_error_count"] == 1 and expected["cleanup_count"] == 1
                and expected["body_called"] is False and expected["teardown_called"] is False,
                "controlled setup/body/cleanup counts wrong")
        for field in ("original_exception_preserved", "cleanup_once", "all_owned_joined", "private_directories_removed",
                      "control_untouched", "file_truncated", "budget_diagnostic"):
            require(expected.get(field) is True, "counterexample assertion missing: " + field)
        require(expected["exception_type"] == "BudgetExceeded" and "phase=controlled partial setUp" in expected["exception"]
                and self.start + expected["injection_limit"] <= expected["injected_at"] < self.start + 40,
                "real budget exhaustion was misclassified as controlled injection")
        diagnostic = self.blob("diagnostic.log", E.JSON_LIMIT)
        require(expected["diagnostic_bytes"] == len(diagnostic) <= expected["diagnostic_limit"] == E.JSON_LIMIT
                and expected["diagnostic"] == {"name": "diagnostic.log", "bytes": len(diagnostic),
                    "sha256": hashlib.sha256(diagnostic).hexdigest()}
                and b"[file truncated:" in diagnostic and b"FIXTURE_BUDGET_EXHAUSTED" in diagnostic,
                "actual diagnostic evidence missing")
        cleanup = self.referenced(end["cleanup"], "fixture-cleanup.json")
        require(cleanup["complete"] is True and cleanup["count"] == 1 and cleanup["errors"] == [], "fixture cleanup incomplete")
        hosts = end["hosts"]
        require(0 < len(hosts) == cleanup["hosts"] <= 128, "host receipt count mismatch")
        children, total = [], 0
        for index, ref in enumerate(hosts):
            h = self.referenced(ref, "host-%03d.json" % index)
            total += ref["bytes"]
            require(total <= E.JSON_LIMIT and h["start"] == self.start and h["complete"] is True
                    and h["rc"] not in (124, 125), "host incomplete")
            observation = h["parent_observation"]
            self.m.verify_host_clock(h, self.start, observation["dispatched_at"], observation["joined_at"])
            children.extend(h["children"])
        seen = expected["observed_child"]
        matched = [c for c in children if c["pid"] == seen["pid"]]
        require(seen["live"] is True and len(matched) == 1
                and matched[0]["born"] <= seen["at"] < expected["injected_at"]
                and matched[0]["joined"] is True, "controlled child never actually existed/joined")
        first = self.referenced(end["control_start"], "control-start.json")
        control = self.referenced(end["control"], "control-final.json")
        require(control["pid"] == control["pgid"] == first["pid"] == first["pgid"]
                and control["directory"] == first["directory"] and control["marker"] == first["marker"],
                "control identity changed")
        require(control["untouched_before_cleanup"] is True and control["marker_identity_unchanged"] is True
                and control["marker_content_unchanged"] is True and control["joined"] is True
                and control["rc"] is not None and control["directory_removed"] is True
                and control["errors"] == [] and control["primary_exception"] is None,
                "control was touched or cleanup failed")
        require(control["created_at"] <= control["checked_at"] <= control["ended"] <= clock["ended"]
                and control["ended"] <= self.start + 53 and control["waits"][-1]["joined"] is True,
                "control cleanup lacks final actual wait")
        for wait in control["waits"]:
            require(wait["started"] <= wait["ended"] <= self.start + 53
                    and wait["deadline"] <= self.start + 53, "control exceeded shared cleanup deadline")
        for event in control["signals"]:
            require(control["checked_at"] <= event["before"] <= event["after"] <= control["ended"], "control signal chronology missing")
        self.log.flush()
        raw = self.blob("runner.log", E.LOG_LIMIT)
        log480 = self.blob("shard480.log", E.LOG_LIMIT)
        log240 = self.blob("shard240.log", E.LOG_LIMIT)
        require(self.eof and not self.log_truncated and len(raw) == self.received, "counterexample raw log incomplete")
        lines = raw.decode("utf-8").splitlines()
        summaries = [s for s in lines if s.startswith("shard-run: attempt ")]
        require(len(summaries) == 2 and "budget 240s" in summaries[0] and "budget 480s" in summaries[1]
                and all(s.startswith("shard-run: attempt 1 ") and s.endswith("exit 1") for s in summaries),
                "not exactly one expected exit1 from each original shard")
        require(log480 == raw[:raw.rfind(summaries[1].encode())]
                and log240 == log480[:log480.rfind(summaries[0].encode())], "original two-shard log boundaries mismatch")
        require(raw.count(b"expected_setup_budget_failure ") == 1 and raw.count(b"counterexample-final ") == 1
                and b"CUT SHORT" not in raw and b"PASS  " not in raw, "wrong/missing expected failure evidence")
        for n in ("shard480.log.cut-mark", "shard480.log.cut-1", "shard240.log.cut-mark", "shard240.log.cut-1"):
            require(E.absent(os.path.join(self.evidence, n)), "counterexample shard cut/retried")
        groups = [self.proc.pid, inner["pgid"], begin["pgid"], control["pgid"]]
        require(all(E.group_absent(n) for n in groups), "known counterexample group still present")
        for directory in [*cleanup["directories"], control["directory"]]:
            require(os.path.realpath(os.path.dirname(directory["path"]))
                    == os.path.realpath(q["temporary"]["path"]), "recorded directory escaped private TMPDIR")
            require(E.absent(directory["path"]), "owned counterexample directory still exists")
        E.same_directory(self.temporary)
        with os.scandir(self.temporary["path"]) as entries:
            require(next(entries, None) is None, "counterexample TMPDIR has unknown residue")
        return {"expected_setup_failure": True, "host_receipts": len(hosts), "children": len(children),
            "diagnostic_bytes": len(diagnostic), "groups_absent": groups, "control_joined": True,
            "runner_log_sha256": hashlib.sha256(raw).hexdigest(), "shard_attempts": [1, 1], "actual_shard_exit": 1}

    def run(self):
        failure, verification, code = None, None, 2
        try:
            self.prepare()
            self.wait_normal()
            verification = self.verify()
            for directory in (self.temporary, self.workspace):
                E.same_directory(directory)
                os.rmdir(directory["path"])
            self.owned_directories_removed = True
            require(self.left(55) > 0, "counterexample final cleanup exceeded target55")
            code = 1  # Preserves the controlled failure, never business PASS.
        except BaseException as exc:
            self.failure_cleanup = True
            failure = {"type": type(exc).__name__, "message": str(exc)[:2048],
                "traceback": "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))[-4096:]}
            for sig in self.saved_handlers:
                signal.signal(sig, signal.SIG_IGN)
            try:
                self.stop_owned()  # Reviewed actual TERM+5; both inner groups must be gone before KILL.
            except BaseException as exc:
                self.errors.append("owned shard cleanup: " + repr(exc)[:512])
        finally:
            for resource in (None if self.proc is None else self.proc.stdin,
                             None if self.proc is None else self.proc.stdout, self.selector, self.log):
                if resource is not None:
                    try:
                        resource.close()
                    except BaseException as exc:
                        self.errors.append("close: " + repr(exc)[:512])
                        code = 2
            if self.clock is not None:
                try:
                    self.clock.close(self.start + 55 if code == 1 else self.failure_join_deadline() + 0.5)
                except BaseException as exc:
                    self.errors.append("counterexample outer clock: " + repr(exc)[:512])
                    code = 2
            for sig, handler in self.saved_handlers.items():
                signal.signal(sig, handler)
        result = {"start": self.start, "ended": self.m.shared_now(), "rc": code, "failure": failure,
            "errors": self.errors, "verification": verification, "clock": None if self.clock is None else self.clock.close_receipt,
            "runner_pid": None if self.proc is None else self.proc.pid,
            "runner_rc": None if self.proc is None else self.proc.returncode,
            "runner_joined": self.proc is not None and self.proc.returncode is not None,
            "signals": self.signals, "failure_runner_waits": self.runner_waits, "cleanup_notices": self.cleanup_notices,
            "workspace": self.workspace, "temporary": self.temporary,
            "allocated_paths": [self.workspace_allocated, self.temporary_allocated],
            "owned_directories_removed": self.owned_directories_removed, "log_eof": self.eof,
            "log_bytes": self.received, "log_truncated": self.log_truncated,
            "resources": "VERIFIED" if verification is not None else "UNKNOWN; retain existing evidence/workspace",
            "scope": "one original controlled setup failure; no normal runner/shadow/255 or business PASS",
            "verdict": "EXPECTED_FAILURE_PENDING_EXTERNAL_TIME" if code == 1 else "UNEXPECTED_OR_INCOMPLETE"}
        if self.records is not None:
            self.records.write("outer-final.json", result)
        require(self.m.shared_now() < self.start + (55 if code == 1 else 60), "counterexample final output exceeded budget")
        print("counterexample-outer-result " + json.dumps({"rc": code, "verdict": result["verdict"],
            "evidence": self.evidence, "elapsed": self.m.shared_now() - self.start}), flush=True)
        return code


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3 and sys.argv[1] == "--evidence", "usage: counterexample-envelope.py --evidence <new private directory>")
        result = CounterOuter(M, sys.argv[2]).run()
    except BaseException as exc:
        # Persistence/output failure after a candidate receipt is NOT the
        # controlled exit1. Keep an explicit different status; never retry.
        try:
            print("counterexample-unexpected " + repr(exc)[:2048], file=sys.stderr, flush=True)
        except OSError:
            pass
        result = 2
    sys.exit(result)
