import { ArchiveButton } from "./ArchiveButton";
import { ScheduleGroup, NewScheduleButton } from "./schedules";
// Task list: PIN, ordinary tasks, then folded earlier sessions. One status slot.
import { createContext, useContext, useEffect, useRef, useState, type FC, type PointerEvent, type ReactNode } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import {
  ChevronDown, ChevronRight, CircleAlert, CircleCheck, CircleDot, CircleX, Clock, GitPullRequest, Loader,
  MessageCircle, Plus, Repeat2, Search, X, type LucideIcon,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { Failed, Loading } from "./parts";
import { compactRows, isTerminal, listItem, listRows, listStatus, listStatusLabel, needsAttention, ROW_SOURCES, rowMeta, rowRef, searchRows, sourceLabel, type CompactGroups, type RowSource } from "./session-list";
import { useUnified } from "./chat/home";
import { useWorkRows } from "./work-rows";
import type { Glyph, Row, Tone, WhyTone } from "./work";

const Spin: FC<{ className?: string; label?: boolean }> = ({ className, label }) => <Loader className={cn("animate-spin motion-reduce:animate-none [animation-duration:2.4s]", className)} />;
export const GLYPH: Record<Glyph, LucideIcon | FC<{ className?: string }>> = {
  ask: CircleAlert, fail: CircleX, work: Spin, pr: GitPullRequest, done: CircleCheck, idle: CircleDot, wait: Clock,
};
export const TONE: Record<Tone, string> = {
  ask: "text-clay", fail: "text-destructive", ok: "text-ok", muted: "text-muted-foreground",
};
// 「为什么还没收」's colour (E101): grey says what holds it, orange it waits on you,
// red its error stopped it
const WHY_TONE: Record<WhyTone, string> = { grey: "", orange: "text-clay font-medium", red: "text-destructive font-medium" };
export const RowWhy: FC<{ r: Row; className?: string }> = ({ r, className }) =>
  r.why ? <span data-testid="row-why" className={cn("block", WHY_TONE[r.whyTone || "grey"], className)}>{tr(r.why[0], r.why[1])}</span> : null;

export const sessionPath = (r: Row, view?: "chat" | "term") => `/s/${encodeURIComponent(rowRef(r))}${view ? `?view=${view}` : ""}`;
// the web conversation, one row of the list (its own page until C3 makes it a session)
export const WEB_CHAT_PATH = "/chat";

// The list's search, shared by the head that draws its button (the left
// column's, the phone's top bar) and the list that draws the box.
type ListUi = { searching: boolean; setSearching: (on: boolean) => void; q: string; setQ: (q: string) => void };
const UiCtx = createContext<ListUi>({ searching: false, setSearching: () => {}, q: "", setQ: () => {} });
const useListUi = () => useContext(UiCtx);

export const ListUiProvider: FC<{ children: ReactNode }> = ({ children }) => {
  const [searching, setSearching] = useState(false);
  const [q, setQ] = useState("");
  return (
    <UiCtx.Provider value={{ searching, setSearching: (on) => { setSearching(on); if (!on) setQ(""); }, q, setQ }}>
      {children}
    </UiCtx.Provider>
  );
};

export const SearchButton: FC<{ className?: string; label?: boolean }> = ({ className, label }) => {
  const { searching, setSearching } = useListUi();
  return (
    <Button variant="ghost" size="icon" className={cn("size-8", searching && "text-clay", className)} aria-pressed={searching}
      aria-label={tr("搜索会话", "Search sessions")} title={tr("搜索会话", "Search sessions")} onClick={() => setSearching(!searching)}>
      <Search />
    </Button>
  );
};

// 新建 opens the new-session screen (GR5E C3)
export const NEW_PATH = "/new";
export const NewButton: FC<{ className?: string; label?: boolean }> = ({ className, label }) => {
  const go = useNavigate();
  const { pathname } = useLocation();
  return (
    <Button variant={label ? "default" : "ghost"} size={label ? "sm" : "icon"} className={cn(!label && "size-8", pathname === NEW_PATH && "text-clay", className)} disabled={!!viewAs}
      aria-label={tr("新会话", "New session")} title={tr("新会话", "New session")} onClick={() => go(NEW_PATH)}>
      <Plus />{label && tr("新建会话", "New session")}
    </Button>
  );
};

// Both creation paths stay within reach above the phone's home bar.
export const NewFab: FC = () => <div className="fixed inset-x-0 bottom-0 z-20 flex items-center justify-center gap-2 border-t bg-background p-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]"><NewButton label className="flex-1" /><NewScheduleButton /></div>;

const SearchBox: FC = () => {
  const { searching, setSearching, q, setQ } = useListUi();
  if (!searching) return null;
  return (
    <div className="relative px-3 pt-1 pb-2">
      <Search className="text-muted-foreground pointer-events-none absolute start-5.5 top-1/2 size-4 -translate-y-[60%]" aria-hidden />
      <Input autoFocus value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => { if (e.key === "Escape") setSearching(false); }}
        placeholder={tr("搜编号、标题、机器", "Code, title or machine")} aria-label={tr("搜编号、标题、机器", "Search by code, title or machine")}
        className="h-9 ps-8 pe-8" autoComplete="off" spellCheck={false} enterKeyHint="search" />
      <button type="button" onClick={() => setSearching(false)} aria-label={tr("关闭搜索", "Close search")}
        className="text-muted-foreground hover:text-foreground absolute end-5 top-1/2 -translate-y-[60%]"><X className="size-4" /></button>
    </div>
  );
};

