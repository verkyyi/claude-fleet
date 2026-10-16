#!/usr/bin/env python3
"""Read-only reap comparison. No caller may turn this observation into a permit.

Sources retain their own timestamps; missing adapters retain the session. This
module is deliberately absent from cleanup/stop/retire control paths. Evidence
bundles and output contain private identities and must stay outside git/issues.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import fleet_launch as launch
import fleet_pending_tool as pending
import fleet_runtime as runtime
import fleet_task_control as tasks
import fleet_reap_policy as policy
from fleet_task_recovery import raw_call

TTL = runtime.TTL
DIMENSIONS = ("task", "report", "pending_tool", "children", "processes", "loop",
              "delivery", "transfer", "migration", "wake", "worktree", "draft",
              "outbox", "policy", "grace")
LISTS = ("loop", "delivery", "transfer", "migration", "wake", "outbox")
TERMINAL = ("succeeded", "failed", "cancelled", "refused")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


def exact(a, b):
    try:
        return digest(a) == digest(b)
    except (TypeError, ValueError):
        return False


def complete(identity):
    try:
        c = {k: identity[k] for k in launch.IDENTITY}
        launch.check_receipt(c, dict(identity, actual_provider=identity["provider"]))
        return isinstance(identity.get("turn_id"), str) and bool(identity["turn_id"])
    except (TypeError, KeyError, ValueError):
        return False


def dimension(evidence, identity, now):
    """Do not renew a stale/invalid source or discard its last-known value."""
    e = evidence if isinstance(evidence, dict) else {}
    d = dict(source=e.get("source", "none"), observed_at=e.get("observed_at"),
             expires_at=e.get("expires_at"), evidence_at=e.get("evidence_at"),
             raw_evidence=copy.deepcopy(e.get("raw_evidence")),
             last_known=copy.deepcopy(e.get("value")),
             retained=True, reason="missing_evidence")
    if not e:
        return d
    if type(e.get("version")) is not int or e["version"] != 1 or not isinstance(d["source"], str) or not d["source"]:
        d["reason"] = "unsupported_evidence"
    elif not complete(identity) or not exact(e.get("identity"), identity):
        d["reason"] = "identity_incomplete_or_changed"
    elif (not all(runtime.number(e.get(k)) for k in ("observed_at", "expires_at"))
          or not 0 < e["expires_at"] - e["observed_at"] <= TTL):
        d["reason"] = "invalid_evidence_time"
    elif now < e["observed_at"]:
        d["reason"] = "clock_regressed"
    elif now >= e["expires_at"]:
        d["reason"] = "expired"
    elif e.get("unknown") or e.get("stale"):
        d["reason"] = e.get("reason") or "source_unknown"
    else:
        d.update(retained=False, reason="")
    return d


def task_matches(t, i):
    return (isinstance(t, dict) and type(t.get("authority_version")) is int and t["authority_version"] == 1
            and type(t.get("generation")) is int and not t.get("_stale")
            and all(t.get(k) == i.get(v) for k, v in
                    (("id", "task"), ("owner", "owner"), ("generation", "generation"),
                     ("execution_owner", "worker_id"), ("resolved_agent", "provider"),
                     ("operation_id", "operation_id"), ("attempt_id", "attempt_id"))))


def clear(name, value, identity, now):
    if name == "task":
        return task_matches(value, identity) and value.get("outcome") in TERMINAL
    if name == "report":
        return (isinstance(value, dict) and value.get("durable") is True
                and value.get("disposition") == "committed" and value.get("outcome") in TERMINAL
                and isinstance(value.get("event_id"), str) and bool(value["event_id"])
                and all(value.get(k) == identity.get(k) for k in ("task", "owner", "generation", "worker_id")))
    if name in LISTS:
        # Only an explicit complete empty set clears; unknown/nonterminal child
        # filtering belongs to the existing children reader, never name guessing.
        return isinstance(value, list) and not value
    if name == "children":
        return (isinstance(value, dict) and value.get("parent") == identity.get("task")
                and value.get("parent_session") == identity.get("worker_id")
                and type(value.get("parent_generation")) is int
                and value["parent_generation"] == identity.get("generation")
                and isinstance(value.get("children"), list) and not value["children"])
    if name == "pending_tool":
        return isinstance(value, dict) and type(value.get("code")) is int and value["code"] == 1
    if name == "processes":
        return (isinstance(value, dict) and value.get("complete") is True
                and value.get("pending") == [] and value.get("unknown") == []
                and isinstance(value.get("fingerprint"), str) and bool(value["fingerprint"]))
    if name == "worktree":
        return isinstance(value, dict) and value.get("clean") is True and value.get("unpushed") is False
    if name == "draft":
        return value == ""
    if name == "policy":
        parsed = policy.parse(value.get("value")) if isinstance(value, dict) and isinstance(value.get("value"), str) else None
        return parsed is not None and parsed[0] != "keep" and value.get("satisfied") is True
    if name == "grace":
        return isinstance(value, dict) and runtime.number(value.get("deadline")) and value["deadline"] <= now
    return False


def project(bundle, now=None):
    now = time.time() if now is None else now
    bundle = bundle if isinstance(bundle, dict) else {}
    raw = bundle.get("runtime")
    r = runtime.project(raw, now=now)
    identity = r.get("identity", {})
    layers = bundle.get("layers")
    layers = layers if isinstance(layers, dict) else {}
    dims = {}
    original = raw if isinstance(raw, dict) else {}
    rd = dimension(dict(version=original.get("version"), identity=original.get("identity"), source=original.get("source"),
                        observed_at=original.get("observed_at"), expires_at=original.get("expires_at"),
                        value=original.get("runtime")), identity, now)
    if r["runtime"].get("state") != "idle":
        rd.update(retained=True, reason=r["runtime"].get("reason") or r["runtime"].get("state", "unknown"))
    dims["runtime"] = rd
    for name in DIMENSIONS:
        d = dimension(layers.get(name), identity, now)
        if not d["retained"] and not clear(name, d["last_known"], identity, now):
            value = d["last_known"]
            d.update(retained=True, reason=(value.get("reason") if isinstance(value, dict) else None) or "unsettled_or_unknown")
        dims[name] = d
    t = dims["task"]["last_known"]
    bp = tasks.blocker_projection(t, stale=bool(dimension(layers.get("task"), identity, now)["retained"] or not task_matches(t, identity)))
    dims["blockers"] = dict(dims["task"], last_known=t.get("task_blockers") if isinstance(t, dict) else None,
                            projection=bp, retained=bp["state"] != "clear",
                            reason="" if bp["state"] == "clear" else "blockers:" + bp["state"])
    report = dims["report"]["last_known"]
    if not dims["report"]["retained"] and (not isinstance(t, dict) or report["outcome"] != t.get("outcome")):
        dims["report"].update(retained=True, reason="outcome_mismatch")
    retained = [k for k, d in dims.items() if d["retained"]]
    legacy = dimension(bundle.get("legacy"), identity, now)
    v = legacy["last_known"]
    comparable = not legacy["retained"] and isinstance(v, dict) and type(v.get("eligible")) is bool
    candidate = not retained
    comparison = ("agree" if v["eligible"] == candidate else
                  "legacy-clear_candidate-retain" if v["eligible"] else "legacy-retain_candidate-clear") if comparable else "incomparable"
    # Fingerprint semantic evidence, including raw identities, values, source
    # times and revisions. Any refreshed evidence requires a new proof.
    try:
        fingerprint = digest(bundle)
    except (TypeError, ValueError):
        fingerprint = None
        candidate = False
        retained.append("invalid_bundle")
        comparison = "incomparable"
    expiries = [d["expires_at"] for d in dims.values() if runtime.number(d["expires_at"])]
    if runtime.number(legacy["expires_at"]):
        expiries.append(legacy["expires_at"])
    return dict(version=1, identity=copy.deepcopy(identity), observed_at=now,
                expires_at=min([now + TTL] + expiries), runtime=r, dimensions=dims,
                legacy=legacy, comparison=comparison, candidate_clear=candidate,
                retained=retained, fingerprint=fingerprint, actionable=False,
                reason="not-actionable:no-atomic-boundary")


def recheck(previous, fresh, now=None):
    """Final-action prerequisite only. Two reads never form an atomic permit."""
    now = time.time() if now is None else now
    p = project(fresh, now=now)
    previous = previous if isinstance(previous, dict) else {}
    p["previous_valid"] = bool(previous.get("version") == 1 and p["fingerprint"]
        and p["comparison"] != "incomparable" and previous.get("comparison") != "incomparable"
        and previous.get("fingerprint") == p["fingerprint"] and p["identity"] == previous.get("identity")
        and complete(p["identity"]) and runtime.number(previous.get("observed_at"))
        and runtime.number(previous.get("expires_at"))
        and previous["observed_at"] <= now < previous["expires_at"])
    # A disconnected fresh read may have no value. Preserve the previous value
    # strictly as rejected history, never a renewed observation or clear gate.
    old_dimensions = previous.get("dimensions", {})
    if isinstance(old_dimensions, dict):
        for name, d in p["dimensions"].items():
            old = old_dimensions.get(name)
            if d["retained"] and d["last_known"] is None and isinstance(old, dict):
                d["previous_evidence"] = {k: copy.deepcopy(old.get(k)) for k in
                    ("source", "observed_at", "expires_at", "evidence_at", "last_known")}
    return p


def authority_reader(action):
    """GET through C6's existing raw transport; no local cache mutation."""
    def reader(identity):
        if not complete(identity):
            return None
        at = time.time()
        data = raw_call(action, identity["task"], timeout=3)
        return dict(version=1, identity=identity, source="task-authority:" + action,
                    observed_at=at, expires_at=at + TTL,
                    stale=data.get("stale", False), value=data.get("task") if action == "get" else data)
    return reader


