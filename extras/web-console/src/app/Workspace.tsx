// Workspace.tsx — one session (GR5E C4), /app/s/<ref>?view=chat|term: its head
// (code · title · where it runs · machine · agent · how long), 「对话 | 终端」 to
// switch in place, and 「详情」 — the card 会话 showed (its words, PR, ways in) —
// in a drawer. Switching keeps the other side: the conversation stays, and a
// terminal left for 对话 stays connected for KEEP_MS. A phone on its side shows
// the terminal on the whole screen under a one-line head; the same element,
// re-fitted, never a reconnect. Stock shadcn/ui only.
import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { ArrowLeft, Info, Loader, MessageCircle, TerminalSquare } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { ChatThread } from "./pages/chat";
import { RowPanel } from "./pages/sessions";
import { TerminalView } from "./pages/terminal";
import { Empty } from "./parts";
import { useBack } from "./Shell";
import { rowAgent, rowMachine, rowMeta } from "./session-list";
import { sessionPath } from "./SessionList";
import type { Row } from "./work";
import { KEEP_MS, LANDSCAPE, termOf, viewOf, type View } from "./workspace-view";

function useMedia(q: string) {
  const [on, setOn] = useState(() => matchMedia(q).matches);
  useEffect(() => { const m = matchMedia(q); const f = () => setOn(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, [q]);
  return on;
}

export function Workspace({ r }: { r: Row }) {
  const [params, setParams] = useSearchParams();
  const go = useNavigate();
  const view = viewOf(params.get("view"));
  // switching is not a step back: Back leaves the session, to the list
  const setView = (v: View) => setParams((p) => { p.set("view", v); return p; }, { replace: true });
  const term = termOf(r);
  const side = useMedia(LANDSCAPE);
  const full = side && view === "term";
  const phone = useMedia("(max-width: 767px)");
  const [details, setDetails] = useState(false);
  const [tools, setTools] = useState<HTMLElement | null>(null);
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

  return (
    <div data-workspace={view} data-full={full ? "" : undefined}
      className={cn("bg-background flex flex-col", full ? "fixed inset-0 z-40 ps-[env(safe-area-inset-left)] pe-[env(safe-area-inset-right)]" : "h-full min-h-0")}>
      <header className={cn("border-border/70 flex shrink-0 gap-2 border-b", full ? "items-center px-2 py-1" : cn("flex-col px-3 pb-2 md:flex-row md:items-center md:px-4 md:pt-2", viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]"))}>
        <div className="flex min-w-0 flex-1 items-center gap-2">
          <Button variant="ghost" size="icon" className={cn("shrink-0", full ? "size-8" : "-ms-2 size-11 md:hidden")} aria-label={tr("返回", "Back")} onClick={back}><ArrowLeft /></Button>
          <div className="min-w-0 flex-1">
            <h1 className="truncate text-[15px] font-semibold leading-tight" title={r.title}>{r.title || r.code}</h1>
            {full ? null : <p className="text-muted-foreground truncate text-xs" data-testid="ws-meta">{rowMeta(r)}</p>}
          </div>
          <Button variant="ghost" size={full ? "icon-sm" : "sm"} className={cn("shrink-0", !full && "h-11 min-w-11 md:h-8 md:min-w-0")} aria-label={tr("详情", "Details")} onClick={() => setDetails(true)}>
            <Info />{full ? null : <span className="hidden sm:inline">{tr("详情", "Details")}</span>}
          </Button>
        </div>
        <div className={cn("flex min-w-0 shrink-0 items-center gap-2", !full && "flex-wrap")}>
          <ToggleGroup type="single" variant="outline" size="sm" value={view} onValueChange={(v) => { if (v) setView(v as View); }} aria-label={tr("看法", "View")}>
            <ToggleGroupItem value="chat" aria-label={tr("对话", "Chat")} className={cn("px-3", !full && "h-11 md:h-8")}><MessageCircle />{full ? null : tr("对话", "Chat")}</ToggleGroupItem>
            <ToggleGroupItem value="term" aria-label={tr("终端", "Terminal")} className={cn("px-3", !full && "h-11 md:h-8")}><TerminalSquare />{full ? null : tr("终端", "Terminal")}</ToggleGroupItem>
          </ToggleGroup>
          {/* the terminal's own tools — Fleet 菜单 · 打开 Shell · 配色 / 字号 — land here */}
          <div ref={setTools} className={cn("flex items-center gap-2 empty:hidden", !full && "max-md:[&_button]:size-11")} data-testid="ws-tools" />
        </div>
      </header>
      <div className="relative min-h-0 flex-1">
        {chatOn ? <div hidden={view !== "chat"} className="h-full">
          <ChatThread source={{ kind: "session", machine: rowMachine(r), key: r.live?.key || r.ended?.key || "", agent }}
            last={r.line} onTerminal={term.kind === "live" ? () => setView("term") : undefined} />
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
            <SheetDescription>{rowMeta(r)}</SheetDescription>
          </SheetHeader>
          <div className="px-5 pt-5 pb-[calc(env(safe-area-inset-bottom)+1.5rem)]">
            <RowPanel r={r} onOpen={(k) => { setDetails(false); go(sessionPath(k)); }}
              onTerminal={term.kind === "live" ? () => { setDetails(false); setView("term"); } : undefined} />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
