import { ArchiveButton } from "./ArchiveButton";
import { schedulePath, useCanSchedule, useSchedules } from "./schedules";
// Task list: pinned first, ordinary tasks, then folded earlier sessions, 定时任务 and API. One status slot.
import { createContext, useContext, useEffect, useRef, useState, type FC, type PointerEvent, type ReactNode } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import {
  ChevronDown, ChevronRight, CircleAlert, CircleCheck, CircleDot, CircleX, Clock, GitPullRequest, Loader,
  MessageCircle, Pin, PinOff, Plus, Repeat2, Search, X, type LucideIcon,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem } from "@/components/ui/sidebar";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { toast } from "sonner";
import { useMe } from "@/shared/api";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { pinSession, pinWorker } from "@/shared/sessions";
import { Failed, Loading } from "./parts";
import {
  activityLabel, lastActive, treeAt, sessionTree, archivedRows, compactRows, foldedDup, isTerminal, listItem, listStatus, listStatusLabel, members, ROW_SOURCES, rowMeta, rowRef, searchRows,
  rowSource, rowsSignal, scheduleLines, signalOf, sourceLabel, treeContext, treeLines, urgentOf, withKids,
  type CompactGroups, type GroupSource, type ScheduleLine, type Signal, type TreeLine,
} from "./session-list";
import { useUnified } from "./chat/home";
import { useWorkRows } from "./work-rows";
import type { Glyph, Row, Tone, WhyTone } from "./work";

