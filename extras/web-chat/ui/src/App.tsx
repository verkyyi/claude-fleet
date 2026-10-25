// App.tsx — the page (issue #3637): the logo bar, then assistant-ui's Thread
// on the one conversation. Every piece is a stock shadcn/ui or assistant-ui
// component; this file only wires them.
import { createContext, useContext, useEffect, type FC } from "react";
import { AssistantRuntimeProvider, type ToolCallMessagePartComponent } from "@assistant-ui/react";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { ToolFallback } from "@/components/assistant-ui/elements/tool-fallback.aui";
import { ModelSelector } from "@/components/assistant-ui/elements/model-selector.aui";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useFleetChat } from "@/chat";
import wordmarkSvg from "../../../fleet-theme/wordmark.svg?raw";

type Chat = ReturnType<typeof useFleetChat>;
const ChatCtx = createContext<Chat | null>(null);
const useChat = () => useContext(ChatCtx)!;

// iOS Safari keeps the layout viewport when the keyboard opens; size the app
// to the visual one so the composer stays above the keyboard.
function useVisualViewport() {
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const set = () => {
      document.documentElement.style.setProperty("--app-h", `${vv.height}px`);
      window.scrollTo(0, 0);
    };
    set();
    vv.addEventListener("resize", set);
    return () => vv.removeEventListener("resize", set);
  }, []);
}

// a folded tool step reads as its gist ("Bash · ls -la"), as before
// and one waiting on the person reads as waiting, opened
const ToolStep: ToolCallMessagePartComponent = (p) => {
  const summary = (p.args as { summary?: string })?.summary;
  const waiting = !!p.approval && p.approval.approved === undefined && p.approval.resolution === undefined;
  const status = waiting ? ({ type: "requires-action", reason: "interrupt" } as const) : p.status;
  return <ToolFallback {...p} status={status} toolName={summary || p.toolName} />;
};

// the app icon (extras/fleet-theme/logo.svg's shape: a white Pac-Man on clay)
const Logo: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox="0 0 64 64" className={className} aria-hidden>
    <rect width="64" height="64" rx="15" fill="var(--fleet-clay)" />
    <path fill="#ffffff" d="M30 32L48.71 41.53A21 21 0 1 1 48.71 22.47Z" />
  </svg>
);

// the brand's text logo, read off extras/fleet-theme/wordmark.svg (the one
// source): its letters are currentColor, so they wear the header's foreground
const WORDMARK = (() => {
  const vb = /viewBox="([^"]*)"/.exec(wordmarkSvg)?.[1] ?? "0 0 0 0";
  const parts = [...wordmarkSvg.matchAll(/<path\b[^>]*>/g)].map(([tag]) => {
    const a = (n: string) => new RegExp(`\\s${n}="([^"]*)"`).exec(tag)?.[1];
    return { d: a("d") ?? "", fill: a("fill") ?? "currentColor", stroke: a("stroke"), sw: a("stroke-width") };
  });
  const [, , w, h] = vb.split(/\s+/).map(Number);
  return { vb, parts, ratio: `${w} / ${h}` };
})();
const Wordmark: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox={WORDMARK.vb} className={className} role="img" aria-label="tokenman"
    style={{ width: "auto", aspectRatio: WORDMARK.ratio, overflow: "visible" }}>
    <title>tokenman</title>
    {WORDMARK.parts.map((p, i) => <path key={i} d={p.d} fill={p.fill} stroke={p.stroke} strokeWidth={p.sw} />)}
  </svg>
);

const ModelPicker: FC = () => {
  const { models, model, setModel } = useChat();
  if (!models.length) return null;
  return (
    <ModelSelector
      models={models.map((m) => ({ id: m.id, name: m.label }))}
      value={model}
      onValueChange={setModel}
      variant="ghost"
      size="sm"
    />
  );
};

const Resume: FC = () => {
  const { resume } = useChat();
  if (!resume) return null;
  return (
    <p className="text-muted-foreground px-2 font-mono text-[11px] leading-snug break-all">
      <span className="select-all">终端里接着用：cd {resume.cwd || "~"} && claude --resume {resume.id}</span>
    </p>
  );
};

// "周一 08:00", "今天 08:00", "明天 08:00" — when the limit frees up, in the reader's own time.
function whenLocal(iso: string | undefined, now = new Date()): string {
  const t = iso ? new Date(iso) : null;
  if (!t || Number.isNaN(t.getTime())) return "";
  const hm = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(t) - day(now)) / 86400000);
  if (days === 0) return `今天 ${hm}`;
  if (days === 1) return `明天 ${hm}`;
  if (days > 1 && days < 7) return `周${"日一二三四五六"[t.getDay()]} ${hm}`;
  return `${t.getMonth() + 1}月${t.getDate()}日 ${hm}`;
}

// the limit is used up: one band over a greyed composer, until it frees up
const QuotaBanner: FC = () => {
  const { budget } = useChat();
  if (!budget) return null;
  const when = whenLocal(budget.until);
  return (
    <div role="status" className="border-[var(--fleet-clay-line)] bg-[var(--fleet-clay-soft)] mx-auto rounded-full border px-4 py-2 text-center text-[13px] leading-snug">
      额度用完了
      {when ? <>，<b className="font-semibold">{when}</b> 恢复</> : null}。
    </div>
  );
};

// the empty conversation: the site's mark and its display type
const Welcome: FC = () => (
  <div className="mb-8 flex flex-col items-start gap-4 px-2">
    <Logo className="size-12" />
    <h2 className="font-display text-[28px] leading-tight font-semibold tracking-tight">
      说第一句话吧<span className="text-clay">。</span>
    </h2>
    <p className="text-muted-foreground text-[15px]">这是你的那一条对话：往上翻是历史，关掉页面也不会停。</p>
  </div>
);

export function App() {
  useVisualViewport();
  const chat = useFleetChat();
  const { runtime, notice } = chat;

  return (
    <ChatCtx.Provider value={chat}>
      <AssistantRuntimeProvider runtime={runtime}>
      <TooltipProvider>
        <div className="flex flex-col overflow-hidden" style={{ height: "var(--app-h, 100dvh)" }}>
          <header className="border-border/70 bg-background/85 sticky top-0 z-20 flex items-center gap-2.5 border-b px-4 pt-[calc(env(safe-area-inset-top)+0.6rem)] pb-2.5 backdrop-blur-md">
            <h1 className="flex items-center gap-2 leading-none">
              <Wordmark className="h-[18px] shrink-0" />
              <span className="text-muted-foreground font-display text-[15px] font-medium">对话</span>
            </h1>
            {notice ? <span className="text-destructive ms-auto truncate text-sm">{notice}</span> : null}
          </header>
          <main className="min-h-0 flex-1 pb-[env(safe-area-inset-bottom)]">
            <Thread autoFocus={false} placeholder={chat.budget ? "额度恢复后可以继续" : undefined}
              components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ModelPicker, ComposerFooter: Resume, ComposerTop: QuotaBanner }} />
          </main>
        </div>
      </TooltipProvider>
    </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