def report_reader(database, authority_scope):
    """Read the EXISTING C6 journal, without Journal()'s schema/expiry/ack writes.

    The caller supplies C6's authority hash, never a guessed hub. A source result
    and parent delivery are distinct: unresolved delivery still holds outbox.
    Old terminal rows are re-observed, preserving their original commit time.
    """
    def reader(identity):
        at = time.time()
        matches = []
        uri = Path(database).resolve().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=1) as db:
            rows = db.execute("SELECT request,result,status,updated FROM operations WHERE action='task_receipt'").fetchall()
        for request, result, status, updated in rows:
            req, res = json.loads(request), json.loads(result or "{}")
            payload = req.get("payload", {})
            receipt = res.get("receipt", {})
            if (req.get("scope") != authority_scope or req.get("action") != "report"
                    or req.get("task") != identity.get("task")
                    or not all(exact(payload.get(k), identity.get(k)) for k in ("task", "owner", "generation", "worker_id"))
                    or payload.get("outcome") not in TERMINAL):
                continue
            matches.append(dict({k: payload.get(k) for k in ("task", "owner", "generation", "worker_id", "outcome", "event_id")},
                                disposition=receipt.get("disposition"),
                                durable=status in ("committed", "succeeded"), journal_status=status,
                                committed_at=updated))
        value = matches[0] if len(matches) == 1 else None
        return dict(version=1, identity=identity, source="C6:task_receipt",
                    observed_at=at, expires_at=at + TTL,
                    evidence_at=value.get("committed_at") if value else None,
                    value=value, unknown=value is None, reason="missing_or_ambiguous_receipt")
    return reader


