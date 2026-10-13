// Release — 发布, /admin/release and /admin/release/:run (EPIC #3923 C14; the
// old /app/trains moves here). One screen answers which version is live, how
// far the Macs trail and where the last train stuck: the train's numbers, the
// two lanes beside the keys that sign them, and every run of the last 7 days
// as one time bar (plain div widths — no chart library) whose row opens its
// merges and stage table. Only reads: /v1/fleet/release/stats (the ledger,
// #3870) · /version (the lanes) · /v1/fleet/release/keys (#3937, ids only).
// 手动发一趟 is a link to the workflow's own dispatch page — never a trigger here.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { ExternalLink, KeyRound, Rocket } from "lucide-react";
import { useNavigate, useParams } from "react-router";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type HubVersion, type ReleaseKeys, type ReleaseStats, type TrainRun } from "../api";
import { ago, t, when, type MsgKey } from "../i18n";

const DAYS = 7;
// the 5-minute budget a train is held to (the hub's trainSlowSecs)
const SLOW = 300;

const short = (sha?: string) => (sha ? sha.slice(0, 7) : "—");

function secs(s: number | null | undefined): string {
  if (s == null || !Number.isFinite(Number(s))) return "—";
  const n = Math.max(0, Math.round(Number(s)));
  const m = Math.floor(n / 60);
  return m ? t("rel.ms", { m, s: String(n % 60).padStart(2, "0") }) : t("rel.s", { s: n });
}

type State = "shipped" | "slow" | "superseded" | "failed";

function stateOf(r: TrainRun): State {
  if (r.conclusion === "failure" || r.conclusion === "cancelled") return "failed";
  if ((r.total_secs || 0) > SLOW) return "slow";
  if (r.conclusion === "superseded") return "superseded";
  return "shipped";
}

const STATE: Record<State, string> = {
  shipped: "border-ok/40 text-ok",
  slow: "border-warn/50 text-warn",
  superseded: "text-muted-foreground",
  failed: "border-destructive/50 text-destructive",
};

function StateBadge({ r }: { r: TrainRun }) {
  const s = stateOf(r);
  return (
    <Badge variant="outline" className={cn("font-normal", STATE[s])}>
      {t(`rel.state.${s}` as MsgKey)}
    </Badge>
  );
}

function whyOf(r: TrainRun): string {
  const b = r.bottleneck;
  if (!b) return "";
  return b.stage ? t("rel.why", { stage: b.stage, secs: secs(b.secs), why: b.why || "" }) : t("rel.whyNoStage", { why: b.why || "" });
}

// ── the time bar ─────────────────────────────────────────────────────────

type Kind = "board" | "lin" | "hub" | "rel" | "mac" | "other";

function kindOf(name: string): Kind {
  if (name === "board") return "board";
  if (name === "Linux") return "lin";
  if (name === "hub" || name === "hub plan") return "hub";
  if (name === "release") return "rel";
  if (name === "mac follow") return "mac";
  return "other";
}

const KIND: Record<Kind, string> = {
  board: "bg-muted-foreground/45",
  lin: "bg-clay",
  hub: "bg-sand ring-1 ring-inset ring-foreground/15",
  rel: "bg-ok",
  mac: "bg-foreground/25",
  other: "bg-muted-foreground/30",
};

const LEGEND: [Kind, MsgKey][] = [
  ["board", "rel.lg.board"],
  ["lin", "rel.lg.lin"],
  ["hub", "rel.lg.hub"],
  ["rel", "rel.lg.rel"],
  ["mac", "rel.lg.mac"],
];

// a watcher spanning the run and the ledger itself: in the table, never a bar
const HIDDEN = new Set(["红灯即停", "ledger"]);

// the seconds every bar shares: a little past 5 minutes, else the longest
// on-path end — the Mac half beside the release never stretches it (clipped)
function scaleOf(runs: TrainRun[]): number {
  let max = SLOW * 1.1;
  for (const r of runs) {
    max = Math.max(max, Number(r.total_secs) || 0);
    for (const s of r.stages || []) if (!s.off_path) max = Math.max(max, (s.offset_secs || 0) + (s.secs || 0));
  }
  return max;
}

const pct = (x: number, max: number) => Math.max(0, Math.min(100, (x / max) * 100));

