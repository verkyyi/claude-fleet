// Workspace.tsx — one session (GR5E C4; 会话合一 Y01K), /app/s/<ref>: its head
// — the title (>_ for a terminal's session), beside it only while not in sync a
// small grey 同步中… / 家机器暂时连不上, under it its code and state, never a
// machine — then 「详情」 and 「⋯ 更多」, whose first item copies `fleet open
// <编号>` for the person's own terminal. Below, its conversation, written here
// whenever the session can be talked to. There is no 对话 | 终端 switch: the web
// terminal is the backup, one small line at the foot of 详情 (?view=term, which
// old links still open), with 对话 to come back. A phone on its side shows the
// terminal on the whole screen under a one-line head. Stock shadcn/ui only.
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { ArrowLeft, Info, Loader, MessageCircle, MoreHorizontal, TerminalSquare } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { ChatThread, SyncNote, type Head } from "./pages/chat";
import { RowPanel } from "./pages/sessions";
import { TerminalView } from "./pages/terminal";
import { Empty } from "./parts";
import { useBack } from "./Shell";
import { headMeta, isTerminal, openLine, rowAgent, rowMachine } from "./session-list";
import { sessionPath, TermTag } from "./SessionList";
import { copyOpen } from "./cli";
import type { Row } from "./work";
import { KEEP_MS, LANDSCAPE, termOf, viewOf, type View } from "./workspace-view";

