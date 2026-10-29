// NewSession.tsx — 新会话, /app/new (GR5E C3; 会话合一 Y01K): the one way to
// start a session — the left column's ＋, a phone's ＋ 新会话 at the bottom right.
// A computer draws it on the right, beside the list; a phone, the whole screen.
//   对话 (the default): the assistant (Claude Code | Codex) and the first line,
//     and it starts — the previous one answering or not. On the new road a chat
//     is a session on the home: POST /v1/chat/open {agent, text} (the home's
//     /api/open — a no-repo window stamped origin web, the line its first turn)
//     answers its fid and worker, opened at /s/<ref>; on the old road (the
//     entry's fleet.chat.unified off) it is the one conversation's 新对话, at /chat.
//     A model (J7BN: DeepSeek, offered when /v1/chat/home lists `models`) goes
//     with agent claude; the hub places it on a mainland machine, never the home.
//   终端: the page starts nothing — it gives the lines for the person's own
//     terminal (fleet claude · fleet codex, the install line before them); the
//     session they open shows in the list, and the web talks to it there too.
//     The web terminal is one small line at the foot, the backup.
// The choice is remembered in this browser (never the words). Stock shadcn/ui;
// the rules are new-session.ts's.
import { useEffect, useRef, useState, type FC, type KeyboardEvent } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import { ArrowLeft, ArrowUp, Loader } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { useLoad } from "@/shared/api";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { newChat } from "./chat/chat";
import { useUnified } from "./chat/home";
import { rememberProvider, useVisualViewport } from "./pages/chat";
import { useBack, usePage } from "./Shell";
import { sessionPath, WEB_CHAT_PATH } from "./SessionList";
import { shellPath } from "./legacy";
import { CopyLine, useInstallLine } from "./cli";
import {
  CHOICE_KEY, chatBlocker, fixChoice, fixModel, modelsOf, openBody, readChoice, rowForOpen, sendsOnEnter, TOUCH_PRIMARY,
  type Agent, type Choice, type Home, type Mode,
} from "./new-session";
import { useWorkRows } from "./work-rows";
import { clockOpened } from "./start-clock";

// the model switch's "the agent's own" item (a ToggleGroup value cannot be "")
const DEFAULT_MODEL = "default";

const AGENT_NAME: Record<"claude" | "codex", string> = { claude: "Claude Code", codex: "Codex" };

// how long a chat start waits for its row before it goes back to the list
const ROW_WAIT_MS = 15_000;
// …and how often it looks (task PNWW: a new row is on the board within a beat)
const ROW_POLL_MS = 1000;
// the hub keeps a person's relay 90 s idle: warmed again inside that
const WARM_EVERY_MS = 60_000;

function saveChoice(c: Choice) {
  try { localStorage.setItem(CHOICE_KEY, JSON.stringify(c)); } catch { /* private mode */ }
}

// 对话 | 终端, 「Claude Code | Codex」: one small segmented switch each
const Seg: FC<{ value: string; items: [string, string][]; onChange: (v: string) => void; label: string; disabled?: boolean }> = ({ value, items, onChange, label, disabled }) => (
  <ToggleGroup type="single" variant="outline" size="sm" value={value} onValueChange={(v) => v && onChange(v)} aria-label={label} disabled={disabled}
    className="w-max">
    {items.map(([v, words]) => (
      <ToggleGroupItem key={v} value={v} className="data-[state=on]:bg-foreground data-[state=on]:text-background h-9 px-3.5 md:h-8">{words}</ToggleGroupItem>
    ))}
  </ToggleGroup>
);

const Step: FC<{ children: string }> = ({ children }) => <p className="text-foreground/80 mt-4 text-[14px]">{children}</p>;