function TimeBar({ r, max }: { r: TrainRun; max: number }) {
  const segs = (r.stages || [])
    .filter((s) => s.secs > 0 && !HIDDEN.has(s.name))
    .map((s) => {
      const left = pct(s.offset_secs || 0, max);
      const width = Math.max(0.6, Math.min(100 - left, pct(s.secs, max)));
      const queue = s.queue_secs && s.queue_secs > 0 ? Math.min(100, (pct(s.queue_secs, max) / width) * 100) : 0;
      return { s, left, width, queue };
    })
    // off-path first, so the path draws on top
    .sort((a, b) => Number(!!b.s.off_path) - Number(!!a.s.off_path));
  return (
    <div className="relative h-5 w-full min-w-56 overflow-hidden rounded-md bg-muted/60" role="img" aria-label={segs.map((x) => `${x.s.name} ${secs(x.s.secs)}`).join(" · ")}>
      {segs.map(({ s, left, width, queue }) => (
        <div
          key={`${s.name}-${s.offset_secs}`}
          title={`${s.name} · ${secs(s.secs)}${s.queue_secs ? ` (${t("rel.lg.queue")} ${secs(s.queue_secs)})` : ""}`}
          className={cn(
            "absolute top-0.5 bottom-0.5 overflow-hidden rounded-[3px]",
            KIND[kindOf(s.name)],
            s.off_path && "opacity-45",
            s.result === "failure" && "bg-destructive ring-1 ring-destructive",
          )}
          style={{ left: `${left}%`, width: `${width}%` }}
        >
          {queue > 0 && <div className="h-full bg-background/45" style={{ width: `${queue}%` }} />}
        </div>
      ))}
      <div className="absolute top-0 bottom-0 border-l-2 border-dashed border-warn" style={{ left: `${pct(SLOW, max)}%` }} title={t("rel.five")} />
    </div>
  );
}

function Legend() {
  return (
    <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-muted-foreground">
      {LEGEND.map(([k, l]) => (
        <span key={k} className="inline-flex items-center gap-1.5">
          <span className={cn("inline-block h-2.5 w-4 rounded-[3px]", KIND[k], k === "mac" && "opacity-45")} />
          {t(l)}
        </span>
      ))}
      <span className="inline-flex items-center gap-1.5">
        <span className="inline-block h-2.5 w-4 rounded-[3px] bg-clay [background-image:linear-gradient(to_right,var(--background)_0_50%,transparent_50%)] opacity-90" />
        {t("rel.lg.queue")}
      </span>
      <span className="inline-flex items-center gap-1.5">
        <span className="inline-block h-3 border-l-2 border-dashed border-warn" />
        {t("rel.five")}
      </span>
    </div>
  );
}

// ── the cards: two lanes, the keys ───────────────────────────────────────

type Ctx = { st: ReleaseStats | null; ver: HubVersion | null; keys: ReleaseKeys | null; keysErr: boolean };

function Line({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex min-h-7 items-center justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="flex min-w-0 items-center gap-2">{children}</span>
    </div>
  );
}

function LanesCard({ c, loading }: { c: Ctx; loading: boolean }) {
  const v = c.ver;
  const linux = v?.stable || c.st?.lanes?.stable || v?.client_version;
  const mac = v?.client_version_macos || c.st?.lanes?.stable_macos;
  const behind = v?.stable_macos_behind || 0;
  const macBadge =
    !mac || mac === linux ? (
      <Badge variant="outline" className="border-ok/40 font-normal text-ok">
        {t("rel.lane.same")}
      </Badge>
    ) : (
      <Badge variant="outline" className="border-warn/50 font-normal text-warn">
        {behind
          ? v?.stable_macos_behind_since
            ? t("rel.lane.behindSince", { n: behind, ago: ago(v.stable_macos_behind_since) })
            : t("rel.lane.behind", { n: behind })
          : t("rel.lane.waiting")}
      </Badge>
    );
  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 font-display text-base">
          <Rocket className="size-4 text-clay" />
          {t("rel.lanes")}
        </CardTitle>
        <CardDescription>{t("rel.lanes.sub")}</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-1">
        {loading ? (
          [0, 1, 2].map((i) => <Skeleton key={i} className="my-1.5 h-4 w-full" />)
        ) : (
          <>
            <Line label={t("rel.lane.linux")}>
              <code className="font-mono text-sm font-semibold">{short(linux)}</code>
            </Line>
            <Line label={t("rel.lane.mac")}>
              <code className="font-mono text-sm font-semibold">{short(mac || linux)}</code>
              {macBadge}
            </Line>
            <Separator className="my-1" />
            <Line label={t("rel.lane.hub")}>
              <code className="font-mono text-xs text-muted-foreground">{v?.version || "—"}</code>
            </Line>
          </>
        )}
      </CardContent>
    </Card>
  );
}

