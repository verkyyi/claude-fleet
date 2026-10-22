// Usage — 全队用量, /admin/usage (EPIC #3923 C13; the old /app/admin/overview
// and /app/admin/sessions move here). Four tabs over one read: 按人 (who used
// most this week, near their limit, mostly on what), 全部会话 (every open
// session, whoever's), 按机器 and 按模型. A person's today / 7 days / limit are
// /v1/admin/usage — the hub's own /v1/me/usage count, so their row and drawer
// say what their own 用量 page says; what they are on, their sessions and
// logins are /v1/admin/overview; the sessions are /v1/admin/sessions. CSV is
// made here, from the rows on screen. 试用 (WACK C6) is one Beijing day of the
// trial identities — /v1/admin/usage/trial, the same count — where the morning
// 「试用日报」's 查看详情 lands (?tab=trial&day=…, &open=<person> from a 超线提醒).
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { ChevronLeft, ChevronRight, Copy, Download, X } from "lucide-react";
import { useSearchParams } from "react-router";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { fmtTokens, fmtWhen } from "@/shared/i18n";
import { AdminTablePage, type Filter, type Kpi } from "../AdminTablePage";
import {
  api,
  type FleetSession,
  type FleetSessions,
  type MeUsage,
  type MeUsageLimit,
  type Overview,
  type OverviewPerson,
  type TeamUsage,
  type TrialSpend,
  type TrialSpendPerson,
  type UsageMachine,
  type UsageModel,
} from "../api";
import { ago, t, type MsgKey } from "../i18n";

const TABS = ["people", "sessions", "machines", "models", "trial"] as const;
type Tab = (typeof TABS)[number];

type Data = { usage: TeamUsage; ov: Overview | null; ses: FleetSessions | null };

const NEAR = 80;

// ── the limit, as the person's own page reads it (C6's LimitCard) ──
type LimitView = { w: "week" | "5h"; limit: number; used: number; left: number; usedPct: number; over: boolean; reset?: string };

function limitOf(l: MeUsageLimit): LimitView | null {
  const week = (l.limit_week || 0) > 0;
  const h5 = (l.limit_5h || 0) > 0;
  if (!l.set || (!week && !h5)) return null;
  const limit = week ? l.limit_week! : l.limit_5h!;
  const used = week ? l.used_week : l.used_5h;
  const left = (week ? l.remaining_week : l.remaining_5h) ?? Math.max(0, limit - used);
  const w = week ? "week" : "5h";
  const usedPct = 100 - Math.max(0, Math.min(100, Math.round((left / limit) * 100)));
  return { w, limit, used, left, usedPct, over: (!!l.over && (l.window || "week") === w) || left <= 0, reset: week ? l.reset_week : l.reset_5h };
}

function LimitCell({ l }: { l: MeUsageLimit }) {
  const v = limitOf(l);
  if (!v) return <span className="text-muted-foreground">{t("usage.noLimit")}</span>;
  return (
    <div className="flex items-center gap-2">
      <Progress
        value={v.usedPct}
        className={cn(
          "h-1.5 w-20",
          v.over ? "[&>[data-slot=progress-indicator]]:bg-destructive" : v.usedPct >= NEAR && "[&>[data-slot=progress-indicator]]:bg-warn",
        )}
      />
      <span className={cn("font-mono text-xs tabular-nums", v.over ? "text-destructive" : "text-muted-foreground")}>
        {v.over ? t("usage.usedUp") : t("usage.left", { p: 100 - v.usedPct })}
      </span>
    </div>
  );
}

const near = (l: MeUsageLimit) => {
  const v = limitOf(l);
  return !!v && (v.over || v.usedPct >= NEAR);
};

const shortRepo = (r?: string) => String(r || "").split("/").pop() || "";
const doingText = (p?: OverviewPerson) => (p?.doing ? [shortRepo(p.doing.repo), p.doing.issue ? `#${p.doing.issue}` : ""].filter(Boolean).join(" · ") : "");
const num = (n: number) => <span className="font-mono tabular-nums">{fmtTokens(n)}</span>;

// ── rows ──
type PersonRow = { id: string; name: string; today: number; week: number; limit: MeUsageLimit; ov?: OverviewPerson };

type SessionRow = {
  id: string;
  key: string;
  title: string;
  repo: string;
  state: string;
  ask: string;
  machine: string;
  availability: string;
  person: string;
  principal: string;
  agent: string;
  worktree: string;
  born: number;
  tokens: number;
};

