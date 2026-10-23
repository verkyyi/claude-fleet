"""Native exit submissions in the existing control journal; no stop replay."""
import hashlib
import json
import sqlite3
import time

from fleet_hub_common import Fault, canonical, identifier, is_identity, now, run

RECEIPT = "native_exit_receipt"
BODY_LIMIT = 1 << 20


def exit_result(result):
    """Public operations carry confirmation only, never the large proof."""
    if not isinstance(result, dict):
        return result
    result = dict(result)
    receipt = result.pop(RECEIPT, None)
    if isinstance(receipt, dict):
        confirmed = receipt.get("confirmed") is True
        result["execution_exit"] = "confirmed" if confirmed else "unproven"
        if confirmed:
            result["exit_receipt_id"] = receipt["operation_id"]
    return result


class NativeExitSubmission:
    def _exit_row(self, db, op_id):
        from fleet_task_execution import validate_request
        row = db.execute("SELECT * FROM operations WHERE id=?", (identifier(op_id),)).fetchone()
        if row is None:
            raise Fault("NOT_FOUND", "No stop operation for native exit submission")
        snapshot = validate_request(json.loads(row["request"]))
        if row["action"] != "worker_stop" or snapshot is None:
            raise Fault("INVALID_ARGUMENT", "Native exit submission requires a controlled stop")
        result = json.loads(row["result"]) if row["result"] else {}
        if not isinstance(result, dict) or not isinstance(result.get(RECEIPT, {}), dict):
            raise ValueError("Malformed native exit journal")
        return snapshot, result, result.get(RECEIPT, {})

    def prepare_native_exit(self, op_id):
        from fleet_task_execution import FenceRefused, prove_native_session_exit
        with self.store.connect() as db:
            snapshot, _, receipt = self._exit_row(db, op_id)
        if "payload" in receipt:
            return receipt["payload"]
        registered = self.execution.launch(snapshot["task_ref"])
        components = {r["component"] for r in registered["native"]} if registered else set()
        if components == {"agent"}:
            provider = "claude"
        elif components == {"server", "client"}:
            provider = "codex"
        else:
            raise FenceRefused("native provider registration is missing or incomplete")
        # Exact snapshot/history/kernel checks stay in the original proof helper.
        # Its admission barriers have ended before journal persistence/network.
        proof = prove_native_session_exit(snapshot, provider, conf_dir=self.conf_dir)
        payload = dict(control_version=1,
                       idempotency_key="native-exit:" + hashlib.sha256(op_id.encode()).hexdigest(), proof=proof)
        if len(canonical(payload).encode()) > BODY_LIMIT:
            raise FenceRefused("native exit proof exceeds the Hub transport bound")
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            current, result, receipt = self._exit_row(db, op_id)
            if current != snapshot:
                raise FenceRefused("stop operation changed while proving native exit")
            # Concurrent proof observers may have different observed_at values.
            # The first committed payload wins, even if its ACK is already here.
            if "payload" not in receipt:
                receipt["payload"] = payload
                result[RECEIPT], result["execution_exit"] = receipt, "unproven"
                db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op_id))
            return receipt["payload"]

    def send_native_exit(self, task, payload, timeout):
        env = self.environment()
        # The outer bound includes optional forwarder + direct HTTP attempts.
        env["FLEET_HUB_TIMEOUT"] = str(max(.1, timeout / 2))
        code, out, _ = run(["bash", str(self.bin / "fleet-task-record.sh"), "execution-exit", task],
                           payload=canonical(payload).encode(), env=env, timeout=timeout)
        if code:
            raise Fault("UNAVAILABLE", "Hub has not confirmed the native exit receipt")
        return json.loads(out)

    def submit_native_exit(self, op_id, *, timeout=8):
        """Failure retains any original packet. Network holds no local locks."""
        from fleet_task_execution import FenceRefused
        failures = (FenceRefused, Fault, OSError, ValueError, TypeError, KeyError, sqlite3.Error)
        deadline = time.monotonic() + timeout
        try:
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                _, result, receipt = self._exit_row(db, op_id)
                if receipt.get("confirmed") is True:
                    return True
                receipt["attempted_at"] = now()
                result[RECEIPT], result["execution_exit"] = receipt, "unproven"
                db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op_id))
            payload = self.prepare_native_exit(op_id)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Fault("TIMEOUT", "Native exit proof saved; submission deferred to next heartbeat")
            response = self.send_native_exit(payload["proof"]["snapshot"]["task_ref"], payload, remaining)
            if not isinstance(response, dict):
                raise ValueError("Invalid native exit response")
            op = response.get("operation", {})
            if (type(response.get("control_version")) is not int or response["control_version"] != 1
                    or response.get("scope") != "native_session" or response.get("execution_exit_confirmed") is not True
                    or not isinstance(op, dict) or op.get("action") != "task_session_exit"
                    or op.get("status") != "succeeded" or not is_identity(op.get("operation_id", ""))):
                raise ValueError("Hub did not confirm this native exit submission")
            with self.store.connect() as db:
                db.execute("BEGIN IMMEDIATE")
                _, result, receipt = self._exit_row(db, op_id)
                if receipt.get("payload") != payload:
                    raise ValueError("Native exit submission changed before acknowledgement")
                if receipt.get("confirmed") and receipt.get("operation_id") != op["operation_id"]:
                    raise ValueError("Hub returned conflicting native exit receipts")
                receipt.update(confirmed=True, operation_id=op["operation_id"])
                receipt.pop("error", None)
                result[RECEIPT], result["execution_exit"] = receipt, "confirmed"
                db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op_id))
            return True
        except failures as exc:
            try:
                with self.store.connect() as db:
                    db.execute("BEGIN IMMEDIATE")
                    _, result, receipt = self._exit_row(db, op_id)
                    if receipt.get("confirmed") is not True:
                        receipt["error"] = str(exc)[:200]
                        result[RECEIPT], result["execution_exit"] = receipt, "unproven"
                        db.execute("UPDATE operations SET result=? WHERE id=?", (canonical(result), op_id))
            except failures:
                pass
            return False

    def retry_native_exits(self, *, limit=8, budget=12):
        """Bounded journal scan; never re-execute stop, read inventory or unfence."""
        deadline = time.monotonic() + budget
        with self.store.connect() as db:
            rows = db.execute("""SELECT id FROM operations WHERE action='worker_stop'
                AND json_extract(request,'$.control_version')=1
                AND coalesce(json_extract(result,'$.native_exit_receipt.confirmed'),0)!=1
                ORDER BY coalesce(json_extract(result,'$.native_exit_receipt.attempted_at'),0),created
                LIMIT ?""", (limit,)).fetchall()
        attempted = 0
        for row in rows:
            remaining = deadline - time.monotonic()
            if remaining < .25:
                break
            self.submit_native_exit(row["id"], timeout=min(8, remaining))
            attempted += 1
        return attempted
