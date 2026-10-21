// Shell.tsx — the member side's frame (EPIC #3923 C3): on a phone (< 768) a
// top bar (the mark, what is left of the person's limit, the avatar into 我的)
// and the bottom bar of the pages marked `tab` (任务 joined 会话, T769); on a
// computer shadcn's Sidebar — the pages, 管理后台 for an admin, the person at
// its foot, whose menu opens 用量 · 设备 · 设置 · 我的 · 管理后台 · 退出. Those
// live in 我的 since GR5E C1, never in either bar. Stock shadcn/ui only; a
// page draws inside <main>.
//
// The conversation is immersive (issue #3996): on a phone the bottom bar folds
// away on 对话 — it takes no room — and the top bar's 菜单 brings it back;
// typing or moving the thread folds it again, and every other page shows it
// always. On a computer the sidebar folds to its icon strip (shadcn's
// collapsible="icon"), the choice kept in this browser.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ComponentProps, type FC, type ReactNode, type Ref } from "react";
import { Link, NavLink, useLocation, useNavigate } from "react-router";
import { ChevronsUpDown, CircleUserRound, Eye, LayoutGrid, LogOut, ShieldCheck } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { NavigationMenu, NavigationMenuItem, NavigationMenuLink, NavigationMenuList } from "@/components/ui/navigation-menu";
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent, SidebarHeader,
  SidebarMenu, SidebarMenuButton, SidebarMenuItem, SidebarProvider, SidebarRail, SidebarSeparator, SidebarTrigger,
} from "@/components/ui/sidebar";
import { cn } from "@/lib/utils";
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import { Toaster } from "@/components/ui/sonner";
import { isAdmin, useMe, useUsageHead, type Me, type Quota, type Trial } from "@/shared/api";
import { leaveViewAs, viewAs } from "@/shared/viewAs";
import { ADMIN_HREF, ME_TABS, PAGES, meTab, type PageDef } from "./routes";
import { TrialBar } from "./TrialBar";

// What every page reads: who is signed in, what is left of their limit and
// their trial's (claude-fleet T796) — both bumped after each conversation turn.
type ShellCtx = { me: Me | null; quota: Quota | null; trial: Trial | null; setTrial: (t: Trial) => void; bumpQuota: () => void };
const Ctx = createContext<ShellCtx>({ me: null, quota: null, trial: null, setTrial: () => {}, bumpQuota: () => {} });
export const useShell = () => useContext(Ctx);

// usePage(title): a page names itself — the tab's title.
export function usePage(title: string) {
  useEffect(() => { document.title = `${title} · ClaudeFleet`; }, [title]);
}

export const quotaWords = (q: Quota) =>
  q.over ? tr("额度用完", "Limit reached") : `${tr("剩余", "Left")} ${q.pct}%`;

// The limit capsule: what is left, a link to 我的 · 用量.
const QuotaPill: FC<{ quota: Quota | null }> = ({ quota }) =>
  quota ? (
    <Button asChild size="sm" variant="outline"
      className={cn("h-6 rounded-full px-2.5 font-mono text-[11px] no-underline",
        quota.over ? "border-clay-line text-clay" : "text-foreground")}>
      <Link to={meTab("usage").path} title={tr("我的用量", "My usage")}>{quotaWords(quota)}</Link>
    </Button>
  ) : null;

// A page's place: inside this app (a route), or the old page while it has none.
// Every other prop (a menu button's data-slot, data-active, class) passes on —
// it is the child of shadcn's asChild buttons.
const PageLink: FC<{ p: PageDef } & Omit<ComponentProps<"a">, "href">> = ({ p, ...rest }) =>
  p.page ? <NavLink to={p.path} end {...(rest as Omit<ComponentProps<typeof NavLink>, "to">)} />
         : <a href={p.href} {...rest} />;

function useActive() {
  const { pathname } = useLocation();
  return (p: PageDef) => !!p.page && (p.path === "/" ? pathname === "/" : pathname.startsWith(p.path));
}

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

