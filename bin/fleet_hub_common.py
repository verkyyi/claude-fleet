"""Small, stdlib-only primitives shared by the Fleet Hub and its SSH bridge."""

import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import time
import uuid

PROTOCOL = 1
MAX_REQUEST = 65536
MAX_RESPONSE = 2 * 1024 * 1024
SCOPES = {"fleet:read", "worker:start", "worker:message", "worker:stop", "worker:resume", "config:write"}
# One scope per write action; a lifecycle tool is never reachable through worker:start.
SCOPE_OF = {"worker_start": "worker:start", "config_set": "config:write",
            "worker_message": "worker:message", "worker_stop": "worker:stop",
            "worker_resume": "worker:resume"}
WORKER_ACTIONS = ("worker_message", "worker_stop", "worker_resume")
MAX_MESSAGE = 4000
# Durable worker identity (issue #834): the fleet UUID plus the binding the fleet
# itself keys every ledger row on — the numeric @issue of a worker, or the
# scratch-<N> slug of an @raw scratch worktree. It survives /fleet-handoff (same
# window, new native session), an account migration (new window, @issue re-bound),
# renumber-windows and a tmux server restart. Window IDs and @wid handles do not.
WORKER_KEY_RE = r"(?:issue|scratch)-[1-9][0-9]{0,9}"
WORKER_ID_RE = re.compile(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(" + WORKER_KEY_RE + r")")
CONFIG_KEYS = {"FLEET_MAX_SESSIONS": (0, 256),
               "FLEET_AUTOFILL": (0, 1),
               "FLEET_AUTOFILL_MAX_PER_TICK": (1, 16)}


class Fault(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

    def as_dict(self):
        return {"code": self.code, "message": str(self)}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def identifier(value):
    try:
        if str(uuid.UUID(value)) == value:
            return value
    except (ValueError, TypeError, AttributeError):
        pass
    raise Fault("INVALID_ARGUMENT", "Expected a canonical UUID")


def parse_worker_id(value):
    """Return (fleet_id, key) for a canonical worker id, or raise."""
    match = isinstance(value, str) and WORKER_ID_RE.fullmatch(value)
    if not match:
        raise Fault("INVALID_ARGUMENT", "worker_id must be <fleet UUID>/issue-<N> or <fleet UUID>/scratch-<N>")
    return identifier(match.group(1)), match.group(2)


def worker_key(issue, scratch, worktree):
    """The durable key of one window: issue-<N>, scratch-<N> (strict: the worktree
    basename must end in scratch-<digits>, as fleet_scratch_key), or None."""
    if issue is not None:
        return "issue-%d" % issue
    if scratch:
        base = (worktree or "").rstrip("/").rsplit("/", 1)[-1]
        found = re.fullmatch(r"(?:.*-)?scratch-([1-9][0-9]{0,9})", base)
        if found:
            return "scratch-" + found.group(1)
    return None


def worker_identity(fleet_id, key):
    return fleet_id + "/" + key if key else None


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise Fault("INVALID_ARGUMENT", "Missing or unsupported request fields")


def name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value):
        raise Fault("INVALID_ARGUMENT", "Invalid name or SSH alias")
    return value


def validate_write(action, params):
    if action == "worker_start":
        fields(params, ("issue",), ("agent",))
        if type(params["issue"]) is not int or not 1 <= params["issue"] <= 2147483647:
            raise Fault("INVALID_ARGUMENT", "issue must be a positive integer")
        if params.get("agent", "") not in ("", "claude", "codex"):
            raise Fault("INVALID_ARGUMENT", "agent must be claude or codex")
    elif action in WORKER_ACTIONS:
        fields(params, ("worker_id",), ("text",) if action == "worker_message" else ())
        parse_worker_id(params["worker_id"])
        if action == "worker_message":
            text = params.get("text")
            if not isinstance(text, str) or not 1 <= len(text) <= MAX_MESSAGE or not text.strip():
                raise Fault("INVALID_ARGUMENT", "text must be 1-%d characters" % MAX_MESSAGE)
            if "<!--" in text or any(ord(c) < 32 and c not in "\n\t" for c in text):
                # A comment marker could forge the bridge's no-relay / provenance
                # rails; control bytes could drive the pane once pasted.
                raise Fault("INVALID_ARGUMENT", "text must not contain HTML comments or control characters")
    elif action == "config_set":
        fields(params, ("key", "value", "expected_revision"))
        key, value = params["key"], params["value"]
        if not isinstance(key, str) or key not in CONFIG_KEYS:
            raise Fault("FORBIDDEN", "Configuration key is not remotely writable")
        lo, hi = CONFIG_KEYS[key]
        if type(value) is not int or not lo <= value <= hi:
            raise Fault("INVALID_ARGUMENT", "Configuration value is outside its permitted range")
        if not isinstance(params["expected_revision"], str) or not re.fullmatch(r"[a-f0-9]{64}", params["expected_revision"]):
            raise Fault("INVALID_ARGUMENT", "expected_revision must come from config_get")
    else:
        raise Fault("INVALID_ARGUMENT", "Unsupported operation")


def private_dir(path):
    path = Path(path).absolute()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise Fault("INVALID_STATE", "State directory must not be a symlink")
    os.chmod(path, 0o700)
    return path


class Database:
    def __init__(self, root, schema):
        self.root = private_dir(root)
        self.path = self.root / "state.sqlite3"
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        os.chmod(self.path, 0o600)
        with self.connect() as db:
            db.executescript(schema)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(str(self.path), timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()


def run(argv, *, payload=None, env=None, timeout=20):
    """Never run a caller-supplied shell command. Kill only our process group."""
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
    except OSError as exc:
        raise Fault("UNAVAILABLE", "Cannot start control transport: " + str(exc)) from exc
    try:
        out, err = proc.communicate(payload, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        raise Fault("TIMEOUT", "Control operation timed out; query its operation ID before retrying") from exc
    if len(out) > MAX_RESPONSE:
        raise Fault("PROTOCOL_ERROR", "Control response is too large")
    return proc.returncode, out, err


def read_request(stream):
    raw = stream.read(MAX_REQUEST + 1)
    if len(raw) > MAX_REQUEST:
        raise Fault("INVALID_ARGUMENT", "Request is too large")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise Fault("INVALID_ARGUMENT", "Expected one JSON request") from exc
    if not isinstance(value, dict):
        raise Fault("INVALID_ARGUMENT", "Expected a JSON object")
    return value


def operation(row):
    return {"operation_id": row["id"], "fleet_id": row["fleet_id"],
            "action": row["action"], "status": row["status"],
            "created_at": row["created"], "updated_at": row["updated"],
            "result": json.loads(row["result"]) if row["result"] else None}


def now():
    return time.time()
