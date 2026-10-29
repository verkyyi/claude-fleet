import { SchedulesProvider, ScheduleGroup, NewScheduleButton, useSchedules, schedulePath } from "./schedules";
// Shell.tsx — the member side's frame (EPIC #3923 C3): on a phone (< 768) a
// top bar (the mark, what is left of the person's limit, on the list its search,
// the avatar into 我的); on a computer shadcn's Sidebar — the session list
// (GR5E C2: its head the mark · the limit · search · 新建), the person at its
// foot, whose menu opens 用量 · 设备 · 设置 · 我的 · 管理后台 · 退出. The list is
// the one way in: no page bar on either (用量 · 设备 · 设置 live in 我的 since
// GR5E C1), the phone's first screen is the list itself. On a phone (GR5E C7)
// the top bar is the list's alone: a session and 新建 are whole screens with
// their own head, every other screen a back bar (← · its name · the limit) —
// phone-screen.ts says which; no bottom bar, screens move by the browser's
// history and 返回 goes to the screen before (useBack). A weak network is one
// band under the bars on every screen (NetBar, GR5E C8). Stock shadcn/ui only; a
// page draws inside <main>. On a computer the sidebar folds to its glyph strip
// (shadcn's collapsible="icon"), the choice kept in this browser.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type CSSProperties, type FC, type ReactNode, type Ref } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import { ArrowLeft, ChevronsUpDown, CircleUserRound, Eye, LogOut, ShieldCheck } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent, SidebarHeader,
  SidebarMenu, SidebarMenuButton, SidebarMenuItem, SidebarProvider, SidebarRail, SidebarSeparator,
} from "@/components/ui/sidebar";
import { cn } from "@/lib/utils";
import { BRAND } from "@/shared/brand";
import { Logo } from "@/shared/Logo";
import { Wordmark } from "@/shared/Wordmark";
import { tr } from "@/shared/i18n";
import { Toaster } from "@/components/ui/sonner";
import { isAdmin, useMe, useUsageHead, type Me, type Quota, type Trial } from "@/shared/api";
import { LegacyMigrationNotice } from "./chat/legacy";
import { leaveViewAs, viewAs } from "@/shared/viewAs";
import { backStep, phoneBar } from "./phone-screen";
import { ADMIN_HREF, ME_TABS, meTab } from "./routes";
import { ListUiProvider, NewButton, SearchButton, SessionRows, sessionPath } from "./SessionList";
import { NetBar } from "./NetBar";
import { TrialBar } from "./TrialBar";
import { useWorkRows, WorkRowsProvider } from "./work-rows";
import { toast } from "sonner";
import { clearBrowserCache } from "./chat/local";

// What every page reads: who is signed in, what is left of their limit and
// their trial's (claude-fleet T796) — both bumped after each conversation turn.
type ShellCtx = { me: Me | null; quota: Quota | null; trial: Trial | null; setTrial: (t: Trial) => void; bumpQuota: () => void };
const Ctx = createContext<ShellCtx>({ me: null, quota: null, trial: null, setTrial: () => {}, bumpQuota: () => {} });
export const useShell = () => useContext(Ctx);
// the page's own name, for the phone's back bar
const TitleCtx = createContext<(t: string) => void>(() => {});

// usePage(title): a page names itself — the tab's title, and a phone's back bar.
export function usePage(title: string) {
  const setTitle = useContext(TitleCtx);
  useEffect(() => { document.title = `${title} · ${BRAND}`; setTitle(title); }, [title, setTitle]);
}

// useBack(): 返回 — the screen before, or the list in place when this tab
// opened here (history.back() off the first entry closes a WeChat page).
export function useBack() {
  const go = useNavigate();
  const { key } = useLocation();
  return useCallback(() => { const to = backStep(key); if (to === -1) go(-1); else go(to, { replace: true }); }, [go, key]);
}

export const quotaWords = (q: Quota) =>
  q.over ? tr("额度用完", "Limit reached") : `${tr("剩余", "Left")} ${q.pct}%`;

