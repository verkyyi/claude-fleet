#!/usr/bin/env python3
"""Version 1 provider observations. Reads never deliver, resume, stop or reclaim.

Launch/task authority stays in C1/C3. Native Claude events occupy one window
option, not a task store or a replay journal. No observer starts a polling loop.
"""
import argparse
import copy
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import time
import uuid

import fleet_launch as launch

BIN = Path(__file__).absolute().parent
TTL = 5.0
FIRST_THREAD_SECS = 45.0
NATIVE = ("native_session", "pid", "birth", "executable", "native_remote")
RPC = runpy.run_path(str(BIN / "fleet-codex-rpc.py"))["Client"]
CODEX = runpy.run_path(str(BIN / "fleet-codex-session.py"))


class Unknown(ValueError):
    pass


def number(v):
    return type(v) in (int, float) and math.isfinite(v)


def identity(context, receipt, turn_id=None):
    return dict(context, **{k: receipt.get(k) for k in NATIVE}, turn_id=turn_id)


def blank(context=None, now=None):
    now = time.time() if now is None else now
    return dict(version=1, identity=context or {}, source="none", observed_at=now, expires_at=now + TTL,
                runtime=dict(state="unknown", reason="unobserved", socket_ready=None,
                             thread_ready=None, first_thread_deadline=None),
                task_result=dict(state="unknown"), controller_delivery=dict(state="unknown"),
                reclaim=dict(eligible=False, reason="separate_gates_required"))


def unknown(s, reason):
    s["runtime"].update(state="unknown", reason=reason)
    s["task_result"] = dict(state="unknown")
    return s


def project(snapshot, expected=None, now=None):
    """Project a local/remote observation without renewing its evidence time.

    expected is an earlier snapshot, compared across the entire execution and
    turn identity. A match is an observation only, never atomic acceptance.
    """
    now = time.time() if now is None else now
    if not isinstance(snapshot, dict):
        return unknown(blank(now=now), "invalid_snapshot")
    s = copy.deepcopy(snapshot)
    s["controller_delivery"] = dict(state="unknown")
    s["reclaim"] = dict(eligible=False, reason="separate_gates_required")
    try:
        if (type(s.get("version")) is not int or s["version"] != 1
                or not isinstance(s.get("runtime"), dict)):
            raise ValueError()
        i = s["identity"]
        if expected is not None and (not isinstance(expected, dict) or expected.get("version") != 1 or expected.get("identity") != i):
            return unknown(s, "identity_changed")
        if s["runtime"].get("state") != "unknown":
            launch.validate_context({k: i[k] for k in launch.IDENTITY})
            launch.check_receipt({k: i[k] for k in launch.IDENTITY}, dict(i, actual_provider=i["provider"]))
            if not isinstance(i.get("turn_id"), str) or not i["turn_id"]:
                raise ValueError()
        if any(not number(s[k]) for k in ("observed_at", "expires_at")):
            raise ValueError()
        if not 0 < s["expires_at"] - s["observed_at"] <= TTL:
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        # Do not retain a malformed remote object's purported permissions.
        out = blank(now=now)
        return unknown(out, "invalid_snapshot")
    if now < s["observed_at"]:
        return unknown(s, "clock_regressed")
    if now >= s["expires_at"]:
        return unknown(s, "expired")
    if s["runtime"].get("state") not in ("active", "idle", "ask", "approval", "interrupted", "unknown"):
        return unknown(s, "unsupported_state")
    return s


def task(context):
    t = launch.task_call(context)
    if (t.get("authority_version") != 1 or any(t.get(k) != v for k, v in (
            ("owner", context["owner"]), ("generation", context["generation"]),
            ("execution_owner", context["worker_id"]), ("resolved_agent", context["provider"])) )):
        raise Unknown("task_fence_changed")
    return {k: t.get(k) for k in ("outcome", "state", "generation", "execution_owner", "cancel_request_id")}


def thread(client, receipt, cwd):
    t = client.call("thread/read", {"threadId": receipt["native_session"], "includeTurns": False})["thread"]
    if (t.get("id") != receipt["native_session"] or t.get("parentThreadId")
            or not t.get("cwd") or Path(t["cwd"]).resolve() != Path(cwd).resolve()):
        raise Unknown("native_identity_changed")
    return t


