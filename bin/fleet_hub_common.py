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
import unicodedata
import uuid

PROTOCOL = 1
MAX_REQUEST = 65536
MAX_RESPONSE = 2 * 1024 * 1024
SCOPES = {"fleet:read", "worker:start", "worker:message", "worker:stop", "worker:resume", "worker:answer",
          "worker:reap", "config:write", "gh:read", "gh:comment"}
# One scope per write action; a lifecycle tool is never reachable through worker:start.
SCOPE_OF = {"worker_start": "worker:start", "config_set": "config:write",
            "worker_message": "worker:message", "worker_stop": "worker:stop",
            "worker_resume": "worker:resume", "worker_answer": "worker:answer",
            "worker_reap": "worker:reap", "gh_comment": "gh:comment"}
# The tools that name a WORKER (a worker_id), not a fleet. worker_answer and
# worker_reap (issue #1487, EPIC #1479 C8) are what a sidebar on another machine
# runs on a row here: answer the pane's open prompt (fleet-answer.sh /
# fleet-permission.sh) and reap the row (dash-reap.sh --yes).
WORKER_ACTIONS = ("worker_message", "worker_stop", "worker_resume", "worker_answer", "worker_reap")
# worker_answer's `answer` (issue #1487): `yes` / `no` for a permission prompt
# (fleet-permission.sh --allow / --deny), else the picks of an AskUserQuestion —
# one option number per question in order, `1,3` toggling several in a
# multiSelect (fleet-answer.sh --answer's grammar). Nothing else: each word
# becomes an argv word of a script that types into a pane.
ANSWER_RE = re.compile(r"yes|no|[1-9][0-9]{0,2}(?:,[1-9][0-9]{0,2}){0,15}(?: [1-9][0-9]{0,2}(?:,[1-9][0-9]{0,2}){0,15}){0,7}")
# GitHub reads through the fleet's local copy (issue #1274): tool → fleet-gh.sh
# kind. Synchronous like fleet_status; gated by gh:read, never by fleet:read alone.
GH_READS = {"gh_issue_view": "issue", "gh_pr_view": "pr", "gh_pr_checks": "checks"}
MAX_MESSAGE = 4000
# The tool dirs every control adapter must see, whatever started it (issue
# #1460). The SSH forced command (fleet_hub.REMOTE_COMMAND) exports exactly
# this PATH; the local `rpc` path — ccquota's agent reading fleet_status for its
# heartbeat under launchd, whose default PATH is /usr/bin:/bin:/usr/sbin:/sbin —
# completes the PATH it inherited with the same dirs (tool_path). Without that a
# Homebrew tmux was not found, fleet-control-read.sh died `tmux: command not
# found`, every fleet_status read UNAVAILABLE, and the hub showed 0 sessions on
# a machine running 22. Same dirs the daemon plists carry (launchd/*.plist.tmpl).
TOOL_DIRS = ("$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")


def tool_path(inherited, home=None):
    """`inherited` PATH with every TOOL_DIRS entry present. The missing ones are
    prepended in TOOL_DIRS order; the ones already there keep their place, so a
    whole PATH comes back unchanged and launchd's default becomes the forced
    command's. $HOME/.local/bin is skipped when no home is known."""
    have = [d for d in (inherited or "").split(os.pathsep) if d]
    want = []
    for d in TOOL_DIRS:
        if d.startswith("$HOME"):
            if not home:
                continue
            d = home.rstrip("/") + d[len("$HOME"):]
        want.append(d)
    return os.pathsep.join([d for d in want if d not in have] + have)
REPO_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}(/[A-Za-z0-9_.-]{1,100})?")
GH_FIELDS_RE = re.compile(r"[A-Za-z]{1,40}(,[A-Za-z]{1,40}){0,29}")
# Durable worker identity (issue #834): the fleet UUID plus the binding the fleet
# itself keys every ledger row on — the numeric @issue of a worker, or the
# scratch-<N> slug of an @raw scratch worktree. It survives /fleet-handoff (same
# window, new native session), an account migration (new window, @issue re-bound),
# renumber-windows and a tmux server restart. Window IDs and @wid handles do not.
# A multi-repo fleet prefixes the window's repo slug (issue #1018, the #789
# spelling): two hosted repos can both have an issue-12. A one-repo fleet's keys
# stay bare.
WORKER_KEY_RE = r"(?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(?:issue|scratch)-[1-9][0-9]{0,9}"
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
        raise Fault("INVALID_ARGUMENT", "worker_id must be <fleet UUID>/[<repo>:]issue-<N> or <fleet UUID>/[<repo>:]scratch-<N>")
    return identifier(match.group(1)), match.group(2)