// A long-press (touch only): `on` after 300 ms held still; the tap that ends it
// opens nothing, and the system's own menu stays away.
function useLongPress(on: () => void, ms = 300) {
  const timer = useRef(0);
  const fired = useRef(false);
  const at = useRef({ x: 0, y: 0 });
  const stop = () => clearTimeout(timer.current);
  useEffect(() => stop, []);
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.pointerType === "mouse") return;
      fired.current = false;
      at.current = { x: e.clientX, y: e.clientY };
      stop();
      timer.current = window.setTimeout(() => { fired.current = true; navigator.vibrate?.(8); on(); }, ms);
    },
    onPointerMove: (e: PointerEvent) => { if (Math.abs(e.clientX - at.current.x) + Math.abs(e.clientY - at.current.y) > 8) stop(); },
    onPointerUp: stop, onPointerCancel: stop, onPointerLeave: stop,
    onClickCapture: (e: { preventDefault: () => void; stopPropagation: () => void }) => {
      if (fired.current) { e.preventDefault(); e.stopPropagation(); fired.current = false; }
    },
    onContextMenu: (e: { preventDefault: () => void }) => e.preventDefault(),
  };
}

// Reserve the same slot for quiet rows; unread replies only affect title weight.
const RowGlyph: FC<{ r: Row }> = ({ r }) => {
  const { kind } = listStatus(r);
  const Icon = kind === "ask" ? CircleAlert : kind === "pending" ? Clock : kind === "work" ? Spin : kind === "loop" ? Repeat2 : null;
  return <span data-status-slot className="flex size-4 shrink-0 items-center justify-center" aria-hidden>
    {Icon ? <Icon className={cn("size-4", kind === "ask" ? "text-clay" : "text-muted-foreground")} /> : null}
  </span>;
};

// >_ after a terminal's session's title (会话合一 Y01K)
export const TermTag: FC<{ r: Row; className?: string }> = ({ r, className }) =>
  isTerminal(r) ? <span className={cn("text-muted-foreground shrink-0 font-mono text-[11px] font-normal", className)} aria-label={tr("终端会话", "terminal session")} title={tr("终端会话", "Terminal session")}>&gt;_</span> : null;

// What a hover and a long-press show: the title, the one detail line, its last word.
const RowDetail: FC<{ r: Row }> = ({ r }) => {
  const { machines } = useWorkRows();
  return <>
    <span className="block text-sm font-semibold break-words">{r.title}</span>
    <span className="block opacity-80">{rowMeta(r, Date.now(), machines)}</span>
    {listStatusLabel(r) ? <span className="block">{listStatusLabel(r)}</span> : null}
    <RowWhy r={r} className="mt-1 text-[13px]" />
    {r.line ? <span className="mt-0.5 block line-clamp-3">{r.quote ? tr(`「${r.line}」`, `“${r.line}”`) : r.line}</span> : null}
  </>;
};

type Variant = "side" | "page";
const rowCls = "text-foreground hover:text-foreground flex items-center gap-3 no-underline";

