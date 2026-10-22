// chat.tsx — 对话, the member side's front page (EPIC #3923 C3): assistant-ui's
// Thread on the person's one conversation, moved here from extras/web-chat/ui
// (issues #3637, #3646). The shell draws the bars; this page draws the thread,
// and says so when there is no conversation to reach: no home yet, the home not
// connected, the limit used up. The conversation service and /v1/chat are
// unchanged. Every piece is a stock shadcn/ui or assistant-ui component.
import { createContext, useContext, useEffect, useRef, useState, type FC, type ReactNode } from "react";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router";
import { AssistantRuntimeProvider, makeAssistantDataUI, ThreadPrimitive, useAui, type ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ExternalLinkIcon, GlobeIcon, TerminalSquareIcon } from "lucide-react";
import { Thread } from "@/components/assistant-ui/elements/thread.aui";
import { ToolFallback } from "@/components/assistant-ui/elements/tool-fallback.aui";
import { ModelSelector } from "@/components/assistant-ui/elements/model-selector.aui";
import { ComposerAddAttachment } from "@/components/assistant-ui/elements/attachment.aui";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Button } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";
import { useFleetChat, PROVIDERS, type Gate, type PageCard, type Provider } from "@/app/chat/chat";
import { useHome, whenLocal, type Home } from "@/app/chat/home";
import { useSessionView } from "@/app/chat/view";
import { handover, stageOf, SURE_MS, type Mine } from "@/app/chat/handover";
import { failWords } from "@/app/chat/talk";
import { cn } from "@/lib/utils";
import { fmtClock, resumedSecs, useTrial, useTrialBeat, useTryClock, type TrialState } from "@/app/chat/try";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import type { Quota } from "@/shared/api";
import { usePage, useShell } from "../Shell";
import { continueLink } from "@/app/chat/continue";
import { composerPlaceholder } from "@/app/chat/placeholder";
import { BindWeChatBanner } from "../WeChatBind";
import { viewAs } from "@/shared/viewAs";

type Chat = ReturnType<typeof useFleetChat> & { home: Home | null; quota: Quota | null };
const ChatCtx = createContext<Chat | null>(null);
const useChat = () => useContext(ChatCtx)!;

