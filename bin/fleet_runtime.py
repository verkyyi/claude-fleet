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


# Codex's queue extension starts a queued user message with the core's
# start_turn_if_idle under a per-thread dispatch lock (refusing an active or
# pending turn), persists each item with its clientUserMessageId, and stamps
# that id on the accepted turn's userMessage item (#4617). Verified on 0.162.1.
CODEX_ACCEPT_MIN = (0, 162)
CODEX_NOT_IDLE = "thread already has an active or pending turn"
CODEX_NOT_FOUND = "queued submission not found"
RECEIPT_PAGES = 20
RECEIPT_PAGE = 50

# Claude has no conditional accept reachable from outside the session (#4617);
# inside it, the fleet mod (>= 0.6.0, mod/fleet/hooks/accept.ts) does it at the
# engine's own entry boundary: $.prompt.submit from an engine frame, refused by
# this plugin's prompt.submit hook with { drop } unless the last finished turn is
# still the expected one, none runs, no /clear since, no draft, before the
# deadline (#4618). Verified on 2.1.295 (fleet-idle-accept-claude-selftest.py).
CLAUDE_ACCEPT = "idle.v1"
CLAUDE_ACCEPT_WINDOW = 5.0      # the request's deadline, seconds from the post
CLAUDE_ACCEPT_GRACE = 3.0       # the mod's ACCEPT_GRACE_S: a submitted slot's last word
CLAUDE_ACCEPT_POLL = 2.0        # the inbox poll (INBOX_MS) and one tmux round
CLAUDE_RECEIPT_PREFIX = "fleet idle-accept receipt delivery_id="
# The mod's refusals at the entry boundary: handed to the engine, then dropped.
CLAUDE_ENTRY_DROPS = ("draft_present", "deadline_passed", "not_idle_at_entry", "slot_lost", "dropped_beneath")


def idle_accept_capability(provider):
    """This adapter's support, not a live probe or an upstream version guess.

    Codex: thread/queue/start is the native start-if-idle; clientUserMessageId
    is the receipt, readable again after a disconnect. Claude: the fleet mod's
    entry-boundary check (#4618) — a pane whose mod does not say `@mod_accept
    idle.v1` is refused per call, nothing sent. Never infer one from
    turn/start, turn/steer's *active* expectedTurnId, a successful read, a peer
    frame write or command.run.
    """
    known = isinstance(provider, str) and provider in ("codex", "claude")
    if provider == "claude":
        return dict(version=1, name="idle-accept", provider="claude", state="available",
                    native_method="mod/prompt.submit", reason="",
                    support="mod_entry_boundary_drop_and_hidden_context_receipt",
                    fence=dict(idle="entry_boundary", turn="entry_boundary"),
                    min_native_version="2.1.295", min_mod_version="0.6.0")
    if provider == "codex":
        return dict(version=1, name="idle-accept", provider="codex", state="available",
                    native_method="thread/queue/start", reason="",
                    support="native_start_if_idle_and_client_message_receipt",
                    fence=dict(idle="native", turn="precheck"),
                    min_native_version="%d.%d" % CODEX_ACCEPT_MIN)
    return dict(version=1, name="idle-accept", provider=provider if known else None,
                state="unavailable", native_method=None,
                reason="native_precondition_unavailable" if known else "unsupported_provider",
                support="native_atomic_precondition_and_receipt_required")


