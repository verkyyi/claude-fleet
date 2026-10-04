"""Versioned JSON bridge. Invoked locally or as a fixed command over SSH."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import threading
import uuid

from fleet_config_write import revision, write
from fleet_hub_common import (CONFIG_KEYS, GH_READS, PROTOCOL, WORKER_ACTIONS, Database, Fault,
                              canonical, fields, identifier, name, now, operation,
                              parse_worker_id, read_request, repo_named, run, tool_path, validate_gh_read,
                              validate_write, worker_identity, worker_key)

BIN = Path(__file__).absolute().parent
SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS operations (
 id TEXT PRIMARY KEY, fleet_id TEXT NOT NULL, action TEXT NOT NULL,
 request TEXT NOT NULL, actor TEXT NOT NULL, status TEXT NOT NULL,
 created REAL NOT NULL, updated REAL NOT NULL, result TEXT);
"""


class Unattempted(Fault):
    """A refusal raised before any side effect was attempted: always `failed`."""


class Control:
    def __init__(self, conf_dir=None, bin_dir=BIN):
        self.conf_dir = Path(conf_dir or os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet")).absolute()
        self.bin = Path(bin_dir).absolute()
        self.store = Database(self.conf_dir / "control", SCHEMA)
        with self.store.connect() as db:
            db.execute("INSERT OR IGNORE INTO metadata VALUES ('machine_id', ?)", (str(uuid.uuid4()),))
            self.machine_id = db.execute("SELECT value FROM metadata WHERE key='machine_id'").fetchone()[0]

    def environment(self):
        # The remote administrator controls the installation/config, not MCP
        # arguments or a calling worker's inherited Fleet overrides.
        allowed = ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SSH_AUTH_SOCK")
        env = {key: os.environ[key] for key in allowed if key in os.environ}
        # PATH is inherited but never trusted to be whole (issue #1460): a launchd
        # job — ccquota's agent reading fleet_status for its heartbeat — runs us
        # under /usr/bin:/bin:/usr/sbin:/sbin, where a Homebrew tmux is not, and
        # the adapter died `tmux: command not found` (UNAVAILABLE: 0 sessions on
        # the hub for a fleet of 22). Complete it with the dirs the SSH forced
        # command exports; a whole PATH passes through unchanged.
        env["PATH"] = tool_path(env.get("PATH"), env.get("HOME"))
        env["FLEET_CONF_DIR"] = str(self.conf_dir)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env

    def adapter(self, mode, *args, timeout=20, payload=None):
        return run(["bash", str(self.bin / "fleet-control-read.sh"), mode, *args],
                   payload=payload, env=self.environment(), timeout=timeout)

    def inventory(self):
        code, output, _ = self.adapter("inventory")
        if code:
            raise Fault("UNAVAILABLE", "Cannot enumerate configured fleets")
        parts = output.decode("utf-8").split("\0")
        if parts.pop() != "" or len(parts) % 5:
            raise Fault("PROTOCOL_ERROR", "Invalid local fleet inventory")
        fleets = []
        for i in range(0, len(parts), 5):
            session, repo, checkout, agent, config = parts[i:i + 5]
            name(session)
            fleet_id = str(uuid.uuid5(uuid.UUID(self.machine_id), canonical([session, repo, checkout])))
            fleets.append(dict(fleet_id=fleet_id, machine_id=self.machine_id, name=session,
                               repo=repo, checkout=checkout, agent=agent, config_path=config))
        return fleets

    def ready(self):
        """Can this login take a NEW session (issue #1475)? The adapter's `ready`
        verdict — gh login, a usable credential, every checkout — as one object:
        {"ready": bool, "gh": bool, "creds": bool, "checkouts": bool, "missing": [...]}.
        The node agent puts it in its heartbeat; the hub's auto placement skips a
        login that says no."""
        code, output, _ = self.adapter("ready")
        if code:
            raise Fault("UNAVAILABLE", "Cannot judge readiness")
        try:
            verdict = json.loads(output.decode("utf-8"))
        except ValueError:
            raise Fault("PROTOCOL_ERROR", "Invalid readiness verdict")
        if not isinstance(verdict, dict) or not isinstance(verdict.get("ready"), bool) \
                or not isinstance(verdict.get("missing"), list):
            raise Fault("PROTOCOL_ERROR", "Invalid readiness verdict")
        return dict(ready=verdict["ready"], gh=bool(verdict.get("gh")), creds=bool(verdict.get("creds")),
                    checkouts=bool(verdict.get("checkouts")),
                    missing=[str(m) for m in verdict["missing"]], observed_at=now())

    def fleet(self, fleet_id):
        identifier(fleet_id)
        for fleet in self.inventory():
            if fleet["fleet_id"] == fleet_id:
                return fleet
        raise Fault("NOT_FOUND", "Fleet is no longer configured on this machine")

    def workers(self, fleet):
        code, output, err = self.adapter("workers", fleet["name"])
        if code == 3:
            return {"state": "down", "workers": [], "observed_at": now()}
        if code:
            # The adapter's last stderr line rides along (issue #1460): `tmux:
            # command not found` is the whole diagnosis, and without it the fault
            # read the same as a wedged server for a day.
            detail = [l for l in err.decode("utf-8", "replace").splitlines() if l.strip()]
            raise Fault("UNAVAILABLE", "Cannot read fleet windows" + (": " + detail[-1].strip()[-200:] if detail else ""))
        workers = []
        for line in output.decode("utf-8").splitlines():
            parts = line.split("\t")
            # Columns 10-12 (issues #1423, #1475): the window name, its @origin_wid
            # and what it needs of its person (@claude_needs), so a remote sidebar
            # can label the row, nest it under its parent and draw its red `?`.
            # Optional — a 9-column adapter is still whole — and the name absorbs
            # any tab of its own, so an odd window name can never make the
            # inventory unreadable (the adapter ships beside this file, so the
            # last two columns are always needs and origin_wid).
            extra = {}
            if len(parts) >= 12:
                extra = dict(name=" ".join(parts[9:-2]), origin_wid=parts[-2] or None, needs=parts[-1] or None)
                parts = parts[:9]
            elif len(parts) >= 10:
                # the #1423 shape (name, origin_wid), from an adapter older than #1475
                extra = dict(name=" ".join(parts[9:-1]) if len(parts) > 10 else parts[9],
                             origin_wid=(parts[-1] or None) if len(parts) > 10 else None)
                parts = parts[:9]
            if len(parts) != 9 or not re.fullmatch(r"@[0-9]+", parts[0]):
                raise Fault("PROTOCOL_ERROR", "Invalid worker inventory")
            window, issue, scratch, worktree, state, agent, handle, lifecycle, repo = parts
            if not issue and scratch != "1":
                continue
            number = int(issue) if issue.isdigit() and int(issue) > 0 else None
            # repo: empty = a one-repo fleet (its keys stay bare); else the
            # window's own repo, which a multi-repo key carries (issue #1018).
            key = worker_key(number, scratch == "1", worktree, repo)
            # worker_id is the durable identity (issue #834); window_id and handle
            # are observations of where it lives right now.
            workers.append(dict(worker_id=worker_identity(fleet["fleet_id"], key), key=key,
                                window_id=window, issue=number,
                                repo=repo if repo and repo != "?" else (None if repo else fleet.get("repo")),
                                scratch=scratch == "1", worktree=worktree, state=state or "unknown",
                                lifecycle=lifecycle or "awake",
                                agent=agent or fleet["agent"], handle=handle, **extra))
        return {"state": "running", "workers": workers, "observed_at": now()}

    def find_workers(self, fleet, key):
        """Windows holding `key`. A bare key in a multi-repo fleet matches every
        repo's (issue #1018) — so two of them resolve as AMBIGUOUS, never a pick."""
        snapshot = self.workers(fleet)
        return [w for w in snapshot["workers"] if w["key"] == key
                or (":" not in key and (w["key"] or "").endswith(":" + key))], snapshot

    def target(self, fleet, key, action):
        """Resolve a durable key to exactly one live window, or raise. The
        window is re-resolved here, at action time; a caller never names one."""
        matches, snapshot = self.find_workers(fleet, key)
        if not matches:
            raise Fault("NOT_FOUND", "No live worker holds this identity on the fleet")
        if len(matches) > 1 and action != "worker_message":
            raise Fault("AMBIGUOUS", "Several live windows hold this identity; resolve them on the fleet first")
        return matches, snapshot

    def config(self, fleet):
        path = Path(fleet["config_path"])
        # Do not pair a new revision with values read from an older file.
        before = revision(path)
        code, output, _ = self.adapter("config", fleet["name"])
        after = revision(path)
        if before != after:
            raise Fault("REVISION_CONFLICT", "Configuration changed while reading; retry")
        parts = output.decode("utf-8").split("\0")
        if code or len(parts) != 4 or parts[-1] or not all(x.isdigit() for x in parts[:-1]):
            raise Fault("INVALID_STATE", "Managed configuration values must be integers")
        return dict(values=dict(zip(CONFIG_KEYS, map(int, parts[:-1]))), revision=after,
                    revision_scope="fleet_overlay", observed_at=now())

    def gh_read(self, fleet, kind, params):
        """One issue / PR / PR's checks via fleet-gh.sh: the daemons' local copy
        when fresh (`_source: cache`), else gh, else REST — same JSON object,
        `_source` / `_age` included (issue #1274)."""
        code, output, err = self.adapter("gh", fleet["name"], kind, str(params["number"]),
                                         params.get("repo", ""), params.get("fields", ""))
        if code == 6:
            raise Fault("INVALID_ARGUMENT", "Name a repo this fleet hosts (owner/name)")
        if code == 2:
            raise Fault("INVALID_ARGUMENT", "GitHub read refused: " + last_line(err))
        if code:
            raise Fault("UNAVAILABLE", "GitHub read failed: " + last_line(err))
        try:
            result = json.loads(output)
        except (ValueError, UnicodeError) as exc:
            raise Fault("PROTOCOL_ERROR", "GitHub read returned no JSON object") from exc
        if not isinstance(result, dict):
            raise Fault("PROTOCOL_ERROR", "GitHub read returned no JSON object")
        return result

    def get_operation(self, op_id):
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (identifier(op_id),)).fetchone()
        if row is None:
            raise Fault("NOT_FOUND", "Operation has not been accepted by this machine")
        result = operation(row)
        if row["status"] in ("accepted", "running") and now() - row["updated"] > 240:
            result["status"] = "unknown"
        return result

    def submit(self, request):
        fields(request, ("operation_id", "fleet_id", "action", "params", "actor"))
        op_id, fleet_id = identifier(request["operation_id"]), identifier(request["fleet_id"])
        validate_write(request["action"], request["params"])
        if not isinstance(request["actor"], str) or not 1 <= len(request["actor"]) <= 200:
            raise Fault("INVALID_ARGUMENT", "Invalid audit actor")
        encoded = canonical(request)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT * FROM operations WHERE id=?", (op_id,)).fetchone()
            if old:
                if old["request"] != encoded:
                    raise Fault("IDEMPOTENCY_CONFLICT", "Operation ID was used for a different request")
                return self.get_operation(op_id)
            self.fleet(fleet_id)
            timestamp = now()
            db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)",
                       (op_id, fleet_id, request["action"], encoded, request["actor"], "accepted", timestamp, timestamp))
        # Commit acceptance BEFORE launching. The detached executor survives an
        # SSH disconnect. A crash in this gap stays accepted/unknown, never
        # silently re-executes a potentially completed side effect.
        try:
            with open(os.devnull, "wb") as sink:
                process = subprocess.Popen([sys.executable, str(self.bin / "fleet-control.py"),
                                            "--conf-dir", str(self.conf_dir), "execute", op_id],
                                           stdin=subprocess.DEVNULL, stdout=sink, stderr=sink,
                                           env=self.environment(), start_new_session=True, close_fds=True)
                # Reap while this process lives; the detached child is adopted
                # normally if an SSH request process exits first.
                threading.Thread(target=process.wait, daemon=True).start()
        except OSError:
            self.finish(op_id, "failed", {"error": {"code": "UNAVAILABLE", "message": "Cannot start executor"}})
        return self.get_operation(op_id)

    def finish(self, op_id, state, result):
        with self.store.connect() as db:
            db.execute("UPDATE operations SET status=?,result=?,updated=? WHERE id=?",
                       (state, canonical(result), now(), op_id))

    def execute_worker(self, fleet, action, params, actor=""):
        """Lifecycle tools on a durable worker identity. Every refusal before the
        adapter runs raises Unattempted (a clean `failed`); anything after it
        is `unknown` unless the post-condition was observed. `actor` is the
        journal's actor — who decided — handed to the one tool whose effect is a
        human's call (worker_answer)."""
        fleet_id, key = parse_worker_id(params["worker_id"])
        if fleet_id != fleet["fleet_id"]:
            raise Unattempted("INVALID_ARGUMENT", "worker_id belongs to a different fleet")
        if action == "worker_answer":
            return self.execute_answer(fleet, key, params["answer"], actor)
        if action == "worker_reap":
            return self.execute_reap(fleet, key)
        if action == "worker_message":
            if not key.rsplit(":", 1)[-1].startswith("issue-"):
                raise Unattempted("INVALID_ARGUMENT", "A scratch session has no issue channel to message")
            matches, _ = self.target(fleet, key, action)
            # A repo-qualified key goes whole: the adapter resolves its repo (#1018).
            code, output, err = self.adapter("message", fleet["name"], key if ":" in key else key[len("issue-"):],
                                             payload=params["text"].encode("utf-8"), timeout=60)
            if code == 5:
                raise Unattempted("UNAVAILABLE", "The issue bridge is not enabled on this fleet")
            if code == 2:
                raise Unattempted("EXECUTION_FAILED", "Fleet refused the message; inspect local Fleet logs")
            if code:
                raise Fault("UNKNOWN_OUTCOME", "Comment post did not confirm; inspect the issue before retrying")
            return {"channel": "issue-bridge", "comment_url": output.decode("utf-8").strip(),
                    "delivery": "relayed by the fleet's issue bridge on its next idle tick",
                    "workers": matches, "observed_at": now()}
        if action == "worker_stop":
            matches, _ = self.target(fleet, key, action)
            if matches[0]["lifecycle"] != "awake":
                raise Unattempted("INVALID_STATE", "Worker is hibernating; wake it on the fleet before stopping it")
            code, output, err = self.adapter("stop", fleet["name"], key, timeout=120)
            token = output.decode("utf-8").strip().splitlines()[-1:] or [""]
            if code in (5, 6, 8):
                raise Unattempted({5: "NOT_FOUND", 6: "AMBIGUOUS", 8: "INVALID_STATE"}[code],
                                  "Stop refused on the fleet: " + token[0])
            if code:
                raise Fault("UNKNOWN_OUTCOME", "Worker did not confirm its exit: " + token[0])
            remaining, snapshot = self.find_workers(fleet, key)
            if remaining:
                raise Fault("UNKNOWN_OUTCOME", "A window still holds this identity after the stop")
            return {"stopped": matches[0], "how": token[0],
                    "kept": "worktree, branch and issue are untouched; the session is resumable",
                    "observed_at": snapshot["observed_at"]}
        # worker_resume
        matches, _ = self.find_workers(fleet, key)
        if matches:
            raise Unattempted("ALREADY_RUNNING", "A live window already holds this identity")
        code, output, err = self.adapter("resume", fleet["name"], key, timeout=180)
        if code in (2, 4, 5):
            raise Unattempted({2: "AT_CAPACITY", 4: "RESOURCE_GATE", 5: "NOT_RESUMABLE"}[code],
                              "Fleet refused to resume the worker; inspect local Fleet logs")
        if code:
            raise Fault("UNKNOWN_OUTCOME", "Restore returned an error after starting; inspect the fleet")
        matches, snapshot = self.find_workers(fleet, key)
        if not matches:
            raise Fault("UNKNOWN_OUTCOME", "Restore returned but no matching worker is visible")
        return {"workers": matches, "observed_at": snapshot["observed_at"]}

    # The two answer scripts' exit codes, both the same shape (fleet-answer.sh /
    # fleet-permission.sh headers): 1 nothing pending or no usable pane, 2 a
    # malformed pick, 3 refused at a screen gate with nothing sent, 5 a Yes/No
    # without a named human. Every one of them left the pane untouched, so each
    # is a clean `failed`; 4 = keys were sent but the transcript never confirmed.
    ANSWER_REFUSALS = {1: "INVALID_STATE", 2: "INVALID_ARGUMENT", 3: "INVALID_STATE", 5: "FORBIDDEN"}

    def execute_answer(self, fleet, key, answer, actor):
        """worker_answer (issue #1487): answer the open prompt of the one live
        window holding `key` — `yes` / `no` on a permission prompt through
        fleet-permission.sh (--allow / --deny, in the name of `actor`), option
        numbers on an AskUserQuestion through fleet-answer.sh. The scripts' own
        gates decide: the transcript must show a pending prompt, the screen must
        show the row, and the verdict is the transcript's tool_result. A refusal
        comes back verbatim — its last stderr line is the reason."""
        matches, _ = self.target(fleet, key, "worker_answer")
        if matches[0]["lifecycle"] != "awake":
            raise Unattempted("INVALID_STATE", "Worker is hibernating; nothing is asking")
        code, output, err = self.adapter("answer", fleet["name"], key, answer, actor or "hub", timeout=120)
        if code in self.ANSWER_REFUSALS:
            raise Unattempted(self.ANSWER_REFUSALS[code], "Answer refused on the fleet: " + last_line(err))
        if code:
            raise Fault("UNKNOWN_OUTCOME", "Keys were sent but the answer was not confirmed: " + last_line(err))
        return {"answered": answer, "how": last_line(output) if output.strip() else "confirmed",
                "worker": matches[0], "by": actor or "hub", "observed_at": now()}

    def execute_reap(self, fleet, key):
        """worker_reap (issue #1487): dash-reap.sh --yes on the one live window
        holding `key` — the confirmed ⌃x branch, so a dirty worktree is still
        KEPT. The result token on stdout is the verdict (issue #869), never the
        exit code: `reaped:*` landed, `skip:*` / `refused:*` touched nothing and
        is a clean `failed` carrying the token and dash-reap's own reason,
        `failed:*` means the gate passed but a disposal did not — unknown."""
        matches, _ = self.target(fleet, key, "worker_reap")
        code, output, err = self.adapter("reap", fleet["name"], key, timeout=300)
        tokens = [l for l in output.decode("utf-8", "replace").splitlines()
                  if re.match(r"(reaped|skip|refused|failed|dispatched):", l)]
        token = tokens[-1].strip() if tokens else ""
        if code == 5 and not token:
            raise Unattempted("NOT_FOUND", "Reap refused on the fleet: " + last_line(err))
        if token.startswith("skip:") or token.startswith("refused:"):
            raise Unattempted("INVALID_STATE", "Reap refused on the fleet: %s — %s" % (token, last_line(err)))
        if not token.startswith("reaped:"):
            raise Fault("UNKNOWN_OUTCOME", "Reap did not confirm: %s" % (token or last_line(err)))
        remaining, snapshot = self.find_workers(fleet, key)
        if remaining:
            raise Fault("UNKNOWN_OUTCOME", "A window still holds this identity after the reap")
        return {"reaped": matches[0], "how": token,
                "kept": "the worktree stays on disk when it was dirty (reaped:keep)" if token == "reaped:keep"
                else "worktree, branch and issue disposed; the window is closed",
                "observed_at": snapshot["observed_at"]}

    def execute_move_in(self, fleet, params):
        """A session moved here through the hub (issue #1426): land its branch
        in a fresh worktree, unpack the transcript the agent downloaded, open a
        window resuming it and see a live agent appear. Everything up to the
        unpack is undone on failure, so those refusals are a clean `failed`;
        a window that opened without an agent is `unknown` — the source keeps
        its own window until someone looks."""
        key = params["worker_key"]
        bundle = self.conf_dir / "control" / "move-in" / (params["move_id"] + ".tar")
        if "issue-" in key and self.find_workers(fleet, key)[0]:
            bundle.unlink(missing_ok=True)
            raise Unattempted("ALREADY_RUNNING", "A live window already holds this identity here")
        argv = ["--repo", params["repo"], "--branch", params["branch"], "--sid", params["sid"],
                "--name", params["name"], "--raw", str(params.get("raw", 0)), "--state", params.get("state") or "done"]
        if params.get("pushed"):
            argv.append("--pushed")
        for opt, k in (("--issue", "issue"), ("--origin", "origin"), ("--origin-wid", "origin_wid"), ("--wid", "handle")):
            if params.get(k) not in (None, ""):
                argv += [opt, str(params[k])]
        code, output, err = self.adapter("movein", fleet["name"], params["move_id"], *argv, timeout=180)
        if code in (1, 4, 6, 7, 8):
            reasons = {4: "RESOURCE_GATE", 6: "INVALID_ARGUMENT", 7: "EXECUTION_FAILED", 8: "EXECUTION_FAILED"}
            raise Unattempted(reasons.get(code, "EXECUTION_FAILED"),
                              "Fleet refused the moved session: " + last_line(err))
        parts = (output.decode("utf-8", "replace").strip().splitlines() or [""])[-1].split("\t")
        window, pid, worktree = (parts + ["", "", ""])[:3]
        if code or not pid:
            raise Fault("UNKNOWN_OUTCOME", "The window opened (%s) but no agent appeared under it" % (window or "?"))
        return {"window": window, "pid": pid, "worktree": worktree, "worker_key": key, "observed_at": now()}

    def execute(self, op_id):
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM operations WHERE id=?", (identifier(op_id),)).fetchone()
            if row is None or row["status"] != "accepted":
                return
            db.execute("UPDATE operations SET status='running',updated=? WHERE id=?", (now(), op_id))
        req = json.loads(row["request"])
        attempted = False
        try:
            fleet = self.fleet(req["fleet_id"])
            params = req["params"]
            if req["action"] in WORKER_ACTIONS:
                result = self.execute_worker(fleet, req["action"], params, req.get("actor", ""))
            elif req["action"] == "gh_comment":
                # Record-only (fleet-comment.sh --note) through the per-token
                # write queue; reaching a live worker is worker_message's job.
                attempted = True
                code, output, err = self.adapter("comment", fleet["name"], str(params["issue"]), params.get("repo", ""),
                                                 payload=params["body"].encode("utf-8"), timeout=900)
                if code == 6:
                    raise Unattempted("INVALID_ARGUMENT", "Name a repo this fleet hosts (owner/name)")
                if code:
                    raise Fault("UNKNOWN_OUTCOME", "Comment post did not confirm; inspect the issue before retrying")
                result = {"comment_url": output.decode("utf-8").strip(), "channel": "record",
                          "delivery": "record only; a live worker on this issue does not see it (use worker_message)",
                          "observed_at": now()}
            elif req["action"] == "worker_start":
                # No --force, arbitrary argv, paths, environment or shell input.
                attempted = True
                code, _, _ = self.adapter("start", fleet["name"], str(params["issue"]), params.get("agent", ""),
                                          params.get("repo", ""), params.get("origin_wid", ""), timeout=180)
                if code:
                    # 6 = no repo named in a fleet hosting several, or one it does not host (#984).
                    reasons = {2: "AT_CAPACITY", 3: "ALREADY_CLAIMED", 4: "RESOURCE_GATE", 6: "INVALID_ARGUMENT"}
                    attempted = code not in reasons
                    raise Fault(reasons.get(code, "EXECUTION_FAILED"), "Fleet refused to start the worker; inspect local Fleet logs")
                snapshot = self.workers(fleet)
                # Match the spawned repo too (issue #1018): another repo's issue-N
                # is a different worker.
                matches = [w for w in snapshot["workers"] if w["issue"] == params["issue"]
                           and (not params.get("repo") or repo_named(w["repo"], params["repo"]))]
                if not matches:
                    raise Fault("UNKNOWN_OUTCOME", "Spawn returned but no matching worker is visible")
                result = {"workers": matches, "observed_at": snapshot["observed_at"]}
            elif req["action"] == "worker_move_in":
                result = self.execute_move_in(fleet, params)
                attempted = True
            else:
                try:
                    attempted = True
                    write(fleet["config_path"], params["key"], str(params["value"]), "int", params["expected_revision"])
                except ValueError as exc:
                    attempted = False
                    raise Fault("REVISION_CONFLICT", str(exc)) from exc
                result = self.config(fleet)
                result["effect"] = "Future scheduling decisions; existing workers are not stopped"
            self.finish(op_id, "succeeded", result)
        except Unattempted as exc:
            self.finish(op_id, "failed", {"error": exc.as_dict()})
        except Fault as exc:
            state = "unknown" if attempted or exc.code in ("TIMEOUT", "UNKNOWN_OUTCOME") else "failed"
            self.finish(op_id, state, {"error": exc.as_dict()})
        except Exception:
            self.finish(op_id, "unknown", {"error": {"code": "UNKNOWN_OUTCOME", "message": "Executor could not confirm the result"}})

    def dispatch(self, request):
        fields(request, ("protocol", "method", "params"), ("machine_id",))
        if type(request["protocol"]) is not int or request["protocol"] != PROTOCOL:
            raise Fault("PROTOCOL_ERROR", "Unsupported control protocol")
        method, params = request["method"], request["params"]
        # discover and ready (issue #1475) are machine-wide reads that name no
        # fleet: the identity check guards a fleet's operations, not these.
        if method not in ("discover", "ready") and request.get("machine_id") != self.machine_id:
            raise Fault("IDENTITY_MISMATCH", "Registered machine identity does not match")
        if method == "discover":
            fields(params, ())
            fleets = [{k: v for k, v in f.items() if k != "config_path"} for f in self.inventory()]
            return {"machine_id": self.machine_id, "hostname": socket.gethostname(),
                    "protocol": PROTOCOL, "fleets": fleets, "observed_at": now()}
        if method == "ready":
            fields(params, ())
            return self.ready()
        if method in ("fleet_status", "config_get"):
            fields(params, ("fleet_id",))
            fleet = self.fleet(params["fleet_id"])
            return self.workers(fleet) if method == "fleet_status" else self.config(fleet)
        if method in GH_READS:
            validate_gh_read(params)
            return self.gh_read(self.fleet(params["fleet_id"]), GH_READS[method], params)
        if method == "operation_get":
            fields(params, ("operation_id",))
            return self.get_operation(params["operation_id"])
        if method == "submit":
            return self.submit(params)
        raise Fault("INVALID_ARGUMENT", "Unsupported control method")


def last_line(err):
    lines = (err or b"").decode("utf-8", "replace").strip().splitlines()
    return lines[-1][:200] if lines else "no detail"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--conf-dir")
    parser.add_argument("command", choices=("rpc", "execute"))
    parser.add_argument("operation_id", nargs="?")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        controller = Control(args.conf_dir)
        if args.command == "execute":
            controller.execute(args.operation_id)
            return 0
        result = controller.dispatch(read_request(sys.stdin.buffer))
        print(canonical({"protocol": PROTOCOL, "machine_id": controller.machine_id, "result": result}))
    except Fault as exc:
        print(canonical({"error": exc.as_dict()}))
        return 1
    except Exception:
        print(canonical({"error": {"code": "INTERNAL", "message": "Local controller failed"}}))
        return 1
    return 0
