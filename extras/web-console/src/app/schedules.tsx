import { ScheduleReader } from "./schedule-feed";
// One owner-scoped feed shared by the sidebar, main panel and result notice.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { Link, useLocation } from "react-router";
import { useMe } from "@/shared/api";
import { lang, tr } from "@/shared/i18n";
import { Button } from "@/components/ui/button";
import { listStatusLabel, needsAttention, rowRef, scheduleCard } from "./session-list";
import { useWorkRows } from "./work-rows";
import type { Row } from "./work";

export type Spec = { id: string; revision: number; name: string; prompt: string; agent?: "" | "claude" | "codex"; at?: string; cron?: string; timezone: string; enabled: boolean; deleted: boolean; delivery: { wechat: boolean; livepage: boolean }; repo?: string };
export type ScheduleRow = { spec: Spec; sync_state: string; sync_note: string; observed: { status?: string; last_run?: number; next_run?: number; last_result?: string; last_line?: string; last_error?: string; stale?: boolean } };
export type Run = { attempt: number; id: string; schedule_id: string; state: string; started: number; ended: number; summary: string; error: string; delivery: { wechat?: string; wechat_channel?: string; livepage?: string; url?: string }; session_id: string };
type Feed = { expired: boolean; read: <T>(url: string, init?: RequestInit) => Promise<T | null>; rows: ScheduleRow[] | null; unread: Run[]; error: string; refresh: () => Promise<void> };
const Context = createContext<Feed>({ expired: false, read: async () => null, rows: null, unread: [], error: "", refresh: async () => {} });
export const useSchedules = () => useContext(Context);
export const schedulePath = (id: string) => `/?schedule=${encodeURIComponent(id)}`;
export function scheduleDate(t: number | undefined, zone: string) {
  if (!t) return "—";
  try { return new Intl.DateTimeFormat(lang === "zh" ? "zh-CN" : "en-US", { timeZone: zone, month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(t * 1000); } catch { return "—"; }
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
export function NewScheduleButton() {
  const { me } = useMe();
  const { expired } = useSchedules();
  return <Button asChild variant="outline" size="sm" className="border-clay/30 bg-clay/10 text-clay hover:bg-clay/15" disabled={expired || !me || !!(me.read_only || me.view_as)}><Link to={schedulePath("new")} aria-disabled={expired || !me || !!(me.read_only || me.view_as)} onClick={e => { if (expired || !me || me.read_only || me.view_as) e.preventDefault(); }}>⏰ {tr("新建定时", "Schedule")}</Link></Button>;
}
// One run under its schedule in the card (Y8XY): its status words and its day.
function RunLink({ r, current }: { r: Row; current: string }) {
  const ref = rowRef(r);
  return <Link to={`/s/${encodeURIComponent(ref)}`} aria-current={current === ref ? "page" : undefined} data-schedule-run={r.id}
    className={`mx-1 flex items-baseline gap-2 rounded-lg border px-2 py-1 pl-4 text-xs no-underline hover:bg-card/80 ${current === ref ? "border-border bg-card" : "border-transparent"}`}>
    <span className={needsAttention(r) ? "shrink-0 text-destructive" : "shrink-0 text-blue-600"}>{listStatusLabel(r) || tr("已结束", "Ended")}</span>
    <span className="truncate text-muted-foreground">{r.title}</span>
  </Link>;
}

export function ScheduleGroup({ phone = false }: { phone?: boolean }) {
  const { rows, error, expired } = useSchedules();
  const { rows: sessions } = useWorkRows();
  const [open, setOpen] = useState(true);
  const [otherOpen, setOtherOpen] = useState(false);
  const { search, pathname } = useLocation();
  const selected = new URLSearchParams(search).get("schedule");
  const m = pathname.match(/^\/s\/([^/]+)/);
  const current = m ? decodeURIComponent(m[1]) : "";
  const card = scheduleCard(sessions ?? [], (rows ?? []).map(r => r.spec.id));
  if (!rows?.length && !card.other.length) return error ? <p role="status" className="p-3 text-xs text-muted-foreground">{error}{expired && <a href="/app/signin" className="ml-2 underline">{tr("重新登录", "Sign in again")}</a>}</p> : null;
  const list = rows ?? [];
  const running = Math.max(list.filter(r => r.observed.status === "running").length, card.running);
  const asking = card.asking;
  const failed = list.filter(r => r.observed.status === "failed" || r.observed.last_result === "failed").length;
  if (phone) return <div className="px-3 py-2"><Link to="/?schedules=1" className="flex items-center rounded-xl border border-clay/30 bg-clay/10 p-3 text-sm no-underline">⏰ {tr("定时任务", "Schedules")} {list.length}{running > 0 && ` · ${running} ${tr("个运行中", "running")}`}{asking > 0 && <span className="ml-2 text-destructive">{asking} {tr("个在问你", "asking")}</span>}{failed > 0 && <span className="ml-2 text-destructive">{failed} {tr("个失败", "failed")}</span>}<span className="ml-auto pl-2">›</span></Link></div>;
  return <section aria-label={tr("定时任务", "Schedules")} className="mx-2 mb-2 rounded-xl border border-clay/30 bg-clay/10 pb-1 group-data-[collapsible=icon]:hidden">
    {failed > 0 && <Link role="status" to={schedulePath(list.find(r => r.observed.status === "failed" || r.observed.last_result === "failed")!.spec.id)} className="m-1 block rounded-lg border border-destructive/20 bg-destructive/5 px-2 py-2 text-xs text-destructive">✗ {failed} {tr("个定时任务失败，查看结果", "schedules failed · view results")}</Link>}
    <button aria-expanded={open} className="w-full px-3 py-2 text-left text-sm font-medium text-clay" onClick={() => setOpen(!open)}>⏰ {tr("定时任务", "Schedules")} ({list.length}){running > 0 && <span className="font-normal text-blue-600"> · {running} {tr("个运行中", "running")}</span>}{asking > 0 && <span className="font-normal text-destructive"> · {asking} {tr("个在问你", "asking")}</span>} <span className="float-right">{open ? "⌄" : "›"}</span></button>
    {open && list.map(r => [<Link key={r.spec.id} to={schedulePath(r.spec.id)} aria-current={selected === r.spec.id ? "page" : undefined} className={`mx-1 block rounded-lg border px-2 py-2 text-xs no-underline hover:bg-card/80 ${selected === r.spec.id ? "border-border bg-card" : "border-transparent"}`}>
      <div className="flex items-baseline justify-between gap-2"><span className="truncate font-medium">{r.spec.name}</span><span className={scheduleStatus(r).startsWith("✗") ? "shrink-0 text-destructive" : r.observed.status === "running" ? "shrink-0 text-blue-600" : "shrink-0 text-muted-foreground"}>{scheduleStatus(r)}</span></div>
      <div className="mt-1 flex flex-wrap items-center gap-x-1 gap-y-1 text-muted-foreground"><span>{recurrence(r.spec)} · {tr("下次", "Next")} {scheduleDate(r.spec.enabled ? r.observed.next_run : undefined, r.spec.timezone)}</span><AgentChip spec={r.spec} /></div>
    </Link>, ...(card.live[r.spec.id] ?? []).map(run => <RunLink key={run.id} r={run} current={current} />)])}
    {open && card.other.length > 0 && <>
      <button aria-expanded={otherOpen || card.other.some(r => rowRef(r) === current)} className="w-full px-3 py-1 text-left text-xs text-muted-foreground hover:text-foreground" onClick={() => setOtherOpen(!otherOpen)}>
        {tr(`其他运行 · ${card.other.length}`, `Other runs · ${card.other.length}`)}{card.other.some(needsAttention) && <span className="text-destructive">{tr(" · 在问你", " · asking")}</span>}
      </button>
      {(otherOpen || card.other.some(r => rowRef(r) === current)) && card.other.slice(0, 20).map(run => <RunLink key={run.id} r={run} current={current} />)}
    </>}
    {error && <p role="status" className="px-3 text-xs text-muted-foreground">{error}</p>}
  </section>;
}

export function AgentChip({ spec }: { spec: Spec }) {
  return <span className="inline-block rounded border bg-card px-1 py-px text-[10px] leading-tight text-foreground">{scheduleAgent(spec)}</span>;
}