type MachineRow = UsageMachine & { availability: string; running: number; sessions: number };
type ModelRow = UsageModel & { share: number };

const STATES: Record<string, { key: MsgKey; group: "working" | "waiting" | "idle"; tone: string }> = {
  working: { key: "usage.st.working", group: "working", tone: "border-ok/40 text-ok" },
  waiting: { key: "usage.st.waiting", group: "waiting", tone: "border-warn/50 text-warn" },
  blocked: { key: "usage.st.blocked", group: "waiting", tone: "border-destructive/50 text-destructive" },
  idle: { key: "usage.st.idle", group: "idle", tone: "text-muted-foreground" },
  done: { key: "usage.st.done", group: "idle", tone: "text-muted-foreground" },
  unknown: { key: "usage.st.unknown", group: "idle", tone: "text-muted-foreground" },
};
const stateKey = (s?: string) => (s && STATES[s] ? s : s === "needs" ? "waiting" : "unknown");

function StateBadge({ s }: { s: string }) {
  return (
    <Badge variant="outline" className={cn("font-normal", STATES[s].tone)}>
      {t(STATES[s].key)}
    </Badge>
  );
}

const AVAIL: Record<string, MsgKey> = {
  online: "usage.avail.online",
  maintenance: "usage.avail.maintenance",
  lost: "usage.avail.lost",
  disabled: "usage.avail.disabled",
};
function AvailBadge({ a }: { a: string }) {
  if (!a || a === "online") return null;
  return (
    <Badge variant="outline" className={cn("font-normal", a === "lost" ? "border-destructive/50 text-destructive" : "border-warn/50 text-warn")}>
      {t(AVAIL[a] || "usage.avail.lost")}
    </Badge>
  );
}

// whose a (machine, login) is, off the overview's people
function loginOwners(ov: Overview | null) {
  const m = new Map<string, OverviewPerson>();
  for (const p of ov?.people || []) for (const [host, login] of p.logins || []) m.set(`${host}\u0000${login}`, p);
  return (host: string, login: string) => m.get(`${host}\u0000${login}`);
}

function sessionRows(d: Data): SessionRow[] {
  const owner = loginOwners(d.ov);
  return (d.ses?.sessions || [])
    .map((s: FleetSession) => {
      const w = s.worker || {};
      const state = stateKey(w.state);
      const p = owner(s.machine_name, s.os_user);
      const msg = (w.status_msg || w.detail || "").replace(/[\x00-\x1f\x7f]+/g, " ").trim().slice(0, 200);
      return {
        id: w.worker_id || s.worker_id || `${s.machine_name}/${w.key || w.name}`,
        key: w.key || w.name || "—",
        title: w.title || "",
        repo: w.repo || "",
        state,
        ask: STATES[state].group === "waiting" ? msg : "",
        machine: s.machine_name || "",
        availability: s.availability || "online",
        person: p?.name || s.os_user || "",
        principal: p?.principal || "",
        agent: w.agent || "",
        worktree: w.worktree || "",
        born: Number(w.born) || 0,
        tokens: Number(s.tokens_today) > 0 ? Number(s.tokens_today) : 0,
      };
    })
    .sort((a, b) => b.born - a.born || a.key.localeCompare(b.key));
}

function machineRows(d: Data): MachineRow[] {
  const by = new Map<string, MachineRow>();
  const get = (node: string) => {
    let m = by.get(node);
    if (!m) by.set(node, (m = { node, today: 0, week: 0, people: 0, availability: "", running: 0, sessions: 0 }));
    return m;
  };
  for (const m of d.usage.machines || []) Object.assign(get(m.node), m);
  for (const n of d.ov?.nodes || d.ses?.nodes || []) get(n.machine_name).availability = n.disabled ? "disabled" : n.availability;
  for (const s of d.ses?.sessions || []) {
    const m = get(s.machine_name);
    m.sessions++;
    if (STATES[stateKey(s.worker?.state)].group !== "idle") m.running++;
  }
  return [...by.values()].sort((a, b) => b.week - a.week || b.sessions - a.sessions || a.node.localeCompare(b.node));
}

function modelRows(d: Data): ModelRow[] {
  const total = (d.usage.models || []).reduce((a, m) => a + m.tokens, 0);
  return (d.usage.models || []).map((m) => ({ ...m, share: total ? Math.round((m.tokens / total) * 100) : 0 }));
}