function keysHealthy(k: ReleaseKeys): boolean {
  return !!k.anchor && (!k.stable_key || (k.stable_key_trusted && !k.stable_key_revoked));
}

function KeysCard({ c, loading }: { c: Ctx; loading: boolean }) {
  const k = c.keys;
  const status = !k ? "unknown" : keysHealthy(k) ? "ok" : "bad";
  const cls = { ok: "border-ok/40 text-ok", bad: "border-destructive/50 text-destructive", unknown: "text-muted-foreground" }[status];
  return (
    <Card className="gap-3">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 font-display text-base">
          <KeyRound className="size-4 text-clay" />
          {t("rel.keys")}
        </CardTitle>
        <CardDescription>{t("rel.keys.sub")}</CardDescription>
        {!loading && (
          <CardAction>
            <Badge variant="outline" className={cn("font-normal", cls)}>
              {t(`rel.keys.${status}` as MsgKey)}
            </Badge>
          </CardAction>
        )}
      </CardHeader>
      <CardContent className="grid gap-1">
        {loading ? (
          [0, 1, 2, 3].map((i) => <Skeleton key={i} className="my-1.5 h-4 w-full" />)
        ) : !k ? (
          <p className="text-sm text-muted-foreground">{t("rel.keys.unknown")}</p>
        ) : (
          <>
            <Line label={t("rel.keys.signer")}>{t(k.signer === "train" ? "rel.keys.signer.train" : "rel.keys.signer.hub")}</Line>
            <Line label={t("rel.keys.root")}>
              {k.root ? (
                <>
                  <code className="font-mono text-xs text-muted-foreground">{k.anchor}</code>
                  <span>{t("rel.keys.rootOn")}</span>
                </>
              ) : (
                <span className="text-warn">{t("rel.keys.rootOff")}</span>
              )}
            </Line>
            <Line label={t("rel.keys.stable")}>
              <code className="font-mono text-xs">{k.stable_key || "—"}</code>
              {k.stable_key && (
                <Badge
                  variant="outline"
                  className={cn("font-normal", k.stable_key_revoked ? "border-destructive/50 text-destructive" : k.stable_key_trusted ? "border-ok/40 text-ok" : "border-warn/50 text-warn")}
                >
                  {t(k.stable_key_revoked ? "rel.keys.revokedKey" : k.stable_key_trusted ? "rel.keys.trusted" : "rel.keys.untrusted")}
                </Badge>
              )}
            </Line>
            <Line label={t("rel.keys.revoked")}>
              {k.revoked ? t("rel.keys.revokedN", { n: k.revoked, v: k.revoked_version }) : t("rel.keys.revokedNone")}
            </Line>
            <p className="pt-1 text-xs text-muted-foreground">
              {t("rel.keys.chain", { n: k.trusted.length })}
              {k.overlap && ` · ${t("rel.keys.overlap")}`}
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
}

// ── the page ─────────────────────────────────────────────────────────────

export function ReleasePage() {
  const { run } = useParams();
  const nav = useNavigate();
  const [c, setC] = React.useState<Ctx>({ st: null, ver: null, keys: null, keysErr: false });
  const max = React.useMemo(() => scaleOf(c.st?.runs || []), [c.st]);

  const fetchRows = React.useCallback(async () => {
    // the ledger is the page; the lanes and the keys only decorate it — one
    // that does not answer says so on its card, never takes the page down
    const [st, ver, keys] = await Promise.all([
      api<ReleaseStats>(`/v1/fleet/release/stats?days=${DAYS}`),
      api<HubVersion>("/version").catch(() => null),
      api<ReleaseKeys>("/v1/fleet/release/keys").catch(() => null),
    ]);
    setC({ st, ver, keys, keysErr: !keys });
    return st.runs || [];
  }, []);

  const columns = React.useMemo<ColumnDef<TrainRun, any>[]>(
    () => [
      {
        accessorKey: "sha",
        header: () => t("rel.col.train"),
        cell: ({ row: { original: r } }) => (
          <div className="grid">
            <code className="font-mono text-sm font-semibold">{short(r.sha)}</code>
            <span className="text-xs text-muted-foreground">{t("rel.merges", { n: (r.merges || []).length })}</span>
          </div>
        ),
      },
      {
        id: "state",
        accessorFn: (r) => stateOf(r),
        header: () => t("rel.col.state"),
        cell: ({ row: { original: r } }) => <StateBadge r={r} />,
      },
      {
        accessorKey: "started_at",
        header: () => t("rel.col.started"),
        cell: ({ row: { original: r } }) => (
          <time dateTime={r.started_at} title={when(r.started_at)} className="whitespace-nowrap text-muted-foreground">
            {ago(r.started_at)}
          </time>
        ),
      },
      {
        id: "bar",
        header: () => t("rel.col.bar"),
        enableSorting: false,
        cell: ({ row: { original: r } }) => {
          const why = whyOf(r);
          const s = stateOf(r);
          return (
            <div className="grid w-full max-w-md gap-1">
              <TimeBar r={r} max={max} />
              {why && <p className={cn("truncate text-xs", s === "failed" ? "text-destructive" : s === "slow" ? "text-warn" : "text-muted-foreground")} title={why}>{why}</p>}
            </div>
          );
        },
      },
      {
        accessorKey: "total_secs",
        header: () => t("rel.col.total"),
        cell: ({ row: { original: r } }) => (
          <span className={cn("font-mono text-xs whitespace-nowrap tabular-nums", r.total_secs > SLOW && "text-warn")}>{secs(r.total_secs)}</span>
        ),
      },
    ],
    [max],
  );

  const filters: Filter<TrainRun>[] = [
    { key: "shipped", label: t("rel.filter.shipped"), test: (r) => stateOf(r) === "shipped" || stateOf(r) === "superseded" },
    { key: "slow", label: t("rel.filter.slow"), test: (r) => stateOf(r) === "slow" },
    { key: "failed", label: t("rel.filter.failed"), test: (r) => stateOf(r) === "failed" },
  ];

  const st = c.st;
  const repo = c.keys?.repo;
  return (
    <AdminTablePage<TrainRun>
      title={t("page.release")}
      lead={t("rel.lead", { days: st?.days || DAYS })}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      searchText={(r) => [r.sha, r.run_id, ...(r.merges || []).map((m) => `${m.sha} ${m.subject || ""}`), r.bottleneck?.stage || ""].join(" ")}
      rowId={(r) => r.run_id}
      openId={run ? decodeURIComponent(run) : null}
      onOpen={(id) => nav(id ? `/release/${encodeURIComponent(id)}` : "/release")}
      emptyText={t("rel.empty")}
      kpis={() =>
        st
          ? [
              {
                label: `${t("rel.k.p50")} · ${t("rel.k.p95", { v: secs(st.merge_to_stable_p95), n: st.merge_to_stable_n || 0 })}`,
                value: <span className={cn(st.merge_to_stable_p50 != null && st.merge_to_stable_p50 > SLOW && "text-warn")}>{secs(st.merge_to_stable_p50)}</span>,
              },
              {
                label: t("rel.k.shipped"),
                value: (
                  <span className={cn(st.runs_started && st.runs_shipped / st.runs_started < 0.9 && "text-warn")}>
                    {st.runs_shipped || 0}/{st.runs_started || 0}
                  </span>
                ),
              },
              { label: t("rel.k.run"), value: <span className={cn(st.run_p50_secs != null && st.run_p50_secs > SLOW && "text-warn")}>{secs(st.run_p50_secs)}</span> },
              {
                label: `${t("rel.k.slow")} · ${t("rel.k.said", { n: st.runs_slow_said || 0, of: st.runs_slow || 0 })}`,
                value: <span className={cn(st.runs_slow ? "text-warn" : "")}>{st.runs_slow || 0}</span>,
              },
            ]
          : []
      }
      aside={(rows) => (
        <div className="grid gap-3">
          <div className="grid gap-3 lg:grid-cols-2">
            <LanesCard c={c} loading={!rows} />
            <KeysCard c={c} loading={!rows} />
          </div>
          <Legend />
        </div>
      )}
      actions={() =>
        repo ? (
          <Button variant="outline" asChild>
            <a href={`https://github.com/${repo}/actions/workflows/release-train.yml`} target="_blank" rel="noopener noreferrer">
              {t("rel.dispatch")}
              <ExternalLink />
            </a>
          </Button>
        ) : null
      }
      drawer={(r) => <RunDrawer r={r} />}
    />
  );
}

function RunDrawer({ r }: { r: TrainRun }) {
  const why = whyOf(r);
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="flex items-center gap-3 font-display text-xl">
          <code className="font-mono">{short(r.sha)}</code>
          <StateBadge r={r} />
        </SheetTitle>
        <SheetDescription className="text-xs">
          {when(r.started_at)} · {secs(r.total_secs)}
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        {why && <p className={cn("rounded-lg border px-3 py-2 text-sm", stateOf(r) === "failed" ? "border-destructive/40 bg-destructive/10" : "border-warn/50 bg-warn/10")}>{why}</p>}

        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("rel.d.merges")}</h3>
          {(r.merges || []).length ? (
            <ul className="grid gap-1.5">
              {r.merges.map((m) => (
                <li key={m.sha} className="flex gap-2 text-sm">
                  <code className="shrink-0 font-mono text-xs text-muted-foreground">{short(m.sha)}</code>
                  <span className="min-w-0">{m.subject || "—"}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("rel.d.noMerges")}</p>
          )}
        </section>

        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("rel.d.stages")}</h3>
          <div className="overflow-hidden rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  <TableHead className="px-3">{t("rel.d.stage")}</TableHead>
                  <TableHead className="px-3 text-right">{t("rel.d.at")}</TableHead>
                  <TableHead className="px-3 text-right">{t("rel.d.secs")}</TableHead>
                  <TableHead className="px-3 text-right">{t("rel.d.budget")}</TableHead>
                  <TableHead className="px-3 text-right">{t("rel.d.result")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {(r.stages || []).map((s) => (
                  <TableRow key={`${s.name}-${s.offset_secs}`} className={cn(r.bottleneck?.stage === s.name && "bg-warn/10")}>
                    <TableCell className="px-3">
                      <span className="inline-flex items-center gap-2">
                        <span className={cn("inline-block size-2 rounded-full", KIND[kindOf(s.name)], s.off_path && "opacity-45")} />
                        {s.name}
                      </span>
                      {s.off_path && <span className="block text-xs text-muted-foreground">{t("rel.d.offPath")}</span>}
                    </TableCell>
                    <TableCell className="px-3 text-right font-mono text-xs tabular-nums">+{secs(s.offset_secs)}</TableCell>
                    <TableCell className={cn("px-3 text-right font-mono text-xs tabular-nums", !s.off_path && s.budget_secs > 0 && s.secs > s.budget_secs && "text-warn")}>
                      {secs(s.secs)}
                    </TableCell>
                    <TableCell className="px-3 text-right font-mono text-xs text-muted-foreground tabular-nums">{s.off_path || !s.budget_secs ? "—" : secs(s.budget_secs)}</TableCell>
                    <TableCell className={cn("px-3 text-right text-xs", s.result === "failure" && "text-destructive")}>{s.result || ""}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          {r.mac && <p className="text-sm text-muted-foreground">{t("rel.d.mac", { c: r.mac.conclusion, after: secs(r.mac.after_secs) })}</p>}
        </section>

        <div className="flex items-center justify-between gap-3 text-xs text-muted-foreground">
          <span className="font-mono">{t("rel.d.run", { id: r.run_id })}</span>
          {r.run_url && (
            <Button variant="link" size="sm" asChild className="h-auto p-0">
              <a href={r.run_url} target="_blank" rel="noopener noreferrer">
                {t("rel.d.open")}
                <ExternalLink />
              </a>
            </Button>
          )}
        </div>
      </div>
    </>
  );
}