def _accept_dir():
    conf = Path(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")))
    d = conf / "global/idle-accept"
    d.mkdir(parents=True, exist_ok=True, mode=0o700)
    return d


def _journal_write(path, record):
    tmp = path.with_name("." + path.name + ".tmp")
    with tmp.open("w") as f:
        json.dump(record, f, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def _prune(directory, now):
    for f in [*directory.glob("*.json"), *directory.glob("*.lock")]:
        try:
            if now - f.stat().st_mtime > 7 * 86400:
                f.unlink()
        except OSError:
            pass


def codex_version(client):
    m = re.search(r"/(\d+)\.(\d+)\.(\d+)", str((getattr(client, "initialized", None) or {}).get("userAgent", "")))
    return tuple(int(x) for x in m.groups()) if m else None


def _receipt_rows(rows, delivery_id, anchor, newer):
    """Scan newest-first rows: ("found"|"anchor"|None, newer, previous)."""
    for t in rows:
        if newer is not None:
            return "found", newer, t.get("id")
        if t.get("id") == anchor:
            return "anchor", None, None
        if any(i.get("type") == "userMessage" and i.get("clientId") == delivery_id
               for i in t.get("items") or []):
            newer = t.get("id")
    return None, newer, None


def codex_receipt(client, sid, delivery_id, anchor):
    """The accepted turn carrying delivery_id, scanning newest-first back to anchor.

    (found, turn_id, previous_turn_id). found None = the scan could not reach the
    anchor within its bound: never read as "not delivered".
    """
    cursor, newer = None, None
    for _ in range(RECEIPT_PAGES):
        params = dict(threadId=sid, limit=RECEIPT_PAGE, sortDirection="desc", itemsView="summary")
        if cursor:
            params["cursor"] = cursor
        try:
            page = client.call("thread/turns/list", params)
        except ValueError as e:
            # A thread whose store has no paginated history yet (a young
            # session): the deprecated full read is the same persisted record.
            if "not supported" not in str(e) or cursor:
                raise
            turns = client.call("thread/read", dict(threadId=sid, includeTurns=True))["thread"].get("turns") or []
            hit, newer, prev = _receipt_rows(list(reversed(turns)), delivery_id, anchor, None)
            if hit == "found" or (hit is None and newer is not None):
                return True, newer, prev
            return (False, None, None) if hit == "anchor" else (None, None, None)
        rows = page.get("data") or []
        hit, newer, prev = _receipt_rows(rows, delivery_id, anchor, newer)
        if hit == "found":
            return True, newer, prev
        if hit == "anchor":
            return False, None, None
        cursor = page.get("nextCursor")
        if not rows or not cursor:
            break
    return (True, newer, None) if newer is not None else (None, None, None)


def codex_queued(client, sid, delivery_id):
    cursor = None
    for _ in range(RECEIPT_PAGES):
        params = dict(threadId=sid, limit=RECEIPT_PAGE)
        if cursor:
            params["cursor"] = cursor
        page = client.call("thread/queue/list", params)
        for q in page.get("data") or []:
            if q.get("clientUserMessageId") == delivery_id:
                return q.get("id")
        cursor = page.get("nextCursor")
        if not cursor:
            return None
    raise Unknown("queue_scan_incomplete")


def codex_settle(client, sid, qid, delivery_id, anchor, wait=2.0):
    """Resolve one queued item: (state, reason, turn_id, previous_turn_id).

    start refused as not idle -> delete under the same native dispatch lock:
    deleted means it never started (rejected); not deleted means the native
    idle dispatch took it first -> the receipt decides. Never a resend.
    """
    try:
        turn = client.call("thread/queue/start", dict(threadId=sid, queuedSubmissionId=qid))["turn"]
    except ValueError as e:
        msg = str(e)
        if CODEX_NOT_IDLE in msg:
            if client.call("thread/queue/delete", dict(threadId=sid, queuedSubmissionId=qid)).get("deleted") is True:
                return "rejected", "native_not_idle", None, None
        elif CODEX_NOT_FOUND not in msg:
            return "unknown", "native_start_failed", None, None
    else:
        # Started by our own call: the answer names the accepted turn.
        try:
            found, tid, prev = codex_receipt(client, sid, delivery_id, anchor)
        except ValueError:
            found = None
        return "accepted", "native_started", turn.get("id"), prev if found and tid == turn.get("id") else None
    deadline = time.monotonic() + wait
    while True:
        found, tid, prev = codex_receipt(client, sid, delivery_id, anchor)
        if found:
            return "accepted", "native_idle_dispatch", tid, prev
        if time.monotonic() >= deadline:
            return "unknown", "receipt_unconfirmed" if found is False else "receipt_scan_incomplete", None, None
        time.sleep(.1)


def accept_if_idle(pane, expected, delivery_id, text, socket=""):
    """Conditional controller input: accepted only when the provider natively
    starts it on an idle session (#4524 contract, #4617 implementation).

    Claude: the fleet mod's inbox (`idle.v1`), checked again at the engine's
    entry boundary; the receipt is the mod's accepted turn (a durable file
    beside the inbox, the delivery id in the turn's hidden context). Codex: a fresh read must still equal `expected`
    and be idle, then thread/queue add + start-if-idle; refused -> deleted under
    the native lock (rejected); a receipt is the accepted turn whose userMessage
    carries clientId == delivery_id. A per-delivery journal is written before
    any native write, so a retry after a disconnect resolves the earlier attempt
    instead of sending again. Unknown is never delivery.
    """
    i = expected.get("identity") if isinstance(expected, dict) else None
    capability = idle_accept_capability(i.get("provider") if isinstance(i, dict) else None)
    result = dict(version=1, capability=capability, state="unknown",
                  reason="capability_unavailable", submitted=False, receipt=None,
                  delivery_id=None, request_identity=None)
    try:
        if (not isinstance(pane, str) or not re.fullmatch(r"%[0-9]+", pane)
                or not isinstance(socket, str) or not launch.valid_uuid(delivery_id)
                or not isinstance(text, str) or not text or len(text) > 65536
                or not isinstance(i, dict) or type(expected.get("version")) is not int
                or expected["version"] != 1):
            raise ValueError()
        c = {k: i[k] for k in launch.IDENTITY}
        launch.check_receipt(c, dict(i, actual_provider=i.get("provider")))
        if not isinstance(i.get("turn_id"), str) or not i["turn_id"]:
            raise ValueError()
        result["delivery_id"] = delivery_id
        result["request_identity"] = {k: i.get(k) for k in launch.IDENTITY + NATIVE + ("turn_id",)}
    except (ValueError, KeyError, TypeError, AttributeError):
        result["reason"] = "invalid_request"
        return result
    if capability["state"] != "available":
        # Do not fall back to turn/start, turn/steer, peer send or command.run.
        return result
    try:
        if capability["provider"] == "claude":
            return _claude_accept(result, pane, expected, delivery_id, text, socket)
        return _codex_accept(result, pane, expected, delivery_id, text, socket)
    except Unknown as e:
        result.update(state="unknown", reason=str(e))
    except (OSError, EOFError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        result.update(state="unknown", reason="native_unavailable")
    return result


def _codex_accept(result, pane, expected, delivery_id, text, socket):
    ident = result["request_identity"]
    fixed = {k: v for k, v in ident.items() if k != "turn_id"}
    digest = hashlib.sha256(text.encode()).hexdigest()
    directory = _accept_dir()
    path = directory / (delivery_id + ".json")
    with (directory / (delivery_id + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rec = json.loads(path.read_text()) if path.exists() else None
        if rec is not None:
            if rec.get("identity") != fixed:
                raise Unknown("delivery_identity_changed")
            if rec.get("text_sha256") != digest:
                result.update(state="rejected", reason="delivery_id_reused")
                return result
            result["submitted"] = bool(rec.get("queued"))
            if rec.get("state") == "accepted":
                result.update(state="accepted", reason="journal", receipt=dict(rec["receipt"], source="journal"))
                return result
        s = read(pane, expected=expected, socket=socket)
        receipt = launch.inspect({k: ident[k] for k in launch.IDENTITY}, pane, socket)
        if {k: receipt.get(k) for k in NATIVE} != {k: ident[k] for k in NATIVE}:
            raise Unknown("native_identity_changed")
        data = CODEX["identity"](pane, socket)
        if (data.get("session_id") != ident["native_session"]
                or data.get("remote") != ident["native_remote"]):
            raise Unknown("endpoint_identity_changed")
        sid = ident["native_session"]
        anchor = rec["anchor"] if rec and rec.get("state") == "pending" else ident["turn_id"]
        client = RPC(data["remote"], timeout=5)
        try:
            v = codex_version(client)
            if v is None or v[:2] < CODEX_ACCEPT_MIN:
                raise Unknown("native_version_untested")
            if rec is not None and rec.get("state") == "pending":
                # Settle the earlier attempt before anything new: never a blind resend.
                qid = codex_queued(client, sid, delivery_id)
                if qid is not None:
                    st, why, tid, prev = codex_settle(client, sid, qid, delivery_id, anchor)
                else:
                    found, tid, prev = codex_receipt(client, sid, delivery_id, anchor)
                    st, why = (("accepted", "native_receipt") if found else
                               ("unknown", "receipt_scan_incomplete") if found is None else
                               ("absent", ""))
                    if st == "absent" and s["runtime"]["state"] != "idle":
                        st, why = "unknown", "previous_attempt_unsettled"
                if st == "accepted":
                    return _accepted(result, path, rec, sid, tid, prev, anchor, why)
                if st == "unknown":
                    result.update(state="unknown", reason=why)
                    return result
                rec.update(state="rejected", reason=why or "not_delivered")
                _journal_write(path, rec)
            if s["runtime"]["state"] != "idle":
                result.update(state="rejected", reason="precheck_" + (s["runtime"]["reason"] or s["runtime"]["state"]))
                return result
            rec = dict(version=1, delivery_id=delivery_id, identity=fixed, text_sha256=digest,
                       anchor=ident["turn_id"], native_session=sid, state="pending",
                       queued=True, created_at=time.time())
            _prune(directory, time.time())
            _journal_write(path, rec)
            result["submitted"] = True
            try:
                q = client.call("thread/queue/add", dict(threadId=sid, clientUserMessageId=delivery_id,
                                                         input=[dict(type="text", text=text)]))["queuedSubmission"]
            except ValueError:
                # A refused add wrote nothing natively.
                rec.update(state="rejected", reason="native_add_refused")
                _journal_write(path, rec)
                result.update(state="rejected", reason="native_add_refused", submitted=False)
                return result
            if q.get("clientUserMessageId") != delivery_id:
                raise Unknown("native_receipt_mismatch")
            rec["queued_submission_id"] = q.get("id")
            _journal_write(path, rec)
            st, why, tid, prev = codex_settle(client, sid, q.get("id"), delivery_id, rec["anchor"])
            if st == "accepted":
                return _accepted(result, path, rec, sid, tid, prev, rec["anchor"], why)
            if st == "rejected":
                rec.update(state="rejected", reason=why)
                _journal_write(path, rec)
            result.update(state=st, reason=why)
            return result
        finally:
            client.close()


def _accepted(result, path, rec, sid, tid, prev, anchor, why):
    if not isinstance(tid, str) or not tid:
        raise Unknown("native_receipt_mismatch")
    receipt = dict(delivery_id=rec["delivery_id"], method="thread/queue", native_session=sid,
                   turn_id=tid, previous_turn_id=prev, anchor_turn_id=anchor,
                   intervening_turn=prev is not None and prev != anchor,
                   queued_submission_id=rec.get("queued_submission_id"),
                   accepted_at=time.time(), source="native")
    rec.update(state="accepted", reason=why, receipt=receipt)
    _journal_write(path, rec)
    result.update(state="accepted", reason=why, submitted=True, receipt=receipt)
    return result


def claude_inbox(pane, socket):
    sock = Path(launch.option(pane, "socket_path", socket)).name
    if not sock:
        raise Unknown("native_query_unavailable")
    conf = Path(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")))
    directory = conf / "global/mod-inbox" / sock / pane[1:]
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    return directory


def claude_post_accept(directory, request, wait):
    """One idle.v1 request on the pane's inbox, its fixed slot; the mod's answer.

    Not taken by the end (the .json renamed back by us, the same rename the mod
    claims with, so one side wins) = never submitted: rejected. Taken and no
    answer = unknown, settled later by its receipt; never a second post.
    """
    directory = Path(directory)
    base = directory / "idle-accept"
    with base.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(state="rejected", reason="accept_slot_busy")
        tmp = directory / ".idle-accept.tmp"
        paths = [base.with_suffix(x) for x in (".json", ".taken", ".done")]
        try:
            for path in paths:
                path.unlink(missing_ok=True)
            tmp.write_text(json.dumps(request))
            tmp.replace(paths[0])
            deadline = time.monotonic() + wait
            while time.monotonic() < deadline:
                try:
                    done = json.loads(paths[2].read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    done = None
                if done is not None:
                    if done.get("ok") is not True:
                        # The mod refuses a request only before taking its slot.
                        return dict(state="rejected", reason="mod_refused")
                    if done.get("nonce") != request["nonce"] or done.get("delivery_id") != request["delivery_id"]:
                        raise Unknown("mod_answer_mismatch")
                    return done
                time.sleep(.05)
            try:
                paths[0].rename(base.with_suffix(".cancelled"))
                return dict(state="rejected", reason="not_taken")
            except FileNotFoundError:
                raise Unknown("entry_unanswered") from None
        finally:
            for path in [tmp, *paths, base.with_suffix(".cancelled")]:
                path.unlink(missing_ok=True)


def claude_transcript(native_session):
    projects = Path(os.environ.get("FLEET_CC_PROJECTS_DIR",
                                   os.environ.get("CLAUDE_PROJECTS_DIR", str(Path.home() / ".claude/projects"))))
    hits = list(projects.glob("*/" + native_session + ".jsonl"))
    return hits[0] if len(hits) == 1 else None


def claude_receipt(directory, delivery_id, native_session):
    """(found, turn_id): the mod's durable receipt, else the turn's hidden context.

    found None = no transcript to read: never "not delivered". A context line
    with no receipt file is a delivery whose turn id is unknown.
    """
    try:
        r = json.loads((Path(directory) / ("idle-accept-%s.receipt" % delivery_id)).read_text())
        if r.get("delivery_id") == delivery_id and r.get("state") == "accepted" and r.get("turn_id"):
            return True, r["turn_id"]
    except (OSError, ValueError, AttributeError):
        pass
    t = claude_transcript(native_session)
    if t is None:
        return None, None
    try:
        with open(t, "rb") as f:
            hit = (CLAUDE_RECEIPT_PREFIX + delivery_id).encode() in f.read()
    except OSError:
        return None, None
    return (True, None) if hit else (False, None)


def _claude_accept(result, pane, expected, delivery_id, text, socket):
    ident = result["request_identity"]
    fixed = {k: v for k, v in ident.items() if k != "turn_id"}
    digest = hashlib.sha256(text.encode()).hexdigest()
    jdir = _accept_dir()
    path = jdir / (delivery_id + ".json")
    sid = ident["native_session"]
    with (jdir / (delivery_id + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rec = json.loads(path.read_text()) if path.exists() else None
        if rec is not None:
            if rec.get("identity") != fixed:
                raise Unknown("delivery_identity_changed")
            if rec.get("text_sha256") != digest:
                result.update(state="rejected", reason="delivery_id_reused")
                return result
            result["submitted"] = bool(rec.get("queued"))
            if rec.get("state") == "accepted":
                result.update(state="accepted", reason="journal", receipt=dict(rec["receipt"], source="journal"))
                return result
        directory = claude_inbox(pane, socket)
        if rec is not None and rec.get("state") == "pending":
            # Settle the earlier attempt before anything new: never a blind resend.
            found, tid = claude_receipt(directory, delivery_id, sid)
            if found and tid:
                return _claude_accepted(result, path, rec, tid, "mod_receipt")
            if found:
                result.update(state="unknown", reason="receipt_turn_unknown")
                return result
            if time.time() < rec["deadline"] + CLAUDE_ACCEPT_GRACE + CLAUDE_ACCEPT_POLL:
                result.update(state="unknown", reason="previous_attempt_unsettled")
                return result
            if found is None:
                result.update(state="unknown", reason="receipt_scan_incomplete")
                return result
            # Past its deadline the mod drops it at entry: it never ran.
            rec.update(state="rejected", reason="not_delivered")
            _journal_write(path, rec)
        if launch.option(pane, "@mod_accept", socket) != CLAUDE_ACCEPT:
            result.update(state="rejected", reason="mod_accept_unavailable")
            return result
        s = read(pane, expected=expected, socket=socket)
        if s["runtime"]["state"] != "idle":
            result.update(state="rejected", reason="precheck_" + (s["runtime"]["reason"] or s["runtime"]["state"]))
            return result
        receipt = launch.inspect({k: ident[k] for k in launch.IDENTITY}, pane, socket)
        if {k: receipt.get(k) for k in NATIVE} != {k: ident[k] for k in NATIVE}:
            raise Unknown("native_identity_changed")
        now = time.time()
        request = dict(accept=CLAUDE_ACCEPT, nonce=uuid.uuid4().hex, launch={k: ident[k] for k in launch.IDENTITY},
                       delivery_id=delivery_id, expected_turn=ident["turn_id"], text=text,
                       deadline=now + CLAUDE_ACCEPT_WINDOW)
        rec = dict(version=1, delivery_id=delivery_id, identity=fixed, text_sha256=digest,
                   anchor=ident["turn_id"], native_session=sid, state="pending", queued=True,
                   method="mod/prompt.submit", deadline=request["deadline"], created_at=now)
        _prune(jdir, now)
        _journal_write(path, rec)
        result["submitted"] = True
        done = claude_post_accept(directory, request,
                                  CLAUDE_ACCEPT_WINDOW + CLAUDE_ACCEPT_GRACE + CLAUDE_ACCEPT_POLL)
        st, why = done.get("state"), done.get("reason") or ""
        if st == "accepted" and done.get("turn_id") and done.get("previous_turn_id") == ident["turn_id"]:
            return _claude_accepted(result, path, rec, done["turn_id"], why)
        if st == "rejected":
            rec.update(state="rejected", reason=why)
            _journal_write(path, rec)
            result.update(state="rejected", reason=why, submitted=why in CLAUDE_ENTRY_DROPS)
            return result
        result.update(state="unknown", reason=why or "mod_answer_invalid")
        return result


def _claude_accepted(result, path, rec, tid, why):
    receipt = dict(delivery_id=rec["delivery_id"], method="mod/prompt.submit", native_session=rec["native_session"],
                   turn_id=tid, previous_turn_id=rec["anchor"], anchor_turn_id=rec["anchor"],
                   intervening_turn=False, queued_submission_id=None, accepted_at=time.time(), source="native")
    rec.update(state="accepted", reason=why, receipt=receipt)
    _journal_write(path, rec)
    result.update(state="accepted", reason=why, submitted=True, receipt=receipt)
    return result


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
    directory = claude_inbox(pane, socket)
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
    p.add_argument("command", choices=("read", "project", "event", "idle-accept-capability", "accept-if-idle"))
    p.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    p.add_argument("--socket", default="")
    a = p.parse_args()
    data = json.load(sys.stdin)
    if a.command in ("idle-accept-capability", "accept-if-idle"):
        s = (idle_accept_capability(data.get("provider")) if a.command == "idle-accept-capability" else
             accept_if_idle(a.pane, data.get("expected"), data.get("delivery_id"), data.get("text"), a.socket))
        print(json.dumps(s, allow_nan=False, separators=(",", ":")))
        return 0 if s.get("state") in ("available", "accepted") else 2
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
