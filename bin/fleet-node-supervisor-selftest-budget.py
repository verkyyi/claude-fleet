#!/usr/bin/env python3
"""Test-only O/U entry clock and ownership of subprocesses, never a daemon.

The shell wrappers exec this file without a subshell. Start before the heavy
test/production imports. This clock excludes the normal runner's preparation
and exit cleanup. Its 53s internal ceiling does NOT establish an external 55s
bound; /usr/bin/time measures that full chain, including interpreter startup.
No change to service ensure's 15s/try, 3 tries, or the shard runner's 240/480.
"""
import time
import sys

# Older CPython on macOS may offset monotonic() per interpreter. Use the
# explicit POSIX system clock, with one origin across these same-machine execs.
# No fallback to a process-local clock, wall time, or a fresh per-host duration.
try:
    _CLOCK_ID = time.CLOCK_MONOTONIC
    _CLOCK_READ = time.clock_gettime
except AttributeError as exc:
    raise RuntimeError("test budget requires clock_gettime(CLOCK_MONOTONIC); executable=%r python=%r"
                       % (sys.executable, sys.version)) from exc


def shared_now():
    return _CLOCK_READ(_CLOCK_ID)


ENTERED = shared_now()
CLOCK_SOURCE = "clock_gettime(CLOCK_MONOTONIC)"

import contextlib
import json
import math
import os
import runpy
import signal
import subprocess
import threading


def clock_identity():
    # Actual executing interpreter, not a guess about the old run's version.
    kernel = os.uname()
    return dict(source=CLOCK_SOURCE, clock_id=_CLOCK_ID, python=sys.version,
                version_info=list(sys.version_info[:3]), implementation=sys.implementation.name,
                executable=sys.executable, executable_realpath=os.path.realpath(sys.executable),
                platform=sys.platform, kernel=dict(system=kernel.sysname, release=kernel.release,
                    version=kernel.version, machine=kernel.machine))


class BudgetExceeded(BaseException):
    """A test observation was cut short, never a production timeout or PASS."""


class HostStop(BaseException):
    pass


_REGISTERING = 0
_DEFERRED = None


def raise_after_registration(error):
    global _DEFERRED
    if _REGISTERING:
        _DEFERRED = error
    else:
        raise error


