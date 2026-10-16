#!/usr/bin/env python3
"""Explicit accepted-task filing, using the existing node operation journal.

No background replay: the same dispatch retries this operation. An uncertain
GitHub create is reconciled by its marker and NEVER sent again. Authority,
generation, filing endpoint and accepted input are checked before side effects.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid

from fleet_control import SCHEMA
from fleet_dispatch import validate
from fleet_hub_common import Database, canonical

BIN = Path(__file__).absolute().parent


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=90, **kwargs)


def task_call(action, task="", payload=None):
    r = run(["bash", str(BIN / "fleet-task-record.sh"), action, task],
            input=canonical(payload) if payload is not None else None,
            env=dict(os.environ, FLEET_TASK_RECOVERY_RAW="1"))
    if r.returncode:
        raise ValueError("task authority unavailable/refused; accepted record retained")
    return r.stdout.strip() if action == "authority" else json.loads(r.stdout)


class Legacy(Exception):
    pass


class Filing:
    def __init__(self, root, authority, call=task_call, runner=run, backend="gh"):
        self.store = Database(Path(root) / "control", SCHEMA)
        self.authority, self.backend = authority.rstrip("/"), backend
        self.scope = hashlib.sha256(authority.rstrip("/").encode()).hexdigest()
        self.call, self.run = call, runner
        self.url = ""

    def save(self, key, state, url=""):
        with self.store.connect() as db:
            db.execute("UPDATE operations SET status=?,result=?,updated=? WHERE id=? AND action='task_ticket'",
                       (state, canonical(dict(url=url)), time.time(), key))

    def file(self, task, envelope, args):
        d = validate(envelope)
        current = self.call("get", task)["task"]
        if current.get("authority_version") != 1:
            raise Legacy()
        repo = args[args.index("--repo") + 1].lower()
        payload = json.loads(current["request_payload"])
        original = payload.get("dispatch", {})
        if (d.get("task") != task or current["repo"] != repo
                or (d["generation"], d["attempt_id"], d["requested_agent"], d["resolved_agent"]) !=
                (current["generation"], current["attempt_id"], current["requested_agent"], current["resolved_agent"])
                or any(d[k] != original.get(k) for k in ("request_id", "agent_source", "requested_agent", "resolved_agent"))):
            raise ValueError("filing differs from accepted task/repo/provider/generation")
        body_path = Path(args[args.index("--body-file") + 1])
        body = body_path.read_text()
        # Persist only a digest of the filing input, never credentials or words.
        stable_args = list(args)
        stable_args[stable_args.index("--body-file") + 1] = body
        digest = hashlib.sha256(canonical(stable_args).encode()).hexdigest()
        key = str(uuid.uuid5(uuid.NAMESPACE_URL, canonical([self.scope, task, d["generation"]])))
        request = dict(scope=self.scope, task=task, generation=d["generation"], digest=digest)
        marker = "<!-- fleet:task-ticket v=1 key=%s -->" % key
        with (self.store.root / ("ticket-" + key + ".lock")).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                row = db.execute("SELECT * FROM operations WHERE id=?", (key,)).fetchone()
                if row is None:
                    filing_id = str(uuid.uuid4())
                    db.execute("INSERT INTO operations VALUES (?,'','task_ticket',?,?,'ready',?,?,NULL)",
                               (key, canonical(dict(request, filing_id=filing_id)), current["owner"], time.time(), time.time()))
                    state = "ready"
                else:
                    saved = json.loads(row["request"])
                    filing_id = saved.pop("filing_id", "")
                    if row["action"] != "task_ticket" or saved != request or row["actor"] != current["owner"] or not filing_id:
                        raise ValueError("filing input changed; use the original dispatch")
                    state = row["status"]
                    self.url = json.loads(row["result"] or "{}").get("url", "")
            if state == "linked":
                if current.get("ticket_ref") != self.ref(repo, self.url):
                    raise ValueError("linked ticket no longer matches authority")
                return self.url
            if current.get("state") != "accepted" or current.get("execution_owner") or current.get("cancel_request"):
                raise ValueError("late filing refused: task already started/cancelled; no lease or identity backfill")
            mutation = dict(generation=d["generation"], expected_worker="", filing_id=filing_id)
            self.call("mutate", task, dict(mutation, kind="ticket_prepare", idempotency_key="ticket-file:g%d" % d["generation"]))
            if not self.url:
                if state == "sending":
                    # A bounded search includes closed issues. Miss, exhausted
                    # budget, outage and ambiguity ALL retain unknown; none can
                    # authorize a second create. A fresh/rejected send needs no
                    # search: the pinned filing incarnation proves its state.
                    found = self.run(["bash", str(BIN / "fleet-ticket.sh"), "find", "--repo", repo, "--marker", marker, "--all"])
                    if found.returncode != 0:
                        raise ValueError("RECONCILIATION_REQUIRED: create acknowledgement unknown; lookup absent/incomplete; no second create")
                    fields = found.stdout.strip().split("\t")
                    if len(fields) != 2 or self.ref(repo, fields[1]) != fields[0]:
                        raise ValueError("invalid ticket reconciliation response")
                    self.url = fields[1]
                elif state in ("ready", "retry"):
                    # This read cannot create a ticket. A refused/unavailable
                    # preflight leaves the journal unsent, so a later natural
                    # quota recovery can retry the same dispatch safely.
                    if self.backend == "gh":
                        ready = self.run(["bash", str(BIN / "fleet-ticket.sh"), "create-ready", "--repo", repo])
                        if ready.returncode:
                            raise ValueError("ticket create not sent: quota preflight unavailable/exhausted; retry the same dispatch")
                    self.save(key, "sending")  # durable BEFORE sending to GitHub
                    with tempfile.TemporaryDirectory(prefix="fleet-task-ticket-") as tmp:
                        capture = Path(tmp) / "body"
                        capture.write_text(body + "\n\n" + marker)
                        create_args = list(args)
                        create_args[create_args.index("--body-file") + 1] = str(capture)
                        result = self.run(["bash", str(BIN / "fleet-ticket.sh"), "new", "--filed", "--once", *create_args])
                    if result.returncode:
                        # Once handed to the writer, ALL errors are uncertain,
                        # even a URL/partial success followed by rate-limit text.
                        # Only marker reconciliation can recover this send.
                        raise ValueError("accepted task retained; ticket create failed/unknown; retry the same dispatch")
                    self.url = result.stdout.strip()
                else:
                    raise ValueError("unknown filing journal state; reconciliation required")
                self.ref(repo, self.url)
                self.save(key, "created", self.url)
            self.call("mutate", task, dict(mutation, kind="ticket_link", idempotency_key="ticket-link:g%d" % d["generation"],
                                           ticket_ref=self.ref(repo, self.url)))
            self.save(key, "linked", self.url)
            print("fleet-task-ticket: %s accepted; ticket created and associated; native start not yet confirmed" % task, file=sys.stderr)
            return self.url

    def ref(self, repo, url):
        if self.backend == "hub":
            match = re.fullmatch(re.escape(self.authority + "/fleet/tickets/" + repo + "/") + r"([1-9][0-9]*)", url)
            if not match:
                raise ValueError("hub ticket URL does not match accepted authority/repo")
            return "hub:%s#%s" % (repo, match[1])
        match = re.fullmatch(r"https://github\.com/([^/]+/[^/]+)/issues/([1-9][0-9]*)", url)
        if not match or match[1].lower() != repo:
            raise ValueError("ticket URL does not match accepted repo")
        return "gh:%s#%s" % (repo, match[2])


def main():
    filing = None
    try:
        task, backend, *args = sys.argv[1:]
        t = task_call("get", task)["task"]
        if t.get("id") != task or t.get("authority_version", 0) not in (0, 1):
            raise ValueError("task identity/authority version unavailable")
        if t.get("authority_version", 0) == 0:
            if json.loads(os.environ.get("FLEET_DISPATCH", "{}") or "{}").get("task"):
                raise ValueError("accepted dispatch cannot adopt a legacy task")
            return 3  # legacy filer remains byte for byte compatible
        if backend not in ("gh", "hub"):
            raise ValueError("unknown ticket backend")
        filing = Filing(os.environ.get("FLEET_CONF_DIR", str(Path.home() / ".config/claude-fleet")), task_call("authority"), backend=backend)
        print(filing.file(task, json.loads(os.environ.get("FLEET_DISPATCH", "{}")), args))
        return 0
    except Legacy:
        return 3
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        if filing and filing.url:
            print(filing.url)
        print("fleet-task-ticket: " + str(exc) + "; association/start incomplete", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
