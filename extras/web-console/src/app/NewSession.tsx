// NewSession.tsx — 新建会话, /app/new (GR5E C3): where 对话 and 终端 are chosen
// now that neither is a standing entry. A computer draws it on the right, in
// the workspace beside the list; a phone, the whole screen. Two big cards —
// 对话 | 终端 —, the assistant (Claude Code | Codex; a terminal also 只开 Shell),
// the machine (the home by default; a chat and the Shell run on the home only),
// an optional line, and the send button at its bottom right starts it:
//   对话 → R9A2's 新对话 on that side (newChat), the line its first turn, at /chat;
//   终端 + an assistant → worker_start through the write door, the row it became
//     opened at /s/<ref>?view=term;
//   只开 Shell → the home's own terminal (/terminal).
// The choice is remembered in this browser (never the words); a home that is
// out says why under the cards and nothing starts. Stock shadcn/ui only; the
// rules are new-session.ts's.
import { useEffect, useMemo, useRef, useState, type FC, type KeyboardEvent } from "react";
import { useNavigate } from "react-router";
import { ArrowLeft, ArrowUp, Loader, MessageCircle, TerminalSquare } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { sendJSON, useLoad } from "@/shared/api";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { newChat } from "./chat/chat";
import { rememberProvider, useVisualViewport } from "./pages/chat";
import { useBack, usePage, useShell } from "./Shell";
import { sessionPath, WEB_CHAT_PATH } from "./SessionList";
import { shellPath } from "./legacy";
import {
  AGENTS, blocker, CHOICE_KEY, fixChoice, machinesOf, readChoice, rowForRequest, sendsOnEnter, startArgs, targetOf, TOUCH_PRIMARY,
  type Agent, type Choice, type Home, type Mode, type Start,
} from "./new-session";
import { useWorkRows } from "./work-rows";

const AGENT_NAME: Record<Agent, () => string> = {
  claude: () => "Claude Code", codex: () => "Codex", shell: () => tr("只开 Shell", "Shell only"),
};

// how long a terminal start waits for its row before it goes back to the list
const ROW_WAIT_MS = 15_000;

function saveChoice(c: Choice) {
  try { localStorage.setItem(CHOICE_KEY, JSON.stringify(c)); } catch { /* private mode */ }
}

const ModeCard: FC<{ value: Mode; icon: typeof MessageCircle; title: string; body: string; disabled: boolean }> = ({ value, icon: Icon, title, body, disabled }) => (
  <Label htmlFor={`new-${value}`}
    className={cn("border-border bg-card hover:bg-accent/40 flex cursor-pointer flex-col items-start gap-2 rounded-2xl border p-4 font-normal shadow-xs transition-colors",
      "has-[[data-state=checked]]:border-foreground has-[[data-state=checked]]:ring-foreground/15 has-[[data-state=checked]]:ring-[3px]",
      disabled && "cursor-not-allowed opacity-60")}>
    <span className="flex w-full items-center gap-2">
      <Icon className="size-5 shrink-0" aria-hidden />
      <span className="text-[17px] font-semibold">{title}</span>
      <RadioGroupItem id={`new-${value}`} value={value} disabled={disabled} className="ms-auto" />
    </span>
    <span className="text-muted-foreground text-[13px] leading-snug">{body}</span>
  </Label>
);

