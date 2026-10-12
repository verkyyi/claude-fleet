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

const Logo: FC<{ className?: string }> = ({ className }) => (
  <svg viewBox="0 0 64 64" className={className} aria-hidden>
    <rect width="64" height="64" rx="15" fill="#19182a" stroke="#33304d" />
    <polyline points="14.4,35.5 21.6,42 14.4,48.5" fill="none" stroke="#d9765a" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
    <polyline points="35,15 47,26 35,37" fill="none" stroke="#d9765a" strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" />
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
    <p className="text-muted-foreground px-2 font-mono text-[11px] leading-snug break-all select-all">
      终端里接着用：cd {resume.cwd || "~"} && claude --resume {resume.id}
    </p>
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
            <Logo className="size-7 shrink-0" />
            <h1 className="font-display text-[17px] leading-none font-semibold tracking-tight">fleet 对话</h1>
            {notice ? <span className="text-destructive ms-auto truncate text-sm">{notice}</span> : null}
          </header>
          <main className="min-h-0 flex-1 pb-[env(safe-area-inset-bottom)]">
            <Thread autoFocus={false} components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ModelPicker, ComposerFooter: Resume }} />
          </main>
        </div>
      </TooltipProvider>
    </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
