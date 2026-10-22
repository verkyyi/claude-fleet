"""Quota continuation for the shared session gate (T943).

Only an explicit native API quota error authorizes a transfer. The transfer
controller remains the authority on identity, drafts, tools, schedules and exit.
The per-source receipt is write-ahead: unknown completion is never retried.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path


def quota_error(path, sid):
    """Latest main conversation message is a native hard-quota API error."""
    if path is None:
        return None
    last = None
    try:
        # Bounded tail; skip an incomplete first record. Never infer an error
        # from a user's words, a tool result, or another session's transcript.
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 2 * 1024 * 1024))
            if f.tell():
                f.readline()
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(r, dict) or r.get("sessionId") != sid or r.get("isSidechain"):
                    continue
                if r.get("type") in ("assistant", "user"):
                    last = r
    except OSError:
        return None
    if not last or last.get("type") != "assistant" or last.get("isApiErrorMessage") is not True:
        return None
    if last.get("error") not in ("rate_limit", "rate_limit_error", "quota_exceeded"):
        return None
    message = last.get("message")
    content = message.get("content", []) if isinstance(message, dict) else []
    if not isinstance(content, list):
        return None
    text = " ".join(str(x.get("text", "")) for x in content if isinstance(x, dict) and x.get("type") == "text")
    # A per-minute 429, network/auth error and cancellation are not quota.
    if re.search(r"per.minute|requests per|too many requests|cancel|authentication|unauthorized", text, re.I):
        return None
    if not re.search(r"(?:hit|reached|exceeded) your (?:weekly |usage |session )?limit|weekly limit|usage limit|session limit|quota (?:exhausted|exceeded)|claude_pool_unavailable", text, re.I):
        return None
    return dict(source_session=sid, error_id=last.get("uuid", ""), transcript=str(path))


def receipt(gate, fid):
    return gate.read_json(gate.fid_dir(fid) / "quota-continuation.json")


def maybe_start(gate, w, rows):
    """Called under the delivery lock, before any further words can be sent."""
    if w is None or w["agent"] != "claude" or not w["sid"]:
        return
    old = receipt(gate, w["fid"])
    if old and old.get("source_session") == w["sid"] and old.get("state") != "waiting":
        return
    signal = quota_error(gate.claude_transcript(w["sid"]), w["sid"])
    if not signal:
        return
    pending = [r for r in rows if r.get("state") in ("trying", "native", "waking")]
    boundary = w["state"] == "done" or (w["state"] == "exited" and w["word"] == "error")
    why = "delivery_unsettled" if pending else "boundary" if gate.busy_of(w) or w["parked"] or not boundary else ""
    same = old if old and old.get("source_session") == w["sid"] else {}
    waiting = why == "boundary" and not w["parked"] and gate.busy_of(w) != "asking" and gate.now() - same.get("at", gate.now()) < 30
    signal.update(at=same.get("at", gate.now()), request_id=same.get("request_id") or uuid.uuid4().hex)
    signal.update(state="waiting" if waiting else "blocked" if why else "starting", why=why, fid=w["fid"])
    path = gate.fid_dir(w["fid"]) / "quota-continuation.json"
    gate.write_json(path, signal)
    # Queued words belong to the source conversation. Return them to the
    # existing composer recovery flow; never replay them as the pickup prompt.
    for r in rows:
        if r.get("state") == "queued":
            gate.ret(r, "quota_continuation")
    if why:
        return
    try:
        subprocess.Popen([sys.executable, str(gate.BIN / "fleet_session_gate.py"), "quota-transfer",
                          "--fid", w["fid"], "--source-session", w["sid"]],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError:
        signal.update(state="blocked", why="controller_unavailable")
        gate.write_json(path, signal)


def run(gate, fid, sid):
    path = gate.fid_dir(fid) / "quota-continuation.json"
    with gate.lock(fid):
        r = receipt(gate, fid)
        w = gate.window(fid)
        if not r or r.get("source_session") != sid or r.get("state") != "starting":
            return
        r.update(state="transferring")
        gate.write_json(path, r)  # crash after here ⇒ recover explicitly, never launch twice
    why = "source_changed"
    if w and w["agent"] == "claude" and w["sid"] == sid and quota_error(gate.claude_transcript(sid), sid):
        argv = ["bash", str(gate.BIN / "fleet-transfer.sh"), "--session", w["sock"], "--window", w["win"],
                "--to", "codex", "--quota-continuation", "--expected-session-id", sid]
        # Keep the controller's rollback, but no automatic relogin retry chain.
        env = dict(os.environ, FLEET_TRANSFER_RETRYING="1")
        env.pop("TMUX_PANE", None)
        try:
            with (path.parent / "quota-transfer.log").open("w") as log:
                p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env)
            after = gate.window(fid)
            if p.returncode == 0 and after and after["agent"] == "codex" and after["sid"]:
                r.update(state="continued", target_session=after["sid"], completed_at=time.time())
                finish(gate, path, r)
                return
            why = "transfer_refused"  # detailed private controller receipt is retained
        except OSError:
            why = "controller_unavailable"
    r.update(state="blocked", why=why)
    finish(gate, path, r)


def finish(gate, path, result):
    # A late old controller cannot overwrite a newer source generation.
    with gate.lock(result["fid"]):
        current = gate.read_json(path) or {}
        if current.get("request_id") == result["request_id"] and current.get("state") == "transferring":
            gate.write_json(path, result)


def view(gate, w):
    r = receipt(gate, w["fid"]) if w else None
    if not r:
        return None
    if w["sid"] not in (r.get("source_session"), r.get("target_session")):
        return None
    state = r.get("state")
    if state == "blocked" and not quota_error(gate.claude_transcript(w["sid"]), w["sid"]):
        return None  # an explicit native continuation has moved past the error
    if (state == "waiting" and gate.now() - r.get("at", 0) >= 30) or (state in ("starting", "transferring") and gate.now() - r.get("at", 0) > 360):
        state = "recovery"  # completion is unknown; never start a second writer
    return dict(state=state, to="codex", message=(
        "Claude 额度已用完，正在换 Codex 继续。" if state in ("waiting", "starting", "transferring") else
        "已换 Codex 继续。" if state == "continued" else
        "Claude 额度已用完，暂时无法安全接续；记录已保留，可从终端恢复或在新会话里接着说。"))
