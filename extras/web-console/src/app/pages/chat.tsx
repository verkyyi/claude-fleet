// chat.tsx — 对话, the member side's front page (EPIC #3923 C3): assistant-ui's
// Thread on the person's one conversation, moved here from extras/web-chat/ui
// (issues #3637, #3646). The shell draws the bars; this page draws the thread,
// and says so when there is no conversation to reach: no home yet, the home not
// connected, the limit used up. The conversation service and /v1/chat are
// unchanged. Every piece is a stock shadcn/ui or assistant-ui component.
import { createContext, useContext, useEffect, useState, type FC } from "react";
import { Link, useSearchParams } from "react-router";
import { AssistantRuntimeProvider, makeAssistantDataUI, useAui, type ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ExternalLinkIcon, GlobeIcon } from "lucide-react";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { ToolFallback } from "@/components/assistant-ui/elements/tool-fallback.aui";
import { ModelSelector } from "@/components/assistant-ui/elements/model-selector.aui";
import { ComposerAddAttachment } from "@/components/assistant-ui/elements/attachment.aui";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Button } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";
import { useFleetChat, type Gate, type PageCard, type Sync } from "@/app/chat/chat";
import { useHome, whenLocal, type Home } from "@/app/chat/home";
import { fmtClock, resumedSecs, useTrial, useTrialBeat, useTryClock, type TrialState } from "@/app/chat/try";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import type { Quota } from "@/shared/api";
import { usePage, useShell } from "../Shell";
import { BindWeChatBanner } from "../WeChatBind";
import { viewAs } from "@/shared/viewAs";

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

// a web page the agent published to the person's 活页 (task T773 ④): one tap opens it,
// in a new window (活页 is not framed here until it allows the entry to)
const PAGE_STATE = (): Record<string, string> => ({
  ready: tr("仅你可见", "Only you can see it"), review: tr("审核中，好了自动能点", "Under review; opens once it passes"),
  publishing: tr("正在发布…", "Publishing…"), failed: tr("没发出去", "Not published"),
  unavailable: tr("这台机器还没连活页", "This machine is not connected to LivePage"),
});
// 在这里预览: 活页's embed link for this page, framed under a sandbox while it lasts
const PagePreview: FC<{ p: PageCard }> = ({ p }) => {
  const [open, setOpen] = useState(false);
  if (!p.embed || !(Date.parse(p.embed_exp || "") > Date.now())) return null;
  return (
    <div className="my-1 max-w-2xl">
      <button type="button" onClick={() => setOpen((o) => !o)} className="text-clay text-[13px] font-medium">
        {open ? tr("收起预览", "Hide the preview") : tr("在这里预览", "Preview here")}
      </button>
      {open ? (
        <iframe src={p.embed} title={p.title} referrerPolicy="no-referrer" loading="lazy"
          sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox"
          className="border-border mt-2 h-[70vh] w-full rounded-xl border bg-white" />
      ) : null}
    </div>
  );
};
const PageCardUI = makeAssistantDataUI<PageCard>({
  name: "fleet-page",
  render: ({ data: p }) => {
    const open = p.status === "ready" && p.url;
    const body = (
      <>
        {p.preview ? <img src={p.preview} alt="" className="border-border h-auto max-h-28 w-28 shrink-0 border-e object-cover object-left-top" /> : null}
        <span className="flex min-w-0 flex-1 flex-col justify-center gap-1 px-3.5 py-3">
          <span className="text-muted-foreground flex items-center gap-1 text-[12px]"><GlobeIcon className="size-3.5" />
            {tr("网页 · 活页", "Web page · LivePage")}{p.version && p.version > 1 ? tr(` · 第 ${p.version} 版`, ` · version ${p.version}`) : ""}</span>
          <span className="text-foreground truncate text-[15px] font-semibold">{p.title}</span>
          <span className="text-muted-foreground flex items-center gap-1 text-[12px]">
            {p.status === "failed" && p.note ? `${PAGE_STATE().failed} · ${p.note}` : PAGE_STATE()[p.status] || p.status}
            {open ? <span className="text-clay ms-auto flex items-center gap-0.5 font-medium">{tr("打开", "Open")}<ExternalLinkIcon className="size-3.5" /></span> : null}
          </span>
        </span>
      </>
    );
    const cls = "border-border bg-card my-2 flex max-w-md overflow-hidden rounded-2xl border no-underline shadow-xs";
    return (
      <>
        {open
          ? <a href={p.url} target="_blank" rel="noopener noreferrer" className={`${cls} hover:bg-accent/40 transition-colors`}>{body}</a>
          : <div className={cls}>{body}</div>}
        {open ? <PagePreview p={p} /> : null}
      </>
    );
  },
});

// the composer's start: 发图片 (task T773 ③), then the model
const ComposerTools: FC = () => (
  <div className="flex items-center gap-1"><ComposerAddAttachment /><ModelPicker /></div>
);

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