def last_turn(client, receipt):
    # Never fetch messages, tool input, output or the complete transcript.
    rows = client.call("thread/turns/list", dict(threadId=receipt["native_session"],
                       limit=1, sortDirection="desc", itemsView="notLoaded"))["data"]
    if not rows:
        return None
    t = rows[0]
    return {k: t.get(k) for k in ("id", "status", "startedAt", "completedAt")}


def codex(s, receipt, pane, socket, cwd):
    data = CODEX["identity"](pane, socket)
    if (data.get("session_id") != receipt["native_session"]
            or data.get("remote") != receipt.get("native_remote")
            or data.get("home") != receipt.get("native_home")):
        raise Unknown("endpoint_identity_changed")
    client = None
    try:
        client = RPC(data["remote"], timeout=3)
        s["runtime"]["socket_ready"] = True
        s["source"] = "codex:rpc"
        s["observed_at"] = time.time()
        t = thread(client, receipt, cwd)
        turn = last_turn(client, receipt)
        again = thread(client, receipt, cwd)
        if t.get("status") != again.get("status") or turn != last_turn(client, receipt):
            raise Unknown("native_changed_during_read")
        if CODEX["identity"](pane, socket) != data:
            raise Unknown("endpoint_identity_changed")
        status = t.get("status", {})
        if status.get("type") not in ("active", "idle"):
            raise Unknown("thread_not_loaded")
        s["runtime"]["thread_ready"] = True
        if not turn or not isinstance(turn.get("id"), str) or not turn["id"]:
            raise Unknown("first_thread_timeout" if time.time() >= s["runtime"]["first_thread_deadline"] else "no_turn")
        s["identity"]["turn_id"] = turn["id"]
        if status["type"] == "active":
            flags = status.get("activeFlags", [])
            if not isinstance(flags, list) or any(x not in ("waitingOnApproval", "waitingOnUserInput") for x in flags):
                raise Unknown("unsupported_active_flags")
            state = "approval" if "waitingOnApproval" in flags else "ask" if "waitingOnUserInput" in flags else "active"
        elif turn["status"] == "completed":
            state = "idle"
        elif turn["status"] == "interrupted":
            state = "interrupted"
        else:
            raise Unknown("turn_not_completed")
        s["runtime"].update(state=state, reason="")
    except Unknown:
        raise
    except (OSError, EOFError, ValueError, KeyError, TypeError):
        if s["runtime"]["socket_ready"] and not s["runtime"]["thread_ready"]:
            raise Unknown("first_thread_timeout" if time.time() >= s["runtime"]["first_thread_deadline"] else "thread_unavailable") from None
        raise Unknown("rpc_unavailable") from None
    finally:
        if client is not None:
            client.close()


