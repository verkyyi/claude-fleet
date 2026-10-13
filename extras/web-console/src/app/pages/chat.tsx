// chat.tsx — 对话, the member side's front page (EPIC #3923 C3): assistant-ui's
// Thread on the person's one conversation, moved here from extras/web-chat/ui
// (issues #3637, #3646). The shell draws the bars; this page draws the thread,
// and says so when there is no conversation to reach: no home yet, the home not
// connected, the limit used up. The conversation service and /v1/chat are
// unchanged. Every piece is a stock shadcn/ui or assistant-ui component.
import { createContext, useContext, useEffect, type FC } from "react";
import { AssistantRuntimeProvider, type ToolCallMessagePartComponent } from "@assistant-ui/react";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { ToolFallback } from "@/components/assistant-ui/elements/tool-fallback.aui";
import { ModelSelector } from "@/components/assistant-ui/elements/model-selector.aui";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Button } from "@/components/ui/button";
import { useFleetChat, type Gate } from "@/app/chat/chat";
import { useHome, whenLocal, type Home } from "@/app/chat/home";
import { fmtClock, useTryClock } from "@/app/chat/try";
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import type { Quota } from "@/shared/api";
import { usePage, useShell } from "../Shell";

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
    return () => { vv.removeEventListener("resize", set); document.documentElement.style.removeProperty("--app-h"); };
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

// the limit is used up: one band over a greyed composer, until it frees up
const QuotaBanner: FC = () => {
  const { budget, quota } = useChat();
  if (!budget) return null;
  const when = whenLocal(budget.until || quota?.reset);
  const what = quota?.over && quota.window === "5h"
    ? tr("这 5 小时的额度用完了", "This 5-hour limit is used up")
    : tr("这周的额度用完了", "This week's limit is used up");
  return (
    <div role="status" className="border-clay-line bg-clay-soft mx-auto rounded-full border px-4 py-2 text-center text-[13px] leading-snug">
      {what}
      {when ? <>{tr("，", ", back ")}<b className="font-semibold">{when}</b>{tr(" 恢复", "")}</> : null}{tr("。", ".")}
      <a href="/app/usage" className="text-foreground ms-1 no-underline">{tr("看用量 ›", "See usage ›")}</a>
    </div>
  );
};

// no conversation to reach: say why, and the one thing to do about it
const GATE_WORDS = (): Record<string, { title: string; body: string; href?: string; action?: string }> => ({
  no_home: {
    title: tr("你还没有家", "You have no home yet"),
    body: tr("对话跑在你自己的那台机器上。先在「我的连接」里选一台，再回来说话。",
      "The conversation runs on your own machine. Pick one under “My connection”, then come back."),
    href: "/fleet/connection", action: tr("去「我的连接」", "Go to My connection"),
  },
  home_down: {
    title: tr("你的机器现在连不上", "Your machine is not reachable"),
    body: tr("对话只在你的家机器上跑，不会换到别的机器。它连回来后，这一页就能接着用。",
      "The conversation runs only on your home machine, never another one. Once it is back, this page carries on."),
  },
  operator: {
    title: tr("请用自己的账号登录", "Sign in with your own account"),
    body: tr("共用的口令没有自己的对话。用你自己的账号登录后再来。", "A shared token has no conversation of its own. Sign in as yourself."),
    href: "/app/signin", action: tr("登录", "Sign in"),
  },
});
const GatePage: FC<{ gate: Gate; home: Home | null; onRetry: () => void }> = ({ gate, home, onRetry }) => {
  const w = GATE_WORDS()[gate.code] || { title: tr("这里打不开", "This cannot open"), body: gate.msg || tr("稍后再试。", "Try again later.") };
  return (
    <div className="mx-auto flex h-full max-w-md flex-col items-start justify-center gap-4 px-6">
      <Logo className="size-12" />
      <h2 className="font-display text-[26px] leading-tight font-semibold tracking-tight">
        {w.title}<span className="text-clay">{tr("。", ".")}</span>
      </h2>
      <p className="text-muted-foreground text-[15px]">{w.body}</p>
      {gate.code === "home_down" && home ? (
        <p className="text-muted-foreground font-mono text-[12px]">{tr("家：", "Home: ")}{home.machine} · {home.login}{gate.msg && gate.msg !== w.title ? ` —— ${gate.msg}` : ""}</p>
      ) : null}
      <div className="flex gap-2">
        {w.href ? <Button asChild className="rounded-full"><a href={w.href} className="no-underline">{w.action}</a></Button> : null}
        {gate.code === "home_down" ? <Button className="rounded-full" onClick={onRetry}>{tr("再试一次", "Try again")}</Button> : null}
      </div>
    </div>
  );
};

// the empty conversation: the site's mark and its display type
const Welcome: FC = () => (
  <div className="mb-8 flex flex-col items-start gap-4 px-2">
    <Logo className="size-12" />
    <h2 className="font-display text-[28px] leading-tight font-semibold tracking-tight">
      {tr("说第一句话吧", "Say something")}<span className="text-clay">{tr("。", ".")}</span>
    </h2>
    <p className="text-muted-foreground text-[15px]">
      {tr("这是你的那一条对话：往上翻是历史，关掉页面也不会停。", "This is your one conversation: scroll up for history; closing the page does not stop it.")}
    </p>
  </div>
);

// the trial's clock (issue #3590): running until the first reply, then the time
const TryClock: FC<{ clock: ReturnType<typeof useTryClock> }> = ({ clock }) => {
  if (!clock.running && clock.took === null) return null;
  return (
    <p role="status" className="text-muted-foreground px-4 pt-2 text-center font-mono text-[13px]">
      {clock.took === null
        ? <>{tr("试用计时 ", "Trial clock ")}<b className="text-foreground font-semibold tabular-nums">{fmtClock(clock.elapsed)}</b></>
        : <>{tr("你用了 ", "You took ")}<b className="text-clay font-semibold tabular-nums">{fmtClock(clock.took)}</b>{tr("，从按下「60 秒试用」到第一句回复。", " from pressing “Try it in 60 seconds” to the first reply.")}</>}
    </p>
  );
};

export default function ChatPage() {
  usePage(tr("对话", "Chat"));
  useVisualViewport();
  const { quota, bumpQuota } = useShell();
  const clock = useTryClock();
  const chat = useFleetChat({
    onReply: clock.stop,
    blockedBy: quota?.over ? { blocked: true, ...(quota.reset ? { until: quota.reset } : {}) } : null,
    onTurnEnd: bumpQuota,
  });
  const { runtime, notice, gate } = chat;
  const home = useHome(gate?.code);
  return (
    <ChatCtx.Provider value={{ ...chat, home, quota }}>
      <AssistantRuntimeProvider runtime={runtime}>
        <TooltipProvider>
          <div className="flex h-full flex-col">
            <TryClock clock={clock} />
            {notice ? <p className="text-destructive px-4 pt-2 text-center text-sm">{notice}</p> : null}
            <div className="min-h-0 flex-1">
              {gate ? <GatePage gate={gate} home={home} onRetry={chat.reload} /> : (
                <Thread autoFocus={false} placeholder={chat.budget ? tr("额度恢复后可以继续", "You can go on once the limit frees up") : undefined}
                  components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ModelPicker, ComposerTop: QuotaBanner }} />
              )}
            </div>
          </div>
        </TooltipProvider>
      </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
