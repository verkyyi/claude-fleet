// MachineDetail — one machine, /admin/machines/:host (EPIC #3923 C11; the old
// /app/machines/<host> moves here — one machine's details are the admin's,
// 拍板 2). On one page: its state and the two writes the list had per card
// (维护 / 结束维护 behind today's confirm, 移除), 负载与内存 (its trend as a
// shadcn Chart), 版本与更新, 安装 (#2697: runtime · login installs · client
// shells, each against stable), 门与连接, 登录账号, 会话, 服务与定时任务 (a row's
// Sheet: its actions and its live log) and which subscriptions its sessions may
// use. Reads /v1/nodes/<host> (re-read every 10 s while the tab is shown),
// /v1/nodes (its door and endpoints), /version, /v1/fleet/ci-runners; writes
// fleet.node_maintenance.<machine>, /v1/fleet/nodes/retire,
// /v1/fleet/service_control, /v1/fleet/cred-policy — every one audited.
import * as React from "react";
import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from "recharts";
import { AlertCircle, ArrowLeft, Trash2, Wrench } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { ChartContainer, ChartTooltip, ChartTooltipContent, type ChartConfig } from "@/components/ui/chart";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";
import { api, ApiError } from "../api";
import { ParkSummary } from "../machines/ParkSummary";
import { lang } from "../i18n";
import { ago, t as ta } from "../i18n";
import { tm, type MKey } from "../machines/i18n";
import {
  components,
  firstLabel,
  gb,
  machineRows,
  serviceRows,
  sessionState,
  short,
  type CIRunner,
  type InstallItem,
  type MachineRow,
  type NodeDetail,
  type NodesSnapshot,
  type ServiceRow,
  type VersionInfo,
} from "../machines/model";
import { PolicyEditor } from "./PolicyEditor";
import { DoorText, kindText, StatusBadge } from "./Machines";
import { ServiceSheet, svcStateWord } from "./ServiceSheet";

type State = { d: NodeDetail; row: MachineRow | null; runner: CIRunner | null; stable: string; nodeId: string | null | undefined };

