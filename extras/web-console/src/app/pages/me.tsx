// me.tsx — 我的 (EPIC #3923 C3): who is signed in, the way to their devices and
// settings, 管理后台 for an admin only (rule 6: a member never sees it), and
// sign-out (rule 11: back to the site's front page). Stock shadcn/ui only.
import type { FC, ReactNode } from "react";
import { ChevronRight, LogOut, MonitorSmartphone, Settings, ShieldCheck, type LucideIcon } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { isAdmin, useDeviceCount, type Me } from "@/shared/api";
import { SignOut, usePage, useShell } from "../Shell";
import { ADMIN_HREF, PAGES } from "../routes";

// how a person signed in, as /v1/me's via says it
const VIA: Record<string, [string, string]> = {
  github: ["用 GitHub 登录", "Signed in with GitHub"],
  wechat: ["用微信登录", "Signed in with WeChat"],
  email: ["用邮箱登录", "Signed in with email"],
  token: ["用口令登录", "Signed in with a token"],
  open: ["免登录", "No sign-in"],
};
const roleWord = (me: Me) => (isAdmin(me) ? tr("管理员", "Admin") : tr("成员", "Member"));

const Row: FC<{ icon: LucideIcon; label: string; hint?: ReactNode; href: string; accent?: boolean }> = ({ icon: Icon, label, hint, href, accent }) => (
  <a href={href} className={cn("hover:bg-accent/60 flex items-center gap-3 px-5 py-4 no-underline transition-colors", accent ? "text-clay" : "text-foreground")}>
    <Icon className="size-[18px] shrink-0" aria-hidden />
    <span className="text-[15px]">{label}</span>
    {hint ? <span className="text-muted-foreground ms-auto truncate text-[13px]">{hint}</span> : <span className="ms-auto" />}
    <ChevronRight className="text-muted-foreground size-4 shrink-0" aria-hidden />
  </a>
);

export default function MePage() {
  usePage(tr("我的", "Me"));
  const { me } = useShell();
  const devices = useDeviceCount();
  const name = me?.name || me?.login || "";
  const page = (id: string) => PAGES.find((p) => p.id === id)!;
  const href = (id: string) => { const p = page(id); return p.page ? `/app${p.path}` : p.href!; };
  const via = me?.via ? VIA[me.via] : undefined;
  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-3 px-4 py-5 md:px-6 md:py-8">
      <Card className="gap-0 py-0">
        <CardContent className="flex items-center gap-4 px-6 py-5">
          {me ? (
            <>
              <Avatar className="size-12"><AvatarFallback className="text-lg font-medium">{(name[0] || "·").toUpperCase()}</AvatarFallback></Avatar>
              <div className="min-w-0">
                <p className="font-display truncate text-[18px] leading-tight font-semibold">{name || tr("（没有名字）", "(no name)")}</p>
                <p className="text-muted-foreground mt-1 truncate text-[13px]">
                  {roleWord(me)}{via ? ` · ${tr(...via)}` : ""}
                </p>
              </div>
            </>
          ) : (
            <>
              <Skeleton className="size-12 rounded-full" />
              <div className="flex flex-col gap-2"><Skeleton className="h-5 w-28" /><Skeleton className="h-4 w-40" /></div>
            </>
          )}
        </CardContent>
      </Card>
      <Card className="gap-0 overflow-hidden py-0">
        <Row icon={MonitorSmartphone} label={page("devices").label} href={href("devices")}
          hint={devices === null ? undefined : devices === 0 ? tr("还没有电脑", "No computers yet") : tr(`${devices} 台电脑`, `${devices} computer${devices === 1 ? "" : "s"}`)} />
        <Separator />
        <Row icon={Settings} label={page("settings").label} href={href("settings")} hint={tr("资料 · 登录方式", "Profile · Sign-in")} />
        {isAdmin(me) ? (
          <>
            <Separator />
            <Row icon={ShieldCheck} label={tr("管理后台", "Admin")} href={ADMIN_HREF} accent />
          </>
        ) : null}
      </Card>
      {me?.can_logout ? (
        <SignOut>
          <Button type="submit" variant="outline" className="h-10 w-full rounded-full">
            <LogOut />{tr("退出登录", "Sign out")}
          </Button>
        </SignOut>
      ) : null}
    </div>
  );
}