// working is a still glyph: nothing in a list spins or pulses
export const GLYPH: Record<Glyph, LucideIcon | FC<{ className?: string }>> = {
  ask: CircleAlert, fail: CircleX, work: Loader, pr: GitPullRequest, done: CircleCheck, idle: CircleDot, wait: Clock,
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

// 新建 opens the new-session screen (GR5E C3). A split button (task PV5W): its
// main part that, its ⌄ a menu — 新会话 · 新建定时任务 (the schedule form, the
// road the separate ⏰ button was).
export const NEW_PATH = "/new";
export const NewButton: FC<{ className?: string; label?: boolean }> = ({ className, label }) => {
  const go = useNavigate();
  const { pathname } = useLocation();
  const canSchedule = useCanSchedule();
  const main = (
    <Button variant={label ? "default" : "ghost"} size={label ? "sm" : "icon"} className={cn(!label && "size-8", label && "flex-1 rounded-e-none", pathname === NEW_PATH && "text-clay")} disabled={!!viewAs}
      aria-label={tr("新会话", "New session")} title={tr("新会话", "New session")} onClick={() => go(NEW_PATH)}>
      <Plus />{label && tr("新建会话", "New session")}
    </Button>
  );
  if (!label) return main;
  return (
    <div className={cn("flex", className)} data-new-split>
      {main}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button size="sm" className="border-primary-foreground/20 rounded-s-none border-s px-2" disabled={!!viewAs}
            aria-label={tr("更多新建方式", "More ways to start")} title={tr("更多新建方式", "More ways to start")}><ChevronDown /></Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="min-w-44">
          <DropdownMenuItem onSelect={() => go(NEW_PATH)}><Plus />{tr("新会话", "New session")}</DropdownMenuItem>
          <DropdownMenuItem disabled={!canSchedule} onSelect={() => go(schedulePath("new"))}><Clock />{tr("新建定时任务", "New schedule")}</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
};

// The new-session button stays within reach above the phone's home bar.
export const NewFab: FC = () => <div className="fixed inset-x-0 bottom-0 z-20 flex items-center justify-center gap-2 border-t bg-background p-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]"><NewButton label className="flex-1" /></div>;

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
// Still, never animated: working is a glyph, not a motion.
const RowGlyph: FC<{ r: Row }> = ({ r }) => {
  const { kind } = listStatus(r);
  const Icon = kind === "ask" ? CircleAlert : kind === "pending" ? Clock : kind === "work" ? Loader : kind === "loop" ? Repeat2 : null;
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

// Where a row sits in the session tree (子会话挂在发起会话下面): its line, its
// twisty's toggle, whether the list has any tree at all (the twisty's slot is
// kept only then), a search hit's parent title, and — a line standing for
// same-title duplicates — the row whose status it draws and how many it holds.
type TreeProps = { line?: TreeLine; onToggle?: (id: string, open: boolean) => void; treeOn?: boolean;
  context?: string; urgent?: Row; dupes?: number; pinnable?: boolean };
const INDENT = ["", "w-4", "w-8"];
// what a folded line's hidden rows say: asking (clay) over working (green) over nothing
export const SIGNAL: Record<Signal, string> = { ask: "text-clay", work: "text-ok", "": "text-muted-foreground" };

// ▾ open · ▸ folded (clay while something folded under it asks, else green
// while one works); a row with nothing under it keeps the same width so the
// titles line up.
const Twisty: FC<{ line?: TreeLine; onToggle?: (id: string, open: boolean) => void }> = ({ line, onToggle }) => {
  if (!line?.kids) return <span data-twisty-slot className="w-3 shrink-0 group-data-[collapsible=icon]:hidden" aria-hidden />;
  const toggle = (e: { preventDefault: () => void; stopPropagation: () => void }) => { e.preventDefault(); e.stopPropagation(); onToggle?.(line.r.id, !line.open); };
  return <span role="button" tabIndex={0} data-twisty aria-expanded={line.open} aria-label={line.open ? tr("收起子会话", "Collapse") : tr("展开子会话", "Expand")}
    onClick={toggle} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") toggle(e); }} onPointerDown={(e) => e.stopPropagation()}
    className={cn("w-3 shrink-0 cursor-pointer text-center text-xs leading-none group-data-[collapsible=icon]:hidden",
      line.open ? "text-muted-foreground hover:text-foreground" : SIGNAL[line.signal])}>{line.open ? "▾" : "▸"}</span>;
};

// 置顶 (task PV5W): no PIN heading — a pinned row wears a clay pin at its end
// (a click unpins); an unpinned one shows a faint pin on hover that pins it
// (the computer's list). On a phone the pin is only a mark: pinning lives in the
// long-press sheet. A child never wears one.
const usePin = (r: Row) => {
  const { reload } = useWorkRows();
  const { me } = useMe();
  const [busy, setBusy] = useState(false);
  const worker = pinWorker(r);
  const pinned = r.group === "pin";
  const can = !!worker && !busy && !!me && !me.read_only && !me.view_as && !viewAs;
  const set = async (on: boolean) => {
    if (!can) return;
    setBusy(true);
    const why = await pinSession(worker, on);
    setBusy(false);
    if (why) toast.error(on ? tr(`没能置顶：${why}`, `Couldn't pin: ${why}`) : tr(`没能取消置顶：${why}`, `Couldn't unpin: ${why}`));
    else reload();
  };
  return { pinned, can, worker, set };
};
const PinButton: FC<{ r: Row; variant: Variant }> = ({ r, variant }) => {
  const { pinned, can, worker, set } = usePin(r);
  if (variant === "page" || !worker) return pinned ? <Pin data-pinned className="text-clay me-3 size-4 shrink-0" aria-label={tr("已置顶", "Pinned")} /> : null;
  const label = pinned ? tr("已置顶 · 点击取消", "Pinned · click to unpin") : tr("置顶", "Pin");
  return <Button variant="ghost" size="icon" data-pin={pinned ? "on" : "off"} aria-label={label} title={label} disabled={!can} onClick={() => void set(!pinned)}
    className={cn("size-7 shrink-0 group-data-[collapsible=icon]:hidden", pinned ? "text-clay" : "text-muted-foreground/60 opacity-0 group-hover/menu-item:opacity-100 focus-visible:opacity-100")}>
    <Pin className="size-4" />
  </Button>;
};

const ActivityCell: FC<{ at: number; now: number }> = ({ at, now }) =>
  <span data-last-active title={lastActive(at, now)} className={cn("hidden min-[480px]:inline-block w-[5ch] shrink-0 text-right text-xs tabular-nums font-normal group-data-[collapsible=icon]:hidden", at && now - at < 300000 ? "text-foreground" : "text-muted-foreground")}>{activityLabel(at, now)}</span>;

const SessionRow: FC<{ r: Row; now: number; variant: Variant; active: boolean; onPress: (r: Row) => void } & TreeProps> = ({ r, now, variant, active, onPress, line, onToggle, treeOn, context, urgent = r, dupes = 1, pinnable }) => {
  const { seen, markSeen, replied } = useWorkRows();
  const it = listItem(r, seen);
  const press = useLongPress(() => onPress(r));
  const isNew = !!replied[r.id] && !active;
  const status = listStatusLabel(urgent);
  // asking the person: said by colour alone — the glyph and the title in clay
  const asking = listStatus(urgent).kind === "ask";
  const at = treeAt(sessionTree([r]))(r);
  const body = (
    <Link to={sessionPath(r)} onClick={() => markSeen(r)} data-row={it.ref} aria-label={[context, it.title, status, r.board?.archived ? tr("已归档", "Archived") : "", lastActive(at, now)].filter(Boolean).join(" · ")} data-replied={isNew ? "" : undefined} aria-current={active ? "page" : undefined}
      className={cn(rowCls, listStatus(urgent).unknown && "opacity-60", variant === "page" && "hover:bg-muted/60 aria-[current]:bg-muted h-11 px-4 [-webkit-touch-callout:none] select-none")} {...(variant === "page" ? press : {})}>
      {line?.depth ? <span className={cn("shrink-0 group-data-[collapsible=icon]:hidden", INDENT[line.depth])} aria-hidden /> : null}
      <RowGlyph r={urgent} />
      {treeOn ? <Twisty line={line} onToggle={onToggle} /> : null}
      <span className={cn("flex min-w-0 flex-1 items-baseline gap-1.5", it.bold ? "font-semibold" : "font-normal", asking && "text-clay")}>
        <span className="min-w-0 truncate">{context ? <span className="text-muted-foreground font-normal">{context} › </span> : null}{r.board?.schedule_id && <span className="mr-1 rounded bg-clay/10 px-0.5" aria-label={tr("定时运行", "Scheduled run")}>⏰</span>}{it.title}</span>
        {r.board?.archived ? <span data-archived-label className="shrink-0 text-xs font-normal text-muted-foreground">{tr("已归档", "Archived")}</span> : null}
        {dupes > 1 ? <span data-dupes className="text-muted-foreground shrink-0 font-normal">×{dupes}</span> : null}
        {line && !line.open && line.hidden ? <span data-tree-hidden className={cn("shrink-0", line.signal === "ask" ? "text-clay font-medium" : "text-muted-foreground font-normal")}>({line.hidden})</span> : null}
      </span>
      <ActivityCell at={at} now={now} />
    </Link>
  );
  // why it is still open stays in the hover / long-press / detail — under the
  // title only for a parked one: that asks the person
  const why = r.board?.tag === "parked" && r.why ? <RowWhy r={r} className={cn("truncate pb-1 text-xs group-data-[collapsible=icon]:hidden",
    variant === "page" ? treeOn ? "ps-17 pe-4" : "ps-11 pe-4" : treeOn ? "ps-15 pe-2" : "ps-9 pe-2")} /> : null;
  const pin = pinnable ? <PinButton r={r} variant={variant} /> : null;
  if (variant === "page") return <li><div className="flex items-center"><div className="min-w-0 flex-1">{body}</div>{pin}<ArchiveButton row={r} /></div>{why}</li>;
  return (
    <SidebarMenuItem>
      <div className="flex items-center"><div className="min-w-0 flex-1"><Tooltip delayDuration={200}>
        <TooltipTrigger asChild>
          <SidebarMenuButton asChild isActive={active} className="data-[active=true]:font-[inherit]">{body}</SidebarMenuButton>
        </TooltipTrigger>
        <TooltipContent side="right" align="start" className="max-w-80 text-xs leading-relaxed"><RowDetail r={r} /></TooltipContent>
      </Tooltip></div>{pin}<ArchiveButton row={r} /></div>
      {why}
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
const PressPin: FC<{ r: Row; onClose: () => void }> = ({ r, onClose }) => {
  const { pinned, can, worker, set } = usePin(r);
  if (!worker) return null;
  return <Button variant="outline" className={cn("w-full", pinned && "text-clay")} disabled={!can} onClick={() => { void set(!pinned); onClose(); }}>
    {pinned ? <><PinOff />{tr("取消置顶", "Unpin")}</> : <><Pin />{tr("置顶", "Pin")}</>}
  </Button>;
};
const PressSheet: FC<{ r: Row | null; onClose: () => void; pinnable?: (r: Row) => boolean }> = ({ r, onClose, pinnable }) => {
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
          <div className="space-y-2 px-5">
            <Button asChild variant="outline" className="text-foreground w-full no-underline"><Link to={sessionPath(r)} onClick={() => { markSeen(r); onClose(); }}><MessageCircle />{tr("打开", "Open")}</Link></Button>
            {pinnable?.(r) ? <PressPin r={r} onClose={onClose} /> : null}
          </div>
        </> : null}
      </SheetContent>
    </Sheet>
  );
};

// One schedule in 定时任务 · N (task PV5W), drawn like a session row: the dot of
// its most urgent run, its twisty (its runs folded under it, (N) when folded),
// its name — red when its last run failed — and, muted at the end, its last
// result (✓ 13:17 · ✗ 13:17) or 下次 07:10. The row opens the schedule.
const ScheduleLineRow: FC<{ s: ScheduleLine; now: number; variant: Variant; active: boolean; open: boolean; onToggle: (open: boolean) => void }> = ({ s, now, variant, active, open, onToggle }) => {
  const line: TreeLine = { r: s.urgent || ({ id: s.id } as Row), depth: 0, kids: s.runs.length, open, hidden: open ? 0 : s.runs.length, signal: rowsSignal(s.runs) };
  const asking = !!s.urgent && listStatus(s.urgent).kind === "ask";
  const toggle = (e: { preventDefault: () => void; stopPropagation: () => void }) => { e.preventDefault(); e.stopPropagation(); onToggle(!open); };
  const body = (
    <Link to={schedulePath(s.id)} data-schedule-line={s.id} aria-current={active ? "page" : undefined} aria-label={[s.name, s.result].filter(Boolean).join(" · ")}
      className={cn(rowCls, variant === "page" && "hover:bg-muted/60 aria-[current]:bg-muted h-11 px-4")}>
      {s.urgent ? <RowGlyph r={s.urgent} /> : s.failed
        ? <span data-status-slot className="flex size-4 shrink-0 items-center justify-center" aria-hidden><CircleX className="text-destructive size-4" /></span>
        : <span data-status-slot className="size-4 shrink-0" aria-hidden />}
      {s.runs.length ? <span role="button" tabIndex={0} data-twisty aria-expanded={open} aria-label={open ? tr("收起运行", "Collapse runs") : tr("展开运行", "Expand runs")}
        onClick={toggle} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") toggle(e); }} onPointerDown={(e) => e.stopPropagation()}
        className={cn("w-3 shrink-0 cursor-pointer text-center text-xs leading-none group-data-[collapsible=icon]:hidden",
          open ? "text-muted-foreground hover:text-foreground" : SIGNAL[line.signal])}>{open ? "▾" : "▸"}</span>
        : <span data-twisty-slot className="w-3 shrink-0 group-data-[collapsible=icon]:hidden" aria-hidden />}
      <span className={cn("flex min-w-0 flex-1 items-baseline gap-1.5 font-normal", s.failed ? "text-destructive" : asking && "text-clay")}>
        <span className="min-w-0 truncate">{s.name}</span>
        {!open && s.runs.length ? <span data-tree-hidden className={cn("shrink-0", line.signal === "ask" ? "text-clay font-medium" : "text-muted-foreground font-normal")}>({s.runs.length})</span> : null}
      </span>
      <ActivityCell at={Math.max(0, ...s.runs.map(treeAt(sessionTree(s.runs))))} now={now} />
      {s.result ? <span data-schedule-result className={cn("shrink-0 text-xs group-data-[collapsible=icon]:hidden", s.failed ? "text-destructive" : "text-muted-foreground")}>{s.result}</span> : null}
    </Link>
  );
  if (variant === "page") return <li>{body}</li>;
  return <SidebarMenuItem><SidebarMenuButton asChild isActive={active} className="data-[active=true]:font-[inherit]">{body}</SidebarMenuButton></SidebarMenuItem>;
};

// the open session's ref, from /s/<ref>
function useOpenRef() {
  const { pathname } = useLocation();
  const m = pathname.match(/^\/s\/([^/]+)/);
  return { ref: m ? decodeURIComponent(m[1]) : "", pathname };
}

// A twisty the person pressed, per row, kept in this browser: it wins over the
// default (open while something under it works or asks).
const TREE_KEY = "fleet.console.tree";
function readOpened(): Record<string, boolean> {
  try { const v = JSON.parse(localStorage.getItem(TREE_KEY) || "{}"); return v && typeof v === "object" ? v : {}; } catch { return {}; }
}

// The list itself. `variant` side = inside the computer's left column (shadcn
// SidebarMenu, folds to its glyphs); page = the phone's whole screen.
export const SessionRows: FC<{ variant: Variant; chatHome?: boolean }> = ({ variant, chatHome }) => {
  const { rows: allRows, board, failed, reload } = useWorkRows();
  const { rows: schedules } = useSchedules();
  const [showArchived, setShowArchived] = useState(false);
  const archivedCount = allRows?.filter(r => r.board?.archived).length || 0;
  const at = treeAt(sessionTree(allRows || []));
  const activityRows = allRows?.map(r => ({ ...r, board: r.board ? { ...r.board, tree_at: at(r) / 1000 } : undefined })) ?? null;
  const rows = activityRows?.filter(r => !!r.board?.archived === showArchived) ?? null;
  const { q } = useListUi();
  // 会话合一: the web's old conversation is a session of the list now (「我的对话」),
  // no row of its own — kept only on the old road
  const oldRoad = useUnified() === false;
  const { ref, pathname } = useOpenRef();
  const scheduleRef = new URLSearchParams(useLocation().search).get("schedule") || "";
  const [goneOpen, setGoneOpen] = useState(false);
  const [sourceOpen, setSourceOpen] = useState<Partial<Record<GroupSource, boolean>>>({});
  const [opened, setOpened] = useState(readOpened);
  // kept only for rows (and schedules: schedule:<id>) the list still has, so the
  // book does not grow forever
  const toggle = (id: string, open: boolean) => setOpened((o) => {
    const known = new Set([...(allRows || []).map((r) => r.id), ...(schedules || []).map((x) => `schedule:${x.spec.id}`)]);
    const n = Object.fromEntries(Object.entries({ ...o, [id]: open }).filter(([k]) => known.has(k)));
    try { localStorage.setItem(TREE_KEY, JSON.stringify(n)); } catch { /* private mode */ }
    return n;
  });
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
  const webActive = pathname === WEB_CHAT_PATH || (!!chatHome && pathname === "/");
  // the session tree: what a session opened hangs under it; the twisty's slot
  // only once the list has a tree at all
  const { tree } = grouped;
  const treeOn = tree.kids.size > 0;
  const row = (r: Row, x: TreeProps = {}) => <SessionRow key={r.id} r={r} now={now} variant={variant} active={ref === rowRef(r)} onPress={setPressed}
    treeOn={treeOn} onToggle={toggle} {...x} />;
  const lines = (roots: Row[]) => treeLines(roots, tree, opened, ref);
  const flat = (items: Row[]): TreeLine[] => items.map((r) => ({ r, depth: 0, kids: 0, open: false, hidden: 0, signal: "" }));
  // a line standing for same-title duplicates draws the most urgent one's status and ×N
  // a top-level line wears the pin (置顶 · task PV5W); a child never does
  const treeRow = (l: TreeLine) => row(l.r, { line: l, urgent: urgentOf(tree, l.r), dupes: members(tree, l.r).length, pinnable: !l.depth });
  const topLevel = (r: Row) => !tree.up.has(r.id) && rowSource(r) !== "schedule";
  const List = variant === "side" ? SidebarMenu : "ul";
  // one list in activity order, no day headings (task PV5W)
  const timeline = (items: TreeLine[]) => items.map(treeRow);
  const searching = !!q.trim();
  const web = <WebChatRow key="web" variant={variant} active={webActive} />;
  const archiveToggle = <button type="button" aria-pressed={showArchived} data-archive-toggle onClick={() => { previous.current = undefined; setShowArchived(!showArchived); }} className="text-muted-foreground px-4 py-2 text-sm">{showArchived ? tr("返回会话", "Back to sessions") : tr(`已归档 · ${archivedCount}`, `Archived · ${archivedCount}`)}</button>;
  let body: ReactNode;
  if (showArchived && !searching) {
    const archives = archivedRows(rows);
    const found = archives;
    body = <>
      {archiveToggle}
      <p className="text-muted-foreground px-4 pb-2 text-xs">{tr("归档会停止会话并从列表隐藏；还在运行的会先问你。取消归档即可恢复显示。", "Archiving stops a session and hides it; a running one asks first. Unarchive to show it again.")}</p>
      {found.length ? <List>{timeline(flat(found))}</List> : <p className="text-muted-foreground px-4 py-3 text-sm">{tr("没有已归档会话", "No archived sessions")}</p>}
    </>;
  } else if (searching) {
    // a hit nested under another says whose: 父标题 › 子标题 — folded ones and
    // same-title duplicates are found too, each on its own
    const found = searchRows(activityRows || [], q);
    const webHit = `${tr("我的对话", "My chat")} chat`.toLowerCase().includes(q.trim().toLowerCase());
    body = found.length || (webHit && oldRoad) ? <List>{webHit && oldRoad ? web : null}{found.map((r) => row(r, { context: treeContext(tree, r) }))}</List>
      : <p className="text-muted-foreground px-4 py-3 text-sm">{tr("没有找到", "Nothing found")}</p>;
  } else {
    const { pin, open, gone, sources } = grouped;
    const everyRow = (roots: Row[]) => withKids(tree, roots).flatMap((r) => members(tree, r));
    const runningHidden = everyRow(gone).filter((r) => listStatus(r).kind === "work").length;
    // 定时任务 · N: one line per schedule, its runs folded under it (task PV5W)
    const sched = scheduleLines(schedules || [], rows);
    const schedRuns = [...sched.lines.flatMap((l) => l.runs), ...sched.other];
    const schedShown = schedRuns.some((r) => rowRef(r) === ref) || (sourceOpen.schedule ?? true); // open unless folded by hand
    const schedOpen = (id: string) => opened[`schedule:${id}`] ?? schedRuns.some((r) => r.board?.schedule_id === id && rowRef(r) === ref);
    const runLine = (r: Row): TreeLine => ({ r, depth: 1, kids: 0, open: false, hidden: 0, signal: "" });
    const otherLine: ScheduleLine = { id: "", name: tr("其他运行", "Other runs"), runs: sched.other, urgent: undefined, failed: false, result: "" };
    const header = (key: string, label: string, n: number, shown: boolean, signal: Signal, flip: () => void) =>
      <button type="button" onClick={flip} aria-expanded={shown} data-section={key}
        className={cn("text-muted-foreground hover:text-foreground flex w-full items-center gap-3 text-sm",
          variant === "page" ? "h-11 px-4" : "h-8 px-2 group-data-[collapsible=icon]:justify-center")}>
        {shown ? <ChevronDown className={cn("size-4 shrink-0", SIGNAL[signal])} /> : <ChevronRight className={cn("size-4 shrink-0", SIGNAL[signal])} />}
        <span className={cn(variant === "side" && "group-data-[collapsible=icon]:hidden")}>{label}<span className="font-mono"> · {n}</span></span>
      </button>;
    // pinned first, in pin order, no heading (task PV5W) → the list → More →
    // 定时任务 → API → archived. The old chat entry remains above the task list
    // for older hubs.
    body = (
      <>
        {oldRoad ? <List>{web}</List> : null}
        <List>{[...lines(pin), ...lines(open)].map(treeRow)}</List>
        {gone.length ? <>
          <button type="button" onClick={() => setGoneOpen(!goneOpen)} aria-expanded={goneOpen}
            className={cn("text-muted-foreground hover:text-foreground flex w-full items-center gap-3 text-sm",
              variant === "page" ? "h-11 px-4" : "h-8 px-2 group-data-[collapsible=icon]:justify-center")}>
            {goneOpen ? <ChevronDown className="size-4 shrink-0" /> : <ChevronRight className="size-4 shrink-0" />}
            <span className={cn(variant === "side" && "group-data-[collapsible=icon]:hidden")}>{tr("更多会话", "More sessions")}<span className="font-mono"> · {gone.length}</span>{runningHidden ? tr(` · ${runningHidden} 个运行中`, ` · ${runningHidden} running`) : null}</span>
          </button>
          {goneOpen ? <List>{timeline(lines(gone))}</List> : null}
        </> : null}
        {/* a schedule's runs live under their schedule (Y8XY), never in the list above */}
        {sched.lines.length || sched.other.length ? <div data-source-group="schedule">
          {header("schedule", tr("定时任务", "Schedules"), sched.lines.length, schedShown, rowsSignal(schedRuns), () => setSourceOpen({ ...sourceOpen, schedule: !schedShown }))}
          {schedShown ? <List>{[...sched.lines, ...(sched.other.length ? [otherLine] : [])].flatMap((l) => {
            const key = l.id || "other";
            const open = schedOpen(key);
            return [<ScheduleLineRow now={now} key={`schedule-${key}`} s={l} variant={variant} active={!!l.id && scheduleRef === l.id} open={open}
              onToggle={(o) => toggle(`schedule:${key}`, o)} />, ...(open ? l.runs.map((r) => row(r, { line: runLine(r) })) : [])];
          })}</List> : null}
        </div> : null}
        {ROW_SOURCES.filter((src) => src !== "schedule").map((src) => {
          const items = sources[src];
          if (!items.length) return null;
          // folded unless opened, or it holds the session open now; its chevron
          // says what is inside by colour alone, as a folded tree's ▸ does
          const shown = sourceOpen[src] ?? withKids(tree, items).some((r) => rowRef(r) === ref);
          return <div key={src} data-source-group={src}>
            {header(src, sourceLabel(src), items.length, shown, signalOf(tree, withKids(tree, items)), () => setSourceOpen({ ...sourceOpen, [src]: !shown }))}
            {shown ? <List>{lines(items).map(treeRow)}</List> : null}
          </div>;
        })}
        {archiveToggle}
      </>
    );
  }
  return (
    <div data-session-list={variant} onPointerEnter={() => setPointing(true)} onPointerLeave={() => setPointing(false)}
      onPointerCancel={() => setPointing(false)} onPointerUp={(e) => { if (e.pointerType !== "mouse") setPointing(false); }}
      onKeyDownCapture={() => { setFocused(true); clearTimeout(keyTimer.current); keyTimer.current = window.setTimeout(() => setFocused(false), 1200); }} onBlurCapture={(e) => { if (!e.currentTarget.contains(e.relatedTarget)) setFocused(false); }}>
      <SearchBox />
      {body}
      {variant === "page" ? <PressSheet r={pressed} onClose={() => setPressed(null)} pinnable={topLevel} /> : null}
    </div>
  );
};

// The phone's first screen: the list (定时任务 under 更多会话), and 新建 at the bottom.
export const SessionListPage: FC = () => (
  <div className="pb-[calc(env(safe-area-inset-bottom)+5rem)]">
    <SessionRows variant="page" />
    <NewFab />
  </div>
);
