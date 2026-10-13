// SiteBar.tsx — the website's top bar over /chat (issue #3646): the ClaudeFleet
// wordmark, the site's own pages with 对话 lit, where the conversation runs,
// what is left of the person's limit, and their avatar. Stock shadcn/ui only.
import type { FC, ReactNode } from "react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";
import type { Home, Me, Quota } from "@/site";

// The site's pages, in its order; a page /v1/me does not list is not drawn.
const NAV = [
  { id: "overview", label: "概览", href: "/app" },
  { id: "usage", label: "我的用量", href: "/app/usage" },
  { id: "tasks", label: "任务", href: "/app/tasks" },
  { id: "mymachines", label: "我的机器", href: "/app/machines" },
  { id: "chat", label: "对话", href: "/chat/" },
];

const HOME_DOT: Record<Home["state"], string> = {
  ok: "bg-[var(--fleet-ok)]",
  offline: "bg-muted-foreground/50",
  maintenance: "bg-[var(--fleet-warn)]",
  old_agent: "bg-[var(--fleet-warn)]",
};
const HOME_WORD: Record<Home["state"], string> = { ok: "在线", offline: "连不上", maintenance: "维护中", old_agent: "需更新" };

// Where it runs (machine · login) and the terminal resume line are not on the
// page by default: the bar shows only the home's state dot; both live in the
// account menu for whoever wants them.
export const SiteBar: FC<{ logo: ReactNode; me: Me | null; home: Home | null; quota: Quota | null;
  resume?: { id: string; cwd: string } | null }> = ({ logo, me, home, quota, resume }) => {
  const pages = new Set([...(me?.pages || []), "chat"]);
  const name = me?.name || me?.login || "";
  return (
    <header className="border-border/70 bg-background/85 sticky top-0 z-20 flex items-center gap-2 border-b px-4 pt-[calc(env(safe-area-inset-top)+0.6rem)] pb-2.5 backdrop-blur-md md:gap-3 md:px-6">
      <a href="/" className="text-foreground flex shrink-0 items-center gap-2.5 no-underline" aria-label="ClaudeFleet">
        {logo}
        <span className="font-display text-[17px] leading-none font-semibold tracking-tight md:text-[18px]">ClaudeFleet</span>
      </a>
      <span className="text-muted-foreground text-sm md:hidden">对话</span>
      <nav className="ms-4 hidden items-center gap-1 md:flex" aria-label="ClaudeFleet">
        {NAV.filter((p) => pages.has(p.id)).map((p) => (
          <Button key={p.id} asChild size="sm" variant={p.id === "chat" ? "secondary" : "ghost"}
            className={cn("text-[14px]", p.id === "chat" ? "text-foreground font-semibold" : "text-muted-foreground")}>
            <a href={p.href} aria-current={p.id === "chat" ? "page" : undefined}>{p.label}</a>
          </Button>
        ))}
      </nav>
      <div className="ms-auto flex items-center gap-2">
        {home ? (
          <span className="flex items-center" title={HOME_WORD[home.state]} aria-label={HOME_WORD[home.state]}>
            <span className={cn("size-1.5 rounded-full", HOME_DOT[home.state])} aria-hidden />
          </span>
        ) : null}
        {quota ? (
          <Button asChild size="sm" variant="outline"
            className={cn("h-7 px-3 font-mono text-[12px] no-underline", quota.over ? "border-[var(--fleet-clay-line)] text-[var(--fleet-clay)]" : "text-foreground")}>
            <a href="/app/usage" title="我的用量">
              <span className="hidden md:inline">{quota.window === "5h" ? "5 小时" : "本周"}</span>剩 {quota.pct}%
            </a>
          </Button>
        ) : null}
        <Popover>
          <PopoverTrigger asChild>
            <button type="button" className="rounded-full" aria-label="我的账户">
              <Avatar>
                <AvatarFallback className="bg-[var(--fleet-sand)] font-medium text-[#19182a]">{(name[0] || "·").toUpperCase()}</AvatarFallback>
              </Avatar>
            </button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-72 p-2">
            {name ? <p className="px-2 pt-1 pb-2 text-sm font-medium">{name}</p> : null}
            {home ? (
              <p className="text-muted-foreground px-2 pb-2 font-mono text-[11px] leading-snug break-all">
                后台：{home.machine} · {home.login} 的登录 · {HOME_WORD[home.state]}
                {resume ? <span className="mt-1 block select-all">终端里接着用：cd {resume.cwd || "~"} && claude --resume {resume.id}</span> : null}
              </p>
            ) : null}
            <div className="flex flex-col">
              <Button asChild variant="ghost" size="sm" className="text-foreground justify-start no-underline"><a href="/app">控制台</a></Button>
              <Button asChild variant="ghost" size="sm" className="text-foreground justify-start no-underline"><a href="/fleet/connection">我的连接</a></Button>
              {me?.can_logout ? (
                <form method="post" action="/logout">
                  <Button type="submit" variant="ghost" size="sm" className="w-full justify-start">退出</Button>
                </form>
              ) : null}
            </div>
          </PopoverContent>
        </Popover>
      </div>
    </header>
  );
};
