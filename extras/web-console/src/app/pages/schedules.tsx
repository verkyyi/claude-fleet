import { useCallback, useEffect, useRef, useState } from "react";
import { useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import { lang, tr } from "@/shared/i18n";
import { getJSON, sendJSON } from "@/shared/api";
import { usePage, useShell } from "../Shell";

type Spec = { id: string; revision: number; name: string; prompt: string; at?: string; cron?: string; timezone: string; enabled: boolean; deleted: boolean; delivery: { wechat: boolean; livepage: boolean }; repo?: string };
type Row = { spec: Spec; sync_state: string; sync_note: string; observed: { status?: string; last_run?: number; next_run?: number; last_result?: string; last_line?: string; last_error?: string; stale?: boolean } };
type Run = { id: string; state: string; started: number; ended: number; summary: string; error: string; delivery: { wechat?: string; wechat_channel?: string; livepage?: string; url?: string }; session_id: string };
type Reply = { schedule?: Row; runs?: Run[] };
const initial = (): Spec => ({ id: "", revision: 0, name: "", prompt: "", at: "07:00", timezone: "Asia/Shanghai", enabled: true, deleted: false, delivery: { wechat: false, livepage: false } });
const panel = "rounded-xl border bg-card p-4 sm:p-5 space-y-3";
function date(t: number | undefined, zone: string) { if (!t) return "—"; try { return new Intl.DateTimeFormat(lang === "zh" ? "zh-CN" : "en-US", { timeZone: zone, month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(t * 1000); } catch { return "—"; } }
const words: Record<string, string> = {
  scheduled: tr("等待运行", "Scheduled"), running: tr("运行中", "Running"), waiting: tr("等待运行条件", "Waiting"),
  retrying: tr("等待重试", "Retrying"), ok: tr("已完成", "Completed"), succeeded: tr("已完成", "Completed"),
  failed: tr("运行失败", "Failed"), stopped: tr("已暂停", "Paused"), pending: tr("等待确认", "Pending"),
  synced: tr("已登记", "Registered"), sent: tr("已发送", "Sent"), undelivered: tr("未送达", "Undelivered"),
  publishing: tr("发布中", "Publishing"), processing: tr("处理中或待审核", "Processing or awaiting review"),
  unconfirmed: tr("投递未确认", "Unconfirmed"), cancelled: tr("已取消", "Cancelled"),
};
export default function SchedulesPage() {
  usePage(tr("定时任务", "Schedules"));
  const { me } = useShell();
  const readOnly = !!(me?.read_only || me?.view_as);
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState("");
  const [edit, setEdit] = useState<Spec | null>(null);
  const [preview, setPreview] = useState<number | null>(null);
  const [previewError, setPreviewError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [selected, setSelected] = useState<string | null>(() => new URLSearchParams(location.search).get("id"));
  const { search } = useLocation();
  useEffect(() => { setSelected(new URLSearchParams(search).get("id")); }, [search]);
  const [runs, setRuns] = useState<Run[] | null>(null);
  const [deleting, setDeleting] = useState<Row | null>(null);
  useEffect(() => {
    setPreview(null); setPreviewError(false);
    if (!edit) return;
    let live = true;
    const q = new URLSearchParams({ preview: "1", timezone: edit.timezone, ...(edit.cron ? { cron: edit.cron } : { at: edit.at ?? "" }) });
    const timer = setTimeout(async () => { const data = await getJSON<{ next_run: number }>(`/v1/schedules?${q}`); if (live) { setPreview(data?.next_run ?? null); setPreviewError(!data); } }, 250);
    return () => { live = false; clearTimeout(timer); };
  }, [edit?.at, edit?.cron, edit?.timezone, !!edit]);
  const idem = useRef<{ signature: string; key: string } | null>(null);
  const refresh = useCallback(async () => {
    const data = await getJSON<{ schedules: Row[] }>("/v1/schedules");
    if (data) setRows(data.schedules); else setError(tr("暂时无法读取，保留上次结果。", "Could not refresh. Showing the previous result."));
  }, []);
  useEffect(() => { void refresh(); const timer = setInterval(() => { if (!document.hidden) void refresh(); }, 15000); return () => clearInterval(timer); }, [refresh]);
  const readRuns = useCallback(async () => {
    if (!selected) return;
    const data = await getJSON<Reply>(`/v1/schedules?id=${encodeURIComponent(selected)}`);
    if (data) {
      setRuns(data.runs ?? []);
      if (!document.hidden && !readOnly) await sendJSON("POST", "/v1/schedules", { action: "read", id: selected, idempotency_key: crypto.randomUUID() });
    }
  }, [selected, readOnly]);
  useEffect(() => { setRuns(null); void readRuns(); const timer = setInterval(() => { if (!document.hidden) void readRuns(); }, 15000); return () => clearInterval(timer); }, [readRuns]);
  async function act(action: string, spec: Spec) {
    if (busy || readOnly) return;
    const body = action === "create" || action === "update" ? { action, ...(spec.id ? { id: spec.id, revision: spec.revision } : {}), name: spec.name, prompt: spec.prompt, ...(spec.cron ? { cron: spec.cron } : { at: spec.at }), timezone: spec.timezone, delivery: spec.delivery, repo: spec.repo ?? "" } : { action, id: spec.id, revision: spec.revision };
    const signature = JSON.stringify(body);
    if (!idem.current || idem.current.signature !== signature) idem.current = { signature, key: crypto.randomUUID() };
    setBusy(true); setError("");
    const result = await sendJSON<Reply>("POST", "/v1/schedules", { ...body, idempotency_key: idem.current.key });
    setBusy(false);
    if (!result.ok) { setError(result.error || tr("请求未确认，请重试。", "Request not confirmed. Retry.")); return; }
    idem.current = null; setEdit(null); setDeleting(null); await refresh(); await readRuns();
  }
  const selectedRow = rows?.find(r => r.spec.id === selected);
  return <div className="mx-auto max-w-4xl space-y-5 p-4 md:p-6">
    <header className="flex flex-wrap items-center justify-between gap-3"><div><h1 className="text-2xl font-semibold">{tr("定时任务", "Schedules")}</h1><p className="mt-1 text-sm text-muted-foreground">{tr("把重复的事交给定时任务。运行使用你自己的额度。", "Automate recurring work using your own allowance.")}</p></div><Button disabled={readOnly} onClick={() => setEdit(initial())}>{tr("新建定时任务", "New schedule")}</Button></header>
    <p className="text-sm text-muted-foreground">{tr("已建", "Saved")} {rows?.length ?? "—"} / 10 · {tr("最快每小时一次，每天最多 24 次计划运行", "Hourly or slower; up to 24 planned runs a day")}</p>
    {error && <p role="alert" className="rounded-lg border border-destructive p-3 text-sm text-destructive">{error}</p>}
    {edit && <form className={panel} onSubmit={e => { e.preventDefault(); void act(edit.id ? "update" : "create", edit); }}>
      <h2 className="font-semibold">{edit.id ? tr("编辑任务", "Edit schedule") : tr("新建任务", "New schedule")}</h2>
      <label className="block space-y-1"><span>{tr("名称", "Name")}</span><Input required maxLength={120} value={edit.name} onChange={e => setEdit({ ...edit, name: e.target.value })} /></label>
      <label className="block space-y-1"><span>{tr("要做什么", "What should it do?")}</span><Textarea required maxLength={16000} rows={4} value={edit.prompt} onChange={e => setEdit({ ...edit, prompt: e.target.value })} /></label>
      <div className="grid gap-3 sm:grid-cols-2"><label className="block space-y-1"><span>{tr("每天的时间", "Daily time")}</span><Input type="time" disabled={!!edit.cron} value={edit.at ?? "07:00"} onChange={e => setEdit({ ...edit, at: e.target.value })} /></label><label className="block space-y-1"><span>{tr("时区", "Timezone")}</span><Input required value={edit.timezone} onChange={e => setEdit({ ...edit, timezone: e.target.value })} /></label></div>
      <details><summary className="cursor-pointer py-2 text-sm">{tr("自定义重复时间", "Custom recurrence")}</summary><label className="block space-y-1"><span className="text-sm">{tr("五段 cron，留空则每天运行", "Five-field cron; leave empty for daily")}</span><Input value={edit.cron ?? ""} placeholder="0 7 * * 1-5" onChange={e => setEdit({ ...edit, cron: e.target.value })} /></label></details>
      <p className="text-sm">{edit.cron || tr("每天", "Every day") + " " + edit.at} · {edit.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : edit.timezone}</p>
      <p role="status" className="text-sm text-muted-foreground">{preview ? `${tr("下次运行", "Next run")}: ${date(preview, edit.timezone)}` : previewError ? tr("请检查时间和时区，暂时无法预览。", "Check the time and timezone; preview unavailable.") : tr("正在预览时间…", "Previewing time…")}</p>
      <fieldset className="space-y-2"><legend className="mb-2 text-sm font-medium">{tr("结果投递（始终保存在站内）", "Delivery (always saved here)")}</legend>
        <label className="flex items-center gap-2"><Checkbox checked={edit.delivery.wechat} onCheckedChange={v => setEdit({ ...edit, delivery: { ...edit.delivery, wechat: v === true } })} />{tr("推到我微信", "My WeChat")}</label>
        <label className="flex items-center gap-2"><Checkbox checked={edit.delivery.livepage} onCheckedChange={v => setEdit({ ...edit, delivery: { ...edit.delivery, livepage: v === true } })} />{tr("发到私密活页", "Private live page")}</label>
        {edit.delivery.livepage && <p className="text-sm text-muted-foreground">{tr("首次发布会用你已绑定的微信为你开通个人活页，只有你能查看。", "Your linked WeChat will be used to open your private live-page account on first publish.")}</p>}
      </fieldset>
      <div className="flex gap-2"><Button disabled={busy || readOnly} type="submit">{busy ? tr("保存中…", "Saving…") : tr("保存任务", "Save schedule")}</Button><Button type="button" variant="outline" onClick={() => setEdit(null)}>{tr("取消", "Cancel")}</Button></div>
    </form>}
    {rows === null ? <p role="status">{tr("正在读取…", "Loading…")}</p> : rows.length === 0 ? <div className={panel}><h2 className="font-semibold">{tr("创建第一个定时任务", "Create your first schedule")}</h2><p>{tr("例如：每天早上 7 点整理群日报。首次使用会自动准备你的运行环境。", "For example: summarize the group chat every morning at 7. Your runtime is prepared automatically.")}</p></div> : rows.map(row => { const s = row.spec; const o = row.observed; const state = row.sync_state !== "synced" ? "pending" : !s.enabled ? "stopped" : o.status ?? "scheduled"; return <article className={panel} key={s.id}>
      <div className="flex flex-wrap justify-between gap-2"><h2 className="font-semibold">{s.name}</h2><span className={state === "failed" ? "text-destructive" : "text-muted-foreground"}>{words[state] ?? state}</span></div>
      <p className="text-sm">{s.cron || tr("每天", "Daily") + " " + s.at} · {s.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : s.timezone}</p>
      <p className="text-sm">{tr("上次", "Last")}: {date(o.last_run, s.timezone)} · {tr("下次", "Next")}: {date(s.enabled ? o.next_run : undefined, s.timezone)}</p>
      {o.stale && <p className="text-sm text-muted-foreground">{tr("运行状态尚未更新，显示上次记录。", "Runtime status is stale; showing the last observation.")}</p>}
      {(row.sync_note || o.last_error || o.last_line) && <p className="break-words text-sm text-muted-foreground">{row.sync_note || o.last_error || o.last_line}</p>}
      <div className="flex flex-wrap gap-2"><Button variant="outline" onClick={() => setSelected(s.id)}>{tr("查看结果", "Results")}</Button><Button variant="outline" disabled={busy || readOnly} onClick={() => void act(s.enabled ? "pause" : "resume", s)}>{s.enabled ? tr("暂停", "Pause") : tr("恢复", "Resume")}</Button><Button variant="outline" disabled={busy || readOnly || row.sync_state !== "synced"} onClick={() => void act("run-now", s)}>{tr("立即运行", "Run now")}</Button><Button variant="ghost" disabled={readOnly} onClick={() => setEdit(structuredClone(s))}>{tr("编辑", "Edit")}</Button><Button variant="ghost" disabled={readOnly} onClick={() => setDeleting(row)}>{tr("删除", "Delete")}</Button></div>
      {!s.enabled && <p className="text-xs text-muted-foreground">{tr("暂停未来运行；已经开始的本次会继续。立即运行一次后仍保持暂停。", "Future runs are paused. An active run continues. A manual run keeps the schedule paused.")}</p>}
    </article>; })}
    {deleting && <div role="alertdialog" aria-label={tr("删除任务", "Delete schedule")} className={panel}><p>{tr("删除后不再自动运行；正在运行的本次继续，已有结果保留 30 天。", "Stops future runs. An active run continues; results remain for 30 days.")} <b>{deleting.spec.name}</b></p><div className="flex gap-2"><Button variant="destructive" disabled={busy || readOnly} onClick={() => void act("delete", deleting.spec)}>{tr("确认删除", "Delete")}</Button><Button variant="outline" onClick={() => setDeleting(null)}>{tr("取消", "Cancel")}</Button></div></div>}
    {selected && <section className={panel}><div className="flex justify-between gap-2"><h2 className="font-semibold">{selectedRow?.spec.name} · {tr("运行结果", "Results")}</h2><Button variant="ghost" onClick={() => setSelected(null)}>{tr("关闭", "Close")}</Button></div>
      {runs === null ? <p>{tr("正在读取…", "Loading…")}</p> : runs.length === 0 ? <p>{tr("还没有运行记录。", "No runs yet.")}</p> : runs.map(run => <div className="space-y-2 border-t pt-3" key={run.id}><p className="text-sm">{date(run.started, selectedRow?.spec.timezone ?? "Asia/Shanghai")} · {words[run.state] ?? run.state}</p><p className="whitespace-pre-wrap break-words text-sm">{run.summary || run.error || tr("正在等待本次最终结论…", "Waiting for the final answer…")}</p>{run.delivery.wechat && <p className="text-xs">{run.delivery.wechat_channel === "email" ? tr("邮件（微信未送达）", "Email (WeChat unavailable)") : tr("微信", "WeChat")}: {words[run.delivery.wechat] ?? run.delivery.wechat}</p>}{run.delivery.livepage && <p className="text-xs">{tr("活页", "Live page")}: {words[run.delivery.livepage] ?? run.delivery.livepage}</p>}{run.delivery.url && <a className="text-sm underline" href={run.delivery.url} target="_blank" rel="noreferrer">{tr("打开私密活页", "Open private live page")}</a>}</div>)}
    </section>}
  </div>;
}
