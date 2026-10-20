#!/usr/bin/env python3
"""Versioned launch proof. Intent, process observation and task outcome are distinct.

The existing operation journal owns dispatch; tmux carries its launch binding.
No retry queue, process discovery by label, or task database lives here.
"""
import argparse
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

IDENTITY = ("version", "operation_id", "task", "owner", "generation", "worker_id", "provider", "attempt_id")
BIN = Path(__file__).resolve().parent


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def validate_context(c):
    if not isinstance(c, dict) or set(c) != set(IDENTITY) or type(c.get("version")) is not int or c["version"] != 1:
        raise ValueError("unsupported launch contract")
    if any(not isinstance(c[k], str) for k in IDENTITY if k not in ("version", "generation")):
        raise ValueError("invalid launch field types")
    if (not valid_uuid(c["operation_id"]) or not re.fullmatch(r"T[1-9][0-9]*", c["task"])
            or type(c["generation"]) is not int or c["generation"] < 1
            or c["attempt_id"] != "task:%s:g%d" % (c["task"], c["generation"])
            or not isinstance(c["owner"], str) or not c["owner"] or len(c["owner"]) > 200
            or c["provider"] not in ("claude", "codex")
            or len(c["worker_id"].split("/")) != 2
            or not all(valid_uuid(x) for x in c["worker_id"].split("/"))):
        raise ValueError("invalid launch identity")
    return c


def check_receipt(context, receipt):
    validate_context(context)
    if not isinstance(receipt, dict) or any(receipt.get(k) != context[k] for k in IDENTITY):
        raise ValueError("launch receipt belongs to another operation/owner/generation")
    if (receipt.get("actual_provider") != context["provider"]
            or not valid_uuid(receipt.get("native_session"))
            or type(receipt.get("pid")) is not int or receipt["pid"] <= 0
            or not isinstance(receipt.get("birth"), str) or not receipt["birth"]
            or not isinstance(receipt.get("executable"), str) or not os.path.isabs(receipt["executable"])):
        raise ValueError("launch has no matching native process/session proof")
    if "worktree" in receipt:
        validate_worktree(receipt["worktree"])
    if "native_worktree" in receipt:
        intent = validate_native_worktree(receipt["native_worktree"])
        if (receipt["actual_provider"] != "claude" or "worktree" not in receipt
                or receipt["worktree"]["root"] != str(native_worktree_path(intent))
                or receipt["worktree"]["common_dir"] != intent["common_dir"]):
            raise ValueError("native worktree receipt differs from its creation intent")
    return receipt


def validate_worktree(binding):
    if (not isinstance(binding, dict) or set(binding) != {"root", "git_dir", "common_dir"}
            or any(not isinstance(value, str) or not os.path.isabs(value)
                   or any(character in value for character in "\n\r\0") for value in binding.values())):
        raise ValueError("invalid worktree binding")
    return binding


def worktree_identity(directory):
    if not isinstance(directory, str) or not os.path.isabs(directory):
        raise ValueError("native cwd must be an absolute worktree path")
    cwd = Path(directory).resolve(strict=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    result = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--path-format=absolute",
                             "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
                            env=environment, capture_output=True, text=True, check=True, timeout=2)
    root, metadata, common = [Path(value).resolve(strict=True) for value in result.stdout.splitlines()]
    marker = root / ".git"
    if (not cwd.is_relative_to(root) or metadata.parent != common / "worktrees"
            or not marker.is_file() or marker.is_symlink()
            or (metadata / (metadata / "gitdir").read_text().strip()).resolve(strict=True) != marker):
        raise ValueError("native cwd is not a registered linked worktree")
    return validate_worktree(dict(root=str(root), git_dir=str(metadata), common_dir=str(common)))


def native_git(root, *arguments):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    return subprocess.run(["git", "-C", root, *arguments], env=environment, capture_output=True,
                          text=True, check=True, timeout=5).stdout.strip()


def validate_native_worktree(intent):
    if (not isinstance(intent, dict) or set(intent) != {"root", "common_dir", "base", "commit", "name"}
            or any(not isinstance(value, str) or not value or any(character in value for character in "\n\r\t\0")
                   for value in intent.values())
            or not all(os.path.isabs(intent[key]) for key in ("root", "common_dir"))
            or not re.fullmatch(r"scratch-[1-9][0-9]{0,14}", intent["name"])
            or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", intent["commit"])
            or not intent["base"].startswith("refs/")):
        raise ValueError("invalid native worktree intent")
    return intent


def native_worktree_path(intent):
    return Path(intent["root"]) / ".claude" / "worktrees" / intent["name"]


def check_native_repository(intent):
    validate_native_worktree(intent)
    root = Path(intent["root"])
    values = native_git(str(root), "rev-parse", "--path-format=absolute", "--show-toplevel",
                        "--absolute-git-dir", "--git-common-dir").splitlines()
    if (root.resolve(strict=True) != root or len(values) != 3 or values !=
            [str(root), intent["common_dir"], intent["common_dir"]]
            or Path(intent["common_dir"]).resolve(strict=True) != root / ".git"
            or not (root / ".git").is_dir()):
        raise ValueError("native creation repository identity changed")
    for directory in (root / ".claude", root / ".claude/worktrees", native_worktree_path(intent)):
        if directory.is_symlink():
            raise ValueError("native worktree location cannot follow a symlink")