const SessionRow: FC<{ r: Row; variant: Variant; active: boolean; onPress: (r: Row) => void }> = ({ r, variant, active, onPress }) => {
  const { seen, markSeen, replied } = useWorkRows();
  const it = listItem(r, seen);
  const press = useLongPress(() => onPress(r));
  const isNew = !!replied[r.id] && !active;
  const status = listStatusLabel(r);
  const body = (
    <Link to={sessionPath(r)} onClick={() => markSeen(r)} data-row={it.ref} aria-label={[it.title, status].filter(Boolean).join(" · ")} data-replied={isNew ? "" : undefined} aria-current={active ? "page" : undefined}
      className={cn(rowCls, listStatus(r).unknown && "opacity-60", variant === "page" && "hover:bg-muted/60 aria-[current]:bg-muted h-11 px-4 [-webkit-touch-callout:none] select-none")} {...(variant === "page" ? press : {})}>
      <RowGlyph r={r} />
      <span className={cn("flex min-w-0 flex-1 items-baseline gap-1.5", it.bold ? "font-semibold" : "font-normal")}>
        <span className="min-w-0 truncate">{r.board?.schedule_id && <span className="mr-1 rounded bg-clay/10 px-0.5" aria-label={tr("定时运行", "Scheduled run")}>⏰</span>}{it.title}</span>
      </span>
    </Link>
  );
  if (variant === "page") return <li className="flex items-center"><div className="min-w-0 flex-1">{body}</div><ArchiveButton row={r} /></li>;
  return (
    <SidebarMenuItem className="flex items-center">
      <div className="min-w-0 flex-1"><Tooltip delayDuration={200}>
        <TooltipTrigger asChild>
          <SidebarMenuButton asChild isActive={active} className="data-[active=true]:font-[inherit]">{body}</SidebarMenuButton>
        </TooltipTrigger>
        <TooltipContent side="right" align="start" className="max-w-80 text-xs leading-relaxed"><RowDetail r={r} /></TooltipContent>
      </Tooltip></div><ArchiveButton row={r} />
    </SidebarMenuItem>
  );
};

const WebChatRow: FC<{ variant: Variant; active: boolean }> = ({ variant, active }) => {
  const title = tr("我的对话", "My chat");
  const body = (
    <Link to={WEB_CHAT_PATH} data-row="web" aria-current={active ? "page" : undefined}
      className={cn(rowCls, variant === "page" && "hover:bg-muted/60 aria-[current]:bg-muted h-11 px-4")}>
      <MessageCircle className="text-muted-foreground size-4 shrink-0" aria-hidden />
      <span className="min-w-0 flex-1 truncate">{title}</span>
    </Link>
  );
  if (variant === "page") return <li>{body}</li>;
  return (
    <SidebarMenuItem>
      <SidebarMenuButton asChild isActive={active} tooltip={title}>{body}</SidebarMenuButton>
    </SidebarMenuItem>
  );
};

// The long-press sheet: the same detail and conversation entry.
const PressSheet: FC<{ r: Row | null; onClose: () => void }> = ({ r, onClose }) => {
  const { markSeen, machines } = useWorkRows();
  return (
    <Sheet open={!!r} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="bottom" className="gap-0 rounded-t-2xl pb-[calc(env(safe-area-inset-bottom)+1rem)]">
        {r ? <>
          <SheetHeader className="gap-1 px-5 pt-5 pb-3">
            <SheetTitle className="text-base leading-snug break-words">{r.title}</SheetTitle>
            <SheetDescription>{[rowMeta(r, Date.now(), machines), listStatusLabel(r)].filter(Boolean).join(" · ")}</SheetDescription>
            <RowWhy r={r} className="text-sm" />
            {r.line ? <p className="text-foreground text-sm break-words">{r.quote ? tr(`「${r.line}」`, `“${r.line}”`) : r.line}</p> : null}
          </SheetHeader>
          <div className="px-5">
            <Button asChild variant="outline" className="text-foreground w-full no-underline"><Link to={sessionPath(r)} onClick={() => { markSeen(r); onClose(); }}><MessageCircle />{tr("打开", "Open")}</Link></Button>
          </div>
        </> : null}
      </SheetContent>
    </Sheet>
  );
};

// the open session's ref, from /s/<ref>
function useOpenRef() {
  const { pathname } = useLocation();
  const m = pathname.match(/^\/s\/([^/]+)/);
  return { ref: m ? decodeURIComponent(m[1]) : "", pathname };
}