class WallDeadline:
    """An owned thread notifies the main thread; never borrow ITIMER_REAL.

    run-selftests' alarm survives exec and is a kernel-fatal backstop even if
    Python cannot run a handler. Leave both that timer and SIGALRM untouched.
    SIGUSR2 is reserved only in this test process, with notifications directed
    to its main thread. No watchdog process, fork, or extra service is created.
    """
    notify_signal = signal.SIGUSR2

    def __init__(self, callback):
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("test clock requires the main thread")
        for name in ("pthread_sigmask", "pthread_kill", "sigpending", "sigwait"):
            if not hasattr(signal, name):
                raise RuntimeError("test clock cannot safely reserve notifications: " + name)
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        if signal.SIGALRM in mask or self.notify_signal in mask:
            raise RuntimeError("test clock refuses blocked alarm/notification")
        # Unsupported inherited state is rejected without touching its handler
        # or timer. This path supports the runner's default-action one-shot (or
        # no timer); it does not guess the intent of a custom/periodic alarm.
        sampled_before = shared_now()
        remaining, interval = signal.getitimer(signal.ITIMER_REAL)
        sampled_after = shared_now()
        if (signal.getsignal(signal.SIGALRM) != signal.SIG_DFL or interval != 0
                or not math.isfinite(remaining) or remaining < 0
                or signal.SIGALRM in signal.sigpending()):
            raise RuntimeError("test clock refuses unknown/periodic/pending external alarm")
        self.external_alarm = dict(remaining=remaining, interval=interval,
            handler="SIG_DFL", sampled_before=sampled_before, sampled_after=sampled_after)
        self.callback = callback
        self.condition = threading.Condition()  # RLock: main-thread signal reentry is safe
        self.main_ident = threading.get_ident()
        self.due = None
        self.payload = None
        self.pending = None
        self.stopping = False
        self.closing = False
        self.closed = False
        self.close_receipt = None
        self.thread_error = None
        self.thread = threading.Thread(target=self.watch, name="selftest-wall-deadline",
                                       daemon=True)
        with self.block_notifications():
            self.previous_handler = signal.getsignal(self.notify_signal)
            if (self.previous_handler != signal.SIG_DFL
                    or self.notify_signal in signal.sigpending()):
                raise RuntimeError("test clock refuses an occupied/pending SIGUSR2")
            signal.signal(self.notify_signal, self.dispatch)
            try:
                self.thread.start()
            except BaseException:
                # No fixture resources exist yet. Keep the original start
                # error; a thread which started must still be stopped/joined.
                with self.condition:
                    self.stopping = True
                    self.condition.notify_all()
                if self.thread.ident is not None:
                    self.thread.join(timeout=0.25)
                if not self.thread.is_alive():
                    signal.signal(self.notify_signal, self.previous_handler)
                raise

    @contextlib.contextmanager
    def block_notifications(self):
        # Only short clock-state transitions/join, NEVER fixture Popen/exec.
        # SIGALRM remains unblocked and kernel-fatal throughout this section.
        previous = signal.pthread_sigmask(signal.SIG_BLOCK, {self.notify_signal})
        try:
            yield
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)

    def latch(self):
        if self.due is not None and shared_now() >= self.due:
            if self.pending is None:
                self.pending = self.payload
            self.due = None  # one notification per arm, not a signal storm
            return True
        return False

    def watch(self):
        try:
            with self.condition:
                while not self.stopping:
                    if self.latch():
                        signal.pthread_kill(self.main_ident, self.notify_signal)
                    delay = None if self.due is None else max(0, self.due - shared_now())
                    self.condition.wait(timeout=delay)
        except BaseException as exc:
            with self.condition:
                self.thread_error = repr(exc)
            # check/close must fail even if notification itself was the error.
            try:
                signal.pthread_kill(self.main_ident, self.notify_signal)
            except (OSError, RuntimeError):
                pass

    def dispatch(self, signum=None, frame=None):
        if signum is not None and self.closing:
            return  # close delivers the retained failure AFTER joining
        with self.condition:
            payload, self.pending = self.pending, None
            error = self.thread_error
        if error is not None:
            raise_after_registration(RuntimeError("test deadline notifier failed: " + error))
        if payload is not None:
            self.callback(payload)

    def arm(self, deadline, payload):
        if not math.isfinite(deadline):
            raise ValueError("test deadline must be finite")
        with self.block_notifications():
            with self.condition:
                if self.stopping:
                    raise RuntimeError("test clock already stopped")
                # Rearming cannot erase an expiry not yet delivered by Python.
                # Install the next cleanup phase before delivering the old one.
                self.latch()
                self.due, self.payload = deadline, payload
                self.condition.notify_all()
        self.dispatch()

    def close(self, join_deadline):
        if self.closed:
            return self.close_receipt
        self.closing = True
        with self.block_notifications():
            with self.condition:
                self.latch()  # ending an entry cannot silently discard expiry
                self.stopping = True
                self.condition.notify_all()
            self.thread.join(timeout=min(0.25, max(0, join_deadline - shared_now())))
            joined = not self.thread.is_alive()
            if joined:
                # All sends are to this thread and the sender is now joined.
                # Drain our pending notification before restoring SIG_DFL.
                while self.notify_signal in signal.sigpending():
                    signal.sigwait({self.notify_signal})
                signal.signal(self.notify_signal, self.previous_handler)
                self.closed = True
        before = shared_now()
        external_at_close = signal.getitimer(signal.ITIMER_REAL)
        after = shared_now()
        self.close_receipt = {"pid": os.getpid(), "clock": clock_identity(), "joined": joined,
            "thread_error": self.thread_error, "external_alarm_at_start": self.external_alarm,
            "external_alarm_at_close": external_at_close,
            "external_close_sampled_before": before, "external_close_sampled_after": after,
            "external_handler_still_default": signal.getsignal(signal.SIGALRM) == signal.SIG_DFL,
            "join_deadline": join_deadline, "ended": shared_now(), "error": None}
        try:
            if not joined:
                raise RuntimeError("test deadline notifier did not join; incomplete")
            if self.close_receipt["ended"] > join_deadline:
                raise RuntimeError("test deadline notifier joined after its shared deadline; incomplete")
            self.dispatch()
        except BaseException as exc:
            self.close_receipt["error"] = repr(exc)
            raise
        finally:
            # Keep the same object for the host journal even on close failure.
            try:
                print("supervisor-clock-close " + json.dumps(self.close_receipt),
                      file=sys.stderr, flush=True)
            except OSError as exc:
                self.close_receipt["output_error"] = repr(exc)
                if self.close_receipt["error"] is None:
                    self.close_receipt["error"] = repr(exc)
                    raise
                # Preserve an existing expiry/join error; the host journal
                # carries this secondary output failure as well.
        return self.close_receipt