const Side: FC = () => {
  const active = useActive();
  return (
    <Sidebar collapsible="icon" className="border-sidebar-border">
      <SidebarHeader className="flex-row items-center gap-1 px-4 pt-4 pb-2 group-data-[collapsible=icon]:flex-col group-data-[collapsible=icon]:px-2">
        <Link to="/" className="text-foreground flex min-w-0 items-center gap-2.5 no-underline" aria-label="ClaudeFleet">
          <Logo className="size-7 shrink-0" />
          <span className="font-display text-[17px] leading-none font-semibold tracking-tight group-data-[collapsible=icon]:hidden">ClaudeFleet</span>
        </Link>
        <SidebarTrigger className="text-muted-foreground ms-auto group-data-[collapsible=icon]:ms-0" title={tr("收起 / 展开侧栏", "Fold / unfold the sidebar")} />
      </SidebarHeader>
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {PAGES.filter((p) => p.side).map((p) => (
                <SidebarMenuItem key={p.id}>
                  <SidebarMenuButton asChild isActive={active(p)} tooltip={p.label} className="text-muted-foreground data-[active=true]:text-foreground">
                    <PageLink p={p}><p.icon />{p.label}</PageLink>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter className="px-3 pb-3">
        <SidebarSeparator className="mx-0" />
        <PersonMenu />
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  );
};

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

// The phone's bars fold on the conversation (issue #3996): `folds` says this
// page may fold them, `open` that the person brought the bottom bar back.
type Nav = { folds: boolean; open: boolean; setOpen: (o: boolean) => void };

const TopBar: FC<{ nav: Nav }> = ({ nav }) => {
  const { me, quota } = useShell();
  return (
    <header className={cn("border-border/70 bg-background/85 sticky top-0 z-20 flex items-center gap-2.5 border-b px-4 pb-2.5 backdrop-blur-md md:hidden",
      viewAs ? "pt-2.5" : "pt-[calc(env(safe-area-inset-top)+0.6rem)]")}>
      <Link to="/" className="text-foreground flex items-center gap-2.5 no-underline" aria-label="ClaudeFleet">
        <Logo className="size-7 shrink-0" />
        <span className="font-display text-[17px] leading-none font-semibold tracking-tight">ClaudeFleet</span>
      </Link>
      <span className="ms-auto"><QuotaPill quota={quota} /></span>
      {nav.folds ? (
        <Button variant="ghost" size="icon" className={cn("size-8", nav.open && "text-clay")} aria-expanded={nav.open} aria-controls="app-tabs"
          aria-label={tr("菜单", "Menu")} title={tr("菜单", "Menu")} onClick={() => nav.setOpen(!nav.open)}>
          <LayoutGrid />
        </Button>
      ) : null}
      <Link to={meTab("account").path} className="rounded-full no-underline" aria-label={tr("我的", "Me")} title={tr("我的", "Me")}>
        <Avatar className="size-8"><AvatarFallback className="text-xs">{initial(me?.name || me?.login || "")}</AvatarFallback></Avatar>
      </Link>
    </header>
  );
};

const BottomBar: FC<{ nav: Nav }> = ({ nav }) => {
  const active = useActive();
  const shown = !nav.folds || nav.open;
  return (
    // folded, it takes no room (0fr) and leaves only the home-bar inset under the composer
    <div id="app-tabs" data-folded={!shown} inert={!shown}
      className={cn("bg-background grid flex-none transition-[grid-template-rows] duration-200 ease-out motion-reduce:transition-none md:hidden",
        shown ? "grid-rows-[1fr]" : "grid-rows-[0fr] pb-[env(safe-area-inset-bottom)]")}>
    <div className="min-h-0 overflow-hidden">
    <NavigationMenu viewport={false} className="border-border/70 bg-background/95 max-w-none flex-none border-t pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden"
      aria-label={tr("页面", "Pages")}>
      <NavigationMenuList className="grid w-screen gap-0" style={{ gridTemplateColumns: `repeat(${PAGES.filter((p) => p.tab).length}, minmax(0, 1fr))` }}>
        {PAGES.filter((p) => p.tab).map((p) => (
          <NavigationMenuItem key={p.id}>
            <NavigationMenuLink asChild active={active(p)}
              className="text-muted-foreground aria-[current=page]:text-clay hover:text-foreground items-center gap-0.5 rounded-none bg-transparent py-2 text-[11px] hover:bg-transparent focus:bg-transparent aria-[current=page]:bg-transparent [&_svg]:size-5 aria-[current=page]:[&_svg]:text-clay">
              <PageLink p={p}><p.icon />{p.label}</PageLink>
            </NavigationMenuLink>
          </NavigationMenuItem>
        ))}
      </NavigationMenuList>
    </NavigationMenu>
    </div>
    </div>
  );
};

// The sidebar's folded or not, kept in this browser across a reload.
const SIDE_KEY = "fleet.console.sidebar";
function useSideOpen(): [boolean, (o: boolean) => void] {
  const [open, set] = useState(() => { try { return localStorage.getItem(SIDE_KEY) !== "folded"; } catch { return true; } });
  const save = useCallback((o: boolean) => { set(o); try { localStorage.setItem(SIDE_KEY, o ? "open" : "folded"); } catch { /* private mode */ } }, []);
  return [open, save];
}

// The phone's bars on this page: only the conversation folds them; moving to a
// page puts them back folded there (the conversation) or shown (anywhere else).
function useNav(): Nav {
  const { pathname } = useLocation();
  const folds = pathname === "/";
  const [open, setOpen] = useState(false);
  useEffect(() => { setOpen(false); }, [pathname]);
  return { folds, open, setOpen };
}

// AppShell: the frame around every member page. The page fills the space
// between the bars; a page that scrolls scrolls inside <main>.
export const AppShell: FC<{ children: ReactNode; quotaKey: number; bumpQuota: () => void }> = ({ children, quotaKey, bumpQuota }) => {
  const { me } = useMe();
  const { quota, trial, setTrial } = useUsageHead(quotaKey);
  const [sideOpen, setSideOpen] = useSideOpen();
  const nav = useNav();
  // typing, or moving through the thread, folds the bar the person brought back
  const fold = () => { if (nav.folds && nav.open) nav.setOpen(false); };
  return (
    <Ctx.Provider value={{ me, quota, trial, setTrial, bumpQuota }}>
      <SidebarProvider open={sideOpen} onOpenChange={setSideOpen} className="min-h-0 motion-reduce:[&_[data-slot^=sidebar]]:transition-none" style={{ height: "var(--app-h, 100dvh)" }}>
        <Side />
        <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
          <ViewAsBar />
          <TopBar nav={nav} />
          <TrialBar trial={trial} onAsked={setTrial} />
          <main className="min-h-0 flex-1 overflow-y-auto" data-immersive={nav.folds && !nav.open}
            onFocusCapture={(e) => { if (e.target instanceof HTMLTextAreaElement) fold(); }}
            onWheelCapture={fold} onTouchMoveCapture={fold}>{children}</main>
          <BottomBar nav={nav} />
        </div>
      </SidebarProvider>
      <Toaster position="top-center" />
    </Ctx.Provider>
  );
};

export { useMe } from "@/shared/api";