export function MachineDetailPage() {
  const { host = "" } = useParams();
  const name = decodeURIComponent(host);
  const nav = useNavigate();
  const [st, setSt] = React.useState<State | null>(null);
  const [err, setErr] = React.useState<{ msg: string; missing: boolean } | null>(null);
  const [svc, setSvc] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    try {
      const [d, snap, ver, runners] = await Promise.all([
        api<NodeDetail>("/v1/nodes/" + encodeURIComponent(name)),
        api<NodesSnapshot>("/v1/nodes").catch(() => null),
        api<VersionInfo>("/version").catch(() => null),
        api<{ runners: CIRunner[] }>("/v1/fleet/ci-runners").catch(() => null),
      ]);
      if (d.machine?.role === "client") {
        // a client device has no machine page: its place is the 客户端 tab
        nav("/machines?tab=clients", { replace: true });
        return;
      }
      const row = snap ? machineRows(snap, ver).find((r) => firstLabel(r.host).toLowerCase() === firstLabel(d.machine.hostname).toLowerCase()) || null : null;
      const runner = (runners?.runners || []).find((r) => firstLabel(r.machine).toLowerCase() === firstLabel(d.machine.hostname).toLowerCase()) || null;
      setSt((old) => ({ d, row, runner, stable: short(ver?.stable || ver?.client_version), nodeId: old?.nodeId }));
      setErr(null);
    } catch (e) {
      setErr({ msg: (e as Error).message, missing: e instanceof ApiError && e.status === 404 });
    }
  }, [name, nav]);

  React.useEffect(() => {
    setSt(null);
    void load();
    const t = setInterval(() => {
      if (!document.hidden) void load();
    }, 10_000);
    return () => clearInterval(t);
  }, [load]);

  // The machine's identity for its subscription rule (cred-policy's
  // machineTargets): one answer from its endpoints, else none.
  const eps = st?.row?.policyEps.join(" ") || "";
  React.useEffect(() => {
    if (!st || st.nodeId !== undefined) return;
    const list = eps ? eps.split(" ") : [];
    Promise.allSettled(list.map((ep) => api<{ effective?: { machine?: string } }>("/v1/fleet/cred-policy?endpoint_id=" + encodeURIComponent(ep)))).then((as) => {
      const ids = [...new Set(as.map((a) => (a.status === "fulfilled" ? a.value.effective?.machine : "")).filter(Boolean))] as string[];
      const bad = as.some((a) => a.status === "rejected" || !a.value.effective?.machine);
      setSt((old) => (old ? { ...old, nodeId: !bad && ids.length === 1 ? ids[0] : null } : old));
    });
  }, [st, eps]);

  const back = (
    <Button variant="ghost" size="sm" asChild className="-ml-2 w-fit text-muted-foreground">
      <Link to="/machines">
        <ArrowLeft />
        {tm("d.back")}
      </Link>
    </Button>
  );

  if (err && !st) {
    return (
      <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 p-6 md:p-8">
        {back}
        {err.missing ? (
          <div className="flex flex-col items-center gap-2 rounded-xl border p-12 text-center">
            <p className="font-display text-xl font-semibold">{tm("d.none", { m: name })}</p>
            <p className="text-sm text-muted-foreground">{tm("d.noneSub")}</p>
            <Button variant="outline" asChild className="mt-2">
              <Link to="/machines">{tm("d.backList")}</Link>
            </Button>
          </div>
        ) : (
          <Alert variant="destructive">
            <AlertCircle />
            <AlertTitle>{ta("state.error")}</AlertTitle>
            <AlertDescription className="flex flex-wrap items-center gap-3">
              <span className="font-mono text-xs">{err.msg}</span>
              <Button size="sm" variant="outline" onClick={() => void load()}>
                {ta("state.retry")}
              </Button>
            </AlertDescription>
          </Alert>
        )}
      </div>
    );
  }

  if (!st) {
    return (
      <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 p-6 md:p-8">
        {back}
        <Skeleton className="h-9 w-56" />
        <div className="grid gap-4 lg:grid-cols-3">
          <Skeleton className="h-64 lg:col-span-2" />
          <Skeleton className="h-64" />
        </div>
        <Skeleton className="h-48" />
      </div>
    );
  }

  const { d, row } = st;
  const m = d.machine;
  const id = firstLabel(m.hostname);
  const label = m.alias || id;
  const svcs = serviceRows(m.hostname, d.services);
  const open = svcs.find((s) => s.id === svc) || null;

  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 p-6 md:p-8">
      {back}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="font-display text-3xl font-semibold tracking-tight">
              <span className="font-mono">{label}</span>
              <span className="text-primary">.</span>
            </h1>
            {row && <StatusBadge r={row} />}
            {row && (
              <Badge variant="secondary" className="font-normal">
                {kindText(row.kind)}
              </Badge>
            )}
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {label !== id && <span className="mr-2 font-mono text-xs">{id}</span>}
            {m.maintenance
              ? tm("maint.why", { reason: m.maintenance.reason || "—", by: m.maintenance.by || "—", when: ago(m.maintenance.since) || "—" })
              : tm("d.seen", { when: ago(m.last_heartbeat || undefined) || "—" })}
          </p>
        </div>
        <div className="flex gap-2">
          <MaintButton id={id} label={label} status={m.status} maintained={!!m.maintenance} sessions={m.sessions} onDone={load} />
          {!!row?.eps.length && <RemoveButton label={label} eps={row.eps} sessions={m.sessions} onDone={() => nav("/machines")} />}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <LoadCard d={d} lost={m.status === "lost"} />
        <VersionCard d={d} row={row} stable={st.stable} />
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <LoginsCard d={d} />
        <DoorCard d={d} row={row} runner={st.runner} />
      </div>

      <InstallsCard d={d} />

      <SessionsCard d={d} />

      <Card className="gap-0 pb-0">
        <CardHeader className="border-b pb-4">
          <CardTitle className="font-display text-base">{tm("d.services")}</CardTitle>
          <CardAction>
            <Fresh at={d.services_at} />
          </CardAction>
        </CardHeader>
        {svcs.length ? (
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                {(["svc.kind", "svc.login", "svc.name", "svc.state", "svc.last", "svc.next", "svc.line"] as MKey[]).map((k) => (
                  <TableHead key={k} className="h-10 px-4">
                    {tm(k)}
                  </TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {svcs.map((s) => (
                <TableRow key={s.id} className="cursor-pointer" data-state={s.id === svc ? "selected" : undefined} onClick={() => setSvc(s.id)}>
                  <TableCell className="px-4 text-muted-foreground">{tm(s.kind === "task" ? "svc.task" : "svc.service")}</TableCell>
                  <TableCell className="px-4 font-mono text-xs">{s.login}</TableCell>
                  <TableCell className="px-4 font-mono text-xs font-medium">{s.name}</TableCell>
                  <TableCell className="px-4">
                    <SvcBadge s={s} />
                  </TableCell>
                  <TableCell className="px-4 text-muted-foreground">{ago(s.lastRun || undefined) || "—"}</TableCell>
                  <TableCell className="px-4 text-muted-foreground">{s.nextRun ? new Date(s.nextRun).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—"}</TableCell>
                  <TableCell className={cn("max-w-64 truncate px-4 font-mono text-xs", s.failed ? "text-destructive" : "text-muted-foreground")} title={s.line}>
                    {s.line || "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <CardContent className="py-8 text-center text-sm text-muted-foreground">{tm("d.noServices")}</CardContent>
        )}
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="font-display text-base">{tm("d.policy")}</CardTitle>
          <CardDescription>{tm("d.policyLead")}</CardDescription>
        </CardHeader>
        <CardContent>
          {st.nodeId === undefined ? (
            <Skeleton className="h-24 w-full" />
          ) : st.nodeId ? (
            <PolicyEditor id={st.nodeId} scope="node" bare />
          ) : (
            <p className="text-sm text-muted-foreground">{tm("d.policyUnknown")}</p>
          )}
        </CardContent>
      </Card>

      <Sheet open={!!open} onOpenChange={(o) => !o && setSvc(null)}>
        <SheetContent className="w-full gap-0 overflow-y-auto sm:max-w-xl">
          {open && <ServiceSheet r={open} machine={label} close={() => setSvc(null)} reload={load} />}
        </SheetContent>
      </Sheet>
    </div>
  );
}

// ---- pieces -----------------------------------------------------------------

// warnAfter: a reading taken on a slower clock (安装, every 5 min) warns later.
function Fresh({ at, warnAfter = 60 }: { at: string | null | undefined; warnAfter?: number }) {
  if (!at) return <span className="text-xs text-muted-foreground">{tm("d.unknownTime")}</span>;
  const age = (Date.now() - Date.parse(at)) / 1000;
  return <span className={cn("text-xs", age > Math.max(300, warnAfter * 2) ? "text-muted-foreground/60" : age > warnAfter ? "text-warn" : "text-muted-foreground")}>{tm("d.measured", { when: ago(at) })}</span>;
}

function SvcBadge({ s }: { s: ServiceRow }) {
  return (
    <Badge
      variant="outline"
      className={cn(
        "font-normal",
        s.failed ? "border-destructive/50 text-destructive" : s.state === "running" || s.state === "ok" ? "border-ok/40 text-ok" : s.state === "retrying" ? "border-warn/50 text-warn" : "text-muted-foreground",
      )}
    >
      {svcStateWord(s)}
    </Badge>
  );
}

function Stat({ value, label, warn }: { value: React.ReactNode; label: string; warn?: boolean }) {
  return (
    <div>
      <p className={cn("font-display text-2xl font-semibold tabular-nums", warn && "text-warn")}>{value}</p>
      <p className="text-xs text-muted-foreground">{label}</p>
    </div>
  );
}

const chartConfig = { load: { label: tm("d.loadSeries"), color: "var(--primary)" } } satisfies ChartConfig;

function LoadCard({ d, lost }: { d: NodeDetail; lost: boolean }) {
  const l = d.load;
  const hist = Array.isArray(l.hist) ? l.hist : [];
  const step = Number(l.hist_step_sec) || 300;
  const data = hist.map((v, i) => ({ min: -Math.round(((hist.length - 1 - i) * step) / 60), load: Number(v.toFixed(2)) }));
  const per = l.ncpu > 0 ? l.now / l.ncpu : null;
  const peak = hist.length ? Math.max(...hist) : null;
  const total = gb(d.mem.total);
  const used = gb(d.mem.used);
  const shortMin = hist.length && hist.length * step < 7200 - step ? Math.round(((hist.length - 1) * step) / 60) : null;
  return (
    <Card className="lg:col-span-2">
      <CardHeader>
        <CardTitle className="font-display text-base">{tm("d.load")}</CardTitle>
        <CardAction>
          <Fresh at={l.at} />
        </CardAction>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div className="grid grid-cols-3 gap-4">
          <Stat value={per == null || lost ? "—" : per.toFixed(2)} label={tm("d.perCore", { n: l.ncpu || "?" })} warn={(per ?? 0) >= 1} />
          <Stat value={peak == null ? "—" : peak.toFixed(2)} label={tm("d.peak")} />
          <Stat
            value={total > 0 ? `${used.toFixed(used < 10 ? 1 : 0)}/${total.toFixed(0)} GB` : "—"}
            label={tm("d.mem") + (d.mem.pressure == null ? "" : ` · ${Math.round(d.mem.pressure * 100)}%`)}
          />
        </div>
        <ParkSummary reading={d.machine} lang={lang} />
        {data.length ? (
          <ChartContainer config={chartConfig} className="aspect-auto h-40 w-full">
            <AreaChart data={data} margin={{ left: 0, right: 8, top: 8, bottom: 0 }}>
              <defs>
                <linearGradient id="fillLoad" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor={lost ? "var(--destructive)" : "var(--color-load)"} stopOpacity={0.35} />
                  <stop offset="95%" stopColor={lost ? "var(--destructive)" : "var(--color-load)"} stopOpacity={0.02} />
                </linearGradient>
              </defs>
              <CartesianGrid vertical={false} />
              <XAxis dataKey="min" tickLine={false} axisLine={false} tickMargin={8} minTickGap={32} tickFormatter={(v) => (v === 0 ? tm("d.now") : `${v}m`)} />
              <YAxis tickLine={false} axisLine={false} width={40} tickMargin={4} tickFormatter={(v: number) => v.toFixed(2).replace(/0$/, "")} />
              <ChartTooltip cursor={false} content={<ChartTooltipContent indicator="line" labelFormatter={(_, p) => `${p?.[0]?.payload?.min ?? ""} min`} />} />
              <Area dataKey="load" type="monotone" stroke={lost ? "var(--destructive)" : "var(--color-load)"} strokeWidth={2} fill="url(#fillLoad)" isAnimationActive={false} />
            </AreaChart>
          </ChartContainer>
        ) : (
          <p className="py-10 text-center text-sm text-muted-foreground">{tm("d.noTrend")}</p>
        )}
        {shortMin != null && <p className="text-xs text-muted-foreground">{tm("d.trendShort", { n: shortMin })}</p>}
        {!!l.unread?.length && <p className="text-xs text-warn">{tm("d.unread", { what: l.unread.join(" · ") })}</p>}
      </CardContent>
    </Card>
  );
}

function KV({ k, children }: { k: string; children: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{k}</dt>
      <dd className="min-w-0 break-words">{children}</dd>
    </>
  );
}

// rollText: a person's pod's image against stable, and the hub's last roll (claude-fleet#4174).
function rollText(r: NonNullable<NodeDetail["version"]["roll"]>): string {
  const parts: string[] = [];
  if (r.behind === 0) parts.push(tm("d.rollOn"));
  else if (r.behind === -1) parts.push(tm("d.rollUnknown"));
  else if (r.behind) parts.push(tm("d.rollBehind", { n: r.behind }));
  const l = r.last;
  if (l) parts.push(l.pending ? tm("d.rollPending") : l.done ? tm("d.rollDone", { v: short(l.stable) }) : tm("d.rollFailed"));
  return parts.join(" · ") || "—";
}

function VersionCard({ d, row, stable }: { d: NodeDetail; row: MachineRow | null; stable: string }) {
  const v = d.version;
  const pair = (n?: number, rel?: string) => (n ? `v${n}${rel ? " · " + short(rel) : ""}` : "—");
  const off = !!v.want && (v.want !== v.reached || !!v.diff);
  const comps = components(v);
  const reported = !!(comps.length || v.phase || v.at);
  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-display text-base">{tm("d.version")}</CardTitle>
        <CardAction>
          <Fresh at={v.at} />
        </CardAction>
      </CardHeader>
      <CardContent>
        <dl className="grid grid-cols-[6.5rem_1fr] gap-x-3 gap-y-2 text-sm">
          <KV k={tm("d.runtime")}>
            <span className={cn("font-mono text-xs", row?.behind && "text-warn")}>{short(v.runtime) || row?.version || "—"}</span>
          </KV>
          <KV k={tm("d.stable")}>
            <span className="font-mono text-xs">{stable || "—"}</span>
          </KV>
          {v.roll && (
            <KV k={tm("d.roll")}>
              <span className={cn("text-xs", !!v.roll.behind && "text-warn")} title={v.roll.last?.result || ""}>
                {rollText(v.roll)}
              </span>
            </KV>
          )}
          <KV k={tm("d.agent")}>
            <span className="font-mono text-xs">{v.agent || "—"}</span>
          </KV>
          <KV k={tm("d.fleet")}>
            <span className="font-mono text-xs">{short(v.fleet) || "—"}</span>
          </KV>
          {(!!v.want || !!v.reached) && (
            <>
              <KV k={tm("d.want")}>
                <span className="font-mono text-xs">{pair(v.want, v.want_release)}</span>
              </KV>
              <KV k={tm("d.reached")}>
                <span className={cn("font-mono text-xs", off && "text-warn")} title={v.diff || ""}>
                  {pair(v.reached, v.release)}
                </span>
              </KV>
            </>
          )}
          {reported && !!comps.length && (
            <KV k={tm("d.comps")}>
              <span className="flex flex-col gap-0.5 font-mono text-xs">
                {comps.map((c) => (
                  <span key={c.name} className={cn(c.off && "text-warn")}>
                    {c.name} {c.have || "—"}
                    {c.off && ` → ${c.want}`}
                  </span>
                ))}
              </span>
            </KV>
          )}
          <KV k={tm("d.update")}>
            {reported ? (
              <span>
                {[v.phase, v.result].filter(Boolean).join(" · ") || "—"}
                {v.reason && <span className="block text-xs text-muted-foreground">{v.reason}</span>}
              </span>
            ) : (
              <span className="text-muted-foreground">{tm("d.tooOld")}</span>
            )}
          </KV>
        </dl>
      </CardContent>
    </Card>
  );
}

function dur(secs: number): string {
  const m = Math.floor(secs / 60);
  if (m < 120) return tm("d.dur.m", { n: m });
  if (m < 2880) return tm("d.dur.h", { h: Math.floor(m / 60), m: m % 60 });
  return tm("d.dur.d", { n: Math.floor(m / 1440) });
}

function InstState({ it }: { it: InstallItem }) {
  if (it.at_stable === true)
    return (
      <Badge variant="outline" className="border-ok/40 font-normal text-ok">
        {tm("d.inst.at")}
      </Badge>
    );
  if (it.at_stable === false)
    return (
      <Badge variant="outline" className="border-warn/50 font-normal text-warn">
        {it.behind_secs != null ? tm("d.inst.behindFor", { d: dur(it.behind_secs) }) : tm("d.inst.behind")}
      </Badge>
    );
  return (
    <Badge variant="outline" className="font-normal text-muted-foreground">
      {tm("d.inst.unknown")}
    </Badge>
  );
}

const srcKey: Record<string, MKey> = {
  hub: "d.inst.src.hub",
  runtime: "d.inst.src.runtime",
  github: "d.inst.src.github",
  dev: "d.inst.src.dev",
};

// 安装 (claude-fleet#2697): what each heartbeat's fleet-installs.sh read, one
// row per install, judged by the hub against the stable it follows.
function InstallsCard({ d }: { d: NodeDetail }) {
  const ins = d.machine.installs;
  type Row = { what: MKey; login: string; it: InstallItem; note?: string };
  const rows: Row[] = [];
  if (ins?.runtime) rows.push({ what: "d.inst.runtime", login: "—", it: ins.runtime });
  for (const l of ins?.logins || []) {
    if (l.install) rows.push({ what: "d.inst.install", login: l.login, it: l.install, note: l.install.kind === "dir" ? tm("d.inst.plain") : undefined });
    if (l.shell) rows.push({ what: "d.inst.shell", login: l.login, it: l.shell, note: tm(l.shell.follows ? "d.inst.follows" : "d.inst.pinned") });
    if (l.client) rows.push({ what: "d.inst.client", login: l.login, it: l.client });
  }
  const ok = rows.filter((r) => r.it.at_stable === true).length;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-display text-base">{tm("d.installs")}</CardTitle>
        <CardDescription>
          {tm("d.installsLead")}
          {!!rows.length && (
            <span className={cn("mt-1 block", ok < rows.length && "text-warn")}>
              {ins?.stable ? tm("d.installsSum", { ok, n: rows.length, s: short(ins.stable) }) : tm("d.installsSumNo")}
            </span>
          )}
        </CardDescription>
        <CardAction>
          <Fresh at={ins?.at} warnAfter={900} />
        </CardAction>
      </CardHeader>
      <CardContent>
        {!rows.length ? (
          <p className="text-sm text-muted-foreground">{tm("d.installsNone")}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{tm("d.inst.what")}</TableHead>
                <TableHead className="hidden sm:table-cell">{tm("d.inst.login")}</TableHead>
                <TableHead>{tm("d.inst.version")}</TableHead>
                <TableHead className="hidden sm:table-cell">{tm("d.inst.source")}</TableHead>
                <TableHead>{tm("d.inst.state")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r, i) => (
                <TableRow key={i}>
                  <TableCell>
                    {tm(r.what)}
                    {r.login !== "—" && <span className="block font-mono text-xs text-muted-foreground sm:hidden">{r.login}</span>}
                    {r.note && <span className="block text-xs text-muted-foreground">{r.note}</span>}
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs sm:table-cell">{r.login}</TableCell>
                  <TableCell className={cn("font-mono text-xs", r.it.at_stable === false && "text-warn")}>{short(r.it.version) || "—"}</TableCell>
                  <TableCell className="hidden text-muted-foreground sm:table-cell">{tm(srcKey[r.it.source || ""] || "d.inst.src.unknown")}</TableCell>
                  <TableCell>
                    <InstState it={r.it} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}

function LoginsCard({ d }: { d: NodeDetail }) {
  const refusedOf = (u: string) => (d.machine.logins_refused || {})[u] || "";
  return (
    <Card className="gap-0 pb-0 lg:col-span-2">
      <CardHeader className="border-b pb-4">
        <CardTitle className="font-display text-base">{tm("d.logins")}</CardTitle>
        <CardAction>
          <Fresh at={d.logins_at} />
        </CardAction>
      </CardHeader>
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <TableHead className="h-10 px-4">{tm("d.login")}</TableHead>
            <TableHead className="h-10 px-4">{tm("d.state")}</TableHead>
            <TableHead className="h-10 px-4 text-right">{tm("col.sessions")}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {d.logins.map((n) => {
            const u = n.os_user || "";
            const ref = (n.logins_refused || {})[u] || refusedOf(u);
            return (
              <TableRow key={(n.endpoint_id || "") + u} className="hover:bg-transparent">
                <TableCell className="px-4 font-mono text-xs font-medium">{u || (n.machine_link ? "—" : "?")}</TableCell>
                <TableCell className="px-4">
                  <div className="flex flex-wrap gap-1.5">
                    {ref ? (
                      <Badge variant="outline" className="border-destructive/50 font-normal text-destructive" title={ref}>
                        {tm("d.refusedChip")}
                      </Badge>
                    ) : (
                      <StatusBadge r={{ status: n.status === "online" ? "online" : n.status === "maintenance" ? "maintenance" : "lost" }} />
                    )}
                    {n.admit === false && (
                      <Badge variant="outline" className="border-warn/50 font-normal text-warn" title={n.admit_why || ""}>
                        {tm("d.paused")}
                      </Badge>
                    )}
                  </div>
                </TableCell>
                <TableCell className="px-4 text-right font-mono text-xs tabular-nums">{n.sessions == null ? "?" : n.sessions}</TableCell>
              </TableRow>
            );
          })}
          {!!d.other_logins && (
            <TableRow className="hover:bg-transparent">
              <TableCell colSpan={3} className="px-4 text-xs text-muted-foreground">
                {tm("d.others", { n: d.other_logins })}
              </TableCell>
            </TableRow>
          )}
          {!d.logins.length && !d.other_logins && (
            <TableRow className="hover:bg-transparent">
              <TableCell colSpan={3} className="px-4 text-muted-foreground">
                —
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </Card>
  );
}

function DoorCard({ d, row, runner }: { d: NodeDetail; row: MachineRow | null; runner: CIRunner | null }) {
  const m = d.machine;
  const trust = d.logins.find((n) => n.trust === "trusted") || d.logins.find((n) => n.trust);
  const refused = Object.keys(m.logins_refused || {}).sort();
  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-display text-base">{tm("d.doorTitle")}</CardTitle>
      </CardHeader>
      <CardContent>
        <dl className="grid grid-cols-[6.5rem_1fr] gap-x-3 gap-y-2 text-sm">
          <KV k={tm("d.door")}>{row ? <DoorText d={row.door} /> : "—"}</KV>
          {trust?.trust && (
            <KV k={tm("d.trust")}>
              <span className={cn(trust.trust_source === "name_borrowed" && "text-destructive")}>
                {trust.trust_source
                  ? tm("d.trustFrom", { trust: tm(trust.trust === "trusted" ? "d.trusted" : "d.untrusted"), src: tm(`d.trustSrc.${trust.trust_source}` as MKey) })
                  : tm(trust.trust === "trusted" ? "d.trusted" : "d.untrusted")}
              </span>
            </KV>
          )}
          {m.links != null && m.status !== "lost" && (
            <KV k={tm("d.linksK")}>
              <span className="text-xs">{tm("d.links", { n: m.links, logins: (row?.logins || []).join("、") || "—" })}</span>
            </KV>
          )}
          {typeof m.spare === "number" && (
            <KV k={tm("d.spareK")}>
              <span className="text-xs">{tm("d.spare", { n: m.spare, used: m.logins_used ?? "?", cap: m.login_cap ?? "?" })}</span>
            </KV>
          )}
          <KV k={tm("d.runner")}>
            {runner ? (
              <span className="flex flex-col">
                <span>
                  <Badge variant="outline" className={cn("font-normal", runner.online ? (runner.runner.state === "error" ? "text-destructive" : "text-ok") : "text-muted-foreground")}>
                    {runner.online ? runner.runner.state : tm("status.lost")}
                  </Badge>
                </span>
                <span className="mt-1 text-xs text-muted-foreground">
                  {tm("d.runnerRuns", { n: runner.runner.runs, f: runner.runner.failed })}
                  {runner.runner.why ? ` · ${runner.runner.why}` : ""}
                </span>
              </span>
            ) : (
              <span className="text-muted-foreground">{tm("d.runnerNone")}</span>
            )}
          </KV>
        </dl>
        {refused.map((l) => (
          <p key={l} className="mt-3 text-xs text-destructive" title={m.logins_refused![l]}>
            {tm("d.refused", { login: l })}
          </p>
        ))}
      </CardContent>
    </Card>
  );
}

function SessionsCard({ d }: { d: NodeDetail }) {
  const rows = (d.sessions || []).map((s) => {
    const w = s.worker || {};
    return { key: w.key || w.name || "—", title: w.title || w.name || "", repo: w.repo || "", state: sessionState(w.state), person: s.os_user || "", born: Number(w.born) || 0 };
  });
  const dot: Record<string, string> = { working: "bg-ok", needs: "bg-warn", done: "bg-muted-foreground/50", idle: "bg-muted-foreground/50", unknown: "bg-muted-foreground/30" };
  return (
    <Card className="gap-0 pb-0">
      <CardHeader className="border-b pb-4">
        <CardTitle className="font-display text-base">
          {tm("d.sessions")} <span className="ml-1 font-mono text-sm font-normal text-muted-foreground">{rows.length}</span>
        </CardTitle>
        <CardAction>
          <Fresh at={d.sessions_at} />
        </CardAction>
      </CardHeader>
      {rows.length ? (
        <div className="max-h-96 overflow-y-auto">
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead className="h-10 px-4">{tm("d.session")}</TableHead>
                <TableHead className="h-10 px-4">{tm("d.state")}</TableHead>
                <TableHead className="h-10 px-4">{tm("d.person")}</TableHead>
                <TableHead className="h-10 px-4 text-right">{tm("d.started")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r, i) => (
                <TableRow key={r.key + i} className="hover:bg-transparent">
                  <TableCell className="px-4">
                    <p className="font-mono text-xs font-medium">{r.key}</p>
                    <p className="max-w-md truncate text-xs text-muted-foreground">{r.title || r.repo || "—"}</p>
                  </TableCell>
                  <TableCell className="px-4">
                    <span className="inline-flex items-center gap-2 text-sm">
                      <span className={cn("size-2 rounded-full", dot[r.state])} />
                      {tm(`sess.${r.state}` as MKey)}
                    </span>
                  </TableCell>
                  <TableCell className="px-4 font-mono text-xs">{r.person || "—"}</TableCell>
                  <TableCell className="px-4 text-right font-mono text-xs text-muted-foreground tabular-nums">
                    {r.born ? new Date(r.born * (r.born < 1e12 ? 1000 : 1)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      ) : (
        <CardContent className="py-8 text-center text-sm text-muted-foreground">{tm("d.noSessions")}</CardContent>
      )}
    </Card>
  );
}

// ---- the two writes ------------------------------------------------------------

function MaintButton({
  id,
  label,
  status,
  maintained,
  sessions,
  onDone,
}: {
  id: string;
  label: string;
  status: string;
  maintained: boolean;
  sessions: number | null;
  onDone: () => void;
}) {
  const [reason, setReason] = React.useState(tm("maint.reasonDefault"));
  const put = async (value: string, ok: string) => {
    try {
      await api("/v1/fleet/settings", { method: "PUT", json: { key: "fleet.node_maintenance." + id, value } });
      toast.success(ok);
      onDone();
    } catch (e) {
      toast.error(tm("err.action", { e: (e as Error).message }));
    }
  };
  if (status === "maintenance" || (status === "lost" && maintained)) {
    return (
      <Button variant="outline" onClick={() => put("", tm("maint.left", { m: label }))}>
        <Wrench />
        {tm("maint.end")}
      </Button>
    );
  }
  if (status !== "online") return null;
  return (
    <AlertDialog onOpenChange={(o) => o && setReason(tm("maint.reasonDefault"))}>
      <AlertDialogTrigger asChild>
        <Button variant="outline">
          <Wrench />
          {tm("maint.btn")}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{tm("maint.q", { m: label })}</AlertDialogTitle>
          <AlertDialogDescription>{tm("maint.body", { n: sessions == null ? "?" : sessions })}</AlertDialogDescription>
        </AlertDialogHeader>
        <div className="grid gap-2">
          <Label htmlFor="mreason">{tm("maint.reason")}</Label>
          <Input id="mreason" maxLength={200} value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        <AlertDialogFooter>
          <AlertDialogCancel>{tm("confirm.cancel")}</AlertDialogCancel>
          <AlertDialogAction onClick={() => put(reason.trim() || tm("maint.reasonDefault"), tm("maint.entered", { m: label }))}>{tm("maint.ok")}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function RemoveButton({ label, eps, sessions, onDone }: { label: string; eps: string[]; sessions: number | null; onDone: () => void }) {
  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button variant="ghost" className="text-destructive hover:text-destructive">
          <Trash2 />
          {tm("remove.btn")}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{tm("remove.q", { m: label })}</AlertDialogTitle>
          <AlertDialogDescription>{tm("remove.body", { n: sessions == null ? "?" : sessions })}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{tm("confirm.cancel")}</AlertDialogCancel>
          <AlertDialogAction
            className="bg-destructive text-white hover:bg-destructive/90"
            onClick={async () => {
              try {
                for (const id of eps) await api("/v1/fleet/nodes/retire", { json: { endpoint_id: id, reason: "removed on the machines page" } });
                toast.success(tm("remove.done", { m: label }));
                onDone();
              } catch (e) {
                toast.error(tm("err.action", { e: (e as Error).message }));
              }
            }}
          >
            {tm("remove.btn")}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