class Budget:
    WORK = 40.0
    DIAGNOSTIC = 42.0
    HOST_STOP = 44.0
    CHILD_TERM = 46.0
    CHILD_JOIN = 49.0
    HOST_JOIN = 50.0
    DIRECTORIES = 52.0
    FINISH = 53.0

    def __init__(self, start):
        self.start = start
        self.limit = self.WORK
        self.phase = "import/setup/body"
        self.clock = WallDeadline(self.expired)
        try:
            self.arm(self.WORK, self.phase)
        except BaseException:
            self.close()
            raise

    def expired(self, phase):
        raise_after_registration(BudgetExceeded(
            "FIXTURE_BUDGET_EXHAUSTED phase=%s elapsed=%.3f; observation incomplete"
            % (phase, self.elapsed())))

    def elapsed(self):
        return shared_now() - self.start

    def left(self, limit=None):
        end = self.start + (self.limit if limit is None else limit)
        return max(0.0, end - shared_now())

    def check(self):
        self.clock.dispatch()
        if not self.left():
            raise BudgetExceeded("FIXTURE_BUDGET_EXHAUSTED before launch; incomplete")

    def arm(self, limit, phase):
        self.limit, self.phase = limit, phase
        self.clock.arm(self.start + limit, phase)

    def close(self):
        primary = sys.exc_info()[1]
        try:
            self.clock.close(self.start + self.FINISH)
        except BaseException as exc:
            if primary is None or (isinstance(primary, SystemExit) and not primary.code):
                raise
            # A real test failure/exit stays primary; close evidence is still
            # explicit and non-PASS. Never replace its traceback with our join.
            print("supervisor-clock-close failed: %r; original %s retained"
                  % (exc, type(primary).__name__), file=sys.stderr, flush=True)

    def until(self, seconds, fn, step=0.05):
        # Keep the original 10/5/15s loop and its final observation. A callback
        # can itself cost time, so every nested CLI shares the *entry* deadline;
        # this loop's nominal seconds never mint another CLI's 60s allowance.
        end = shared_now() + seconds
        while shared_now() < end:
            self.check()
            value = fn()
            if value:
                return value
            time.sleep(min(step, self.left()))
        self.check()
        return fn()


@contextlib.contextmanager
def registration():
    # A deadline must not land between fork/exec and retaining its Popen handle.
    # Defer Python exceptions rather than masking OS signals: an exec'd fixture
    # must NOT inherit a blocked SIGTERM/SIGALRM mask from its creator.
    global _REGISTERING, _DEFERRED
    _REGISTERING += 1
    try:
        yield
    finally:
        _REGISTERING -= 1
        if not _REGISTERING and _DEFERRED is not None:
            error, _DEFERRED = _DEFERRED, None
            raise error


def launch(budget, owned, args, **kwargs):
    budget.check()
    with registration():
        proc = subprocess.Popen(args, **kwargs)
        owned.append(proc)
    return proc


def host_argv(start, dispatched_at, args):
    return [sys.executable, os.path.abspath(__file__), "--host", str(start),
            str(dispatched_at), CLOCK_SOURCE, *args]


