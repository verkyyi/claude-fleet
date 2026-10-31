import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { ArrowLeft, ArrowUp, BarChart3, ExternalLink, FileText, Globe, LayoutTemplate, Monitor, Plus, RefreshCw, Smartphone } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { PageQR } from "../chat/page-qr";
import { PageFrame } from "../chat/page-frame";
import { ChatThread, useVisualViewport } from "./chat";
import { usePage, useShell } from "../Shell";
import { useWorkRows } from "../work-rows";
import { rowForOpen } from "../new-session";
import { useStudioPreview } from "./studio-preview";
import { BcConfigPanel, BcImageBench, BcScripts, useBc, type BcClient, type BcTemplate, type Script } from "./bubble-cloud";
import { cn } from "@/lib/utils";

type Project = { proposal_id: string; title: string; url?: string; visibility?: string };
type Version = Project & { version_id: string; version?: string; status: string; embed?: string; embed_exp?: string; note?: string; at: number; renewable?: boolean; preview_error?: string; scripts?: Script[] };
type Operation = { id: string; action: Action; state: string; message?: string; at: number };
type Session = Partial<Project> & { key: string; fid: string; agent: string; versions: Version[]; qr_url?: string; analytics?: Summary; leads?: Summary; operations?: Operation[]; profile?: string; client?: string; template?: string };
type Summary = { summary: string; at: number };
type State = { projects: Project[]; sessions: Record<string, Session>; updated_at?: number };
type Action = "publish" | "visibility" | "wechat" | "links" | "analytics" | "leads" | "preview";
type Command = { id: string; fid: string; proposal_id?: string; action: Action; version_id?: string; visibility?: string; confirmed: boolean };
const LABEL: Record<Action, string> = { publish: "发布", visibility: "更改可见范围", wechat: "推到我的微信", links: "读取链接与二维码", analytics: "读取本周阅读", leads: "读取本周留资", preview: "刷新预览" };
const STATUS: Record<string, string> = { hold: "待发布", ready: "已发布", review: "审核中", failed: "未完成" };
const QUICK = [
  { icon: Globe, title: "企业品牌样板", text: "给目标企业做一份带对方品牌的私密样板。先问我企业名称、素材与增长目标，读取 list_examples 和品牌规范，生成 hold 版本并给预览。" },
  { icon: FileText, title: "更新官网首页", text: "更新官网首页。先读 core/space/examples/official-home/README.md，确认绑定页面和三语内容，按 pull → 改 → push --hold → 预览流程，等待右栏确认发布。先问我本次要改什么。" },
  { icon: LayoutTemplate, title: "上新 / 更新模板", text: "上新或更新一个模板。先读取 list_examples 与品牌规范，问清对象、用途和本次变更；所有改动存 hold 版本并给预览，不能直接上线。" },
  { icon: BarChart3, title: "本周阅读与留资", text: "读取本工作区本周阅读与表单留资。明确日期范围、时区和来源，未读取的数据注明未知；不修改页面，不编造指标。" },
];
async function request<T>(path: string, body?: unknown): Promise<T> {
  const r = await fetch(`/v1/chat/studio${path}`, { method: body ? "POST" : "GET", cache: "no-store",
    headers: body ? { "Content-Type": "application/json", "X-Fleet-Webchat": "1" } : {}, ...(body ? { body: JSON.stringify(body) } : {}) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.state === "refused") throw new Error(j.error || j.reason || (r.status === 404 ? "工作台未开放" : "暂时连不上家机器，请重试"));
  return j as T;
}

export default function StudioPage() {
  usePage("一站式企业增长运营 Agent");
  useVisualViewport();
  const { me } = useShell();
  return me?.studio ? <Studio /> : <div className="p-8" role="status">{me ? "404 · 页面不存在" : "正在读取…"}</div>;
}

function CanvasPreview({ version, device }: { version: Version; device: string }) {
  const host = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(version.embed!);
  const sources = shown === version.embed ? [shown] : [shown, version.embed!];
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const observer = new ResizeObserver(([entry]) => setSize({ width: entry.contentRect.width, height: entry.contentRect.height }));
    if (host.current) observer.observe(host.current);
    return () => observer.disconnect();
  }, []);
  const width = device === "phone" ? 390 : 1280;
  const scale = Math.min(1, size.width / width);
  return <div ref={host} className="flex h-full min-h-80 w-full justify-center overflow-hidden">
    {scale > 0 ? <div className="relative h-full overflow-hidden rounded-lg border bg-white shadow-sm" style={{ width: width * scale }}>
      <div className="absolute left-0 top-0 origin-top-left" style={{ width, height: size.height / scale, transform: `scale(${scale})` }}>
        {sources.map(src => <div key={src} className={cn("absolute inset-0", src !== shown && "pointer-events-none opacity-0")} aria-hidden={src !== shown}>
          <PageFrame src={src} title={version.title || "活页预览"} className="h-full w-full border-0" onLoad={() => { if (src === version.embed) setShown(src); }} />
        </div>)}
      </div>
    </div> : null}
  </div>;
}

