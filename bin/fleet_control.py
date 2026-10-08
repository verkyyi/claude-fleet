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
import time
import uuid

from fleet_config_write import revision, write
from fleet_hub_common import (CONFIG_KEYS, GH_READS, PROTOCOL, WORKER_ACTIONS, Database, Fault,
                              canonical, fields, identifier, name, now, operation,
                              parse_worker_id, is_identity, read_request, repo_named, run, tool_path, validate_gh_read,
                              validate_write, worker_identity, worker_key, inventory_row)

BIN = Path(__file__).absolute().parent
# A start the hub stopped waiting for (claude-fleet#1606): the hub waits 60 s
# for a placed start to open, then calls one this machine journalled but never
# began "never started" and hands its lease back to the asker. An executor
# that only gets to it after that must not open it behind the asker's back.
START_STALE_SECS = 60
# How long a start's executor keeps watching its new window for `t_ready` (issue
# #2238): past it the operation's timing simply has none — the start itself
# finished long before. FLEET_TIMING_READY_SECS overrides it (0 = never watch).
READY_WATCH_SECS = 120
# What @claude_state reads when the person can type into the session and their
# words are not queued behind a turn (EPIC #2230 共同约定 4).
READY_STATES = ("done", "idle", "ready")
OPS_LOG_MAX = 1 << 20
SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS operations (
 id TEXT PRIMARY KEY, fleet_id TEXT NOT NULL, action TEXT NOT NULL,
 request TEXT NOT NULL, actor TEXT NOT NULL, status TEXT NOT NULL,
 created REAL NOT NULL, updated REAL NOT NULL, result TEXT);