// ── CSV, made here from the rows ──
function csv(name: string, head: string[], rows: (string | number)[][]) {
  const cell = (v: string | number) => {
    const s = String(v ?? "");
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  const text = "﻿" + [head, ...rows].map((r) => r.map(cell).join(",")).join("\r\n");
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  a.download = `${name}-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function exportTab(tab: Tab, d: Data) {
  if (tab === "people") {
    const ov = new Map((d.ov?.people || []).map((p) => [p.principal, p]));
    csv("team-usage-people", ["principal", "name", "today", "week", "limit_week", "used_week", "remaining_week", "doing", "sessions", "running"], d.usage.people.map((p) => {
      const o = ov.get(p.principal);
      return [p.principal, p.name, p.today, p.week, p.limit.limit_week ?? "", p.limit.used_week, p.limit.remaining_week ?? "", doingText(o), o?.sessions ?? 0, o?.running ?? 0];
    }));
  } else if (tab === "sessions") {
    csv("team-sessions", ["key", "repo", "state", "machine", "person", "agent", "tokens_today", "started"], sessionRows(d).map((r) => [
      r.key, r.repo, r.state, r.machine, r.person, r.agent, r.tokens, r.born ? new Date(r.born * 1000).toISOString() : "",
    ]));
  } else if (tab === "machines") {
    csv("team-usage-machines", ["machine", "availability", "today", "week", "people", "sessions", "running"], machineRows(d).map((m) => [
      m.node, m.availability, m.today, m.week, m.people, m.sessions, m.running,
    ]));
  } else {
    csv("team-usage-models", ["model", "provider", "week", "share_pct"], modelRows(d).map((m) => [m.name, m.provider, m.tokens, m.share]));
  }
}

// ── the page ──
export function UsagePage() {
  const [sp, setSp] = useSearchParams();
  const raw = sp.get("tab") || "people";
  const tab: Tab = (TABS as readonly string[]).includes(raw) ? (raw as Tab) : "people";
  const who = sp.get("who") || "";
  const open = sp.get("open");
  const [data, setData] = React.useState<Data | null>(null);
  const [trial, setTrial] = React.useState<TrialSpend | null>(null);
  const day = sp.get("day") || "";
  const cache = React.useRef<Promise<Data> | null>(null);

  const load = React.useCallback((): Promise<Data> => {
    if (!cache.current) {
      cache.current = Promise.all([
        api<TeamUsage>("/v1/admin/usage"),
        api<Overview>("/v1/admin/overview?since=7d").catch(() => null),
        api<FleetSessions>("/v1/admin/sessions").catch(() => null),
      ]).then(
        ([usage, ov, ses]) => {
          const d = { usage, ov, ses };
          setData(d);
          return d;
        },
        (e) => {
          cache.current = null;
          throw e;
        },
      );
    }
    return cache.current;
  }, []);
  const set = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(sp);
    for (const [k, v] of Object.entries(patch)) {
      if (v) next.set(k, v);
      else next.delete(k);
    }
    setSp(next);
  };

  const kpis = (): Kpi[] => {
    if (!data) return [];
    const ppl = data.usage.people;
    return [
      { label: t("usage.kpi.today"), value: fmtTokens(ppl.reduce((a, p) => a + p.today, 0)) },
      { label: t("usage.kpi.week"), value: fmtTokens(ppl.reduce((a, p) => a + p.week, 0)) },
      { label: t("usage.kpi.running"), value: data.ov ? data.ov.totals.running : sessionRows(data).filter((r) => STATES[r.state].group !== "idle").length },
      { label: t("usage.kpi.near"), value: ppl.filter((p) => near(p.limit)).length },
    ];
  };

  const tabs = (
    <Tabs value={tab} onValueChange={(v) => set({ tab: v === "people" ? null : v, open: null, who: null, day: null })}>
      <TabsList>
        {TABS.map((k) => (
          <TabsTrigger key={k} value={k} className="px-3">
            {t(`usage.tab.${k}` as MsgKey)}
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  );

  const common = {
    title: t("page.usage"),
    lead: t("usage.lead"),
    kpis: kpis,
    aside: () => tabs,
    openId: open,
    onOpen: (id: string | null) => set({ open: id }),
    actions: (_reload: () => void, rows: unknown[]) => (
      <Button variant="outline" disabled={!data || !rows.length} onClick={() => data && exportTab(tab, data)}>
        <Download />
        {t("usage.export")}
      </Button>
    ),
  };

  if (tab === "trial") {
    const shown = trial?.day || day || bjDay(-1);
    const go = (d: number) => set({ day: shiftDay(shown, d), open: null });
    return (
      <AdminTablePage<TrialRow>
        key={`trial:${day}`}
        {...common}
        title={t("usage.trial.title")}
        lead={t("usage.trial.lead", { when: trialWhen(shown) })}
        kpis={() =>
          trial
            ? [
                { label: t("usage.trial.split", { pool: fmtTokens(trial.pool), byo: fmtTokens(trial.byo) }), value: t("usage.trial.tokens", { n: fmtTokens(trial.tokens) }) },
                { label: t("usage.trial.activeNew", { n: trial.new }), value: peopleN(trial.active) },
                { label: t("usage.trial.overLine"), value: peopleN(trial.over) },
              ]
            : []
        }
        aside={() => (
          <div className="flex flex-wrap items-center gap-3">
            {tabs}
            <div className="flex items-center gap-1">
              <Button variant="outline" size="icon" className="size-8" aria-label={t("usage.trial.prev")} onClick={() => go(-1)}>
                <ChevronLeft />
              </Button>
              <span className="min-w-24 text-center font-mono text-xs tabular-nums">{shown}</span>
              <Button variant="outline" size="icon" className="size-8" aria-label={t("usage.trial.next")} disabled={shown >= bjDay()} onClick={() => go(1)}>
                <ChevronRight />
              </Button>
            </div>
            {trial?.all_over && (
              <Badge variant="outline" className="h-7 border-destructive/50 font-normal text-destructive">
                {t("usage.trial.allOver", { n: fmtTokens(trial.line.all_day) })}
              </Badge>
            )}
          </div>
        )}
        actions={(_reload, rows) => (
          <Button
            variant="outline"
            disabled={!rows.length}
            onClick={() =>
              csv(`trial-usage-${shown}`, ["principal", "name", "trial_day", "tokens", "pool", "byo", "new", "active", "over"], (rows as TrialRow[]).map((r) => [
                r.principal, r.name, r.trial_day, r.tokens, r.pool, r.byo, String(r.new), String(r.active), String(r.over),
              ]))
            }
          >
            <Download />
            {t("usage.export")}
          </Button>
        )}
        fetch={() =>
          Promise.all([api<TrialSpend>(`/v1/admin/usage/trial${day ? `?day=${encodeURIComponent(day)}` : ""}`), load().catch(() => null)]).then(([d]) => {
            setTrial(d);
            return d.people.map((p) => ({ ...p, id: p.principal }));
          })
        }
        columns={trialColumns}
        filters={trialFilters}
        searchText={(r) => [r.name, r.principal].join(" ")}
        rowId={(r) => r.id}
        emptyText={t("usage.empty.trial")}
        drawer={(r) => {
          const p = data?.usage.people.find((x) => x.principal === r.principal);
          const row: PersonRow = {
            id: r.principal,
            name: r.name,
            today: p?.today || 0,
            week: p?.week || 0,
            limit: p?.limit || { set: false, used_week: 0, used_5h: 0 },
            ov: data?.ov?.people.find((x) => x.principal === r.principal),
          };
          return <PersonDrawer r={row} subName={(a) => data?.ov?.pool.find((s) => s.account === a)?.label || a} onSessions={() => set({ tab: "sessions", who: r.principal, open: null, day: null })} />;
        }}
      />
    );
  }
  if (tab === "sessions") {
    const whoName = who && data ? data.usage.people.find((p) => p.principal === who)?.name || who : who;
    return (
      <AdminTablePage<SessionRow>
        key="sessions"
        {...common}
        aside={() => (
          <div className="flex flex-wrap items-center gap-3">
            {tabs}
            {who && (
              <Badge variant="outline" className="h-7 gap-1 border-clay-line bg-clay-soft pr-1 font-normal text-clay">
                {t("usage.who", { name: whoName })}
                <Button variant="ghost" size="icon" className="size-5 text-clay hover:bg-transparent" aria-label={t("usage.whoAll")} onClick={() => set({ who: null })}>
                  <X className="size-3.5" />
                </Button>
              </Badge>
            )}
          </div>
        )}
        fetch={() => load().then((d) => sessionRows(d).filter((r) => !who || r.principal === who))}
        columns={sessionColumns}
        filters={sessionFilters}
        searchText={(r) => [r.key, r.title, r.repo, r.machine, r.person, r.ask].join(" ")}
        rowId={(r) => r.id}
        emptyText={t("usage.empty.sessions")}
        drawer={(r) => <SessionDrawer r={r} />}
      />
    );
  }
  if (tab === "machines") {
    return (
      <AdminTablePage<MachineRow>
        key="machines"
        {...common}
        onOpen={undefined}
        fetch={() => load().then(machineRows)}
        columns={machineColumns}
        searchText={(r) => r.node}
        rowId={(r) => r.node || "-"}
        emptyText={t("usage.empty.machines")}
      />
    );
  }
  if (tab === "models") {
    return (
      <AdminTablePage<ModelRow>
        key="models"
        {...common}
        onOpen={undefined}
        fetch={() => load().then(modelRows)}
        columns={modelColumns}
        filters={modelFilters}
        searchText={(r) => `${r.name} ${r.provider}`}
        rowId={(r) => `${r.provider}/${r.name}`}
        emptyText={t("usage.empty.models")}
      />
    );
  }
  return (
    <AdminTablePage<PersonRow>
      key="people"
      {...common}
      fetch={() =>
        load().then((d) => {
          const ov = new Map((d.ov?.people || []).map((p) => [p.principal, p]));
          return d.usage.people.map((p) => ({ id: p.principal, name: p.name, today: p.today, week: p.week, limit: p.limit, ov: ov.get(p.principal) }));
        })
      }
      columns={personColumns}
      filters={personFilters}
      searchText={(r) => [r.name, r.id, doingText(r.ov)].join(" ")}
      rowId={(r) => r.id}
      emptyText={t("usage.empty.people")}
      drawer={(r) => <PersonDrawer r={r} subName={(a) => data?.ov?.pool.find((s) => s.account === a)?.label || a} onSessions={() => set({ tab: "sessions", who: r.id, open: null })} />}
    />
  );
}

// ── by person ──
const personColumns: ColumnDef<PersonRow, any>[] = [
  { accessorKey: "name", header: () => t("usage.col.person"), cell: ({ getValue }) => <span className="font-medium">{getValue()}</span> },
  { accessorKey: "today", header: () => t("usage.col.today"), cell: ({ getValue }) => num(getValue()) },
  { accessorKey: "week", header: () => t("usage.col.week"), cell: ({ getValue }) => num(getValue()) },
  {
    id: "limit",
    accessorFn: (r) => limitOf(r.limit)?.usedPct ?? -1,
    header: () => t("usage.col.limit"),
    cell: ({ row }) => <LimitCell l={row.original.limit} />,
  },
  { id: "doing", accessorFn: (r) => doingText(r.ov), header: () => t("usage.col.doing"), cell: ({ getValue }) => getValue() || <span className="text-muted-foreground">—</span> },
  {
    id: "sessions",
    accessorFn: (r) => r.ov?.sessions || 0,
    header: () => t("usage.col.sessions"),
    cell: ({ row: { original: r } }) =>
      r.ov?.sessions ? <span className="tabular-nums">{t("usage.running", { r: r.ov.running, n: r.ov.sessions })}</span> : <span className="text-muted-foreground">—</span>,
  },
];

const personFilters: Filter<PersonRow>[] = [
  { key: "near", label: t("usage.filter.near"), test: (r) => near(r.limit) },
  { key: "running", label: t("usage.filter.running"), test: (r) => (r.ov?.running || 0) > 0 },
];

function Field({ k, children }: { k: MsgKey; children: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{t(k)}</dt>
      <dd className="min-w-0">{children}</dd>
    </>
  );
}

function Bars({ items }: { items: [string, number][] }) {
  const max = Math.max(1, ...items.map(([, n]) => n));
  return (
    <ul className="grid gap-2">
      {items.map(([label, n]) => (
        <li key={label} className="grid grid-cols-[minmax(0,9rem)_1fr_auto] items-center gap-3 text-sm">
          <span className="truncate font-mono text-xs">{label}</span>
          <Progress value={(n / max) * 100} className="h-1.5" />
          <span className="font-mono text-xs text-muted-foreground tabular-nums">{fmtTokens(n)}</span>
        </li>
      ))}
    </ul>
  );
}

function PersonDrawer({ r, subName, onSessions }: { r: PersonRow; subName: (a: string) => string; onSessions: () => void }) {
  // the person's whole answer, the same /v1/me/usage count their own page reads
  const [u, setU] = React.useState<MeUsage | null>(null);
  const [err, setErr] = React.useState("");
  React.useEffect(() => {
    setU(null);
    setErr("");
    api<MeUsage>(`/v1/admin/usage?range=7d&principal=${encodeURIComponent(r.id)}`).then(setU, (e: Error) => setErr(e.message));
  }, [r.id]);
  const lim = u?.limit || r.limit;
  const v = limitOf(lim);
  const o = r.ov;
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{r.name}</SheetTitle>
        <SheetDescription>{t("usage.d.sub")}</SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="usage.d.today">{num(u ? u.today : r.today)}</Field>
          <Field k="usage.d.week">{num(u ? u.week : r.week)}</Field>
          <Field k={v?.w === "5h" ? "usage.d.limit5h" : "usage.d.limitWeek"}>
            {v ? (
              <div className="grid gap-1.5">
                <LimitCell l={lim} />
                <span className="font-mono text-xs text-muted-foreground">
                  {v.reset
                    ? t("usage.d.ofLimit", { left: fmtTokens(v.left), limit: fmtTokens(v.limit), when: fmtWhen(v.reset) })
                    : t("usage.d.ofLimitNoReset", { left: fmtTokens(v.left), limit: fmtTokens(v.limit) })}
                </span>
              </div>
            ) : (
              <span className="text-muted-foreground">{t("usage.noLimit")}</span>
            )}
          </Field>
          <Field k="usage.d.doing">{doingText(o) || <span className="text-muted-foreground">—</span>}</Field>
          <Field k="usage.d.sessions">{o?.sessions ? t("usage.running", { r: o.running, n: o.sessions }) : <span className="text-muted-foreground">—</span>}</Field>
          <Field k="usage.d.subs">
            {o?.subs?.length ? <span className="font-mono text-xs">{o.subs.map(subName).join(", ")}</span> : <span className="text-muted-foreground">—</span>}
          </Field>
          <Field k="usage.d.logins">
            {o?.logins?.length ? (
              <span className="grid gap-0.5 font-mono text-xs">
                {o.logins.map(([host, login]) => (
                  <span key={`${host}/${login}`}>
                    {host} · {login}
                  </span>
                ))}
              </span>
            ) : (
              <span className="text-muted-foreground">—</span>
            )}
          </Field>
        </dl>

        <Separator />
        {err ? (
          <p className="font-mono text-xs text-destructive">{err}</p>
        ) : !u ? (
          <div className="grid gap-2" aria-label={t("usage.d.loading")}>
            <Skeleton className="h-4 w-32" />
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-3 w-4/5" />
          </div>
        ) : (
          <>
            {u.models.length > 0 && (
              <section className="grid gap-3">
                <h3 className="font-display text-base font-semibold">{t("usage.d.models")}</h3>
                <Bars items={u.models.slice(0, 5).map((m) => [m.name || m.provider, m.tokens])} />
              </section>
            )}
            {u.by_session.some((s) => s.week > 0) && (
              <section className="grid gap-3">
                <h3 className="font-display text-base font-semibold">{t("usage.d.bySession")}</h3>
                <Bars items={u.by_session.filter((s) => s.week > 0).slice(0, 6).map((s) => [s.kind === "none" ? t("usage.noSession") : s.key || s.worker_id || "—", s.week])} />
              </section>
            )}
          </>
        )}
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        <Button variant="outline" onClick={onSessions}>
          {t("usage.d.seeSessions")}
        </Button>
      </SheetFooter>
    </>
  );
}

// ── all sessions ──
const sessionColumns: ColumnDef<SessionRow, any>[] = [
  {
    accessorKey: "key",
    header: () => t("usage.col.session"),
    cell: ({ row: { original: r } }) => (
      <div className="grid min-w-0 gap-0.5">
        <span className="font-mono text-xs font-medium">{r.key}</span>
        {r.title && <span className="max-w-64 truncate text-xs text-muted-foreground">{r.title}</span>}
      </div>
    ),
  },
  { accessorKey: "repo", header: () => t("usage.col.repo"), cell: ({ getValue }) => <span className="font-mono text-xs">{getValue() || "—"}</span> },
  {
    accessorKey: "state",
    header: () => t("usage.col.state"),
    cell: ({ row: { original: r } }) => (
      <div className="grid gap-1">
        <StateBadge s={r.state} />
        {r.ask && <span className="max-w-56 truncate text-xs text-muted-foreground" title={r.ask}>{r.ask}</span>}
      </div>
    ),
  },
  // one row style wherever the session runs (EPIC #3923 拍板 13): the machine is plain text
  {
    accessorKey: "machine",
    header: () => t("usage.col.machine"),
    cell: ({ row: { original: r } }) => (
      <span className="inline-flex items-center gap-2">
        <span className="font-mono text-xs">{r.machine || "—"}</span>
        <AvailBadge a={r.availability} />
      </span>
    ),
  },
  { accessorKey: "person", header: () => t("usage.col.person"), cell: ({ getValue }) => getValue() || <span className="text-muted-foreground">—</span> },
  { accessorKey: "tokens", header: () => t("usage.col.today"), cell: ({ getValue }) => (getValue() ? num(getValue()) : <span className="text-muted-foreground">—</span>) },
  { accessorKey: "born", header: () => t("usage.col.started"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue() ? ago(new Date(getValue() * 1000).toISOString()) : "—"}</span> },
];

const sessionFilters: Filter<SessionRow>[] = [
  { key: "working", label: t("usage.filter.working"), test: (r) => STATES[r.state].group === "working" },
  { key: "waiting", label: t("usage.filter.waiting"), test: (r) => STATES[r.state].group === "waiting" },
  { key: "idle", label: t("usage.filter.idle"), test: (r) => STATES[r.state].group === "idle" },
];

function CmdBox({ cmd }: { cmd: string }) {
  return (
    <div className="flex items-center gap-2 rounded-lg border bg-muted/40 px-3 py-2">
      <code className="min-w-0 flex-1 truncate font-mono text-xs">{cmd}</code>
      <Button
        variant="ghost"
        size="icon"
        className="size-7"
        aria-label={t("new.copy")}
        onClick={() => navigator.clipboard?.writeText(cmd).then(() => toast.success(t("usage.copied")))}
      >
        <Copy className="size-3.5" />
      </Button>
    </div>
  );
}

function SessionDrawer({ r }: { r: SessionRow }) {
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-mono text-lg">{r.key}</SheetTitle>
        <SheetDescription>{r.title || r.repo || "—"}</SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <div className="flex flex-wrap items-center gap-2">
          <StateBadge s={r.state} />
          <AvailBadge a={r.availability} />
        </div>
        {r.ask && <p className="rounded-lg border border-warn/40 px-3 py-2 text-sm">{t("usage.ses.ask", { msg: r.ask })}</p>}
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="usage.col.repo">
            <span className="font-mono text-xs">{r.repo || "—"}</span>
          </Field>
          <Field k="usage.col.machine">
            <span className="font-mono text-xs">{r.machine || "—"}</span>
          </Field>
          <Field k="usage.col.person">{r.person || "—"}</Field>
          <Field k="usage.ses.agent">{r.agent || "—"}</Field>
          <Field k="usage.ses.todayTokens">{r.tokens ? num(r.tokens) : "—"}</Field>
          <Field k="usage.col.started">{r.born ? fmtWhen(r.born * 1000) : "—"}</Field>
          {r.worktree && (
            <Field k="usage.ses.worktree">
              <span className="font-mono text-xs break-all">{r.worktree}</span>
            </Field>
          )}
        </dl>
        {STATES[r.state].group === "waiting" && (
          <section className="grid gap-2">
            <h3 className="font-display text-base font-semibold">{t("usage.ses.answer")}</h3>
            <CmdBox cmd={`fleet answer ${r.key}`} />
          </section>
        )}
        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("usage.ses.attach")}</h3>
          <CmdBox cmd={`fleet connect ${r.machine}`} />
          <p className="text-xs text-muted-foreground">{t("usage.ses.attachHint", { m: r.machine, key: r.key })}</p>
        </section>
      </div>
    </>
  );
}

// ── by machine ──
const machineColumns: ColumnDef<MachineRow, any>[] = [
  {
    accessorKey: "node",
    header: () => t("usage.col.machine"),
    cell: ({ row: { original: m } }) => (
      <span className="inline-flex items-center gap-2">
        <span className="font-mono text-xs font-medium">{m.node || t("usage.noMachine")}</span>
        <AvailBadge a={m.availability} />
      </span>
    ),
  },
  { accessorKey: "today", header: () => t("usage.col.today"), cell: ({ getValue }) => num(getValue()) },
  { accessorKey: "week", header: () => t("usage.col.week"), cell: ({ getValue }) => num(getValue()) },
  { accessorKey: "people", header: () => t("usage.col.people"), cell: ({ getValue }) => <span className="tabular-nums">{getValue() || "—"}</span> },
  {
    accessorKey: "sessions",
    header: () => t("usage.col.sessions"),
    cell: ({ row: { original: m } }) => (m.sessions ? <span className="tabular-nums">{t("usage.running", { r: m.running, n: m.sessions })}</span> : <span className="text-muted-foreground">—</span>),
  },
];

// ── 试用: one Beijing day of the trial identities ──
type TrialRow = TrialSpendPerson & { id: string };

// bjDay is the Beijing date d days from now, YYYY-MM-DD.
const bjDay = (d = 0) => new Date(Date.now() + 8 * 3_600_000 + d * 86_400_000).toISOString().slice(0, 10);
const shiftDay = (day: string, d: number) => new Date(Date.parse(day + "T00:00:00Z") + d * 86_400_000).toISOString().slice(0, 10);
const peopleN = (n: number) => t(n === 1 ? "usage.trial.person" : "usage.trial.people", { n });

function trialWhen(day: string) {
  if (day === bjDay(-1)) return t("usage.trial.yesterday");
  if (day === bjDay()) return t("usage.trial.today");
  return day;
}

function TrialState({ r }: { r: TrialRow }) {
  return (
    <div className="flex flex-wrap gap-1">
      {r.over && (
        <Badge variant="outline" className="border-destructive/50 font-normal text-destructive">
          {t("usage.trial.st.over")}
        </Badge>
      )}
      {r.new && (
        <Badge variant="outline" className="border-clay-line bg-clay-soft font-normal text-clay">
          {t("usage.trial.st.new")}
        </Badge>
      )}
      {!r.new && (
        <Badge variant="outline" className={cn("font-normal", r.active ? "border-ok/40 text-ok" : "text-muted-foreground")}>
          {t(r.active ? "usage.trial.st.active" : "usage.trial.st.ended")}
        </Badge>
      )}
    </div>
  );
}

const trialColumns: ColumnDef<TrialRow, any>[] = [
  { accessorKey: "name", header: () => t("usage.col.person"), cell: ({ getValue }) => <span className="font-medium">{getValue()}</span> },
  {
    accessorKey: "trial_day",
    header: () => t("usage.col.trialDay"),
    cell: ({ getValue }) => (getValue() ? <span className="tabular-nums">{t("usage.trial.dayN", { n: getValue() })}</span> : <span className="text-muted-foreground">—</span>),
  },
  { accessorKey: "tokens", header: () => t("usage.col.tokens"), cell: ({ getValue }) => num(getValue()) },
  { accessorKey: "pool", header: () => t("usage.col.pool"), cell: ({ getValue }) => num(getValue()) },
  { accessorKey: "byo", header: () => t("usage.col.byo"), cell: ({ getValue }) => num(getValue()) },
  { id: "state", accessorFn: (r) => (r.over ? 2 : r.new ? 1 : 0), header: () => t("usage.col.trialState"), cell: ({ row }) => <TrialState r={row.original} /> },
];

const trialFilters: Filter<TrialRow>[] = [
  { key: "over", label: t("usage.filter.over"), test: (r) => r.over },
  { key: "new", label: t("usage.filter.new"), test: (r) => r.new },
];

// ── by model ──
const modelColumns: ColumnDef<ModelRow, any>[] = [
  { accessorKey: "name", header: () => t("usage.col.model"), cell: ({ row: { original: m } }) => <span className="font-medium">{m.name || "—"}</span> },
  { accessorKey: "provider", header: () => t("usage.col.provider"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue() === "codex" ? "Codex" : "Claude"}</span> },
  { accessorKey: "tokens", header: () => t("usage.col.week"), cell: ({ getValue }) => num(getValue()) },
  {
    accessorKey: "share",
    header: () => t("usage.col.share"),
    cell: ({ getValue }) => (
      <div className="flex items-center gap-2">
        <Progress value={getValue()} className="h-1.5 w-24" />
        <span className="font-mono text-xs text-muted-foreground tabular-nums">{getValue()}%</span>
      </div>
    ),
  },
];

const modelFilters: Filter<ModelRow>[] = [
  { key: "claude", label: t("usage.filter.claude"), test: (m) => m.provider !== "codex" },
  { key: "codex", label: t("usage.filter.codex"), test: (m) => m.provider === "codex" },
];
