// usage.tsx — 用量 (EPIC #3923 C6, issue #3929): what is left of the person's
// own limit and when it resets, today and the last 7 days, two weeks of bars
// (Claude / Codex), and where it went — by model, task, repo, batch — with a
// row's detail — and 我自己的订阅 (C21, ../subs.tsx). Only the person's own read, /v1/me/usage (me_usage.go; EPIC
// #3225's numbers, never the pool's windows); the range rides ?range= as on
// the old page. Stock shadcn/ui only: Card, Progress, Chart, Tabs, Sheet.
import { useMemo, useState, type FC, type ReactNode } from "react";
import { useSearchParams } from "react-router";
import { Bar, BarChart, XAxis } from "recharts";
import { RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { ChartContainer, ChartLegend, ChartLegendContent, ChartTooltip, ChartTooltipContent, type ChartConfig } from "@/components/ui/chart";
import { Progress } from "@/components/ui/progress";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { fmtTokens, fmtWhen, lang, tr } from "@/shared/i18n";
import { useLoad, type Trial } from "@/shared/api";
import { Failed, PageHeader } from "../parts";
import { useShell, usePage } from "../Shell";
import { MySubsCard } from "../subs";
import { trialParts, UpgradeAsk } from "../TrialBar";

// /v1/me/usage's answer (MeUsage, me_usage.go)
type Limit = {
  set?: boolean; limit_week?: number; used_week?: number; remaining_week?: number; reset_week?: string;
  limit_5h?: number; used_5h?: number; remaining_5h?: number; reset_5h?: string; over?: boolean; window?: string;
};
type Day = { day: string; claude: number; codex: number };
type Model = { name: string; provider: string; tokens: number };
type Item = {
  kind: string; title: string; repo?: string; issue?: number; epic?: string; epic_title?: string;
  tokens: number; models?: [string, number][]; sessions?: string[]; node?: string; login?: string;
};
type Usage = {
  range: string; limit: Limit; trial?: Trial; today: number; today_prev: number; week: number; week_prev: number; total: number;
  days: Day[]; models: Model[]; work: { issue: Item[]; repo: Item[]; epic: Item[] }; since_first?: string;
};

// The ranges ?range= takes on this page, the old page's three; no ?range= is 7d, the hub's default.
const RANGES = [["today", tr("今天", "Today")], ["7d", tr("7 天", "7 days")], ["30d", tr("30 天", "30 days")]] as const;
type Range = (typeof RANGES)[number][0];
const rangeOf = (v: string | null): Range => (RANGES.some(([r]) => r === v) ? (v as Range) : "7d");
const rangeWord = (r: Range) => RANGES.find(([k]) => k === r)![1];

const DAY = 864e5;
const num = (v: unknown) => Number(v) || 0;
const pct = (part: number, whole: number) => (whole > 0 ? Math.max(0, Math.min(100, Math.round((part / whole) * 100))) : 0);
// a window was fully recorded only when the hub's first row is at or before its start (claude-fleet#3230)
const fullFrom = (sinceFirst: string | undefined, start: number) => { const f = Date.parse(sinceFirst || ""); return Number.isFinite(f) && f <= start; };
const repoName = (r?: string) => String(r || "").split("/").pop() || "";
const epicNum = (e?: string) => /#(\d+)$/.exec(String(e || ""))?.[1] || "";

// The comparison under a number: 「比昨天 +12%」, or why there is none.
function delta(cur: number, prev: number, full: boolean, vs: [string, string], partial: [string, string]) {
  if (!full) return tr(...partial);
  if (!prev) return "";
  const p = Math.round(((cur - prev) / prev) * 100);
  return tr(`${vs[0]} ${p >= 0 ? "+" : ""}${p}%`, `${p >= 0 ? "+" : ""}${p}% ${vs[1]}`);
}

// ── a trial member's limits (claude-fleet T796): the same `trial` the bar over
// every page reads — tokens left of the ceiling, the days, the session count ──
const trialLeftPct = (t: Trial) => (num(t.tokens) > 0 ? pct(Math.max(0, num(t.tokens) - num(t.used_tokens)), num(t.tokens)) : 100);
const TrialLimitCard: FC<{ t: Trial; extra?: ReactNode }> = ({ t, extra }) => {
  const over = t.state === "expired" || t.state === "spent";
  const leftPct = trialLeftPct(t);
  const usedPct = 100 - leftPct;
  const tone = over ? "[&>[data-slot=progress-indicator]]:bg-destructive" : t.state === "soon" ? "[&>[data-slot=progress-indicator]]:bg-[var(--fleet-warn)]" : "";
  return (
    <Card className="gap-2" data-limit="trial">
      <CardHeader><CardDescription>{tr("我的上限 · 试用", "My limit · trial")}</CardDescription></CardHeader>
      <CardContent>
        {over ? (
          <p className="font-display text-destructive text-[34px] leading-none font-semibold tracking-tight">
            {t.state === "expired" ? tr("试用已结束", "Trial ended") : tr("用完了", "Used up")}
          </p>
        ) : num(t.tokens) > 0 ? (
          <p className="font-display text-[44px] leading-none font-semibold tracking-tight">
            {leftPct}<span className="text-muted-foreground text-2xl">%</span>
          </p>
        ) : (
          <p className="font-display text-[34px] leading-none font-semibold tracking-tight">{t.days_left != null ? tr(`剩 ${t.days_left} 天`, `${t.days_left} days left`) : tr("试用中", "On trial")}</p>
        )}
        {num(t.tokens) > 0 ? <Progress value={usedPct} className={cn("mt-4 h-2.5", tone)} aria-label={tr("已用", "Used")} /> : null}
        <p className={cn("mt-2 text-[13px]", over ? "text-destructive" : "text-muted-foreground")}>{trialParts(t).join(" · ")}</p>
        {t.until && !over ? <p className="text-muted-foreground mt-1 text-[13px]">{tr(`${fmtWhen(t.until)} 到期`, `Ends ${fmtWhen(t.until)}`)}</p> : null}
        {extra}
      </CardContent>
    </Card>
  );
};

// ── the limit: the stricter of a trial's and the weekly budget's, the other
// under it; what is left this week (and in 5 hours, when set); 不限额 only when
// neither is held ──
const LimitCard: FC<{ l: Limit; trial?: Trial }> = ({ l, trial }) => {
  const week = num(l.limit_week) > 0, h5 = num(l.limit_5h) > 0;
  const budget = !!l.set && (week || h5);
  if (trial) {
    const bLeft = budget ? (week ? pct(l.remaining_week ?? Math.max(0, num(l.limit_week) - num(l.used_week)), num(l.limit_week))
      : pct(l.remaining_5h ?? Math.max(0, num(l.limit_5h) - num(l.used_5h)), num(l.limit_5h))) : 101;
    const trialOver = trial.state === "expired" || trial.state === "spent";
    if (!budget || trialOver || trialLeftPct(trial) <= bLeft) {
      const extra = budget ? (
        <p className="text-muted-foreground mt-3 border-t pt-3 text-[13px]">
          {week ? tr(`本周上限还剩 ${bLeft}%`, `${bLeft}% of the weekly limit left`) : tr(`这 5 小时还剩 ${bLeft}%`, `${bLeft}% left in these 5 hours`)}
        </p>
      ) : null;
      return <TrialLimitCard t={trial} extra={extra} />;
    }
  }
  if (!budget) {
    return (
      <Card className="gap-2">
        <CardHeader><CardDescription>{tr("我的上限", "My limit")}</CardDescription></CardHeader>
        <CardContent>
          <p className="font-display text-[34px] leading-none font-semibold tracking-tight">{tr("不限额", "No limit")}</p>
          <p className="text-muted-foreground mt-3 text-[13px]">{tr("管理员没给你设上限，不会被拦。", "No admin has set you a limit; nothing is refused.")}</p>
          <p className="text-muted-foreground mt-1 text-[13px]">
            {tr(`近 5 小时用了 ${fmtTokens(l.used_5h)}，只是记录`, `${fmtTokens(l.used_5h)} in the last 5 hours — a record only`)}
          </p>
        </CardContent>
      </Card>
    );
  }
  // the binding window leads: the week when set, else the 5 hours
  const main = week
    ? { lim: num(l.limit_week), used: num(l.used_week), left: l.remaining_week, reset: l.reset_week, w: "week" }
    : { lim: num(l.limit_5h), used: num(l.used_5h), left: l.remaining_5h, reset: l.reset_5h, w: "5h" };
  const left = main.left ?? Math.max(0, main.lim - main.used);
  const leftPct = pct(left, main.lim);
  const over = (l.over && (l.window || "week") === main.w) || left <= 0;
  const usedPct = 100 - leftPct;
  const tone = over ? "[&>[data-slot=progress-indicator]]:bg-destructive" : usedPct >= 70 ? "[&>[data-slot=progress-indicator]]:bg-[var(--fleet-warn)]" : "";
  const h5Left = l.remaining_5h ?? Math.max(0, num(l.limit_5h) - num(l.used_5h));
  const h5Over = (l.over && l.window === "5h") || (h5 && h5Left <= 0);
  return (
    <Card className="gap-2">
      <CardHeader>
        <CardDescription>{main.w === "week" ? tr("本周还剩", "Left this week") : tr("这 5 小时还剩", "Left in these 5 hours")}</CardDescription>
      </CardHeader>
      <CardContent>
        {over ? (
          <p className="font-display text-destructive text-[34px] leading-none font-semibold tracking-tight">{tr("用完了", "Used up")}</p>
        ) : (
          <p className="font-display text-[44px] leading-none font-semibold tracking-tight">
            {leftPct}<span className="text-muted-foreground text-2xl">%</span>
          </p>
        )}
        <Progress value={usedPct} className={cn("mt-4 h-2.5", tone)} aria-label={tr("已用", "Used")} />
        <div className="text-muted-foreground mt-2 flex flex-wrap justify-between gap-x-3 text-[13px]">
          <span>{tr(`已用 ${fmtTokens(main.used)} / ${fmtTokens(main.lim)}`, `${fmtTokens(main.used)} of ${fmtTokens(main.lim)} used`)}</span>
          {main.reset ? <span>{over ? tr(`${fmtWhen(main.reset)} 恢复`, `Back ${fmtWhen(main.reset)}`) : tr(`${fmtWhen(main.reset)} 重置`, `Resets ${fmtWhen(main.reset)}`)}</span> : null}
        </div>
        {week && h5 ? (
          <div className={cn("mt-3 flex flex-wrap justify-between gap-x-3 border-t pt-3 text-[13px]", h5Over ? "text-destructive" : "text-muted-foreground")}>
            <span>
              {h5Over ? tr("这 5 小时用完了", "These 5 hours are used up")
                : tr(`这 5 小时还剩 ${pct(h5Left, num(l.limit_5h))}%`, `${pct(h5Left, num(l.limit_5h))}% left in these 5 hours`)}
            </span>
            <span>{l.reset_5h ? tr(`${fmtWhen(l.reset_5h)} 恢复`, `Back ${fmtWhen(l.reset_5h)}`) : tr("没用，不计时", "Unused — no clock running")}</span>
          </div>
        ) : null}
        {trial ? <p className="text-muted-foreground mt-3 border-t pt-3 text-[13px]">{tr("试用", "Trial")} · {trialParts(trial).join(" · ")}</p> : null}
      </CardContent>
    </Card>
  );
};

const Stat: FC<{ label: string; value: number; note: string }> = ({ label, value, note }) => (
  <Card className="gap-1">
    <CardHeader><CardDescription>{label}</CardDescription></CardHeader>
    <CardContent>
      <p className="font-display text-[28px] leading-tight font-semibold tracking-tight whitespace-nowrap">{fmtTokens(value)}</p>
      <p className="text-muted-foreground mt-1 text-[13px]">{["tokens", note].filter(Boolean).join(" · ")}</p>
    </CardContent>
  </Card>
);

// ── two weeks of bars, Claude below and Codex on top ──
const chartConfig = {
  claude: { label: "Claude", color: "var(--fleet-clay)" },
  codex: { label: "Codex", color: "var(--fleet-sand)" },
} satisfies ChartConfig;

const DaysCard: FC<{ days: Day[] | null; failed: boolean; onRetry: () => void }> = ({ days, failed, onRetry }) => {
  const rows = useMemo(() => (days || []).map((d) => ({
    ...d, label: String(Number(d.day.slice(8))),
    full: lang === "zh" ? `${Number(d.day.slice(5, 7))}月${Number(d.day.slice(8))}日` : new Date(`${d.day}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }),
  })), [days]);
  const any = rows.some((d) => num(d.claude) + num(d.codex) > 0);
  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="text-base">{tr("最近 14 天", "Last 14 days")}</CardTitle>
        <CardDescription>{tr("每天用了多少（按 UTC 日）", "Each day's tokens (UTC days)")}</CardDescription>
      </CardHeader>
      <CardContent>
        {failed ? (
          <div className="flex items-center justify-between gap-3 py-6 text-[13px]">
            <span className="text-muted-foreground">{tr("这一块没读出来", "This part didn't load")}</span>
            <Button variant="outline" size="sm" onClick={onRetry}><RotateCw />{tr("再试一次", "Try again")}</Button>
          </div>
        ) : !days ? (
          <Skeleton className="h-44 w-full" />
        ) : !any ? (
          <div className="text-muted-foreground flex h-44 flex-col items-center justify-center gap-1 text-center text-[13px]">
            <p className="text-foreground text-[15px] font-medium">{tr("这两周还没有计入你名下的用量", "Nothing counted under you in these two weeks")}</p>
            <p>{tr("会话走订阅池时才计量。", "Usage is counted when a session goes through the subscription pool.")}</p>
          </div>
        ) : (
          <ChartContainer config={chartConfig} className="aspect-auto h-44 w-full">
            <BarChart data={rows} margin={{ left: 0, right: 0, top: 4 }}>
              <XAxis dataKey="label" tickLine={false} axisLine={false} fontSize={11} interval={0} tickMargin={6} />
              <ChartTooltip content={<ChartTooltipContent labelKey="full" formatter={(v, name) => (
                <div className="flex w-full items-center justify-between gap-4">
                  <span className="text-muted-foreground">{chartConfig[name as keyof typeof chartConfig]?.label}</span>
                  <span className="font-mono">{fmtTokens(v)}</span>
                </div>)} />} />
              <ChartLegend content={<ChartLegendContent />} />
              <Bar dataKey="claude" stackId="a" fill="var(--color-claude)" radius={[0, 0, 3, 3]} />
              <Bar dataKey="codex" stackId="a" fill="var(--color-codex)" radius={[3, 3, 0, 0]} />
            </BarChart>
          </ChartContainer>
        )}
      </CardContent>
    </Card>
  );
};

// ── where it went ──
type Mode = "model" | "issue" | "repo" | "epic";
const MODES: [Mode, string][] = [["model", tr("模型", "Model")], ["issue", tr("任务", "Task")], ["repo", tr("仓库", "Repo")], ["epic", tr("批次", "Batch")]];
const NONE: Record<Exclude<Mode, "model">, [string, string]> = {
  issue: ["没挂在任务上的会话", "Sessions on no task"], repo: ["没声明仓库", "No repo named"], epic: ["不在批次里", "Not in a batch"],
};

type Row = { key: string; title: string; sub: string; tokens: number; share: number; muted: boolean; codex?: boolean; item?: Item };

function rowsOf(u: Usage, mode: Mode): Row[] {
  if (mode === "model") {
    const list = (u.models || []).filter((m) => num(m.tokens) > 0);
    const total = list.reduce((s, m) => s + num(m.tokens), 0);
    return list.map((m) => ({ key: m.name, title: m.name || "—", sub: m.provider === "codex" ? "Codex" : "Claude", tokens: num(m.tokens), share: pct(num(m.tokens), total), muted: false, codex: m.provider === "codex" }));
  }
  // the hub's "none" row is always there (each breakdown sums to the total); a row at 0 is dropped
  const list = (u.work?.[mode] || []).filter((r) => num(r.tokens) > 0);
  const total = list.reduce((s, r) => s + num(r.tokens), 0);
  return list.map((r, i) => {
    const n = epicNum(r.epic);
    let title: string;
    if (r.kind === "none") title = tr(...NONE[mode]);
    else if (mode === "issue") title = r.issue ? `#${r.issue}${r.title ? " " + r.title : ""}` : r.title || "—";
    else if (mode === "repo") title = repoName(r.repo || r.title);
    else title = n ? `#${n}${r.epic_title || r.title ? " " + (r.epic_title || r.title) : ""}` : r.title || "—";
    const sub = mode === "issue" ? [repoName(r.repo), n ? tr(`批次 #${n}`, `Batch #${n}`) : ""].filter(Boolean).join(" · ") : "";
    return { key: `${mode}${i}`, title, sub, tokens: num(r.tokens), share: pct(num(r.tokens), total), muted: r.kind === "none", item: r };
  });
}

const RowLine: FC<{ r: Row; onOpen?: () => void }> = ({ r, onOpen }) => {
  const body = (
    <>
      <div className="flex items-baseline justify-between gap-3">
        <span className={cn("min-w-0 truncate text-[14px]", r.muted ? "text-muted-foreground" : "font-medium", "")}>{r.title}</span>
        <span className="shrink-0 font-mono text-[13px]">{fmtTokens(r.tokens)}</span>
      </div>
      <Progress value={r.share} className={cn("mt-1.5 h-1.5", r.muted ? "[&>[data-slot=progress-indicator]]:bg-muted-foreground" : r.codex ? "[&>[data-slot=progress-indicator]]:bg-[var(--fleet-sand)]" : "")} aria-hidden />
      <p className="text-muted-foreground mt-1 text-[12px]">{[r.sub, `${r.share}%`].filter(Boolean).join(" · ")}</p>
    </>
  );
  return onOpen ? (
    <button type="button" onClick={onOpen} className="hover:bg-accent/60 -mx-2 block w-[calc(100%+1rem)] rounded-md px-2 py-2 text-left transition-colors">{body}</button>
  ) : <div className="py-2">{body}</div>;
};

const Detail: FC<{ row: Row | null; mode: Mode; u: Usage; range: Range; onClose: () => void }> = ({ row, mode, u, range, onClose }) => {
  const { me } = useShell();
  const r = row?.item;
  const KV: FC<{ k: string; children: ReactNode }> = ({ k, children }) => (
    <div className="grid grid-cols-[6.5rem_1fr] gap-3 py-2 text-[14px]"><dt className="text-muted-foreground">{k}</dt><dd className="min-w-0 break-words">{children}</dd></div>
  );
  let body: ReactNode = null;
  if (row && r && mode !== "issue" && mode !== "model") {
    // a repo or a batch: the tasks in it, from the task breakdown
    const inside = rowsOf(u, "issue").filter((x) => (mode === "repo"
      ? (r.kind === "none" ? !x.item?.repo : x.item?.repo === r.repo)
      : (r.kind === "none" ? !x.item?.epic : x.item?.epic === r.epic)));
    body = (
      <div className="px-4">
        <p className="mb-1 text-[13px] font-medium">{tr("里面的任务", "Tasks in it")}</p>
        {inside.length ? inside.map((x) => <RowLine key={x.key} r={{ ...x, share: pct(x.tokens, row.tokens) }} />)
          : <p className="text-muted-foreground py-2 text-[13px]">{tr("这段时间没有计入你名下的用量", "Nothing counted under you in this range")}</p>}
      </div>
    );
  } else if (row && r) {
    body = (
      <dl className="divide-y px-4">
        <KV k={tr("会话", "Sessions")}><span className="font-mono text-[13px]">{r.sessions?.length ? r.sessions.map((s) => <span key={s} className="block">{s}</span>) : "—"}</span></KV>
        <KV k={tr("模型", "Models")}>{r.models?.length ? r.models.map(([m, n]) => <span key={m} className="block">{m} <span className="text-muted-foreground font-mono text-[13px]">{fmtTokens(n)}</span></span>) : "—"}</KV>
        <KV k={tr("在哪跑的", "Where it ran")}>{r.node || r.login ? <>{tr("服务节点", "Node")} <b>{r.node || "—"}</b>{r.login ? <> · {tr("登录", "login")} <span className="font-mono text-[13px]">{r.login}</span></> : null}</> : "—"}</KV>
        <KV k={tr("记在谁名下", "Counted under")}>{me?.name || me?.login || tr("你", "you")} <span className="text-muted-foreground text-[13px]">{tr("（这次会话用的池子通行证发给的人）", "(whom the session's pool pass was issued to)")}</span></KV>
        <p className="text-muted-foreground py-3 text-[12.5px]">{tr("服务节点和登录只在这里说明「在哪跑的」，不作拆分维度。", "The node and login only say where it ran here; usage is never split by them.")}</p>
      </dl>
    );
  }
  return (
    <Sheet open={!!row} onOpenChange={(o) => !o && onClose()}>
      <SheetContent side="right" className="w-full overflow-y-auto sm:max-w-md">
        <SheetHeader>
          <SheetTitle className="pe-6 leading-snug">{row?.title}</SheetTitle>
          <SheetDescription>{[r?.repo, row?.sub && mode === "issue" ? row.sub.split(" · ").slice(1).join(" · ") : "", row ? `${rangeWord(range)} ${fmtTokens(row.tokens)}` : ""].filter(Boolean).join(" · ")}</SheetDescription>
        </SheetHeader>
        {body}
      </SheetContent>
    </Sheet>
  );
};

const WhereCard: FC<{ u: Usage | null; range: Range; setRange: (r: Range) => void; mode: Mode; setMode: (m: Mode) => void; loading: boolean; failed: boolean; onRetry: () => void }> = ({ u, range, setRange, mode, setMode, loading, failed, onRetry }) => {
  const [open, setOpen] = useState<Row | null>(null);
  return (
    <Card className="gap-3">
      <CardHeader className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <CardTitle className="text-base">{tr(`${rangeWord(range)}花在哪`, `Where it went · ${rangeWord(range).toLowerCase()}`)}</CardTitle>
          <CardDescription className="mt-1">{mode === "model" ? tr("按模型的名字", "By model name") : tr("点一行看详情", "Open a row for details")}</CardDescription>
        </div>
        <Tabs value={range} onValueChange={(v) => setRange(v as Range)}>
          <TabsList className="h-8">{RANGES.map(([k, w]) => <TabsTrigger key={k} value={k} className="px-2.5 text-[13px]">{w}</TabsTrigger>)}</TabsList>
        </Tabs>
      </CardHeader>
      <CardContent>
        <Tabs value={mode} onValueChange={(v) => setMode(v as Mode)}>
          <TabsList className="mb-2 w-full">{MODES.map(([k, w]) => <TabsTrigger key={k} value={k}>{w}</TabsTrigger>)}</TabsList>
          {MODES.map(([k]) => (
            <TabsContent key={k} value={k}>
              {failed ? <Failed what={tr("用量", "your usage")} onRetry={onRetry} /> : loading || !u ? (
                <div className="flex flex-col gap-4 py-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-9 w-full" />)}</div>
              ) : (() => {
                const rows = rowsOf(u, k);
                return rows.length ? rows.map((r) => <RowLine key={r.key} r={r} onOpen={k === "model" ? undefined : () => setOpen(r)} />)
                  : <p className="text-muted-foreground py-6 text-center text-[13px]">{tr("这段时间没有计入你名下的用量", "Nothing counted under you in this range")}</p>;
              })()}
            </TabsContent>
          ))}
        </Tabs>
      </CardContent>
      {u ? <Detail row={open} mode={mode} u={u} range={range} onClose={() => setOpen(null)} /> : null}
    </Card>
  );
};

export default function UsagePage() {
  const shell = useShell();
  usePage(tr("用量", "Usage"));
  const [qs, setQs] = useSearchParams();
  const range = rangeOf(qs.get("range"));
  const mode = (MODES.some(([m]) => m === qs.get("by")) ? qs.get("by") : "model") as Mode;
  const set = (k: string, v: string, dflt: string) => setQs((q) => { const n = new URLSearchParams(q); if (v === dflt) n.delete(k); else n.set(k, v); return n; }, { replace: true });
  const main = useLoad<Usage>(`/v1/me/usage?range=${range}`);
  const two = useLoad<Usage>("/v1/me/usage?range=14d");
  const u = main.data;
  const now = Date.now();
  const midnight = Math.floor(now / DAY) * DAY;
  const dt = u ? delta(u.today, u.today_prev, fullFrom(u.since_first, midnight - DAY), ["比昨天", "vs yesterday"], ["昨天无完整数据", "No full data for yesterday"]) : null;
  const dw = u ? delta(u.week, u.week_prev, fullFrom(u.since_first, now - 14 * DAY), ["比上周", "vs last week"], ["上周无完整数据", "No full data for last week"]) : null;
  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-3 px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("用量", "Usage")} sub={tr("只算走订阅池的用量，记在租用它的人名下；接上的自己的订阅在下面。", "Only usage that goes through the subscription pool, counted under the person who leased it. Your own connected subscriptions are below.")} />
      {main.failed && !u ? <Failed what={tr("用量", "your usage")} onRetry={main.reload} /> : !u ? (
        <>
          <Card><CardContent className="flex flex-col gap-3"><Skeleton className="h-4 w-20" /><Skeleton className="h-11 w-28" /><Skeleton className="h-2.5 w-full" /><Skeleton className="h-4 w-full" /></CardContent></Card>
          <div className="grid grid-cols-2 gap-3">{[0, 1].map((i) => <Card key={i}><CardContent className="flex flex-col gap-2"><Skeleton className="h-4 w-16" /><Skeleton className="h-8 w-20" /></CardContent></Card>)}</div>
        </>
      ) : (
        <>
          <LimitCard l={u.limit || {}} trial={u.trial} />
          {u.trial ? <UpgradeAsk trial={{ ...u.trial, upgrade_asked: shell.trial?.upgrade_asked || u.trial.upgrade_asked }} onAsked={shell.setTrial} /> : null}
          <div className="grid grid-cols-2 gap-3">
            <Stat label={tr("今天用了", "Used today")} value={u.today} note={u.today ? dt! : tr("今天还没用", "Nothing yet today")} />
            <Stat label={tr("近 7 天", "Last 7 days")} value={u.week} note={dw!} />
          </div>
        </>
      )}
      <MySubsCard />
      <DaysCard days={two.data?.days ?? null} failed={two.failed} onRetry={two.reload} />
      {main.failed && !u ? null : <WhereCard u={u} range={range} setRange={(r) => set("range", r, "7d")} mode={mode} setMode={(m) => set("by", m, "model")}
        loading={main.loading} failed={main.failed} onRetry={main.reload} />}
    </div>
  );
}
