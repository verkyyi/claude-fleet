"""Node-local execution fence in the existing control database.

This module does no Hub I/O and authenticates no remote data. Its caller must
verify the Hub response and map it to the fields below before bind/observe.
``authorized=True`` means a *new explicit grant*, not a cached @dispatch.
Only that grant may create a binding or clear a stop tombstone with no old
binding. Replacing an existing execution needs proof of its exit; this module
does not yet offer that operation and refuses it even for a newer grant.

Admission is a short, task-scoped flock for local fork/registration. Never do
network I/O while holding it. Stop writes deliberately bypass that flock, so
a busy launcher cannot delay durable stop acceptance. A permit must recheck
before each side effect; a stop can still arrive just after a recheck. Runtime
integration must therefore reconcile and terminate any in-flight execution.
This helper neither proves execution-domain exit nor upgrades old sessions.
"""
import contextlib
import fcntl
import os
from pathlib import Path
import re
import stat

from fleet_hub_common import Database, is_identity, private_dir


SCHEMA = """
CREATE TABLE IF NOT EXISTS task_execution_fences (
 task_ref TEXT PRIMARY KEY,
 task_fid TEXT NOT NULL,
 generation INTEGER NOT NULL,
 binding_generation INTEGER NOT NULL,
 attempt_id TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 execution_endpoint TEXT NOT NULL,
 execution_owner TEXT NOT NULL,
 cancel_request TEXT NOT NULL
);
"""
FIELDS = ("task_ref", "task_fid", "generation", "binding_generation", "attempt_id",
          "operation_id", "execution_endpoint", "execution_owner", "cancel_request")
BINDING_FIELDS = ("task_fid", "binding_generation", "attempt_id", "operation_id", "execution_endpoint", "execution_owner")


class FenceRefused(ValueError):
    """Unknown, stale, stopped or contradictory execution authorization."""


def _task_ref(value):
    if not isinstance(value, str) or not re.fullmatch(r"T[1-9][0-9]{0,18}", value):
        raise FenceRefused("execution fence requires a canonical Task reference")
    return value


def _generation(value):
    if type(value) is not int or not 1 <= value <= 2**63 - 1:
        raise FenceRefused("execution fence requires a positive generation")
    return value


def _token(value, label, *, empty=False):
    if empty and value == "":
        return value
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._:/@-]{1,512}", value):
        raise FenceRefused("invalid execution " + label)
    return value


def _snapshot(value):
    if not isinstance(value, dict) or set(value) - set(FIELDS):
        raise FenceRefused("execution snapshot contains unsupported fields")
    row = {key: value.get(key, "") for key in FIELDS}
    row["task_ref"] = _task_ref(row["task_ref"])
    row["generation"] = _generation(row["generation"])
    row["cancel_request"] = _token(row["cancel_request"], "cancel request", empty=True)
    stopping = bool(row["cancel_request"])
    # A stop advances the fence generation but may still name the old attempt.
    attempt = row["attempt_id"]
    match = isinstance(attempt, str) and re.fullmatch(r"task:" + row["task_ref"] + r":g([1-9][0-9]*)", attempt)
    if match:
        binding_generation = _generation(int(match.group(1)))
        if binding_generation > row["generation"] or (not stopping and binding_generation != row["generation"]):
            raise FenceRefused("execution attempt does not match its generation")
    elif stopping and attempt == "":
        binding_generation = 0
    else:
        raise FenceRefused("execution snapshot requires its accepted attempt")
    if "binding_generation" in value and value["binding_generation"] != binding_generation:
        raise FenceRefused("execution binding generation conflicts with its attempt")
    row["binding_generation"] = binding_generation
    if not (stopping and row["task_fid"] == "") and not is_identity(row["task_fid"]):
        raise FenceRefused("execution snapshot requires a stable Hub Task FID")
    worker = row["execution_owner"]
    if not (stopping and worker == ""):
        parts = worker.split("/") if isinstance(worker, str) else []
        if len(parts) != 2 or not all(is_identity(part) for part in parts):
            raise FenceRefused("execution worker identity requires fleet UUID/session UUID")
    for key in ("operation_id", "execution_endpoint"):
        row[key] = _token(row[key], key, empty=stopping)
    return row


class Admission:
    """A permit valid only inside ExecutionFence.admission's context."""

    def __init__(self, fence, expected):
        self._fence = fence
        self._expected = expected
        self._active = True

    def assert_current(self):
        if not self._active:
            raise FenceRefused("execution admission permit has been released")
        return self._fence._assert_current(self._expected)


