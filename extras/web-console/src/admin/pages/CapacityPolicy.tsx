// Subscription capacity evidence and safe routing preview. No account weights.
import * as React from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { api } from "../api";
import type { Sub } from "../pool";

type Profile = {
  plan: string; tier: string; pool: string; unit: string; basis: string; source: string; version: string;
  confidence: string; effective_from: string; effective_to?: string;
  windows: { minutes: number; units: number; source?: string }[];
};
type ProviderCatalog = { mode: string; profiles: Profile[] };
type Catalog = ProviderCatalog & { providers?: Record<string, ProviderCatalog> };
type Revision = { revision: number; catalog: Catalog; actor: string; at: string };
const path = "/v1/fleet/plans/capacity";
const empty = (provider: string): Profile => ({ plan: "", tier: "", pool: provider, unit: "", basis: "", source: "", version: "", confidence: "provisional", effective_from: new Date().toISOString(), windows: [] });

function TextField({ label, value, onChange }: { label: string; value: string; onChange: (v: string) => void }) {
  return <Label className="grid gap-1 text-xs">{label}<Input value={value} onChange={e => onChange(e.target.value)} /></Label>;
}

export function CapacityPolicy() {
  const [open, setOpen] = React.useState(false);
  const [current, setCurrent] = React.useState<Revision | null>(null);
  const [history, setHistory] = React.useState<Revision[]>([]);
  const [draft, setDraft] = React.useState<Catalog>({ mode: "off", profiles: [] });
  const [provider, setProvider] = React.useState("codex");
  const [model, setModel] = React.useState("claude-sonnet-4-6");
  const selected = provider === "codex" ? draft : draft.providers?.[provider] || { mode: "off", profiles: [] };
  const setSelected = (change: (c: ProviderCatalog) => ProviderCatalog) => setDraft(d => provider === "codex" ? { ...d, ...change(d) } : { ...d, providers: { ...d.providers, [provider]: change(d.providers?.[provider] || { mode: "off", profiles: [] }) } });
  const [busy, setBusy] = React.useState(false);
  const [worker, setWorker] = React.useState("");
  const [newSession, setNewSession] = React.useState(false);
  const [preview, setPreview] = React.useState<any>(null);
  const load = async () => {
    const body = await api<{ current: Revision; history: Revision[] }>(path);
    setCurrent(body.current); setDraft(body.current.catalog); setHistory(body.history); setPreview(null);
  };
  React.useEffect(() => { if (open) load().catch(e => toast.error(e.message)); }, [open]);
  const update = (i: number, change: Partial<Profile>) => {
    setSelected(d => ({ ...d, profiles: d.profiles.map((p, j) => j === i ? { ...p, ...change } : p) })); setPreview(null);
  };
  const save = async () => {
    if (!current) return;
    setBusy(true);
    try { await api(path, { method: "PUT", json: { expected_revision: current.revision, catalog: draft } }); await load(); toast.success("Capacity catalog saved / 容量目录已保存"); }
    catch (e: any) { toast.error(e.message); } finally { setBusy(false); }
  };
  return <Dialog open={open} onOpenChange={setOpen}>
    <DialogTrigger asChild><Button variant="outline">订阅容量路由 / Capacity</Button></DialogTrigger>
    <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
      <DialogHeader><DialogTitle>订阅容量路由 / Capacity routing</DialogTitle><DialogDescription>按套餐和确认的档位登记容量；不是实际 token 数。金额不参与容量估算。Register comparable work estimates by plan and tier; provisional estimates have low confidence and are not official capacity.</DialogDescription></DialogHeader>
      <Label className="grid gap-1">Provider / 服务商<Select value={provider} onValueChange={v => { setProvider(v); setPreview(null); }}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="codex">Codex</SelectItem><SelectItem value="claude">Claude</SelectItem></SelectContent></Select></Label>
      {provider === "claude" && <p className="text-xs">官方仅确认 5h 相对容量：Pro 1、Max5 5、Max20 20。周容量未知；5h、周及适用模型限制始终决定能否使用。金额不参与。 / Five-hour estimate only; weekly capacity is unknown without separate evidence.</p>}
      <Label className="grid gap-1">模式 / Mode
        <Select value={selected.mode} onValueChange={mode => { setSelected(d => ({ ...d, mode })); setPreview(null); }}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent>
          <SelectItem value="off">Off · 保守策略</SelectItem><SelectItem value="shadow">Shadow · 仅预览</SelectItem><SelectItem value="active">Active · 下次独立请求生效</SelectItem>
        </SelectContent></Select>
      </Label>
      <p className="text-xs text-muted-foreground">Provisional profiles are low-confidence operator estimates, not official multipliers. Effective provisional and verified profiles affect capacity estimates; confidence stays explicit. Missing profiles or readings remain unknown. Calibration: 1, pending matched observations. Saves do not rebind sessions. / 已登记且在有效期内的容量估计参与路由（保留确认程度）；保存不会批量换绑会话。</p>
      {selected.profiles.map((p, i) => <fieldset key={i} className="grid gap-3 rounded-md border p-3">
        <legend className="px-1 text-sm">{p.plan || "New plan"} / {p.tier || "unspecified tier"}</legend>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {([ ["plan", "Provider plan / 检测到的套餐"], ["tier", "Registered tier / 登记档位"], ["unit", "Comparable unit / 可比工作单位"], ["basis", "Comparison basis / 可比依据"], ["source", "Evidence source / 确认来源"], ["version", "Evidence version / 版本"], ["effective_from", "Effective from / 生效时间 (RFC3339)"], ["effective_to", "Effective until / 失效时间 (可空)"] ] as const).map(([key, label]) => <TextField key={key} label={label} value={p[key] || ""} onChange={value => update(i, { [key]: value || (key === "effective_to" ? undefined : "") })} />)}
        </div>
        <Label className="grid gap-1">确认程度 / Confidence<Select value={p.confidence} onValueChange={confidence => update(i, { confidence })}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="provisional">Provisional · 低置信度运营估计</SelectItem><SelectItem value="verified">Verified · 已确认</SelectItem></SelectContent></Select></Label>
        <p className="text-xs text-muted-foreground">{provider === "claude" ? "5h is the estimate baseline. Weekly and applicable model limits always gate eligibility, even without a weekly baseline. / 5h 是估计基线；未登记周基线仍检查周与模型限制。" : "Select every expected window. Weekly-only profiles require explicit evidence. / 勾选所有应有窗口；仅周窗口套餐须有明确依据。"}</p>
        {[300, 10080].map(minutes => {
          const window = p.windows.find(w => w.minutes === minutes);
          return <div key={minutes} className="flex flex-wrap items-center gap-3"><Label className="flex items-center gap-2"><input type="checkbox" checked={!!window} onChange={e => update(i, { windows: e.target.checked ? [...p.windows, { minutes, units: 1 }] : p.windows.filter(w => w.minutes !== minutes) })} />{minutes === 300 ? "5h" : "7d"} · {provider}</Label>{window && <TextField label="Baseline work units / 容量基准" value={String(window.units)} onChange={v => update(i, { windows: p.windows.map(w => w.minutes === minutes ? { ...w, units: Number(v) } : w) })} />}{provider === "claude" && minutes === 10080 && window && <TextField label="Separate weekly evidence / 独立周容量证据" value={window.source || ""} onChange={source => update(i, { windows: p.windows.map(w => w.minutes === minutes ? { ...w, source } : w) })} />}</div>;
        })}
        <Button variant="outline" onClick={() => { setSelected(d => ({ ...d, profiles: d.profiles.filter((_, j) => i !== j) })); setPreview(null); }}>Remove profile / 清除该套餐容量</Button>
      </fieldset>)}
      <div className="flex flex-wrap gap-2"><Button variant="outline" onClick={() => setSelected(d => ({ ...d, profiles: [...d.profiles, empty(provider)] }))}>Add plan profile / 添加套餐容量</Button><Button disabled={!current || busy} onClick={save}>Save catalog / 保存</Button><Button variant="outline" onClick={() => load().catch(e => toast.error(e.message))}>Reload / 重新读取</Button></div>
      <p className="text-xs text-muted-foreground">Revision {current?.revision ?? "—"} · {current?.actor} · {current?.at}</p>
      <details><summary className="cursor-pointer text-sm">History & rollback / 历史与恢复</summary><div className="grid gap-2 py-2">{history.map(r => <div key={r.revision} className="flex flex-wrap items-center gap-2 text-xs"><span>v{r.revision} · {r.at} · {r.actor}</span><Button variant="outline" size="sm" onClick={() => { setDraft(r.catalog); setPreview(null); }}>Load as draft / 载入后保存</Button></div>)}</div></details>
      <hr />
      <h3 className="text-sm font-medium">Safe preview / 安全预览</h3>
      <p className="text-xs text-muted-foreground">Uses the saved catalog and a live worker’s authorized subscriptions. No inference, refresh or binding writes. / 使用已保存目录与该会话的权限，不推理、不刷新凭据、不换绑。</p>
      {provider === "claude" && <TextField label="Request model / 请求模型" value={model} onChange={setModel} />}
      <TextField label="Live worker ID / 在线会话身份" value={worker} onChange={setWorker} />
      <Label className="flex items-center gap-2"><input type="checkbox" checked={newSession} onChange={e => setNewSession(e.target.checked)} />Preview first pick (ignore sticky binding) / 模拟首次分配</Label>
      <Button variant="outline" disabled={!worker || busy} onClick={async () => { setBusy(true); try { setPreview(await api("/v1/fleet/credproxy/preview", { json: { worker_id: worker, new_session: newSession, provider, ...(provider === "claude" ? { model } : {}) } })); } catch (e: any) { toast.error(e.message); } finally { setBusy(false); } }}>Preview saved policy / 预览已保存策略</Button>
      {preview && <div className="grid gap-3 text-sm">
        <p>v{preview.catalog_revision} · {preview.mode} · Proposed: {preview.proposed.owner}/{preview.proposed.account} · {preview.proposed.reason}</p>
        <p>Current policy: {preview.current_policy.owner}/{preview.current_policy.account} · {preview.current_policy.reason}</p>
        {preview.inputs.map((q: any) => <div key={`${q.owner}/${q.account}`} className="rounded-md border p-3">
          <p>{q.owner}/{q.account} · {q.state} · {q.reason}</p>
          {provider === "claude" ? <>
          <p>Observed / 观测: {q.observed_plan || "unknown"} / {q.observed_tier || "unknown"} · {q.metadata_observed_at || "unknown time"} · age {q.observed_age_seconds ?? "unknown"}s · {q.observed_source}</p>
          <p>Registered / 登记: {q.registered_plan || "none"} / {q.registered_tier || "none"} · {q.metadata_status} · {q.registered_source} · {q.registered_confidence} · age {q.registered_age_seconds ?? "unknown"}s · {q.registered_at}</p>
          <p>5h estimate: {q.estimated_five_hour_units ?? "unknown"} · {q.capacity_status} · weekly capacity: {q.weekly_capacity} · weekly remaining: {q.weekly_remaining_percent ?? "unknown"}%</p>
          <p>{q.observation_status} · {q.issues?.join(", ")}</p>
          {q.windows?.map((w: any, i: number) => <p key={i}>{w.id} · {w.model || "general"} · {w.unknown_scope ? "unknown scope" : ""} · used {w.used_percent ?? "unknown"}% · observed {w.observed_at} · reset {w.reset_at || "unknown"}</p>)}
          </> : <><p>{q.capacity.plan || "Unknown plan"} / {q.capacity.tier || "Unregistered tier"} · {q.capacity.status}</p>
          <p>Estimated remaining / 估计剩余: {q.capacity.estimated_remaining_units ?? "Unknown"} {q.capacity.profile?.unit || ""} · score {q.score ?? "Unknown"}</p>
          <p>Basis / 依据: {q.capacity.profile?.basis || "Unknown"} · {q.capacity.profile?.confidence || "Unknown"} · {q.capacity.profile?.source} · {q.capacity.profile?.version}</p>
          <p>Live pass bindings: {q.live_pass_bindings ?? "Unknown"} · Calibration {q.capacity.calibration_factor}: {q.capacity.calibration_status}</p>
          {q.windows?.map((w: any) => <p key={w.minutes}>{w.minutes} min · {w.state} · {w.remaining_percent ?? "Unknown"}% · {w.estimated_remaining_units ?? "Unknown"} units · reset {w.reset_at || "Unknown"}</p>)}</>}
        </div>)}
      </div>}
    </DialogContent>
  </Dialog>;
}