def verify_host_clock(receipt, start, dispatched_at, joined_at):
    """Check preserved observations in one clock domain, not inferred rc==0."""
    clock = receipt.get("clock")
    assert isinstance(clock, dict), "host clock receipt missing"
    assert receipt.get("clock_identity") == clock_identity(), "host clock/interpreter mismatch"
    assert clock.get("clock") == clock_identity(), "close clock/interpreter mismatch"
    assert clock.get("pid") == receipt.get("host"), "wrong clock owner"
    assert clock.get("joined") is True, "host deadline thread not joined"
    assert clock.get("thread_error") is None and clock.get("error") is None, "host clock failed"
    assert receipt.get("clock_close_error") is None, "host clock close failed"
    assert receipt.get("dispatched_at") == dispatched_at, "wrong parent dispatch sample"
    assert receipt.get("deadlines") == {
        "host_stop": start + Budget.HOST_STOP,
        "child_term": start + Budget.CHILD_TERM,
        "child_join": start + Budget.CHILD_JOIN,
    }, "host deadlines were rebased"
    assert clock.get("join_deadline") == start + Budget.CHILD_TERM, "clock join deadline rebased"
    initial = clock.get("external_alarm_at_start")
    assert isinstance(initial, dict), "initial alarm observation missing"
    times = [start, dispatched_at, receipt.get("host_entered"), initial.get("sampled_before"),
             initial.get("sampled_after"), clock.get("external_close_sampled_before"),
             clock.get("external_close_sampled_after"), clock.get("ended"),
             receipt.get("ended"), joined_at]
    assert all(isinstance(t, (int, float)) and math.isfinite(t) for t in times), "invalid clock sample"
    assert times == sorted(times), "host observations do not share the parent's clock origin"
    assert clock["ended"] <= start + Budget.CHILD_TERM, "host clock join exceeded shared deadline"
    assert receipt["ended"] <= start + Budget.CHILD_JOIN, "host child joins exceeded shared deadline"
    assert joined_at <= start + Budget.HOST_JOIN, "parent host join exceeded shared deadline"
    for child in receipt.get("children", []):
        born = child.get("born")
        assert isinstance(born, (int, float)) and math.isfinite(born), "child clock sample missing"
        assert receipt["host_entered"] <= born <= receipt["ended"], "child clock origin mismatch"
        assert child.get("joined") is True and child.get("rc") is not None, "child not joined"
    after = clock.get("external_alarm_at_close")
    assert isinstance(after, (list, tuple)) and len(after) == 2, "final alarm observation missing"
    before = initial.get("remaining")
    assert isinstance(before, (int, float)) and math.isfinite(before) and before >= 0
    assert all(isinstance(t, (int, float)) and math.isfinite(t) for t in after)
    assert initial.get("handler") == "SIG_DFL" and initial.get("interval") == 0
    assert clock.get("external_handler_still_default") is True and after[1] == 0
    assert 0 <= after[0] <= before, "external one-shot timer grew or became invalid"
    # Exact sample brackets are retained for review; do not invent a kernel
    # timer-resolution tolerance or reset an elapsed external backstop here.


def host(start, dispatched_at, clock_source, args):
    """Run the unchanged supervisor with a ledger of *actual* child handles.

    Instrument Popen construction only: argv, credentials, environment, session
    flags and production waits are forwarded unchanged. Retain the objects even
    after production removes them from its tables. Cleanup can then waitpid its
    own children, without trusting a stale state PID or scanning the machine.
    """
    if (clock_source != CLOCK_SOURCE or not math.isfinite(start)
            or not math.isfinite(dispatched_at) or not 0 <= start <= dispatched_at <= ENTERED):
        raise RuntimeError("test host refuses incompatible shared clock origin")
    owned = []
    original = subprocess.Popen
    journal = os.environ["SUPERVISOR_TEST_JOURNAL"]
    receipt = {"host": os.getpid(), "start": start, "dispatched_at": dispatched_at,
               "host_entered": ENTERED, "clock_identity": clock_identity(), "children": [],
               "deadlines": {"host_stop": start + Budget.HOST_STOP,
                             "child_term": start + Budget.CHILD_TERM,
                             "child_join": start + Budget.CHILD_JOIN}}

    class TrackedPopen(original):
        def __init__(self, *a, **kw):
            with registration():
                super().__init__(*a, **kw)
                self.test_own_group = bool(kw.get("start_new_session"))
                self.test_birth = shared_now()
                owned.append(self)

    def stop(signum, frame):
        raise_after_registration(HostStop("test cleanup requested"))

    def deadline(phase):
        raise_after_registration(BudgetExceeded("FIXTURE_BUDGET_EXHAUSTED supervisor host; incomplete"))

    def remaining(limit):
        return max(0.0, start + limit - shared_now())

    def send(proc, sig):
        # An unreaped direct-child handle pins the PID generation. A group is
        # signalled only while its actual leader is still our live child.
        if proc.poll() is not None:
            return
        try:
            if proc.test_own_group and os.getpgid(proc.pid) == proc.pid:
                os.killpg(proc.pid, sig)
            else:
                proc.send_signal(sig)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, stop)  # run() installs its normal graceful handler
    # fork does not inherit the parent's interval timer; still validate the
    # host's actual state and leave any supported external alarm untouched.
    clock = WallDeadline(deadline)
    subprocess.Popen = TrackedPopen
    rc = 0
    try:
        if not remaining(Budget.HOST_STOP):
            raise BudgetExceeded("FIXTURE_BUDGET_EXHAUSTED during host startup; incomplete")
        clock.arm(start + Budget.HOST_STOP, "supervisor host")
        with open(journal + ".ready", "w") as out:
            json.dump({"host": os.getpid(), "start": start, "host_entered": ENTERED,
                       "dispatched_at": dispatched_at, "clock_identity": clock_identity()}, out)
        source = os.path.join(os.path.dirname(__file__), "fleet-node-supervisor.py")
        sys.argv = [source, *args]
        runpy.run_path(source, run_name="__main__")
    except SystemExit as exc:
        rc = exc.code if isinstance(exc.code, int) else int(exc.code is not None)
    except HostStop:
        rc = 143
    except BudgetExceeded as exc:
        print(str(exc), file=sys.stderr, flush=True)
        rc = 124
    except BaseException:
        import traceback
        traceback.print_exc()
        rc = 1
    finally:
        receipt["body_rc"] = rc  # preserve the pre-cleanup outcome if close/join also fails
        receipt["clock_close_error"] = None
        try:
            # Join uses the existing child-TERM reserve, never a fresh allowance.
            clock.close(start + Budget.CHILD_TERM)
        except BaseException as exc:
            rc = 125
            receipt["clock_close_error"] = repr(exc)
            try:
                print("supervisor-host clock cleanup failed: %r" % exc, file=sys.stderr, flush=True)
            except OSError:
                pass  # the journal still records this; continue owned-child cleanup
        finally:
            receipt["clock"] = clock.close_receipt  # None is evidence missing, never filled in
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        subprocess.Popen = original
        for proc in owned:
            send(proc, signal.SIGTERM)
        # One shared grace for ALL children, not N times a per-child timeout.
        grace = min(shared_now() + 2, start + Budget.CHILD_TERM)
        for proc in owned:
            try:
                proc.wait(timeout=max(0, grace - shared_now()))
            except subprocess.TimeoutExpired:
                pass
        for proc in owned:
            send(proc, signal.SIGKILL)
        for proc in owned:
            try:
                proc.wait(timeout=remaining(Budget.CHILD_JOIN))
            except subprocess.TimeoutExpired:
                rc = 125
            receipt["children"].append({"pid": proc.pid, "born": proc.test_birth,
                                        "rc": proc.returncode, "joined": proc.returncode is not None})
        clock_result = receipt["clock"] or {}
        clock_complete = (clock_result.get("joined") is True and clock_result.get("error") is None
                          and clock_result.get("thread_error") is None
                          and receipt["clock_close_error"] is None)
        receipt.update(rc=rc, ended=shared_now(), complete=clock_complete and all(
            child["joined"] for child in receipt["children"]))
        # One private file per host, no shared append/truncated JSON race.
        with open(journal, "w") as out:
            json.dump(receipt, out)
    return rc