class ExecutionFence:
    def __init__(self, conf_dir=None):
        self.conf_dir = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")).absolute()
        # Add a table to Control's database, not another journal or state file.
        self.store = Database(self.conf_dir / "control", SCHEMA)
        self._locks = private_dir(self.store.root / "task-admission")

    @contextlib.contextmanager
    def _admission_lock(self, task_ref):
        path = self._locks / (_task_ref(task_ref) + ".lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise FenceRefused("execution admission lock is not a regular file")
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    @staticmethod
    def _read(db, task_ref):
        row = db.execute("SELECT * FROM task_execution_fences WHERE task_ref=?", (task_ref,)).fetchone()
        return dict(row) if row is not None else None

    @staticmethod
    def _save(db, row):
        db.execute("INSERT OR REPLACE INTO task_execution_fences (" + ",".join(FIELDS) + ") VALUES (" +
                   ",".join("?" for _ in FIELDS) + ")", tuple(row[key] for key in FIELDS))

    def read(self, task_ref):
        with self.store.connect() as db:
            return self._read(db, _task_ref(task_ref))

    def snapshot(self):
        with self.store.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM task_execution_fences ORDER BY task_ref")]

    def bind(self, snapshot, *, authorized=False):
        """Install a verified explicit grant; repeated identical grants are inert.

        The caller obtains authorization *before* entering here. A new grant
        must have a strictly higher generation than any locally known stop.
        Old/same snapshots never clear stop and never change binding identity.
        A higher generation is not itself authorization to take over a task.
        Any existing execution binding remains reserved until there is proof
        of exit. There is no release API here yet, so replacing it is refused.
        """
        incoming = _snapshot(snapshot)
        if incoming["cancel_request"] or authorized is not True:
            raise FenceRefused("binding requires an explicit current Hub grant")
        with self._admission_lock(incoming["task_ref"]), self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = self._read(db, incoming["task_ref"])
            if old is not None:
                if incoming["generation"] < old["generation"]:
                    raise FenceRefused("execution grant is older than the local fence")
                if incoming["generation"] == old["generation"]:
                    if old != incoming:
                        raise FenceRefused("execution grant conflicts with the local binding or stop")
                    return old
                if old["binding_generation"] or any(old[key] for key in ("attempt_id", "operation_id", "execution_endpoint", "execution_owner")):
                    raise FenceRefused("replacing a known execution requires matching exit proof")
                if old["task_fid"] and old["task_fid"] != incoming["task_fid"]:
                    raise FenceRefused("execution grant changes the stable Task identity")
            self._save(db, incoming)
            return incoming

    def observe(self, snapshot):
        """Apply a verified stop or confirm the exact binding; never adopt one.

        A stop may omit its binding fields. The known old execution target is
        retained so a later runtime reconciliation still knows what to stop.
        """
        incoming = _snapshot(snapshot)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = self._read(db, incoming["task_ref"])
            if old is None:
                raise FenceRefused("unknown execution binding; an explicit grant is required")
            if incoming["generation"] < old["generation"]:
                raise FenceRefused("execution snapshot is older than the local fence")
            if incoming["cancel_request"]:
                for key in BINDING_FIELDS:
                    if incoming[key] and incoming[key] != old[key]:
                        raise FenceRefused("stop snapshot conflicts with the known execution target")
                return self._stop(db, old, incoming["cancel_request"], incoming["generation"])
            if old != incoming:
                raise FenceRefused("snapshot cannot change execution authorization or clear stop")
            return old

    @classmethod
    def _stop(cls, db, old, cancel_request, generation):
        if generation < old["generation"]:
            raise FenceRefused("stop request is older than the local fence")
        stopped = dict(old, generation=generation, cancel_request=old["cancel_request"] or cancel_request)
        if stopped != old:
            cls._save(db, stopped)
        return stopped

    def request_stop(self, task_ref, cancel_request, *, generation=None):
        """Commit a stop before any wait for admission or runtime shutdown.

        Pass the authoritative generation when it is known. Omitting it closes
        local admission at the already observed generation; it does not mint a
        Hub generation. Repeated stop requests retain the first cancel request.
        An unknown task needs an explicit verified generation; persist a stop
        tombstone even when stop arrives before its binding. Never infer a
        generation or an execution target from a legacy @dispatch.
        """
        task_ref = _task_ref(task_ref)
        cancel_request = _token(cancel_request, "cancel request")
        if generation is not None:
            _generation(generation)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = self._read(db, task_ref)
            if old is None:
                if generation is None:
                    raise FenceRefused("stop for an unknown task requires its verified Hub generation")
                stopped = dict.fromkeys(FIELDS, "")
                stopped.update(task_ref=task_ref, generation=generation, binding_generation=0,
                               cancel_request=cancel_request)
                self._save(db, stopped)
                return stopped
            return self._stop(db, old, cancel_request, generation if generation is not None else old["generation"])

    def _assert_current(self, expected):
        actual = self.read(expected["task_ref"])
        if actual is None or actual["cancel_request"] or actual != expected:
            raise FenceRefused("execution is unknown, stopped or no longer current")
        return actual

    @contextlib.contextmanager
    def admission(self, expected):
        """Hold through local fork/registration; recheck before each side effect.

        No database transaction spans the body. Stop can commit during it.
        The final recheck detects this for the caller's runtime cleanup, but
        does not promise that already-forked processes have exited.
        """
        expected = _snapshot(expected)
        with self._admission_lock(expected["task_ref"]):
            permit = Admission(self, expected)
            try:
                permit.assert_current()
                yield permit
                permit.assert_current()
            finally:
                permit._active = False

    def assert_current(self, expected):
        """One short admission check; use admission() to cover fork/registration."""
        with self.admission(expected) as permit:
            return permit.assert_current()
