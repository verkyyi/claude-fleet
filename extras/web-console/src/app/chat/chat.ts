// chat.ts — the one conversation (issue #3567), as assistant-ui's external store
// (issue #3637). The server's protocol is unchanged: GET /api/conversation for
// the whole history, POST /api/turn streams NDJSON items, /api/stop, /api/answer
// — on the website the same four under the entry's /v1/chat (issue #3646, API).
// This file only turns those items into ThreadMessageLike[] for the components.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  useExternalStoreRuntime,
  type AppendMessage,
  type RespondToToolApprovalOptions,
  type ThreadMessageLike,
  SimpleImageAttachmentAdapter,
} from "@assistant-ui/react";
import { tr } from "@/shared/i18n";
import { attachedPics, MAX_PICS, packPics, type SentPic } from "./pics";
import { linkFiles, picSrc, type Pic as MediaPic } from "./media";
import { cachedCopy } from "./copy";
import { browserCache, mayCache, mayShow, trim, type Layer } from "./local";
import { meOnce } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";

// The console's conversation is the entry's /v1/chat (claude-fleet#3926: moved
// here from extras/web-chat/ui's site build, its protocol unchanged).
import { fetchChat as chatFetch } from "../../../../browser-transport/chat";
const API = "/v1/chat";
const SITE = true;

export type Item =
  | { t: "user"; text: string; images?: Pic[] }
  // an image in a reply or a tool's result (task T773): fetched by its ref; the
  // copy beside the entry carries only its preview (thumb); big = over the bound
  | { t: "image"; id?: string; ref?: string; w?: number; h?: number; thumb?: string; big?: boolean }
  | { t: "image_more"; n: number }
  // the home's files the reply before it links to (task T773 ②): target as written → ref
  | { t: "files"; files: Record<string, string> }
  // a web page the agent published to the person's 活页 (task T773 ④): a card
  | PageCard
  | { t: "text"; d: string }
  | { t: "tool"; id: string; name: string; summary?: string }
  // more: a terminal session read along carries its output's start only (task YP39)
  | { t: "tool_result"; id: string; text?: string; error?: boolean; more?: boolean }
  | { t: "stopped" }
  | { t: "error"; msg: string; code?: string }
  // a line Claude Code wrote to the agent itself — a background task's notice
  // (task WD8F): one quiet line in the reply, never the person's bubble
  | { t: "note"; kind?: string; text: string };

// the turn the home did not see end (it was stopped mid-answer — task WD8F): its words, for 重试
export type Interrupted = { text: string; pics?: number; at?: string } | null;

type Pic = MediaPic;
export type PageCard = { t: "page"; id?: string; title: string; url?: string; status: string; proposal?: string;
  version?: number; preview?: string; note?: string; embed?: string; embed_exp?: string;
  // task XA4R: 活页 was opened for a trial person by this publish (said once); the page went to their WeChat
  fresh?: boolean; pushed?: boolean };

type Question = {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: { label: string; description?: string }[];
};
export type Ask = {
  t: "ask";
  rid: string;
  id?: string; // the tool_use it gates, when the server knows it
  kind: "question" | "permission";
  questions?: Question[];
  tool?: string;
  summary?: string;
};
type Answered = { approved: boolean; answers?: Record<string, { optionIds: string[] }> };
export type Model = { id: string; label: string };
// The pool's per-person budget, as the service says it (fleet.person_budget).
export type Budget = { blocked: boolean; msg?: string; until?: string };
// Why there is no conversation to show: the entry's refusal (issue #3645) —
// no_home, home_down, operator, … — or any other read that failed.
export type Gate = { code: string; msg: string };
// The copy beside the entry: being checked against the home · matches it ·
// the home is out of reach (the copy is what shows).
export type Sync = "" | "syncing" | "synced" | "offline";
// Which side holds the conversation (task T810): a terminal session it was handed
// to, answering or idle — the page is then read-only and follows it; absent =
// this page. `handed`: it came over from a terminal session (said once, on top).
export type Owner = { where: "terminal"; busy: boolean; label?: string; machine?: string; agent?: string } | null;
export type Handed = { from: "terminal"; label?: string; at?: string } | null;
// how often a page reads the conversation while a terminal session holds it
const OWNER_POLL_MS = 3000;
// Which assistant this conversation talks to (task R9A2): each has its own one
// conversation on the same home. Claude's is addressed as before (no parameter).
export type Provider = "claude" | "codex";
export const PROVIDERS: Provider[] = ["claude", "codex"];
// The other side, as the home says it: running now, and its last finished turn
// (the page marks it read when it was last on screen).
export type Side = { busy?: boolean; last?: string };
const at = (path: string, p: Provider) => (p === "claude" ? path : `${path}${path.includes("?") ? "&" : "?"}provider=${p}`);
const modelKey = (p: Provider) => (p === "claude" ? "fwc-model" : `fwc-model-${p}`);
const GATES = new Set(["no_home", "home_down", "operator", "signin", "forbidden", "not_yours"]);

