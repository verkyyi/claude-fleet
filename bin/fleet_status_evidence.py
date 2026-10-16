#!/usr/bin/env python3
"""Display shared observations, never decide delivery or reclamation (#4504).

No scans on list refresh. `--pane` is one explicit shadow read; stdin consumes
the very same proof. The display retains source times and last-known values.
"""
import argparse
import json
import sys
import time

import fleet_reap_shadow as shadow
import fleet_runtime as runtime


def obj(value):
    return value if isinstance(value, dict) else {}


def delivery_identity(observation, now=None):
    """Use the owner's fresh reread, not the proof's own asserted identity."""
    observation = obj(observation)
    proof = obj(observation.get("proof"))
    previous = obj(proof.get("runtime"))
    current = runtime.project(observation.get("current"), expected=previous, now=now)
    if (obj(current.get("runtime")).get("state") == "unknown"
            or not shadow.exact(current.get("runtime"), previous.get("runtime"))):
        return None
    return current.get("identity")


def project(proof=None, now=None, expected_worker=None, lost=False, expected=None):
    now = time.time() if now is None else now
    p = obj(proof)
    raw = obj(p.get("runtime"))
    r = runtime.project(raw, now=now)
    identity = obj(p.get("identity"))
    valid = (p.get("version") == 1 and p.get("actionable") is False
             and shadow.complete(identity) and shadow.exact(identity, r.get("identity"))
             and shadow.complete(expected) and shadow.exact(identity, expected)
             and (not expected_worker or identity.get("worker_id") == expected_worker))
    unavailable = ("remote_unavailable" if lost else "current_binding_unavailable" if expected is None
                   else "identity_incomplete_or_changed" if not valid else "")
    rows = []

    def add(name, state, source=None, at=None, until=None, reason="", last=None, **extra):
        stale = runtime.number(until) and now >= until
        reason = ":".join(x for x in (unavailable, "expired" if stale else reason) if x)
        rows.append(dict(name=name, state="unknown" if reason else state,
                         source=source or "none", observed_at=at, expires_at=until,
                         stale=bool(stale or lost), reason=reason, last_known=last,
                         **extra))

    native = obj(r.get("runtime"))
    add("runtime", native.get("state", "unknown"), raw.get("source"), raw.get("observed_at"),
        raw.get("expires_at"), native.get("reason", ""), obj(raw.get("runtime")),
        first_thread_deadline=native.get("first_thread_deadline"))
    dims = obj(p.get("dimensions"))
    for name in ("task", "blockers", "loop", "delivery"):
        d = obj(dims.get(name))
        value = d.get("last_known")
        # Read the source validity, not the shadow's clear/retain decision: a
        # running task and a scheduled loop are valid evidence that retains.
        envelope = dict(version=1, identity=identity, source=d.get("source"),
                        observed_at=d.get("observed_at"), expires_at=d.get("expires_at"), value=value)
        check = shadow.dimension(envelope, identity, now)
        reason = check["reason"]
        if d.get("reason") not in (None, "", "unsettled_or_unknown", "blockers:blocked", "blockers:revoked"):
            reason = d["reason"]
        if name == "task":
            state = obj(value).get("outcome") or obj(value).get("state") or "unknown"
            if not shadow.task_matches(value, identity):
                reason = "task_identity_unavailable"
        elif name == "blockers":
            state = obj(d.get("projection")).get("state", "unknown")
        elif name == "delivery":
            # #4431 has not published acceptance receipts. Inbox absence and
            # native active/idle are never substitutes for that receipt.
            state, reason = "unknown", "controller_acceptance_unavailable"
        else:
            state = "pending" if value else "none" if isinstance(value, list) else "unknown"
        add(name, state, d.get("source"), d.get("observed_at"), d.get("expires_at"),
            reason, value, evidence_at=d.get("evidence_at"), projection=d.get("projection"))
    add("reap", "retained", "reap-shadow.v1" if p else "none", p.get("observed_at"),
        p.get("expires_at"), "", p.get("retained"),
        dimensions=dims, comparison=p.get("comparison", "incomparable"),
        actionable=False, permit="not-actionable:no-atomic-boundary")
    return dict(version=1, rows=rows, actionable=False)


LABELS = {"runtime": ("运行", "Runtime"), "task": ("本次任务", "Task"),
          "blockers": ("任务阻塞", "Task blockers"), "loop": ("循环计划", "Loop schedule"),
          "delivery": ("接受/投递", "Acceptance/delivery"), "reap": ("回收保留", "Reap retention")}


def lines(proof=None, now=None, expected_worker=None, lost=False, english=False, expected=None):
    out = []
    for row in project(proof, now, expected_worker, lost, expected)["rows"]:
        label = LABELS[row["name"]][int(english)]
        out.append(f'{label}: {row["state"]}' + (f' · {row["reason"]}' if row["reason"] else ""))
        out.append(f'  {row["source"]} · {row["observed_at"] if row["observed_at"] is not None else "?"}')
        if row["last_known"] is not None:
            value = row["last_known"]
            if row["name"] == "task":
                value = {k: obj(value).get(k) for k in ("state", "outcome", "updated_at")}
            elif row["name"] == "blockers":
                value = [{k: obj(x).get(k) for k in ("blocker_id", "state")} for x in obj(value).get("items", [])]
            out.append("  last-known: " + json.dumps(value, ensure_ascii=False, separators=(",", ":")))
        if row.get("first_thread_deadline") is not None:
            out.append("  first-thread deadline: " + str(row["first_thread_deadline"]))
        if row["name"] == "reap":
            out.append("  not-actionable:no-atomic-boundary")
            for name, d in obj(row.get("dimensions")).items():
                d = obj(d)
                if d.get("retained"):
                    out.append(f'  {name}: {d.get("reason", "unknown")} · {d.get("source", "none")} · {d.get("observed_at", "?")}')
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pane")
    parser.add_argument("--socket", default="")
    parser.add_argument("--text", action="store_true")
    args = parser.parse_args()
    proof = shadow.read(args.pane, socket=args.socket) if args.pane else json.load(sys.stdin)
    expected = None
    if args.pane and args.text:
        current = runtime.read(args.pane, socket=args.socket, expected=proof.get("runtime"))
        expected = delivery_identity(dict(proof=proof, current=current))
    print("\n".join(lines(proof, expected=expected))
          if args.text else json.dumps(proof, ensure_ascii=False))


if __name__ == "__main__":
    main()
