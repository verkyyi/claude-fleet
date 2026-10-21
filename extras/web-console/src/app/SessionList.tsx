// SessionList.tsx — the session list (GR5E C2): the computer's left column and
// the phone's first screen. One row per session — a status glyph and its title,
// nothing else: ⌘P's top-level entries in ⌘P's order (the hub's board, A4G2,
// read once through work-rows.tsx), no group headings or counts, an EPIC only
// as its parent row, the put-away ones folded under 「已结束的会话」 at the foot,
// and the web conversation pinned as the first row. The rest — code · machine ·
// agent · where it runs · how long — shows on hover (computer, a Tooltip) or a
// long-press (phone, a Sheet with 对话 / 终端). The head: the mark · the limit ·
// a search icon (a box only once tapped; it finds a code, a title, a machine) ·
// 新建 (/app/new, GR5E C3). No filter, nothing pinned. A row opens /app/s/<ref>.
// Stock shadcn/ui.
import { createContext, useContext, useEffect, useRef, useState, type FC, type PointerEvent, type ReactNode } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import {
  ChevronDown, ChevronRight, CircleAlert, CircleCheck, CircleDot, CircleX, Clock, GitPullRequest, Loader,
  MessageCircle, Plus, Search, TerminalSquare, X, type LucideIcon,
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
import { listItem, listRows, rowMeta, rowRef, searchRows } from "./session-list";
import { useWorkRows } from "./work-rows";
import type { Glyph, Row, Tone, WhyTone } from "./work";

const Spin: FC<{ className?: string }> = ({ className }) => <Loader className={cn("animate-spin [animation-duration:2.4s]", className)} />;
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

export const SearchButton: FC<{ className?: string }> = ({ className }) => {
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
export const NewButton: FC<{ className?: string }> = ({ className }) => {
  const go = useNavigate();
  const { pathname } = useLocation();
  return (
    <Button variant="ghost" size="icon" className={cn("size-8", pathname === NEW_PATH && "text-clay", className)} disabled={!!viewAs}
      aria-label={tr("新建会话", "New session")} title={tr("新建会话", "New session")} onClick={() => go(NEW_PATH)}>
      <Plus />
    </Button>
  );
};

// The phone's 新建, at the bottom right above the home bar.
export const NewFab: FC = () => {
  const go = useNavigate();
  return (
    <Button size="lg" disabled={!!viewAs} onClick={() => go(NEW_PATH)}
      className="fixed end-4 bottom-[calc(env(safe-area-inset-bottom)+1rem)] z-20 h-12 rounded-full px-5 text-base shadow-lg">
      <Plus />{tr("新建", "New")}
    </Button>
  );
};

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

const RowGlyph: FC<{ r: Row }> = ({ r }) => {
  const Icon = GLYPH[r.glyph];
  return <Icon className={cn("size-4 shrink-0", TONE[r.tone])} aria-hidden />;
};

// What a hover and a long-press show: the title, the one detail line, its last word.
const RowDetail: FC<{ r: Row }> = ({ r }) => (
  <>
    <span className="block text-sm font-semibold break-words">{r.title}</span>
    <span className="block opacity-80">{rowMeta(r)}</span>
    <RowWhy r={r} className="mt-1 text-[13px]" />
    {r.line ? <span className="mt-0.5 block line-clamp-3">{r.quote ? tr(`「${r.line}」`, `“${r.line}”`) : r.line}</span> : null}
  </>
);

type Variant = "side" | "page";
const rowCls = "text-foreground hover:text-foreground flex items-center gap-3 no-underline";

const SessionRow: FC<{ r: Row; variant: Variant; active: boolean; onPress: (r: Row) => void }> = ({ r, variant, active, onPress }) => {
  const { seen, markSeen } = useWorkRows();
  const it = listItem(r, seen);
  const press = useLongPress(() => onPress(r));
  const body = (
    <Link to={sessionPath(r)} onClick={() => markSeen(r)} data-row={it.ref} aria-current={active ? "page" : undefined}
      className={cn(rowCls, variant === "page" && "hover:bg-muted/60 aria-[current]:bg-muted h-11 px-4 [-webkit-touch-callout:none] select-none")} {...(variant === "page" ? press : {})}>
      <RowGlyph r={r} />
      <span className={cn("min-w-0 flex-1 truncate", it.bold ? "font-semibold" : "font-normal")}>{it.title}</span>
    </Link>
  );
  if (variant === "page") return <li>{body}</li>;
  return (
    <SidebarMenuItem>
      <Tooltip delayDuration={200}>
        <TooltipTrigger asChild>
          <SidebarMenuButton asChild isActive={active} className="data-[active=true]:font-[inherit]">{body}</SidebarMenuButton>
        </TooltipTrigger>
        <TooltipContent side="right" align="start" className="max-w-80 text-xs leading-relaxed"><RowDetail r={r} /></TooltipContent>
      </Tooltip>
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

// The long-press sheet: the same detail, and the two ways in.
const PressSheet: FC<{ r: Row | null; onClose: () => void }> = ({ r, onClose }) => {
  const { markSeen } = useWorkRows();
  return (
    <Sheet open={!!r} onOpenChange={(o) => { if (!o) onClose(); }}>
      <SheetContent side="bottom" className="gap-0 rounded-t-2xl pb-[calc(env(safe-area-inset-bottom)+1rem)]">
        {r ? <>
          <SheetHeader className="gap-1 px-5 pt-5 pb-3">
            <SheetTitle className="text-base leading-snug break-words">{r.title}</SheetTitle>
            <SheetDescription>{rowMeta(r)}</SheetDescription>
            <RowWhy r={r} className="text-sm" />
            {r.line ? <p className="text-foreground text-sm break-words">{r.quote ? tr(`「${r.line}」`, `“${r.line}”`) : r.line}</p> : null}
          </SheetHeader>
          <div className="grid grid-cols-2 gap-3 px-5">
            <Button asChild variant="outline" className="text-foreground no-underline"><Link to={sessionPath(r, "chat")} onClick={() => { markSeen(r); onClose(); }}><MessageCircle />{tr("对话", "Chat")}</Link></Button>
            {r.live ? <Button asChild variant="outline" className="text-foreground no-underline"><Link to={sessionPath(r, "term")} onClick={() => { markSeen(r); onClose(); }}><TerminalSquare />{tr("终端", "Terminal")}</Link></Button>
              : <Button variant="outline" disabled><TerminalSquare />{tr("终端", "Terminal")}</Button>}
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
  const { rows, failed, reload } = useWorkRows();
  const { q } = useListUi();
  const { ref, pathname } = useOpenRef();
  const [goneOpen, setGoneOpen] = useState(false);
  const [pressed, setPressed] = useState<Row | null>(null);
  if (rows === null) return failed ? <div className="px-3"><Failed what={tr("会话", "your sessions")} onRetry={reload} /></div> : <div className="px-3"><Loading /></div>;
  const webActive = pathname === WEB_CHAT_PATH || (!!chatHome && pathname === "/");
  const row = (r: Row) => <SessionRow key={r.id} r={r} variant={variant} active={ref === rowRef(r)} onPress={setPressed} />;
  const List = variant === "side" ? SidebarMenu : "ul";
  const searching = !!q.trim();
  const web = <WebChatRow key="web" variant={variant} active={webActive} />;
  let body: ReactNode;
  if (searching) {
    const found = searchRows(rows, q);
    const webHit = `${tr("我的对话", "My chat")} chat`.toLowerCase().includes(q.trim().toLowerCase());
    body = found.length || webHit ? <List>{webHit ? web : null}{found.map(row)}</List>
      : <p className="text-muted-foreground px-4 py-3 text-sm">{tr("没有找到", "Nothing found")}</p>;
  } else {
    const { open, gone } = listRows(rows);
    // the web conversation is pinned on top, whatever the sessions' state (C25B)
    body = (
      <>
        <List>{web}{open.map(row)}</List>
        {gone.length ? <>
          <button type="button" onClick={() => setGoneOpen(!goneOpen)} aria-expanded={goneOpen}
            className={cn("text-muted-foreground hover:text-foreground flex w-full items-center gap-3 text-sm",
              variant === "page" ? "h-11 px-4" : "h-8 px-2 group-data-[collapsible=icon]:justify-center")}>
            {goneOpen ? <ChevronDown className="size-4 shrink-0" /> : <ChevronRight className="size-4 shrink-0" />}
            <span className={cn(variant === "side" && "group-data-[collapsible=icon]:hidden")}>{tr("已结束的会话", "Ended sessions")}</span>
          </button>
          {goneOpen ? <List>{gone.map(row)}</List> : null}
        </> : null}
      </>
    );
  }
  return (
    <div data-session-list={variant}>
      <SearchBox />
      {body}
      {variant === "page" ? <PressSheet r={pressed} onClose={() => setPressed(null)} /> : null}
    </div>
  );
};

// The phone's first screen: the list, and 新建 at the bottom right.
export const SessionListPage: FC = () => (
  <div className="pb-[calc(env(safe-area-inset-bottom)+5rem)]">
    <SessionRows variant="page" />
    <NewFab />
  </div>
);