function useMedia(q: string) {
  const [on, setOn] = useState(() => matchMedia(q).matches);
  useEffect(() => { const m = matchMedia(q); const f = () => setOn(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, [q]);
  return on;
}

// the worker a session's record is read by: its live window's; on the new road a
// parked one has none, and is read (and woken) by the identity the hub names
const workerOf = (r: Row) => r.live?.id || (r.origin ? r.board?.worker_id || r.task?.worker_id || r.ended?.wid || "" : "");

export function Workspace({ r }: { r: Row }) {
  const [params, setParams] = useSearchParams();
  const go = useNavigate();
  const view = viewOf(params.get("view"));
  // the backup terminal and back is not a step: Back leaves the session, to the list
  const setView = (v: View) => setParams((p) => { if (v === "term") p.set("view", v); else p.delete("view"); return p; }, { replace: true });
  const term = termOf(r);
  const side = useMedia(LANDSCAPE);
  const full = side && view === "term";
  const phone = useMedia("(max-width: 767px)");
  const [details, setDetails] = useState(false);
  const [tools, setTools] = useState<HTMLElement | null>(null);
  const [head, setHead] = useState<Head>({ sync: "" });
  const onHead = useCallback((h: Head) => setHead((o) => (o.sync === h.sync && o.busy === h.busy ? o : h)), []);
  // the terminal is mounted once looked at, and kept KEEP_MS after it is left
  const [termOn, setTermOn] = useState(view === "term");
  useEffect(() => {
    if (view === "term") { setTermOn(true); return; }
    if (!termOn) return;
    const t = setTimeout(() => setTermOn(false), KEEP_MS);
    return () => clearTimeout(t);
  }, [view, termOn]);
  const [chatOn, setChatOn] = useState(view === "chat");
  useEffect(() => { if (view === "chat") setChatOn(true); }, [view]);
  const back = useBack();
  const agent = rowAgent(r);
  const open = openLine(r);
  const canOpen = !!(r.live || r.board?.worker_id) && r.group !== "gone";

  return (
    <div data-workspace={view} data-full={full ? "" : undefined}
      className={cn("bg-background flex flex-col", full ? "fixed inset-0 z-40 ps-[env(safe-area-inset-left)] pe-[env(safe-area-inset-right)]" : "h-full min-h-0")}>
      <header className={cn("border-border/70 flex shrink-0 items-center gap-2 border-b", full ? "px-2 py-1" : cn("px-3 pb-2 md:px-4 md:pt-2", viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]"))}>
        <Button variant="ghost" size="icon" className={cn("shrink-0", full ? "size-8" : "-ms-2 size-11 md:hidden")} aria-label={tr("返回", "Back")} onClick={back}><ArrowLeft /></Button>
        <div className="min-w-0 flex-1">
          <h1 className="flex min-w-0 items-baseline gap-1.5 text-[15px] leading-tight font-semibold" title={r.title}>
            <span className="truncate">{r.title || r.code}</span>
            <TermTag r={r} />
            <SyncNote sync={head.sync} className="ms-1" />
          </h1>
          {full ? null : <p className="text-muted-foreground truncate text-xs" data-testid="ws-meta">{headMeta(r, head.busy)}</p>}
        </div>
        {view === "term" ? (
          <Button variant="ghost" size={full ? "icon-sm" : "sm"} className={cn("shrink-0", !full && "h-11 min-w-11 md:h-8 md:min-w-0")} aria-label={tr("对话", "Chat")} onClick={() => setView("chat")}>
            <MessageCircle />{full ? null : <span className="hidden sm:inline">{tr("对话", "Chat")}</span>}
          </Button>
        ) : null}
        {/* the terminal's own tools — Fleet 菜单 · 打开 Shell · 配色 / 字号 — land here while it shows */}
        <div ref={setTools} className={cn("flex items-center gap-2 empty:hidden", !full && "max-md:[&_button]:size-11")} data-testid="ws-tools" />
        <Button variant="outline" size={full ? "icon-sm" : "sm"} className={cn("shrink-0", !full && "h-11 min-w-11 md:h-8 md:min-w-0")} aria-label={tr("详情", "Details")} onClick={() => setDetails(true)}>
          <Info className="md:hidden" />{full ? null : <span className="hidden md:inline">{tr("详情", "Details")}</span>}
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" size="icon" className={cn("shrink-0", full ? "size-8" : "size-11 md:size-8")} aria-label={tr("更多", "More")} data-testid="ws-more">
              <MoreHorizontal />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-56">
            {canOpen ? <DropdownMenuItem onSelect={() => void copyOpen(open)} data-testid="ws-copy-open">
              <TerminalSquare />{tr(`在终端里打开 · 复制 ${open}`, `Open in terminal · copy ${open}`)}
            </DropdownMenuItem> : null}
            <DropdownMenuItem onSelect={() => setDetails(true)}><Info />{tr("详情", "Details")}</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </header>
      <div className="relative min-h-0 flex-1">
        {chatOn ? <div hidden={view !== "chat"} className="h-full">
          <ChatThread source={{ kind: "session", machine: rowMachine(r), key: r.live?.key || r.ended?.key || "", agent, worker: workerOf(r),
            ...(isTerminal(r) && canOpen ? { open } : {}) }}
            last={r.line} onHead={onHead} />
        </div> : null}
        {termOn && term.kind === "live"
          ? <TerminalView key={term.worker} worker={term.worker} name={r.title} toolsInto={tools} compact={full} icons={full || phone} hidden={view !== "term"} />
          : null}
        {view === "term" && term.kind === "opening" ? <p role="status" data-testid="term-opening"
          className="text-muted-foreground flex items-center gap-2 p-4 text-sm"><Loader className="size-4 animate-spin" aria-hidden />
          {tr("会话正在开，开好就进入它的终端。", "The session is opening; its terminal opens once it is up.")}</p> : null}
        {view === "term" && term.kind === "ended" ? <div className="p-4"><Empty icon={<TerminalSquare />}
          title={tr("这个会话已结束", "This session has ended")}
          body={tr("它的终端已经关了。详情里可以接回它。", "Its terminal is closed. You can bring it back from Details.")}
          action={<Button size="sm" variant="outline" onClick={() => setDetails(true)}>{tr("详情", "Details")}</Button>} /></div> : null}
      </div>
      <Sheet open={details} onOpenChange={setDetails}>
        <SheetContent side="right" className="w-full gap-0 overflow-y-auto sm:max-w-xl">
          {/* the card names the session itself; the drawer's own title is for a screen reader */}
          <SheetHeader className="sr-only">
            <SheetTitle>{r.title}</SheetTitle>
            <SheetDescription>{headMeta(r)}</SheetDescription>
          </SheetHeader>
          <div className="px-5 pt-5 pb-[calc(env(safe-area-inset-bottom)+1.5rem)]">
            <RowPanel r={r} cli onOpen={(k) => { setDetails(false); go(sessionPath(k)); }}
              onTerminal={term.kind === "live" ? () => { setDetails(false); setView("term"); } : undefined} />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