// 终端: the lines for the person's own terminal
const TermLines: FC<{ agent: "claude" | "codex" }> = ({ agent }) => {
  const install = useInstallLine();
  const other = agent === "codex" ? "claude" : "codex";
  return (
    <div data-testid="new-term">
      <Step>{tr("终端会话推荐在 iTerm2 里开，在本机终端里粘贴：", "Terminal sessions are best in iTerm2 — paste in your local terminal:")}</Step>
      <CopyLine text={`fleet ${agent}`} className="mt-1.5" />
      <Step>{tr(`要 ${AGENT_NAME[other]}：`, `For ${AGENT_NAME[other]}:`)}</Step>
      <CopyLine text={`fleet ${other}`} className="mt-1.5" />
      <Step>{tr("还没装 fleet？先粘贴：", "No fleet yet? Paste this first:")}</Step>
      <CopyLine text={install} className="mt-1.5" />
      <p className="text-muted-foreground mt-3 text-[13px]">{tr("开好的终端会话会出现在左边的表里，网页上也能直接说。", "It shows up in the list on the left, and you can talk to it here too.")}</p>
      <p className="border-border/80 text-muted-foreground mt-6 border-t border-dashed pt-3 text-[12px]">
        <Link to={shellPath()} className="text-muted-foreground hover:text-foreground no-underline" data-testid="new-web-term">
          {tr("没有本地终端？用网页终端（备用）", "No local terminal? Use the web terminal (backup)")}
        </Link>
      </p>
    </div>
  );
};