// 试用中 (issue #4059): the trial's bar, always on top while it runs — how
// long and how many lines are left, and the one way on, 「申请正式使用」.
const applyWords = (t: TrialState) => (t.applied && t.applied !== "withdrawn"
  ? tr("看我的申请", "See my application")
  : tr("申请正式使用", "Apply for full use"));

const TrialBar: FC<{ trial: TrialState; secsLeft: number }> = ({ trial, secsLeft }) => (
  <div className="px-4 pt-3">
    <Alert role="status" data-testid="trial-bar"
      className="border-clay-line bg-clay-soft mx-auto flex max-w-3xl items-center gap-3 rounded-full py-2 ps-4 pe-2">
      <b className="shrink-0 font-semibold">{tr("试用", "Trial")}</b>
      <span className="text-muted-foreground min-w-0 flex-1 truncate text-[13px]">
        {trial.state === "waiting"
          ? tr("还没领到机器", "No machine yet")
          : trial.msgs_left <= 0
            ? tr("条数用完，回复后结束", "No lines left")
            : <>{tr("还剩 ", "")}<b className="text-foreground font-mono font-semibold tabular-nums">{fmtClock(secsLeft * 1000)}</b>
              {tr(" · ", " left · ")}<b className="text-foreground font-semibold tabular-nums">{trial.msgs_left}</b>{tr(" 条", " lines")}</>}
      </span>
      <Button asChild size="sm" className="shrink-0 rounded-full">
        <a href={trial.apply} className="no-underline">{applyWords(trial)}</a>
      </Button>
    </Alert>
  </div>
);

// the trial is spent: the machine went back; what is left is applying
const TrialOver: FC<{ trial: TrialState }> = ({ trial }) => {
  const mins = Math.round(trial.max_secs / 60);
  const why = trial.ended === "msgs"
    ? tr(`${trial.max_msgs} 条消息用完了。`, `Your ${trial.max_msgs} lines are used up. `)
    : tr(`${mins} 分钟到了。`, `Your ${mins} minutes are up. `);
  return (
    <div className="mx-auto flex h-full max-w-md flex-col items-start justify-center gap-4 px-6" data-testid="trial-over">
      <Logo className="size-12" />
      <h2 className="font-display text-[26px] leading-tight font-semibold tracking-tight">
        {tr("这次试用用完了", "This trial is over")}<span className="text-clay">{tr("。", ".")}</span>
      </h2>
      <p className="text-muted-foreground text-[15px]">
        {why}{tr("觉得有用？一键申请，通过后就在这段对话里接着聊。", "Found it useful? Apply in one step — once approved you carry on in this conversation.")}
      </p>
      <Button asChild className="rounded-full"><a href={trial.apply} className="no-underline">{applyWords(trial)}</a></Button>
      <p className="text-muted-foreground text-[13px]">
        {tr("对话保存 24 小时；没通过的话，到期删除。试用里生成的文件不保留。",
          "The conversation is kept for 24 hours; if you are not approved, it is deleted then. Files made in the trial are not kept.")}
      </p>
    </div>
  );
};

// 只读预览 (claude-fleet#3944): the conversation is the person's own talk —
// the entry never relays it under a view, and the page says so.
const PreviewChat: FC = () => {
  usePage(tr("对话", "Chat"));
  const { me } = useShell();
  const name = me?.view_as?.name || "";
  return (
    <div className="mx-auto flex h-full max-w-md flex-col items-start justify-center gap-4 px-6">
      <Logo className="size-12" />
      <h2 className="font-display text-[26px] leading-tight font-semibold tracking-tight">
        {tr("对话不在预览里", "The conversation stays private")}<span className="text-clay">{tr("。", ".")}</span>
      </h2>
      <p className="text-muted-foreground text-[15px]">
        {tr(`这是${name || "他"}自己的那一条对话，只读预览不打开它。会话、任务、用量、设备和设置都和${name || "他"}看到的一样。`,
          `This is ${name || "their"}${name ? "’s" : ""} own conversation; a read-only preview does not open it. Sessions, tasks, usage, devices and settings are exactly as ${name || "they"} see${name ? "s" : ""} them.`)}
      </p>
      <Button asChild className="rounded-full"><Link to="/sessions" className="no-underline">{tr("看会话", "See sessions")}</Link></Button>
    </div>
  );
};

// the trial's 「还在吗？」 (issue #4060): no input for 3 minutes — a minute
// later the machine goes to the next person; the conversation is kept 24 h
const StillHere: FC<{ open: boolean; secs: number; onStay: () => void; onPause: () => void }> = ({ open, secs, onStay, onPause }) => (
  <AlertDialog open={open}>
    <AlertDialogContent>
      <AlertDialogHeader>
        <AlertDialogTitle>{tr("还在吗？", "Still there?")}</AlertDialogTitle>
        <AlertDialogDescription>
          {tr(`3 分钟没动静了。${secs > 0 ? `${Math.max(1, Math.round(secs / 60))} 分钟后` : "马上"}暂停，把机器让给排队的人；对话会保存 24 小时，回来接着聊。`,
            `Nothing for 3 minutes. ${secs > 0 ? `In about ${Math.max(1, Math.round(secs / 60))} minute` : "Soon"} it pauses and the machine goes to the next person; your conversation is kept 24 hours — come back and go on.`)}
        </AlertDialogDescription>
      </AlertDialogHeader>
      <AlertDialogFooter>
        <AlertDialogCancel onClick={onPause}>{tr("先暂停", "Pause now")}</AlertDialogCancel>
        <AlertDialogAction onClick={onStay}>{tr("我还在", "I'm here")}</AlertDialogAction>
      </AlertDialogFooter>
    </AlertDialogContent>
  </AlertDialog>
);

