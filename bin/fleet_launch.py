#!/usr/bin/env python3
"""Versioned launch proof. Intent, process observation and task outcome are distinct.

The existing operation journal owns dispatch; tmux carries its launch binding.
No retry queue, process discovery by label, or task database lives here.
"""
import argparse
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
    return receipt


def tmux(*args, socket=""):
    cmd = ["tmux"] + (["-L", socket] if socket else [])
    return subprocess.run(cmd + list(args), capture_output=True, text=True, check=True, timeout=5).stdout.strip()


def option(pane, key, socket=""):
    return tmux("display-message", "-p", "-t", pane, "#{" + key + "}", socket=socket)


def stamp(pane, key, value):
    tmux("set-option", "-w", "-t", pane, key, json.dumps(value, separators=(",", ":")))


def process(pid):
    """Kernel executable + start time, never argv, environment or a window label."""
    row = subprocess.run(["ps", "-p", str(pid), "-o", "ppid=,lstart="],
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
    else:
        executable = os.readlink("/proc/%d/exe" % pid)
        # Linux start ticks distinguish PID reuse within the same second.
        row[1] += ":" + Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()[19]
    return dict(pid=int(pid), ppid=int(row[0]), birth=row[1], executable=executable)


def same_process(receipt):
    try:
        current = process(receipt["pid"])
        return all(current[k] == receipt[k] for k in ("pid", "birth", "executable"))
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


def native_name(path):
    base = Path(path).name
    return base in ("codex", "claude") or bool(re.fullmatch(r"\d+\.\d+\.\d+", base))


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


def native_parent():
    """The hook's native ancestor. Only its version probe sees an empty request."""
    pid = os.getppid()
    for _ in range(12):
        p = process(pid)
        # Managed Claude binaries use a numeric version basename. Do not run
        # arbitrary ancestor shells/interpreters as provider probes.
        if native_name(p["executable"]):
            v = subprocess.run([p["executable"], "--version"], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=5)
            version = v.stdout.strip()
            actual = "codex" if re.fullmatch(r"codex-cli \S+", version) else (
                "claude" if re.fullmatch(r"\S+ \(Claude Code\)", version) else "")
            if v.returncode == 0 and actual:
                return dict(p, actual_provider=actual)
        pid = p["ppid"]
        if pid <= 1:
            break
    raise ValueError("no verified native provider in hook ancestry")


def hook(payload):
    raw = os.environ.get("FLEET_LAUNCH_CONTEXT", "")
    if not raw or payload.get("hook_event_name") != "SessionStart":
        return
    c = validate_context(json.loads(raw))
    pane = os.environ["TMUX_PANE"]
    if json.loads(option(pane, "@launch")) != c:
        raise ValueError("launch binding changed")
    p = native_parent()
    supervisor = int(os.environ["FLEET_LAUNCH_SUPERVISOR"])
    if not root_native(p, supervisor):
        raise ValueError("native process is outside this launch")
    receipt = dict(c, **p, native_session=payload.get("session_id"), observed_at=time.time(), phase="verified")
    if p["actual_provider"] == "codex":
        receipt.update(native_remote=os.environ.get("FLEET_CODEX_REMOTE", ""),
                       native_home=os.environ.get("CODEX_HOME", ""))
    # Preserve an old native identity on resume. Missing identity never starts
    # a fresh session under an existing accepted operation.
    expected = os.environ.get("FLEET_LAUNCH_NATIVE", "")
    if expected and expected != receipt["native_session"]:
        raise ValueError("resume changed native session identity")
    check_receipt(c, receipt)
    old = option(pane, "@launch_receipt")
    if old:
        previous = check_receipt(c, json.loads(old))
        if any(previous[k] != receipt[k] for k in ("pid", "birth", "executable", "native_session")):
            raise ValueError("late or nested hook cannot replace launch identity")
        return
    stamp(pane, "@launch_receipt", receipt)


def inspect(context, pane, socket=""):
    c = validate_context(context)
    if json.loads(option(pane, "@launch", socket)) != c:
        raise ValueError("window no longer holds this launch")
    receipt = check_receipt(c, json.loads(option(pane, "@launch_receipt", socket)))
    if option(pane, "@fleet_id", socket) != c["worker_id"].split("/")[1] or not same_process(receipt):
        raise ValueError("interrupted: native process identity was lost")
    if not descendant(receipt["pid"], int(option(pane, "pane_pid", socket))):
        raise ValueError("interrupted: native process no longer belongs to this pane")
    return dict(receipt, window_id=option(pane, "window_id", socket))


def task_call(context, mutation=None):
    cmd = ["bash", str(BIN / "fleet-task-record.sh"), "mutate" if mutation else "get", context["task"]]
    payload = json.dumps(mutation) if mutation else None
    r = subprocess.run(cmd, input=payload, text=True, capture_output=True, timeout=15)
    if r.returncode:
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
    env = dict(os.environ, FLEET_LAUNCH_CONTEXT=json.dumps(c), FLEET_LAUNCH_SUPERVISOR=str(os.getpid()),
               FLEET_LAUNCH_NATIVE=resume)
    tmux("set-option", "-wu", "-t", pane, "@launch_receipt")
    tmux("set-option", "-w", "-t", pane, "@launch_started", "1")
    child = subprocess.Popen(argv, env=env)
    root = None
    verified = False
    receipt = None
    try:
        root = process(child.pid)
        deadline = time.monotonic() + 45
        receipt = None
        while child.poll() is None and time.monotonic() < deadline:
            try:
                receipt = inspect(c, pane)
                if descendant(receipt["pid"], child.pid):
                    break
                receipt = None
            except (OSError, ValueError, subprocess.SubprocessError):
                receipt = None
            time.sleep(0.1)
        if receipt is None or child.poll() is not None:
            raise ValueError("unknown: no matching process/native-session receipt; task input withheld")
        publish(c, receipt)
        if seed:
            # A final process/identity comparison immediately precedes native
            # inbox delivery. No keystrokes, alternate provider or queued retry.
            final = inspect(c, pane)
            if any(final[k] != receipt[k] for k in (*IDENTITY, "native_session", "pid", "birth", "executable")):
                raise ValueError("launch identity changed before input")
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
        return child.wait()
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
    p.add_argument("mode", choices=("inspect", "supervise", "transfer-check", "transfer-commit", "admit"))
    p.add_argument("--socket", default="")
    p.add_argument("--pane", default="")
    p.add_argument("--target", default="")
    p.add_argument("--bundle", default="")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    a = p.parse_args()
    try:
        if a.mode == "admit":
            d = json.load(sys.stdin)
            if d.get("task"):
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