// The limit capsule: what is left, a link to 我的 · 用量.
const QuotaPill: FC<{ quota: Quota | null }> = ({ quota }) =>
  quota ? (
    <Button asChild size="sm" variant="outline"
      className={cn("relative h-6 rounded-full px-2.5 font-mono text-[11px] no-underline after:absolute after:-inset-x-1 after:-inset-y-2.5 after:content-[''] md:after:hidden",
        quota.over ? "border-clay-line text-clay" : "text-foreground")}>
      <Link to={meTab("usage").path} title={tr("我的用量", "My usage")}>{quotaWords(quota)}</Link>
    </Button>
  ) : null;

const SignOut: FC<{ children?: ReactNode; formRef?: Ref<HTMLFormElement> }> = ({ children, formRef }) => (
  // back to the site's front page after (claude-fleet#3798): to=site, a fixed word
  // the conversation this browser kept goes first (task KSQG), then the form
  <form ref={formRef} method="post" action="/app/logout" onSubmit={(e) => {
    e.preventDefault();
    const f = e.currentTarget;
    void clearBrowserCache().finally(() => f.submit());
  }}>
    <input type="hidden" name="to" value={document.documentElement.lang === "en" ? "site-en" : "site"} />
    {children}
  </form>
);
export { SignOut };

const initial = (name: string) => (name[0] || "·").toUpperCase();

// The person at the sidebar's foot, and their menu: 我的's tabs, 我的 itself,
// 管理后台 for an admin, sign-out.
const PersonMenu: FC = () => {
  const { me, quota } = useShell();
  const go = useNavigate();
  const out = useRef<HTMLFormElement>(null);
  const name = me?.name || me?.login || "";
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton size="lg" tooltip={tr("我的", "Me")} aria-label={tr("我的", "Me")}
              className="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground">
              <Avatar className="size-8"><AvatarFallback className="text-xs">{initial(name)}</AvatarFallback></Avatar>
              <span className="grid min-w-0 flex-1 text-start leading-tight">
                <span className="truncate text-sm font-medium">{name}</span>
                {quota ? <span className="text-muted-foreground truncate font-mono text-[11px]">{quotaWords(quota)}</span> : null}
              </span>
              <ChevronsUpDown className="text-muted-foreground ms-auto size-4" />
            </SidebarMenuButton>
          </DropdownMenuTrigger>
          <DropdownMenuContent side="top" align="start" className="w-(--radix-dropdown-menu-trigger-width) min-w-52">
            <DropdownMenuLabel className="truncate font-normal">
              <span className="block truncate text-sm font-medium">{name}</span>
              {quota ? <span className="text-muted-foreground block font-mono text-[11px]">{quotaWords(quota)}</span> : null}
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            {ME_TABS.filter((t) => t.id !== "account").map((t) => (
              <DropdownMenuItem key={t.id} onSelect={() => go(t.path)}><t.icon />{t.label}</DropdownMenuItem>
            ))}
            <DropdownMenuItem onSelect={() => location.assign("/status")}><ShieldCheck />{tr("服务健康", "Service health")}</DropdownMenuItem>
            <DropdownMenuItem onSelect={() => go(meTab("account").path)}><CircleUserRound />{tr("我的", "Me")}</DropdownMenuItem>
            {me?.studio ? <DropdownMenuItem onSelect={() => go("/studio")}>活页工作台</DropdownMenuItem> : null}
            {isAdmin(me) ? (
              <DropdownMenuItem asChild className="text-clay focus:text-clay [&_svg]:!text-clay">
                <a href={ADMIN_HREF} className="no-underline"><ShieldCheck />{tr("管理后台", "Admin")}</a>
              </DropdownMenuItem>
            ) : null}
            {me?.can_logout ? (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuItem onSelect={() => out.current?.requestSubmit()}><LogOut />{tr("退出登录", "Sign out")}</DropdownMenuItem>
              </>
            ) : null}
          </DropdownMenuContent>
        </DropdownMenu>
        {me?.can_logout ? <SignOut formRef={out} /> : null}
      </SidebarMenuItem>
    </SidebarMenu>
  );
};

