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
from fleet_hub_common import (CONFIG_KEYS, PROTOCOL, Database, Fault, canonical,
                              fields, identifier, name, now, operation,
                              read_request, run, validate_write)

BIN = Path(__file__).absolute().parent
SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS operations (
 id TEXT PRIMARY KEY, fleet_id TEXT NOT NULL, action TEXT NOT NULL,
 request TEXT NOT NULL, actor TEXT NOT NULL, status TEXT NOT NULL,
 created REAL NOT NULL, updated REAL NOT NULL, result TEXT);
"""


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
        env["FLEET_CONF_DIR"] = str(self.conf_dir)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        return env

    def adapter(self, mode, *args, timeout=20):
        return run(["bash", str(self.bin / "fleet-control-read.sh"), mode, *args],
                   env=self.environment(), timeout=timeout)

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

    def fleet(self, fleet_id):
        identifier(fleet_id)
        for fleet in self.inventory():
            if fleet["fleet_id"] == fleet_id:
                return fleet
        raise Fault("NOT_FOUND", "Fleet is no longer configured on this machine")

    def workers(self, fleet):
        code, output, _ = self.adapter("workers", fleet["name"])
        if code == 3:
            return {"state": "down", "workers": [], "observed_at": now()}
        if code:
            raise Fault("UNAVAILABLE", "Cannot read fleet windows")
        workers = []
        for line in output.decode("utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) != 7 or not re.fullmatch(r"@[0-9]+", parts[0]):
                raise Fault("PROTOCOL_ERROR", "Invalid worker inventory")
            window, issue, scratch, worktree, state, agent, handle = parts
            if not issue and scratch != "1":
                continue
            workers.append(dict(window_id=window, issue=int(issue) if issue.isdigit() else None,
                                scratch=scratch == "1", worktree=worktree, state=state or "unknown",
                                agent=agent or fleet["agent"], handle=handle))
        return {"state": "running", "workers": workers, "observed_at": now()}

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
            if req["action"] == "worker_start":
                # No --force, arbitrary argv, paths, environment or shell input.
                attempted = True
                code, _, _ = self.adapter("start", fleet["name"], str(params["issue"]), params.get("agent", ""), timeout=180)
                if code:
                    reasons = {2: "AT_CAPACITY", 3: "ALREADY_CLAIMED", 4: "RESOURCE_GATE"}
                    attempted = code not in reasons
                    raise Fault(reasons.get(code, "EXECUTION_FAILED"), "Fleet refused to start the worker; inspect local Fleet logs")
                snapshot = self.workers(fleet)
                matches = [w for w in snapshot["workers"] if w["issue"] == params["issue"]]
                if not matches:
                    raise Fault("UNKNOWN_OUTCOME", "Spawn returned but no matching worker is visible")
                result = {"workers": matches, "observed_at": snapshot["observed_at"]}
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
        if method != "discover" and request.get("machine_id") != self.machine_id:
            raise Fault("IDENTITY_MISMATCH", "Registered machine identity does not match")
        if method == "discover":
            fields(params, ())
            fleets = [{k: v for k, v in f.items() if k != "config_path"} for f in self.inventory()]
            return {"machine_id": self.machine_id, "hostname": socket.gethostname(),
                    "protocol": PROTOCOL, "fleets": fleets, "observed_at": now()}
        if method in ("fleet_status", "config_get"):
            fields(params, ("fleet_id",))
            fleet = self.fleet(params["fleet_id"])
            return self.workers(fleet) if method == "fleet_status" else self.config(fleet)
        if method == "operation_get":
            fields(params, ("operation_id",))
            return self.get_operation(params["operation_id"])
        if method == "submit":
            return self.submit(params)
        raise Fault("INVALID_ARGUMENT", "Unsupported control method")


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
