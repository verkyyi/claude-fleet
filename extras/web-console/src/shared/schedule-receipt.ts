// A receipt is only emitted by a successful create response. A list/update,
// partial streamed JSON or an MCP error must never claim a task was created.
export type ScheduleReceipt = { id: string; name: string; at?: string; cron?: string; timezone: string; agent: "" | "claude" | "codex"; delivery: { wechat: boolean; livepage: boolean }; synced: boolean; next?: number };
const object = (v: unknown): Record<string, unknown> | null => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
export const isScheduleTool = (tool: string) => /(?:^|[_.])schedule$/.test(tool);
export function scheduleReceiptRef(tool: string, result: unknown): string | null {
  if (!isScheduleTool(tool) || typeof result !== "string") return null;
  try { const r = JSON.parse(result.split("\n", 1)[0]); return r?.action === "create" && typeof r.schedule_id === "string" && /^schedule-[a-zA-Z0-9-]+$/.test(r.schedule_id) ? r.schedule_id : null; } catch { return null; }
}
export function scheduleReceipt(tool: string, result: unknown, depth = 0): ScheduleReceipt | null {
  if (!isScheduleTool(tool) || depth > 4) return null;
  if (typeof result === "string") { try { return scheduleReceipt(tool, JSON.parse(result), depth + 1); } catch { return null; } }
  // Claude stores text blocks; Codex may keep the MCP envelope.
  if (Array.isArray(result)) {
    for (const block of result) { const b = object(block); if (b?.type === "text") { const found = scheduleReceipt(tool, b.text, depth + 1); if (found) return found; } }
    return null;
  }
  const r = object(result);
  if (!r || r.isError || r.error) return null;
  if (r.structuredContent) return scheduleReceipt(tool, r.structuredContent, depth + 1);
  if (r.content) return scheduleReceipt(tool, r.content, depth + 1);
  const row = object(r.schedule), s = object(row?.spec), delivery = object(s?.delivery), observed = object(row?.observed);
  if (r.action !== "create" || !s || typeof s.id !== "string" || !/^schedule-[a-zA-Z0-9-]+$/.test(s.id) || typeof s.name !== "string" || typeof s.timezone !== "string" || !delivery || (typeof s.at !== "string" && typeof s.cron !== "string")) return null;
  return { id: s.id, name: s.name, timezone: s.timezone, at: typeof s.at === "string" ? s.at : undefined, cron: typeof s.cron === "string" ? s.cron : undefined, agent: s.agent === "claude" || s.agent === "codex" ? s.agent : "", delivery: { wechat: delivery.wechat === true, livepage: delivery.livepage === true }, synced: row?.sync_state === "synced", next: typeof observed?.next_run === "number" ? observed.next_run : undefined };
}