const Side: FC = () => (
  <Sidebar collapsible="icon" className="border-sidebar-border">
    <SidebarHeader className="flex-row items-center gap-1 px-3 pt-3 pb-1 group-data-[collapsible=icon]:flex-col group-data-[collapsible=icon]:px-2">
      <Link to="/" className="text-foreground flex min-w-0 items-center gap-2 no-underline" aria-label={BRAND}>
        <Logo className="hidden size-7 shrink-0 group-data-[collapsible=icon]:block" />
        <Wordmark className="h-[15px] shrink-0 group-data-[collapsible=icon]:hidden" />
      </Link>
      <span className="ms-auto flex items-center gap-0.5 group-data-[collapsible=icon]:hidden">
        <QuotaPillOf />
        <SearchButton />
      </span>
    </SidebarHeader>
    <SidebarContent>
      <div className="flex gap-2 px-2 group-data-[collapsible=icon]:hidden"><NewButton label className="flex-1" /><NewScheduleButton /></div>
      <StudioLink />
      <ScheduleGroup />
      <SidebarGroup className="px-1.5">
        <SidebarGroupContent><SessionRows variant="side" chatHome /></SidebarGroupContent>
      </SidebarGroup>
    </SidebarContent>
    <SidebarFooter className="px-3 pb-3">
      <SidebarSeparator className="mx-0" />
      <PersonMenu />
    </SidebarFooter>
    <SidebarRail />
  </Sidebar>
);

const StudioLink: FC = () => useShell().me?.studio ? <Link to="/studio" className="mx-2 rounded-lg px-3 py-2 text-sm font-medium hover:bg-muted">活页工作台</Link> : null;

const QuotaPillOf: FC = () => <QuotaPill quota={useShell().quota} />;

// 只读预览 (claude-fleet#3944): an admin looking through a member's eyes. The
// band sits over every page, phone and computer alike, until they leave; the
// entry refuses every change behind it.
const ViewAsBar: FC = () => {
  const { me } = useShell();
  if (!viewAs || (me && !me.view_as)) return null; // the entry took no view (one's own row)
  const name = me?.view_as?.name || me?.name || "…";
  return (
    <div role="status" aria-live="polite"
      className="bg-primary text-primary-foreground flex flex-none items-center gap-2.5 px-4 pt-[calc(env(safe-area-inset-top)+0.5rem)] pb-2 text-sm md:pt-2">
      <Eye className="size-4 shrink-0" aria-hidden />
      <span className="min-w-0 flex-1 truncate">
        <b className="font-semibold">{tr("只读预览", "Read-only preview")} · {name}</b>
        <span className="hidden opacity-85 sm:inline">{tr("　你看到的就是他的「我的」，这里改不了任何东西", " — exactly what they see; nothing can be changed here")}</span>
      </span>
      <Button size="sm" variant="secondary" className="h-7 shrink-0 rounded-full px-3" onClick={leaveViewAs}>
        {tr("退出预览", "Leave preview")}
      </Button>
    </div>
  );
};

// The phone's bar over a screen (phone-screen.ts): the list's top bar — the
// mark, the limit, search, the avatar into 我的 — or a back bar, or nothing
// over a whole screen with its own head. Every tap target 44px.
const TopBar: FC<{ title: string }> = ({ title }) => {
  const { me, quota } = useShell();
  const { pathname, search } = useLocation();
  const back = useBack();
  const bar = phoneBar(pathname, search);
  if (bar === "none") return null;
  return (
    <header data-phone-bar={bar} className={cn("border-border/70 bg-background/85 sticky top-0 z-20 flex min-h-14 items-center gap-1 border-b ps-2 pe-2 pb-1 backdrop-blur-md md:hidden",
      viewAs ? "pt-1" : "pt-[calc(env(safe-area-inset-top)+0.25rem)]")}>
      {bar === "list" ? (
        <Link to="/" className="text-foreground flex min-h-11 items-center gap-2.5 ps-2 no-underline" aria-label={BRAND}>
          <Wordmark className="h-[17px] shrink-0" />
        </Link>
      ) : (
        <>
          <Button variant="ghost" size="icon" className="size-11 shrink-0" aria-label={tr("返回", "Back")} onClick={back}><ArrowLeft /></Button>
          <h1 className="min-w-0 flex-1 truncate text-[15px] font-semibold">{pathname.startsWith("/me/") ? tr("我的", "Me") : title}</h1>
        </>
      )}
      <span className="ms-auto flex shrink-0 items-center px-1"><QuotaPill quota={quota} /></span>
      {bar === "list" ? <SearchButton className="size-11" /> : null}
      {bar === "list" ? (
        <Link to={meTab("account").path} className="flex size-11 shrink-0 items-center justify-center rounded-full no-underline" aria-label={tr("我的", "Me")} title={tr("我的", "Me")}>
          <Avatar className="size-8"><AvatarFallback className="text-xs">{initial(me?.name || me?.login || "")}</AvatarFallback></Avatar>
        </Link>
      ) : null}
    </header>
  );
};