function Studio() {
  const { rows, reload } = useWorkRows();
  const { me } = useShell();
  const storageKey = `studio-project:${me?.person || ""}${new URLSearchParams(location.search).get("profile") === "bc" ? ":bc" : ""}`;
  const [search, setSearch] = useSearchParams();
  // The Bubble Cloud proposal workbench (task APVZ) is this page with ?profile=bc: its own sessions and panels.
  const bubble = search.get("profile") === "bc";
  const nav = (p: Record<string, string>) => setSearch(bubble ? { ...p, profile: "bc" } : p);
  const key = search.get("project") || "";
  const [state, setState] = useState<State>({ projects: [], sessions: {} });
  const [error, setError] = useState("");
  const [syncError, setSyncError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [agent, setAgent] = useState("claude");
  const [draft, setDraft] = useState("");
  const [tab, setTab] = useState("chat");
  const [device, setDevice] = useState("desktop");
  const versionID = search.get("version") || "";
  const [loaded, setLoaded] = useState(false);
  const [visibility, setVisibility] = useState("private");
  const [confirmation, setConfirmation] = useState<Command | null>(null);
  const [retry, setRetry] = useState<Command | null>(null);
  const openKey = useRef("");
  const session = Object.hasOwn(state.sessions, key) ? state.sessions[key] : undefined;
  const row = session ? rowForOpen(rows, session.fid, "") : null;
  const worker = row?.board?.worker_id || row?.live?.id || "";
  // FIDs persist in the studio book; the shared owner-scoped list resolves
  // their current live worker address, including after a page reload.
  useEffect(() => {
    if (!session || worker) return;
    reload();
    const timer = setInterval(reload, 3000);
    return () => clearInterval(timer);
  }, [session?.fid, worker, reload]);
  const versions = session?.versions || [];
  const latest = versions.at(-1);
  const version = versions.find(v => v.version_id === versionID) || latest;
  const lastLatest = useRef({ key: "", version: "" });
  useEffect(() => {
    if (!latest) return;
    if (lastLatest.current.key === key && lastLatest.current.version && lastLatest.current.version !== latest.version_id) nav({ project: key });
    lastLatest.current = { key, version: latest.version_id };
  }, [key, latest?.version_id]);
  useEffect(() => {
    try {
      if (!search.has("project")) {
        const previous = localStorage.getItem(storageKey);
        if (previous) setSearch(new URLSearchParams(previous), { replace: true });
      } else localStorage.setItem(storageKey, search.toString());
    } catch { /* Storage disabled: the URL remains the source of truth. */ }
  }, [storageKey, search]);
  useEffect(() => { setVisibility(session?.visibility || "private"); setRetry(null); }, [key, session?.visibility]);
  const refresh = useCallback(async () => {
    try { setState(await request<State>("")); setSyncError(""); } catch (e) { setSyncError((e as Error).message); }
  }, []);
  useEffect(() => {
    let live = true;
    const read = async () => { try { const j = await request<State>(""); if (live) { setState(j); setSyncError(""); setLoaded(true); } } catch (e) { if (live) setSyncError((e as Error).message); } };
    void read();
    const wake = () => { if (document.visibilityState === "visible") void read(); };
    const t = setInterval(wake, 5000);
    window.addEventListener("online", wake); window.addEventListener("focus", wake);
    return () => { live = false; clearInterval(t); window.removeEventListener("online", wake); window.removeEventListener("focus", wake); };
  }, []);
  const preview = useStudioPreview(session, version, request, refresh);
  const open = async (proposal?: Project, text?: string, catalog = false, bcPick?: { client?: BcClient; template?: BcTemplate }) => {
    if (busy) return;
    setBusy(true); setError(""); setNotice("");
    // A failed open keeps its identity for retry; a response lost after spawn
    // must not create a second session.
    const next = catalog ? "catalog" : proposal?.proposal_id || (openKey.current ||= `new-${crypto.randomUUID()}`);
    try {
      const s = await request<Session>("/open", { key: next, proposal_id: proposal?.proposal_id || "", text: text || draft || (bubble ? "先读 bc_config，按客户卡和模板起一份完整方案 Deck（13 页）和中文内部说明；缺的信息先问我。" : ""), agent, embed_origin: location.origin,
        ...(bubble ? { profile: "bubble-cloud", client: bcPick?.client?.id || "", template: bcPick?.template?.id || "" } : {}) });
      setState(old => ({ ...old, sessions: { ...old.sessions, [s.key]: s } }));
      nav({ project: s.key }); setTab("chat"); setDraft(""); openKey.current = "";
      if (catalog && (s as Session & { reused?: boolean }).reused) {
        const target = rowForOpen(rows, s.fid, "");
        const address = target?.board?.worker_id || target?.live?.id;
        if (!address) throw new Error("会话尚未就绪，请稍后重试刷新项目");
        const r = await fetch(`/v1/chat/say?worker=${encodeURIComponent(address)}`, { method: "POST", headers: { "Content-Type": "application/json", "X-Fleet-Webchat": "1" },
          body: JSON.stringify({ id: crypto.randomUUID(), text: "请重新读取 list_proposals 全部分页，用 fleet.studio_projects 更新完整项目列表。只读。" }) });
        const j = await r.json().catch(() => ({}));
        if (!r.ok || j.state === "refused") throw new Error(j.error || j.reason || "刷新请求未送达");
      }
    } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  };
  // A line into this project's session, as if typed in the chat (the workbench's 改这一页 / 用这张图 / 改讲稿).
  const say = async (text: string) => {
    if (!worker) throw new Error("会话尚未就绪");
    const r = await fetch(`/v1/chat/say?worker=${encodeURIComponent(worker)}`, { method: "POST", headers: { "Content-Type": "application/json", "X-Fleet-Webchat": "1" },
      body: JSON.stringify({ id: crypto.randomUUID(), text }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || j.state === "refused") throw new Error(j.error || j.reason || "没送达");
  };
  const send = async (command: Command) => {
    setBusy(true); setError(""); setNotice("");
    try {
      const r = await request<{ state: string }>("/action", command);
      setRetry(null); setNotice(r.state === "unknown" ? "结果待核实，请在会话中读取实际状态，勿重复操作" : r.state === "queued" ? "指令已排队，等 Agent 当前一轮结束后执行" : "指令已送达，执行结果会更新到这里");
      void refresh();
    } catch (e) { setError((e as Error).message); setRetry(command); } finally { setBusy(false); }
  };
  const action = (a: Action) => {
    if (!session || busy) return;
    const confirm = ["publish", "visibility", "wechat"].includes(a);
    const command: Command = { id: crypto.randomUUID(), fid: session.fid, proposal_id: session.proposal_id, action: a, version_id: version?.version_id, visibility, confirmed: confirm };
    if (confirm) setConfirmation(command); else void send(command);
  };
  const expired = preview.expired;
  if (bubble) return <BubbleCloudStudio {...{ state, session, key, version, versions, worker, row, busy, error, syncError, notice, retry, agent, setAgent, draft, setDraft,
    device, setDevice, visibility, setVisibility, canAct: !!session?.proposal_id && !busy, expired, preview, open, send, action, say, nav, confirmation, setConfirmation, loaded }} />;
  const canAct = !!session?.proposal_id && !busy;
  const panel = (name: string) => cn("min-h-0 min-w-0 flex-col", tab === name ? "flex" : "hidden", "lg:flex");
  if (!loaded) return <div role="status" className="p-6 text-sm">{syncError ? "暂时连不上家机器，正在重新连接；项目和版本会保留。" : "正在恢复工作台…"}</div>;
  return <div className="flex h-full min-h-0 flex-col bg-background" data-testid="livepage-studio">
    <header className="flex min-h-16 flex-wrap items-center gap-3 border-b px-4 py-2">
      <Link to="/" aria-label="返回会话" className="rounded-lg p-2 text-muted-foreground hover:bg-muted"><ArrowLeft className="size-4" /></Link>
      <div className="mr-auto"><h1 className="text-base font-semibold tracking-tight">一站式企业增长运营 Agent</h1><p className="text-xs text-muted-foreground">从一个想法，到可以分享的页面</p></div>
      <label className="min-w-0 flex-1 sm:max-w-72"><span className="sr-only">项目</span>
        <select aria-label="项目" className="h-9 w-full rounded-lg border bg-background px-2 text-sm" value={session?.proposal_id || (key === "catalog" ? "catalog" : "")} onChange={e => {
          const p = state.projects.find(x => x.proposal_id === e.target.value); if (p) void open(p);
        }}><option value="">选择活页项目</option>{key === "catalog" ? <option value="catalog">工作区项目列表</option> : null}{state.projects.map(p => <option key={p.proposal_id} value={p.proposal_id}>{p.title || p.proposal_id}</option>)}</select>
      </label>
      <Button variant="ghost" size="sm" disabled={busy} onClick={() => void open(undefined, undefined, true)} title="让 Agent 读取工作区项目"><RefreshCw className="size-4" /><span className="hidden sm:inline">刷新项目</span></Button>
      <Button variant="outline" size="sm" onClick={() => { setSearch({ project: "" }); setDraft(""); setNotice(""); openKey.current = ""; }}><Plus className="size-4" />新页面</Button>
      <Link to="/studio?profile=bc" className="text-xs text-muted-foreground underline">Bubble Cloud 方案工作台</Link>
    </header>
    <nav aria-label="工作台面板" className="grid grid-cols-3 border-b p-1 lg:hidden">{[["chat", "对话"], ["canvas", "画布"], ["publish", "发布与数据"]].map(([id, title]) => <Button key={id} variant={tab === id ? "secondary" : "ghost"} aria-pressed={tab === id} onClick={() => setTab(id)}>{title}</Button>)}</nav>
    {error || syncError ? <div role="alert" className="border-b bg-destructive/5 px-4 py-2 text-sm text-destructive">{error || syncError}{retry ? <button className="ml-3 underline" disabled={busy} onClick={() => void send(retry)}>重试同一操作</button> : null}</div> : null}
    {notice ? <p role="status" className="border-b px-4 py-2 text-xs text-muted-foreground">{notice}</p> : null}
    <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(300px,0.9fr)_minmax(400px,1.65fr)_280px]">
      <section aria-label="与 Agent 对话" className={cn(panel("chat"), "lg:border-r")}>
        <div className="flex h-12 shrink-0 items-center justify-between border-b px-4 text-sm"><span className="font-medium">与 Agent 一起创作</span>
          {session ? <span className="text-xs text-muted-foreground">{session.agent === "codex" ? "Codex" : "Claude Code"} · <Link className="underline" to={`/s/${encodeURIComponent(worker || "fid:" + session.fid)}`}>会话详情 / 接回</Link></span> : <select aria-label="Agent" value={agent} onChange={e => setAgent(e.target.value)} className="rounded border bg-background p-1 text-xs"><option value="claude">Claude Code</option><option value="codex">Codex</option></select>}
        </div>
        <div className="min-h-0 flex-1">{session ? (worker ? <ChatThread source={{ kind: "session", worker, machine: row?.live?.machine || row?.board?.machine || "", key: session.key, agent: session.agent }} /> : <div className="p-5 text-sm text-muted-foreground" role="status"><p>正在连接会话…</p><Link className="mt-3 inline-block underline" to={`/s/${encodeURIComponent("fid:" + session.fid)}`}>查看会话状态 / 接回</Link><p className="mt-2">已授权的画布仍可使用。</p></div>) : <div className="flex h-full flex-col gap-5 overflow-auto p-5">
          <div className="pt-6"><p className="text-xl font-semibold">今天想做什么？</p><p className="mt-2 text-sm leading-6 text-muted-foreground">说一句需求，Agent 帮你把内容做成活页。每次改动先预览，由你决定何时发布。</p></div>
          <div className="grid grid-cols-1 gap-2">{QUICK.map(q => <button key={q.title} disabled={busy} onClick={() => void open(undefined, q.text)} className="flex items-center gap-3 rounded-xl border p-3 text-left text-sm hover:bg-muted"><q.icon className="size-4 text-muted-foreground" />{q.title}</button>)}</div>
          <div className="mt-auto rounded-xl border p-2"><Textarea aria-label="需求" placeholder="例如：给一家咖啡店做一份秋季活动样板…" value={draft} onChange={e => setDraft(e.target.value)} className="min-h-28 resize-none border-0 shadow-none" /><div className="flex justify-end"><Button aria-label="开始创作" disabled={busy || !draft.trim()} onClick={() => void open()}><ArrowUp className="size-4" />{busy ? "正在开始…" : "开始创作"}</Button></div></div>
        </div>}</div>
      </section>
      <section aria-label="画布" className={cn(panel("canvas"), "bg-muted/30 lg:border-r")}>
        <div className="flex min-h-12 shrink-0 flex-wrap items-center gap-2 border-b bg-background px-3 py-2">
          <span className="mr-auto text-sm font-medium">画布</span>
          <select aria-label="版本" className="max-w-40 rounded border bg-background p-1 text-xs" value={version?.version_id || ""} onChange={e => setSearch({ project: key, version: e.target.value })}><option value="" disabled>等待首个版本</option>{versions.map(v => <option key={v.version_id} value={v.version_id}>{v.version ? `第 ${v.version} 版` : v.version_id.slice(-6)} · {STATUS[v.status] || v.status}</option>)}</select>
          <Button size="icon" variant={device === "desktop" ? "secondary" : "ghost"} aria-label="电脑预览" aria-pressed={device === "desktop"} onClick={() => setDevice("desktop")}><Monitor className="size-4" /></Button>
          <Button size="icon" variant={device === "phone" ? "secondary" : "ghost"} aria-label="手机预览" aria-pressed={device === "phone"} onClick={() => setDevice("phone")}><Smartphone className="size-4" /></Button>
        </div>
        <div className="flex min-h-0 flex-1 justify-center overflow-auto p-3 sm:p-5">
          {version?.embed ? <CanvasPreview key={version.version_id} version={version} device={device} /> : <div className="flex max-w-sm flex-col items-center justify-center gap-3 text-center text-muted-foreground"><LayoutTemplate className="size-10 opacity-30" /><p className="font-medium text-foreground">{version?.embed ? "预览已过期" : "你的下一张活页，从这里开始"}</p><p className="text-sm leading-6">{version?.embed ? "刷新预览后继续查看，已保存的版本不受影响。" : "Agent 存好待发版本后，预览会自动出现在画布中。"}</p>{canAct ? <Button variant="outline" onClick={() => void preview.renew(true)}>获取预览</Button> : null}</div>}
        </div>
        {preview.message ? <p role="status" className="shrink-0 border-t px-4 py-2 text-xs">{preview.message}</p> : null}
        {version ? <p className="shrink-0 border-t px-4 py-2 text-xs text-muted-foreground">{STATUS[version.status]}{version.note ? ` · ${version.note}` : ""}{version.status === "hold" ? " · 尚未上线" : ""}</p> : null}
      </section>
      <aside aria-label="发布与数据" className={cn(panel("publish"), "overflow-y-auto")}>
        <div className="flex h-12 shrink-0 items-center border-b px-4 text-sm font-medium">发布与数据</div>
        <div className="space-y-6 p-4">
          {session?.operations?.length ? <div aria-label="操作记录" className="space-y-2 border-b pb-3"><h2 className="text-sm font-semibold">操作记录</h2>{session.operations.slice(-4).reverse().map(op => <p key={op.id} className="text-xs leading-5">{LABEL[op.action]} · {({pending:"准备发送",queued:"已排队",sent:"已送达",executing:"执行中",succeeded:"已完成",failed:"未完成",unknown:"结果待核实"} as Record<string,string>)[op.state] || "结果待核实"}{op.message ? `：${op.message}` : ""}</p>)}</div> : null}
          <div className="space-y-3"><h2 className="text-sm font-semibold">{session?.title || "发布设置"}</h2><p className="text-xs leading-5 text-muted-foreground">{version ? `${STATUS[version.status]} · ${version.version ? `第 ${version.version} 版` : "当前版本"}` : "先创作，再预览，最后发布。"}</p>
            <label className="block text-xs">可见范围<select aria-label="可见范围" value={visibility} onChange={e => setVisibility(e.target.value)} disabled={!canAct} className="mt-2 h-9 w-full rounded-lg border bg-background px-2 text-sm"><option value="private">仅自己</option><option value="passcode">密码访问</option><option value="public">公开</option></select></label>
            <Button variant="outline" className="w-full" disabled={!canAct || visibility === session?.visibility} onClick={() => action("visibility")}>确认更改范围</Button>
            <Button className="w-full" disabled={!canAct || version?.status !== "hold" || !version.embed || expired} onClick={() => action("publish")}>发布当前预览版本</Button>
            <Button variant="outline" className="w-full" disabled={!canAct} onClick={() => action("wechat")}>推到我的微信</Button>
          </div>
          <div className="space-y-3 border-t pt-4"><h2 className="text-sm font-semibold">链接与二维码</h2>{session?.url ? <a href={session.url} target="_blank" rel="noopener noreferrer" className="flex items-center gap-1 break-all text-xs text-clay">打开正式链接<ExternalLink className="size-3" /></a> : <p className="text-xs text-muted-foreground">尚未读取链接</p>}{session?.url ? <PageQR url={session.url} /> : null}<Button size="sm" variant="outline" disabled={!canAct} onClick={() => action("links")}>读取链接与二维码</Button></div>
          {([['analytics', '本周阅读'], ['leads', '表单留资']] as const).map(([id, title]) => <div key={id} className="space-y-3 border-t pt-4"><div className="flex items-center justify-between"><h2 className="text-sm font-semibold">{title}</h2><Button size="icon" variant="ghost" aria-label={`刷新${title}`} disabled={!canAct} onClick={() => action(id)}><RefreshCw className="size-3.5" /></Button></div><p className="whitespace-pre-wrap break-words text-xs leading-6 text-muted-foreground">{session?.[id]?.summary || "尚未读取，不代表为零"}</p>{session?.[id] ? <p className="text-[10px] text-muted-foreground">读取于 {new Date(session[id]!.at * 1000).toLocaleString()}</p> : null}</div>)}
        </div>
      </aside>
    </div>
    <AlertDialog open={!!confirmation} onOpenChange={open => { if (!open) setConfirmation(null); }}><AlertDialogContent><AlertDialogHeader><AlertDialogTitle>{confirmation ? `确认${LABEL[confirmation.action]}` : "确认操作"}</AlertDialogTitle><AlertDialogDescription>{confirmation?.action === "publish" ? `将当前预览版本（${confirmation.version_id}）上线。其它待发版本不会发布。` : confirmation?.action === "visibility" ? `将这张活页改为「${visibility === "public" ? "公开，任何人可访问" : visibility === "passcode" ? "密码访问" : "仅自己"}」。` : "将这张活页的已发布内容推送到你自己的微信。"}</AlertDialogDescription></AlertDialogHeader><AlertDialogFooter><AlertDialogCancel>取消</AlertDialogCancel><AlertDialogAction onClick={() => { if (confirmation) void send(confirmation); setConfirmation(null); }}>确认执行</AlertDialogAction></AlertDialogFooter></AlertDialogContent></AlertDialog>
  </div>;
}

type BcProps = {
  state: State; session?: Session; key: string; version?: Version; versions: Version[]; worker: string; row: ReturnType<typeof rowForOpen>;
  busy: boolean; error: string; syncError: string; notice: string; retry: Command | null; agent: string; setAgent: (a: string) => void;
  draft: string; setDraft: (d: string) => void; device: string; setDevice: (d: string) => void; visibility: string; setVisibility: (v: string) => void;
  canAct: boolean; expired: boolean; preview: ReturnType<typeof useStudioPreview>; loaded: boolean;
  open: (proposal?: Project, text?: string, catalog?: boolean, bcPick?: { client?: BcClient; template?: BcTemplate }) => Promise<void>;
  send: (c: Command) => Promise<void>; action: (a: Action) => void; say: (text: string) => Promise<void>; nav: (p: Record<string, string>) => void;
  confirmation: Command | null; setConfirmation: (c: Command | null) => void;
};

// The Bubble Cloud proposal workbench (task APVZ): config · chat · deck canvas / rendering bench · scripts and publishing.
// Desktop only (≥ 1280 px); the delivered deck keeps LivePage's phone layout for the client.
function BubbleCloudStudio(p: BcProps) {
  const { state, session, key, version, versions, worker, row, busy, error, syncError, notice, retry } = p;
  const sessions = Object.values(state.sessions).filter(s => s.profile === "bubble-cloud").sort((a, b) => (b.versions.at(-1)?.at || 0) - (a.versions.at(-1)?.at || 0));
  const proposal = session?.proposal_id || session?.key || "";
  const { state: bcState, error: bcError, read } = useBc(proposal);
  const [canvas, setCanvas] = useState("deck");
  const [slideAsk, setSlideAsk] = useState({ slide: "1", text: "" });
  const [sent, setSent] = useState("");
  const clientName = (id?: string) => bcState?.config.clients.find(c => c.id === id)?.name || "";
  if (!p.loaded) return <div role="status" className="p-6 text-sm">{syncError ? "暂时连不上家机器，正在重新连接；项目和版本会保留。" : "正在恢复工作台…"}</div>;
  return <div className="flex h-full min-h-0 flex-col bg-background" data-testid="bubble-cloud-studio">
    <header className="flex min-h-14 flex-wrap items-center gap-3 border-b px-4 py-2">
      <Link to="/" aria-label="返回会话" className="rounded-lg p-2 text-muted-foreground hover:bg-muted"><ArrowLeft className="size-4" /></Link>
      <div className="mr-auto"><h1 className="text-base font-semibold tracking-tight">Bubble Cloud 方案工作台</h1><p className="text-xs text-muted-foreground">客户方案 Deck · 效果图 · 讲稿，托管在活页</p></div>
      <label className="min-w-0 flex-1 sm:max-w-80"><span className="sr-only">方案</span>
        <select aria-label="方案" className="h-9 w-full rounded-lg border bg-background px-2 text-sm" value={session?.key || ""} onChange={e => p.nav({ project: e.target.value })}>
          <option value="">选择一份方案</option>{sessions.map(s => <option key={s.key} value={s.key}>{s.title || clientName(s.client) || s.key}</option>)}</select></label>
      <Button variant="outline" size="sm" onClick={() => p.nav({ project: "" })}><Plus className="size-4" />新方案</Button>
      <Link to="/studio" className="text-xs text-muted-foreground underline">增长运营 Agent</Link>
    </header>
    {error || syncError || bcError ? <div role="alert" className="border-b bg-destructive/5 px-4 py-2 text-sm text-destructive">{error || syncError || bcError}{retry ? <button className="ml-3 underline" disabled={busy} onClick={() => void p.send(retry)}>重试同一操作</button> : null}</div> : null}
    {notice || sent ? <p role="status" className="border-b px-4 py-2 text-xs text-muted-foreground">{notice || sent}</p> : null}
    <div className="p-6 text-sm xl:hidden" role="status">方案工作台只做了电脑版，请在宽度 1280 以上的电脑浏览器里打开。发给客户的 Deck 在手机上照常能看。</div>
    <div className="hidden min-h-0 flex-1 xl:grid xl:grid-cols-[300px_minmax(320px,0.85fr)_minmax(460px,1.7fr)_300px]">
      <section aria-label="配置" className="flex min-h-0 flex-col border-r">
        <div className="flex h-11 shrink-0 items-center border-b px-3 text-sm font-medium">配置</div>
        <BcConfigPanel bcState={bcState} reload={read} busy={busy} onNew={(client, template) => void p.open(undefined, undefined, false, { client, template })} />
      </section>
      <section aria-label="与 Agent 对话" className="flex min-h-0 flex-col border-r">
        <div className="flex h-11 shrink-0 items-center justify-between border-b px-3 text-sm"><span className="font-medium">对话</span>
          {session ? <span className="text-xs text-muted-foreground">{clientName(session.client) ? `${clientName(session.client)} · ` : ""}{session.agent === "codex" ? "Codex" : "Claude Code"} · <Link className="underline" to={`/s/${encodeURIComponent(worker || "fid:" + session.fid)}`}>会话详情</Link></span>
            : <select aria-label="Agent" value={p.agent} onChange={e => p.setAgent(e.target.value)} className="rounded border bg-background p-1 text-xs"><option value="claude">Claude Code</option><option value="codex">Codex</option></select>}
        </div>
        <div className="min-h-0 flex-1">{session ? (worker ? <ChatThread source={{ kind: "session", worker, machine: row?.live?.machine || row?.board?.machine || "", key: session.key, agent: session.agent }} />
          : <div className="p-5 text-sm text-muted-foreground" role="status">正在连接会话…</div>) : <div className="flex h-full flex-col gap-4 overflow-auto p-5">
          <div className="pt-4"><p className="text-lg font-semibold">新建一份方案</p><p className="mt-2 text-sm leading-6 text-muted-foreground">左边「客户」里选一张客户卡点「用这个客户新建方案」，或直接写需求。Agent 读公司资料、客户卡和模板，出 13 页英文 Deck、每页讲稿和中文内部说明；每次改动先存待发版本。</p></div>
          <div className="mt-auto rounded-xl border p-2"><Textarea aria-label="需求" placeholder="例：给 Google 湾区办公室做年终派对方案，12/14，约 300 人，主题 Winter Wonderland…" value={p.draft} onChange={e => p.setDraft(e.target.value)} className="min-h-28 resize-none border-0 shadow-none" />
            <div className="flex justify-end"><Button disabled={busy || !p.draft.trim()} onClick={() => void p.open()}><ArrowUp className="size-4" />{busy ? "正在开始…" : "开始"}</Button></div></div>
        </div>}</div>
      </section>
      <section aria-label="画布" className="flex min-h-0 flex-col border-r bg-muted/30">
        <div className="flex min-h-11 shrink-0 flex-wrap items-center gap-2 border-b bg-background px-3 py-1.5">
          {[["deck", "Deck"], ["images", "效果图"]].map(([id, t]) => <Button key={id} size="sm" variant={canvas === id ? "secondary" : "ghost"} aria-pressed={canvas === id} onClick={() => setCanvas(id)}>{t}</Button>)}
          <span className="mr-auto" />
          {canvas === "deck" ? <>
            <select aria-label="版本" className="max-w-40 rounded border bg-background p-1 text-xs" value={version?.version_id || ""} onChange={e => p.nav({ project: key, version: e.target.value })}><option value="" disabled>等待首个版本</option>{versions.map(v => <option key={v.version_id} value={v.version_id}>{v.version ? `第 ${v.version} 版` : v.version_id.slice(-6)} · {STATUS[v.status] || v.status}</option>)}</select>
            <Button size="icon" variant={p.device === "desktop" ? "secondary" : "ghost"} aria-label="电脑效果" onClick={() => p.setDevice("desktop")}><Monitor className="size-4" /></Button>
            <Button size="icon" variant={p.device === "phone" ? "secondary" : "ghost"} aria-label="客户手机效果" onClick={() => p.setDevice("phone")}><Smartphone className="size-4" /></Button></> : null}
        </div>
        {canvas === "deck" ? <>
          <div className="flex min-h-0 flex-1 justify-center overflow-auto p-4">
            {version?.embed ? <CanvasPreview key={version.version_id} version={version} device={p.device} /> : <div className="flex max-w-sm flex-col items-center justify-center gap-3 text-center text-muted-foreground"><LayoutTemplate className="size-10 opacity-30" /><p className="font-medium text-foreground">Deck 会出现在这里</p><p className="text-sm leading-6">Agent 存好待发版本后自动显示；切到「效果图」可以单独调图。</p></div>}
          </div>
          {p.preview.message ? <p role="status" className="shrink-0 border-t px-4 py-2 text-xs">{p.preview.message}</p> : null}
          {session ? <div className="flex shrink-0 items-center gap-2 border-t bg-background px-3 py-2">
            <label className="text-xs">改第 <input aria-label="页码" className="w-10 rounded border bg-background px-1" value={slideAsk.slide} onChange={e => setSlideAsk(x => ({ ...x, slide: e.target.value }))} /> 页</label>
            {(version?.scripts || []).length ? <div className="flex gap-1">{version!.scripts!.slice(0, 16).map(s => <button key={s.slide} title={s.title} onClick={() => setSlideAsk(x => ({ ...x, slide: s.slide }))} className={cn("rounded border px-1.5 text-[11px]", slideAsk.slide === s.slide && "border-clay text-clay")}>{s.slide}</button>)}</div> : null}
            <input className="min-w-0 flex-1 rounded-md border bg-background px-2 py-1 text-sm" placeholder="这一页改什么，例：标题更短、换成三栏、拱门换品牌色" value={slideAsk.text} onChange={e => setSlideAsk(x => ({ ...x, text: e.target.value }))} />
            <Button size="sm" disabled={!worker || !slideAsk.text.trim()} onClick={() => void p.say(`改第 ${slideAsk.slide} 页：${slideAsk.text}。只改这一页，存新 hold 版本并回传预览和 scripts。`).then(() => { setSlideAsk(x => ({ ...x, text: "" })); setSent(`已发给 Agent：改第 ${slideAsk.slide} 页`); }, e => setSent((e as Error).message))}>发给 Agent</Button>
          </div> : null}
        </> : session ? <BcImageBench proposal={proposal} bcState={bcState} reload={read} say={p.say} /> : <p className="p-6 text-sm text-muted-foreground">先新建或选择一份方案，效果图按方案归档。</p>}
      </section>
      <aside aria-label="讲稿与发布" className="flex min-h-0 flex-col overflow-y-auto">
        <div className="flex h-11 shrink-0 items-center border-b px-3 text-sm font-medium">讲稿与发布</div>
        <div className="space-y-5 p-3">
          <div className="space-y-2"><h2 className="text-sm font-semibold">讲稿</h2><BcScripts scripts={version?.scripts || []} say={p.say} /></div>
          {session?.operations?.length ? <div aria-label="操作记录" className="space-y-1 border-t pt-3"><h2 className="text-sm font-semibold">操作记录</h2>{session.operations.slice(-4).reverse().map(op => <p key={op.id} className="text-xs leading-5">{LABEL[op.action]} · {op.state}{op.message ? `：${op.message}` : ""}</p>)}</div> : null}
          <div className="space-y-2 border-t pt-3"><h2 className="text-sm font-semibold">{session?.title || "发布"}</h2><p className="text-xs leading-5 text-muted-foreground">{version ? `${STATUS[version.status]} · ${version.version ? `第 ${version.version} 版` : "当前版本"}${version.status === "hold" ? " · 客户还看不到" : ""}` : "先做出第一个版本。"}</p>
            <label className="block text-xs">可见范围<select aria-label="可见范围" value={p.visibility} onChange={e => p.setVisibility(e.target.value)} disabled={!p.canAct} className="mt-1 h-8 w-full rounded-lg border bg-background px-2 text-sm"><option value="private">仅自己</option><option value="passcode">口令访问</option><option value="public">公开</option></select></label>
            <Button variant="outline" size="sm" className="w-full" disabled={!p.canAct || p.visibility === session?.visibility} onClick={() => p.action("visibility")}>确认更改范围</Button>
            <Button size="sm" className="w-full" disabled={!p.canAct || version?.status !== "hold" || !version.embed || p.expired} onClick={() => p.action("publish")}>确认发布当前版本</Button>
          </div>
          <div className="space-y-2 border-t pt-3"><h2 className="text-sm font-semibold">链接</h2>{session?.url ? <a href={session.url} target="_blank" rel="noopener noreferrer" className="flex items-center gap-1 break-all text-xs text-clay">打开正式链接<ExternalLink className="size-3" /></a> : <p className="text-xs text-muted-foreground">尚未读取</p>}{session?.url ? <PageQR url={session.url} /> : null}<Button size="sm" variant="outline" disabled={!p.canAct} onClick={() => p.action("links")}>读取链接与二维码</Button></div>
          <div className="space-y-2 border-t pt-3"><div className="flex items-center justify-between"><h2 className="text-sm font-semibold">客户阅读</h2><Button size="icon" variant="ghost" aria-label="刷新阅读" disabled={!p.canAct} onClick={() => p.action("analytics")}><RefreshCw className="size-3.5" /></Button></div><p className="whitespace-pre-wrap text-xs leading-5 text-muted-foreground">{session?.analytics?.summary || "尚未读取，不代表为零"}</p></div>
        </div>
      </aside>
    </div>
    <AlertDialog open={!!p.confirmation} onOpenChange={o => { if (!o) p.setConfirmation(null); }}><AlertDialogContent><AlertDialogHeader><AlertDialogTitle>{p.confirmation ? `确认${LABEL[p.confirmation.action]}` : "确认操作"}</AlertDialogTitle><AlertDialogDescription>{p.confirmation?.action === "publish" ? `将当前预览版本（${p.confirmation.version_id}）发给客户可见。其它待发版本不会发布。` : `将这份方案改为「${p.visibility === "public" ? "公开，任何人可访问" : p.visibility === "passcode" ? "口令访问" : "仅自己"}」。`}</AlertDialogDescription></AlertDialogHeader><AlertDialogFooter><AlertDialogCancel>取消</AlertDialogCancel><AlertDialogAction onClick={() => { if (p.confirmation) void p.send(p.confirmation); p.setConfirmation(null); }}>确认执行</AlertDialogAction></AlertDialogFooter></AlertDialogContent></AlertDialog>
  </div>;
}
