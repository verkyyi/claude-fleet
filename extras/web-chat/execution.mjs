// The legacy SDK has no Hub execution grant. It must never adopt a controlled
// Task's native session, even when that Task is currently allowed to run.
import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const EXECUTION_MESSAGE = "请在统一会话中继续此任务；旧 WebChat 不能启动第二个执行会话。";
export function sdkExecutionGuard({ helpers, env, lockDir }) {
  return async function check(agent, conversation = {}) {
    const refuse = () => { const e = new Error(EXECUTION_MESSAGE); e.code = "native_session_required"; throw e; };
    if (conversation.task || conversation.task_execution || conversation.execution_owner) refuse();
    let fid = conversation.fleet_session_fid || conversation.fid || "";
    const sid = conversation.session || conversation.thread || "";
    if (!fid && /^[A-Za-z0-9_-]{1,80}$/.test(sid)) {
      try { fid = JSON.parse(readFileSync(join(lockDir, `${agent}-${sid}.json`), "utf8")).window_fid || ""; }
      catch (e) { if (e.code !== "ENOENT") refuse(); }
    }
    if (!fid) return; // Unbound legacy conversations have no Task to adopt.
    const ok = await new Promise((resolve) => execFile("python3", [join(helpers, "fleet-webchat-execution.py"), fid],
      { env: { ...env, PYTHONDONTWRITEBYTECODE: "1" }, timeout: 5000 }, (err) => resolve(!err)));
    if (!ok) refuse();
  };
}