export default function NewSession() {
  usePage(tr("新建会话", "New session"));
  useVisualViewport();
  const go = useNavigate();
  const back = useBack();
  const { me } = useShell();
  const { rows, reload, markSeen } = useWorkRows();
  const homeRead = useLoad<Home>("/v1/chat/home");
  const nodes = useLoad<Parameters<typeof machinesOf>[0]>("/v1/nodes");
  const [choice, setChoiceState] = useState<Choice>(() => { try { return readChoice(localStorage.getItem(CHOICE_KEY)); } catch { return fixChoice(null); } });
  const setChoice = (c: Partial<Choice>) => setChoiceState((old) => fixChoice({ ...old, ...c }));
  const [words, setWords] = useState("");
  const [busy, setBusy] = useState(false);
  const [waiting, setWaiting] = useState("");   // a terminal start's key, until its row shows
  const box = useRef<HTMLTextAreaElement>(null);

  const home = homeRead.data;
  const machines = useMemo(() => machinesOf(nodes.data, me?.logins, home), [nodes.data, me?.logins, home]);
  const target = targetOf(choice, machines);
  const loading = homeRead.loading || nodes.loading;
  const why = loading ? "" : viewAs ? tr("只读预览里不能新建会话。", "A read-only preview cannot start a session.") : blocker(choice, machines, home);
  const homeOnly = choice.mode === "chat" || choice.agent === "shell";
  const shell = choice.mode === "term" && choice.agent === "shell";
  const canStart = !loading && !why && !busy && !waiting;

  // a terminal start: once its row is in the list, open it in the terminal view
  useEffect(() => {
    if (!waiting) return;
    const r = rowForRequest(rows, waiting);
    if (r) { markSeen(r); go(sessionPath(r, "term"), { replace: true }); return; }
    const t = window.setTimeout(() => {
      toast.success(tr("已开始 —— 它一会儿出现在列表里。", "Started — it shows in the list in a moment."));
      go("/", { replace: true });
    }, ROW_WAIT_MS);
    return () => clearTimeout(t);
  }, [waiting, rows]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!waiting) return;
    const t = window.setInterval(reload, 2500);
    return () => clearInterval(t);
  }, [waiting, reload]);

  // startSession: the one way a choice and its words become a session
  const startSession = async (s: Start) => {
    saveChoice(s);
    if (s.mode === "chat") {
      const provider = s.agent === "codex" ? "codex" : "claude";
      setBusy(true);
      const r = await newChat(provider);
      setBusy(false);
      if (!r.ok) {
        toast.error(r.code === "home_down" ? tr("你的家现在连不上，对话开不了。", "Your home is unreachable; the chat cannot start.")
          : r.code === "no_home" ? tr("你还没有家，对话开不了。", "You have no home yet; the chat cannot start.")
          : tr(`没能开新对话：${r.error || "稍后再试"}`, `Couldn't start the chat: ${r.error || "try again later"}`));
        return;
      }
      rememberProvider(provider);
      const say = s.words.trim();
      go(WEB_CHAT_PATH, { replace: true, state: say ? { say } : null });
      return;
    }
    if (s.agent === "shell") { go(shellPath(), { replace: true }); return; }
    setBusy(true);
    const idem = "web-" + (crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`).replace(/[^A-Za-z0-9-]/g, "");
    const r = await sendJSON<{ status?: string; result?: { error?: { message?: string } } }>("POST", "/v1/fleet/write",
      { tool: "worker_start", args_json: JSON.stringify(startArgs(s, s.words, target, idem)) });
    setBusy(false);
    const failed = !r.ok ? r.error || `HTTP ${r.status}` : r.data?.status === "failed" ? r.data.result?.error?.message || "failed" : "";
    if (failed) { toast.error(tr(`没能开始：${failed}`, `Couldn't start it: ${failed}`)); return; }
    setWaiting(idem);
    reload();
  };
  const start = () => { if (canStart) void startSession({ ...choice, words: shell ? "" : words }); };
  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    const touch = typeof matchMedia === "function" && matchMedia(TOUCH_PRIMARY).matches;
    if (sendsOnEnter({ key: e.key, shiftKey: e.shiftKey, isComposing: e.nativeEvent.isComposing, keyCode: e.keyCode }, touch)) { e.preventDefault(); start(); }
  };

  return (
    <div className="flex h-full flex-col" data-testid="new-session">
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={cn("mx-auto w-full max-w-2xl px-4 pb-4 md:px-6 md:pt-10", viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]")}>
          <div className="mb-4 flex items-center gap-2">
            <Button variant="ghost" size="icon" className="-ms-3 size-11 md:hidden" aria-label={tr("返回", "Back")}
              onClick={back}><ArrowLeft /></Button>
            <h1 className="font-display text-[24px] leading-tight font-semibold tracking-tight md:text-[28px]">
              {tr("新建会话", "New session")}<span className="text-clay">{tr("。", ".")}</span>
            </h1>
          </div>

          <RadioGroup value={choice.mode} onValueChange={(v) => setChoice({ mode: v as Mode })} className="grid grid-cols-2 gap-3"
            aria-label={tr("对话还是终端", "Chat or terminal")}>
            <ModeCard value="chat" icon={MessageCircle} title={tr("对话", "Chat")} disabled={!!viewAs}
              body={tr("在网页里和助手说话，关掉页面也不停。", "Talk with the assistant here; closing the page does not stop it.")} />
            <ModeCard value="term" icon={TerminalSquare} title={tr("终端", "Terminal")} disabled={!!viewAs}
              body={tr("在机器上开一个终端会话，打字、看它干活。", "A terminal session on a machine — type, and watch it work.")} />
          </RadioGroup>
          {why ? <p role="status" data-testid="new-why"
            className="border-destructive/40 bg-destructive/10 text-destructive mt-3 rounded-lg border px-3 py-2 text-[13px] leading-relaxed">{why}</p> : null}

          <div className="mt-5 space-y-1.5">
            <Label>{tr("助手", "Assistant")}</Label>
            <ToggleGroup type="single" variant="outline" value={choice.agent} onValueChange={(v) => v && setChoice({ agent: v as Agent })}
              className="w-full" disabled={!!viewAs}>
              {AGENTS[choice.mode].map((a) => <ToggleGroupItem key={a} value={a} className="h-11 flex-1 md:h-9">{AGENT_NAME[a]()}</ToggleGroupItem>)}
            </ToggleGroup>
          </div>

          <div className="mt-4 space-y-1.5">
            <Label htmlFor="new-machine">{tr("机器", "Machine")}</Label>
            <Select value={target?.hostname || ""} onValueChange={(v) => setChoice({ machine: v })} disabled={homeOnly || !!viewAs || machines.length < 2}>
              <SelectTrigger id="new-machine" className="w-full data-[size=default]:h-11 md:data-[size=default]:h-9">
                <SelectValue placeholder={loading ? tr("读取中…", "Loading…") : tr("没有能用的机器", "No machine to use")} />
              </SelectTrigger>
              <SelectContent>
                {machines.map((m) => (
                  <SelectItem key={m.hostname} value={m.hostname} disabled={m.state !== "on"}>
                    {m.label}{m.home ? tr(" · 家", " · home") : ""}{m.state === "lost" ? tr(" · 连不上", " · offline") : m.state === "maint" ? tr(" · 维护中", " · maintenance") : ""}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-muted-foreground text-xs">
              {choice.mode === "chat" ? tr("对话只在你的家上跑。", "A chat runs on your home only.")
                : shell ? tr("Shell 是你家上的那个终端。", "The shell is your home's own terminal.")
                : tr("默认在你的家；也可以换一台你的机器。", "Your home by default; any machine of yours will do.")}
            </p>
          </div>
        </div>
      </div>

      {/* the line, and 开始 at its bottom right — above the keyboard, above the home bar */}
      <div className="bg-background/95 flex-none px-4 pt-2 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] md:px-6 md:pb-6">
        <div className="border-input bg-card focus-within:ring-ring/50 mx-auto flex w-full max-w-2xl items-end gap-2 rounded-3xl border p-2 ps-4 shadow-xs focus-within:ring-[3px]">
          <Textarea ref={box} value={shell ? "" : words} onChange={(e) => setWords(e.target.value)} onKeyDown={onKey} rows={2}
            disabled={shell || !!viewAs} aria-label={tr("先说一句（可以不写）", "A first line (optional)")}
            placeholder={shell ? tr("只开 Shell：不用写", "Shell only: nothing to write")
              : choice.mode === "chat" ? tr("先说一句（可以不写）", "Say something first (optional)")
              : tr("要它做什么（可以不写）", "What should it do (optional)")}
            className="max-h-40 min-h-11 flex-1 resize-none border-0 bg-transparent px-0 py-2 text-base shadow-none focus-visible:ring-0 dark:bg-transparent" />
          <Button size="icon" className="size-11 shrink-0 rounded-full md:size-10" disabled={!canStart} onClick={start} data-testid="new-start"
            aria-label={tr("开始", "Start")} title={tr("开始", "Start")}>
            {busy || waiting ? <Loader className="animate-spin" aria-hidden /> : <ArrowUp />}
          </Button>
        </div>
        {waiting ? <p role="status" className="text-muted-foreground mx-auto mt-2 max-w-2xl text-center text-xs">
          {tr("正在开 —— 出现在列表里就进入它的终端。", "Opening — it opens in its terminal once it is in the list.")}</p> : null}
      </div>
    </div>
  );
}
