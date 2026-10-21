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
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import { Toaster } from "@/components/ui/sonner";
import { isAdmin, useMe, useUsageHead, type Me, type Quota, type Trial } from "@/shared/api";
import { leaveViewAs, viewAs } from "@/shared/viewAs";
import { backStep, phoneBar } from "./phone-screen";
import { ADMIN_HREF, ME_TABS, meTab } from "./routes";
import { ListUiProvider, NewButton, SearchButton, SessionRows } from "./SessionList";
import { NetBar } from "./NetBar";
import { TrialBar } from "./TrialBar";
import { WorkRowsProvider } from "./work-rows";

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
  useEffect(() => { document.title = `${title} · ClaudeFleet`; setTitle(title); }, [title, setTitle]);
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
  <form ref={formRef} method="post" action="/app/logout">
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
            <DropdownMenuItem onSelect={() => go(meTab("account").path)}><CircleUserRound />{tr("我的", "Me")}</DropdownMenuItem>
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
      <Link to="/" className="text-foreground flex min-w-0 items-center gap-2 no-underline" aria-label="ClaudeFleet">
        <Logo className="size-7 shrink-0" />
        <span className="font-display truncate text-[16px] leading-none font-semibold tracking-tight group-data-[collapsible=icon]:hidden">ClaudeFleet</span>
      </Link>
      <span className="ms-auto flex items-center gap-0.5 group-data-[collapsible=icon]:hidden">
        <QuotaPillOf />
        <SearchButton />
        <NewButton />
      </span>
    </SidebarHeader>
    <SidebarContent>
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
        <Link to="/" className="text-foreground flex min-h-11 items-center gap-2.5 ps-2 no-underline" aria-label="ClaudeFleet">
          <Logo className="size-7 shrink-0" />
          <span className="font-display text-[17px] leading-none font-semibold tracking-tight">ClaudeFleet</span>
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

// The sidebar's folded or not, kept in this browser across a reload.
const SIDE_KEY = "fleet.console.sidebar";
function useSideOpen(): [boolean, (o: boolean) => void] {
  const [open, set] = useState(() => { try { return localStorage.getItem(SIDE_KEY) !== "folded"; } catch { return true; } });
  const save = useCallback((o: boolean) => { set(o); try { localStorage.setItem(SIDE_KEY, o ? "open" : "folded"); } catch { /* private mode */ } }, []);
  return [open, save];
}

// AppShell: the frame around every member page. The page fills the space
// between the bars; a page that scrolls scrolls inside <main>.
export const AppShell: FC<{ children: ReactNode; quotaKey: number; bumpQuota: () => void }> = ({ children, quotaKey, bumpQuota }) => {
  const { me } = useMe();
  const { quota, trial, setTrial } = useUsageHead(quotaKey);
  const [sideOpen, setSideOpen] = useSideOpen();
  const [title, setTitle] = useState("");
  return (
    <Ctx.Provider value={{ me, quota, trial, setTrial, bumpQuota }}>
     <TitleCtx.Provider value={setTitle}>
     <WorkRowsProvider>
     <ListUiProvider>
      <SidebarProvider open={sideOpen} onOpenChange={setSideOpen} className="min-h-0 motion-reduce:[&_[data-slot^=sidebar]]:transition-none"
        style={{ height: "var(--app-h, 100dvh)", "--sidebar-width": "20rem" } as CSSProperties}>
        <Side />
        <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
          <ViewAsBar />
          <TopBar title={title} />
          <NetBarOf />
          <TrialBar trial={trial} onAsked={setTrial} />
          <main className="min-h-0 flex-1 overflow-y-auto">{children}</main>
        </div>
      </SidebarProvider>
     </ListUiProvider>
     </WorkRowsProvider>
      <Toaster position="top-center" />
     </TitleCtx.Provider>
    </Ctx.Provider>
  );
};

export { useMe } from "@/shared/api";