// The list itself. `variant` side = inside the computer's left column (shadcn
// SidebarMenu, folds to its glyphs); page = the phone's whole screen.
export const SessionRows: FC<{ variant: Variant; chatHome?: boolean }> = ({ variant, chatHome }) => {
  const { rows: allRows, board, failed, reload, markSeen } = useWorkRows();
  const [showArchived, setShowArchived] = useState(false);
  const archivedCount = allRows?.filter(r => r.board?.archived).length || 0;
  const rows = allRows?.filter(r => !!r.board?.archived === showArchived) ?? null;
  const { q } = useListUi();
  // 会话合一: the web's old conversation is a session of the list now (「我的对话」),
  // no row of its own — kept only on the old road
  const oldRoad = useUnified() === false;
  const { ref, pathname } = useOpenRef();
  const [goneOpen, setGoneOpen] = useState(false);
  const [sourceOpen, setSourceOpen] = useState<Partial<Record<RowSource, boolean>>>({});
  const [pressed, setPressed] = useState<Row | null>(null);
  const previous = useRef<CompactGroups | undefined>(undefined);
  const [pointing, setPointing] = useState(false);
  const [focused, setFocused] = useState(false);
  const [now, setNow] = useState(Date.now);
  const keyTimer = useRef(0);
  useEffect(() => () => clearTimeout(keyTimer.current), []);
  useEffect(() => { const t = window.setInterval(() => setNow(Date.now()), 60_000); return () => clearInterval(t); }, []);
  if (rows === null) return failed ? <div className="px-3"><Failed what={tr("会话", "your sessions")} onRetry={reload} /></div> : <div className="px-3"><Loading /></div>;
  const grouped = compactRows(rows, { current: ref, preferences: board?.session_list, now, previous: previous.current, interacting: pointing || focused });
  previous.current = grouped;
  const searchGroups = listRows(rows);
  const ordered = [...searchGroups.pin, ...searchGroups.open, ...searchGroups.gone];
  const webActive = pathname === WEB_CHAT_PATH || (!!chatHome && pathname === "/");
  const row = (r: Row) => <SessionRow key={r.id} r={r} variant={variant} active={ref === rowRef(r)} onPress={setPressed} />;
  const List = variant === "side" ? SidebarMenu : "ul";
  const timeline = (items: Row[]) => {
    let previous = "";
    const today = new Date(now).toDateString();
    const yesterdayDate = new Date(now); yesterdayDate.setDate(yesterdayDate.getDate() - 1);
    return items.flatMap(r => {
      const day = new Date(r.at).toDateString();
      const label = day === today ? tr("今天", "Today") : day === yesterdayDate.toDateString() ? tr("昨天", "Yesterday") : new Date(r.at).toLocaleDateString();
      const heading = day !== previous ? <li key={`day-${r.id}`} className="px-4 pt-3 pb-1 text-xs text-muted-foreground group-data-[collapsible=icon]:hidden">{label}</li> : null;
      previous = day;
      return heading ? [heading, row(r)] : [row(r)];
    });
  };
  const searching = !!q.trim();
  const web = <WebChatRow key="web" variant={variant} active={webActive} />;
  let body: ReactNode;
  if (showArchived) {
    const found = searching ? searchRows(ordered, q) : ordered;
    body = found.length ? <List>{timeline(found)}</List> : <p className="text-muted-foreground px-4 py-3 text-sm">{tr("没有已归档会话", "No archived sessions")}</p>;
  } else if (searching) {
    const found = searchRows(ordered, q);
    const webHit = `${tr("我的对话", "My chat")} chat`.toLowerCase().includes(q.trim().toLowerCase());
    body = found.length || (webHit && oldRoad) ? <List>{webHit && oldRoad ? web : null}{found.map(row)}</List>
      : <p className="text-muted-foreground px-4 py-3 text-sm">{tr("没有找到", "Nothing found")}</p>;
  } else {
    const { pin, open, gone, sources } = grouped;
    const runningHidden = gone.filter((r) => listStatus(r).kind === "work").length;
    // A count, not a group (task DDBQ): the rows stay in time order; the count
    // opens the next one that needs the person, after the one open now —
    // a folded source group's included.
    const waiting = [...pin, ...open, ...ROW_SOURCES.flatMap((s) => sources[s])].filter(needsAttention);
    const nextWaiting = waiting[(waiting.findIndex((r) => rowRef(r) === ref) + 1) % (waiting.length || 1)];
    // The old chat entry remains above the task list for older hubs.
    body = (
      <>
        {oldRoad ? <List>{web}</List> : null}
        {nextWaiting ? <Link to={sessionPath(nextWaiting)} onClick={() => markSeen(nextWaiting)} data-testid="attention-next"
          className="text-clay flex min-h-8 w-full items-center gap-2 px-4 text-sm no-underline group-data-[collapsible=icon]:hidden">
          <ChevronRight className="size-4" />{tr("待处理", "Needs attention")} · {waiting.length}
        </Link> : null}
        {pin.length ? <><div className="text-muted-foreground px-4 pt-3 pb-1 text-xs group-data-[collapsible=icon]:hidden">PIN</div><div className="max-h-60 overflow-y-auto"><List>{pin.map(row)}</List></div></> : null}
        <List>{timeline(open)}</List>
        {ROW_SOURCES.map((src) => {
          const items = sources[src];
          if (!items.length) return null;
          // folded unless opened, or it holds the session open now
          const shown = sourceOpen[src] ?? items.some((r) => rowRef(r) === ref);
          const asking = items.filter(needsAttention).length;
          return <div key={src} data-source-group={src}>
            <button type="button" onClick={() => setSourceOpen({ ...sourceOpen, [src]: !shown })} aria-expanded={shown}
              className={cn("text-muted-foreground hover:text-foreground flex w-full items-center gap-3 text-sm",
                variant === "page" ? "h-11 px-4" : "h-8 px-2 group-data-[collapsible=icon]:justify-center")}>
              {shown ? <ChevronDown className="size-4 shrink-0" /> : <ChevronRight className="size-4 shrink-0" />}
              <span className={cn(variant === "side" && "group-data-[collapsible=icon]:hidden")}>{sourceLabel(src)}<span className="font-mono"> · {items.length}</span>
                {asking ? <span className="text-destructive font-medium">{tr(` · ${asking} 个在问你`, ` · ${asking} asking`)}</span> : null}</span>
            </button>
            {shown ? <List>{items.map(row)}</List> : null}
          </div>;
        })}
        {gone.length ? <>
          <button type="button" onClick={() => setGoneOpen(!goneOpen)} aria-expanded={goneOpen}
            className={cn("text-muted-foreground hover:text-foreground flex w-full items-center gap-3 text-sm",
              variant === "page" ? "h-11 px-4" : "h-8 px-2 group-data-[collapsible=icon]:justify-center")}>
            {goneOpen ? <ChevronDown className="size-4 shrink-0" /> : <ChevronRight className="size-4 shrink-0" />}
            <span className={cn(variant === "side" && "group-data-[collapsible=icon]:hidden")}>{tr("更多会话", "More sessions")}<span className="font-mono"> · {gone.length}</span>{runningHidden ? tr(` · ${runningHidden} 个运行中`, ` · ${runningHidden} running`) : null}</span>
          </button>
          {goneOpen ? <List>{timeline(gone)}</List> : null}
        </> : null}
      </>
    );
  }
  return (
    <div data-session-list={variant} onPointerEnter={() => setPointing(true)} onPointerLeave={() => setPointing(false)}
      onPointerCancel={() => setPointing(false)} onPointerUp={(e) => { if (e.pointerType !== "mouse") setPointing(false); }}
      onKeyDownCapture={() => { setFocused(true); clearTimeout(keyTimer.current); keyTimer.current = window.setTimeout(() => setFocused(false), 1200); }} onBlurCapture={(e) => { if (!e.currentTarget.contains(e.relatedTarget)) setFocused(false); }}>
      <SearchBox />
      <button type="button" aria-pressed={showArchived} onClick={() => { previous.current = undefined; setShowArchived(!showArchived); }} className="text-muted-foreground px-4 py-2 text-sm">{showArchived ? tr("返回会话", "Back to sessions") : tr(`已归档 · ${archivedCount}`, `Archived · ${archivedCount}`)}</button>
      {showArchived ? <p className="text-muted-foreground px-4 pb-2 text-xs">{tr("归档会停止会话并从列表隐藏；还在运行的会先问你。取消归档即可恢复显示。", "Archiving stops a session and hides it; a running one asks first. Unarchive to show it again.")}</p> : null}
      {body}
      {variant === "page" ? <PressSheet r={pressed} onClose={() => setPressed(null)} /> : null}
    </div>
  );
};

// The phone's first screen: the list, and 新建 at the bottom right.
export const SessionListPage: FC = () => (
  <div className="pb-[calc(env(safe-area-inset-bottom)+5rem)]">
    <ScheduleGroup phone />
    <SessionRows variant="page" />
    <NewFab />
  </div>
);