const H = { "X-Fleet-Webchat": "1", "Content-Type": "application/json" };
// The first history on screen after the page opened, and which layer drew it
// (task KSQG's measure): performance marks chat:first:<layer>, and the first
// one on window.__fleetChatFirst = { layer, ms } for a test to read.
const marked = new Set<string>();
function markFirst(layer: "local" | "copy" | "home") {
  if (marked.has(layer)) return;
  marked.add(layer);
  try {
    performance.mark(`chat:first:${layer}`);
    const w = window as unknown as { __fleetChatFirst?: { layer: string; ms: number } };
    w.__fleetChatFirst ??= { layer, ms: Math.round(performance.now()) };
  } catch { /* no performance API */ }
}

// how often a page on screen reads the home again by itself (task Y393)
const POLL_MS = 30_000;
type Part = Exclude<ThreadMessageLike["content"], string>[number];
export type Msg = { id: string; role: "user" | "assistant"; content: Part[]; status?: ThreadMessageLike["status"] };

// items → messages: a user line is one message, everything after it up to the
// next user line is the assistant's (text, folded tool steps, the asks).
// `worker`: the items are a terminal session's, read along (task YP39) — its
// images and files are fetched from the machine it runs on
export function toMessages(items: Item[], asks: Ask[], answered: Map<string, Answered>, worker = ""): Msg[] {
  const out: Msg[] = [];
  let cur: Msg | null = null;
  const tools = new Map<string, Record<string, unknown>>();
  const files = new Map<string, string>();
  for (const it of items) if (it.t === "files") for (const [k, v] of Object.entries(it.files || {})) files.set(k, v);
  // a page published again (a new version, a review that passed): every card of it says the latest
  const latest = new Map<string, PageCard>();
  for (const it of items) if (it.t === "page" && it.proposal) latest.set(it.proposal, { ...latest.get(it.proposal), ...it });
  const assistant = (i: number) => {
    if (!cur) { cur = { id: `a${i}`, role: "assistant", content: [] }; out.push(cur); }
    return cur;
  };
  items.forEach((it, i) => {
    switch (it.t) {
      case "user":
        cur = null;
        out.push({ id: `u${i}`, role: "user", content: [
          ...(it.images || []).filter((g) => picSrc(g, undefined, worker)).map((g) => ({ type: "image", image: picSrc(g, undefined, worker) }) as Part),
          ...(it.text || !it.images?.length ? [{ type: "text", text: it.text } as Part] : []),
        ] });
        break;
      case "text": {
        const m = assistant(i);
        const last = m.content[m.content.length - 1] as { type: string; text?: string } | undefined;
        if (last?.type === "text") m.content[m.content.length - 1] = { type: "text", text: linkFiles((last.text || "") + it.d, files, undefined, worker) };
        else m.content.push({ type: "text", text: linkFiles(it.d, files, undefined, worker) });
        break;
      }
      case "tool": {
        // the gist rides in args.summary (the folded line); no raw-args block under it
        const p = { type: "tool-call", toolCallId: it.id, toolName: it.name, args: { summary: it.summary || it.name }, argsText: "" } as Record<string, unknown>;
        tools.set(it.id, p);
        assistant(i).content.push(p as Part);
        break;
      }
      case "tool_result": {
        let p = tools.get(it.id);
        if (!p) {
          p = { type: "tool-call", toolCallId: it.id, toolName: tr("工具结果", "Tool result"), args: {}, argsText: "" };
          tools.set(it.id, p);
          assistant(i).content.push(p as Part);
        }
        p.result = it.text || tr("(空)", "(empty)");
        p.isError = !!it.error;
        if (it.more) p.artifact = { more: true };
        break;
      }
      case "image": {
        const src = it.big ? "" : picSrc(it, undefined, worker);
        if (src) assistant(i).content.push({ type: "image", image: src } as Part);
        else assistant(i).content.push({ type: "text", text: it.big
          ? tr("\n\n*（一张图超过 10 MB，网页里不显示）*\n\n", "\n\n*(An image over 10 MB is not shown here.)*\n\n")
          : tr("\n\n*（图片在你的机器上，连上后显示）*\n\n", "\n\n*(The image shows once your machine is back.)*\n\n") } as Part);
        break;
      }
      case "page": {
        const p = it.proposal ? { ...it, ...latest.get(it.proposal), id: it.id } : it;
        const card = { ...p, ...(p.preview ? { preview: picSrc({ ref: p.preview }, undefined, worker) } : {}) };
        assistant(i).content.push({ type: "data", name: "fleet-page", data: card } as unknown as Part);
        break;
      }
      case "image_more": {
        const m = assistant(i);
        const last = m.content[m.content.length - 1] as { type: string; text?: string; more?: number } | undefined;
        const n = (last?.more || 0) + (it.n || 1);
        const part = { type: "text", text: tr(`\n\n*还有 ${n} 张图没显示*\n\n`, `\n\n*${n} more image(s) not shown*\n\n`), more: n } as Part;
        if (last?.more) m.content[m.content.length - 1] = part; else m.content.push(part);
        break;
      }
      case "note":
        assistant(i).content.push({ type: "text", text: `\n\n*${it.text}*\n\n` } as Part);
        break;
      case "stopped":
        assistant(i).status = { type: "incomplete", reason: "cancelled" };
        cur = null;
        break;
      case "error":
        // a budget refusal is the banner's to say, never a red bubble (issue #3646)
        assistant(i).status = it.code === "budget" ? { type: "incomplete", reason: "other" } : { type: "incomplete", reason: "error", error: it.msg };
        cur = null;
        break;
    }
  });
  // what the agent is asking right now rides on the tool step it gates
  for (const a of asks) {
    const done = answered.get(a.rid);
    const approval = a.kind === "question"
      ? {
          id: a.rid, display: "questions" as const,
          questions: (a.questions || []).map((q) => ({
            id: q.question, prompt: q.question, ...(q.header ? { header: q.header } : {}), multiple: !!q.multiSelect,
            options: (q.options || []).map((o) => ({ id: o.label, label: o.label, ...(o.description ? { description: o.description } : {}) })),
          })),
          ...(done ? { approved: done.approved, ...(done.answers ? { answers: done.answers } : {}) } : {}),
        }
      : {
          id: a.rid, prompt: `${tr("要用工具：", "Wants to use: ")}${a.summary || a.tool}`,
          ...(done ? { approved: done.approved } : {}),
        };
    let p = a.id ? tools.get(a.id) : undefined;
    if (!p) {
      p = { type: "tool-call", toolCallId: a.id || a.rid, toolName: a.kind === "question" ? "AskUserQuestion" : a.tool || tr("工具", "Tool"),
        args: { summary: a.summary || "" }, argsText: "" };
      const m: Msg = out[out.length - 1]?.role === "assistant" ? out[out.length - 1] : (out.push({ id: `a-${a.rid}`, role: "assistant", content: [] }), out[out.length - 1]);
      m.content.push(p as Part);
      tools.set(String(p.toolCallId), p);
    }
    // the message keeps its own status (running): flipping it to requires-action
    // mid-stream freezes assistant-ui's smooth text reveal — the step opens itself
    // instead (App.tsx ToolStep, thread.aui.tsx PendingToolGroup)
    p.approval = approval;
  }
  return out;
}