// iOS Safari keeps the layout viewport when the keyboard opens; size the app
// to the visual one so the composer stays above the keyboard (the new-session
// screen's 开始 too, GR5E C3).
export function useVisualViewport() {
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

// a terminal session's step read along carries its output's start only (task
// YP39): the whole of it when the person asks, from the session's own machine
const ViewWorker = createContext("");
const ViewToolStep: ToolCallMessagePartComponent = (p) => {
  const worker = useContext(ViewWorker);
  const [full, setFull] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const more = !!(p.artifact as { more?: boolean } | undefined)?.more && full === null && !!worker;
  const load = async () => {
    setBusy(true);
    try {
      const r = await fetch(`/v1/chat/view?worker=${encodeURIComponent(worker)}&tool=${encodeURIComponent(p.toolCallId)}`, { cache: "no-store" });
      const j = r.ok ? await r.json() : null;
      if (typeof j?.text === "string") setFull(j.text);
    } catch { /* the button stays */ } finally { setBusy(false); }
  };
  return (
    <>
      <ToolStep {...p} result={full ?? p.result} />
      {more ? (
        <button type="button" disabled={busy} onClick={() => void load()} data-testid="view-tool-more"
          className="text-muted-foreground hover:text-foreground -mt-1 mb-2 self-start text-[12px] underline underline-offset-2">
          {busy ? tr("读取中…", "Loading…") : tr("显示全部输出", "Show all output")}
        </button>
      ) : null}
    </>
  );
};

// a web page the agent published to the person's 活页 (task T773 ④): one tap opens it,
// in a new window (活页 is not framed here until it allows the entry to)
const PAGE_STATE = (): Record<string, string> => ({
  ready: tr("仅你可见", "Only you can see it"), review: tr("审核中，好了自动能点", "Under review; opens once it passes"),
  publishing: tr("正在发布…", "Publishing…"), failed: tr("没发出去", "Not published"),
  unavailable: tr("这台机器还没连活页", "This machine is not connected to LivePage"),
  account: tr("活页账号还没开好，网页先留在对话里，稍后自动再试", "Your LivePage account isn't ready yet. The page stays here; we'll retry shortly."),
});
// a trial's page once it went to their WeChat (task XA4R)
const PUSHED = () => tr("仅你可见 · 已发到你的微信", "Only you can see it · Sent to your WeChat");
// 现在重试: the account was not open yet — ask the agent to publish it again, now
const RetryPublish: FC<{ title: string }> = ({ title }) => {
  const aui = useAui();
  return (
    <button type="button" data-testid="page-retry" className="text-clay my-1 self-start text-[13px] font-medium"
      onClick={() => { aui.composer().setText(tr(`重试发布「${title}」`, `Retry publishing "${title}"`)); aui.composer().send(); }}>
      {tr("现在重试", "Retry now")}
    </button>
  );
};
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
            {p.status === "failed" && p.note ? `${PAGE_STATE().failed} · ${p.note}`
              : p.status === "ready" && p.pushed ? PUSHED() : PAGE_STATE()[p.status] || p.status}
            {open ? <span className="text-clay ms-auto flex items-center gap-0.5 font-medium">{tr("打开", "Open")}<ExternalLinkIcon className="size-3.5" /></span> : null}
          </span>
        </span>
      </>
    );
    const cls = "border-border bg-card my-2 flex max-w-md overflow-hidden rounded-2xl border no-underline shadow-xs";
    return (
      <>
        {p.fresh ? (
          <p data-testid="page-fresh" className="text-muted-foreground my-1 max-w-md text-[13px] leading-snug">
            {tr("已用你的微信开好活页账号。你做的网页默认只有你能看。",
              "Your LivePage account is ready, set up with your WeChat. Pages you make are visible only to you.")}
          </p>
        ) : null}
        {open
          ? <a href={p.url} target="_blank" rel="noopener noreferrer" className={`${cls} hover:bg-accent/40 transition-colors`}>{body}</a>
          : <div className={cls}>{body}</div>}
        {open ? <PagePreview p={p} /> : null}
        {p.status === "account" ? <RetryPublish title={p.title} /> : null}
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
  const { trial: mine } = useShell();
  if (!budget) return null;
  const trial = quota?.over && quota.window === "trial"; // a trial's end is not a reset (T796)
  const when = trial ? "" : whenLocal(budget.until || quota?.reset);
  const what = trial && mine?.livepage_kept // their 活页 pages are kept (task XA4R)
    ? tr("试用已结束。你的网页保留 30 天，申请转正后接着用；也可以在活页里注销、立即删除",
      "Your trial has ended. Your pages are kept for 30 days — become a member to keep using them, or close your LivePage account to delete them now")
    : trial
    ? tr("试用额度已用完或已到期，申请转正后继续使用", "Your trial is over — ask to become a member to carry on")
    : quota?.over && quota.window === "5h"
    ? tr("这 5 小时的额度用完了", "This 5-hour limit is used up")
    : tr("这周的额度用完了", "This week's limit is used up");
  return (
    <div role="status" className="border-clay-line bg-clay-soft mx-auto rounded-full border px-4 py-2 text-center text-[13px] leading-snug">
      {what}
      {when ? <>{tr("，", ", back ")}<b className="font-semibold">{when}</b>{tr(" 恢复", "")}</> : null}{tr("。", ".")}
      <a href="/app/me/usage" className="text-foreground ms-1 no-underline">{tr("看用量 ›", "See usage ›")}</a>
    </div>
  );
};

