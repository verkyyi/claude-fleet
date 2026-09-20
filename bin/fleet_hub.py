"""Fleet Hub registry, authorization, routing and operation journal."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import secrets
import sys
import uuid

from fleet_hub_common import (CONFIG_KEYS, PROTOCOL, SCOPES, Database, Fault,
                              canonical, digest, fields, identifier, name, now,
                              operation, run, validate_write)

BIN = Path(__file__).absolute().parent
REMOTE_COMMAND = ('export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; '
                  'exec python3 "$HOME/.claude/fleet/bin/fleet-control.py" rpc')
SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes (
 id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, transport TEXT NOT NULL,
 endpoint TEXT NOT NULL, conf_dir TEXT, observed REAL, error TEXT);
CREATE TABLE IF NOT EXISTS fleets (
 id TEXT PRIMARY KEY, node_id TEXT NOT NULL, snapshot TEXT NOT NULL, present INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS principals (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT UNIQUE,
 oauth_issuer TEXT, oauth_subject TEXT, oauth_client TEXT,
 policy TEXT NOT NULL, expires REAL NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS operations (
 id TEXT PRIMARY KEY, fleet_id TEXT NOT NULL, action TEXT NOT NULL,
 request TEXT NOT NULL, actor TEXT NOT NULL, idem TEXT NOT NULL,
 status TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, result TEXT,
 UNIQUE(actor,idem));
CREATE TABLE IF NOT EXISTS audit (
 id INTEGER PRIMARY KEY, actor TEXT, action TEXT NOT NULL, fleet_id TEXT,
 outcome TEXT NOT NULL, operation_id TEXT, created REAL NOT NULL);
"""


