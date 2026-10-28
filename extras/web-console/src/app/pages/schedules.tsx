import { ScheduleReceipt } from "../ScheduleReceipt";
import { scheduleReceipt, type ScheduleReceipt as Receipt } from "@/shared/schedule-receipt";
import { useEffect, useRef, useState } from "react";
import { Link, Navigate, useLocation, useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { tr } from "@/shared/i18n";
import { sendJSON } from "@/shared/api";
import { usePage, useShell } from "../Shell";

import { useSchedules, scheduleDate as date, schedulePath, recurrence, scheduleStatus, AgentChip, type Spec, type ScheduleRow as Row, type Run } from "../schedules";

type Reply = { action?: string; schedule?: Row; runs?: Run[] };
const initial = (): Spec => ({ id: "", revision: 0, name: "", prompt: "", at: "07:00", timezone: "Asia/Shanghai", enabled: true, deleted: false, delivery: { wechat: false, livepage: false } });
const panel = "rounded-xl border bg-card p-4 sm:p-5 space-y-3";
const words: Record<string, string> = {
  scheduled: tr("等待运行", "Scheduled"), running: tr("运行中", "Running"), waiting: tr("等待运行条件", "Waiting"),
  retrying: tr("等待重试", "Retrying"), ok: tr("已完成", "Completed"), succeeded: tr("已完成", "Completed"),
  failed: tr("运行失败", "Failed"), stopped: tr("已暂停", "Paused"), pending: tr("等待确认", "Pending"),
  synced: tr("已登记", "Registered"), sent: tr("已发送", "Sent"), undelivered: tr("未送达", "Undelivered"),
  publishing: tr("发布中", "Publishing"), processing: tr("处理中或待审核", "Processing or awaiting review"),
  unconfirmed: tr("投递未确认", "Unconfirmed"), cancelled: tr("已取消", "Cancelled"),
};
// compat-1v: 下一批删 — old bookmarks and result notices keep their destination.
export default function SchedulesPage() {
  const { search } = useLocation();
  const id = new URLSearchParams(search).get("id");
  return <Navigate replace to={id ? schedulePath(id) : "/?schedules=1"} />;
}
export function SchedulePanel() {
  usePage(tr("定时任务", "Schedules"));
  const { me } = useShell();
  const { rows, error: feedError, refresh, read, expired } = useSchedules();
  const readOnly = expired || !me || !!(me.read_only || me.view_as);
  const go = useNavigate();
  const { search, state } = useLocation();
  const selected = new URLSearchParams(search).get("schedule");
  const selection = useRef(selected); selection.current = selected;
  const seed = state as { prompt?: string; name?: string; agent?: Spec["agent"]; repo?: string } | null;
  const [error, setError] = useState("");
  const [created, setCreated] = useState<Receipt | null>(null);
  const [edit, setEdit] = useState<Spec | null>(null);
  useEffect(() => { setEdit(selected === "new" ? { ...initial(), ...seed } : null); setDeleting(null); setError(""); }, [selected, seed]);
  const [preview, setPreview] = useState<number | null>(null);
  const [previewError, setPreviewError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [runs, setRuns] = useState<Run[] | null>(null);
  const [deleting, setDeleting] = useState<Row | null>(null);
  useEffect(() => {
    setPreview(null); setPreviewError(false);
    if (!edit) return;
    if (edit.trigger?.type === "now") { setPreview(Math.floor(Date.now()/1000)); return; }
    const once = edit.once_at || (edit.trigger?.type === "once" ? Date.parse(edit.trigger.at ?? "")/1000 : 0);
    if (edit.trigger?.type === "once" && !Number.isFinite(once)) { setPreviewError(true); return; }
    if (edit.once_at) { setPreview(edit.once_at); return; }
    let live = true;
    const q = new URLSearchParams({ preview: "1", timezone: edit.timezone, ...(once ? { once_at: String(once) } : edit.cron ? { cron: edit.cron } : { at: edit.at ?? "" }) });
    const timer = setTimeout(async () => { const data = await read<{ next_run: number }>(`/v1/schedules?${q}`); if (live) { setPreview(data?.next_run ?? null); setPreviewError(!data); } }, 250);
    return () => { live = false; clearTimeout(timer); };
  }, [edit?.at, edit?.cron, edit?.once_at, edit?.trigger?.type, edit?.trigger?.at, edit?.timezone, !!edit, read]);
  const idem = useRef<{ signature: string; key: string } | null>(null);
  const [detail, setDetail] = useState<Row | null>(null);
  const [runsVersion, setRunsVersion] = useState(0);
  useEffect(() => {
    setRuns(null); setDetail(null);
    if (!selected || selected === "new") return;
    let live = true, lastRead = "";
    const readRuns = async () => {
      const data = await read<Reply>(`/v1/schedules?id=${encodeURIComponent(selected)}`);
      if (!live) return;
      if (data) {
        setRuns(data.runs ?? []); setDetail(data.schedule ?? null);
        const resultKey = (data.runs ?? []).map(r => `${r.id}:${r.state}:${r.ended}`).join("|");
        if (!document.hidden && !readOnly && resultKey && resultKey !== lastRead) {
          const acknowledged = await read("/v1/schedules", { method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify({ action: "read", id: selected, idempotency_key: crypto.randomUUID() }) });
          if (live && acknowledged) { lastRead = resultKey; await refresh(); }
        }
      } else setError(tr("暂时无法读取任务详情，请稍后重试。", "Could not read schedule details. Please retry."));
    };
    void readRuns(); const timer = setInterval(() => { if (!document.hidden) void readRuns(); }, 15000);
    return () => { live = false; clearInterval(timer); };
  }, [selected, readOnly, refresh, read, runsVersion]);
  async function act(action: string, spec: Spec) {
    if (busy || readOnly) return;
    const requestedSelection = selected;
    const body = action === "create" || action === "update" ? { action, ...(spec.id ? { id: spec.id, revision: spec.revision } : {}), name: spec.name, prompt: spec.prompt, agent: spec.agent ?? "", ...(spec.once_at ? {} : spec.trigger ? { trigger: spec.trigger } : spec.cron ? { cron: spec.cron } : { at: spec.at }), ...(spec.execution ? { execution: spec.execution } : {}), timezone: spec.timezone, delivery: spec.delivery, repo: spec.repo ?? "" } : { action, id: spec.id, revision: spec.revision };
    const signature = JSON.stringify(body);
    if (!idem.current || idem.current.signature !== signature) idem.current = { signature, key: crypto.randomUUID() };
    setBusy(true); setError("");
    const result = await sendJSON<Reply>("POST", "/v1/schedules", { ...body, idempotency_key: idem.current.key });
    setBusy(false);
    if (selection.current !== requestedSelection) { await refresh(); return; }
    if (!result.ok) { setError(result.error || tr("请求未确认，请重试。", "Request not confirmed. Retry.")); return; }
    if (action === "create") setCreated(scheduleReceipt("schedule", result.data));
    idem.current = null; setEdit(null); setDeleting(null); await refresh(); setRunsVersion(v => v + 1);
    if (action === "delete") go("/?schedules=1");
    else if (result.data?.schedule) go(schedulePath(result.data.schedule.spec.id), { replace: action !== "create" });
  }
  const selectedRow = rows?.find(r => r.spec.id === selected) ?? (detail?.spec.id === selected ? detail : null);
  const editFromLink = new URLSearchParams(search).get("edit") === "1";
  const editOpened = useRef("");
  useEffect(() => {
    if (!editFromLink) { editOpened.current = ""; return; }
    if (selectedRow && editOpened.current !== selectedRow.spec.id) {
      editOpened.current = selectedRow.spec.id; setEdit(structuredClone(selectedRow.spec));
    }
  }, [editFromLink, selectedRow]);
  const actions = (row: Row, compact = false) => <ScheduleActions row={row} compact={compact} disabled={busy || readOnly} act={act} edit={() => setEdit(structuredClone(row.spec))} remove={() => setDeleting(row)} />;
  return <div className="mx-auto max-w-5xl space-y-5 p-4 md:p-6">
    <header className="space-y-3 border-b pb-4">
      <div className="flex flex-wrap items-center justify-between gap-3"><h1 className="text-xl font-semibold">⏰ {selectedRow?.spec.name || tr("定时任务", "Schedules")}</h1>
        {selectedRow && !edit ? actions(selectedRow) : <div className="flex gap-2"><Button variant="ghost" size="sm" onClick={() => go("/")}>{tr("‹ 会话", "‹ Sessions")}</Button>{!edit && <Button size="sm" disabled={readOnly} onClick={() => go(schedulePath("new"))}>{tr("＋ 新建", "+ New")}</Button>}</div>}
      </div>
      {selectedRow && !edit ? <><div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-muted-foreground"><span>{recurrence(selectedRow.spec)} · {selectedRow.spec.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : selectedRow.spec.timezone}</span><AgentChip spec={selectedRow.spec} /><span>{deliveryLabel(selectedRow.spec)}</span><span>{tr("下次", "Next")} {date(selectedRow.spec.enabled ? selectedRow.observed.next_run : undefined, selectedRow.spec.timezone)}</span></div><p className="text-xs text-muted-foreground">{scheduleStatus(selectedRow)} · {tr("运行使用你自己的额度。", "Runs use your own allowance.")}</p></> : !edit && <p className="text-xs text-muted-foreground">{tr("已建", "Saved")} {rows?.length ?? "—"} / 10 · {tr("最快每小时一次，每天最多 24 次计划运行", "Hourly or slower; up to 24 planned runs a day")}</p>}
    </header>
    {created && created.id === selected && !edit && <ScheduleReceipt receipt={created} />}
    {feedError && <p role="status" className="text-sm text-muted-foreground">{feedError}{expired && <a href="/app/signin" className="ml-2 underline">{tr("重新登录", "Sign in again")}</a>}</p>}
    {error && <p role="alert" className="rounded-lg border border-destructive p-3 text-sm text-destructive">{error}</p>}
    {edit && <form className={panel} onSubmit={e => { e.preventDefault(); void act(edit.id ? "update" : "create", edit); }}>
      <h2 className="font-semibold">{edit.id ? tr("编辑任务", "Edit schedule") : tr("新建任务", "New schedule")}</h2>
      <label className="block space-y-1"><span>{tr("名称", "Name")}</span><Input required maxLength={120} value={edit.name} onChange={e => setEdit({ ...edit, name: e.target.value })} /></label>
      <label className="block space-y-1"><span>{tr("要做什么", "What should it do?")}</span><Textarea required maxLength={16000} rows={4} value={edit.prompt} onChange={e => setEdit({ ...edit, prompt: e.target.value })} /></label>
      <label className="block space-y-1"><span>{tr("Agent 类型", "Agent type")}</span><select className="h-9 w-full rounded-md border bg-background px-3 text-sm" value={edit.agent ?? ""} onChange={e => setEdit({ ...edit, agent: e.target.value as Spec["agent"] })}><option value="">{tr("跟随 fleet 默认", "Fleet default")}</option><option value="claude">Claude</option><option value="codex">Codex</option></select></label>
      {!edit.id && <label className="block space-y-1"><span>{tr("何时执行", "When to run")}</span><select className="block h-9 w-full rounded-md border bg-background px-3" value={edit.trigger?.type ?? "recurring"} onChange={e => setEdit({ ...edit, trigger: e.target.value === "recurring" ? undefined : { type: e.target.value as "now" | "once", ...(e.target.value === "once" ? { at: "" } : {}) } })}><option value="recurring">{tr("重复执行", "Recurring")}</option><option value="now">{tr("立即执行一次", "Run once now")}</option><option value="once">{tr("指定时间，仅一次", "Once at a specified time")}</option></select></label>}
      {edit.trigger?.type === "once" && <label className="block space-y-1"><span>{tr("日期时间（含时区偏移）", "Date and time (include UTC offset)")}</span><Input required value={edit.trigger.at ?? ""} placeholder="2027-01-01T07:00:00+08:00" onChange={e => setEdit({ ...edit, trigger: { type: "once", at: e.target.value } })} /><span className="text-xs text-muted-foreground">{tr("例如 +08:00 表示北京时间；执行后不会重复。", "For example, +08:00 means Beijing time. This runs only once.")}</span></label>}
      {(!!edit.once_at || !!edit.trigger) && <p className="text-sm text-muted-foreground">{tr("一次性任务默认不自动重试；最长运行 1 小时。运行环境未就绪时排队等待。", "One-shot jobs do not retry by default and have a one-hour deadline. They wait for an available runtime.")}</p>}
      {!edit.once_at && !edit.trigger && <>
      <div className="grid gap-3 sm:grid-cols-2"><label className="block space-y-1"><span>{tr("每天的时间", "Daily time")}</span><Input type="time" disabled={!!edit.cron} value={edit.at ?? "07:00"} onChange={e => setEdit({ ...edit, at: e.target.value })} /></label><label className="block space-y-1"><span>{tr("时区", "Timezone")}</span><Input required value={edit.timezone} onChange={e => setEdit({ ...edit, timezone: e.target.value })} /></label></div>
      <details><summary className="cursor-pointer py-2 text-sm">{tr("自定义重复时间", "Custom recurrence")}</summary><label className="block space-y-1"><span className="text-sm">{tr("五段 cron，留空则每天运行", "Five-field cron; leave empty for daily")}</span><Input value={edit.cron ?? ""} placeholder="0 7 * * 1-5" onChange={e => setEdit({ ...edit, cron: e.target.value })} /></label></details>
      </>}
      <p className="text-sm">{recurrence(edit)} · {edit.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : edit.timezone}</p>
      <p role="status" className="text-sm text-muted-foreground">{preview ? `${tr("下次运行", "Next run")}: ${date(preview, edit.timezone)}` : previewError ? tr("请检查时间和时区，暂时无法预览。", "Check the time and timezone; preview unavailable.") : tr("正在预览时间…", "Previewing time…")}</p>
      <fieldset className="space-y-2"><legend className="mb-2 text-sm font-medium">{tr("结果投递（始终保存在站内）", "Delivery (always saved here)")}</legend>
        <label className="flex items-center gap-2"><Checkbox checked={edit.delivery.wechat} onCheckedChange={v => setEdit({ ...edit, delivery: { ...edit.delivery, wechat: v === true } })} />{tr("推到我微信", "My WeChat")}</label>
        <label className="flex items-center gap-2"><Checkbox checked={edit.delivery.livepage} onCheckedChange={v => setEdit({ ...edit, delivery: { ...edit.delivery, livepage: v === true } })} />{tr("发到私密活页", "Private live page")}</label>
        {edit.delivery.livepage && <p className="text-sm text-muted-foreground">{tr("首次发布会用你已绑定的微信为你开通个人活页，只有你能查看。", "Your linked WeChat will be used to open your private live-page account on first publish.")}</p>}
      </fieldset>
      <div className="flex gap-2"><Button disabled={busy || readOnly} type="submit">{busy ? tr("保存中…", "Saving…") : tr("保存任务", "Save schedule")}</Button><Button type="button" variant="outline" onClick={() => { setEdit(null); if (selected === "new") go("/?schedules=1"); }}>{tr("取消", "Cancel")}</Button></div>
    </form>}
    {!edit && !selected && (rows === null ? <p role="status">{tr("正在读取…", "Loading…")}</p> : rows.length === 0 ? <div className={panel}><h2 className="font-semibold">{tr("创建第一个定时任务", "Create your first schedule")}</h2><p>{tr("例如：每天早上 7 点整理群日报。首次使用会自动准备你的运行环境。", "For example: summarize the group chat every morning at 7. Your runtime is prepared automatically.")}</p></div> : rows.map(row => <article className={`${panel} ${failed(row) ? "border-destructive/40" : ""}`} key={row.spec.id}>
      <div className="flex items-start justify-between gap-3"><Link to={schedulePath(row.spec.id)} className="min-w-0 break-words font-semibold">{row.spec.name}</Link><span className={`shrink-0 text-xs ${failed(row) ? "text-destructive" : row.observed.status === "running" ? "text-blue-600" : "text-muted-foreground"}`}>{scheduleStatus(row)}</span></div>
      <div className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">{recurrence(row.spec)} · {row.spec.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : row.spec.timezone} <AgentChip spec={row.spec} /></div>
      <p className="text-xs text-muted-foreground">{tr("上次", "Last")}: {date(row.observed.last_run, row.spec.timezone)} · {tr("下次", "Next")}: {date(row.spec.enabled ? row.observed.next_run : undefined, row.spec.timezone)}</p>
      {(row.sync_note || row.observed.last_error || row.observed.last_line) && <p className={`line-clamp-2 break-words text-xs ${failed(row) ? "text-destructive" : "text-muted-foreground"}`}>{row.sync_note || row.observed.last_error || row.observed.last_line}</p>}
      {actions(row, true)}
    </article>))}
    {selectedRow && !edit && (selectedRow.sync_note || selectedRow.observed.stale || !selectedRow.spec.enabled) && <p role="status" className="text-xs text-muted-foreground">{selectedRow.sync_note || (selectedRow.observed.stale ? tr("运行状态尚未更新，显示上次记录。", "Runtime status is stale; showing the last observation.") : tr("暂停未来运行；已经开始的本次会继续。立即运行一次后仍保持暂停。", "Future runs are paused. An active run continues. A manual run keeps the schedule paused."))}</p>}
    {deleting && <div role="alertdialog" aria-label={tr("删除任务", "Delete schedule")} className={panel}><p>{tr("删除后不再自动运行；正在运行的本次继续，已有结果保留 30 天。", "Stops future runs. An active run continues; results remain for 30 days.")} <b>{deleting.spec.name}</b></p><div className="flex gap-2"><Button variant="destructive" disabled={busy || readOnly} onClick={() => void act("delete", deleting.spec)}>{tr("确认删除", "Delete")}</Button><Button variant="outline" onClick={() => setDeleting(null)}>{tr("取消", "Cancel")}</Button></div></div>}
    {selected && selected !== "new" && !edit && <section className="space-y-3"><h2 className="text-sm font-medium text-muted-foreground">{tr("运行记录 · 点一行打开那次会话", "Run history · select a row to open its conversation")}</h2>
      {runs === null ? <p>{tr("正在读取…", "Loading…")}</p> : runs.length === 0 ? <p className={panel}>{tr("还没有运行记录。", "No runs yet.")}</p> : <RunHistory runs={runs} zone={selectedRow?.spec.timezone ?? "Asia/Shanghai"} />}
    </section>}
    {selectedRow && !edit && <section className="space-y-3"><h2 className="text-sm font-medium text-muted-foreground">{tr("要做什么", "Prompt")}</h2><pre className="whitespace-pre-wrap break-words rounded-xl border bg-card p-4 font-mono text-xs leading-relaxed">{selectedRow.spec.prompt}</pre><p className="break-words font-mono text-xs text-muted-foreground">{tr("日志末行", "Last log line")} · {selectedRow.observed.last_line || "—"}</p></section>}
  </div>;
}
const failed = (row: Row) => row.observed.status === "failed" || row.observed.last_result === "failed";
export const deliveryLabel = (s: Spec) => [tr("站内通知", "In-app notice"), ...(s.delivery.wechat ? [tr("本人微信", "My WeChat")] : []), ...(s.delivery.livepage ? [tr("私密活页", "Private live page")] : [])].join(" · ");
function ScheduleActions({ row, compact, disabled, act, edit, remove }: { row: Row; compact: boolean; disabled: boolean; act: (action: string, spec: Spec) => Promise<void>; edit: () => void; remove: () => void }) {
  const s = row.spec, locked = disabled || s.deleted;
  return <div className="flex flex-wrap items-center gap-2">
    {compact && <Button asChild size="sm" variant="outline"><Link to={schedulePath(s.id)}>{row.observed.status === "running" ? tr("查看本次", "Current run") : tr("查看记录", "History")}</Link></Button>}
    {(!compact || failed(row)) && <Button size="sm" disabled={locked || !!s.once_at || row.sync_state !== "synced" || row.observed.status === "running"} onClick={() => void act("run-now", s)}>▶ {tr("立即运行", "Run now")}</Button>}
    <Button size="sm" variant="outline" disabled={locked} onClick={() => void act(s.enabled ? "pause" : "resume", s)}>{s.enabled ? tr("⏸ 暂停", "⏸ Pause") : tr("▶ 恢复", "▶ Resume")}</Button>
    {!compact && <Button size="sm" variant="outline" disabled={locked} onClick={edit}>{tr("编辑", "Edit")}</Button>}
    <DropdownMenu><DropdownMenuTrigger asChild><Button size="sm" variant="outline" aria-label={tr("更多任务操作", "More schedule actions")}>⋯</Button></DropdownMenuTrigger><DropdownMenuContent align="end">
      {compact && <DropdownMenuItem disabled={locked || !!s.once_at || row.sync_state !== "synced" || row.observed.status === "running"} onSelect={() => void act("run-now", s)}>{tr("立即运行", "Run now")}</DropdownMenuItem>}
      {compact && <DropdownMenuItem disabled={locked} onSelect={edit}>{tr("编辑", "Edit")}</DropdownMenuItem>}
      <DropdownMenuItem className="text-destructive" disabled={locked} onSelect={remove}>{tr("删除", "Delete")}</DropdownMenuItem>
    </DropdownMenuContent></DropdownMenu>
  </div>;
}
const columns = "grid grid-cols-2 items-start gap-2 px-3 py-3 sm:grid-cols-[9rem_8rem_minmax(0,1fr)_9rem]";
function RunHistory({ runs, zone }: { runs: Run[]; zone: string }) {
  return <div className="overflow-hidden rounded-xl border bg-card" role="table" aria-label={tr("运行记录", "Run history")}>
    <div role="row" className={`${columns} hidden bg-muted/40 text-xs text-muted-foreground sm:grid`}>{[tr("时间", "Time"), tr("结果", "Result"), tr("结论", "Conclusion"), tr("投递", "Delivery")].map(t => <span role="columnheader" key={t}>{t}</span>)}</div>
    {runs.map(run => {
      const summary = (run.summary || run.error || tr("正在等待本次最终结论…", "Waiting for the final answer…")).split("\n")[0];
      const duration = run.ended > run.started && run.started > 0 ? `${Math.max(1, Math.round((run.ended - run.started) / 60))} ${tr("分", "min")}` : "";
      const cells = <><span role="cell" className="text-xs">{date(run.started, zone)}</span><span role="cell"><span className={`inline-block rounded-full px-2 py-0.5 text-xs ${run.state === "failed" ? "bg-destructive/10 text-destructive" : run.state === "running" ? "bg-blue-500/10 text-blue-600" : run.state === "ok" || run.state === "succeeded" ? "bg-emerald-500/10 text-emerald-700" : "bg-muted text-muted-foreground"}`}>{words[run.state] ?? run.state} {duration}</span>{run.attempt > 1 && <span className="mt-1 block text-xs text-muted-foreground">{tr("重试", "Retry")} {run.attempt - 1}</span>}</span><span role="cell" className="col-span-2 min-w-0 text-sm sm:col-span-1"><span className="line-clamp-2 break-words">{summary}</span>{run.session_id && <span className="text-xs text-clay">{tr("打开会话", "Open conversation")} ›</span>}</span><span role="cell" className="col-span-2 flex flex-wrap gap-1 sm:col-span-1">{[[run.delivery.wechat_channel === "email" ? tr("邮件（微信未送达）", "Email (WeChat unavailable)") : tr("微信", "WeChat"), run.delivery.wechat], [tr("活页", "Live page"), run.delivery.livepage]].filter(([, state]) => state).map(([channel, state]) => <span key={channel} className={`rounded-full px-2 py-0.5 text-xs ${state === "sent" ? "bg-emerald-500/10 text-emerald-700" : "bg-muted text-muted-foreground"}`}>{channel} · {words[state!] ?? state}</span>)}{!run.delivery.wechat && !run.delivery.livepage && "—"}</span></>;
      return <div key={run.id} className="border-t first:border-0">{run.session_id ? <Link role="row" className={`${columns} text-foreground no-underline hover:bg-muted/50 focus-visible:bg-muted`} to={`/s/${encodeURIComponent("fid:" + run.session_id)}`} aria-label={`${tr("打开完整对话", "Open conversation")} · ${date(run.started, zone)}`}>{cells}</Link> : <div role="row" className={columns}>{cells}</div>}{run.delivery.url && <a className="mx-3 mb-3 inline-block text-xs text-clay underline" href={run.delivery.url} target="_blank" rel="noreferrer">{tr("打开私密活页", "Open private live page")}</a>}</div>;
    })}
  </div>;
}
