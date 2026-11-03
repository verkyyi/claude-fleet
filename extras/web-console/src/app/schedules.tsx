import { ScheduleReader } from "./schedule-feed";
// One owner-scoped feed shared by the sidebar, main panel and result notice.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useMe } from "@/shared/api";
import { lang, tr } from "@/shared/i18n";
import { scheduleMs } from "./session-list";

export type Spec = { id: string; revision: number; name: string; prompt: string; agent?: "" | "claude" | "codex"; at?: string; cron?: string; timezone: string; enabled: boolean; deleted: boolean; delivery: { wechat: boolean; livepage: boolean }; repo?: string };
export type ScheduleRow = { spec: Spec; sync_state: string; sync_note: string; observed: { status?: string; last_run?: number | string; next_run?: number | string; last_result?: string; last_line?: string; last_error?: string; stale?: boolean } };
export type Run = { attempt: number; id: string; schedule_id: string; state: string; started: number; ended: number; summary: string; error: string; delivery: { wechat?: string; wechat_channel?: string; livepage?: string; url?: string }; session_id: string };
type Feed = { expired: boolean; read: <T>(url: string, init?: RequestInit) => Promise<T | null>; rows: ScheduleRow[] | null; unread: Run[]; error: string; refresh: () => Promise<void> };
const Context = createContext<Feed>({ expired: false, read: async () => null, rows: null, unread: [], error: "", refresh: async () => {} });
export const useSchedules = () => useContext(Context);
export const schedulePath = (id: string) => `/?schedule=${encodeURIComponent(id)}`;
export function scheduleDate(t: number | string | undefined, zone: string) {
  const ms = scheduleMs(t);
  if (!ms) return "—";
  try { return new Intl.DateTimeFormat(lang === "zh" ? "zh-CN" : "en-US", { timeZone: zone, month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(ms); } catch { return "—"; }
}
export const scheduleAgent = (s: Spec) => s.agent === "claude" ? "Claude" : s.agent === "codex" ? "Codex" : tr("跟随默认", "Default agent");
export const recurrence = (s: Spec) => s.cron || `${tr("每天", "Daily")} ${s.at}`;
export function scheduleStatus(r: ScheduleRow) {
  if (!r.spec.enabled) return tr("⏸ 已暂停", "⏸ Paused");
  if (r.sync_state !== "synced") return tr("等待确认", "Pending");
  if (r.observed.status === "running") return tr("● 运行中", "● Running");
  if (r.observed.last_result === "failed" || r.observed.status === "failed") return tr("✗ 失败", "✗ Failed");
  if (r.observed.last_run) return `✓ ${scheduleDate(r.observed.last_run, r.spec.timezone)}`;
  return tr("等待运行", "Scheduled");
}
export function SchedulesProvider({ children }: { children: ReactNode }) {
  const [rows, setRows] = useState<ScheduleRow[] | null>(null);
  const [unread, setUnread] = useState<Run[]>([]);
  const [error, setError] = useState("");
  const reader = useRef(new ScheduleReader());
  const [expired, setExpired] = useState(false);
  const read = useCallback(async <T,>(url: string, init?: RequestInit): Promise<T | null> => {
    const result = await reader.current.read<T>(url, init);
    if (result.kind === "expired") { setExpired(true); setRows([]); setUnread([]); }
    return result.kind === "ok" ? result.data : null;
  }, []);
  const refresh = useCallback(async () => {
    const data = await read<{ schedules: ScheduleRow[]; unread?: Run[] }>("/v1/schedules");
    if (data) { setRows(data.schedules); setUnread(data.unread ?? []); setError(""); }
    else setError(tr("暂时无法刷新定时任务，保留上次结果。", "Could not refresh schedules. Showing the previous result."));
  }, [read]);
  useEffect(() => { if (expired) return; void refresh(); const timer = setInterval(() => { if (!document.hidden) void refresh(); }, 15000); return () => clearInterval(timer); }, [refresh, expired]);
  return <Context.Provider value={{ rows, unread, error: expired ? tr("登录已过期，请重新登录。", "Your sign-in expired. Sign in again.") : error, refresh, expired, read }}>{children}</Context.Provider>;
}
// Whether this person may make a schedule here: signed in, not read-only, not
// a preview, the feed not expired (新建定时任务 in the 新会话 menu, the switch).
export function useCanSchedule() {
  const { me } = useMe();
  const { expired } = useSchedules();
  return !expired && !!me && !me.read_only && !me.view_as;
}
// Marks one schedule's results read (the bell, its 全部已读): the same call the
// schedule's own page makes when it is opened.
export const readSchedule = (read: Feed["read"], id: string) => read("/v1/schedules", { method: "POST",
  headers: { "Content-Type": "application/json", Accept: "application/json" },
  body: JSON.stringify({ action: "read", id, idempotency_key: crypto.randomUUID() }) });

export function AgentChip({ spec }: { spec: Spec }) {
  return <span className="inline-block rounded border bg-card px-1 py-px text-[10px] leading-tight text-foreground">{scheduleAgent(spec)}</span>;
}