export default function NewSession() {
  usePage(tr("新会话", "New session"));
  useVisualViewport();
  const go = useNavigate();
  const back = useBack();
  const unified = useUnified();
  const { rows, reload, markSeen } = useWorkRows();
  const homeRead = useLoad<Home>("/v1/chat/home");
  const defaults = useLoad<{ settings: { FLEET_AGENT?: string } }>("/v1/fleet/client-settings");
  const [choice, setChoiceState] = useState<Choice>(() => { try { return readChoice(localStorage.getItem(CHOICE_KEY)); } catch { return fixChoice(null); } });
  const choiceTouched = useRef(false);
  const setChoice = (c: Partial<Choice>) => { choiceTouched.current = true; setChoiceState((old) => { const n = fixChoice({ ...old, ...c }); saveChoice(n); return n; }); };
  useEffect(() => {
    if (defaults.loading || choiceTouched.current) return;
    const configured = defaults.data?.settings?.FLEET_AGENT;
    const fallback = configured === "codex" || configured === "claude" ? configured : undefined;
    try { setChoiceState(readChoice(localStorage.getItem(CHOICE_KEY), fallback)); }
    catch { setChoiceState(fixChoice(null, fallback)); }
  }, [defaults.loading, defaults.data]);
  // 「在新会话里接着说」 brings the line that did not go through
  const { state: carried } = useLocation();
  const [words, setWords] = useState(() => (typeof (carried as { say?: unknown } | null)?.say === "string" ? (carried as { say: string }).say : ""));
  const [busy, setBusy] = useState(false);
  // a chat opened, until its row shows; t0 / openAt: its clock (task PNWW)
  const [waiting, setWaiting] = useState<{ fid: string; worker: string; t0: number; openAt: number } | null>(null);
  const box = useRef<HTMLTextAreaElement>(null);

  const agent: "claude" | "codex" = choice.agent === "codex" ? "codex" : "claude";
  // a model besides the agent's own (J7BN: DeepSeek, the mainland region's) —
  // offered only when the home read lists it; never remembered, "" by default
  const models = modelsOf(homeRead.data);
  const [modelPick, setModelPick] = useState("");
  const model = agent === "claude" ? fixModel(modelPick, homeRead.data) : "";
  const loading = homeRead.loading || defaults.loading || unified === null;
  const why = loading ? "" : viewAs ? tr("只读预览里不能新建会话。", "A read-only preview cannot start a session.") : chatBlocker(homeRead.data, model);
  const canStart = !loading && !why && !busy && !waiting;

  // the session page's code fetched while the person types (task PNWW): after
  // the press it is one more download, over a slow link up to tens of seconds
  useEffect(() => { void import("./pages/session").catch(() => {}); }, []);
  // the relay to the home dialled and kept, its service awake, while the person
  // types (task PNWW): a press then is one round trip, not a dial-back across the sea
  useEffect(() => {
    if (!unified || viewAs || why || loading) return;
    const warm = () => { void fetch("/v1/chat/warm", { cache: "no-store" }).catch(() => {}); };
    warm();
    const t = window.setInterval(warm, WARM_EVERY_MS);
    return () => clearInterval(t);
  }, [unified, why, loading]);

  // a chat start on the new road: once its row is in the list, open it
  useEffect(() => {
    if (!waiting) return;
    const r = rowForOpen(rows, waiting.fid, waiting.worker);
    if (r) {
      const w = r.board?.worker_id || r.live?.id || "";
      if (w) clockOpened(w, waiting.t0, agent, undefined, waiting.openAt);
      markSeen(r); go(sessionPath(r), { replace: true }); return;
    }
    // not listed yet: its own page reads it by its worker all the same
    const t = window.setTimeout(() => go(waiting.worker ? `/s/${encodeURIComponent(waiting.worker)}` : "/", { replace: true }), ROW_WAIT_MS);
    return () => clearTimeout(t);
  }, [waiting, rows]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!waiting) return;
    const t = window.setInterval(reload, ROW_POLL_MS);
    return () => clearInterval(t);
  }, [waiting, reload]);

  const start = async () => {
    if (!canStart) return;
    const say = words.trim();
    if (!unified) {
      // the old road: the one conversation on that side starts over (newChat), the line its first turn
      setBusy(true);
      const r = await newChat(agent);
      setBusy(false);
      if (!r.ok) {
        toast.error(r.code === "home_down" ? tr("家机器暂时连不上，对话开不了。", "Your machine is out of reach; the chat cannot start.")
          : r.code === "no_home" ? tr("你还没有家，对话开不了。", "You have no home yet; the chat cannot start.")
          : tr(`没能开新对话：${r.error || "稍后再试"}`, `Couldn't start the chat: ${r.error || "try again later"}`));
        return;
      }
      rememberProvider(agent);
      go(WEB_CHAT_PATH, { replace: true, state: say ? { say } : null });
      return;
    }
    setBusy(true);
    const t0 = Date.now();
    const r = await fetch("/v1/chat/open", { method: "POST", cache: "no-store",
      headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: JSON.stringify(openBody(agent, model, say)) }).catch(() => null);
    const j = r ? await r.json().catch(() => ({})) : {};
    setBusy(false);
    if (!r?.ok || j.state === "refused") {
      const code = String(j.code || j.reason || "");
      toast.error(code === "region_not_allowed" ? tr("DeepSeek 会话还在试用，你暂时不能开。", "DeepSeek sessions are a trial you are not on yet.")
        : code === "no_region_machine" ? tr("现在没有能开 DeepSeek 会话的机器，稍后再试。", "No machine can take a DeepSeek session now; try again later.")
        : code === "home_down" || code === "home_reconnecting" ? tr("家机器暂时连不上，对话开不了。", "Your machine is out of reach; the chat cannot start.")
        : tr(`没能开始：${j.error || (r ? `HTTP ${r.status}` : "连不上")}`, `Couldn't start it: ${j.error || (r ? `HTTP ${r.status}` : "offline")}`));
      return;
    }
    setWords("");
    const worker = String(j.worker || j.worker_id || "");
    clockOpened(worker, t0, agent);
    // its own page reads it by its worker at once (task PNWW): no wait for the list
    if (worker) { reload(); go(`/s/${encodeURIComponent(worker)}`, { replace: true }); return; }
    setWaiting({ fid: String(j.fid || ""), worker, t0, openAt: Date.now() });
    reload();
  };
  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    const touch = typeof matchMedia === "function" && matchMedia(TOUCH_PRIMARY).matches;
    if (sendsOnEnter({ key: e.key, shiftKey: e.shiftKey, isComposing: e.nativeEvent.isComposing, keyCode: e.keyCode }, touch)) { e.preventDefault(); void start(); }
  };

  return (
    <div className="flex h-full flex-col" data-testid="new-session" data-mode={choice.mode}>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={cn("mx-auto w-full max-w-2xl px-4 pb-6 md:px-6 md:pt-14", viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]")}>
          <div className="mb-4 flex items-center gap-2">
            <Button variant="ghost" size="icon" className="-ms-3 size-11 md:hidden" aria-label={tr("返回", "Back")}
              onClick={back}><ArrowLeft /></Button>
            <h1 className="font-display text-[24px] leading-tight font-semibold tracking-tight md:text-[28px]">
              {tr("新会话", "New session")}<span className="text-clay">{tr("。", ".")}</span>
            </h1>
          </div>
          <Seg value={choice.mode} label={tr("对话还是终端", "Chat or terminal")} disabled={!!viewAs}
            items={[["chat", tr("对话", "Chat")], ["term", tr("终端", "Terminal")]]} onChange={(v) => setChoice({ mode: v as Mode })} />

          {choice.mode === "term" ? <TermLines agent={agent} /> : (
            <div className="mt-4">
              <div className="border-input bg-card focus-within:ring-ring/50 rounded-2xl border p-2 ps-3.5 shadow-xs focus-within:ring-[3px]">
                <Textarea ref={box} value={words} onChange={(e) => setWords(e.target.value)} onKeyDown={onKey} rows={3} autoFocus
                  disabled={!!viewAs || !!waiting} aria-label={tr("说第一句话", "Say the first thing")}
                  placeholder={tr("说第一句话…", "Say the first thing…")}
                  className="max-h-60 min-h-20 resize-none border-0 bg-transparent px-0 py-1.5 text-base shadow-none focus-visible:ring-0 dark:bg-transparent" />
                <div className="flex items-center justify-between gap-2">
                  <div className="flex flex-wrap items-center gap-2">
                    <Seg value={agent} label={tr("选助手", "Pick the assistant")} disabled={!!viewAs || !!waiting}
                      items={(["claude", "codex"] as Agent[]).map((a) => [a, AGENT_NAME[a as "claude" | "codex"]])} onChange={(v) => setChoice({ agent: v as Agent })} />
                    {models.length > 0 && agent === "claude" ? (
                      <Seg value={model || DEFAULT_MODEL} label={tr("选模型", "Pick the model")} disabled={!!viewAs || !!waiting}
                        items={[[DEFAULT_MODEL, tr("默认", "Default")], ...models.map((m): [string, string] => [m.id, m.label])]}
                        onChange={(v) => setModelPick(v === DEFAULT_MODEL ? "" : v)} />
                    ) : null}
                  </div>
                  <Button size="icon" className="size-11 shrink-0 rounded-full md:size-9" disabled={!canStart} onClick={() => void start()} data-testid="new-start"
                    aria-label={tr("开始", "Start")} title={tr("开始", "Start")}>
                    {busy || waiting ? <Loader className="animate-spin" aria-hidden /> : <ArrowUp />}
                  </Button>
                </div>
              </div>
              {why ? <p role="status" data-testid="new-why" className="text-muted-foreground mt-2 text-[13px]">{why}</p>
                : waiting ? <p role="status" className="text-muted-foreground mt-2 text-[13px]">{tr("正在开 —— 开好就进入它。", "Opening — it opens once it is up.")}</p>
                : <p className="text-muted-foreground mt-2 text-[13px]">{tr("关掉网页也不停，随时回来接着说。", "Keeps going when you close the page; come back any time.")}</p>}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