def new_native_worktree(root, base):
    root = str(Path(root).resolve(strict=True))
    remote = native_git(root, "remote").splitlines()
    reference = "refs/remotes/origin/" + base if "origin" in remote else "refs/heads/" + base
    commit = native_git(root, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}")
    intent = dict(root=root, common_dir=str(Path(root) / ".git"), base=reference, commit=commit,
                  name="scratch-" + str(1 + int(uuid.uuid4().hex[:12], 16)))
    check_native_repository(intent)
    return intent


def prepare_native_worktree(pane, provider, worktree, previous=None):
    raw = option(pane, "@native_worktree")
    if not raw:
        if previous and "native_worktree" in previous:
            raise ValueError("native creation intent disappeared")
        return None
    intent = validate_native_worktree(json.loads(raw))
    if provider != "claude":
        raise ValueError("native worktree creation requires Claude")
    check_native_repository(intent)
    path = native_worktree_path(intent)
    if previous:
        if (previous.get("native_worktree") != intent or not worktree
                or worktree["root"] != str(path) or worktree["common_dir"] != intent["common_dir"]):
            raise ValueError("native worktree recovery lost its saved binding")
    else:
        if worktree or path.exists() or native_git(intent["root"], "branch", "--list", "worktree-" + intent["name"]):
            raise ValueError("native creation cannot adopt a pre-existing worktree or branch")
        if native_git(intent["root"], "rev-parse", "--verify", "--end-of-options",
                      intent["base"] + "^{commit}") != intent["commit"]:
            raise ValueError("native creation base changed before launch")
    return intent


def observe_native_worktree(pane, payload, intent, expected=None):
    if json.loads(option(pane, "@native_worktree")) != validate_native_worktree(intent):
        raise ValueError("native creation intent changed")
    check_native_repository(intent)
    observed = worktree_identity(payload.get("cwd"))
    if (observed["root"] != str(native_worktree_path(intent))
            or observed["common_dir"] != intent["common_dir"]):
        raise ValueError("native creator entered another worktree or repository")
    if expected:
        if observed != expected:
            raise ValueError("native recovery changed worktree identity")
        check_worktree_window(pane, expected)
    else:
        if option(pane, "@worktree") not in ("", observed["root"]):
            raise ValueError("native creation window already names another worktree")
        if native_git(observed["root"], "rev-parse", "HEAD") != intent["commit"]:
            raise ValueError("native creator used a different base commit")
    return observed


def restore_native_worktree(context, receipt, directory, session, provider, fleet_id):
    if not isinstance(receipt, dict) or "native_worktree" not in receipt:
        return None
    check_receipt(context, receipt)
    if (directory != receipt["worktree"]["root"] or session != receipt["native_session"]
            or provider != context["provider"] or fleet_id != context["worker_id"].split("/")[1]):
        raise ValueError("restore row differs from its native launch receipt")
    intent = receipt["native_worktree"]
    check_native_repository(intent)
    if worktree_identity(directory) != receipt["worktree"]:
        raise ValueError("restored native worktree lost its saved Git binding")
    return intent


def prepare_worktree(pane, previous=None, socket=""):
    path = option(pane, "@worktree", socket)
    expected = (previous or {}).get("worktree")
    if not path:
        if expected is not None:
            raise ValueError("saved worktree binding disappeared")
        return None
    observed = worktree_identity(path)
    if Path(path).resolve(strict=True) != Path(observed["root"]):
        raise ValueError("window worktree must name its registered root")
    if expected is not None and validate_worktree(expected) != observed:
        raise ValueError("saved worktree identity changed")
    return observed


def check_worktree_window(pane, expected, socket=""):
    path = option(pane, "@worktree", socket)
    if not path or Path(path).resolve(strict=True) != Path(expected["root"]):
        raise ValueError("window worktree binding changed")


def bind_native_worktree(payload, expected):
    validate_worktree(expected)
    if worktree_identity(payload.get("cwd")) != expected:
        raise ValueError("native cwd differs from the bound worktree")
    return expected


def tmux(*args, socket=""):
    cmd = ["tmux"] + (["-S" if os.path.isabs(socket) else "-L", socket] if socket else [])
    return subprocess.run(cmd + list(args), capture_output=True, text=True, check=True, timeout=5).stdout.strip()


def option(pane, key, socket=""):
    return tmux("display-message", "-p", "-t", pane, "#{" + key + "}", socket=socket)


def stamp(pane, key, value):
    tmux("set-option", "-w", "-t", pane, key, json.dumps(value, separators=(",", ":")))


