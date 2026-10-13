// Shell.tsx — the member side's frame (EPIC #3923 C3): on a phone (< 768) a
// top bar (the mark, what is left of the person's limit) and the five-tab
// bottom bar 对话 · 会话 · 任务 · 用量 · 我的; on a computer shadcn's Sidebar —
// the pages, 管理后台 for an admin, the person and sign-out at its foot.
// Stock shadcn/ui only; a page draws inside <main>.
import { createContext, useContext, useEffect, type ComponentProps, type FC, type ReactNode } from "react";
import { Link, NavLink, useLocation } from "react-router";
import { LogOut, ShieldCheck } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { NavigationMenu, NavigationMenuItem, NavigationMenuLink, NavigationMenuList } from "@/components/ui/navigation-menu";
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent, SidebarHeader,
  SidebarMenu, SidebarMenuButton, SidebarMenuItem, SidebarProvider, SidebarSeparator,
} from "@/components/ui/sidebar";
import { cn } from "@/lib/utils";
import { Logo } from "@/shared/Logo";
import { tr } from "@/shared/i18n";
import { isAdmin, useMe, useQuota, type Me, type Quota } from "@/shared/api";
import { ADMIN_HREF, PAGES, type PageDef } from "./routes";

// What every page reads: who is signed in, and what is left of their limit
// (bumped after each conversation turn).
type ShellCtx = { me: Me | null; quota: Quota | null; bumpQuota: () => void };
const Ctx = createContext<ShellCtx>({ me: null, quota: null, bumpQuota: () => {} });
export const useShell = () => useContext(Ctx);

// usePage(title): a page names itself — the tab's title.
export function usePage(title: string) {
  useEffect(() => { document.title = `${title} · ClaudeFleet`; }, [title]);
}

export const quotaWords = (q: Quota) =>
  q.over ? tr("额度用完", "Limit reached") : `${tr("剩余", "Left")} ${q.pct}%`;

// The limit capsule: what is left, a link to 用量.
const QuotaPill: FC<{ quota: Quota | null }> = ({ quota }) =>
  quota ? (
    <Button asChild size="sm" variant="outline"
      className={cn("h-6 rounded-full px-2.5 font-mono text-[11px] no-underline",
        quota.over ? "border-clay-line text-clay" : "text-foreground")}>
      <Link to="/usage" title={tr("我的用量", "My usage")}>{quotaWords(quota)}</Link>
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

const SignOut: FC<{ children: ReactNode }> = ({ children }) => (
  // back to the site's front page after (claude-fleet#3798): to=site, a fixed word
  <form method="post" action="/app/logout">
    <input type="hidden" name="to" value={document.documentElement.lang === "en" ? "site-en" : "site"} />
    {children}
  </form>
);
export { SignOut };

const Side: FC = () => {
  const { me, quota } = useShell();
  const active = useActive();
  const name = me?.name || me?.login || "";
  return (
    <Sidebar collapsible="none" className="border-sidebar-border sticky top-0 hidden h-svh border-e md:flex">
      <SidebarHeader className="px-4 pt-4 pb-2">
        <Link to="/" className="text-foreground flex items-center gap-2.5 no-underline" aria-label="ClaudeFleet">
          <Logo className="size-7 shrink-0" />
          <span className="font-display text-[17px] leading-none font-semibold tracking-tight">ClaudeFleet</span>
        </Link>
      </SidebarHeader>
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {PAGES.filter((p) => p.side).map((p) => (
                <SidebarMenuItem key={p.id}>
                  <SidebarMenuButton asChild isActive={active(p)} className="text-muted-foreground data-[active=true]:text-foreground">
                    <PageLink p={p}><p.icon />{p.label}</PageLink>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter className="px-3 pb-3">
        {isAdmin(me) ? (
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton asChild className="text-clay hover:text-clay">
                <a href={ADMIN_HREF}><ShieldCheck />{tr("管理后台", "Admin")}</a>
              </SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
        ) : null}
        <SidebarSeparator className="mx-0" />
        <div className="flex items-center gap-2.5 px-1 pt-1">
          <Link to="/me" className="text-foreground flex min-w-0 flex-1 items-center gap-2.5 no-underline" aria-label={tr("我的", "Me")}>
            <Avatar className="size-8"><AvatarFallback className="text-xs">{(name[0] || "·").toUpperCase()}</AvatarFallback></Avatar>
            <span className="min-w-0">
              <span className="block truncate text-sm font-medium">{name}</span>
              {quota ? <span className="text-muted-foreground block font-mono text-[11px]">{quotaWords(quota)}</span> : null}
            </span>
          </Link>
          {me?.can_logout ? (
            <SignOut>
              <Button type="submit" variant="ghost" size="icon" className="size-8" aria-label={tr("退出登录", "Sign out")} title={tr("退出登录", "Sign out")}>
                <LogOut />
              </Button>
            </SignOut>
          ) : null}
        </div>
      </SidebarFooter>
    </Sidebar>
  );
};

const TopBar: FC = () => {
  const { quota } = useShell();
  return (
    <header className="border-border/70 bg-background/85 sticky top-0 z-20 flex items-center gap-2.5 border-b px-4 pt-[calc(env(safe-area-inset-top)+0.6rem)] pb-2.5 backdrop-blur-md md:hidden">
      <Link to="/" className="text-foreground flex items-center gap-2.5 no-underline" aria-label="ClaudeFleet">
        <Logo className="size-7 shrink-0" />
        <span className="font-display text-[17px] leading-none font-semibold tracking-tight">ClaudeFleet</span>
      </Link>
      <span className="ms-auto"><QuotaPill quota={quota} /></span>
    </header>
  );
};

const BottomBar: FC = () => {
  const active = useActive();
  return (
    <NavigationMenu viewport={false} className="border-border/70 bg-background/95 max-w-none flex-none border-t pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden"
      aria-label={tr("页面", "Pages")}>
      <NavigationMenuList className="grid w-screen grid-cols-5 gap-0">
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
  );
};

// AppShell: the frame around every member page. The page fills the space
// between the bars; a page that scrolls scrolls inside <main>.
export const AppShell: FC<{ children: ReactNode; quotaKey: number; bumpQuota: () => void }> = ({ children, quotaKey, bumpQuota }) => {
  const { me } = useMe();
  const quota = useQuota(quotaKey);
  return (
    <Ctx.Provider value={{ me, quota, bumpQuota }}>
      <SidebarProvider className="min-h-0" style={{ height: "var(--app-h, 100dvh)" }}>
        <Side />
        <div className="flex min-w-0 flex-1 flex-col overflow-hidden">
          <TopBar />
          <main className="min-h-0 flex-1 overflow-y-auto">{children}</main>
          <BottomBar />
        </div>
      </SidebarProvider>
    </Ctx.Provider>
  );
};

export { useMe } from "@/shared/api";