def claude_registry(receipt):
    # Use the established registry locator, never a newest-file/session scan.
    path = subprocess.check_output(["bash", "-c", '. "$1"; fleet_cc_session_json "$2"',
                                   "runtime", str(BIN / "fleet-lib.sh"), str(receipt["pid"])],
                                  text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
    with open(path) as f:
        raw = f.read(65537)
    if len(raw) > 65536:
        raise Unknown("registry_invalid")
    r = json.loads(raw)
    if r.get("sessionId") != receipt["native_session"] or str(r.get("pid")) != str(receipt["pid"]):
        raise Unknown("native_identity_changed")
    return r


def query_claude(pane, socket, context):
    """One bounded read request on the existing mod inbox, never a /command.

    One fixed request slot per pane, serialized locally; no new timer or journal.
    Only a native-ancestry-checked event with this nonce can answer the reader.
    """
    sock = Path(launch.option(pane, "socket_path", socket)).name
    if not sock:
        raise Unknown("native_query_unavailable")
    conf = Path(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")))
    directory = conf / "global/mod-inbox" / sock / pane[1:]
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    base = directory / "runtime-observation"
    with base.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Unknown("native_query_busy") from None
        nonce = uuid.uuid4().hex
        deadline = time.monotonic() + 3
        tmp = directory / ".runtime-observation.tmp"
        paths = [base.with_suffix(s) for s in (".json", ".taken", ".done")]
        try:
            for path in paths:
                path.unlink(missing_ok=True)
            tmp.write_text(json.dumps(dict(query="runtime.v1", nonce=nonce, launch=context,
                                           deadline=time.time() + 3)))
            tmp.replace(paths[0])
            while time.monotonic() < deadline:
                event = json.loads(launch.option(pane, "@runtime_claude", socket) or "{}")
                if event.get("query_id") == nonce:
                    return event
                if paths[2].exists():
                    break
                time.sleep(.05)
            raise Unknown("native_query_unavailable")
        finally:
            for path in [tmp, *paths]:
                path.unlink(missing_ok=True)


def claude(s, receipt, pane, socket, cwd):
    event = json.loads(launch.option(pane, "@runtime_claude", socket) or "{}")
    if event.get("version") != 1 or not event.get("turn_id"):
        raise Unknown("no_turn_observation")
    if event.get("identity") != identity({k: receipt[k] for k in launch.IDENTITY}, receipt):
        raise Unknown("event_identity_changed")
    at = event.get("observed_at")
    if not number(at):
        raise Unknown("invalid_event")
    s["source"] = "claude:native-query" if event.get("query_id") else "claude:native-event"
    s["identity"]["turn_id"] = event["turn_id"]
    # Even a rejected observation keeps its source time and turn. A reader's
    # current clock must never make an expired event look newly observed.
    s["observed_at"] = at
    s["expires_at"] = at + TTL
    if time.time() < at:
        raise Unknown("clock_regressed")
    if time.time() - at >= TTL:
        event = query_claude(pane, socket, {k: receipt[k] for k in launch.IDENTITY})
        if event.get("identity") != identity({k: receipt[k] for k in launch.IDENTITY}, receipt):
            raise Unknown("event_identity_changed")
        at = event.get("observed_at")
        if not number(at) or not 0 <= time.time() - at < TTL:
            raise Unknown("event_expired")
        s.update(source="claude:native-query", observed_at=at, expires_at=at + TTL)
        s["identity"]["turn_id"] = event["turn_id"]
    r = claude_registry(receipt)
    if not r.get("cwd") or Path(r["cwd"]).resolve() != Path(cwd).resolve():
        raise Unknown("native_identity_changed")
    s["runtime"]["thread_ready"] = True
    state = event.get("state")
    if state == "idle" and r.get("status") != "idle":
        raise Unknown("registry_contradicts_event")
    if state not in ("active", "idle", "ask", "approval", "interrupted"):
        raise Unknown("unsupported_event")
    if json.loads(launch.option(pane, "@runtime_claude", socket) or "{}") != event:
        raise Unknown("native_changed_during_read")
    s["runtime"].update(state=state, reason="")


def read(pane, context=None, expected=None, socket=""):
    """One bounded read; explicit pane ID and optional frozen C3 context."""
    s = blank()
    try:
        if not re.fullmatch(r"%[0-9]+", pane or ""):
            raise Unknown("explicit_pane_required")
        raw = launch.option(pane, "@launch", socket)
        if not raw:
            raise Unknown("missing_launch")
        c = launch.validate_context(context if context is not None else json.loads(raw))
        s["identity"] = c.copy()
        if json.loads(raw) != c:
            raise Unknown("launch_changed")
        # Anchor the first-thread deadline to this pane's kernel birth, never
        # to a reader's retry or a wall-clock value from a remote cache.
        root = launch.process(int(launch.option(pane, "pane_pid", socket)))
        started = time.mktime(time.strptime(root["birth"][:24], "%a %b %d %H:%M:%S %Y"))
        s["runtime"]["first_thread_deadline"] = started + FIRST_THREAD_SECS
        if not launch.option(pane, "@launch_receipt", socket):
            raise Unknown("first_thread_timeout" if time.time() >= started + FIRST_THREAD_SECS else "missing_launch_receipt")
        receipt = launch.inspect(c, pane, socket)
        s["identity"] = identity(c, receipt)
        before = task(c)
        s["task_result"] = dict(state=before["outcome"] or "pending")
        cwd = launch.option(pane, "@worktree", socket) or launch.option(pane, "pane_current_path", socket)
        (codex if c["provider"] == "codex" else claude)(s, receipt, pane, socket, cwd)
        if launch.inspect(c, pane, socket) != receipt or task(c) != before:
            raise Unknown("identity_changed_during_read")
        s["expires_at"] = s["observed_at"] + TTL
        return project(s, expected=expected)
    except Unknown as e:
        return unknown(s, str(e))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return unknown(s, "identity_or_authority_unavailable")


def record_event(payload):
    """Existing Claude native event hook; no settings Stop event is accepted."""
    pane = os.environ.get("TMUX_PANE", "")
    raw = os.environ.get("FLEET_LAUNCH_CONTEXT", "")
    if not raw or not re.fullmatch(r"%[0-9]+", pane):
        return
    c = launch.validate_context(json.loads(raw))
    if c["provider"] != "claude":
        return
    r = launch.inspect(c, pane)
    pid = os.getppid()
    for _ in range(24):
        if pid == r["pid"]:
            break
        parent = launch.process(pid)
        if launch.native_name(parent["executable"]) or parent["ppid"] <= 1:
            raise Unknown("event_outside_native_process")
        pid = parent["ppid"]
    if pid != r["pid"]:
        raise Unknown("event_outside_native_process")
    registry = claude_registry(r)
    if registry.get("sessionId") != r["native_session"]:
        raise Unknown("event_identity_changed")
    at, turn, sequence = payload.get("observed_at"), payload.get("turn_id"), payload.get("sequence")
    if (not number(at) or not 0 <= time.time() - at < TTL
            or not isinstance(turn, str) or not turn or len(turn) > 200
            or type(sequence) is not int or sequence < 1
            or payload.get("state") not in ("active", "idle", "ask", "approval", "interrupted")):
        raise Unknown("invalid_event")
    key = hashlib.sha256((os.environ.get("TMUX", "") + pane).encode()).hexdigest()
    # A mutex only, no retained journal; serialize asynchronous native edges.
    lockdir = Path(tempfile.gettempdir()) / ("fleet-runtime-%d" % os.getuid())
    lockdir.mkdir(mode=0o700, exist_ok=True)
    with (lockdir / key).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = json.loads(launch.option(pane, "@runtime_claude") or "{}")
        ident = identity(c, r)
        query = payload.get("query_id")
        if query is not None and (not isinstance(query, str) or not re.fullmatch(r"[a-f0-9]{32}", query)
                or payload.get("start") or old.get("identity") != ident
                or old.get("turn_id") != turn or old.get("state") != payload["state"]):
            raise Unknown("query_identity_changed")
        if old.get("identity") == ident:
            if at < old.get("observed_at", 0) or sequence <= old.get("sequence", 0):
                raise Unknown("late_event")
            if not payload.get("start") and turn != old.get("turn_id"):
                raise Unknown("late_turn_event")
            if not query and turn == old.get("turn_id") and old.get("state") in ("idle", "interrupted"):
                raise Unknown("closed_turn_event")
        elif not payload.get("start"):
            raise Unknown("missing_turn_start")
        if launch.inspect(c, pane) != r:
            raise Unknown("event_identity_changed")
        launch.stamp(pane, "@runtime_claude", dict(version=1, identity=ident,
                     turn_id=turn, state=payload["state"], observed_at=at, sequence=sequence,
                     query_id=query))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=("read", "project", "event"))
    p.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    p.add_argument("--socket", default="")
    a = p.parse_args()
    data = json.load(sys.stdin)
    if a.command == "event":
        record_event(data)
        return 0
    s = (project(data["snapshot"], expected=data.get("expected")) if a.command == "project" else
         read(a.pane, context=data.get("launch"), expected=data.get("expected"), socket=a.socket))
    print(json.dumps(s, allow_nan=False, separators=(",", ":")))
    return 2 if s["runtime"]["state"] == "unknown" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("runtime observation unavailable", file=sys.stderr)
        sys.exit(2)
