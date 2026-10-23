"""Node-local execution fence in the existing control database.

Pure fence operations accept only already-verified snapshots. The runtime
entrypoints obtain fresh snapshots through the existing authenticated node
transport, outside all admission locks. ``authorized=True`` means a *new
explicit grant*, not a cached @dispatch.
Only that grant may create a binding or clear a stop tombstone with no old
binding. Ordinary bind never replaces an existing execution. The separate
continuation method additionally requires the exact acknowledged exit proof.

Admission is a short, task-scoped flock for local fork/registration. Never do
network I/O while holding it. Stop writes deliberately bypass that flock, so
a busy launcher cannot delay durable stop acceptance. A permit must recheck
before each side effect; a stop can still arrive just after a recheck. Runtime
integration must therefore reconcile and terminate any in-flight execution.
The opt-in read-only proof below covers registered native-session roots only,
not execution-domain exit; it does not upgrade old sessions.
"""
import contextlib
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import signal
import subprocess
import sys
import time
import uuid
from urllib.parse import quote

from fleet_hub_common import Database, is_identity, private_dir


SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
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
CREATE TABLE IF NOT EXISTS task_execution_sessions (
 task_ref TEXT PRIMARY KEY, operation_id TEXT NOT NULL, execution_owner TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_execution_windows (
 task_ref TEXT PRIMARY KEY, operation_id TEXT NOT NULL, execution_owner TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS task_execution_launches (
 task_ref TEXT PRIMARY KEY, launch_id TEXT NOT NULL, operation_id TEXT NOT NULL,
 supervisor TEXT NOT NULL, wrapper TEXT NOT NULL, child TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS task_execution_native (
 task_ref TEXT NOT NULL, launch_id TEXT NOT NULL, component TEXT NOT NULL,
 process TEXT NOT NULL, PRIMARY KEY (task_ref, launch_id, component)
);
CREATE TABLE IF NOT EXISTS task_execution_launch_history (
 task_ref TEXT NOT NULL, launch_id TEXT NOT NULL, registration TEXT NOT NULL,
 PRIMARY KEY (task_ref, launch_id)
);
"""
FIELDS = ("task_ref", "task_fid", "generation", "binding_generation", "attempt_id",
          "operation_id", "execution_endpoint", "execution_owner", "cancel_request")
BINDING_FIELDS = ("task_fid", "binding_generation", "attempt_id", "operation_id", "execution_endpoint", "execution_owner")


class FenceRefused(ValueError):
    """Unknown, stale, stopped or contradictory execution authorization."""


def _historical_session_stop(db, session_fid):
    """A replaced current slot must not turn an old controlled FID into legacy.

    The existing immutable stop request remains the source of its revocation;
    receipt ACK and cleanup status do not affect whether the session is stopped.
    """
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='operations'").fetchone():
        return None
    rows = db.execute("""SELECT id,request FROM operations WHERE action='worker_stop'
        AND json_extract(request,'$.control_version')=1
        AND json_extract(request,'$.task_execution.execution_owner') LIKE ?""", ('%/' + session_fid,)).fetchall()
    found = None
    for row in rows:
        request = json.loads(row['request'])
        snapshot = validate_request(request)
        if (snapshot is None or request['action'] != 'worker_stop' or row['id'] != snapshot['cancel_request']
                or snapshot['execution_owner'].split('/')[-1] != session_fid):
            raise FenceRefused('historical session stop is inconsistent')
        if found is not None and found != snapshot:
            raise FenceRefused('session has conflicting historical stop bindings')
        found = snapshot
    from fleet_task_unclaimed import historical_stop
    retired = historical_stop(db, session_fid)
    if retired is not None:
        if found is not None and found != retired:
            raise FenceRefused('session has conflicting historical stop bindings')
        found = retired
    return found


def read_session(session_fid, *, conf_dir=None):
    """Read-only observation, including a stop; this never grants permission."""
    if not is_identity(session_fid):
        raise FenceRefused("session lookup requires its immutable FID")
    root = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")).absolute()
    path = root / "control/state.sqlite3"
    rows = []
    if path.exists():
        try:
            with contextlib.closing(sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro", uri=True, timeout=2)) as db:
                db.row_factory = sqlite3.Row
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_execution_fences'").fetchone():
                    rows = db.execute("SELECT * FROM task_execution_fences WHERE execution_owner LIKE ?",
                                      ("%/" + session_fid,)).fetchall()
                if not rows:
                    historical = _historical_session_stop(db, session_fid)
                    rows = [historical] if historical else []
        except (sqlite3.Error, ValueError, TypeError, KeyError) as exc:
            raise FenceRefused("task execution fence is unavailable") from exc
    if len(rows) > 1:
        raise FenceRefused("session has conflicting task execution bindings")
    return dict(rows[0]) if rows else None


def read_task(task_ref, *, conf_dir=None):
    """Read a Task's local binding/tombstone without creating state or authorizing."""
    task_ref = _task_ref(task_ref)
    root = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")).absolute()
    path = root / "control/state.sqlite3"
    if not path.exists():
        return None
    try:
        with contextlib.closing(sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro", uri=True, timeout=2)) as db:
            db.row_factory = sqlite3.Row
            if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_execution_fences'").fetchone():
                return None
            row = db.execute("SELECT * FROM task_execution_fences WHERE task_ref=?", (task_ref,)).fetchone()
            return dict(row) if row else None
    except sqlite3.Error as exc:
        raise FenceRefused("task execution fence is unavailable") from exc


def check_session(session_fid, *, conf_dir=None, expected=None, controlled=False):
    """Read-only ingress check: legacy missing state is inert, controlled isn't."""
    if expected is not None:
        expected = _snapshot(expected)
        controlled = True
        if expected["execution_owner"].rsplit("/", 1)[-1] != session_fid:
            raise FenceRefused("execution metadata names another session")
    row = read_session(session_fid, conf_dir=conf_dir)
    if row is None:
        if controlled:
            raise FenceRefused("controlled session has no local execution fence")
        return None
    if row["cancel_request"]:
        raise FenceRefused("task stop forbids further launch, wake or turn delivery")
    if expected is not None and row != expected:
        raise FenceRefused("execution metadata no longer matches the local fence")
    return row


def _authority(command, task_ref="", *, conf_dir=None):
    env = dict(os.environ, FLEET_HUB_TIMEOUT="10")
    if conf_dir is not None:
        env["FLEET_CONF_DIR"] = str(conf_dir)
    try:
        result = subprocess.run(["bash", str(Path(__file__).with_name("fleet-task-record.sh")), command,
                                 *([task_ref] if task_ref else [])], text=True, capture_output=True, timeout=15, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise FenceRefused("fresh authenticated task execution authority is unavailable") from exc
    if result.returncode:
        raise FenceRefused("fresh authenticated task execution authority is unavailable")
    return json.loads(result.stdout)


def refresh_session(session_fid, *, conf_dir=None, expected=None, controlled=False, read=None, read_stops=None):
    """Sync stops then read fresh authority BEFORE FID/admission/queue/wake locks.

    The independent read_stops/read callbacks replace transport only; neither
    omits validation or persistence. Legacy sessions never need either read.
    """
    current = check_session(session_fid, conf_dir=conf_dir, expected=expected, controlled=controlled)
    if current is None:
        return None
    sync_stops(conf_dir=conf_dir, read=read_stops)
    # Sync may revoke this session. Do not let a subsequent/cached active GET
    # override its tombstone or proceed using the pre-sync observation.
    current = check_session(session_fid, conf_dir=conf_dir, expected=expected, controlled=controlled)
    if current is None:
        raise FenceRefused("controlled session lost its local execution fence during synchronization")
    response = (read(current["task_ref"]) if read else
                _authority("execution-get", current["task_ref"], conf_dir=conf_dir))
    actual = _snapshot(response, allow_unclaimed=True)
    if actual["task_ref"] != current["task_ref"] or actual["task_fid"] != current["task_fid"]:
        raise FenceRefused("authority response names a different task")
    fence = ExecutionFence(conf_dir)
    if actual["cancel_request"]:
        fence.apply_stop(actual)
        raise FenceRefused("task stop forbids further launch, wake or turn delivery")
    if actual != current:
        raise FenceRefused("execution authority no longer matches the local session")
    fence.observe(actual)
    return actual


def sync_stops(*, conf_dir=None, read=None):
    """Reconnect barrier: import every verified endpoint stop before any starts."""
    response = read() if read else _authority("execution-list", conf_dir=conf_dir)
    if (not isinstance(response, dict) or type(response.get("control_version")) is not int
            or response["control_version"] != 1 or not isinstance(response.get("task_executions"), list)):
        raise FenceRefused("invalid task execution synchronization response")
    snapshots = [_snapshot(item, allow_unclaimed=True) for item in response["task_executions"]]
    try:
        fence = ExecutionFence(conf_dir)
        stopped = []
        for snapshot in snapshots:
            if snapshot["cancel_request"]:
                stopped.append(fence.apply_stop(snapshot))
        return stopped
    except (OSError, sqlite3.Error) as exc:
        # Controlled callers have not allocated or started anything yet. A
        # failed local stop import refuses admission; it is not an unknown
        # start outcome and must not leak past their normal refusal handling.
        raise FenceRefused("local task stop synchronization is unavailable") from exc


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


def _snapshot(value, *, allow_unclaimed=False):
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
    if not ((stopping or allow_unclaimed) and worker == ""):
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

    def reserve_launch(self, launch_id, supervisor, *, wrapper=None):
        """Consume this grant once, durably, before fork; never replay on doubt."""
        self.assert_current()
        _token(launch_id, "launch id")
        supervisor = _process_proof(supervisor)
        wrapper = _process_proof(wrapper or supervisor)
        previous = self._fence.launch(self._expected["task_ref"])
        if previous:
            if previous["wrapper"] != wrapper or not _same_birth(wrapper):
                raise FenceRefused("another wrapper incarnation owns this task grant")
            proofs = [previous["supervisor"], *([previous["child"]] if previous["child"] else []),
                      *(item["process"] for item in previous["native"])]
            if not all(_definitely_exited(proof) for proof in proofs):
                raise FenceRefused("the previous native launch has not verifiably exited")
        with self._fence.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._fence._assert_current_in(db, self._expected)
            current = db.execute("SELECT launch_id FROM task_execution_launches WHERE task_ref=?",
                                 (self._expected["task_ref"],)).fetchone()
            if (current is None) != (previous is None) or (current and current[0] != previous["launch_id"]):
                raise FenceRefused("native launch registration changed during admission")
            if previous:
                db.execute("INSERT INTO task_execution_launch_history VALUES (?,?,?)",
                           (self._expected["task_ref"], previous["launch_id"], json.dumps(previous)))
                db.execute("DELETE FROM task_execution_launches WHERE task_ref=?", (self._expected["task_ref"],))
            db.execute("INSERT INTO task_execution_launches (task_ref,launch_id,operation_id,supervisor,wrapper) VALUES (?,?,?,?,?)",
                       (self._expected["task_ref"], launch_id, self._expected["operation_id"], json.dumps(supervisor), json.dumps(wrapper)))

    def register_child(self, launch_id, child):
        self.assert_current()
        child = _process_proof(child)
        with self._fence.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._fence._assert_current_in(db, self._expected)
            row = db.execute("SELECT * FROM task_execution_launches WHERE task_ref=?",
                             (self._expected["task_ref"],)).fetchone()
            if row is None or row["launch_id"] != launch_id or row["child"]:
                raise FenceRefused("launch child was already registered or its reservation changed")
            db.execute("UPDATE task_execution_launches SET child=? WHERE task_ref=?",
                       (json.dumps(child), self._expected["task_ref"]))

    def register_native(self, launch_id, component, proof):
        """Consume one actual native component slot immediately before exec."""
        self.assert_current()
        if component not in ("agent", "server", "client"):
            raise FenceRefused("unknown native execution component")
        proof = _process_proof(proof)
        with self._fence.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._fence._assert_current_in(db, self._expected)
            row = db.execute("SELECT * FROM task_execution_launches WHERE task_ref=?",
                             (self._expected["task_ref"],)).fetchone()
            if row is None or row["launch_id"] != launch_id or row["operation_id"] != self._expected["operation_id"]:
                raise FenceRefused("native launch has no matching reservation")
            prior = db.execute("SELECT component FROM task_execution_native WHERE task_ref=? AND launch_id=?",
                               (self._expected["task_ref"], launch_id)).fetchall()
            components = {item[0] for item in prior}
            if component in components or (component == "agent" and components) or "agent" in components:
                raise FenceRefused("native execution component was already consumed")
            db.execute("INSERT INTO task_execution_native VALUES (?,?,?,?)",
                       (self._expected["task_ref"], launch_id, component, json.dumps(proof)))


def _process_proof(value):
    if (not isinstance(value, dict) or type(value.get("pid")) is not int or value["pid"] <= 1
            or not isinstance(value.get("birth"), str) or not value["birth"]):
        raise FenceRefused("process registration requires kernel PID and birth identity")
    # Executable changes on exec; birth, rather than its former executable path,
    # identifies the same process after the final native admission.
    return dict(pid=value["pid"], birth=value["birth"])


def validate_request(request):
    """Cross-check the authenticated control envelope before journalling it."""
    if "control_version" not in request and "task_execution" not in request:
        return None
    if type(request.get("control_version")) is not int or request["control_version"] != 1:
        raise FenceRefused("unsupported task execution control protocol")
    expected = _snapshot(request.get("task_execution"), allow_unclaimed=True)
    params = request["params"]
    owner = expected["execution_owner"]
    if owner and owner.split("/")[0] != request["fleet_id"]:
        raise FenceRefused("execution owner belongs to another fleet")
    if params.get("task") != expected["task_ref"]:
        raise FenceRefused("operation and execution snapshot name different tasks")
    if request["action"] == "worker_start":
        dispatch = params.get("dispatch") or {}
        if (expected["cancel_request"] or request["operation_id"] != expected["operation_id"]
                or dispatch.get("task") != expected["task_ref"]
                or dispatch.get("generation") != expected["generation"]
                or dispatch.get("attempt_id") != expected["attempt_id"]):
            raise FenceRefused("start operation does not match its execution grant")
    elif request["action"] == "worker_stop":
        if (not expected["cancel_request"] or request["operation_id"] != expected["cancel_request"]
                or params.get("start_operation_id") != expected["operation_id"]
                or params.get("generation") != expected["binding_generation"]
                or params.get("attempt_id") != expected["attempt_id"]
                or params.get("execution_endpoint") != expected["execution_endpoint"]
                or params.get("worker_id", "") != owner):
            raise FenceRefused("stop operation does not match its execution fence")
    else:
        raise FenceRefused("task execution envelope only supports start or stop")
    return expected


def claim_execution(snapshot, fleet_id, *, conf_dir=None, call=None, read_stops=None):
    """Sync stops before allocation, then authenticate claim and bind, lock-free I/O."""
    expected = _snapshot(snapshot, allow_unclaimed=True)
    if expected["cancel_request"] or not is_identity(fleet_id):
        raise FenceRefused("cannot allocate a stopped or unidentified execution")
    sync_stops(conf_dir=conf_dir, read=read_stops)
    fence = ExecutionFence(conf_dir)
    worker = fence.allocate_worker(expected, fleet_id)
    body = dict(control_version=1, operation_id=expected["operation_id"], worker_id=worker,
                generation=expected["generation"], attempt_id=expected["attempt_id"])
    if call is None:
        result = subprocess.run(["bash", str(Path(__file__).with_name("fleet-task-record.sh")),
                                 "execution-claim", expected["task_ref"]], input=json.dumps(body),
                                text=True, capture_output=True, timeout=15,
                                env=dict(os.environ, FLEET_CONF_DIR=str(fence.conf_dir), FLEET_HUB_TIMEOUT="10"))
        if result.returncode:
            raise FenceRefused("authenticated task execution claim was unavailable or refused")
        actual = json.loads(result.stdout)
    else:
        actual = call(expected["task_ref"], body)
    actual = _snapshot(actual)
    wanted = dict(expected, execution_owner=worker)
    if actual != wanted:
        if actual["task_ref"] == expected["task_ref"] and actual["cancel_request"]:
            fence.apply_stop(actual)
        raise FenceRefused("Hub claim changed the accepted execution authorization")
    return fence.bind(actual, authorized=True)


def continue_execution(snapshot, fleet_id, exit_operation_id, *, conf_dir=None, read=None, call=None, read_stops=None):
    """Explicit opt-in only: fresh authority before local replacement and claim.

    No normal start/bind path calls this function. The callbacks replace only
    authenticated transport for isolated tests; all validation remains active.
    Network is outside the admission lock and SQLite transaction. A claim failure
    retains the same durable allocation for a retry and starts no native process.
    """
    expected = _snapshot(snapshot, allow_unclaimed=True)
    sync_stops(conf_dir=conf_dir, read=read_stops)
    actual = _snapshot(read(expected['task_ref']) if read else
                       _authority('execution-get', expected['task_ref'], conf_dir=conf_dir), allow_unclaimed=True)
    if actual != dict(expected, execution_owner=actual['execution_owner'] if not expected['execution_owner'] else expected['execution_owner']):
        raise FenceRefused('continuation grant is no longer the latest authenticated authority')
    fence = ExecutionFence(conf_dir)
    fence.continue_binding(actual, fleet_id, exit_operation_id, authorized=True)
    return claim_execution(actual, fleet_id, conf_dir=conf_dir, call=call, read_stops=read_stops)


def continue_unclaimed_execution(snapshot, fleet_id, continuation, dispatch, *, conf_dir=None,
                                 read_start=None, call=None, read_stops=None):
    """Fresh authenticated immediate stop, pure local replacement, then Hub claim."""
    from fleet_dispatch import check_current
    from fleet_task_continuation import validate_continuation
    expected = _snapshot(snapshot, allow_unclaimed=True)
    validate_continuation(continuation)
    if 'stop_operation_id' not in continuation:
        raise FenceRefused('unclaimed continuation requires its stop proof branch')
    sync_stops(conf_dir=conf_dir, read=read_stops)
    try:
        authority = check_current(dispatch, execution=expected, continuation=continuation, read_start=read_start)
    except ValueError as exc:
        raise FenceRefused(str(exc)) from exc
    if authority is None:
        raise FenceRefused('unclaimed continuation requires its authenticated start')
    actual = _snapshot(authority['task_execution'], allow_unclaimed=True)
    ExecutionFence(conf_dir).continue_unclaimed(actual, fleet_id, authority['source_stop'], authorized=True)
    return claim_execution(actual, fleet_id, conf_dir=conf_dir, call=call, read_stops=read_stops)


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

    def allocate_worker(self, snapshot, fleet_id):
        """Allocate a real session identity once before authenticated Hub claim."""
        incoming = _snapshot(snapshot, allow_unclaimed=True)
        if incoming["cancel_request"] or not is_identity(fleet_id):
            raise FenceRefused("cannot allocate a stopped or unidentified execution")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = self._read(db, incoming["task_ref"])
            if old and (old["cancel_request"] or old["generation"] != incoming["generation"]):
                raise FenceRefused("allocation conflicts with the local execution fence")
            row = db.execute("SELECT * FROM task_execution_sessions WHERE task_ref=?", (incoming["task_ref"],)).fetchone()
            if row:
                if row["operation_id"] != incoming["operation_id"] or not row["execution_owner"].startswith(fleet_id + "/"):
                    raise FenceRefused("another operation already allocated this task session")
                worker = row["execution_owner"]
            else:
                worker = fleet_id + "/" + str(uuid.uuid4())
                if incoming["execution_owner"]:
                    raise FenceRefused("cannot adopt a claimed worker without its local allocation")
                db.execute("INSERT INTO task_execution_sessions VALUES (?,?,?)",
                           (incoming["task_ref"], incoming["operation_id"], worker))
            if incoming["execution_owner"] and incoming["execution_owner"] != worker:
                raise FenceRefused("Hub claim does not match the allocated session")
            return worker

    def launch(self, task_ref, *, timeout=None):
        with self.store.connect() as db:
            if timeout is not None:
                db.execute("PRAGMA busy_timeout=%d" % max(0, int(timeout * 1000)))
            row = db.execute("SELECT * FROM task_execution_launches WHERE task_ref=?", (_task_ref(task_ref),)).fetchone()
            if row is None:
                return None
            result = dict(row)
            for key in ("supervisor", "wrapper", "child"):
                result[key] = json.loads(result[key]) if result[key] else None
            result["native"] = [dict(component=item["component"], process=json.loads(item["process"]))
                                for item in db.execute("SELECT * FROM task_execution_native WHERE task_ref=? AND launch_id=?",
                                                       (task_ref, result["launch_id"]))]
            return result

    def reserve_window(self, expected):
        """Reserve the one new window before tmux; uncertainty is not retry permission."""
        expected = _snapshot(expected)
        with self.admission(expected), self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            self._assert_current_in(db, expected)
            if db.execute("SELECT 1 FROM task_execution_windows WHERE task_ref=?", (expected["task_ref"],)).fetchone():
                raise FenceRefused("task window was already reserved; do not create a second session")
            db.execute("INSERT INTO task_execution_windows VALUES (?,?,?)",
                       (expected["task_ref"], expected["operation_id"], expected["execution_owner"]))

    def for_session(self, session_fid):
        return read_session(session_fid, conf_dir=self.conf_dir)

    def assert_session_allowed(self, session_fid):
        row = self.for_session(session_fid)
        if row is not None and row["cancel_request"]:
            raise FenceRefused("task stop forbids further launch, wake or turn delivery")
        return row

    def bind(self, snapshot, *, authorized=False):
        """Install a verified explicit grant; repeated identical grants are inert.

        The caller obtains authorization *before* entering here. A new grant
        must have a strictly higher generation than any locally known stop.
        Old/same snapshots never clear stop and never change binding identity.
        A higher generation is not itself authorization to take over a task.
        Any existing execution binding remains reserved; only the separate
        explicit continuation method may replace it using acknowledged proof.
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

    def continue_binding(self, snapshot, fleet_id, exit_operation_id, *, authorized=False):
        """Atomically replace one proved old attempt and allocate its successor.

        Like bind, the caller must obtain current authenticated authority first.
        Unlike bind, this requires the exact confirmed old stop packet. The new
        allocation is recorded beside that packet for crash/idempotency recovery;
        original proof bytes and old-FID revocation remain in the stop journal.
        No networking, process observation, signaling or launch happens here.
        """
        from fleet_task_exit_submit import acknowledged_native_exit, RECEIPT
        incoming = _snapshot(snapshot, allow_unclaimed=True)
        if authorized is not True or incoming['cancel_request'] or not is_identity(fleet_id):
            raise FenceRefused('continuation requires an explicit current Hub grant')
        try:
            with self._admission_lock(incoming['task_ref']), self.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                row, stopped, result, receipt = acknowledged_native_exit(db, exit_operation_id)
                old = self._read(db, incoming['task_ref'])
                if (stopped['task_ref'] != incoming['task_ref'] or stopped['task_fid'] != incoming['task_fid']
                        or stopped['execution_endpoint'] != incoming['execution_endpoint']
                        or stopped['execution_owner'].split('/')[0] != fleet_id
                        or incoming['generation'] != stopped['generation'] + 1
                        or stopped['generation'] != stopped['binding_generation'] + 1
                        or incoming['operation_id'] in (stopped['operation_id'], stopped['cancel_request'])):
                    raise FenceRefused('continuation does not match the proved Task, endpoint or generation')
                saved = receipt.get('continuation')
                if saved is not None:
                    if not isinstance(saved, dict):
                        raise FenceRefused('malformed original continuation allocation')
                    allocated = _snapshot(saved['snapshot'])
                    wanted = dict(incoming, execution_owner=allocated['execution_owner'])
                    session = db.execute('SELECT * FROM task_execution_sessions WHERE task_ref=?',
                                         (incoming['task_ref'],)).fetchone()
                    if (allocated != wanted or old != allocated or incoming['execution_owner'] not in ('', allocated['execution_owner'])
                            or session is None or session['operation_id'] != allocated['operation_id']
                            or session['execution_owner'] != allocated['execution_owner']):
                        raise FenceRefused('continuation was replaced, stopped or conflicts with its original allocation')
                    return allocated
                if old != stopped or incoming['execution_owner']:
                    raise FenceRefused('continuation cannot adopt a different or already claimed execution')
                proof = receipt['payload']['proof']
                launches = _session_exit_registrations(db, stopped, proof['provider'])
                _match_exit_registrations(proof, launches)
                # These two slots are created before native launch. A missing or
                # conflicting slot is uncertainty, not permission to reconstruct.
                for table in ('task_execution_sessions', 'task_execution_windows'):
                    slot = db.execute('SELECT * FROM ' + table + ' WHERE task_ref=?', (incoming['task_ref'],)).fetchone()
                    if slot is None or slot['operation_id'] != stopped['operation_id'] or slot['execution_owner'] != stopped['execution_owner']:
                        raise FenceRefused('continuation has missing or conflicting old session/window reservation')
                worker = fleet_id + '/' + str(uuid.uuid4())
                if worker == stopped['execution_owner'] or worker.split('/')[1] == incoming['task_fid']:
                    raise FenceRefused('continuation requires a fresh Session FID')
                allocated = dict(incoming, execution_owner=worker)
                # Archive full registration beside the already persisted proof,
                # then retire only the checked operation/launches from active
                # slots. New stop proofs must not read an older operation's roots.
                receipt['continuation'] = dict(snapshot=allocated, registrations=launches)
                result[RECEIPT] = receipt
                db.execute('UPDATE operations SET result=? WHERE id=?', (json.dumps(result, separators=(',', ':')), row['id']))
                for launch in launches:
                    db.execute('DELETE FROM task_execution_native WHERE task_ref=? AND launch_id=?', (incoming['task_ref'], launch['launch_id']))
                    db.execute('DELETE FROM task_execution_launch_history WHERE task_ref=? AND launch_id=?', (incoming['task_ref'], launch['launch_id']))
                db.execute('DELETE FROM task_execution_launches WHERE task_ref=? AND operation_id=?', (incoming['task_ref'], stopped['operation_id']))
                db.execute('DELETE FROM task_execution_windows WHERE task_ref=? AND operation_id=?', (incoming['task_ref'], stopped['operation_id']))
                db.execute('UPDATE task_execution_sessions SET operation_id=?,execution_owner=? WHERE task_ref=? AND operation_id=?',
                           (allocated['operation_id'], worker, incoming['task_ref'], stopped['operation_id']))
                self._save(db, allocated)
                return allocated
        except (sqlite3.Error, OSError, ValueError, KeyError, TypeError, OverflowError) as exc:
            if isinstance(exc, FenceRefused):
                raise
            raise FenceRefused('local continuation evidence is unavailable or inconsistent') from exc

    def continue_unclaimed(self, snapshot, fleet_id, source_stop, *, authorized=False):
        """Separate explicit entry: never infer native exit from an empty claim."""
        from fleet_task_unclaimed import replace_unclaimed
        return replace_unclaimed(self, snapshot, fleet_id, source_stop, authorized=authorized)

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
        if not old["cancel_request"]:
            cls._remember_stop(db, stopped)
        return stopped

    @staticmethod
    def _remember_stop(db, stopped):
        # A cleanup opportunity must never make durable stop acceptance fail.
        # The existing metadata namespace also works without a Control journal.
        try:
            from fleet_native_stop import remember_stop
            remember_stop(db, stopped)
        except (ImportError, OSError, ValueError, TypeError, KeyError, sqlite3.Error):
            pass

    def request_stop(self, task_ref, cancel_request, *, generation=None):
        """Commit a stop before any wait for admission or runtime shutdown.

        Pass the authoritative generation when it is known. Omitting it closes
        local admission at the already observed generation; it does not mint a
        Hub generation. Repeated stop requests retain the first cancel request.
        An unknown task needs an explicit verified generation; persist a stop
        tombstone even when stop arrives before its binding. Never infer a
        generation or an execution target from a legacy @dispatch.
        """
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            return self.request_stop_in_transaction(db, task_ref, cancel_request, generation=generation)

    def apply_stop(self, snapshot):
        """Persist a verified stopped snapshot, including a previously unknown target."""
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            return self.apply_stop_in_transaction(db, snapshot)

    def apply_stop_in_transaction(self, db, snapshot):
        if not db.in_transaction:
            raise FenceRefused("stop persistence requires an explicit caller transaction")
        incoming = _snapshot(snapshot, allow_unclaimed=True)
        if not incoming["cancel_request"]:
            raise FenceRefused("stop synchronization requires a stop request")
        old = self._read(db, incoming["task_ref"])
        if old is None:
            self._save(db, incoming)
            self._remember_stop(db, incoming)
            return incoming
        if old["task_fid"] and old["task_fid"] != incoming["task_fid"]:
            raise FenceRefused("stop snapshot changes the known Task identity")
        for key in BINDING_FIELDS:
            if incoming[key] and old[key] and incoming[key] != old[key]:
                raise FenceRefused("stop snapshot conflicts with the known execution target")
        return self._stop(db, old, incoming["cancel_request"], incoming["generation"])

    def request_stop_in_transaction(self, db, task_ref, cancel_request, *, generation=None):
        """Control may persist its receipt and stop in ONE existing transaction."""
        if not db.in_transaction:
            raise FenceRefused("stop persistence requires an explicit caller transaction")
        task_ref = _task_ref(task_ref)
        cancel_request = _token(cancel_request, "cancel request")
        if generation is not None:
            _generation(generation)
        old = self._read(db, task_ref)
        if old is None:
            if generation is None:
                raise FenceRefused("stop for an unknown task requires its verified Hub generation")
            stopped = dict.fromkeys(FIELDS, "")
            stopped.update(task_ref=task_ref, generation=generation, binding_generation=0,
                           cancel_request=cancel_request)
            self._save(db, stopped)
            self._remember_stop(db, stopped)
            return stopped
        return self._stop(db, old, cancel_request, generation if generation is not None else old["generation"])

    def _assert_current_in(self, db, expected):
        actual = self._read(db, expected["task_ref"])
        if actual is None or actual["cancel_request"] or actual != expected:
            raise FenceRefused("execution is unknown, stopped or no longer current")
        return actual

    def _assert_current(self, expected, *, timeout=None):
        with self.store.connect() as db:
            if timeout is not None:
                db.execute("PRAGMA busy_timeout=%d" % max(0, int(timeout * 1000)))
            return self._assert_current_in(db, expected)

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


def _kernel_process(pid):
    from fleet_native_proc import process
    return _process_proof(process(pid))


def _same_birth(proof):
    from fleet_native_proc import birth_token, kernel_identity
    try:
        return kernel_identity(proof["pid"])["birth_token"] == birth_token(proof["birth"])
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def _definitely_exited(proof):
    return _session_root_exit_evidence(proof) is not None


def _session_root_exit_evidence(proof):
    """One exit predicate shared by launch recovery and read-only session proof."""
    from fleet_native_proc import birth_token, kernel_identity
    proof = _process_proof(proof)
    try:
        registered = birth_token(proof["birth"])
    except ValueError as exc:
        raise FenceRefused("registered kernel birth is unavailable") from exc
    try:
        os.kill(proof["pid"], 0)
    except ProcessLookupError:
        return dict(proof, evidence="pid_absent")
    except OSError as exc:
        raise FenceRefused("native session root exit cannot be observed") from exc
    try:
        current = kernel_identity(proof["pid"])
    except ProcessLookupError:
        # Missing /proc data can mean hidden/unmounted procfs, not exit.
        # Re-probe after the failed read; a live/reused or inaccessible PID
        # cannot establish which registered process the missing record was.
        try:
            os.kill(proof["pid"], 0)
        except ProcessLookupError:
            return dict(proof, evidence="pid_absent")
        except OSError as exc:
            raise FenceRefused("native session root exit cannot be observed") from exc
        raise FenceRefused("native session root birth/state cannot be observed")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise FenceRefused("native session root birth/state cannot be observed") from exc
    if current["birth_token"] != registered:
        return dict(proof, evidence="pid_reused", observed_kernel_birth=current["birth_token"])
    if current["state"] == "Z":
        return dict(proof, evidence="kernel_zombie", observed_kernel_birth=current["birth_token"], kernel_state="Z")
    return None


def _session_exit_registrations(db, expected, provider):
    """Read a complete registration set; an empty launch is not exit evidence."""
    actual = ExecutionFence._read(db, expected["task_ref"])
    if actual is None or _snapshot(actual) != expected or not actual["cancel_request"]:
        raise FenceRefused("native session exit requires the exact persisted stop snapshot")
    task = expected["task_ref"]
    current = db.execute("SELECT * FROM task_execution_launches WHERE task_ref=?", (task,)).fetchone()
    if current is None:
        raise FenceRefused("native session exit has no launch registration; never-started is unproven")
    current = dict(current)
    for key in ("supervisor", "wrapper", "child"):
        current[key] = json.loads(current[key]) if current[key] else None
    native = {}
    for row in db.execute("SELECT * FROM task_execution_native WHERE task_ref=? ORDER BY launch_id,component", (task,)):
        native.setdefault(row["launch_id"], []).append(dict(component=row["component"], process=json.loads(row["process"])))
    current["native"] = native.get(current["launch_id"], [])
    launches = []
    for row in db.execute("SELECT * FROM task_execution_launch_history WHERE task_ref=? ORDER BY launch_id", (task,)):
        old = json.loads(row["registration"])
        if not isinstance(old, dict) or old.get("launch_id") != row["launch_id"]:
            raise FenceRefused("native session exit has inconsistent launch history")
        launches.append(old)
    launches.append(current)
    seen = set()
    required = {"server", "client"} if provider == "codex" else {"agent"}
    keys = {"task_ref", "launch_id", "operation_id", "supervisor", "wrapper", "child", "native"}
    for launch in launches:
        if (set(launch) != keys or launch["task_ref"] != task
                or launch["operation_id"] != expected["operation_id"]
                or launch["launch_id"] in seen):
            raise FenceRefused("native session exit has conflicting launch identity")
        _token(launch["launch_id"], "launch id")
        seen.add(launch["launch_id"])
        for key in ("supervisor", "wrapper", "child"):
            if _process_proof(launch[key]) != launch[key]:
                raise FenceRefused("native session exit has malformed process registration")
        if launch["wrapper"] != current["wrapper"] or not isinstance(launch["native"], list):
            raise FenceRefused("native session exit has conflicting wrapper or native registration")
        components = set()
        for item in launch["native"]:
            if (not isinstance(item, dict) or set(item) != {"component", "process"}
                    or item["component"] in components
                    or _process_proof(item["process"]) != item["process"]):
                raise FenceRefused("native session exit has malformed native registration")
            components.add(item["component"])
        # reserve_launch can archive an interrupted initialization with a
        # registered child and only some/no native roots. Verify those recorded
        # roots; do not invent missing ones. A missing child remains unknown.
        if (not components <= {"agent", "server", "client"} or "agent" in components and len(components) != 1
                or launch is current and components != required):
            raise FenceRefused("native session exit is missing required native component registrations")
        if sorted(launch["native"], key=lambda item: item["component"]) != native.get(launch["launch_id"], []):
            raise FenceRefused("native session exit history disagrees with registered roots")
    if set(native) - seen:
        raise FenceRefused("native session exit has orphan native registrations")
    return launches


def _match_exit_registrations(proof, launches):
    """Compare ACKed observations to every exact registration before retiring it."""
    if (proof.get('launch_id') != launches[-1]['launch_id'] or proof.get('wrapper') != launches[-1]['wrapper']
            or type(proof.get('observed_at')) not in (int, float)
            or not math.isfinite(proof['observed_at']) or proof['observed_at'] <= 0
            or len(proof['launches']) != len(launches)):
        raise FenceRefused('acknowledged exit proof no longer matches launch registration')
    for observation, launch in zip(proof['launches'], launches):
        if not isinstance(observation, dict) or not isinstance(observation.get('roots'), list):
            raise FenceRefused('acknowledged exit proof has malformed observations')
        expected = {key: launch[key] for key in ('supervisor', 'child')}
        expected.update({item['component']: item['process'] for item in launch['native']})
        observed = {}
        for root in observation['roots']:
            if not isinstance(root, dict):
                raise FenceRefused('acknowledged exit proof has malformed roots')
            component = root['component']
            if component in observed or root.get('evidence') not in ('pid_absent', 'pid_reused', 'kernel_zombie'):
                raise FenceRefused('acknowledged exit proof has inconsistent root observations')
            observed[component] = _process_proof(dict(pid=root['pid'], birth=root['birth']))
            if root['evidence'] != 'pid_absent' and (not isinstance(root.get('observed_kernel_birth'), str) or not root['observed_kernel_birth']):
                raise FenceRefused('acknowledged exit proof lacks observed kernel identity')
            if root['evidence'] == 'kernel_zombie' and root.get('kernel_state') != 'Z':
                raise FenceRefused('acknowledged exit proof lacks zombie evidence')
        if observation['launch_id'] != launch['launch_id'] or observed != expected:
            raise FenceRefused('acknowledged exit proof does not cover the current registrations')


def _exited_session_root(proof):
    """Prove this registered root gone, using the launch-recovery predicate."""
    result = _session_root_exit_evidence(proof)
    if result is None:
        raise FenceRefused("registered native session root is still alive")
    return result


def prove_native_session_exit(snapshot, provider, *, conf_dir=None):
    """Return raw exit proof for an exactly stopped, registered native session.

    This is raw evidence, not a release/stop receipt; Control persists and
    submits it separately. It
    neither clears bindings/tombstones nor revokes plans, independent teammates,
    arbitrary development services or escaped descendants. A recovery wrapper
    may remain alive; the persisted stop continues to forbid its old execution.
    Missing/partial registrations (including stop-before-start), busy admission,
    corrupt state and unobservable processes raise FenceRefused, never success.

    Existing admission locks are acquired non-blockingly around two read-only
    snapshots. Process/kernel reads happen BETWEEN these short barriers. The
    final exact match ensures no registration was in flight or changed while
    it was observed. No files, schemas or locks are created, and no networking,
    signaling beyond kill(pid, 0), or runtime mutations occur. The result names
    its exact snapshot; it is not authorization for a later replacement start.
    """
    expected = _snapshot(snapshot)
    if not expected["cancel_request"] or provider not in ("claude", "codex"):
        raise FenceRefused("native session exit requires a stopped snapshot and known provider")
    root = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")).absolute()
    lock_path = root / "control/task-admission" / (expected["task_ref"] + ".lock")
    path = root / "control/state.sqlite3"

    def read():
        # Do not instantiate ExecutionFence: its constructor installs schemas
        # and directories. A missing lock is missing evidence, not a new lock.
        fd = os.open(lock_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise FenceRefused("native session admission lock is not a regular file")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with contextlib.closing(sqlite3.connect("file:" + quote(str(path), safe="/") + "?mode=ro",
                                                   uri=True, timeout=.05)) as db:
                db.row_factory = sqlite3.Row
                db.execute("BEGIN")
                return _session_exit_registrations(db, expected, provider)
        finally:
            os.close(fd)

    try:
        launches = read()
        observations = []
        for launch in launches:
            roots = [(key, launch[key]) for key in ("supervisor", "child")]
            roots.extend((item["component"], item["process"]) for item in launch["native"])
            observations.append(dict(launch_id=launch["launch_id"], roots=[
                dict(component=component, **_exited_session_root(process)) for component, process in roots]))
        if read() != launches:
            raise FenceRefused("native session registrations changed during exit observation")
        return dict(scope="native_session", snapshot=expected, provider=provider,
                    launch_id=launches[-1]["launch_id"], launches=observations,
                    wrapper=launches[-1]["wrapper"], observed_at=time.time())
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        if isinstance(exc, FenceRefused):
            raise
        raise FenceRefused("native session exit evidence is unavailable or inconsistent") from exc


def native_command(argv, component, env=None):
    """Prefix the actual native argv, inside any relay, priority or loop wrapper."""
    env = os.environ if env is None else env
    if not env.get("FLEET_TASK_EXECUTION"):
        return list(argv)
    return [sys.executable, str(Path(__file__).resolve()), "native", "--component", component, "--", *argv]


def native_exec(argv, component):
    """Final native boundary: consume the component slot, then exec under flock."""
    from fleet_native_proc import descendant
    expected = _snapshot(json.loads(os.environ["FLEET_TASK_EXECUTION"]))
    launch_id = _token(os.environ.get("FLEET_TASK_LAUNCH_ID", ""), "launch id")
    fence = ExecutionFence()
    refresh_session(expected["execution_owner"].split("/")[1], expected=expected)
    registered = fence.launch(expected["task_ref"])
    if (registered is None or registered["launch_id"] != launch_id
            or not _same_birth(registered["supervisor"])
            or not descendant(os.getpid(), registered["supervisor"]["pid"])):
        raise FenceRefused("native command has no live owning launch supervisor")
    proof = _kernel_process(os.getpid())
    environment = dict(os.environ)
    # The root's admission token must not enroll its native Subagents or tools.
    environment.pop("FLEET_TASK_EXECUTION", None)
    environment.pop("FLEET_TASK_LAUNCH_ID", None)
    with fence.admission(expected) as permit:
        permit.register_native(launch_id, component, proof)
        permit.assert_current()
        os.execvpe(argv[0], argv, environment)


def _signal_registered(fence, task_ref, launch_id, sig):
    try:
        registered = fence.launch(task_ref, timeout=.025)
    except (OSError, sqlite3.Error):
        return
    if registered is None or registered["launch_id"] != launch_id:
        return
    proofs = [item["process"] for item in registered["native"]]
    if registered["child"]:
        proofs.append(registered["child"])
    for proof in proofs:
        if _same_birth(proof):
            try:
                os.kill(proof["pid"], sig)
            except ProcessLookupError:
                pass


def terminate_registered(fence, task_ref, *, launch_id=None, abort=lambda: False):
    """One bounded cancel-before-signal path; still not a domain-exit proof."""
    try:
        registered = fence.launch(task_ref, timeout=.025)
    except (OSError, sqlite3.Error):
        return
    if registered is None or launch_id is not None and registered["launch_id"] != launch_id:
        return
    launch_id = registered["launch_id"]
    common_deadline = None
    if not abort():
        try:
            from fleet_native_stop import before_signal
            common_deadline = before_signal(fence, task_ref, launch_id, abort=abort)
        except ImportError:
            pass  # an old isolated wrapper fixture or partial install cannot hold stop
    _signal_registered(fence, task_ref, launch_id, signal.SIGTERM)
    deadline = time.monotonic() + 2
    if common_deadline is not None:
        deadline = min(deadline, common_deadline)
    proofs = [item["process"] for item in registered["native"]]
    if registered["child"]:
        proofs.append(registered["child"])
    while time.monotonic() < deadline and any(_same_birth(proof) for proof in proofs):
        if abort():
            break
        time.sleep(min(.025, max(0, deadline - time.monotonic())))
    _signal_registered(fence, task_ref, launch_id, signal.SIGKILL)


def supervise(expected, argv):
    """One controlled wrapper launch. Registration survives crashes and exit.

    The monitor stops its registered processes when stop commits. It does not
    prove that escaped descendants are gone, and never releases the binding.
    """
    expected = _snapshot(expected)
    fence = ExecutionFence()
    refresh_session(expected["execution_owner"].split("/")[1], expected=expected)
    launch_id = str(uuid.uuid4())
    supervisor = _kernel_process(os.getpid())
    wrapper = supervisor
    if os.environ.get("FLEET_SESSION_WRAP"):
        from fleet_native_proc import descendant
        wrapper_pid = int(os.environ["FLEET_SESSION_WRAP"])
        if not descendant(os.getpid(), wrapper_pid):
            raise FenceRefused("native supervisor is not owned by the supplied wrapper")
        wrapper = _kernel_process(wrapper_pid)
    environment = dict(os.environ, FLEET_TASK_EXECUTION=json.dumps(expected, separators=(",", ":")),
                       FLEET_TASK_LAUNCH_ID=launch_id)
    ended = []
    handlers = {}
    child = None
    try:
        for sig in (signal.SIGHUP, signal.SIGTERM):
            handlers[sig] = signal.signal(sig, lambda value, frame: ended.append(value))
        for sig in (signal.SIGINT, signal.SIGQUIT):
            handlers[sig] = signal.signal(sig, lambda value, frame: None)
        with fence.admission(expected) as permit:
            permit.reserve_launch(launch_id, supervisor, wrapper=wrapper)
            permit.assert_current()
            child = subprocess.Popen(argv, env=environment)
            permit.register_child(launch_id, _kernel_process(child.pid))
        while child.poll() is None:
            revoked = False
            try:
                fence._assert_current(expected, timeout=.025)
            except (FenceRefused, OSError, sqlite3.Error):
                revoked = True
            if ended or revoked:
                # Stop discovery (including sync) gets the same fixed opportunity
                # as Control. External HUP/TERM bypasses or interrupts it.
                terminate_registered(fence, expected["task_ref"], launch_id=launch_id,
                                     abort=lambda: bool(ended))
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=2)
                return 128 + (ended[0] if ended else signal.SIGTERM)
            time.sleep(.1)
        return child.returncode if child.returncode >= 0 else 128 - child.returncode
    finally:
        if child is not None and child.poll() is None:
            # Crash/unwind cannot start another cancellation opportunity.
            terminate_registered(fence, expected["task_ref"], launch_id=launch_id, abort=lambda: True)
            if child.poll() is None:
                child.kill()
            child.wait(timeout=2)
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check-session")
    check.add_argument("--session-fid", required=True)
    check.add_argument("--expected")
    check.add_argument("--controlled", action="store_true")
    refresh = commands.add_parser("refresh-session")
    refresh.add_argument("--session-fid", required=True)
    refresh.add_argument("--expected")
    refresh.add_argument("--controlled", action="store_true")
    commands.add_parser("sync-stops")
    history = commands.add_parser("check-history")
    history.add_argument("--task-ref", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--snapshot", required=True)
    prepare.add_argument("--fleet-id", required=True)
    prepare.add_argument("--continuation", default="")
    prepare.add_argument("--dispatch", default="")
    window = commands.add_parser("reserve-window")
    window.add_argument("--snapshot", required=True)
    run = commands.add_parser("run")
    run.add_argument("--snapshot", required=True)
    run.add_argument("argv", nargs=argparse.REMAINDER)
    native = commands.add_parser("native")
    native.add_argument("--component", required=True, choices=("agent", "server", "client"))
    native.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.command in ("check-session", "refresh-session"):
            action = refresh_session if args.command == "refresh-session" else check_session
            result = action(args.session_fid, expected=json.loads(args.expected) if args.expected else None,
                            controlled=args.controlled)
            print(json.dumps(result, separators=(",", ":")))
            return 0
        if args.command == "sync-stops":
            print(json.dumps(sync_stops(), separators=(",", ":")))
            return 0
        if args.command == "check-history":
            if read_task(args.task_ref) is not None:
                raise FenceRefused("controlled task history is review-only; explicit execution authorization is required")
            return 0
        if args.command == "prepare":
            expected = _snapshot(json.loads(args.snapshot), allow_unclaimed=True)
            continuation = None
            if args.continuation:
                from fleet_task_continuation import validate_continuation
                continuation = validate_continuation(json.loads(args.continuation))
            if expected["execution_owner"]:
                if expected["execution_owner"].split("/")[0] != args.fleet_id:
                    raise FenceRefused("execution is allocated to another fleet")
                expected = refresh_session(expected["execution_owner"].split("/")[1], expected=expected)
            elif continuation:
                if 'stop_operation_id' in continuation:
                    expected = continue_unclaimed_execution(expected, args.fleet_id, continuation, json.loads(args.dispatch))
                else:
                    expected = continue_execution(expected, args.fleet_id, continuation['exit_operation_id'])
            else:
                expected = claim_execution(expected, args.fleet_id)
            print(json.dumps(expected, separators=(",", ":")))
            return 0
        if args.command == "reserve-window":
            ExecutionFence().reserve_window(json.loads(args.snapshot))
            return 0
        argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        if not argv:
            raise FenceRefused("native launch needs an executable")
        if args.command == "native":
            native_exec(argv, args.component)
        return supervise(json.loads(args.snapshot), argv)
    except (FenceRefused, OSError, KeyError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print("fleet-task-execution: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