export function RegisterPlanTier({ sub, reload }: { sub: Sub; reload: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [plan, setPlan] = React.useState(sub.plan);
  const [tier, setTier] = React.useState(sub.planTier || "");
  const [source, setSource] = React.useState("");
  const [observedAt, setObservedAt] = React.useState("");
  if (!sub.cred || !["codex", "claude"].includes(sub.prov)) return null;
  return <Dialog open={open} onOpenChange={v => { setOpen(v); setPlan(sub.plan); setTier(sub.planTier || ""); }}>
    <DialogTrigger asChild><Button variant="outline" size="sm">Register tier / 登记档位</Button></DialogTrigger>
    <DialogContent><DialogHeader><DialogTitle>Subscription tier / 订阅档位</DialogTitle><DialogDescription>Register a verified tier for this provider plan. It selects a shared plan profile; it is not an account priority. A provider plan mismatch disables the capacity baseline. / 按确认信息登记；套餐不一致时容量未知。</DialogDescription></DialogHeader>
      {sub.prov === "claude" && <><TextField label="Evidence source / 确认来源（凭据身份匹配）" value={source} onChange={setSource} /><TextField label="Observed at / 观测时间 RFC3339" value={observedAt} onChange={setObservedAt} /></>}
      <TextField label="Provider plan / 套餐" value={plan} onChange={setPlan} /><TextField label="Confirmed tier / 确认档位" value={tier} onChange={setTier} />
      <Button onClick={async () => { try { await api("/v1/fleet/credentials", { json: { action: "plan", principal_id: sub.cred!.principal_id, provider: sub.prov, account: sub.cred!.account, plan, rate_limit_tier: tier, ...(sub.prov === "claude" ? { plan_evidence: { source, observed_at: observedAt, confidence: "verified" } } : {}) } }); setOpen(false); reload(); } catch (e: any) { toast.error(e.message); } }}>Save / 保存</Button>
      <Button variant="outline" onClick={async () => { try { await api("/v1/fleet/credentials", { json: { action: "plan", principal_id: sub.cred!.principal_id, provider: sub.prov, account: sub.cred!.account, plan: "", rate_limit_tier: "" } }); setOpen(false); reload(); } catch (e: any) { toast.error(e.message); } }}>Clear registration / 清除登记</Button>
    </DialogContent>
  </Dialog>;
}