async function readLines(r: Response, onItems: (items: Record<string, unknown>[]) => void) {
  const rd = r.body!.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await rd.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const batch: Record<string, unknown>[] = [];
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line) batch.push(JSON.parse(line));
    }
    if (batch.length) onItems(batch);
  }
}

// newChat: one side starts over (R9A2's 新对话) — the chat page's button and
// the new-session screen (GR5E C3) both go through it. code is the entry's word
// when it refused (no_home · home_down · …), "" when it could not be asked.
export async function newChat(p: Provider, signal?: AbortSignal): Promise<{ ok: true } | { ok: false; code: string; error: string }> {
  const r = await chatFetch(at(`${API}/new`, p), { method: "POST", headers: H, signal, body: "{}" }).catch(() => null);
  if (r?.ok) return { ok: true };
  const j = r ? await r.json().catch(() => ({})) : {};
  return { ok: false, code: String(j.code || ""), error: String(j.error || (r ? `HTTP ${r.status}` : "")) };
}

// blockedBy: a limit the page knows of before the service refuses a turn (the
// website reads the person's own off /v1/me/usage); onTurnEnd: a turn ended here;
// onReply: the first text of a reply arrived (the trial's clock, issue #3590).
export function useFleetChat({ blockedBy = null, onTurnEnd, onReply, provider = "claude" }: { blockedBy?: Budget | null; onTurnEnd?: () => void; onReply?: () => void; provider?: Provider } = {}) {
  const [items, setItems] = useState<Item[]>([]);
  const [asks, setAsks] = useState<Ask[]>([]);
  const [answered, setAnswered] = useState<Map<string, Answered>>(new Map());
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [models, setModels] = useState<Model[]>([]);
  const [model, setModelState] = useState("");
  const [resume, setResume] = useState<{ id: string; cwd: string } | null>(null);
  const [notice, setNotice] = useState("");
  const [gate, setGate] = useState<Gate | null>(null);
  const [budget, setBudget] = useState<Budget>({ blocked: false });
  // The copy beside the entry (task V9DJ D): shown first, marked syncing until
  // the home answers; the home's answer replaces it. "" = no copy in play.
  const [sync, setSync] = useState<Sync>("");
  const [owner, setOwner] = useState<Owner>(null);
  const [handed, setHanded] = useState<Handed>(null);
  const [others, setOthers] = useState<Partial<Record<Provider, Side>>>({});
  // the assistants the home offers (an older home, or one without codex: none said ⇒ Claude only)
  const [providers, setProviders] = useState<Provider[]>(["claude"]);
  const [last, setLast] = useState("");
  const [interrupted, setInterrupted] = useState<Interrupted>(null);
  const hadCopy = useRef(false);
  // the history this browser kept (task KSQG) is on the page, before copy or home
  const hadLocal = useRef(false);
  const localTried = useRef(false);
  // the highest layer on the page so far (local < copy < home)
  const top = useRef<Layer | null>(null);
  // what the local layer drew, to tell a copy that says the same thing
  const localDrawn = useRef("");
  // whose history this page may keep in the browser ("" = none: a view, a ticket, unknown)
  const [keeper, setKeeper] = useState("");
  const homeDefault = useRef("");
  // the home has answered this page once: from then on only the home is shown
  const homeSeen = useRef(false);
  const turnEnd = useRef(onTurnEnd);
  turnEnd.current = onTurnEnd;
  const reply = useRef(onReply);
  reply.current = onReply;
  const turnId = useRef<string | null>(null);
  const streaming = useRef(false);
  const transport = useRef(new AbortController());
  const follow = useRef<number | undefined>(undefined);
  const historyRead = useRef(0);
  // bumped by 新对话: a stream from before it is the conversation put away (task WD8F)
  const convGen = useRef(0);

  const load = useCallback(async () => {
    clearTimeout(follow.current);
    const signal = transport.current.signal;
    if (signal.aborted || !navigator.onLine || streaming.current) return;
    const read = ++historyRead.current;
    if (!localTried.current && !homeSeen.current) {
      // first of all, what this browser kept (no network but /v1/me, which the
      // shell has in flight already): drawn only while neither copy nor home has
      // answered — a lower layer never replaces a higher one
      localTried.current = true;
      const kept = browserCache()?.readAny(provider).catch(() => null) ?? Promise.resolve(null);
      void meOnce().then(async (me) => {
        if (!mayCache(me, viewAs)) return;
        setKeeper(me!.person!);
        const any = await kept;
        const snap = any && any.principal === me!.person ? any.snap : null;
        if (!snap || !snap.items.length || signal.aborted || !mayShow("local", top.current)) return;
        hadLocal.current = true;
        top.current = "local";
        localDrawn.current = JSON.stringify(snap.items);
        markFirst("local");
        setModels((snap.models as Model[]) || []);
        setModelState((m) => {
          if (m) return m;
          const saved = localStorage.getItem(modelKey(provider));
          return ((snap.models as Model[]) || []).some((x) => x.id === saved) ? saved! : snap.default || "";
        });
        setItems(snap.items as Item[]);
        setResume(snap.session ? { id: snap.session, cwd: snap.cwd || "" } : null);
        setSync("syncing");
        setLoaded(true);
      }).catch(() => {});
    }
    if (!hadCopy.current && !homeSeen.current) {
      // first read: the entry's copy, at once, while the home's answer travels.
      // The copy is never newer than the home: once the home has answered (this
      // read or an earlier one) a copy that lands later is dropped (task Y393).
      void fetch(at(`${API}/conversation?cached=1`, provider), { headers: H, signal }).then(async (c) => {
        if (!c.ok || signal.aborted || read !== historyRead.current || homeSeen.current) return;
        // no copy kept yet (a first visit): nothing to show, the home's answer comes
        const j = cachedCopy(c.ok, await c.json().catch(() => null));
        if (!j || read !== historyRead.current || homeSeen.current || !mayShow("copy", top.current)) return;
        hadCopy.current = true;
        top.current = "copy";
        // the copy says what this browser already drew: no second render of it
        if (localDrawn.current && JSON.stringify(trim(j.items || [])) === localDrawn.current) { setSync("syncing"); return; }
        markFirst("copy");
        setModels(j.models || []);
        setModelState((m) => {
          if (m) return m;
          const saved = localStorage.getItem(modelKey(provider));
          return (j.models || []).some((x: Model) => x.id === saved) ? saved! : j.default;
        });
        setItems(j.items || []);
        setResume(j.session ? { id: j.session, cwd: j.cwd } : null);
        setSync("syncing");
        setLoaded(true);
      }).catch(() => {});
    }
    const r = await chatFetch(at(`${API}/conversation`, provider), { headers: H, signal }).catch(() => null);
    const j = r ? await r.json().catch(() => ({})) : {};
    // A newer read or local turn owns the transcript, even after that turn ends.
    if (signal.aborted || read !== historyRead.current) return;
    if (!r || !r.ok) {
      if (r?.status === 401 && SITE) { location.assign("/app/signin"); return; }
      const code = String(j.code || "");
      if (code === "home_reconnecting") {
        // the hub moved under the home's link (a deploy): it is back in seconds
        if (hadCopy.current || hadLocal.current) setSync("syncing");
        else setNotice(tr("正在重连你的家，稍候…", "Reconnecting to your machine, one moment…"));
        setLoaded(true);
        follow.current = window.setTimeout(load, 3000);
        return;
      }
      if ((hadCopy.current || hadLocal.current) && (code === "home_down" || !r)) {
        // the home is out of reach: the copy stays on the page, said so
        setSync("offline");
        setLoaded(true);
        return;
      }
      // this side is not on the home (no codex there, or an older home): back to Claude
      if (provider !== "claude" && r?.status === 404) { setGate({ code: "no_provider", msg: "" }); setLoaded(true); return; }
      if (SITE && GATES.has(code)) setGate({ code, msg: String(j.error || "") });
      else setNotice(j.error || tr("读不到对话", "Could not read the conversation"));
      setLoaded(true);
      return;
    }
    homeSeen.current = true;
    top.current = "home";
    markFirst("home");
    setNotice("");
    setGate(null);
    if (hadCopy.current || hadLocal.current) setSync("synced");
    homeDefault.current = String(j.default || "");
    setBudget(j.budget && typeof j.budget === "object" ? j.budget : { blocked: false });
    setModels(j.models || []);
    setModelState((m) => {
      if (m) return m;
      const saved = localStorage.getItem(modelKey(provider));
      return (j.models || []).some((x: Model) => x.id === saved) ? saved! : j.default;
    });
    setItems(j.items || []);
    setAsks(j.asks || []);
    setResume(j.session ? { id: j.session, cwd: j.cwd } : null);
    setBusy(!!j.busy);
    const o = j.owner && j.owner.where === "terminal" ? j.owner : null;
    setOwner(o ? { where: "terminal", busy: !!o.busy, label: o.label, machine: o.machine, agent: o.agent } : null);
    setHanded(j.handed && j.handed.from === "terminal" ? j.handed : null);
    setOthers(j.others && typeof j.others === "object" ? j.others : {});
    setProviders(Array.isArray(j.providers) ? j.providers.filter((p: string): p is Provider => PROVIDERS.includes(p as Provider)) : ["claude"]);
    setLast(String(j.last || ""));
    setInterrupted(j.interrupted && typeof j.interrupted.text === "string" ? j.interrupted : null);
    turnId.current = j.turn || null;
    setLoaded(true);
    // a turn this page did not start (or lost): follow it; a terminal holding it: follow that
    if (j.busy && !streaming.current) follow.current = window.setTimeout(load, 2500);
    else if (o) follow.current = window.setTimeout(load, OWNER_POLL_MS);
  }, [provider]);

  useEffect(() => {
    transport.current = new AbortController();
    load();
    const vis = () => { if (!document.hidden && !streaming.current) load(); };
    document.addEventListener("visibilitychange", vis);
    window.addEventListener("focus", vis);
    const online = () => { if (!streaming.current) load(); };
    window.addEventListener("online", online);
    // The same person may have the chat open in another browser (task Y393):
    // what that one does reaches the home, never this page's stream — so a
    // page on screen reads the home again by itself every POLL_MS, and at once
    // when it comes back into view or focus.
    const poll = window.setInterval(() => { if (!document.hidden && !streaming.current) load(); }, POLL_MS);
    return () => {
      transport.current.abort(); clearTimeout(follow.current); clearInterval(poll);
      document.removeEventListener("visibilitychange", vis); window.removeEventListener("focus", vis); window.removeEventListener("online", online);
    };
  }, [load]);

  // keep what the home said (and what a turn added since) in this browser, for
  // the next opening — only once the home has answered, never mid-answer
  useEffect(() => {
    if (!homeSeen.current || busy || !keeper) return;
    const who = keeper;
    const t = window.setTimeout(() => {
      void browserCache()?.write(who, provider, {
        session: resume?.id || "", cwd: resume?.cwd, models, default: homeDefault.current, items,
      }).catch(() => {});
    }, 400);
    return () => clearTimeout(t);
  }, [items, busy, resume, models, provider, keeper]);

  const setModel = useCallback((m: string) => { setModelState(m); localStorage.setItem(modelKey(provider), m); }, [provider]);

  // 新对话: this side starts over; the other side and the history file stay
  // — mid-answer too (task WD8F): the home lets that turn answer on, put away
  // with its conversation; this page lets go of its stream and starts clean
  const startNew = useCallback(async () => {
    const r = await newChat(provider, transport.current.signal);
    if (!r.ok) { setNotice(r.error ? tr(`没能开新对话：${r.error}`, `Could not start a new conversation: ${r.error}`) : tr("没能开新对话，稍后再试。", "Could not start a new conversation; try again.")); return; }
    if (streaming.current) {
      ++convGen.current;
      transport.current.abort();
      transport.current = new AbortController();
      streaming.current = false;
      turnId.current = null;
      setBusy(false);
    }
    setItems([]); setAsks([]); setResume(null); setInterrupted(null); setNotice("");
    await load();
  }, [provider, load]);

  const onNew = useCallback(async (message: AppendMessage) => {
    const text = message.content.map((p) => (p.type === "text" ? p.text : "")).join("").trim();
    const shown = attachedPics(message);
    if (!text && !shown.length) return;
    if (shown.length > MAX_PICS) setNotice(tr(`一次最多发 ${MAX_PICS} 张图，只发了前 ${MAX_PICS} 张。`, `At most ${MAX_PICS} pictures a message; the first ${MAX_PICS} went.`));
    let images: SentPic[] = [];
    try { images = await packPics(shown.slice(0, MAX_PICS), text); } catch {
      setNotice(tr("这张图读不出来，换一张试试。", "That picture could not be read; try another."));
      return;
    }
    clearTimeout(follow.current);
    ++historyRead.current;
    streaming.current = true;
    const gen = convGen.current;
    setLoaded(true);
    setInterrupted(null);
    setItems((xs) => [...xs, { t: "user", text, ...(images.length ? { images: images.map((g) => ({ thumb: `data:${g.media_type};base64,${g.data}` })) } : {}) }]);
    setAsks([]);
    setBusy(true);
    let lost = false;
    let replied = false;
    try {
      const r = await chatFetch(at(`${API}/turn`, provider), { method: "POST", headers: H, signal: transport.current.signal, body: JSON.stringify({ text, model, ...(images.length ? { images } : {}), origin: location.origin }) });
      if (!r.ok) {
        const j = await r.json().catch(() => ({}));
        if (SITE && GATES.has(String(j.code || ""))) setGate({ code: String(j.code), msg: String(j.error || "") });
        setItems((xs) => [...xs, { t: "error", msg: String(j.error || r.status) }]);
        return;
      }
      await readLines(r, (batch) => {
        if (gen !== convGen.current) return;               // put away by 新对话: not this page's any more
        const add: Item[] = [];
        const newAsks: Ask[] = [];
        for (const o of batch) {
          switch (o.t) {
            case "turn": turnId.current = String(o.id); break;
            case "session": setResume({ id: String(o.id), cwd: String(o.cwd || "") }); break;
            case "ask": newAsks.push(o as unknown as Ask); break;
            case "done": break;
            case "error":
              if (o.code === "budget") setBudget({ blocked: true, ...(o.msg ? { msg: String(o.msg) } : {}), ...(o.until ? { until: String(o.until) } : {}) });
              add.push(o as unknown as Item);
              break;
            default:
              if (o.t === "text" && !replied) { replied = true; reply.current?.(); }
              add.push(o as unknown as Item);
          }
        }
        if (add.length) setItems((xs) => [...xs, ...add]);
        if (newAsks.length) setAsks((xs) => [...xs, ...newAsks.filter((a) => !xs.some((x) => x.rid === a.rid))]);
      });
    } catch {
      lost = true;
    } finally {
      if (gen === convGen.current) {
        streaming.current = false;
        setBusy(false);
        turnId.current = null;
      }
      turnEnd.current?.();
    }
    if (gen !== convGen.current) return;
    // the line dropped; the turn goes on — pick it back up. A finished turn
    // reloads too: the transcript is the record, the stream was only its preview.
    if (lost) { await load(); setNotice("连接中断，消息可能已送达。请查看对话，再决定是否重试。"); }
    else {
      setAsks([]);
      // the copy beside the entry follows the home: read the finished turn back
      if (hadCopy.current) void load();
    }
  }, [model, load]);

  // 重试 (task WD8F): the words of a turn the home was stopped in, said again
  const retry = useCallback(() => {
    const it = interrupted;
    if (!it?.text) return;
    setInterrupted(null);
    void onNew({ content: [{ type: "text", text: it.text }] } as unknown as AppendMessage);
  }, [interrupted, onNew]);
  const dismissInterrupted = useCallback(() => setInterrupted(null), []);

  const onCancel = useCallback(async () => {
    if (!turnId.current) return;
    try {
      const r = await chatFetch(at(`${API}/stop`, provider), { method: "POST", headers: H, signal: transport.current.signal, body: JSON.stringify({ turn: turnId.current }) });
      if (!r.ok) throw new Error("stop refused");
    } catch { await load(); setNotice("无法确认是否已停止，请查看对话后重试。"); }
  }, [load]);

  const onRespondToToolApproval = useCallback(async (o: RespondToToolApprovalOptions) => {
    const a = asks.find((x) => x.rid === o.approvalId);
    if (!a) return;
    let payload: Record<string, unknown>;
    let answers: Record<string, { optionIds: string[] }> | undefined;
    if (a.kind === "question") {
      const out: Record<string, string> = {};
      answers = {};
      for (const [q, ans] of Object.entries(o.answers || {})) {
        const picked = [...(ans.optionIds || []), ...(ans.text ? [ans.text] : [])];
        out[q] = picked.join(", ");
        answers[q] = { optionIds: [...(ans.optionIds || [])] };
      }
      payload = { answers: out };
    } else {
      payload = { allow: o.approved };
    }
    try {
      const r = await chatFetch(at(`${API}/answer`, provider), { method: "POST", headers: H, signal: transport.current.signal, body: JSON.stringify({ rid: a.rid, ...payload }) });
      if (!r.ok) throw new Error("answer refused");
      setAnswered((m) => new Map(m).set(a.rid, { approved: a.kind === "question" ? true : o.approved, ...(answers ? { answers } : {}) }));
    } catch { await load(); setNotice("无法确认回答是否送达，请查看对话后重试。"); }
  }, [asks, load]);

  const messages = useMemo(() => toMessages(items, asks, answered), [items, asks, answered]);

  // a refusal with a time on it lifts by itself: read the conversation again then
  const own = budget.blocked && !(budget.until && Date.parse(budget.until) <= Date.now());
  useEffect(() => {
    if (!own || !budget.until) return;
    const ms = Date.parse(budget.until) - Date.now();
    if (!(ms > 0) || ms > 2 ** 31 - 1) return;
    const t = window.setTimeout(load, ms + 1000);
    return () => clearTimeout(t);
  }, [own, budget.until, load]);
  const stop = own ? budget : blockedBy?.blocked ? blockedBy : null;

  // 在这里继续 (task T810): take the conversation back from an idle terminal session
  const [taking, setTaking] = useState(false);
  const takeOver = useCallback(async () => {
    setTaking(true);
    try {
      const r = await chatFetch(at(`${API}/take`, provider), { method: "POST", headers: H, body: "{}" });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) setNotice(j.error || tr("没接过来，稍后再试", "Could not take it over; try again"));
    } catch { setNotice(tr("没接过来，稍后再试", "Could not take it over; try again")); }
    setTaking(false);
    await load();
  }, [load, provider]);

  const runtime = useExternalStoreRuntime<Msg>({
    messages,
    convertMessage: (m) => m as ThreadMessageLike,
    isRunning: busy,
    isLoading: !loaded,
    isDisabled: !!stop || !!owner,
    onNew,
    onCancel,
    onRespondToToolApproval,
    // pictures to send (task T773 ③): the composer's 发图片 and a pasted one
    adapters: { attachments: new SimpleImageAttachmentAdapter() },
  });

  return { runtime, models, model, setModel, resume, notice, gate, budget: stop, reload: load, busy, sync, owner, handed, takeOver, taking,
    provider, providers, others, last, startNew, loaded, interrupted, retry, dismissInterrupted };
}