// a terminal session holds the conversation (task T810): the page reads along,
// says where it is and whether it is answering; idle, one tap takes it back
const OwnerBanner: FC = () => {
  const { owner, takeOver, taking } = useChat();
  if (!owner) return null;
  return (
    <div role="status" data-testid="owner-banner"
      className="border-border bg-card mx-auto flex w-full max-w-xl items-center gap-2 rounded-full border py-1.5 ps-4 pe-1.5 text-[13px] leading-snug shadow-xs">
      <span className={`size-2 shrink-0 rounded-full ${owner.busy ? "bg-clay animate-pulse" : "bg-muted-foreground/50"}`} />
      <span className="min-w-0 flex-1 truncate">
        {owner.busy ? tr("正在终端里回答…", "Answering in the terminal…") : tr("这段对话在终端里", "In the terminal")}
        {owner.label ? <span className="text-muted-foreground font-mono text-[12px]"> · {owner.label}</span> : null}
      </span>
      <Button size="sm" className="shrink-0 rounded-full" disabled={owner.busy || taking} onClick={() => void takeOver()}>
        {owner.busy ? tr("等它答完", "Wait for it") : taking ? tr("接过来…", "Taking over…") : tr("在这里继续", "Continue here")}
      </Button>
    </div>
  );
};
// the last turn did not finish here — the home was stopped mid-answer (a release,
// a takeover; task WD8F): said in one line, and its words go again on one tap
const InterruptedBanner: FC = () => {
  const { interrupted, retry, dismissInterrupted, busy } = useChat();
  if (!interrupted || busy) return null;
  return (
    <div role="status" data-testid="interrupted-banner"
      className="border-border bg-card mx-auto flex w-full max-w-xl items-center gap-2 rounded-full border py-1.5 ps-4 pe-1.5 text-[13px] leading-snug shadow-xs">
      <span className="bg-clay size-2 shrink-0 rounded-full" />
      <span className="min-w-0 flex-1">
        {tr("上一句没答完：服务那边重启，把回复打断了。", "The last reply was cut off: the service restarted mid-answer.")}
        {interrupted.pics ? <span className="text-muted-foreground">{tr("（图片要重新附上）", " (attach the pictures again)")}</span> : null}
      </span>
      <Button size="sm" variant="ghost" className="text-muted-foreground shrink-0 rounded-full" onClick={dismissInterrupted}>{tr("算了", "Dismiss")}</Button>
      <Button size="sm" className="shrink-0 rounded-full" onClick={retry} data-testid="interrupted-retry">{tr("重试", "Retry")}</Button>
    </div>
  );
};
// the composer's top: whoever stops the person typing says so — the terminal first, then the limit
const ComposerTop: FC = () => {
  const { owner, interrupted, busy, budget } = useChat();
  return owner ? <OwnerBanner /> : interrupted && !busy && !budget ? <InterruptedBanner /> : <QuotaBanner />;
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
// the hub's 「正在为你开家」 (fleet_accounts.go noHomeWhy): a home on its way —
// a trial a 试用二维码 just started is here before its machine is (claude-fleet MRGB)
const OPENING = "正在为你开家";
const OPENING_WORDS = (): { title: string; body: string; href?: string; action?: string } => ({
  title: tr("正在给你准备一台电脑", "Getting a computer ready for you"),
  body: tr("通常 1 分钟内好。好了会自动进入对话，不用刷新。", "Usually within a minute. The chat opens on its own when it is ready — no need to reload."),
});
const GatePage: FC<{ gate: Gate; home: Home | null; onRetry: () => void }> = ({ gate, home, onRetry }) => {
  const opening = gate.code === "no_home" && gate.msg.startsWith(OPENING);
  useEffect(() => {
    if (!opening) return;
    const t = setInterval(onRetry, 5000); // ask again until the home is there
    return () => clearInterval(t);
  }, [opening, onRetry]);
  const w = opening ? OPENING_WORDS() : GATE_WORDS()[gate.code] || { title: tr("这里打不开", "This cannot open"), body: gate.msg || tr("稍后再试。", "Try again later.") };
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

const PROVIDER_NAME: Record<Provider, string> = { claude: "Claude Code", codex: "Codex" };
// the empty conversation: the site's mark and its display type — a trial
// member (one a 试用二维码 let in, claude-fleet MRGB) is greeted with what to
// say and three lines to start from; a tap puts one in the box, nothing is sent
const Welcome: FC = () => {
  const { trial } = useShell();
  const provider = PROVIDER_NAME[useChat().provider];
  return (
    <div className="mb-8 flex flex-col items-start gap-4 px-2">
      <Logo className="size-12" />
      <h2 className="font-display text-[28px] leading-tight font-semibold tracking-tight">
        {trial ? tr("你好，想让我帮你做什么？", "Hi — what can I do for you?") : <>{tr("说第一句话吧", "Say something")}<span className="text-clay">{tr("。", ".")}</span></>}
      </h2>
      <p className="text-muted-foreground text-[15px]">
        {trial
          ? tr("直接说就行：写文案、整理表格、做一页网页、查资料……做完的东西会留在这里。", "Just say it: write copy, tidy a sheet, make a web page, look something up… what I make stays here.")
          : tr(`这是你和 ${provider} 的那一条对话：往上翻是历史，关掉页面也不会停。`,
            `This is your one conversation with ${provider}: scroll up for history; closing the page does not stop it.`)}
      </p>
      {trial && (
        <div className="grid w-full gap-2 pt-2">
          {STARTERS.map(([zh, en, zhSub, enSub]) => (
            <ThreadPrimitive.Suggestion key={zh} prompt={tr(zh, en)} send={false} asChild>
              <button type="button" className="rounded-xl border bg-card px-4 py-3 text-start text-[14px] transition-colors hover:bg-muted">
                {tr(zh, en)}
                <span className="text-muted-foreground block text-xs">{tr(zhSub, enSub)}</span>
              </button>
            </ThreadPrimitive.Suggestion>
          ))}
        </div>
      )}
    </div>
  );
};

// the empty conversation's three starting lines: 中文, English, and what each brings
const STARTERS: [string, string, string, string][] = [
  ["把这段会议录音整理成要点", "Turn these meeting notes into key points", "粘一段文字，或发个文件", "paste text or send a file"],
  ["帮我做一页活动报名网页", "Make a sign-up page for my event", "做好给你一个能发到群里的链接", "you get a link to share"],
  ["比较三款扫地机器人，列个表", "Compare three robot vacuums in a table", "会去网上查，给出来源", "it searches the web and cites sources"],
];

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
      <Button asChild className="rounded-full"><Link to="/" className="no-underline">{tr("看会话", "See sessions")}</Link></Button>
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

// The new-session screen's first words (GR5E C3): it started a new conversation
// and comes here with { say }; once the conversation has loaded (no gate) they
// are sent as the first turn, once — the address's state is cleared after.
const FirstWords: FC<{ ready: boolean }> = ({ ready }) => {
  const aui = useAui();
  const { state, pathname, search } = useLocation();
  const go = useNavigate();
  const sent = useRef(false);
  const say = typeof (state as { say?: unknown } | null)?.say === "string" ? (state as { say: string }).say.trim() : "";
  useEffect(() => {
    if (!ready || !say || sent.current) return;
    sent.current = true;
    aui.composer().setText(say);
    aui.composer().send();
    go(`${pathname}${search}`, { replace: true, state: null });
  }, [aui, ready, say, go, pathname, search]);
  return null;
};

// 「Claude Code ｜ Codex」 (task R9A2): two assistants, one conversation each on
// the same home. The page opens on the side used last; the other side's tab
// wears a dot while it runs or holds a reply this page has not shown.
const PROVIDER_KEY = "fwc-provider";
// the side the page opens on next: the new-session screen picks it (GR5E C3)
export const rememberProvider = (p: Provider) => localStorage.setItem(PROVIDER_KEY, p);
const seenKey = (p: Provider) => `fwc-seen-${p}`;
function lastProvider(): Provider {
  const p = localStorage.getItem(PROVIDER_KEY);
  return p === "codex" ? "codex" : "claude";
}

// the side's switch, 在终端里继续, and where the history on screen stands (the
// one SyncNote, 会话合一 Y01K). 新对话 is gone: a new one starts from ＋ (新会话).
const ProviderBar: FC<{ onSwitch: (p: Provider) => void; sync: SyncWord }> = ({ onSwitch, sync }) => {
  const { provider, providers, others, last, busy, resume } = useChat();
  // what is on screen is read
  useEffect(() => { if (last) localStorage.setItem(seenKey(provider), last); }, [provider, last]);
  const dot = (p: Provider) => {
    if (p === provider) return "";
    const o = others[p];
    if (o?.busy) return "busy";
    return o?.last && o.last !== localStorage.getItem(seenKey(p)) ? "new" : "";
  };
  // a home that offers one assistant shows no switch (as before this bar existed)
  if (!providers.includes("codex") && provider === "claude") return sync ? (
    <div className="mx-auto flex w-full max-w-[44rem] justify-end px-4 pt-2"><SyncNote sync={sync} /></div>) : null;
  return (
    <div className="mx-auto flex w-full max-w-[44rem] items-center gap-2 px-4 pt-3" data-testid="provider-bar">
      <div role="tablist" aria-label={tr("选助手", "Pick the assistant")}
        className="border-border bg-card inline-flex rounded-full border p-0.5 shadow-xs">
        {PROVIDERS.map((p) => {
          const d = dot(p);
          return (
            <button key={p} role="tab" type="button" aria-selected={p === provider} data-provider={p}
              onClick={() => p !== provider && onSwitch(p)}
              className={`relative rounded-full px-3.5 py-1 text-[13px] font-medium transition-colors ${p === provider ? "bg-foreground text-background" : "text-muted-foreground hover:text-foreground"}`}>
              {PROVIDER_NAME[p]}
              {d ? <span aria-label={d === "busy" ? tr("正在回复", "Replying") : tr("有新回复", "New reply")}
                className={`bg-clay absolute -top-0.5 -right-0.5 size-2 rounded-full ring-2 ring-[var(--background)] ${d === "busy" ? "animate-pulse" : ""}`} /> : null}
            </button>
          );
        })}
      </div>
      <SyncNote sync={sync} className="ms-1" />
      {/* 在终端里继续: the same conversation in the home's shell — never while a turn runs here */}
      <Button asChild={!busy && !!resume} variant="ghost" size="sm" className="text-muted-foreground ms-auto rounded-full" disabled={busy || !resume}
        title={busy ? tr("正在回复，答完再接", "Replying — continue once it is done") : tr("在网页终端里接着这段对话", "Continue this conversation in the web terminal")}>
        {!busy && resume
          ? <Link to={continueLink(provider)} className="no-underline"><TerminalSquareIcon className="size-4" /><span className="hidden sm:inline">{tr("在终端里继续", "Continue in terminal")}</span></Link>
          // one row with the icon, as the link above (task WD8F: a bare span stacked it over the words)
          : <span className="inline-flex items-center gap-2"><TerminalSquareIcon className="size-4" /><span className="hidden sm:inline">{tr("在终端里继续", "Continue in terminal")}</span></span>}
      </Button>
    </div>
  );
};

export default function ChatPage() {
  // the entry's word decides: a view it did not take (one's own row) is no view
  const { me } = useShell();
  const [provider, setProvider] = useState<Provider>(lastProvider);
  const pick = (p: Provider) => { rememberProvider(p); setProvider(p); };
  return viewAs && (!me || me.view_as) ? <PreviewChat /> : <LiveChat key={provider} provider={provider} onSwitch={pick} />;
}

// <ChatThread source> (GR5E C4): the conversation a session's workspace shows.
// `web` is the person's own conversation on one side (the page above, as /chat
// draws it on the old road); `session` is a session of the list — its record
// streams in by its worker id (task F481, view.ts). 会话合一 (Y01K): a session
// the web can talk to (the view's can_talk) is written here like a chat — a
// terminal's too, at the same time as its terminal; an older one is read-only,
// said once in its composer. A session with no worker shows what it said last.
export type ThreadSource =
  | { kind: "web"; provider: Provider }
  | { kind: "session"; machine: string; key: string; agent: string; worker?: string; open?: string };

// what the session's head shows beside its title (会话合一 Y01K): nothing while
// in sync, 同步中… while not, 家机器暂时连不上 when the home is out of reach —
// and whether it answers now, from its own stream
export type SyncWord = "" | "syncing" | "offline";
export type Head = { sync: SyncWord; busy?: boolean };

export function ChatThread({ source, last, onHead }: { source: ThreadSource; last?: string; onHead?: (h: Head) => void }) {
  const { me } = useShell();
  const [provider, setProvider] = useState<Provider>(source.kind === "web" ? source.provider : "claude");
  if (source.kind === "web") {
    const pick = (p: Provider) => { rememberProvider(p); setProvider(p); };
    return viewAs && (!me || me.view_as) ? <PreviewChat /> : <LiveChat key={provider} provider={provider} onSwitch={pick} />;
  }
  return source.worker
    ? <SessionView key={source.worker} source={source} last={last} onHead={onHead} />
    : <SessionThread source={source} last={last} />;
}

type SessionProps = { source: Extract<ThreadSource, { kind: "session" }>; last?: string; onHead?: (h: Head) => void };

// 同步中 past this long is said as the home being out of reach (and the box locks)
const SYNC_GIVE_UP_MS = 10_000;
export function useSyncWord(raw: SyncWord): SyncWord {
  const [late, setLate] = useState(false);
  useEffect(() => {
    setLate(false);
    if (raw !== "syncing") return;
    const t = setTimeout(() => setLate(true), SYNC_GIVE_UP_MS);
    return () => clearTimeout(t);
  }, [raw]);
  return raw === "syncing" && late ? "offline" : raw;
}

// The one way sync is said, everywhere (会话合一 Y01K): beside the title, small
// and grey, only while not in sync — never 「已同步」.
export const SyncNote: FC<{ sync: SyncWord; className?: string }> = ({ sync, className }) =>
  sync ? <span role="status" data-testid="sync-note" data-sync={sync} className={cn("text-muted-foreground/80 shrink-0 text-[12px] font-normal", className)}>
    {sync === "offline" ? tr("家机器暂时连不上", "Your machine is out of reach") : tr("同步中…", "Syncing…")}</span> : null;

// the composer of a session that cannot be written here: one sentence, nothing else
const readOnlyWords = (open?: string) => open
  ? tr(`只读 · 终端会话。要接着说，在 iTerm2 里输入 ${open}（详情里可复制）`, `Read-only · terminal session. To continue, run ${open} in iTerm2 (copy it in Details)`)
  : tr("只读 · 终端会话。要接着说，到它的终端里。", "Read-only · terminal session. To continue, use its terminal.");
const OFFLINE_BOX = () => tr("家机器连回来后才能发", "Send once your machine is back");

// why the record cannot be followed here, in one sentence
const VIEW_WORDS = (): Record<string, string> => ({
  not_yours: tr("没有这个会话，或者它不是你的。", "No such session of yours."),
  old_agent: tr("这台机器的 fleet 还旧，网页里看不了这个会话的对话；更新后就能看，现在请用终端。",
    "This machine's fleet is too old to show this conversation here; update it, and use the terminal for now."),
  old_service: tr("这台机器的网页对话服务还旧，看不了终端里的对话；更新后就能看，现在请用终端。",
    "This machine's chat service is too old to follow a terminal; update it, and use the terminal for now."),
  no_session: tr("这个会话已经不在那台机器上了。", "This session is no longer on that machine."),
  gone: tr("这个会话的窗口关了。", "This session's window has closed."),
  agent: tr("这个助手的对话记录网页里还读不了，请用终端。", "This assistant's record cannot be read here yet; use the terminal."),
  home_down: tr("家机器暂时连不上，连回来后接着看。", "Your machine is out of reach; this carries on once it is back."),
});

// 交回 (task VV8F): why a giveback did not happen, in one sentence
const HANDOVER_WORDS = (): Record<string, string> => ({
  web_busy: tr("网页正在回答，等它说完再交回。", "The web is answering; give it back once it is done."),
  taking: tr("另一处正在接管这个会话，稍后再看。", "Somewhere else is taking this session over; look again in a moment."),
  old_agent: tr("这台机器还旧，交回不了；更新后就能，现在请用终端。", "This machine is too old to hand it back; update it, and use the terminal for now."),
  old_service: tr("这台机器的网页对话服务还旧，交回不了；更新后就能，现在请用终端。", "This machine's chat service is too old to hand it back; update it, and use the terminal for now."),
  home_down: tr("家机器暂时连不上，稍后再试。", "Your machine is out of reach; try again later."),
  offline: tr("连不上，稍后再试。", "Not connected; try again later."),
  no_session: tr("这个会话已经不在那台机器上了。", "This session is no longer on that machine."),
});
const handoverWhy = (code: string, error: string) => HANDOVER_WORDS()[code] || error || tr("没办成，稍后再试。", "That did not work; try again.");

// a running session: talked to here when it can be (TalkView), else followed
// read-only (ReadView); one the old road handed over to this page (VV8F) stays
// written here until given back (HeldChat) — 接管 itself is gone (会话合一)
const SessionView: FC<SessionProps> = (props) => {
  const { source, onHead } = props;
  const { me } = useShell();
  // Both a read-only ticket and a view-as preview keep the runtime read-only.
  const preview = !!(me?.read_only || (viewAs && (!me || me.view_as)));
  const v = useSessionView(source.worker || "", !!me && !preview);
  const [mine, setMine] = useState<Mine>(null);
  const [, setTick] = useState(0);
  // a giveback made here is believed SURE_MS at most: look again then
  useEffect(() => {
    if (!mine) return;
    const t = setTimeout(() => setTick((n) => n + 1), SURE_MS + 50);
    return () => clearTimeout(t);
  }, [mine]);
  const stage = stageOf(v.state, mine, Date.now());
  const raw: SyncWord = v.gate?.code === "home_down" ? "offline" : v.gate && v.count ? "syncing" : v.layer && v.layer !== "home" ? "syncing" : "";
  const sync = useSyncWord(raw);
  const busy = v.state ? v.busy : undefined;
  useEffect(() => { onHead?.({ sync, busy }); }, [sync, busy, onHead]);
  if (stage === "held" && v.state?.session && !preview) return (
    <HeldChat provider={v.state.agent === "codex" ? "codex" : "claude"} session={v.state.session}
      worker={source.worker || ""} label={v.state.label} onGave={() => setMine({ held: false, at: Date.now() })} />
  );
  return <ReadView {...props} v={v} sync={sync} preview={!!preview} />;
};

// the failed line, in the composer (会话合一 Y01K): 这一句没送到 · 重试 · 在新会话里接着说
const FailLine: FC<{ v: ReturnType<typeof useSessionView> }> = ({ v }) => {
  const go = useNavigate();
  const aui = useAui();
  const p = v.failed[v.failed.length - 1];
  // a line the session gave back: its words go back in the box (never over what is typed there)
  const back = p?.returned ? p.id : "";
  useEffect(() => {
    if (!back || !p) return;
    if (!aui.composer().getState().text.trim()) aui.composer().setText(p.text);
  }, [back]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!p && !v.note) return null;
  if (!p) return <p role="status" className="text-destructive px-1 text-center text-[13px]">{v.note}</p>;
  const w = failWords(p.why);
  return (
    <div role="status" data-testid="say-failed" data-why={p.why}
      className="border-border bg-card mx-auto flex w-full max-w-xl flex-wrap items-center gap-x-2 gap-y-1 rounded-2xl border px-4 py-2 text-[13px] leading-snug shadow-xs">
      <span className="min-w-0 flex-1">{w.text}</span>
      {w.retry ? <button type="button" data-testid="say-retry" className="text-clay font-medium" onClick={() => {
        if (p.returned && aui.composer().getState().text.trim() === p.text.trim()) aui.composer().setText("");
        v.retry(p.id);
      }}>{tr("重试", "Retry")}</button> : null}
      <span className="text-muted-foreground" aria-hidden>·</span>
      <button type="button" className="text-clay font-medium" onClick={() => { v.dismiss(p.id); go("/new", { state: { say: p.text } }); }}>
        {tr("在新会话里接着说", "Continue in a new session")}</button>
    </div>
  );
};

const ReadView: FC<SessionProps & { v: ReturnType<typeof useSessionView>; sync: SyncWord; preview: boolean }> = (props) => {
  const { last, v, sync, preview, source } = props;
  const talk = v.canTalk && !preview;
  // nothing read yet and a refusal: the sentence, and the last word if there is one
  if (v.gate && !v.count) return (
    <div className="flex h-full flex-col" data-testid="session-view" data-gate={v.gate.code}>
      <div className="mx-auto flex w-full max-w-[44rem] min-h-0 flex-1 flex-col justify-end gap-3 px-4 py-6">
        {last ? <div className="bg-muted max-w-[85%] self-end rounded-2xl px-4 py-2.5 text-[15px] break-words whitespace-pre-wrap" data-testid="last-word">{last}</div> : null}
        <p className="text-muted-foreground text-center text-[13px]" role="status" data-testid="view-gate">
          {VIEW_WORDS()[v.gate.code] || v.gate.msg || tr("现在看不了这个会话的对话。", "This conversation cannot be followed right now.")}
        </p>
      </div>
      <ClosedComposer words={v.gate.code === "home_down" ? OFFLINE_BOX() : readOnlyWords(source.open)} />
    </div>
  );
  const Empty: FC = () => (
    <div className="mx-auto flex w-full max-w-[44rem] flex-1 flex-col justify-end px-4 py-6">
      <p className="text-muted-foreground text-center text-[14px]">{v.loaded ? (talk ? tr("说点什么吧。", "Say something.") : tr("它还没说话。", "Nothing said yet.")) : tr("正在读它的对话…", "Reading its conversation…")}</p>
    </div>
  );
  const Top: FC = () => <FailLine v={v} />;
  return (
    <ViewWorker.Provider value={props.source.worker || ""}>
    <AssistantRuntimeProvider runtime={v.runtime}>
      <TooltipProvider>
        <PageCardUI />
        <div className="flex h-full flex-col" data-testid="session-view" data-talk={talk ? "" : undefined} data-live={v.live ? "" : undefined}>
          <div className="min-h-0 flex-1">
            <Thread autoFocus={false}
              placeholder={sync === "offline" ? OFFLINE_BOX() : talk ? composerPlaceholder(null, null)
                : v.access === "checking" ? tr("正在连接会话，可以先写下要说的话…", "Connecting to your session; you can draft your message…") : readOnlyWords(source.open)}
              components={talk ? { Welcome: Empty, ToolFallback: ViewToolStep, ComposerStart: ComposerAddAttachment, ComposerTop: Top }
                : { Welcome: Empty, ToolFallback: ViewToolStep }} />
          </div>
        </div>
      </TooltipProvider>
    </AssistantRuntimeProvider>
    </ViewWorker.Provider>
  );
};

const ClosedComposer: FC<{ words: string }> = ({ words }) => (
  <div className="px-4 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
    <div aria-disabled data-testid="closed-composer" className="border-border text-muted-foreground mx-auto flex w-full max-w-[44rem] items-center rounded-2xl border px-4 py-3 text-[14px] opacity-70">
      {words}
    </div>
  </div>
);

// handed over on the old road (VV8F): this page's conversation on that
// assistant's side IS the session, written here; 交回终端 hands it back — never
// mid-answer. 会话合一 takes nothing over any more; this only lets one go.
const HeldChat: FC<{ provider: Provider; session: string; worker: string; label?: string; onGave: () => void }> = ({ provider, session, worker, label, onGave }) => {
  const { quota, bumpQuota } = useShell();
  const chat = useFleetChat({ provider, onTurnEnd: bumpQuota,
    blockedBy: quota?.over ? { blocked: true, ...(quota.reset ? { until: quota.reset } : {}) } : null });
  const [going, setGoing] = useState(false);
  const [why, setWhy] = useState("");
  // the web side moved on to another conversation since (新对话): this one is not it
  const other = chat.loaded && !!chat.resume?.id && chat.resume.id !== session;
  const give = async () => {
    setGoing(true); setWhy("");
    const r = await handover(worker, "giveback");
    setGoing(false);
    if (r.ok) onGave(); else setWhy(handoverWhy(r.code, r.error));
  };
  const Empty: FC = () => (
    <div className="mx-auto flex w-full max-w-[44rem] flex-1 flex-col justify-end px-4 py-6">
      <p className="text-muted-foreground text-center text-[14px]">{chat.loaded ? tr("接着说吧。", "Go on.") : tr("正在读它的对话…", "Reading its conversation…")}</p>
    </div>
  );
  return (
    <ChatCtx.Provider value={{ ...chat, home: null, quota }}>
      <AssistantRuntimeProvider runtime={chat.runtime}>
        <TooltipProvider>
          <PageCardUI />
          <div className="flex h-full flex-col" data-testid="session-held">
            <div className="px-4 pt-3">
              <div role="status" data-testid="held"
                className="border-border bg-card mx-auto flex w-full max-w-xl items-center gap-2 rounded-3xl border py-1.5 ps-4 pe-1.5 text-[13px] leading-snug shadow-xs">
                <span className="min-w-0 flex-1">
                  {tr("在这里说，终端只读", "Talk here; the terminal is read-only")}
                  {label ? <span className="text-muted-foreground hidden font-mono text-[12px] sm:inline"> · {label}</span> : null}
                </span>
                <Button size="sm" variant="outline" className="shrink-0 rounded-full" data-testid="give-back" disabled={chat.busy || going} onClick={() => void give()}>
                  <TerminalSquareIcon className="size-4" />
                  {chat.busy ? tr("等它说完", "Wait for it") : going ? tr("交回中…", "Giving back…") : tr("交回终端", "Give back")}
                </Button>
              </div>
            </div>
            {why || chat.notice ? <p role="alert" className="text-destructive px-4 pt-2 text-center text-sm">{why || chat.notice}</p> : null}
            <div className="min-h-0 flex-1">
              {other ? <p role="status" className="text-muted-foreground p-6 text-center text-[13px]">
                {tr("网页这边已经开了另一段对话；交回终端后，这个会话在终端里接着说。", "The web has moved on to another conversation; give this session back to carry on in its terminal.")}
              </p> : <Thread autoFocus={false}
                placeholder={composerPlaceholder(null, chat.budget)}
                components={{ Welcome: Empty, ToolFallback: ToolStep, ComposerStart: ComposerTools, ComposerTop: QuotaBanner }} />}
            </div>
          </div>
        </TooltipProvider>
      </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
};

const SessionThread: FC<SessionProps> = (props) => {
  const { source, last } = props;
  return (
    <div className="flex h-full flex-col" data-testid="session-thread">
      <div className="mx-auto flex w-full max-w-[44rem] min-h-0 flex-1 flex-col justify-end gap-3 px-4 py-6">
        {last ? <div className="bg-muted max-w-[85%] self-end rounded-2xl px-4 py-2.5 text-[15px] break-words whitespace-pre-wrap" data-testid="last-word">{last}</div>
          : <p className="text-muted-foreground text-center text-[14px]">{tr("它还没说话。", "Nothing said yet.")}</p>}
        <p className="text-muted-foreground text-center text-[12px]">
          {tr(`${source.agent || "会话"}的对话记录在它的终端里；这里显示它最近说的一句。`, `${source.agent || "The session"}'s conversation is in its terminal; this is the last thing it said.`)}
        </p>
      </div>
      <ClosedComposer words={readOnlyWords(source.open)} />
    </div>
  );
};

function LiveChat({ provider, onSwitch }: { provider: Provider; onSwitch: (p: Provider) => void }) {
  usePage(tr("对话", "Chat"));
  useVisualViewport();
  const { me, quota, bumpQuota } = useShell();
  const clock = useTryClock();
  const { trial, secsLeft, refresh: readTrial } = useTrial(me?.role === "trial");
  const chat = useFleetChat({
    onReply: clock.stop,
    blockedBy: quota?.over ? { blocked: true, ...(quota.reset ? { until: quota.reset } : {}) } : null,
    onTurnEnd: () => { bumpQuota(); void readTrial(); },
    provider,
  });
  // spent (time · lines) ends here; a pause, a hidden page or no input went
  // back to /app/try with the conversation kept (issue #4060)
  const over = trial?.state === "ended" && (trial.ended === "time" || trial.ended === "msgs");
  const { runtime, notice, gate } = chat;
  const home = useHome(gate?.code);
  // the Codex side is not on this home: the Claude side
  useEffect(() => { if (gate?.code === "no_provider") onSwitch("claude"); }, [gate?.code, onSwitch]);
  const beat = useTrialBeat(me?.role === "trial" && !over, chat.busy);
  // where the history on screen stands: nothing once in sync (no 「已同步」)
  const sync = useSyncWord(chat.sync === "offline" ? "offline" : chat.sync === "syncing" ? "syncing" : "");
  const resumed = resumedSecs();
  return (
    <ChatCtx.Provider value={{ ...chat, home, quota }}>
      <AssistantRuntimeProvider runtime={runtime}>
        <AboutPrefill />
        <FirstWords ready={chat.loaded && !gate && !over && !chat.owner} />
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
            {!over && !gate ? <ProviderBar onSwitch={onSwitch} sync={sync} /> : null}
            {chat.handed && !chat.owner ? <p role="status" data-testid="handed" className="text-muted-foreground px-4 pt-2 text-center text-[13px]">
              {tr("已从终端接过来", "Picked up from the terminal")}{chat.handed.label ? <span className="font-mono text-[12px]"> · {chat.handed.label}</span> : null}
              {tr(" · 历史完整，接着说", " · the whole history is here; go on")}
            </p> : null}
            {notice ? <p className="text-destructive px-4 pt-2 text-center text-sm">{notice}</p> : null}
            <div className="min-h-0 flex-1">
              {over ? <TrialOver trial={trial} /> : gate ? <GatePage gate={gate} home={home} onRetry={chat.reload} /> : (
                <Thread autoFocus={false} placeholder={sync === "offline" ? OFFLINE_BOX() : composerPlaceholder(chat.owner, chat.budget)}
                  components={{ Welcome, ToolFallback: ToolStep, ComposerStart: ComposerTools, ComposerTop }} />
              )}
            </div>
          </div>
        </TooltipProvider>
      </AssistantRuntimeProvider>
    </ChatCtx.Provider>
  );
}
