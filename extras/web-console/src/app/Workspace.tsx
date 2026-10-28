import { schedulePath } from "./schedules";
// A task opens its web conversation. Native interactions continue in iTerm2.
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { ArrowLeft, Info, MoreHorizontal, Play, Square, TerminalSquare } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { ChatThread, SyncNote, type Head } from "./pages/chat";
import { RowPanel } from "./pages/sessions";
import { useBack } from "./Shell";
import { headMeta, isTerminal, openLine, rowAgent, rowMachine } from "./session-list";
import { sessionPath, TermTag } from "./SessionList";
import { copyOpen } from "./cli";
import { rowWorker, type Row } from "./work";
import { toast } from "sonner";
import { canStopRow } from './task-stop';
import { stopRow, stopAcknowledgment } from './task-stop-api';
import { canContinueRow, requestRowContinue, type ContinueAgent } from './task-continue';
import { sendJSON, useMe } from "@/shared/api";
import { useWorkRows } from "./work-rows";
import { pendingStartRef } from "./task-cancel";

export function Workspace({ r }: { r: Row }) {
  const [params, setParams] = useSearchParams();
  const go = useNavigate();
  // Old task terminal links stay usable, but open the conversation once.
  useEffect(() => {
    if (params.get("view") !== "term") return;
    setParams((p) => { p.delete("view"); return p; }, { replace: true });
    toast.info(tr("已打开网页对话。原生终端操作请在 iTerm2 中继续。", "Opened the conversation. Continue native terminal interactions in iTerm2."));
  }, [params, setParams]);
  const pendingRecord = !r.live && !!r.board && ["queued", "starting", "not_seen"].includes(r.board.tag);
  const cancelRef = pendingStartRef(r);
  const { reload } = useWorkRows();
  const { me } = useMe();
  const [cancelling, setCancelling] = useState(false);
  const [cancelError, setCancelError] = useState("");
  const [stopping, setStopping] = useState(false);
  const [continuing, setContinuing] = useState(false);
  const [scheduling, setScheduling] = useState(false);
  const [details, setDetails] = useState(false);
  const [head, setHead] = useState<Head>({ sync: "" });
  const onHead = useCallback((h: Head) => setHead((o) => (o.sync === h.sync && o.busy === h.busy && o.firstPrompt === h.firstPrompt && o.agent === h.agent ? o : h)), []);
  const back = useBack();
  const agent = rowAgent(r);
  const open = openLine(r);
  const canOpen = !!(r.live || r.board?.worker_id) && r.group !== "gone";
  const canContinue = canContinueRow(r);
  const readOnly = !me || !!me.read_only || !!me.view_as || !!viewAs;

  const makeSchedule = async () => {
    if (readOnly || scheduling || !head.firstPrompt) return;
    setScheduling(true);
    try {
      const prompt = await head.firstPrompt();
      const engine = head.agent || r.board?.agent || r.task?.actual_agent || "";
      go(schedulePath("new"), { state: { prompt, name: r.title.slice(0, 120), repo: r.board?.repo || r.live?.repo || r.task?.repo || "", agent: engine === "codex" || engine === "claude" ? engine : "" } });
    } catch {
      toast.error(tr("无法确认首条消息，请重试或从「新建定时」填写任务内容。", "Could not read the first message. Retry or enter your prompt in New schedule."));
    } finally { setScheduling(false); }
  };

  const continueTask = async (nextAgent?: ContinueAgent) => {
    if (!canContinue || continuing || readOnly) return;
    setContinuing(true);
    try {
      const result = await requestRowContinue(r, { post: (url, body) => sendJSON('POST', url, body) }, nextAgent);
      if (result.ok) toast.info(tr('已提交继续请求。', 'Continue request submitted.'));
      else toast.error(tr(`没能继续：${result.error}`, `Could not continue: ${result.error}`));
      if (result.ok || result.status === 409) reload();
    } finally { setContinuing(false); }
  };

  const stop = async () => {
    if (!canStopRow(r) || stopping || !me || me.read_only || me.view_as || viewAs) return;
    setStopping(true);
    try {
      const result = await stopRow(r);
      if (!result.ok) toast.error(tr(`没能停止：${result.error}`, `Could not stop: ${result.error}`));
      else { toast.info(stopAcknowledgment(result)); reload(); }
    } finally { setStopping(false); }
  };

  const cancelStart = async () => {
    if (!cancelRef || cancelling || !me || me.read_only || me.view_as || viewAs) return;
    setCancelling(true);
    setCancelError("");
    try {
      const result = await sendJSON("POST", `/v1/fleet/tasks/${encodeURIComponent(cancelRef)}/cancel`, {});
      if (result.ok) {
        toast.info(tr("已撤销启动请求。", "Start request cancelled."));
        reload();
      } else {
        const message = result.status === 409
          ? tr("会话可能已经启动。请刷新后停止运行会话。", "The session may have started. Refresh and stop the running session.")
          : tr("没能取消启动", "Could not cancel start");
        setCancelError(`${message}${result.error ? ` · ${result.error}` : result.status ? ` (HTTP ${result.status})` : tr(" · 网络连接失败", " · Network unavailable")}`);
        if (result.status === 409) reload();
      }
    } finally { setCancelling(false); }
  };

  return (
    <div data-workspace="chat" className="bg-background flex h-full min-h-0 flex-col">
      <header className={cn("border-border/70 flex shrink-0 items-center gap-2 border-b", cn("px-3 pb-2 md:px-4 md:pt-2", viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]"))}>
        <Button variant="ghost" size="icon" className="-ms-2 size-11 shrink-0 md:hidden" aria-label={tr("返回", "Back")} onClick={back}><ArrowLeft /></Button>
        <div className="min-w-0 flex-1">
          <h1 className="flex min-w-0 items-baseline gap-1.5 text-[15px] leading-tight font-semibold" title={r.title}>
            <span className="truncate">{r.title || r.code}</span>
            <TermTag r={r} />
            <SyncNote sync={head.sync} className="ms-1" />
          </h1>
          <p className="text-muted-foreground truncate text-xs" data-testid="ws-meta">{headMeta(r, head.busy)}</p>
        </div>
        {canContinue ? <Button variant="outline" size="sm" className="h-11 shrink-0 md:h-8" disabled={continuing || readOnly} onClick={() => void continueTask()} aria-label={tr('继续', 'Continue')}>
          <Play className="size-4" />{tr('继续', 'Continue')}
        </Button> : canStopRow(r) ? <Button variant="outline" size="sm" className="h-11 shrink-0 md:h-8" disabled={stopping || readOnly} onClick={() => void stop()} aria-label={tr("停止", "Stop")}>
          <Square className="size-4" />{tr("停止", "Stop")}
        </Button> : null}
        {pendingRecord && cancelRef ? <Button variant="outline" size="sm" className="h-11 shrink-0 md:h-8"
          disabled={cancelling || !me || !!me.read_only || !!me.view_as || !!viewAs}
          onClick={() => void cancelStart()} aria-label={tr("取消启动", "Cancel start")}>
          <Square className="size-4" />{tr("取消启动", "Cancel start")}
        </Button> : null}
        <Button variant="outline" size="sm" className="h-11 min-w-11 shrink-0 md:h-8 md:min-w-0" aria-label={tr("详情", "Details")} onClick={() => setDetails(true)}>
          <Info className="md:hidden" /><span className="hidden md:inline">{tr("详情", "Details")}</span>
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" size="icon" className="size-11 shrink-0 md:size-8" aria-label={tr("更多", "More")} data-testid="ws-more">
              <MoreHorizontal />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-56">
            {canContinue ? <>
              <DropdownMenuItem disabled={continuing || readOnly} onSelect={() => void continueTask('claude')}><Play />{tr('用 Claude 继续', 'Continue with Claude')}</DropdownMenuItem>
              <DropdownMenuItem disabled={continuing || readOnly} onSelect={() => void continueTask('codex')}><Play />{tr('用 Codex 继续', 'Continue with Codex')}</DropdownMenuItem>
            </> : null}
            {canOpen ? <DropdownMenuItem onSelect={() => void copyOpen(open)} data-testid="ws-copy-open">
              <TerminalSquare />{tr(`在终端里打开 · 复制 ${open}`, `Open in terminal · copy ${open}`)}
            </DropdownMenuItem> : null}
            <DropdownMenuItem disabled={readOnly || scheduling || !head.firstPrompt} onSelect={() => void makeSchedule()}>⏰ {scheduling ? tr("读取首条消息…", "Reading first message…") : tr("设为定时任务", "Create schedule")}</DropdownMenuItem>
            {r.board?.schedule_id && <DropdownMenuItem onSelect={() => go(schedulePath(r.board!.schedule_id!))}>⏰ {tr("查看定时任务", "View schedule")}</DropdownMenuItem>}
            <DropdownMenuItem onSelect={() => setDetails(true)}><Info />{tr("详情", "Details")}</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </header>
      <div className="relative min-h-0 flex-1">
        {cancelError ? <p role="alert" className="px-4 pt-4 text-sm text-destructive">{cancelError}</p> : null}
        {pendingRecord ? <div className="min-w-0 max-w-full space-y-2 p-4 text-sm [overflow-wrap:anywhere]" role="status">
          <p>{tr(...r.tag)}</p><p>{rowAgent(r)}</p>
          {r.board?.context ? <p>{tr(...r.board.context)}</p> : null}
        </div> : null}
        {!pendingRecord ? <div className="h-full">
          <ChatThread source={{ kind: "session", machine: rowMachine(r), key: r.live?.key || r.ended?.key || "", agent, worker: rowWorker(r),
            ...(isTerminal(r) && canOpen ? { open } : {}) }}
            last={r.line} onHead={onHead} />
        </div> : null}

      </div>
      <Sheet open={details} onOpenChange={setDetails}>
        <SheetContent side="right" className="w-full min-w-0 max-w-full gap-0 overflow-y-auto sm:max-w-xl">
          {/* the card names the session itself; the drawer's own title is for a screen reader */}
          <SheetHeader className="sr-only">
            <SheetTitle>{r.title}</SheetTitle>
            <SheetDescription>{headMeta(r)}</SheetDescription>
          </SheetHeader>
          <div className="min-w-0 max-w-full px-5 pt-5 pb-[calc(env(safe-area-inset-bottom)+1.5rem)]">
            <RowPanel r={r} cli onOpen={(k) => { setDetails(false); go(sessionPath(k)); }} />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