// the network band (NetBar) — at the very top of a whole screen, which has no
// bar over it, so it clears the notch there
const NetBarOf: FC = () => {
  const { pathname, search } = useLocation();
  return <NetBar top={!viewAs && phoneBar(pathname, search) === "none"} />;
};

// 新回复 (会话合一 Y01K): a session the person is not looking at finished its
// reply — one line on top for 3 s, 「X」答完了 · 去看; the row keeps its dot.
const ReplyToast: FC = () => {
  const { done, markSeen } = useWorkRows();
  const go = useNavigate();
  useEffect(() => {
    if (!done) return;
    const r = done.row;
    const t = r.title.length > 14 ? `${r.title.slice(0, 13)}…` : r.title;
    toast(tr(`「${t}」答完了`, `“${t}” is done`), {
      duration: 3000, id: "reply-done",
      action: { label: tr("去看", "View"), onClick: () => { markSeen(r); go(sessionPath(r)); } },
    });
  }, [done]); // eslint-disable-line react-hooks/exhaustive-deps
  return null;
};

// The sidebar's folded or not, kept in this browser across a reload.
const SIDE_KEY = "fleet.console.sidebar";
function useSideOpen(): [boolean, (o: boolean) => void] {
  const [open, set] = useState(() => { try { return localStorage.getItem(SIDE_KEY) !== "folded"; } catch { return true; } });
  const save = useCallback((o: boolean) => { set(o); try { localStorage.setItem(SIDE_KEY, o ? "open" : "folded"); } catch { /* private mode */ } }, []);
  return [open, save];
}

// One persistent in-app result notice, also available without external delivery.
const ScheduleNotice: FC = () => {
  const { search } = useLocation();
  const { unread } = useSchedules();
  if (!unread.length || new URLSearchParams(search).has("schedule")) return null;
  return <Link role="status" to={schedulePath(unread[0].schedule_id)} className="border-b bg-muted px-4 py-2 text-sm no-underline">
    <span className="font-medium">{tr("定时任务有新结果", "New schedule results")} ({unread.length})</span>
    <span className="ml-2 line-clamp-2 break-words">{(unread[0].summary || unread[0].error).slice(0, 160)}</span>
  </Link>;
};

// AppShell: the frame around every member page. The page fills the space
// between the bars; a page that scrolls scrolls inside <main>.
export const AppShell: FC<{ children: ReactNode; quotaKey: number; bumpQuota: () => void }> = ({ children, quotaKey, bumpQuota }) => {
  const { me } = useMe();
  const studio = useLocation().pathname === "/studio";
  const { quota, trial, setTrial } = useUsageHead(quotaKey);
  const [sideOpen, setSideOpen] = useSideOpen();
  const [title, setTitle] = useState("");
  return (
    <Ctx.Provider value={{ me, quota, trial, setTrial, bumpQuota }}>
     <TitleCtx.Provider value={setTitle}>
     <WorkRowsProvider>
     <SchedulesProvider>
     <ListUiProvider>
      <ReplyToast />
      <SidebarProvider open={sideOpen} onOpenChange={setSideOpen} className="min-h-0 motion-reduce:[&_[data-slot^=sidebar]]:transition-none"
        style={{ height: "var(--app-h, 100dvh)", "--sidebar-width": "20rem" } as CSSProperties}>
        {studio ? null : <Side />}
        <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
          <ViewAsBar />
          {studio ? null : <TopBar title={title} />}
          <NetBarOf />
          {studio ? null : <LegacyMigrationNotice />}
          {studio ? null : <ScheduleNotice />}
          <TrialBar trial={trial} onAsked={setTrial} />
          <main className="min-h-0 flex-1 overflow-y-auto">{children}</main>
        </div>
      </SidebarProvider>
     </ListUiProvider>
     </SchedulesProvider>
     </WorkRowsProvider>
      <Toaster position="top-center" />
     </TitleCtx.Provider>
    </Ctx.Provider>
  );
};

export { useMe } from "@/shared/api";