"""


class Unattempted(Fault):
    """A refusal raised before any side effect was attempted: always `failed`."""


class Refused(Fault):
    """A spawn the fleet refused (issue #1586): its exit code and refusal line
    go into the operation's error, so the machine that placed it can say why."""

    def __init__(self, code, message, exit_code, line, **extra):
        super().__init__(code, message)
        self.exit_code, self.line, self.extra = exit_code, line, extra

    def as_dict(self):
        return dict(super().as_dict(), exit=self.exit_code, stderr1=self.line, **self.extra)


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
        # The ready watch's bound (issue #2238) reaches the detached executor.
        if os.environ.get("FLEET_TIMING_READY_SECS"):
            env["FLEET_TIMING_READY_SECS"] = os.environ["FLEET_TIMING_READY_SECS"]
        return env

    def adapter(self, mode, *args, timeout=20, payload=None):
        return run(["bash", str(self.bin / "fleet-control-read.sh"), mode, *args],
                   payload=payload, env=self.environment(), timeout=timeout)

    def inventory(self):
        code, output, _ = self.adapter("inventory")
        if code:
            raise Fault("UNAVAILABLE", "Cannot enumerate configured fleets")
        parts = output.decode("utf-8").split("\0")
        if parts.pop() != "" or len(parts) % 6:
            raise Fault("PROTOCOL_ERROR", "Invalid local fleet inventory")
        fleets = []
        for i in range(0, len(parts), 6):
            session, repo, checkout, agent, config, hosted = parts[i:i + 6]
            name(session)
            fleet_id = self.frozen_identity(session) \
                or str(uuid.uuid5(uuid.UUID(self.machine_id), canonical([session, repo, checkout])))
            # repos (issue #1512): every repo the fleet hosts, for the hub's
            # placement — its own repo alone in a one-repo fleet.
            repos = [r for r in hosted.split("\n") if r] or ([repo] if repo else [])
            fleets.append(dict(fleet_id=fleet_id, machine_id=self.machine_id, name=session,
                               repo=repo, repos=repos, checkout=checkout, agent=agent, config_path=config))
        return fleets

    def frozen_identity(self, session):
        """The fleet's UUID as fleet_uuid froze it (issue #1936): fleets/<sess>/identity,
        written once from the same uuid5 the line above computes, then never derived
        from a repo again. None when absent or damaged — the caller mints it."""
        try:
            value = (self.conf_dir / "fleets" / session / "identity").read_text().split()[0]
            return str(uuid.UUID(value)) if len(value) == 36 else None
        except (OSError, IndexError, ValueError):
            return None

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

    def capacity(self):
        """This login's own session cap and the count its spawn gate reads (issue
        #1587): {"sessions": n, "max_sessions": m}, m = 0 for unlimited. Best
        effort — None when the adapter cannot say, and discover then omits it, so
        the hub filters nothing (exactly what an older install sends)."""
        code, output, _ = self.adapter("capacity")
        if code:
            return None
        try:
            got = json.loads(output.decode("utf-8"))
        except ValueError:
            return None
        if not isinstance(got, dict) or type(got.get("sessions")) is not int \
                or type(got.get("max_sessions")) is not int:
            return None
        out = dict(sessions=got["sessions"], max_sessions=got["max_sessions"])
        # The gate's own verdict rides along (issue #1836): admit (bool),
        # admit_why (the hold's reason, only with admit false) and room (how
        # many more fit in memory). A read script older than #1836 says none,
        # and the hub then filters nothing on them.
        if type(got.get("admit")) is bool:
            out["admit"] = got["admit"]
            if not got["admit"] and isinstance(got.get("admit_why"), str) and got["admit_why"]:
                out["admit_why"] = got["admit_why"]
        if type(got.get("room")) is int and got["room"] >= 0:
            out["room"] = got["room"]
        return out

    def fleet(self, fleet_id):
        identifier(fleet_id)
        for fleet in self.inventory():
            if fleet["fleet_id"] == fleet_id:
                return fleet
        raise Fault("NOT_FOUND", "Fleet is no longer configured on this machine")

    def workers(self, fleet, window=""):
        # window (issue #2237): that one window's rows by the same reads — a start's
        # post-condition check, which over the whole fleet cost seconds.
        code, output, err = self.adapter("workers", fleet["name"], *([window] if window else []))
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
            # The adapter's columns — name, @origin_wid, needs, identity, busy … title —
            # through the one reader both inventories share (issue #1698).
            row = inventory_row(line.split("\t"))
            if row is None:
                raise Fault("PROTOCOL_ERROR", "Invalid worker inventory")
            parts, extra = row
            window, issue, scratch, worktree, state, agent, handle, lifecycle, repo = parts
            # A window with no key — a no-repo session, a pinned guide — is listed
            # under its identity (issue #1749): the adapter mints one for every
            # session window, so what the operator's own list shows, the other
            # machines' lists show too. No key and no identity: not a session.
            if not issue and scratch != "1" and not extra.get("identity"):
                continue
            number = int(issue) if issue.isdigit() and int(issue) > 0 else None
            # repo: the window's own repo, which its key carries (issue #1018;
            # every fleet since #1939 — empty only from an older adapter).
            key = worker_key(number, scratch == "1", worktree, repo)
            # worker_id is the durable identity (issue #834); window_id and handle
            # are observations of where it lives right now.
            workers.append(dict(worker_id=worker_identity(fleet["fleet_id"], key or extra.get("identity")), key=key,
                                window_id=window, issue=number,
                                repo=repo if repo and repo != "?" else (None if repo else fleet.get("repo")),
                                scratch=scratch == "1", worktree=worktree, state=state or "unknown",
                                lifecycle=lifecycle or "awake",
                                agent=agent or fleet["agent"], handle=handle, **extra))
        return {"state": "running", "workers": workers, "observed_at": now()}

    def find_workers(self, fleet, key):
        """Windows holding `key`. A bare key in a multi-repo fleet matches every
        repo's (issue #1018) — so two of them resolve as AMBIGUOUS, never a pick.
        An identity (issue #1646, a worker_id's `<fleet_id>` half) matches the
        window whose @fleet_id it is, whatever key that window answers to now."""
        snapshot = self.workers(fleet)
        if is_identity(key):
            return [w for w in snapshot["workers"] if w.get("identity") == key], snapshot
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

    def oplog(self, op_id, action, line):
        """One line per step of an operation in control/ops.log (claude-fleet#1606):
        accepted, running, and how it finished — so a start the hub says it
        sent and this machine never opened leaves a trace either way. Never
        fails the operation; kept to one rotated megabyte."""
        try:
            path = self.store.root / "ops.log"
            if path.exists() and path.stat().st_size > OPS_LOG_MAX:
                os.replace(path, path.with_suffix(".log.1"))
            stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            with open(path, "a", encoding="utf-8") as out:
                out.write("%s %s %s %s\n" % (stamp, action, op_id, " ".join(str(line).split())[:300]))
        except OSError:
            pass

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
        self.oplog(op_id, request["action"], "accepted from %s %s" % (request["actor"], describe(request)))
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
            row = db.execute("SELECT action FROM operations WHERE id=?", (op_id,)).fetchone()
        error = result.get("error") or {}
        if error:
            said = "%s exit=%s %s" % (error.get("code", ""), error.get("exit", "-"),
                                      error.get("stderr1") or error.get("message", ""))
        else:
            said = "window=%s" % (result.get("window") or "-")
            timing = result.get("timing") if isinstance(result.get("timing"), dict) else {}
            if timing:
                # The start's clock, one line (issue #2234): what the batch reads.
                said += " timing " + " ".join("%s=%s" % (k, timing[k]) for k in sorted(timing))
        self.oplog(op_id, row["action"] if row else "?", "%s %s" % (state, said))

    def stamp_timing(self, op_id, **points):
        """Merge timing points (epoch ms) into a finished operation's result
        (issue #2238) — its status and every other field untouched."""
        with self.store.connect() as db:
            row = db.execute("SELECT result FROM operations WHERE id=?", (op_id,)).fetchone()
            if row is None or not row["result"]:
                return
            result = json.loads(row["result"])
            timing = result.get("timing") if isinstance(result.get("timing"), dict) else {}
            timing.update(points)
            result["timing"] = timing
            db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op_id))

    def watch_ready(self, op_id, fleet, window, seeded):
        """After a start has finished: watch its window until the person can type
        (issue #2238) and stamp `t_ready` — @claude_state idle (READY_STATES), or
        for an unseeded start, its agent up (SessionStart's @cc_session_id) with no
        turn running. A seeded start also gets `t_prompt`: the first `working`, the
        first sentence on its way. Bounded by READY_WATCH_SECS; a window that is
        gone or unreadable ends the watch — a timing point is never worth more."""
        try:
            limit = float(os.environ.get("FLEET_TIMING_READY_SECS", READY_WATCH_SECS))
        except ValueError:
            limit = READY_WATCH_SECS
        start = time.monotonic()
        deadline = start + limit
        prompt = False
        while time.monotonic() < deadline:
            code, output, err = self.adapter("wstate", fleet["name"], window, timeout=10)
            if code:
                return
            state, _, sid = output.decode("utf-8", "replace").strip("\n").partition("\t")
            state, sid = state.strip(), sid.strip()
            if seeded and not prompt and state == "working":
                prompt = True
                self.stamp_timing(op_id, t_prompt=ms(now()))
            if state in READY_STATES or (not seeded and not state and sid):
                self.stamp_timing(op_id, t_ready=ms(now()))
                return
            # Fine-grained while it matters (the batch's bar is 3 s), coarse after.
            time.sleep(0.25 if time.monotonic() - start < 15 else 1.0)

    def execute_worker(self, fleet, action, params, actor=""):
        """Lifecycle tools on a durable worker identity. Every refusal before the
        adapter runs raises Unattempted (a clean `failed`); anything after it
        is `unknown` unless the post-condition was observed. `actor` is the
        journal's actor — who decided — handed to the one tool whose effect is a
        human's call (worker_answer)."""
        fleet_id, key = parse_worker_id(params["worker_id"])
        if fleet_id != fleet["fleet_id"]:
            raise Unattempted("INVALID_ARGUMENT", "worker_id belongs to a different fleet")
        if action == "worker_switch":
            # By identity or key alike: a no-repo session (the pinned guide) has
            # no key at all, only its @fleet_id (issue #2102).
            return self.execute_switch(fleet, key, params.get("account", ""))
        if is_identity(key):
            # An identity-form worker_id (issue #1646): the session it names, under
            # the key it answers to NOW — every adapter below speaks keys.
            if action == "worker_resume":
                raise Unattempted("INVALID_ARGUMENT", "Resume a stopped worker by its key-form worker_id")
            matches, _ = self.target(fleet, key, action)
            key = matches[0]["key"]
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
                return self.execute_inject(fleet, matches, params["text"])
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

    def execute_inject(self, fleet, matches, text):
        """worker_message on a fleet without the issue bridge (issue #1554): this
        node IS the worker's machine, so the text goes to the live session
        directly — fleet-peer-send.sh, the local inbox channel SendMessage uses,
        never keystrokes. No comment means no GitHub record, so this needs
        exactly ONE live window: the bridge path may post to an issue several
        windows share, a direct send must pick none of them on a guess."""
        if len(matches) > 1:
            raise Unattempted("AMBIGUOUS", "Several live windows hold this identity and the fleet has no issue bridge; "
                                           "resolve them on the fleet first")
        code, output, err = self.adapter("inject", fleet["name"], matches[0]["key"],
                                         payload=text.encode("utf-8"), timeout=60)
        if code:
            raise Unattempted("EXECUTION_FAILED", "No issue bridge on this fleet, and direct delivery was refused: "
                              + last_line(err))
        return {"channel": "direct", "how": last_line(output),
                "delivery": "straight to the live session (no issue bridge on this fleet, so no issue comment)",
                "workers": matches, "observed_at": now()}

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

    def execute_switch(self, fleet, key, account=""):
        """worker_switch (issue #2102): the sidebar's 「换到可用订阅」 on a row here.
        dash-migrate.sh <window> to [<account>] — its own dry-run gates the move
        (the same account, a benched or quota-unverified target, a window with no
        Claude) and refuses with one line, touching nothing: a clean `failed`.
        A plan that moves is dispatched detached (a cold `claude --resume` takes
        ~25 s) and reports through the fleet's alerts, so success here means the
        move started, never that it landed."""
        matches, _ = self.target(fleet, key, "worker_switch")
        if matches[0].get("lifecycle", "awake") != "awake":
            raise Unattempted("INVALID_STATE", "Worker is hibernating; wake it on the fleet before switching it")
        window = matches[0].get("window_id", "")
        code, output, err = self.adapter("switch", fleet["name"], window, *([account] if account else []),
                                         timeout=120)
        said = last_line(output if (output or b"").strip() else err)
        if code == 2:
            raise Unattempted("INVALID_ARGUMENT", "Switch refused on the fleet: " + said)
        if code:
            raise Unattempted("INVALID_STATE", "Switch refused on the fleet: " + said)
        return {"switching": matches[0], "to": account or "active", "window": window,
                "how": "dispatched: closes the session and resumes the same conversation on the new "
                       "subscription; the fleet's alerts report the outcome",
                "observed_at": now()}

    def execute_reap(self, fleet, key):
        """worker_reap (issue #1487): dash-reap.sh --yes on the one live window
        holding `key` — the confirmed ⌃x branch, so a dirty worktree is still
        KEPT. The result token on stdout is the verdict (issue #869), never the
        exit code: `reaped:*` landed, `skip:*` / `refused:*` touched nothing and
        is a clean `failed` carrying the token and dash-reap's own reason,
        `failed:*` means the gate passed but a disposal did not — unknown.
        Either way the record carries #1586's terminal fields (issue #1589):
        `exit` (dash-reap's own status) + `stderr1` (its reason) + `token`, so
        the machine that asked (dash-reap.sh's hub branch, fleet_hub_reap)
        answers with exactly what a reap there would have."""
        matches, _ = self.target(fleet, key, "worker_reap")
        code, output, err = self.adapter("reap", fleet["name"], key, timeout=300)
        tokens = [l for l in output.decode("utf-8", "replace").splitlines()
                  if re.match(r"(reaped|skip|refused|failed|dispatched):", l)]
        token = tokens[-1].strip() if tokens else ""
        window = matches[0].get("window_id", "")
        if code == 5 and not token:
            raise Refused("NOT_FOUND", "Reap refused on the fleet: " + last_line(err), 4, last_line(err),
                          token="refused:no-target", window=window)
        if token.startswith("skip:") or token.startswith("refused:"):
            raise Refused("INVALID_STATE", "Reap refused on the fleet: %s — %s" % (token, last_line(err)),
                          code, last_line(err), token=token, window=window)
        if not token.startswith("reaped:"):
            raise Refused("UNKNOWN_OUTCOME", "Reap did not confirm: %s" % (token or last_line(err)),
                          code or 5, last_line(err), token=token or "failed:unconfirmed", window=window)
        remaining, snapshot = self.find_workers(fleet, key)
        if remaining:
            raise Refused("UNKNOWN_OUTCOME", "A window still holds this identity after the reap",
                          5, "a window still holds %s after the reap" % key, token="failed:window", window=window)
        return {"reaped": matches[0], "how": token, "token": token, "exit": 0, "window": window,
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
            stale = row["action"] == "worker_start" and now() - row["created"] > START_STALE_SECS
            db.execute("UPDATE operations SET status='running',updated=? WHERE id=?", (now(), op_id))
        req = json.loads(row["request"])
        if stale:
            self.finish(op_id, "failed", {"error": Unattempted(
                "EXPIRED", "Start reached its executor %ds after it was accepted; the hub already "
                "gave its lease back — not opening it" % int(now() - row["created"])).as_dict()})
            return
        self.oplog(op_id, row["action"], "running")
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
                scratch = params.get("kind") == "scratch"
                filed = params.get("kind") == "new"
                warm = False
                # The reap policy (issue #1902) as the adapter's $9, only when one
                # was chosen — with none the argv is exactly what it was.
                reap_arg = [params["reap"]] if params.get("reap") else []
                if scratch:
                    # issue #1541: a raw scratch session the hub placed here — the
                    # adapter's start with `scratch` for the issue, the account class
                    # in its usual slot and the name (validated above) as one more
                    # argv word; dash-raw-session.sh opens it and prints its receipt
                    # (`<window_id>\t<name>\t<worktree>\t<fleet_id>`).
                    # issue #1956: a no-repo scratch says `-` for its repo (the
                    # adapter opens it with --no-repo), and the writing area's
                    # text rides stdin as its seed — never an argv.
                    code, output, err = self.adapter("start", fleet["name"], "scratch", params.get("agent", ""),
                                                     "-" if params.get("no_repo") else params.get("repo", ""),
                                                     params.get("origin_wid", ""),
                                                     params.get("account_class", ""), params.get("name", "").strip(),
                                                     *reap_arg, payload=params["body"].encode("utf-8") if params.get("body") else None,
                                                     timeout=180)
                elif filed:
                    # issue #1953: the client's writing area — the adapter's start
                    # with `new` for the issue and the title (validated above) where
                    # a scratch has its name; the body rides stdin, never an argv.
                    # It files the issue, prints its URL first, then spawns as an
                    # issue start does.
                    code, output, err = self.adapter("start", fleet["name"], "new", params.get("agent", ""),
                                                     params.get("repo", ""), params.get("origin_wid", ""),
                                                     params.get("account_class", ""), params["title"].strip(),
                                                     *reap_arg, payload=params.get("body", "").encode("utf-8"),
                                                     timeout=240)
                    first = output.decode("utf-8", "replace").split("\n", 1)[0].strip()
                    if not code and first.startswith("warm\t"):
                        # 发出即开 (issue #2234, EPIC #2230 C4): answered from the warm
                        # pool — the window is a scratch already working on the
                        # person's words; its issue is filed and bound afterwards.
                        warm = True
                        output = first[len("warm\t"):].encode("utf-8")
                    elif not code:
                        number = re.search(r"/issues/([1-9][0-9]*)$", first)
                        if not number:
                            raise Fault("UNKNOWN_OUTCOME", "The issue was filed but its number did not come back")
                        params = dict(params, issue=int(number.group(1)))
                else:
                    code, output, err = self.adapter("start", fleet["name"], str(params["issue"]), params.get("agent", ""),
                                                     params.get("repo", ""), params.get("origin_wid", ""),
                                                     params.get("account_class", ""), *([""] + reap_arg if reap_arg else []),
                                                     timeout=180)
                if code:
                    # 6 = no repo named in a fleet hosting several, or one it does not host (#984).
                    # 7 = a new issue (issue #1953) that could not be filed: nothing was opened.
                    reasons = {2: "AT_CAPACITY", 3: "ALREADY_CLAIMED", 4: "RESOURCE_GATE", 6: "INVALID_ARGUMENT",
                               7: "EXECUTION_FAILED"}
                    attempted = code not in reasons
                    # The spawn's own exit code and refusal line ride back to
                    # whoever placed it (issue #1586): a refusal there prints
                    # what a refusal here would.
                    raise Refused(reasons.get(code, "EXECUTION_FAILED"),
                                  "Fleet refused to start the worker: " + refusal_line(err), code, refusal_line(err))
                # The window the spawn opened (issue #2237): an issue start prints it
                # last (dash-issue-session.sh --print), a scratch first — its row
                # alone is read. No id (an older spawn), or the window it names is
                # not the worker: the whole fleet, as before.
                lines = output.decode("utf-8", "replace").split("\n")
                receipt = (lines[0] if scratch or warm else ([l for l in lines if l.strip()] or [""])[-1]).split("\t")
                window = receipt[0].strip()
                # Its 4th field is the window's @fleet_id (issue #1873): identity
                # first (issue #2339) — a no-repo session (`fleet claude`) has no
                # @raw and no key, so the `scratch` test never matched one and every
                # HOME start came back UNKNOWN with its window left open.
                fid = receipt[3].strip() if len(receipt) > 3 else ""
                fid = fid if is_identity(fid) else ""

                def started(snapshot):
                    if scratch or warm:
                        if fid:
                            return [w for w in snapshot["workers"] if w.get("identity") == fid]
                        # The receipt names the window: that row, and only that row.
                        return [w for w in snapshot["workers"] if window and w["window_id"] == window and w["scratch"]]
                    # Match the spawned repo too (issue #1018): another repo's issue-N
                    # is a different worker.
                    return [w for w in snapshot["workers"] if w["issue"] == params["issue"]
                            and (not params.get("repo") or repo_named(w["repo"], params["repo"]))]
                snapshot = self.workers(fleet, window if re.fullmatch(r"@[0-9]+", window) else "")
                matches = started(snapshot)
                if not matches and re.fullmatch(r"@[0-9]+", window):
                    snapshot = self.workers(fleet)
                    matches = started(snapshot)
                if not matches and fid:
                    # Opened, but not the session it should be: never leave it as an
                    # orphan nobody was told about (issue #2339) — the stop by its
                    # identity, the one address a no-repo session has. Still unknown:
                    # what the window holds is not this start's to vouch for.
                    stop, _, _ = self.adapter("stop", fleet["name"], "fid:" + fid, timeout=120)
                    raise Fault("UNKNOWN_OUTCOME", "Spawn returned but no matching worker is visible; "
                                + ("its window was closed" if not stop else "closing its window failed (fid:%s)" % fid))
                if not matches:
                    raise Fault("UNKNOWN_OUTCOME", "Spawn returned but no matching worker is visible")
                result = {"workers": matches, "observed_at": snapshot["observed_at"],
                          "exit": 0, "window": matches[0].get("window_id", ""),
                          # Where the client switches at once (issue #2236): every
                          # start, not only a warm one; a no-repo session has no key.
                          "window_id": matches[0].get("window_id", ""),
                          **({"key": matches[0]["key"]} if matches[0].get("key") else {}),
                          # This machine's half of the send's clock (issue #2238,
                          # EPIC #2230 共同约定 3): epoch ms, the names fixed there.
                          "timing": {"t_accepted": ms(row["created"]), "t_window": ms(now())}}
                # A warm start's receipt carries its own clock (issue #2234):
                # `<t_window> <t_ready> <t_prompt>` after the four fields — the
                # claim, the input seen idle, the first turn submitted. Its window
                # and key ride at the top for the client to switch to at once
                # (共同约定 3); `filed: pending` = the issue is still being made.
                stamps = dict(zip(("t_window", "t_ready", "t_prompt"),
                                  (f.strip() for f in receipt[4:7])))
                warmed = {k: int(v) for k, v in stamps.items() if v.isdigit()}
                if warmed:
                    result["timing"].update(warmed)
                    if warm:
                        result["filed"] = "pending"
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
            if req["action"] == "worker_start" and result.get("window"):
                # A start without a seed is ready the moment its agent is up; a
                # seeded one (an issue's /fleet-claim, a scratch's text) first
                # runs that turn — its `t_prompt` is when the turn began.
                # Never the start's outcome: it is already written, and an error
                # here must not reach the `unknown` below.
                seeded = not (params.get("kind") == "scratch" and not params.get("body"))
                try:
                    # A warm start measured its own t_ready / t_prompt (issue #2234).
                    if "t_prompt" not in result.get("timing", {}):
                        self.watch_ready(op_id, fleet, result["window"], seeded)
                except Exception:
                    pass
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
            out = {"machine_id": self.machine_id, "hostname": socket.gethostname(),
                   "protocol": PROTOCOL, "fleets": fleets, "observed_at": now()}
            capacity = self.capacity()
            if capacity is not None:
                out["capacity"] = capacity
            return out
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


def ms(seconds):
    """Epoch seconds → the integer epoch milliseconds a timing point is (issue #2238)."""
    return int(round(seconds * 1000))


def describe(request):
    """The few params worth a log line: which issue, repo and parent."""
    params = request.get("params") or {}
    words = ["%s=%s" % (k, params[k]) for k in ("issue", "kind", "repo", "worker_id", "origin_wid") if params.get(k)]
    return " ".join(words) or "-"


def last_line(err):
    lines = (err or b"").decode("utf-8", "replace").strip().splitlines()
    return lines[-1][:200] if lines else "no detail"


def refusal_line(err):
    """The spawn's refusal: its last `dash-issue-session:` / `dash-raw-session:`
    line (a lease note can come first), else its last stderr line."""
    lines = [l.strip() for l in (err or b"").decode("utf-8", "replace").splitlines() if l.strip()]
    said = [l for l in lines if l.startswith(("dash-issue-session:", "dash-raw-session:"))]
    return (said or lines or ["no detail"])[-1][:200]


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
