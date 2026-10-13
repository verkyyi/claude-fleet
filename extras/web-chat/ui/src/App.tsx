// App.tsx — the page (issue #3637): the logo bar, then assistant-ui's Thread
// on the one conversation. Every piece is a stock shadcn/ui or assistant-ui
// component; this file only wires them. The website's build (issue #3646)
// wears the site's top bar instead, and says so when there is no conversation
// to reach: no home yet, the home not connected, the limit used up.
import { createContext, useContext, useEffect, useState, type FC } from "react";
import { AssistantRuntimeProvider, type ToolCallMessagePartComponent } from "@assistant-ui/react";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { ToolFallback } from "@/components/assistant-ui/elements/tool-fallback.aui";
import { ModelSelector } from "@/components/assistant-ui/elements/model-selector.aui";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Button } from "@/components/ui/button";
import { useFleetChat, type Gate } from "@/chat";
import { SITE, useHome, useMe, useQuota, whenLocal, type Home, type Quota } from "@/site";
import { SiteBar } from "@/SiteBar";

type Chat = ReturnType<typeof useFleetChat> & { home: Home | null; quota: Quota | null };
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
    <rect width="64" height="64" rx="15" fill="var(--fleet-bg)" stroke="var(--fleet-line)" />
    <polyline points="14.4,35.5 21.6,42 14.4,48.5" fill="none" stroke="var(--fleet-clay)" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
    <polyline points="35,15 47,26 35,37" fill="none" stroke="var(--fleet-clay)" strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" />
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
  const { resume, home } = useChat();
  if (!resume && !home) return null;
  return (
    <p className="text-muted-foreground px-2 font-mono text-[11px] leading-snug break-all">
      {home ? <>后台：{home.machine} · {home.login} 的登录{resume ? " · " : ""}</> : null}
      {resume ? <span className="select-all">终端里接着用：cd {resume.cwd || "~"} && claude --resume {resume.id}</span> : null}
    </p>
  );
};

// the limit is used up: one band over a greyed composer, until it frees up
const QuotaBanner: FC = () => {
  const { budget, quota } = useChat();
  if (!budget) return null;
  const when = whenLocal(budget.until || quota?.reset);
  const what = !SITE ? "额度用完了" : quota?.over && quota.window === "5h" ? "这 5 小时的额度用完了" : "这周的额度用完了";
  return (
    <div role="status" className="border-[var(--fleet-clay-line)] bg-[var(--fleet-clay-soft)] mx-auto rounded-full border px-4 py-2 text-center text-[13px] leading-snug">
      {what}
      {when ? <>，<b className="font-semibold">{when}</b> 恢复</> : null}。
      {SITE ? <a href="/app/usage" className="text-foreground ms-1 no-underline">看用量 ›</a> : null}
    </div>
  );
};

// no conversation to reach: say why, and the one thing to do about it
const GATE_WORDS: Record<string, { title: string; body: string; href?: string; action?: string }> = {
  no_home: { title: "你还没有家", body: "对话跑在你自己的那台机器上。先在「我的连接」里选一台，再回来说话。", href: "/fleet/connection", action: "去「我的连接」" },
  home_down: { title: "你的机器现在连不上", body: "对话只在你的家机器上跑，不会换到别的机器。它连回来后，这一页就能接着用。" },
  operator: { title: "请用自己的账号登录", body: "共用的口令没有自己的对话。用你自己的账号登录后再来。", href: "/app/signin", action: "登录" },
};
const GatePage: FC<{ gate: Gate; home: Home | null; onRetry: () => void }> = ({ gate, home, onRetry }) => {
  const w = GATE_WORDS[gate.code] || { title: "这里打不开", body: gate.msg || "稍后再试。" };
  return (
    <div className="mx-auto flex h-full max-w-md flex-col items-start justify-center gap-4 px-6">
      <Logo className="size-12" />
      <h2 className="font-display text-[26px] leading-tight font-semibold tracking-tight">
        {w.title}<span className="text-clay">。</span>
      </h2>
      <p className="text-muted-foreground text-[15px]">{w.body}</p>
      {gate.code === "home_down" && home ? (
        <p className="text-muted-foreground font-mono text-[12px]">家：{home.machine} · {home.login}{gate.msg && gate.msg !== w.title ? ` —— ${gate.msg}` : ""}</p>
      ) : null}
      <div className="flex gap-2">
        {w.href ? <Button asChild><a href={w.href} className="no-underline">{w.action}</a></Button> : null}
        {gate.code === "home_down" ? <Button onClick={onRetry}>再试一次</Button> : null}
        <Button asChild variant="outline"><a href="/app" className="text-foreground no-underline">回控制台</a></Button>
      </div>
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
  const [turns, setTurns] = useState(0);
  const me = useMe();
  const quota = useQuota(turns);
  const chat = useFleetChat({
    blockedBy: quota?.over ? { blocked: true, ...(quota.reset ? { until: quota.reset } : {}) } : null,
    onTurnEnd: () => setTurns((n) => n + 1),
  });
  const { runtime, notice, gate } = chat;
  const home = useHome(gate?.code);
  useEffect(() => {
    if (!SITE) return;
    document.documentElement.dataset.site = "";
    document.title = "对话 · ClaudeFleet";
  }, []);

  return (
    <ChatCtx.Provider value={{ ...chat, home, quota }}>
      <AssistantRuntimeProvider runtime={runtime}>
      <TooltipProvider>
        <div className="flex flex-col overflow-hidden" style={{ height: "var(--app-h, 100dvh)" }}>
          {SITE ? <SiteBar logo={<Logo className="size-7 shrink-0" />} me={me} home={home} quota={quota} resume={chat.resume} /> : <header className="border-border/70 bg-background/85 sticky top-0 z-20 flex items-center gap-2.5 border-b px-4 pt-[calc(env(safe-area-inset-top)+0.6rem)] pb-2.5 backdrop-blur-md">
            <Logo className="size-7 shrink-0" />
            <h1 className="font-display text-[17px] leading-none font-semibold tracking-tight">fleet 对话</h1>
            {notice ? <span className="text-destructive ms-auto truncate text-sm">{notice}</span> : null}
          </header>}
          {SITE && notice ? <p className="text-destructive px-4 pt-2 text-center text-sm">{notice}</p> : null}
          <main className="min-h-0 flex-1 pb-[env(safe-area-inset-bottom)]">
            {gate ? <GatePage gate={gate} home={home} onRetry={chat.reload} /> : (
              <Thread autoFocus={false} placeholder={chat.budget ? "额度恢复后可以继续" : undefined}
                components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ModelPicker, ComposerFooter: SITE ? undefined : Resume, ComposerTop: QuotaBanner }} />
            )}
          </main>
        </div>
      </TooltipProvider>
    </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
