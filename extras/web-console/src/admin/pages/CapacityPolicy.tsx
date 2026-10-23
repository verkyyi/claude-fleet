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
  windows: { minutes: number; units: number }[];
};
type Catalog = { mode: string; profiles: Profile[] };
type Revision = { revision: number; catalog: Catalog; actor: string; at: string };
const path = "/v1/fleet/plans/capacity";
const empty = (): Profile => ({ plan: "", tier: "", pool: "codex", unit: "", basis: "", source: "", version: "", confidence: "provisional", effective_from: new Date().toISOString(), windows: [] });

function TextField({ label, value, onChange }: { label: string; value: string; onChange: (v: string) => void }) {
  return <Label className="grid gap-1 text-xs">{label}<Input value={value} onChange={e => onChange(e.target.value)} /></Label>;
}

export function CapacityPolicy() {
  const [open, setOpen] = React.useState(false);
  const [current, setCurrent] = React.useState<Revision | null>(null);
  const [history, setHistory] = React.useState<Revision[]>([]);
  const [draft, setDraft] = React.useState<Catalog>({ mode: "off", profiles: [] });
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
    setDraft(d => ({ ...d, profiles: d.profiles.map((p, j) => j === i ? { ...p, ...change } : p) })); setPreview(null);
  };
  const save = async () => {
    if (!current) return;
    setBusy(true);
    try { await api(path, { method: "PUT", json: { expected_revision: current.revision, catalog: draft } }); await load(); toast.success("Capacity catalog saved / 容量目录已保存"); }
    catch (e: any) { toast.error(e.message); } finally { setBusy(false); }
  };
  return <Dialog open={open} onOpenChange={setOpen}>
    <DialogTrigger asChild><Button variant="outline">Codex 容量路由 / Capacity</Button></DialogTrigger>
    <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
      <DialogHeader><DialogTitle>Codex 容量路由 / Capacity routing</DialogTitle><DialogDescription>按套餐和确认的档位登记容量；不是实际 token 数。金额不参与容量估算。Register verified comparable work units by plan and tier, never by account.</DialogDescription></DialogHeader>
      <Label className="grid gap-1">模式 / Mode
        <Select value={draft.mode} onValueChange={mode => { setDraft(d => ({ ...d, mode })); setPreview(null); }}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent>
          <SelectItem value="off">Off · 保守策略</SelectItem><SelectItem value="shadow">Shadow · 仅预览</SelectItem><SelectItem value="active">Active · 下次独立请求生效</SelectItem>
        </SelectContent></Select>
      </Label>
      <p className="text-xs text-muted-foreground">Only verified, effective profiles affect capacity estimates. Missing profiles or readings remain unknown. Calibration: 1, pending matched observations. Saves do not rebind sessions. / 仅确认且在有效期内的容量参与估算；保存不会批量换绑会话。</p>
      {draft.profiles.map((p, i) => <fieldset key={i} className="grid gap-3 rounded-md border p-3">
        <legend className="px-1 text-sm">{p.plan || "New plan"} / {p.tier || "unspecified tier"}</legend>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {([ ["plan", "Provider plan / 检测到的套餐"], ["tier", "Registered tier / 登记档位"], ["unit", "Comparable unit / 可比工作单位"], ["basis", "Comparison basis / 可比依据"], ["source", "Evidence source / 确认来源"], ["version", "Evidence version / 版本"], ["effective_from", "Effective from / 生效时间 (RFC3339)"], ["effective_to", "Effective until / 失效时间 (可空)"] ] as const).map(([key, label]) => <TextField key={key} label={label} value={p[key] || ""} onChange={value => update(i, { [key]: value || (key === "effective_to" ? undefined : "") })} />)}
        </div>
        <Label className="grid gap-1">确认程度 / Confidence<Select value={p.confidence} onValueChange={confidence => update(i, { confidence })}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="provisional">Provisional · 不参与路由</SelectItem><SelectItem value="verified">Verified · 已确认</SelectItem></SelectContent></Select></Label>
        <p className="text-xs text-muted-foreground">Select every expected window. Weekly only requires explicit evidence. A missing expected window remains unknown. / 勾选所有应有窗口；仅周窗口必须有明确依据。</p>
        {[300, 10080].map(minutes => {
          const window = p.windows.find(w => w.minutes === minutes);
          return <div key={minutes} className="flex flex-wrap items-center gap-3"><Label className="flex items-center gap-2"><input type="checkbox" checked={!!window} onChange={e => update(i, { windows: e.target.checked ? [...p.windows, { minutes, units: 1 }] : p.windows.filter(w => w.minutes !== minutes) })} />{minutes === 300 ? "5h" : "7d"} · Codex</Label>{window && <TextField label="Baseline work units / 容量基准" value={String(window.units)} onChange={v => update(i, { windows: p.windows.map(w => w.minutes === minutes ? { ...w, units: Number(v) } : w) })} />}</div>;
        })}
        <Button variant="outline" onClick={() => { setDraft(d => ({ ...d, profiles: d.profiles.filter((_, j) => i !== j) })); setPreview(null); }}>Remove profile / 清除该套餐容量</Button>
      </fieldset>)}
      <div className="flex flex-wrap gap-2"><Button variant="outline" onClick={() => setDraft(d => ({ ...d, profiles: [...d.profiles, empty()] }))}>Add plan profile / 添加套餐容量</Button><Button disabled={!current || busy} onClick={save}>Save catalog / 保存</Button><Button variant="outline" onClick={() => load().catch(e => toast.error(e.message))}>Reload / 重新读取</Button></div>
      <p className="text-xs text-muted-foreground">Revision {current?.revision ?? "—"} · {current?.actor} · {current?.at}</p>
      <details><summary className="cursor-pointer text-sm">History & rollback / 历史与恢复</summary><div className="grid gap-2 py-2">{history.map(r => <div key={r.revision} className="flex flex-wrap items-center gap-2 text-xs"><span>v{r.revision} · {r.at} · {r.actor}</span><Button variant="outline" size="sm" onClick={() => { setDraft(r.catalog); setPreview(null); }}>Load as draft / 载入后保存</Button></div>)}</div></details>
      <hr />
      <h3 className="text-sm font-medium">Safe preview / 安全预览</h3>
      <p className="text-xs text-muted-foreground">Uses the saved catalog and a live worker’s authorized subscriptions. No inference, refresh or binding writes. / 使用已保存目录与该会话的权限，不推理、不刷新凭据、不换绑。</p>
      <TextField label="Live worker ID / 在线会话身份" value={worker} onChange={setWorker} />
      <Label className="flex items-center gap-2"><input type="checkbox" checked={newSession} onChange={e => setNewSession(e.target.checked)} />Preview first pick (ignore sticky binding) / 模拟首次分配</Label>
      <Button variant="outline" disabled={!worker || busy} onClick={async () => { setBusy(true); try { setPreview(await api("/v1/fleet/credproxy/preview", { json: { worker_id: worker, new_session: newSession } })); } catch (e: any) { toast.error(e.message); } finally { setBusy(false); } }}>Preview saved policy / 预览已保存策略</Button>
      {preview && <div className="grid gap-3 text-sm">
        <p>v{preview.catalog_revision} · {preview.mode} · Proposed: {preview.proposed.owner}/{preview.proposed.account} · {preview.proposed.reason}</p>
        <p>Current policy: {preview.current_policy.owner}/{preview.current_policy.account} · {preview.current_policy.reason}</p>
        {preview.inputs.map((q: any) => <div key={`${q.owner}/${q.account}`} className="rounded-md border p-3">
          <p>{q.owner}/{q.account} · {q.state} · {q.reason}</p>
          <p>{q.capacity.plan || "Unknown plan"} / {q.capacity.tier || "Unregistered tier"} · {q.capacity.status}</p>
          <p>Estimated remaining / 估计剩余: {q.capacity.estimated_remaining_units ?? "Unknown"} {q.capacity.profile?.unit || ""} · score {q.score ?? "Unknown"}</p>
          <p>Basis / 依据: {q.capacity.profile?.basis || "Unknown"} · {q.capacity.profile?.confidence || "Unknown"} · {q.capacity.profile?.source} · {q.capacity.profile?.version}</p>
          <p>Live pass bindings: {q.live_pass_bindings ?? "Unknown"} · Calibration {q.capacity.calibration_factor}: {q.capacity.calibration_status}</p>
          {q.windows?.map((w: any) => <p key={w.minutes}>{w.minutes} min · {w.state} · {w.remaining_percent ?? "Unknown"}% · {w.estimated_remaining_units ?? "Unknown"} units · reset {w.reset_at || "Unknown"}</p>)}
        </div>)}
      </div>}
    </DialogContent>
  </Dialog>;
}