// 「在对话里说」 on a 会话 row (T769): /app/?about=<code> starts the composer
// with 「关于 <code>：」, once; the address is left clean after.
const AboutPrefill: FC = () => {
  const aui = useAui();
  const [params, setParams] = useSearchParams();
  const about = params.get("about") || "";
  useEffect(() => {
    if (!/^[A-Za-z0-9-]{2,40}$/.test(about)) return;
    aui.composer().setText(tr(`关于 ${about}：`, `About ${about}: `));
    setParams((p) => { p.delete("about"); return p; }, { replace: true });
  }, [aui, about, setParams]);
  return null;
};

export default function ChatPage() {
  // the entry's word decides: a view it did not take (one's own row) is no view
  const { me } = useShell();
  return viewAs && (!me || me.view_as) ? <PreviewChat /> : <LiveChat />;
}

// The copy beside the entry (task V9DJ D): where the history on screen stands.
function SyncChip({ sync }: { sync: Sync }) {
  if (!sync) return null;
  const off = sync === "offline";
  const words = sync === "synced" ? tr("已同步", "In sync")
    : off ? tr("同步中 · 家机器暂时连不上", "Syncing · your machine is out of reach") : tr("同步中", "Syncing");
  return (
    <div className="flex flex-col items-end gap-1 px-4 pt-2" role="status">
      <span className={`rounded-full px-2 py-px text-[12px] ${sync === "synced" ? "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" : "bg-amber-50 text-amber-800 dark:bg-amber-950 dark:text-amber-300"}`}>{words}</span>
      {off ? <span className="text-muted-foreground text-[12px]">{tr("可以看历史；家机器连回来后才能发新话", "You can read the history; send once your machine is back")}</span> : null}
    </div>
  );
}

function LiveChat() {
  usePage(tr("对话", "Chat"));
  useVisualViewport();
  const { me, quota, bumpQuota } = useShell();
  const clock = useTryClock();
  const { trial, secsLeft, refresh: readTrial } = useTrial(me?.role === "trial");
  const chat = useFleetChat({
    onReply: clock.stop,
    blockedBy: quota?.over ? { blocked: true, ...(quota.reset ? { until: quota.reset } : {}) } : null,
    onTurnEnd: () => { bumpQuota(); void readTrial(); },
  });
  // spent (time · lines) ends here; a pause, a hidden page or no input went
  // back to /app/try with the conversation kept (issue #4060)
  const over = trial?.state === "ended" && (trial.ended === "time" || trial.ended === "msgs");
  const { runtime, notice, gate } = chat;
  const home = useHome(gate?.code);
  const beat = useTrialBeat(me?.role === "trial" && !over, chat.busy);
  const resumed = resumedSecs();
  return (
    <ChatCtx.Provider value={{ ...chat, home, quota }}>
      <AssistantRuntimeProvider runtime={runtime}>
        <AboutPrefill />
        <TooltipProvider>
          <PageCardUI />
          <div className="flex h-full flex-col">
            <BindWeChatBanner unbound={!!me?.reach && !me.reach.wechat} />
            {trial && !over ? <TrialBar trial={trial} secsLeft={secsLeft} /> : null}
            <TryClock clock={clock} />
            {resumed ? <p role="status" className="text-muted-foreground px-4 pt-2 text-center text-[13px]">
              {tr(`已在一台干净的机器上续上你的对话 · 用了 ${resumed} 秒`, `Picked your conversation up on a clean machine · took ${resumed} s`)}
            </p> : null}
            <StillHere open={!!beat.beat?.warn} secs={beat.beat?.pause_in_secs ?? 0} onStay={beat.stillHere} onPause={beat.pause} />
            <SyncChip sync={chat.sync} />
            {notice ? <p className="text-destructive px-4 pt-2 text-center text-sm">{notice}</p> : null}
            <div className="min-h-0 flex-1">
              {over ? <TrialOver trial={trial} /> : gate ? <GatePage gate={gate} home={home} onRetry={chat.reload} /> : (
                <Thread autoFocus={false} placeholder={chat.budget ? tr("额度恢复后可以继续", "You can go on once the limit frees up") : undefined}
                  components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ComposerTools, ComposerTop: QuotaBanner }} />
              )}
            </div>
          </div>
        </TooltipProvider>
      </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