def read(pane, socket="", readers=None, legacy_reader=None, pr=None):
    """One explicit collection; no polling, writes, cached provider or new probe.

    Reader callbacks consume a frozen runtime identity and return source-owned
    evidence envelopes. There are intentionally no default clear values for
    controller/lease/report/process/worktree dimensions. Missing owner adapters
    are visible retained evidence, not a guessed absence. The pending-tool oracle
    supports Claude; its unsupported Codex result is retained too.
    """
    r = runtime.read(pane, socket=socket)
    i = r.get("identity", {})
    layers = {}
    sources = dict(task=authority_reader("get"), children=authority_reader("children"))
    try:
        from fleet_reap_shadow_local import LocalSources
        local = LocalSources(pane,socket,pr=pr)
        sources.update(local.readers())
        if legacy_reader is None:
            legacy_reader = local.legacy
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        pass  # remote/unknown socket or binding remains unavailable per dimension
    sources.update(readers or {})
    for name, reader in sources.items():
        if name not in DIMENSIONS or name == "pending_tool":
            raise ValueError("unsupported/owned reader: " + name)
        try:
            layers[name] = reader(copy.deepcopy(i))
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError):
            layers[name] = dict(unknown=True, reason="reader_failed", source=name)
    try:
        observations = pending.observe(lambda: [row for row in pending.read_panes(socket) if row["pane"] == pane])
        if len(observations) == 1:
            o = observations[0]
            pi = o.get("identity") or {}
            native = pi.get("native") or {}
            matched = (pi.get("worker") == i.get("worker_id", "").split("/")[-1]
                       and pi.get("sid") == i.get("native_session")
                       and all(native.get(k) == i.get(k) for k in ("pid", "birth", "executable")))
            layers["pending_tool"] = dict(version=1, identity=i, source="fleet_pending_tool.observe",
                observed_at=o["observed_at"], expires_at=o["expires_at"], value=o,
                unknown=not matched or o["code"] == 4, reason=o["reason"] if matched else "pending_identity_unavailable")
    except pending.ERRORS:
        pass  # missing remains unknown, never no_pending
    legacy = None
    if legacy_reader is not None:
        try:
            legacy = legacy_reader(copy.deepcopy(i))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            pass
    after = runtime.read(pane, expected=r, socket=socket)
    if after.get("identity") != i or after["runtime"] != r["runtime"]:
        r = runtime.unknown(copy.deepcopy(r), "changed_during_shadow_read")
    return project(dict(runtime=r, layers=layers, legacy=legacy))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pane", help="explicit pane; absent reads a private evidence bundle on stdin")
    parser.add_argument("--socket", default="")
    parser.add_argument("--pr", type=int, help="explicit PR for the existing merged/closed dry-run gate")
    parser.add_argument("--previous", help="private previous proof; recheck only, never execute")
    a = parser.parse_args()
    if a.pane:
        if a.previous:
            parser.error("recheck requires a fresh full evidence bundle on stdin")
        result = read(a.pane, a.socket, pr=a.pr)
    else:
        bundle = json.load(sys.stdin)
        if a.previous:
            with open(a.previous) as f:
                result = recheck(json.load(f), bundle)
        else:
            result = project(bundle)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))
    return 0  # observation succeeded, NOT an action exit code


if __name__ == "__main__":
    sys.exit(main())