def repo_slug(repo):
    """fleet_slug: owner/name → owner-name, anything outside [A-Za-z0-9._-] dropped."""
    return re.sub(r"[^A-Za-z0-9._-]", "", repo.replace("/", "-"))


def repo_named(repo, want):
    """fleet_repo_for_slug's match rule: owner/name, its slug, or the bare name."""
    return bool(repo) and want in (repo, repo_slug(repo), repo.split("/", 1)[-1])


def worker_key(issue, scratch, worktree, repo=""):
    """The durable key of one window: issue-<N>, scratch-<N> (strict: the worktree
    basename must end in scratch-<digits>, as fleet_scratch_key), or None. `repo`
    is the adapter's column 9 (issue #1018): empty in a one-repo fleet (the key
    stays bare), the window's owner/name in a multi-repo one (the key becomes
    <slug>:issue-<N>), `?` when that repo is unknown — None, never a guess."""
    key = None
    if issue is not None:
        key = "issue-%d" % issue
    elif scratch:
        base = (worktree or "").rstrip("/").rsplit("/", 1)[-1]
        found = re.fullmatch(r"(?:.*-)?scratch-([1-9][0-9]{0,9})", base)
        if found:
            key = "scratch-" + found.group(1)
    if key and repo:
        slug = repo_slug(repo) if repo != "?" else ""
        key = slug + ":" + key if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", slug) else None
    return key


def worker_identity(fleet_id, key):
    return fleet_id + "/" + key if key else None


def fields(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise Fault("INVALID_ARGUMENT", "Missing or unsupported request fields")


def name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value):
        raise Fault("INVALID_ARGUMENT", "Invalid name or SSH alias")
    return value


def check_number(value, what="issue"):
    if type(value) is not int or not 1 <= value <= 2147483647:
        raise Fault("INVALID_ARGUMENT", what + " must be a positive integer")


def check_repo(params):
    # Which hosted repo (issue #984): owner/name, slug or bare name — resolved
    # against the fleet's repos on the machine, never a path.
    repo = params.get("repo", "")
    if not isinstance(repo, str) or repo and not REPO_RE.fullmatch(repo):
        raise Fault("INVALID_ARGUMENT", "repo must be owner/name or a hosted repo's name")


def check_text(text, what="text"):
    if not isinstance(text, str) or not 1 <= len(text) <= MAX_MESSAGE or not text.strip():
        raise Fault("INVALID_ARGUMENT", "%s must be 1-%d characters" % (what, MAX_MESSAGE))
    if "<!--" in text or any(ord(c) < 32 and c not in "\n\t" for c in text):
        # A comment marker could forge the bridge's no-relay / provenance
        # rails; control bytes could drive the pane once pasted.
        raise Fault("INVALID_ARGUMENT", what + " must not contain HTML comments or control characters")


MAX_SCRATCH_NAME = 64


def check_scratch_name(value):
    """A scratch start's optional name (issue #1541): None / blank is no name;
    otherwise ≤ 64 characters, no control characters, no `#` (tmux's format
    character) — the opener clips it again. The hub's checkScratchName."""
    if value is None:
        return
    if not isinstance(value, str):
        raise Fault("INVALID_ARGUMENT", "name must be a string")
    text = value.strip()
    if not text:
        return
    if len(text) > MAX_SCRATCH_NAME:
        raise Fault("INVALID_ARGUMENT", "name must be at most %d characters" % MAX_SCRATCH_NAME)
    if any(ord(c) < 32 or ord(c) == 127 or c == "#" for c in text):
        raise Fault("INVALID_ARGUMENT", "name must not contain control characters or #")


def check_answer(value):
    if not isinstance(value, str) or not ANSWER_RE.fullmatch(value):
        raise Fault("INVALID_ARGUMENT", "answer must be yes, no, or option numbers (`2`, `1,3`, one per question)")


def validate_gh_read(params):
    fields(params, ("fleet_id", "number"), ("repo", "fields"))
    check_number(params["number"], "number")
    check_repo(params)
    wanted = params.get("fields", "")
    if not isinstance(wanted, str) or wanted and not GH_FIELDS_RE.fullmatch(wanted):
        raise Fault("INVALID_ARGUMENT", "fields must be comma-separated gh --json field names")


