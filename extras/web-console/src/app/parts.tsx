// parts.tsx — what every member page draws besides its own rows (EPIC #3923
// rule 14: the loading, failed and empty states are as finished as the page):
// its heading, the cards while it loads, the sentence when the entry does not
// answer, the empty state. Stock shadcn/ui only.
import type { FC, ReactNode } from "react";
import { CircleAlert, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { lang, tr } from "@/shared/i18n";

// A page's heading: its name with the site's clay full stop, one line under it.
export const PageHeader: FC<{ title: string; sub?: string; action?: ReactNode; count?: number }> = ({ title, sub, action, count }) => (
  <div className="mb-4 flex items-end justify-between gap-3">
    <div className="min-w-0">
      <h1 className="font-display text-[26px] leading-tight font-semibold tracking-tight">
        {title}<span className="text-clay">.</span>
        {count !== undefined ? <span className="bg-primary text-primary-foreground ms-2 inline-block rounded-full px-2 align-middle font-mono text-sm leading-6" aria-label={tr(`共 ${count} 个`, `${count} in all`)}>{count}</span> : null}
      </h1>
      {sub ? <p className="text-muted-foreground mt-1 text-sm">{sub}</p> : null}
    </div>
    {action}
  </div>
);

// The cards a list shows while its read is on the way.
export const Loading: FC<{ n?: number }> = ({ n = 3 }) => (
  <div className="space-y-3" aria-busy="true">
    {Array.from({ length: n }, (_, i) => (
      <Card key={i}>
        <CardContent className="space-y-2">
          <Skeleton className="h-4 w-2/5" />
          <Skeleton className="h-3 w-3/5" />
        </CardContent>
      </Card>
    ))}
  </div>
);

// The entry did not answer: say what could not be read, and offer to try again.
export const Failed: FC<{ what: string; onRetry: () => void }> = ({ what, onRetry }) => (
  <Card className="border-destructive/40">
    <CardContent className="flex items-start gap-3">
      <CircleAlert className="text-destructive mt-0.5 size-5 shrink-0" aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="font-medium">{tr(`读不到${what}`, `Couldn't load ${what}`)}</p>
        <p className="text-muted-foreground text-sm">{tr("入口暂时没有回应，别的页面不受影响。", "The hub isn't answering right now; other pages still work.")}</p>
      </div>
      <Button size="sm" variant="outline" onClick={onRetry}><RotateCw /> {tr("重试", "Retry")}</Button>
    </CardContent>
  </Card>
);

// Nothing here yet: what it is, and the way to make the first one.
export const Empty: FC<{ icon: ReactNode; title: string; body: string; action?: ReactNode }> = ({ icon, title, body, action }) => (
  <div className="flex flex-col items-center px-6 py-14 text-center">
    <div className="bg-muted text-muted-foreground mb-4 grid size-12 place-items-center rounded-2xl [&_svg]:size-6">{icon}</div>
    <p className="font-display text-lg font-semibold">{title}</p>
    <p className="text-muted-foreground mt-1 max-w-xs text-sm">{body}</p>
    {action ? <div className="mt-5">{action}</div> : null}
  </div>
);

// ago(iso): how long ago, in the page's language — 刚才 · 5 分钟前 · 3 小时前 ·
// 2 天前, a date past a month.
export function ago(iso: string | undefined, now = Date.now()): string {
  const t = iso ? Date.parse(iso) : NaN;
  if (!Number.isFinite(t)) return "";
  const m = Math.floor(Math.max(0, now - t) / 60000);
  if (m < 1) return tr("刚才", "just now");
  if (m < 60) return tr(`${m} 分钟前`, `${m} min ago`);
  const h = Math.floor(m / 60);
  if (h < 24) return tr(`${h} 小时前`, `${h} h ago`);
  const d = Math.floor(h / 24);
  if (d < 30) return tr(`${d} 天前`, `${d} d ago`);
  return new Date(t).toLocaleDateString(lang === "zh" ? "zh-CN" : "en", { year: "numeric", month: "short", day: "numeric" });
}