# Set only by the independent entry launcher. A direct/all unittest invocation
# gets a separate clock per bounded case; it is not advertised as a <60s entry.
ACTIVE = None
ENVELOPE_RECORD = None


def envelope_module():
    # Not imported by ordinary discovery/direct tests without the opt-in context.
    import importlib.util
    name = "supervisor_test_envelope"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name,
            os.path.join(os.path.dirname(__file__), "fleet-node-supervisor-selftest-envelope.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def main():
    global ACTIVE
    if len(sys.argv) > 1 and sys.argv[1] == "--outer":
        return envelope_module().outer(sys.modules[__name__], sys.argv[2:])
    if len(sys.argv) == 3 and sys.argv[1] == "--outer-gate":
        return envelope_module().gate(sys.modules[__name__], sys.argv[2])
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        return host(float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5:])
    if len(sys.argv) != 2:
        raise SystemExit("usage: fleet-node-supervisor-selftest-budget.py <case>")
    case = sys.argv[1]
    if "SUPERVISOR_TEST_ENVELOPE" in os.environ:
        return envelope_module().entry(sys.modules[__name__], case)
    print("supervisor-budget-origin " + json.dumps({"pid": os.getpid(), "case": case,
        "clock": clock_identity(), "start": ENTERED, "recorded_at": shared_now(),
        "scope": "helper imports through own cleanup; excludes runner preparation/exit cleanup",
        "shadow_root": os.environ.get("FLEET_SELFTEST_ROOT")}), file=sys.stderr, flush=True)
    ACTIVE = Budget(ENTERED)
    # The test module imports this same object, not a second clock/module.
    sys.modules["supervisor_test_budget"] = sys.modules[__name__]
    source = os.path.join(os.path.dirname(__file__), "fleet-node-supervisor-selftest.py")
    sys.argv = [source, case]
    try:
        runpy.run_path(source, run_name="__main__")
    finally:
        ACTIVE.close()


if __name__ == "__main__":
    sys.exit(main())