def validate_write(action, params):
    if action == "worker_start":
        fields(params, (), ("issue", "kind", "name", "agent", "repo", "origin_wid", "account_class"))
        # kind (issue #1541): "issue" (the default — a worker on an issue, `issue`
        # required) or "scratch" (a raw scratch session: no issue, an optional
        # name — dash-raw-session.sh opens it). Held to the hub's own rule
        # (tokenledger/internal/api/fleet_write.go), letter for letter.
        kind = params.get("kind", "issue")
        if kind == "scratch":
            if "issue" in params:
                raise Fault("INVALID_ARGUMENT", "a scratch start has no issue")
            check_scratch_name(params.get("name"))
        elif kind == "issue":
            if "issue" not in params or "name" in params:
                raise Fault("INVALID_ARGUMENT", "Missing or unsupported request fields")
            check_number(params["issue"])
        else:
            raise Fault("INVALID_ARGUMENT", "kind must be issue or scratch")
        if params.get("agent", "") not in ("", "claude", "codex"):
            raise Fault("INVALID_ARGUMENT", "agent must be claude or codex")
        check_repo(params)
        if "origin_wid" in params:
            # The parent on another machine (issue #1425): a worker_id, never
            # free text — it becomes an argv word and a window option.
            parse_worker_id(params["origin_wid"])
        # The asker's account class (issue #1540): which kind of subscription the
        # session runs on — one of three words, never free text (an argv word and
        # a window option on the machine that opens it).
        if params.get("account_class", "") not in ("", "any", "local", "pool"):
            raise Fault("INVALID_ARGUMENT", "account_class must be local, pool or any")
    elif action == "worker_move_in":
        validate_move_in(params)
    elif action == "gh_comment":
        fields(params, ("issue", "body"), ("repo",))
        check_number(params["issue"])
        check_repo(params)
        check_text(params["body"], "body")
    elif action in WORKER_ACTIONS:
        if action == "worker_answer":
            fields(params, ("worker_id", "answer"))
        else:
            fields(params, ("worker_id",), ("text",) if action == "worker_message" else ())
        parse_worker_id(params["worker_id"])
        if action == "worker_message":
            check_text(params.get("text"))
        if action == "worker_answer":
            check_answer(params["answer"])
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


# worker_move_in (issue #1426): a session moved here through the hub. Every
# value becomes an argv word of fleet-move-remote.sh movein (or a tmux window
# option), never shell input — and each is held to the hub's own rule
# (tokenledger/internal/api/fleet_move.go parseMoveIn), letter for letter.
MOVE_RES = {
    "move_id": re.compile(r"[0-9a-f]{32}"),
    "worker_key": re.compile(WORKER_KEY_RE),
    "branch": re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}"),
    "sid": re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"),
    "state": re.compile(r"[a-z]{1,16}"),
    "origin": re.compile(r"[A-Za-z0-9][A-Za-z0-9._:#/-]{0,255}"),
    "handle": re.compile(r"[a-z][1-9]"),
    "from_node": re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"),
}


def validate_move_in(params):
    fields(params, ("move_id", "worker_key", "repo", "branch", "sid", "name"),
           ("pushed", "raw", "state", "issue", "origin", "origin_wid", "handle", "from_node"))
    for key, rx in MOVE_RES.items():
        if key in params and (not isinstance(params[key], str) or not rx.fullmatch(params[key])):
            raise Fault("INVALID_ARGUMENT", key + " is not valid")
    branch = params["branch"]
    if ".." in branch or branch.endswith(".lock") or branch.endswith("/"):
        raise Fault("INVALID_ARGUMENT", "branch is not valid")
    if params.get("state") == "working":
        raise Fault("INVALID_STATE", "a working session is never moved; wait until it is idle")
    if not params["repo"]:
        raise Fault("INVALID_ARGUMENT", "repo must be owner/name")
    check_repo(params)
    label = params["name"]
    if not isinstance(label, str) or not 1 <= len(label) <= 80 or any(unicodedata.category(c) == "Cc" for c in label):
        raise Fault("INVALID_ARGUMENT", "name must be 1-80 printable characters")
    if "pushed" in params and type(params["pushed"]) is not bool:
        raise Fault("INVALID_ARGUMENT", "pushed must be true or false")
    if "raw" in params and (type(params["raw"]) is not int or params["raw"] not in (0, 1)):
        raise Fault("INVALID_ARGUMENT", "raw must be 0 or 1")
    if "issue" in params:
        check_number(params["issue"])
    if "origin_wid" in params:
        parse_worker_id(params["origin_wid"])


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
