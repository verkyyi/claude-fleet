// AdminShell — the admin side's frame: the left column (shadcn Sidebar,
// grouped 人 · 机器 · 钱 · 发布 · 入口, nav.ts) and the page beside it; 回到我的
// 页面 at its foot goes to /app (EPIC #3923 拍板 3). On a phone the column
// folds behind a trigger (rule 9: opens and reads, no layout of its own).
import { ArrowLeft } from "lucide-react";
import { NavLink, Outlet, useLocation } from "react-router";
import { Badge } from "@/components/ui/badge";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Logo } from "@/shared/Logo";
import { t } from "./i18n";
import { NAV } from "./nav";

export function AdminShell() {
  const { pathname } = useLocation();
  return (
    <TooltipProvider>
      <SidebarProvider>
        <Sidebar>
          <SidebarHeader className="px-4 pt-5 pb-3">
            <div className="flex items-center gap-2.5">
              <Logo className="size-7" />
              <span className="font-display text-base font-semibold text-foreground">ClaudeFleet</span>
              <Badge variant="outline" className="border-clay-line bg-clay-soft text-clay">
                {t("brand.admin")}
              </Badge>
            </div>
          </SidebarHeader>
          <SidebarContent>
            {NAV.map((g) => (
              <SidebarGroup key={g.key}>
                <SidebarGroupLabel>{t(g.key)}</SidebarGroupLabel>
                <SidebarGroupContent>
                  <SidebarMenu>
                    {g.items.map((it) => {
                      const Icon = it.icon;
                      const active = !!it.to && (pathname === it.to || pathname.startsWith(it.to + "/"));
                      return (
                        <SidebarMenuItem key={it.key}>
                          <SidebarMenuButton asChild isActive={active} className="text-sidebar-foreground data-[active=true]:bg-clay-soft data-[active=true]:text-clay">
                            {it.to ? (
                              <NavLink to={it.to}>
                                <Icon />
                                <span>{t(it.key)}</span>
                              </NavLink>
                            ) : (
                              <a href={it.href}>
                                <Icon />
                                <span>{t(it.key)}</span>
                              </a>
                            )}
                          </SidebarMenuButton>
                        </SidebarMenuItem>
                      );
                    })}
                  </SidebarMenu>
                </SidebarGroupContent>
              </SidebarGroup>
            ))}
          </SidebarContent>
          <SidebarFooter className="p-3">
            <SidebarMenu>
              <SidebarMenuItem>
                <SidebarMenuButton asChild className="text-sidebar-foreground">
                  <a href="/app">
                    <ArrowLeft />
                    <span>{t("back.mine")}</span>
                  </a>
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarFooter>
        </Sidebar>
        <SidebarInset className="min-w-0">
          <header className="flex h-12 items-center gap-2 border-b px-4 md:hidden">
            <SidebarTrigger />
            <span className="font-display text-sm font-semibold">ClaudeFleet · {t("brand.admin")}</span>
          </header>
          <Outlet />
        </SidebarInset>
      </SidebarProvider>
      <Toaster position="top-center" />
    </TooltipProvider>
  );
}

export function NotFound() {
  return (
    <div className="mx-auto flex max-w-md flex-col items-center gap-2 p-16 text-center">
      <h1 className="font-display text-2xl font-semibold">{t("notfound.title")}</h1>
      <p className="text-sm text-muted-foreground">{t("notfound.sub")}</p>
    </div>
  );
}