export function RegisterPlanTier({ sub, reload }: { sub: Sub; reload: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [plan, setPlan] = React.useState(sub.plan);
  const [tier, setTier] = React.useState(sub.planTier || "");
  if (!sub.cred || sub.prov !== "codex") return null;
  return <Dialog open={open} onOpenChange={v => { setOpen(v); setPlan(sub.plan); setTier(sub.planTier || ""); }}>
    <DialogTrigger asChild><Button variant="outline" size="sm">Register tier / 登记档位</Button></DialogTrigger>
    <DialogContent><DialogHeader><DialogTitle>Subscription tier / 订阅档位</DialogTitle><DialogDescription>Register a verified tier for this provider plan. It selects a shared plan profile; it is not an account priority. A provider plan mismatch disables the capacity baseline. / 按确认信息登记；套餐不一致时容量未知。</DialogDescription></DialogHeader>
      <TextField label="Provider plan / 套餐" value={plan} onChange={setPlan} /><TextField label="Confirmed tier / 确认档位" value={tier} onChange={setTier} />
      <Button onClick={async () => { try { await api("/v1/fleet/credentials", { json: { action: "plan", principal_id: sub.cred!.principal_id, provider: "codex", account: sub.cred!.account, plan, rate_limit_tier: tier } }); setOpen(false); reload(); } catch (e: any) { toast.error(e.message); } }}>Save / 保存</Button>
      <Button variant="outline" onClick={async () => { try { await api("/v1/fleet/credentials", { json: { action: "plan", principal_id: sub.cred!.principal_id, provider: "codex", account: sub.cred!.account, plan: "", rate_limit_tier: "" } }); setOpen(false); reload(); } catch (e: any) { toast.error(e.message); } }}>Clear registration / 清除登记</Button>
    </DialogContent>
  </Dialog>;
}