def process(pid, *, ps_row=None):
    """Kernel executable + birth. ps_row reuses one observation's ppid/lstart.

    The optional row never substitutes for the kernel birth/executable read.
    Callers must discard it after that observation; the default C3 path is
    unchanged. No process or task observation is cached here.
    """
    row = list(ps_row) if ps_row is not None else subprocess.run(
        ["ps", "-p", str(pid), "-o", "ppid=,lstart="],
        capture_output=True, text=True, check=True, timeout=3).stdout.strip().split(None, 1)
    if len(row) != 2:
        raise ValueError("native process disappeared")
    if sys.platform == "darwin":
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(int(pid), buf, len(buf)) <= 0:
            raise ValueError("native executable unavailable")
        executable = os.fsdecode(buf.value)
        # proc_bsdinfo carries microsecond birth time; ps lstart alone permits
        # a reused PID from the same second to impersonate a stopped native.
        class BSDInfo(ctypes.Structure):
            _fields_ = [("ids", ctypes.c_uint32 * 12), ("comm", ctypes.c_char * 16),
                        ("name", ctypes.c_char * 32), ("info", ctypes.c_uint32 * 6),
                        ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
        info = BSDInfo()
        if lib.proc_pidinfo(int(pid), 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            raise ValueError("native process birth unavailable")
        row[1] += ":%d:%d" % (info.start_sec, info.start_usec)
        kernel_parent, started = info.ids[4], info.start_sec
    else:
        executable = os.readlink("/proc/%d/exe" % pid)
        # Linux start ticks distinguish PID reuse within the same second.
        fields = Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()
        row[1] += ":" + fields[19]
        if ps_row is not None:
            boot = next(int(line.split()[1]) for line in Path('/proc/stat').read_text().splitlines()
                        if line.startswith('btime '))
            kernel_parent, started = int(fields[1]), boot + int(fields[19]) // os.sysconf('SC_CLK_TCK')
    if ps_row is not None:
        # A PID can exit/recycle between ps and the kernel read. Never attach a
        # fresh birth to stale comm/parent data and call it the earlier process.
        if (kernel_parent != int(row[0]) or ' '.join(time.ctime(started).split()) !=
                ' '.join(ps_row[1].split())):
            raise ValueError('process changed during observation')
    return dict(pid=int(pid), ppid=int(row[0]), birth=row[1], executable=executable)


def same_executable(a, b):
    """One executable FILE, whatever name the kernel gives it (T524).

    A release hard-links one binary under several names (tools/claude/<sha>/claude,
    every <sha>/.release/artifacts/claude-<ver>-<os>-<arch>), and macOS
    proc_pidpath answers whichever name the vnode cache last saw — so reading an
    artifact during a version switch renames every running Claude. The identity
    is the inode: the same path, or two paths naming the same file."""
    if not isinstance(a, str) or not isinstance(b, str):
        return False
    if a == b:
        return True
    try:
        return os.path.isabs(a) and os.path.isabs(b) and os.path.samefile(a, b)
    except OSError:
        return False


def same_identity(a, b):
    """pid + birth + executable of two kernel observations name one process."""
    try:
        return (a["pid"] == b["pid"] and a["birth"] == b["birth"]
                and same_executable(a["executable"], b["executable"]))
    except (KeyError, TypeError):
        return False


def identity_diff(receipt):
    """Which of pid / birth / executable no longer matches — for the failure line."""
    try:
        current = process(receipt["pid"])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return "pid %s is gone" % receipt.get("pid")
    if current["birth"] != receipt["birth"]:
        return "pid %d birth differs" % receipt["pid"]
    if not same_executable(current["executable"], receipt["executable"]):
        return "executable %s, receipt %s" % (current["executable"], receipt["executable"])
    return "matches"


def same_process(receipt):
    try:
        return same_identity(process(receipt["pid"]), receipt)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return False


def descendant(pid, parent):
    for _ in range(24):
        if pid == parent:
            return True
        if pid <= 1:
            break
        try:
            pid = process(pid)["ppid"]
        except (OSError, ValueError, subprocess.SubprocessError):
            break
    return False


def native_tool(path):
    """claude | codex | '' — the provider a binary's NAME says it is.

    Besides `claude` / `codex` and Claude's numeric version files, a release's
    artifact name (`claude-2.1.295-darwin-arm64`, `codex-0.162.1-darwin-arm64`)
    is the same binary under a hard link (T524: macOS may report that name)."""
    base = Path(path).name
    m = re.fullmatch(r"(claude|codex)(?:-\d+\.\d+\.\d+(?:-[A-Za-z0-9_]+)*)?", base)
    if m:
        return m.group(1)
    return "claude" if re.fullmatch(r"\d+\.\d+\.\d+", base) else ""


def native_name(path):
    return bool(native_tool(path))


def root_native(p, supervisor):
    pid = p["ppid"]
    for _ in range(24):
        if pid == supervisor:
            return True
        if pid <= 1:
            return False
        ancestor = process(pid)
        if native_name(ancestor["executable"]):
            return False  # nested helper/subagent, never the root launch
        pid = ancestor["ppid"]
    return False


def native_provider(p):
    """The provider a native process says it is, by its own version probe."""
    # Managed Claude binaries use a numeric version basename. Do not run
    # arbitrary ancestor shells/interpreters as provider probes.
    if not native_name(p["executable"]):
        return ""
    v = subprocess.run([p["executable"], "--version"], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=5)
    version = v.stdout.strip()
    actual = "codex" if re.fullmatch(r"codex-cli \S+", version) else (
        "claude" if re.fullmatch(r"\S+ \(Claude Code\)", version) else "")
    return actual if v.returncode == 0 else ""


def native_parent():
    """The hook's native ancestor. Only its version probe sees an empty request."""
    pid = os.getppid()
    for _ in range(12):
        p = process(pid)
        actual = native_provider(p)
        if actual:
            return dict(p, actual_provider=actual)
        pid = p["ppid"]
        if pid <= 1:
            break
    raise ValueError("no verified native provider in hook ancestry")


def launch_log(line):
    """One line in $FLEET_CONF_DIR/logs/launch.log: why a launch proof failed (T524)."""
    try:
        conf = os.environ.get("FLEET_CONF_DIR") or str(Path.home() / ".config/claude-fleet")
        path = Path(conf) / "logs" / "launch.log"
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as out:
            out.write("%s pane=%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                           os.environ.get("TMUX_PANE", "-"), line.replace("\n", " ")))
    except OSError:
        pass


def hook(payload):
    raw = os.environ.get("FLEET_LAUNCH_CONTEXT", "")
    if not raw or payload.get("hook_event_name") != "SessionStart":
        return
    try:
        record(validate_context(json.loads(raw)), native_parent(), payload)
    except Exception as e:
        # The hook's caller swallows a failure (telemetry never fails a turn), so
        # the supervisor would only see «no receipt»: say why, on the window and
        # in the log (T522 refused silently).
        why = "%s: %s" % (type(e).__name__, e)
        launch_log("hook refused: " + why)
        try:
            tmux("set-option", "-w", "-t", os.environ["TMUX_PANE"], "@launch_hook_error", why[:300])
        except (OSError, KeyError, subprocess.SubprocessError):
            pass
        raise


def witness_codex(server_pid, payload, remote):
    """The Codex receipt without a turn (T485). Codex 0.162's app-server runs
    SessionStart only when the first turn starts, and an accepted launch holds
    that turn until a receipt exists — so the private runtime, which owns the
    server, witnesses it instead: the PID the kernel names as its socket's peer,
    the thread that server has loaded. Same checks as the hook from there on."""
    raw = os.environ.get("FLEET_LAUNCH_CONTEXT", "")
    if not raw:
        return
    p = process(server_pid)
    if native_provider(p) != "codex":
        raise ValueError("app-server peer is not a verified Codex")
    record(validate_context(json.loads(raw)), dict(p, actual_provider="codex"), payload, remote)


def record(c, p, payload, remote=None):
    pane = os.environ["TMUX_PANE"]
    if json.loads(option(pane, "@launch")) != c:
        raise ValueError("launch binding changed")
    supervisor = int(os.environ["FLEET_LAUNCH_SUPERVISOR"])
    if not root_native(p, supervisor):
        raise ValueError("native process is outside this launch")
    receipt = dict(c, **p, native_session=payload.get("session_id"), observed_at=time.time(), phase="verified")
    old = option(pane, "@launch_receipt")
    previous = check_receipt(c, json.loads(old)) if old else None
    worktree = os.environ.get("FLEET_LAUNCH_WORKTREE")
    native_worktree = os.environ.get("FLEET_LAUNCH_CREATE")
    if native_worktree:
        if p["actual_provider"] != "claude":
            raise ValueError("native worktree creator is not Claude")
        intent = validate_native_worktree(json.loads(native_worktree))
        expected_worktree = json.loads(worktree) if worktree else (previous or {}).get("worktree")
        receipt["worktree"] = observe_native_worktree(pane, payload, intent, expected_worktree)
        receipt["native_worktree"] = intent
    elif worktree:
        receipt["worktree"] = bind_native_worktree(payload, json.loads(worktree))
        check_worktree_window(pane, receipt["worktree"])
    if p["actual_provider"] == "codex":
        receipt.update(native_remote=os.environ.get("FLEET_CODEX_REMOTE", "") if remote is None else remote,
                       native_home=os.environ.get("CODEX_HOME", ""))
    # Preserve an old native identity on resume. Missing identity never starts
    # a fresh session under an existing accepted operation.
    expected = os.environ.get("FLEET_LAUNCH_NATIVE", "")
    if expected and expected != receipt["native_session"]:
        raise ValueError("resume changed native session identity")
    check_receipt(c, receipt)
    if previous:
        if previous["native_session"] != receipt["native_session"] or not same_identity(previous, receipt):
            raise ValueError("late or nested hook cannot replace launch identity")
        if "worktree" in previous and previous["worktree"] != receipt.get("worktree"):
            raise ValueError("late hook cannot replace worktree identity")
        if "native_worktree" in previous and previous["native_worktree"] != receipt.get("native_worktree"):
            raise ValueError("late hook cannot replace native creation intent")
        return
    if native_worktree:
        tmux("set-option", "-w", "-t", pane, "@worktree", receipt["worktree"]["root"])
    stamp(pane, "@launch_receipt", receipt)


def inspect(context, pane, socket=""):
    c = validate_context(context)
    if json.loads(option(pane, "@launch", socket)) != c:
        raise ValueError("window no longer holds this launch")
    receipt = check_receipt(c, json.loads(option(pane, "@launch_receipt", socket)))
    if option(pane, "@fleet_id", socket) != c["worker_id"].split("/")[1]:
        raise ValueError("interrupted: native process identity was lost (window @fleet_id differs)")
    if not same_process(receipt):
        raise ValueError("interrupted: native process identity was lost (" + identity_diff(receipt) + ")")
    if not descendant(receipt["pid"], int(option(pane, "pane_pid", socket))):
        raise ValueError("interrupted: native process no longer belongs to this pane")
    if "worktree" in receipt:
        prepare_worktree(pane, receipt, socket)
    if "native_worktree" in receipt and json.loads(option(pane, "@native_worktree", socket)) != receipt["native_worktree"]:
        raise ValueError("native creation intent changed after observation")
    return dict(receipt, window_id=option(pane, "window_id", socket))


def task_call(context, mutation=None):
    cmd = ["bash", str(BIN / "fleet-task-record.sh"), "mutate" if mutation else "get", context["task"]]
    payload = json.dumps(mutation) if mutation else None
    r = subprocess.run(cmd, input=payload, text=True, capture_output=True, timeout=15)
    if r.returncode:
        if "ID_SWITCH" in r.stderr:
            raise IDSwitched("the hub reads sessions by ID now (EPIC T497 C6)")
        raise ValueError("task authority unavailable/refused; no input or replacement authorized")
    data = json.loads(r.stdout)
    return data.get("task", data)


def current_task(c):
    t = task_call(c)
    if any(t.get(k) != v for k, v in (("owner", c["owner"]), ("generation", c["generation"]),
           ("execution_owner", c["worker_id"]), ("resolved_agent", c["provider"]))):
        raise ValueError("task owner/generation/provider fence changed")
    if t.get("outcome"):
        raise ValueError("task generation is terminal")
    return t


class IDSwitched(ValueError):
    """The hub's ID switch is on (EPIC T497 C6): nothing claims a task record."""


def id_switch_on():
    try:
        import fleet_id
        return fleet_id.switch_on()
    except ImportError:
        return False


def local_launch(d, fleet_uuid):
    """An accepted task that opens on THIS machine (issue #4754).

    The hub binds a remote start in claimLaunch; a local one (placement LOCAL,
    or a scratch that is never placed) gets the same binding here: the operation
    and the session identity are one fresh UUID, as the hub's are, and the hub's
    own fenced claim makes this worker the task's owner before any window opens.
    No claim, no binding: never a start without the authority's word.
    """
    if not d.get("task"):
        return None
    if id_switch_on():
        return None   # EPIC T497 C6: the window opens with its ID and @task, no claim
    if not valid_uuid(fleet_uuid):
        raise ValueError("local accepted launch needs this fleet's UUID")
    t = task_call({"task": d["task"]})
    if (t.get("authority_version") != 1 or t.get("generation") != d.get("generation")
            or t.get("attempt_id") != d.get("attempt_id") or t.get("resolved_agent") != d.get("resolved_agent")
            or t.get("state") != "accepted" or t.get("execution_owner") or t.get("outcome")):
        raise ValueError("accepted task is not open for a local launch")
    op = str(uuid.uuid4())
    c = validate_context(dict(version=1, operation_id=op, task=d["task"], owner=t.get("owner"),
                              generation=d["generation"], worker_id=fleet_uuid + "/" + op,
                              provider=d["resolved_agent"], attempt_id=d["attempt_id"]))
    try:
        t = task_call(c, dict(kind="claim", idempotency_key="launch-claim:" + op,
                              generation=c["generation"], worker_id=c["worker_id"]))
    except IDSwitched:
        return None   # the hub said so before this node heard it: open unclaimed
    if t.get("generation") != c["generation"] or t.get("execution_owner") != c["worker_id"]:
        raise ValueError("task claim did not make this launch its owner")
    return c


class NotBound(ValueError):
    """rebind: the record holds no live binding for this native session."""


class Unread(ValueError):
    """rebind: the record could not be read (no hub, no answer) — unknown."""


def rebind(task, sid, fleet_id=""):
    """The SAME session back in a new window (claude-fleet#4974).

    A reopen (a cfg-stale / ver-stale / quota migrate, a /fleet-history resume,
    a parked wake) closes a hub task's window and resumes its transcript in
    another; the task's binding is the hub's own record of it: the executor it
    names and the launch receipt its last verified start published as evidence.
    Never a new claim or a new identity: the record must still name this worker,
    its receipt this native session, and that native must be gone. Returns
    {launch, receipt, fleet_id} for the new window's stamps. NotBound (exit 3) =
    nothing to rebind (closed, unowned, another session); Unread (4) = no record
    could be read (no hub here: the caller's road as before); ValueError (1) = the
    record says it is this session but it cannot continue now.
    """
    if not re.fullmatch(r"T[1-9][0-9]*", task or "") or not valid_uuid(sid):
        raise NotBound("rebind needs a task T<n> and a native session id")
    try:
        t = task_call({"task": task})
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        raise Unread("task record unreadable: " + str(exc)) from exc
    if t.get("authority_version") != 1 or t.get("outcome") or not t.get("execution_owner"):
        raise NotBound("task has no open execution to continue")
    try:
        evidence = json.loads(t.get("evidence") or "")
        c = validate_context({k: evidence.get(k) for k in IDENTITY})
        receipt = check_receipt(c, {k: v for k, v in evidence.items() if k != "window_id"})
    except (ValueError, TypeError, AttributeError) as exc:
        raise NotBound("task record carries no verified launch receipt") from exc
    if receipt["native_session"] != sid:
        raise NotBound("task's native session is another conversation")
    if (c["task"] != task or t.get("owner") != c["owner"] or t.get("generation") != c["generation"]
            or t.get("execution_owner") != c["worker_id"] or t.get("attempt_id") != c["attempt_id"]
            or t.get("resolved_agent") != c["provider"]):
        raise ValueError("task owner/generation/provider fence differs from its launch receipt")
    fid = c["worker_id"].split("/")[1]
    if fleet_id and fleet_id != fid:
        raise ValueError("window identity differs from the task's executor")
    if same_process(receipt):
        raise ValueError("the original native process is still alive; reconnect to it")
    return dict(launch=c, receipt=receipt, fleet_id=fid)


def publish(c, receipt):
    current_task(c)  # idempotent event replay alone cannot authorize old work
    proof = {k: v for k, v in receipt.items() if k != "window_id"}
    evidence = json.dumps(proof, sort_keys=True, separators=(",", ":"))
    key = "launch-native:" + c["operation_id"] + ":" + hashlib.sha256(evidence.encode()).hexdigest()[:16]
    t = task_call(c, dict(kind="transition", idempotency_key=key, generation=c["generation"],
                         expected_worker=c["worker_id"], state="running", actual_agent=c["provider"], evidence=evidence))
    if t.get("generation") != c["generation"] or t.get("execution_owner") != c["worker_id"]:
        raise ValueError("task changed during launch verification")


def stop_created(child, root=None):
    try:
        current = process(child.pid)
    except (OSError, ValueError, subprocess.SubprocessError):
        return
    if root is None or current["birth"] != root["birth"]:
        return  # an exited/reused parent cannot authorize signalling its new tree
    rows = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=3).stdout
    parents = {int(a): int(b) for a, b in (line.split() for line in rows.splitlines())}
    owned = {child.pid}
    for _ in range(24):
        more = {pid for pid, parent in parents.items() if parent in owned}
        if more <= owned:
            break
        owned |= more
    proofs = []
    for pid in owned:
        try:
            if descendant(pid, child.pid):
                proofs.append(process(pid))
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    for proof in proofs:
        if same_process(proof):
            try:
                os.kill(proof["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and any(same_process(p) for p in proofs):
        time.sleep(0.05)
    for proof in proofs:
        if same_process(proof):
            try:
                os.kill(proof["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def held_argv(argv, seed, has_seed, old):
    """Parse only the launcher's supported options; no prompt/option guessing.

    Recovery may carry one legacy nudge, which is discarded. Unknown flags or
    additional positional input refuse before any native process is created.
    """
    if not argv:
        raise ValueError("missing launcher")
    if not old and has_seed:
        if len(argv) < 2 or argv[-1] != seed:
            raise ValueError("seed does not match the held launch input")
        argv = argv[:-1]  # even a prompt beginning with '-' remains data
    out, positionals, provider, resume, fresh_sid = argv[:1], [], "claude", "", ""
    values = {"--agent", "--as", "--role", "--codex-home", "--codex-profile",
              "--model", "-m", "--effort", "-c", "--append-system-prompt-file",
              "--permission-mode", "--tools", "--disallowedTools", "--session-id"}
    i = 1
    while i < len(argv):
        arg = argv[i]
        key, sep, value = arg.partition("=")
        if key in values:
            if not sep:
                i += 1
                if i == len(argv):
                    raise ValueError("missing launcher option value")
                value = argv[i]
                out.extend((key, value))
            else:
                out.append(arg)
            if key == "--agent":
                provider = value
            if key == "--session-id":
                if fresh_sid or not valid_uuid(value):
                    raise ValueError("invalid explicit native session identity")
                fresh_sid = value
        elif arg in ("resume", "--resume"):
            i += 1
            if resume or i == len(argv) or not valid_uuid(argv[i]):
                raise ValueError("resume requires one explicit native session")
            resume = argv[i]
            out.extend((arg, resume))
        elif arg.startswith("-"):
            raise ValueError("unsupported accepted-launch option: " + key)
        else:
            positionals.append(arg)
        i += 1
    if fresh_sid and (old or resume):
        raise ValueError("resume cannot also start a fresh native session")
    if old:
        if resume != old["native_session"] or len(positionals) > 1:
            raise ValueError("interrupted: resume needs the original native session")
    elif positionals:
        raise ValueError("seed does not match the held launch input")
    return out, provider, resume or fresh_sid


def supervise(argv):
    pane = os.environ["TMUX_PANE"]
    c = validate_context(json.loads(option(pane, "@launch")))
    from fleet_task_recovery import native_guard
    with contextlib.ExitStack() as guard:
        guard.enter_context(native_guard(c))
        return supervise_guarded(argv, pane, c, guard)


def supervise_guarded(argv, pane, c, guard):
    old_raw = option(pane, "@launch_receipt")
    old = check_receipt(c, json.loads(old_raw)) if old_raw else None
    if option(pane, "@launch_started") and old is None:
        raise ValueError("interrupted: an earlier start lost native identity; no fresh rerun")
    if old and same_process(old):
        raise ValueError("the original native process is still alive; reconnect to it")
    # The spawner records the seed file BEFORE opening the window. Remove it
    # from the launcher's argv; neither native provider sees it before proof.
    seedfile = option(pane, "@launch_seed")
    seed = Path(seedfile).read_text().rstrip("\n") if seedfile and not old else ""
    argv, asked, resume = held_argv(argv, seed, bool(seedfile), old)
    if asked != c["provider"]:
        raise ValueError("resume provider differs from accepted launch")
    if old:
        seed = ""  # a launch seed is never redelivered on recovery
    current_task(c)  # stale transfers/recovery cannot even start a native process
    worktree = prepare_worktree(pane, old)
    native_worktree = prepare_native_worktree(pane, asked, worktree, old)
    env = dict(os.environ, FLEET_LAUNCH_CONTEXT=json.dumps(c), FLEET_LAUNCH_SUPERVISOR=str(os.getpid()),
               FLEET_LAUNCH_NATIVE=resume)
    env.pop("FLEET_LAUNCH_WORKTREE", None)
    env.pop("FLEET_LAUNCH_CREATE", None)
    if worktree:
        env["FLEET_LAUNCH_WORKTREE"] = json.dumps(worktree)
    directory = worktree["root"] if worktree else None
    if native_worktree:
        env["FLEET_LAUNCH_CREATE"] = json.dumps(native_worktree)
        argv += ["--worktree", native_worktree["name"], "--name", native_worktree["name"]]
        directory = native_worktree["root"]
    tmux("set-option", "-wu", "-t", pane, "@launch_receipt")
    tmux("set-option", "-wu", "-t", pane, "@launch_hook_error")
    tmux("set-option", "-wu", "-t", pane, "@launch_error")
    tmux("set-option", "-w", "-t", pane, "@launch_started", "1")
    if not option(pane, "@task"):
        # A reopened window (restore, migrate, a history resume) is the same
        # task's session: its record rides with the launch (claude-fleet#4974).
        tmux("set-option", "-w", "-t", pane, "@task", c["task"])
    child = subprocess.Popen(argv, env=env, **({"cwd": directory} if directory else {}))
    root = None
    verified = False
    receipt = None
    try:
        root = process(child.pid)
        deadline = time.monotonic() + 45
        receipt = None
        why = "no receipt: the native SessionStart hook recorded none"
        while child.poll() is None and time.monotonic() < deadline:
            try:
                if not option(pane, "@launch_receipt"):
                    refused = option(pane, "@launch_hook_error")
                    if refused:
                        why = "no receipt: the SessionStart hook refused — " + refused
                    raise LookupError(why)
                receipt = inspect(c, pane)
                if native_worktree:
                    if receipt.get("native_worktree") != native_worktree:
                        raise ValueError("native launch did not prove its creation intent")
                    if worktree and receipt.get("worktree") != worktree:
                        raise ValueError("native recovery did not prove its saved worktree")
                elif worktree != receipt.get("worktree"):
                    raise ValueError("native launch did not prove the expected worktree")
                if descendant(receipt["pid"], child.pid):
                    break
                why = "pid ancestry: native %d is not under this launch's process %d" % (receipt["pid"], child.pid)
                receipt = None
            except LookupError:
                receipt = None
            except (OSError, ValueError, subprocess.SubprocessError) as e:
                why = str(e) or type(e).__name__
                receipt = None
            time.sleep(0.1)
        if child.poll() is not None:
            why = "the native process exited first (rc %s)" % child.returncode
        if receipt is None or child.poll() is not None:
            # Say WHICH proof did not match (T524), on the window and in the log.
            line = "unknown: no matching process/native-session receipt (%s); task input withheld" % why
            launch_log("%s %s: %s" % (c["task"], c["operation_id"], line))
            try:
                tmux("set-option", "-w", "-t", pane, "@launch_error", line[:400])
            except (OSError, subprocess.SubprocessError):
                pass
            raise ValueError(line)
        publish(c, receipt)
        if seed:
            # A final process/identity comparison immediately precedes native
            # inbox delivery. No keystrokes, alternate provider or queued retry.
            final = inspect(c, pane)
            if (any(final[k] != receipt[k] for k in (*IDENTITY, "native_session"))
                    or not same_identity(final, receipt)):
                raise ValueError("launch identity changed before input")
            if final.get("worktree") != receipt.get("worktree"):
                raise ValueError("worktree identity changed before input")
            if c["provider"] == "codex" and seed.startswith("/fleet-"):
                seed = "$" + seed[1:]
            if c["provider"] == "codex":
                send = [sys.executable, str(BIN / "fleet-codex-session.py"), "send", "--pane", pane]
                env["FLEET_LAUNCH_DELIVERY"] = json.dumps(receipt)
            else:
                # The existing native inbox, addressed to the verified PID.
                # Unlike peer-send's operator channel this never queues a retry.
                send = ["bash", "-c", '. "$1/fleet-lib.sh"; fleet_peer_send "$2" "$(cat)"',
                        "launch", str(BIN), str(receipt["pid"])]
            result = subprocess.run(send, input=seed, text=True, capture_output=True, timeout=20, env=env)
            if result.returncode != 0:
                raise ValueError("unknown: native input delivery did not confirm; no retry")
        receipt["phase"] = "delivered" if seed else "resumed" if old else "ready"
        stamp(pane, "@launch_receipt", receipt)
        tmux("set-option", "-wu", "-t", pane, "@launch_seed")
        verified = True
        guard.close()  # future stop reconciliation may inspect this incarnation
        status = child.wait()
        # Retire execution ownership or acknowledge a pending cancellation.
        # Explicit success/failure already committed while the session lived;
        # native exit alone never creates either work outcome.
        result = subprocess.run([sys.executable, str(BIN / "fleet_task_control.py"), "finalize", "--pane", pane],
                                capture_output=True, text=True, timeout=45)
        if result.stdout:
            print(result.stdout.strip(), file=sys.stderr)
        return status
    finally:
        if not verified or child.poll() is None:
            # Only descendants of this Popen are ours. Never close a window
            # found by label/issue or signal a surviving unrelated session.
            stop_created(child, root)
            if old and not verified:
                stamp(pane, "@launch_receipt", old)


def transfer_check(pane, socket):
    raw = option(pane, "@launch", socket)
    if not raw:
        return
    c = validate_context(json.loads(raw))
    inspect(c, pane, socket)
    current_task(c)


def transfer_commit(pane, socket, target, bundle):
    c = validate_context(json.loads(option(pane, "@launch", socket)))
    old = check_receipt(c, json.loads(option(pane, "@launch_receipt", socket)))
    if "native_worktree" in old:
        raise ValueError("native Claude worktree transfer needs a verified provider handoff")
    if same_process(old):
        raise ValueError("source is still alive; no replacement authorized")
    current_task(c)
    if target not in ("codex", "claude"):
        raise ValueError("unknown transfer provider")
    # The existing transfer package and operation journal keep the request;
    # a failed/ambiguous response never causes a second fresh generation.
    package = Path(bundle)
    binding = package / "task-launch.json"
    if binding.exists():
        raise ValueError("transfer acceptance already attempted; inspect task/operation before recovery")
    op = str(uuid.uuid4())
    with os.fdopen(os.open(binding, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump(dict(source=c, operation_id=op), stream)
    evidence = json.dumps(dict(source_receipt=old, execution_stopped=True, target=target))
    t = task_call(c, dict(kind="transfer", idempotency_key="launch-transfer:" + op,
                         generation=c["generation"], expected_worker=c["worker_id"], execution_stopped=True,
                         requested_agent=target, resolved_agent=target, evidence=evidence))
    if t.get("generation") != c["generation"] + 1 or t.get("state") != "accepted":
        raise ValueError("transfer did not accept the next generation")
    new = dict(c, generation=t["generation"], attempt_id=t["attempt_id"], operation_id=op, provider=target)
    validate_context(new)
    task_call(new, dict(kind="claim", idempotency_key="launch-claim:" + op,
                        generation=new["generation"], worker_id=new["worker_id"]))
    from fleet_control import Control
    from fleet_hub_common import canonical, now
    controller = Control()
    req = dict(operation_id=op, fleet_id=c["worker_id"].split("/")[0], action="worker_transfer",
               params=dict(launch=new), actor=c["owner"])
    with controller.store.connect() as db:
        db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)",
                   (op, req["fleet_id"], req["action"], canonical(req), c["owner"], "running", now(), now()))
    binding.write_text(json.dumps(dict(source=c, launch=new)))
    tmux("set-option", "-w", "-t", pane, "@launch", json.dumps(new), socket=socket)
    tmux("set-option", "-wu", "-t", pane, "@launch_receipt", socket=socket)
    tmux("set-option", "-wu", "-t", pane, "@launch_started", socket=socket)
    tmux("set-option", "-w", "-t", pane, "@launch_seed", str(package / "pickup.md"), socket=socket)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("inspect", "supervise", "transfer-check", "transfer-commit", "admit", "local", "native-worktree", "restore-native-worktree", "rebind"))
    p.add_argument("--socket", default="")
    p.add_argument("--pane", default="")
    p.add_argument("--target", default="")
    p.add_argument("--bundle", default="")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    a = p.parse_args()
    try:
        if a.mode == "rebind":
            if len(a.argv) not in (2, 3):
                raise ValueError("rebind requires a task, a native session and optionally a fleet identity")
            try:
                print(json.dumps(rebind(*a.argv), separators=(",", ":")))
            except NotBound as e:
                print("launch: " + str(e), file=sys.stderr)
                return 3
            except Unread as e:
                print("launch: " + str(e), file=sys.stderr)
                return 4
            return 0
        if a.mode == "restore-native-worktree":
            if len(a.argv) != 4:
                raise ValueError("restore-native-worktree requires directory, session, provider and fleet identity")
            saved = json.load(sys.stdin)
            if not isinstance(saved, list) or len(saved) != 2:
                raise ValueError("restore-native-worktree requires saved context and receipt")
            intent = restore_native_worktree(*saved, *a.argv)
            if intent:
                print(json.dumps(intent))
            return 0
        if a.mode == "native-worktree":
            if len(a.argv) != 2:
                raise ValueError("native-worktree requires repository and base branch")
            intent = new_native_worktree(*a.argv)
            print(intent["name"] + "\t" + str(native_worktree_path(intent)) + "\t" + json.dumps(intent))
            return 0
        if a.mode == "local":
            if len(a.argv) != 1:
                raise ValueError("local requires this fleet's UUID")
            c = local_launch(json.load(sys.stdin), a.argv[0])
            if c:
                print(json.dumps(c, separators=(",", ":")))
            return 0
        if a.mode == "admit":
            d = json.load(sys.stdin)
            if d.get("task") and not (id_switch_on() and not os.environ.get("FLEET_LAUNCH")):
                c = validate_context(json.loads(os.environ.get("FLEET_LAUNCH", "null")))
                if any(c[k] != d.get(k) for k in ("task", "generation", "attempt_id")) or c["provider"] != d.get("resolved_agent"):
                    raise ValueError("accepted dispatch needs its authorized launch binding")
            return 0
        if a.mode == "transfer-check":
            transfer_check(a.pane, a.socket)
            return 0
        if a.mode == "transfer-commit":
            transfer_commit(a.pane, a.socket, a.target, a.bundle)
            return 0
        if a.mode == "inspect":
            print(json.dumps(inspect(json.load(sys.stdin), a.pane, a.socket)))
            return 0
        # Terminal interrupts belong to the native process, as in the wrapper.
        # Shutdown unwinds the supervisor and cleans only its created tree.
        def shutdown(signum, _frame):
            raise InterruptedError("launch supervisor stopped by signal %d" % signum)
        for sig in (signal.SIGHUP, signal.SIGTERM):
            signal.signal(sig, shutdown)
        for sig in (signal.SIGINT, signal.SIGQUIT):
            signal.signal(sig, lambda _sig, _frame: None)
        return supervise(a.argv[1:] if a.argv[:1] == ["--"] else a.argv)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        print("launch: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