class Hub:
    def __init__(self, state_dir=None):
        self.store = Database(state_dir or Path.home() / ".config/claude-fleet/hub", SCHEMA)
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if "ssh_config" not in {row[1] for row in db.execute("PRAGMA table_info(nodes)")}:
                db.execute("ALTER TABLE nodes ADD COLUMN ssh_config TEXT")

    def rpc(self, node, method, params):
        request = {"protocol": PROTOCOL, "method": method, "params": params}
        if node.get("id"):
            request["machine_id"] = node["id"]
        if node["transport"] == "ssh":
            # Alias is administrator-registered, never taken from tool input.
            alias = name(node["endpoint"])
            argv = ["ssh"]
            if node.get("ssh_config"):
                argv.extend(["-F", node["ssh_config"]])
            argv.extend(["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=2", alias, REMOTE_COMMAND])
        else:
            argv = [sys.executable, str(BIN / "fleet-control.py")]
            if node.get("conf_dir"):
                argv.extend(["--conf-dir", node["conf_dir"]])
            argv.append("rpc")
        env = {k: v for k, v in os.environ.items()
               if k in ("HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "SSH_AUTH_SOCK", "USER", "LOGNAME")}
        code, output, _ = run(argv, payload=canonical(request).encode(), env=env, timeout=25)
        try:
            response = json.loads(output)
            if not isinstance(response, dict):
                raise ValueError()
        except (ValueError, UnicodeError) as exc:
            raise Fault("UNAVAILABLE" if code else "PROTOCOL_ERROR", "No valid response from the registered machine") from exc
        if "error" in response:
            error = response["error"]
            raise Fault(str(error.get("code", "REMOTE_ERROR")), str(error.get("message", "Remote controller refused the request")))
        if code or response.get("protocol") != PROTOCOL or "result" not in response:
            raise Fault("PROTOCOL_ERROR", "Incompatible remote controller")
        machine_id = identifier(response.get("machine_id"))
        if node.get("id") and machine_id != node["id"]:
            raise Fault("IDENTITY_MISMATCH", "SSH endpoint now identifies a different machine")
        if method == "discover" and (not isinstance(response["result"], dict)
                                     or response["result"].get("machine_id") != machine_id
                                     or response["result"].get("protocol") != PROTOCOL):
            raise Fault("PROTOCOL_ERROR", "Discovery envelope and inventory identity disagree")
        return response["result"]

    def register(self, label, ssh=None, conf_dir=None, ssh_config=None):
        name(label)
        node = dict(name=label, transport="ssh" if ssh else "local", endpoint=name(ssh) if ssh else "local",
                    conf_dir=str(Path(conf_dir).absolute()) if conf_dir else None,
                    ssh_config=str(Path(ssh_config).expanduser().absolute()) if ssh_config else None)
        snapshot = self.rpc(node, "discover", {})
        node["id"] = identifier(snapshot["machine_id"])
        with self.store.connect() as db:
            if db.execute("SELECT 1 FROM nodes WHERE id=? OR name=?", (node["id"], label)).fetchone():
                raise Fault("CONFLICT", "Machine or display name is already registered; use sync")
            db.execute("INSERT INTO nodes (id,name,transport,endpoint,conf_dir,ssh_config) VALUES (?,?,?,?,?,?)",
                       (node["id"], label, node["transport"], node["endpoint"], node["conf_dir"], node["ssh_config"]))
        self.save_snapshot(node, snapshot)
        return {"machine_id": node["id"], "name": label, "fleets": snapshot["fleets"]}

    def nodes(self):
        with self.store.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM nodes ORDER BY name")]

    def save_snapshot(self, node, snapshot):
        if snapshot.get("machine_id") != node["id"] or snapshot.get("protocol") != PROTOCOL:
            raise Fault("IDENTITY_MISMATCH", "Inventory is not from the registered machine")
        fleets = snapshot.get("fleets")
        if not isinstance(fleets, list):
            raise Fault("PROTOCOL_ERROR", "Invalid fleet inventory")
        seen = set()
        for fleet in fleets:
            identifier(fleet["fleet_id"])
            if fleet["machine_id"] != node["id"] or fleet["fleet_id"] in seen:
                raise Fault("PROTOCOL_ERROR", "Invalid fleet identity")
            seen.add(fleet["fleet_id"])
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE fleets SET present=0 WHERE node_id=?", (node["id"],))
            for fleet in fleets:
                old = db.execute("SELECT node_id FROM fleets WHERE id=?", (fleet["fleet_id"],)).fetchone()
                if old and old[0] != node["id"]:
                    raise Fault("IDENTITY_MISMATCH", "Fleet ID belongs to a different machine")
                db.execute("INSERT INTO fleets VALUES (?,?,?,1) ON CONFLICT(id) DO UPDATE SET snapshot=excluded.snapshot,present=1",
                           (fleet["fleet_id"], node["id"], canonical(fleet)))
            db.execute("UPDATE nodes SET observed=?,error=NULL WHERE id=?", (now(), node["id"]))

    def sync(self, node):
        try:
            self.save_snapshot(node, self.rpc(node, "discover", {}))
            return {"machine_id": node["id"], "state": "reachable"}
        except Fault as exc:
            with self.store.connect() as db:
                db.execute("UPDATE nodes SET error=? WHERE id=?", (exc.code, node["id"]))
            return {"machine_id": node["id"], "state": "unreachable", "error": exc.as_dict()}

    def grant(self, label, fleet_ids, scopes, config_keys=(), ttl_hours=24,
              oauth_issuer=None, oauth_subject=None, oauth_client=None):
        name(label)
        if not scopes or set(scopes) - SCOPES or set(config_keys) - CONFIG_KEYS.keys():
            raise Fault("INVALID_ARGUMENT", "Unknown scope or configuration key")
        if not fleet_ids or not math.isfinite(ttl_hours) or not 0 < ttl_hours <= 8760:
            raise Fault("INVALID_ARGUMENT", "Grant requires fleets and an expiry within one year")
        oauth = [oauth_issuer, oauth_subject, oauth_client]
        if any(oauth) and not all(oauth):
            raise Fault("INVALID_ARGUMENT", "OAuth grants require issuer, subject and client ID")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            if all(oauth) and db.execute(
                    "SELECT 1 FROM principals WHERE oauth_issuer=? AND oauth_subject=? AND oauth_client=? AND revoked=0 AND expires>?",
                    (*oauth, now())).fetchone():
                raise Fault("CONFLICT", "OAuth identity already has an active grant; revoke it before replacing it")
            for fleet_id in fleet_ids:
                identifier(fleet_id)
                if not db.execute("SELECT 1 FROM fleets WHERE id=? AND present=1", (fleet_id,)).fetchone():
                    raise Fault("NOT_FOUND", "Grant targets an unregistered fleet")
            principal_id, token = str(uuid.uuid4()), None if all(oauth) else secrets.token_urlsafe(32)
            policy = dict(fleets=sorted(set(fleet_ids)), scopes=sorted(set(scopes)), config_keys=sorted(set(config_keys)))
            expires = now() + ttl_hours * 3600
            db.execute("INSERT INTO principals VALUES (?,?,?,?,?,?,?,?,0)",
                       (principal_id, label, digest(token) if token else None, *oauth, canonical(policy), expires))
        return dict(principal_id=principal_id, token=token, expires_at=expires, policy=policy)

    def authenticate(self, token=None, oauth=None):
        with self.store.connect() as db:
            if oauth:
                row = db.execute("SELECT * FROM principals WHERE oauth_issuer=? AND oauth_subject=? AND oauth_client=? AND revoked=0 AND expires>? ORDER BY expires DESC",
                                 (*oauth, now())).fetchone()
            elif isinstance(token, str) and token:
                row = db.execute("SELECT * FROM principals WHERE token_hash=? AND revoked=0 AND expires>?",
                                 (digest(token), now())).fetchone()
            else:
                row = None
        if row is None:
            raise Fault("UNAUTHORIZED", "No active Fleet Hub grant for this caller")
        principal = dict(row)
        principal["policy"] = json.loads(principal["policy"])
        return principal

    def authorize(self, principal, scope, fleet_id=None):
        policy = principal["policy"]
        if scope not in policy["scopes"] or (fleet_id is not None and fleet_id not in policy["fleets"]):
            raise Fault("FORBIDDEN", "Operation is outside this caller's Fleet grant")

    def fleet_node(self, fleet_id, require_present=True):
        identifier(fleet_id)
        with self.store.connect() as db:
            fleet = db.execute("SELECT * FROM fleets WHERE id=?", (fleet_id,)).fetchone()
            if fleet is None or (require_present and not fleet["present"]):
                raise Fault("NOT_FOUND", "Fleet is not currently registered")
            node = db.execute("SELECT * FROM nodes WHERE id=?", (fleet["node_id"],)).fetchone()
        return dict(node)

    def list_fleets(self, principal, refresh=True):
        allowed = principal["policy"]["fleets"]
        with self.store.connect() as db:
            fleet_rows = [dict(r) for r in db.execute("SELECT * FROM fleets") if r["id"] in allowed]
        nodes = {n["id"]: n for n in self.nodes()}
        if refresh:
            targets = {r["node_id"] for r in fleet_rows}
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(self.sync, [nodes[x] for x in targets]))
            nodes = {n["id"]: n for n in self.nodes()}
            with self.store.connect() as db:
                fleet_rows = [dict(r) for r in db.execute("SELECT * FROM fleets") if r["id"] in allowed]
        result = []
        for row in fleet_rows:
            node = nodes[row["node_id"]]
            state = "unreachable" if node["error"] else "fresh" if node["observed"] and now() - node["observed"] < 60 else "stale"
            result.append(dict(json.loads(row["snapshot"]), machine_name=node["name"],
                               registered=bool(row["present"]), availability=state, observed_at=node["observed"]))
        return {"fleets": result}

    def submit(self, principal, action, params):
        fields(params, ("fleet_id", "idempotency_key", "params"))
        fleet_id = identifier(params["fleet_id"])
        self.authorize(principal, "worker:start" if action == "worker_start" else "config:write", fleet_id)
        key = params["idempotency_key"]
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", key):
            raise Fault("INVALID_ARGUMENT", "idempotency_key must be 1–128 letters, digits or ._:-")
        validate_write(action, params["params"])
        if action == "config_set" and params["params"]["key"] not in principal["policy"]["config_keys"]:
            raise Fault("FORBIDDEN", "Configuration key is outside this caller's grant")
        node = self.fleet_node(fleet_id)
        request = canonical({"fleet_id": fleet_id, "action": action, "params": params["params"]})
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            old = db.execute("SELECT * FROM operations WHERE actor=? AND idem=?", (principal["id"], key)).fetchone()
            if old:
                if old["request"] != request:
                    raise Fault("IDEMPOTENCY_CONFLICT", "Key was used for a different operation")
                return operation(old)
            op_id, timestamp = str(uuid.uuid4()), now()
            db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,'pending',?,?,NULL)",
                       (op_id, fleet_id, action, request, principal["id"], key, timestamp, timestamp))
        envelope = dict(json.loads(request), operation_id=op_id, actor=principal["id"])
        try:
            remote = self.rpc(node, "submit", envelope)
            self.save_operation(op_id, remote)
        except Fault as exc:
            # A lost acknowledgement is NOT a failed execution. Retain the ID
            # and never auto-submit a second request; operation_get reconciles.
            self.save_operation(op_id, dict(operation_id=op_id, fleet_id=fleet_id, action=action,
                                            status="unknown", result={"error": exc.as_dict()}))
        return self.stored_operation(op_id)

    def stored_operation(self, op_id):
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (identifier(op_id),)).fetchone()
        if row is None:
            raise Fault("NOT_FOUND", "Unknown operation")
        return operation(row)

    def save_operation(self, op_id, remote):
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM operations WHERE id=?", (op_id,)).fetchone()
            if (remote.get("operation_id") != op_id or remote.get("fleet_id") != row["fleet_id"]
                    or remote.get("action") != row["action"] or remote.get("status") not in ("accepted", "running", "succeeded", "failed", "unknown")):
                raise Fault("PROTOCOL_ERROR", "Remote operation identity does not match")
            db.execute("UPDATE operations SET status=?,result=?,updated=? WHERE id=?",
                       (remote["status"], canonical(remote.get("result")), now(), op_id))

    def get_operation(self, principal, op_id):
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM operations WHERE id=? AND actor=?", (identifier(op_id), principal["id"])).fetchone()
        if row is None:
            raise Fault("NOT_FOUND", "Unknown operation for this caller")
        self.authorize(principal, "fleet:read", row["fleet_id"])
        if row["status"] not in ("succeeded", "failed"):
            try:
                remote = self.rpc(self.fleet_node(row["fleet_id"], require_present=False), "operation_get", {"operation_id": op_id})
                self.save_operation(op_id, remote)
            except Fault as exc:
                result = operation(row)
                result.update(status="unknown", reconciliation_error=exc.as_dict())
                return result
        return self.stored_operation(op_id)

    def call(self, tool, params, *, token=None, oauth=None, token_scopes=None):
        principal, result, outcome = None, None, "OK"
        try:
            principal = self.authenticate(token, oauth)
            if token_scopes is not None:
                principal["policy"]["scopes"] = sorted(set(principal["policy"]["scopes"]) & set(token_scopes))
            self.authorize(principal, "fleet:read")
            if tool == "fleet_list":
                fields(params, (), ("refresh",))
                if type(params.get("refresh", True)) is not bool:
                    raise Fault("INVALID_ARGUMENT", "refresh must be a boolean")
                result = self.list_fleets(principal, params.get("refresh", True))
            elif tool in ("fleet_status", "config_get"):
                fields(params, ("fleet_id",))
                self.authorize(principal, "fleet:read", params["fleet_id"])
                result = self.rpc(self.fleet_node(params["fleet_id"]), tool, params)
            elif tool in ("worker_start", "config_set"):
                result = self.submit(principal, tool, params)
            elif tool == "operation_get":
                fields(params, ("operation_id",))
                result = self.get_operation(principal, params["operation_id"])
            else:
                raise Fault("INVALID_ARGUMENT", "Unknown Fleet tool")
            return result
        except Fault as exc:
            outcome = exc.code
            raise
        except Exception:
            outcome = "INTERNAL"
            raise
        finally:
            with self.store.connect() as db:
                db.execute("INSERT INTO audit(actor,action,fleet_id,outcome,operation_id,created) VALUES (?,?,?,?,?,?)",
                           (principal["id"] if principal else None, str(tool),
                            params.get("fleet_id") if isinstance(params, dict) else None,
                            outcome, result.get("operation_id") if isinstance(result, dict) else None, now()))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir")
    sub = parser.add_subparsers(dest="command", required=True)
    register = sub.add_parser("register", help="Administrator: enroll one machine and discover its fleets")
    register.add_argument("name")
    transport = register.add_mutually_exclusive_group(required=True)
    transport.add_argument("--ssh")
    transport.add_argument("--local", action="store_true")
    register.add_argument("--conf-dir", help="Local transport only")
    register.add_argument("--ssh-config", help="Administrator-owned OpenSSH configuration for this node")
    sub.add_parser("nodes")
    sub.add_parser("sync")
    grant = sub.add_parser("grant", help="Administrator: issue an expiring grant; token is printed once")
    grant.add_argument("name")
    grant.add_argument("--fleet", action="append", required=True)
    grant.add_argument("--scope", action="append", choices=sorted(SCOPES), default=[])
    grant.add_argument("--config-key", action="append", choices=sorted(CONFIG_KEYS), default=[])
    grant.add_argument("--ttl-hours", type=float, default=24)
    grant.add_argument("--oauth-issuer")
    grant.add_argument("--oauth-subject")
    grant.add_argument("--oauth-client")
    revoke = sub.add_parser("revoke")
    revoke.add_argument("principal_id")
    sub.add_parser("audit")
    serve = sub.add_parser("serve")
    serve.add_argument("--transport", choices=("stdio", "streamable-http"), default="stdio")
    serve.add_argument("--auth", choices=("oauth", "grant-token"), default="oauth",
                       help="HTTP authentication: OAuth JWTs or pre-issued private-deployment grants")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8765)
    serve.add_argument("--issuer")
    serve.add_argument("--jwks-url")
    serve.add_argument("--resource-url")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        hub = Hub(args.state_dir)
        if args.command == "register":
            if args.ssh and args.conf_dir:
                raise Fault("INVALID_ARGUMENT", "--conf-dir applies only to local registration")
            if args.ssh_config and not args.ssh:
                raise Fault("INVALID_ARGUMENT", "--ssh-config applies only to SSH registration")
            result = hub.register(args.name, args.ssh, args.conf_dir, args.ssh_config)
        elif args.command == "nodes":
            result = hub.nodes()
        elif args.command == "sync":
            result = [hub.sync(node) for node in hub.nodes()]
        elif args.command == "grant":
            result = hub.grant(args.name, args.fleet, sorted(set(args.scope) | {"fleet:read"}),
                               args.config_key, args.ttl_hours, args.oauth_issuer, args.oauth_subject, args.oauth_client)
        elif args.command == "revoke":
            with hub.store.connect() as db:
                count = db.execute("UPDATE principals SET revoked=1 WHERE id=?", (identifier(args.principal_id),)).rowcount
            result = {"revoked": bool(count)}
        elif args.command == "audit":
            with hub.store.connect() as db:
                result = [dict(row) for row in db.execute("SELECT * FROM audit ORDER BY id DESC LIMIT 100")]
        else:
            from fleet_hub_mcp import serve as serve_mcp
            serve_mcp(hub, args)
            return 0
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (Fault, ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0
