// The Bubble Cloud proposal workbench (task APVZ): the studio's second profile. Its config
// areas (company · clients · templates · assets), the rendering bench and the script panel.
// Everything is read from and written to the home login's store (bin/fleet_bc_studio.py)
// through /v1/chat/studio/bc; publishing stays with the studio's right panel.
import { useCallback, useEffect, useRef, useState } from "react";
import { Crop, ImagePlus, Loader2, Plus, Sparkles, Star, Wand2, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";

export type BcClient = { id?: string; name: string; event?: string; date?: string; venue?: string; guests?: string; budget?: string;
  brand?: string; prefs?: string; contacts?: string; quote_url?: string; notes?: string; include_prices?: boolean };
export type BcTemplate = { id?: string; name: string; kind?: string; proposal_id?: string; version_id?: string; note?: string };
export type BcConfig = { rev: number; company: Record<string, string>; clients: BcClient[]; templates: BcTemplate[] };
export type BcImage = { id: string; kind: "asset" | "render"; label?: string; group?: string; proposal?: string; slide?: string;
  model?: string; prompt?: string; parent?: string; refs?: string[]; batch?: string; op?: string; status?: string; error?: string;
  cost?: number; score?: number; judge?: Record<string, number | string>; picked?: boolean; thumb?: string; at: number };
export type BcState = { config: BcConfig; assets: BcImage[]; renders: BcImage[] };
export type Script = { slide: string; title: string; text: string };

export async function bc<T>(op: string, body: Record<string, unknown> = {}): Promise<T> {
  const r = await fetch("/v1/chat/studio/bc", { method: "POST", cache: "no-store",
    headers: { "Content-Type": "application/json", "X-Fleet-Webchat": "1" }, body: JSON.stringify({ ...body, op }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(j.error || (r.status === 404 ? "工作台未开放" : "暂时连不上家机器，请重试"));
  return j as T;
}

// The store for one proposal (or every rendering when none): re-read often while something runs.
export function useBc(proposal: string) {
  const [state, setState] = useState<BcState | null>(null);
  const [error, setError] = useState("");
  const read = useCallback(async () => {
    try { setState(await bc<BcState>("read", { proposal })); setError(""); } catch (e) { setError((e as Error).message); }
  }, [proposal]);
  const running = !!state?.renders.some(r => r.status === "running");
  useEffect(() => {
    void read();
    const t = setInterval(() => { if (document.visibilityState === "visible") void read(); }, running ? 4000 : 15000);
    return () => clearInterval(t);
  }, [read, running]);
  return { state, error, read, setError };
}

// A photo shrunk in the browser before it travels (the entry takes at most 1 MB a request).
async function shrink(file: File | Blob, max = 1600, quality = 0.85): Promise<string> {
  const bmp = await createImageBitmap(file);
  const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
  const c = document.createElement("canvas");
  c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
  c.getContext("2d")!.drawImage(bmp, 0, 0, c.width, c.height);
  let q = quality, url = c.toDataURL("image/jpeg", q);
  while (url.length > 900_000 && q > 0.4) { q -= 0.1; url = c.toDataURL("image/jpeg", q); }
  return url;
}

const COMPANY_LABEL: Record<string, string> = { name: "对外名称", legal: "法人名", positioning: "定位", address: "地址", website: "官网",
  contacts: "联系方式", services: "服务", cases: "案例", procurement: "可采购资质", theme: "默认主题（客户无品牌时）", voice: "语气" };
const CLIENT_FIELDS: [keyof BcClient, string][] = [["name", "客户 / 公司"], ["event", "活动"], ["date", "日期"], ["venue", "场地"],
  ["guests", "人数"], ["budget", "预算范围"], ["brand", "品牌要求（Logo / 颜色 / 字体）"], ["prefs", "偏好与禁忌"], ["contacts", "联系人"],
  ["quote_url", "报价单链接"], ["notes", "备注"]];
const field = "w-full rounded-md border bg-background px-2 py-1 text-xs";

export function BcConfigPanel({ bcState, reload, onNew, busy }: { bcState: BcState | null; reload: () => Promise<void>;
  onNew: (client?: BcClient, template?: BcTemplate) => void; busy: boolean }) {
  const [tab, setTab] = useState("company");
  const [draft, setDraft] = useState<BcConfig | null>(null);
  const [msg, setMsg] = useState("");
  const [open, setOpen] = useState(-1);
  const cfg = draft || bcState?.config;
  useEffect(() => { if (!draft && bcState) setOpen(o => o); }, [bcState, draft]);
  const edit = (f: (c: BcConfig) => BcConfig) => setDraft(f(structuredClone(cfg!)));
  const save = async () => {
    if (!draft) return;
    try { await bc("save", { rev: draft.rev, company: draft.company, clients: draft.clients, templates: draft.templates });
      setDraft(null); setMsg("已保存，下一份方案就用新的"); await reload(); } catch (e) { setMsg((e as Error).message); }
  };
  if (!cfg) return <p className="p-4 text-xs text-muted-foreground" role="status">正在读取资料…</p>;
  return <div className="flex min-h-0 flex-1 flex-col">
    <nav className="grid grid-cols-4 gap-1 border-b p-1" aria-label="配置区">{[["company", "公司"], ["clients", "客户"], ["templates", "模板"], ["assets", "素材"]].map(([id, t]) =>
      <Button key={id} size="sm" variant={tab === id ? "secondary" : "ghost"} aria-pressed={tab === id} onClick={() => setTab(id)}>{t}</Button>)}</nav>
    {draft ? <div className="flex items-center gap-2 border-b bg-amber-50 px-3 py-1.5 text-xs dark:bg-amber-950/30"><span className="mr-auto">有未保存的修改</span>
      <Button size="sm" variant="ghost" onClick={() => setDraft(null)}>放弃</Button><Button size="sm" onClick={() => void save()}>保存</Button></div> : null}
    {msg ? <p role="status" className="border-b px-3 py-1.5 text-xs text-muted-foreground">{msg}</p> : null}
    <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-3">
      {tab === "company" ? Object.entries(cfg.company).map(([k, v]) => <label key={k} className="block text-xs font-medium">{COMPANY_LABEL[k] || k}
        <Textarea value={v} rows={k.length > 0 && v.length > 80 ? 3 : 1} className="mt-1 min-h-8 text-xs" onChange={e => edit(c => ({ ...c, company: { ...c.company, [k]: e.target.value } }))} /></label>) : null}
      {tab === "clients" ? <>
        <Button size="sm" variant="outline" className="w-full" onClick={() => { edit(c => ({ ...c, clients: [...c.clients, { name: "New client" }] })); setOpen(cfg.clients.length); }}><Plus className="size-3.5" />新客户卡</Button>
        {cfg.clients.length ? null : <p className="text-xs text-muted-foreground">还没有客户卡。每个客户一张：活动、日期、场地、品牌要求；新建方案时选它。</p>}
        {cfg.clients.map((cl, i) => <div key={cl.id || i} className="rounded-lg border p-2">
          <button className="flex w-full items-center gap-2 text-left text-sm font-medium" onClick={() => setOpen(open === i ? -1 : i)}>
            <span className="mr-auto truncate">{cl.name || "未命名"}</span><span className="text-xs text-muted-foreground">{[cl.event, cl.date].filter(Boolean).join(" · ")}</span></button>
          {open === i ? <div className="mt-2 space-y-1.5">
            {CLIENT_FIELDS.map(([k, t]) => <label key={k} className="block text-[11px] text-muted-foreground">{t}
              <input className={field} value={String(cl[k] || "")} onChange={e => edit(c => { c.clients[i] = { ...c.clients[i], [k]: e.target.value }; return c; })} /></label>)}
            <label className="flex items-center gap-2 text-xs"><input type="checkbox" checked={!!cl.include_prices} onChange={e => edit(c => { c.clients[i] = { ...c.clients[i], include_prices: e.target.checked }; return c; })} />这份方案带报价页（默认不带）</label>
            <div className="flex gap-2 pt-1">
              <Button size="sm" disabled={busy || !!draft || !cl.id} title={draft ? "先保存" : ""} onClick={() => onNew(cl)}><Sparkles className="size-3.5" />用这个客户新建方案</Button>
              <Button size="sm" variant="ghost" className="ml-auto text-destructive" onClick={() => { edit(c => ({ ...c, clients: c.clients.filter((_, j) => j !== i) })); setOpen(-1); }}>删除</Button></div>
          </div> : null}
        </div>)}
      </> : null}
      {tab === "templates" ? <>
        {cfg.templates.map((t, i) => <div key={t.id || i} className="space-y-1 rounded-lg border p-2">
          <input aria-label="模板名" className={cn(field, "font-medium")} value={t.name} onChange={e => edit(c => { c.templates[i] = { ...c.templates[i], name: e.target.value }; return c; })} />
          <div className="flex gap-1 text-[11px]"><select aria-label="类型" className="rounded border bg-background" value={t.kind || "template"} onChange={e => edit(c => { c.templates[i] = { ...c.templates[i], kind: e.target.value }; return c; })}>
            <option value="template">模板</option><option value="example">示例</option><option value="block">版块</option><option value="reference">参考</option></select>
            <input aria-label="活页 version_id" className={field} placeholder="活页 version_id" value={t.version_id || ""} onChange={e => edit(c => { c.templates[i] = { ...c.templates[i], version_id: e.target.value }; return c; })} /></div>
          <input aria-label="说明" className={field} placeholder="说明" value={t.note || ""} onChange={e => edit(c => { c.templates[i] = { ...c.templates[i], note: e.target.value }; return c; })} />
          <div className="flex gap-2"><Button size="sm" variant="outline" disabled={busy || !!draft || t.kind === "example"} onClick={() => onNew(undefined, t)}>用这套新建</Button>
            <Button size="sm" variant="ghost" className="ml-auto text-destructive" onClick={() => edit(c => ({ ...c, templates: c.templates.filter((_, j) => j !== i) }))}>移除</Button></div>
        </div>)}
        <Button size="sm" variant="outline" className="w-full" onClick={() => edit(c => ({ ...c, templates: [...c.templates, { name: "New template", kind: "template" }] }))}><Plus className="size-3.5" />登记一套模板</Button>
        <p className="text-[11px] leading-5 text-muted-foreground">做得好的方案可以登记为模板：填它在活页上的 version_id。Agent 按这里的清单读模板。</p>
      </> : null}
      {tab === "assets" ? <BcAssets bcState={bcState!} reload={reload} /> : null}
    </div>
  </div>;
}

function BcAssets({ bcState, reload }: { bcState: BcState; reload: () => Promise<void> }) {
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  const upload = async (files: FileList | null) => {
    if (!files?.length) return;
    setBusy(true); setMsg("");
    try { for (const f of Array.from(files).slice(0, 8)) await bc("asset", { data: await shrink(f), label: f.name.replace(/\.[^.]+$/, ""), group: "venue" });
      await reload(); setMsg("已上传"); } catch (e) { setMsg((e as Error).message); } finally { setBusy(false); }
  };
  const groups = [["venue", "场地照（客户提供）"], ["portfolio", "Bubble Cloud 作品照"]] as const;
  return <div className="space-y-4">
    <div className="flex flex-wrap gap-2">
      <label className={cn("inline-flex cursor-pointer items-center gap-1 rounded-md border px-2 py-1 text-xs hover:bg-muted", busy && "opacity-50")}><ImagePlus className="size-3.5" />上传场地照
        <input type="file" accept="image/*" multiple className="sr-only" disabled={busy} onChange={e => void upload(e.target.files)} /></label>
      <Button size="sm" variant="outline" disabled={busy} onClick={async () => { setMsg("正在导入作品照，约一分钟…"); try { await bc("import_portfolio"); setTimeout(() => void reload(), 20000); } catch (e) { setMsg((e as Error).message); } }}>导入作品照</Button>
    </div>
    {msg ? <p role="status" className="text-xs text-muted-foreground">{msg}</p> : null}
    {groups.map(([g, t]) => { const list = bcState.assets.filter(a => (a.group || "venue") === g); return <div key={g}>
      <h3 className="mb-1 text-xs font-semibold">{t} · {list.length}</h3>
      {list.length ? <div className="grid grid-cols-3 gap-1">{list.map(a => <figure key={a.id} title={`${a.label} · ${a.id}`} className="overflow-hidden rounded border">
        {a.thumb ? <img src={a.thumb} alt={a.label} className="aspect-square w-full object-cover" /> : null}
        <figcaption className="truncate px-1 text-[10px] text-muted-foreground">{a.label}</figcaption></figure>)}</div>
        : <p className="text-[11px] text-muted-foreground">{g === "venue" ? "客户的场地照：出效果图时当第一张参考图。" : "点「导入作品照」取官网作品照，当风格参考。"}</p>}
    </div>; })}
  </div>;
}

const MODEL: Record<string, string> = { gemini: "Gemini", gpt: "GPT-Image", seedream: "Seedream" };
type Usage = { spent: number; cap: number; models: string[] };

export function BcImageBench({ proposal, bcState, reload, say }: { proposal: string; bcState: BcState | null; reload: () => Promise<void>; say: (text: string) => Promise<void> }) {
  const [slide, setSlide] = useState("4");
  const [prompt, setPrompt] = useState("");
  const [models, setModels] = useState<string[]>(["gemini"]);
  const [n, setN] = useState(2);
  const [refs, setRefs] = useState<string[]>([]);
  const [parent, setParent] = useState("");
  const [msg, setMsg] = useState("");
  const [usage, setUsage] = useState<Usage | null>(null);
  const [view, setView] = useState<{ img: BcImage; data: string; crop: boolean } | null>(null);
  const [overCap, setOverCap] = useState<Record<string, unknown> | null>(null);
  const readUsage = useCallback(async () => { try { setUsage(await bc<Usage>("usage", { proposal })); } catch { /* shown as unknown */ } }, [proposal]);
  useEffect(() => { void readUsage(); }, [readUsage]);
  const renders = (bcState?.renders || []).filter(r => r.proposal === proposal);
  const slides = [...new Set(renders.map(r => r.slide || "?"))];
  const generate = async (extra: Record<string, unknown> = {}, override = false) => {
    setMsg("");
    const body = { proposal, slide, prompt, models, n, refs, parent, ...extra, override };
    if (!String(body.prompt).trim()) return setMsg("先写一句要什么样的效果图");
    if (usage && usage.spent >= usage.cap && !override) return setOverCap(body);
    try { await bc("generate", body); setMsg("已开始，每张约 20–90 秒"); setParent(""); await reload(); setTimeout(() => void readUsage(), 60000); }
    catch (e) { setMsg((e as Error).message); }
  };
  const open = async (img: BcImage, crop = false) => {
    try { const j = await bc<{ data: string }>("media", { id: img.id }); setView({ img, data: j.data, crop }); } catch (e) { setMsg((e as Error).message); }
  };
  return <div className="flex min-h-0 flex-1 flex-col">
    <div className="space-y-2 border-b bg-background p-3">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <label>页 <input aria-label="第几页" className="w-14 rounded border bg-background px-1" value={slide} onChange={e => setSlide(e.target.value)} /></label>
        {Object.entries(MODEL).map(([m, t]) => <label key={m} className="flex items-center gap-1"><input type="checkbox" checked={models.includes(m)}
          onChange={e => setModels(x => e.target.checked ? [...x, m] : x.filter(y => y !== m))} />{t}</label>)}
        <label>每个模型 <select aria-label="张数" value={n} onChange={e => setN(Number(e.target.value))} className="rounded border bg-background">{[1, 2, 3, 4].map(k => <option key={k}>{k}</option>)}</select> 张</label>
        <span className="ml-auto text-muted-foreground">{usage ? `本方案已花 $${usage.spent.toFixed(2)} / 上限 $${usage.cap}` : "花费未读取"}</span>
      </div>
      <Textarea aria-label="效果图要求" rows={2} className="min-h-14 text-xs" placeholder="例：把场地照里的大堂入口布置成海军蓝、白、珊瑚色的有机气球拱门，两侧落地花艺；保持场地结构和机位不变"
        value={prompt} onChange={e => setPrompt(e.target.value)} />
      <div className="flex items-center gap-2">
        <span className="text-xs text-muted-foreground">参考图 {refs.length}/4</span>
        <div className="flex min-w-0 flex-1 gap-1 overflow-x-auto">{(bcState?.assets || []).map(a => <button key={a.id} title={a.label} aria-pressed={refs.includes(a.id)}
          onClick={() => setRefs(x => x.includes(a.id) ? x.filter(y => y !== a.id) : x.length < 4 ? [...x, a.id] : x)}
          className={cn("size-10 shrink-0 overflow-hidden rounded border-2", refs.includes(a.id) ? "border-clay" : "border-transparent opacity-70")}>
          {a.thumb ? <img src={a.thumb} alt="" className="size-full object-cover" /> : null}</button>)}</div>
        <Button size="sm" disabled={!models.length} onClick={() => void generate()}><Wand2 className="size-3.5" />{parent ? "基于选中图出一批" : "出一批"}</Button>
      </div>
      {parent ? <p className="text-xs">基于 <code>{parent}</code> 修改 <button className="underline" onClick={() => setParent("")}>取消</button></p> : null}
      {msg ? <p role="status" className="text-xs text-muted-foreground">{msg}</p> : null}
    </div>
    <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-3">
      {!renders.length ? <p className="text-sm text-muted-foreground">还没有效果图。选参考图（场地照放第一张）、写要求，点「出一批」；或在对话里让 Agent 出图。</p> : null}
      {slides.map(s => <section key={s}><h3 className="mb-2 text-xs font-semibold">第 {s} 页</h3>
        <div className="grid grid-cols-2 gap-2 2xl:grid-cols-3">{renders.filter(r => (r.slide || "?") === s).sort((a, b) => (b.score ?? -1) - (a.score ?? -1) || b.at - a.at).map(r =>
          <figure key={r.id} className={cn("overflow-hidden rounded-lg border bg-background", r.picked && "ring-2 ring-clay")}>
            <button className="block w-full" onClick={() => r.status === "ok" && void open(r)} aria-label="放大看">
              {r.status === "ok" && r.thumb ? <img src={r.thumb} alt={r.prompt} className="aspect-[3/2] w-full object-cover" />
                : <div className="flex aspect-[3/2] items-center justify-center text-xs text-muted-foreground">{r.status === "running" ? <><Loader2 className="mr-1 size-4 animate-spin" />生成中</> : `失败：${r.error || ""}`}</div>}
            </button>
            <figcaption className="space-y-1 p-2 text-[11px]">
              <div className="flex items-center gap-1"><span className="font-medium">{MODEL[r.model || ""] || r.model}</span>{r.op && r.op !== "generate" ? <span className="text-muted-foreground">· {r.op === "region" ? "局部改" : r.op}</span> : null}
                {r.parent ? <span className="text-muted-foreground" title={r.parent}>· 改自 {r.parent.slice(0, 4)}</span> : null}
                <span className="ml-auto">{r.score != null ? <b title={String(r.judge?.notes || "")}>{r.score} 分</b> : null}{r.cost ? ` · $${r.cost.toFixed(3)}` : ""}</span></div>
              {r.judge?.notes ? <p className="line-clamp-2 text-muted-foreground">{String(r.judge.notes)}</p> : null}
              {r.status === "ok" ? <div className="flex flex-wrap gap-1">
                <Button size="sm" variant={r.picked ? "secondary" : "outline"} className="h-6 px-2 text-[11px]" onClick={async () => { await bc("pick", { id: r.id }); await reload(); }}><Star className="size-3" />{r.picked ? "已挑" : "挑这张"}</Button>
                <Button size="sm" variant="ghost" className="h-6 px-2 text-[11px]" onClick={async () => { await bc("judge", { id: r.id }); setMsg("打分中，约半分钟"); setTimeout(() => void reload(), 30000); }}>打分</Button>
                <Button size="sm" variant="ghost" className="h-6 px-2 text-[11px]" onClick={() => { setParent(r.id); setSlide(r.slide || slide); setPrompt(r.prompt || ""); }}>基于它改</Button>
                <Button size="sm" variant="ghost" className="h-6 px-2 text-[11px]" onClick={() => void open(r, true)}><Crop className="size-3" />圈一块改</Button>
                <Button size="sm" variant="ghost" className="h-6 px-2 text-[11px]" onClick={() => void say(`第 ${r.slide} 页用效果图 ${r.id}（bc_config 里取它的 path），替换该页图片，存新 hold 版本并回传预览。`).then(() => setMsg(`已请 Agent 把它用到第 ${r.slide} 页`))}>用到这一页</Button>
              </div> : null}
            </figcaption>
          </figure>)}</div></section>)}
    </div>
    {view ? <ImageView view={view} onClose={() => setView(null)} onRegion={(marked, text) => { void generate({ parent: view.img.id, slide: view.img.slide, prompt: text, marked, op: "region" }); setView(null); }} /> : null}
    {overCap ? <div role="dialog" aria-modal className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-6"><div className="max-w-sm space-y-3 rounded-xl bg-background p-5 shadow-xl">
      <p className="font-medium">本方案已到花费上限</p><p className="text-sm text-muted-foreground">已花 ${usage?.spent.toFixed(2)}，上限 ${usage?.cap}。继续会产生新的费用。</p>
      <div className="flex justify-end gap-2"><Button variant="ghost" onClick={() => setOverCap(null)}>取消</Button><Button onClick={() => { const b = overCap; setOverCap(null); void generate(b, true); }}>确认继续</Button></div></div></div> : null}
  </div>;
}

// The full image; in crop mode a dragged rectangle is drawn onto it in red and the edit asks for that area only.
function ImageView({ view, onClose, onRegion }: { view: { img: BcImage; data: string; crop: boolean }; onClose: () => void; onRegion: (marked: string, text: string) => void }) {
  const img = useRef<HTMLImageElement>(null);
  const [box, setBox] = useState<{ x: number; y: number; w: number; h: number } | null>(null);
  const start = useRef<{ x: number; y: number } | null>(null);
  const [text, setText] = useState("");
  const pos = (e: React.PointerEvent) => { const r = img.current!.getBoundingClientRect(); return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height }; };
  const mark = async () => {
    const el = img.current!, c = document.createElement("canvas");
    const k = Math.min(1, 1600 / Math.max(el.naturalWidth, el.naturalHeight));
    c.width = Math.round(el.naturalWidth * k); c.height = Math.round(el.naturalHeight * k);
    const g = c.getContext("2d")!; g.drawImage(el, 0, 0, c.width, c.height);
    g.strokeStyle = "#ff0000"; g.lineWidth = Math.max(4, c.width / 200);
    g.strokeRect(box!.x * c.width, box!.y * c.height, box!.w * c.width, box!.h * c.height);
    const prompt = `Edit ONLY the area inside the red rectangle in the first image: ${text}. Keep everything outside the rectangle exactly as it is (venue, camera, lighting). Remove the red rectangle. No people, no text, no logos or brand marks.`;
    onRegion(c.toDataURL("image/jpeg", 0.85), prompt);
  };
  return <div role="dialog" aria-modal className="fixed inset-0 z-50 flex flex-col bg-black/80 p-4" onClick={onClose}>
    <div className="m-auto flex max-h-full max-w-6xl flex-col gap-2" onClick={e => e.stopPropagation()}>
      <div className="flex items-center gap-2 text-sm text-white"><span className="mr-auto">{MODEL[view.img.model || ""]} · 第 {view.img.slide} 页 · {view.img.id}{view.crop ? " · 在图上拖一个框" : ""}</span>
        <Button size="icon" variant="ghost" className="text-white" aria-label="关闭" onClick={onClose}><X className="size-4" /></Button></div>
      <div className="relative select-none">
        <img ref={img} src={view.data} alt={view.img.prompt} className="max-h-[75vh] w-auto touch-none" draggable={false}
          onPointerDown={e => { if (!view.crop) return; start.current = pos(e); setBox(null); }}
          onPointerMove={e => { if (!start.current) return; const p = pos(e), s = start.current; setBox({ x: Math.min(s.x, p.x), y: Math.min(s.y, p.y), w: Math.abs(p.x - s.x), h: Math.abs(p.y - s.y) }); }}
          onPointerUp={() => { start.current = null; }} />
        {box ? <div className="pointer-events-none absolute border-2 border-red-500" style={{ left: `${box.x * 100}%`, top: `${box.y * 100}%`, width: `${box.w * 100}%`, height: `${box.h * 100}%` }} /> : null}
      </div>
      {view.crop ? <div className="flex gap-2"><input className="flex-1 rounded-md px-2 py-1 text-sm" placeholder="这一块改成什么，例：换成金白色气球柱，或换成品牌色" value={text} onChange={e => setText(e.target.value)} />
        {["recolor to the brand palette", "warm evening lighting", "remove this object"].map(q => <Button key={q} size="sm" variant="secondary" onClick={() => setText(q)}>{q === "recolor to the brand palette" ? "换品牌色" : q === "warm evening lighting" ? "改黄昏光" : "去掉"}</Button>)}
        <Button disabled={!box || box.w < 0.02 || !text.trim()} onClick={() => void mark()}>只改这一块</Button></div> : null}
    </div>
  </div>;
}

export function BcScripts({ scripts, say }: { scripts: Script[]; say: (text: string) => Promise<void> }) {
  const [ask, setAsk] = useState<Record<string, string>>({});
  const [msg, setMsg] = useState("");
  if (!scripts.length) return <p className="text-xs leading-5 text-muted-foreground">Agent 每出一个版本都会回传每页讲稿，显示在这里；只有发布者看得到，现场用手机扫码跟着翻页。</p>;
  return <div className="space-y-3">
    {msg ? <p role="status" className="text-xs text-muted-foreground">{msg}</p> : null}
    {scripts.map(s => <div key={s.slide} className="space-y-1 rounded-lg border p-2">
      <p className="text-xs font-semibold">{s.slide}. {s.title}</p>
      <p className="whitespace-pre-wrap text-xs leading-5 text-muted-foreground">{s.text}</p>
      <div className="flex gap-1"><input className={field} placeholder="怎么改：更短 / 更正式 / 加一个案例" value={ask[s.slide] || ""} onChange={e => setAsk(a => ({ ...a, [s.slide]: e.target.value }))} />
        <Button size="sm" variant="outline" className="h-7" disabled={!ask[s.slide]?.trim()} onClick={() => void say(`讲稿：第 ${s.slide} 页（${s.title}）${ask[s.slide]}。只改这一页的讲稿，存新 hold 版本并回传 scripts。`).then(() => { setAsk(a => ({ ...a, [s.slide]: "" })); setMsg("已发给 Agent"); })}>改</Button></div>
    </div>)}
  </div>;
}
