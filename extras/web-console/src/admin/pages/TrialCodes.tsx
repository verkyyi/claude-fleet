// TrialCodes — 试用二维码, /admin/trial-codes and /admin/trial-codes/:id
// (claude-fleet MRGB). An admin draws a code on the service account; whoever
// scans it and follows starts a trial with no request to approve. Each row is
// one code: how many it gave of its cap, its funnel from scan to member, its
// state. A row opens its drawer — the code to download, its plan, the median
// time from scan to first line, the people it reached — where it is stopped or
// resumed. Reads and writes /v1/admin/trial-codes only; the hub audits every
// create, stop and resume.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { AlertTriangle, Download, QrCode, WifiOff } from "lucide-react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Separator } from "@/components/ui/separator";
import { Sheet, SheetClose, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type TrialCode, type TrialCodeDetail, type TrialCodesList, type TrialFunnel } from "../api";
import { lang, t, when, type MsgKey } from "../i18n";

const BASE = "/v1/admin/trial-codes";
const zeroTime = (iso?: string) => !iso || iso.startsWith("0001-");
// a date as the codes are made: 2026-11-30, Beijing's day
const day = (iso?: string) => (zeroTime(iso) ? "" : new Date(Date.parse(iso!) + 8 * 3600_000).toISOString().slice(0, 10));
const terms = (c: TrialCode) => (lang === "zh" ? c.terms_words : c.terms_words_en);
// the plan in a table cell: 「7 天 · 300 万 · 并发 1」 / "7 days · 3M · 1 at a time"
function planShort(v: string): string {
  const m = Object.fromEntries(v.split(",").map((p) => p.split("=").map((x) => x.trim())));
  if (v.trim() === "off") return t("tc.plan.off");
  const p: string[] = [];
  if (m.days) p.push(t("tc.plan.days", { n: m.days }));
  if (m.tokens) p.push(lang === "zh" ? `${Number(m.tokens) / 10_000} 万` : `${Number(m.tokens) / 1_000_000}M`);
  if (m.sessions) p.push(t("tc.plan.sessions", { n: m.sessions }));
  return p.join(" · ");
}
const given = (c: TrialCode) => c.funnel.granted + c.funnel.queued + c.funnel.pending;

// the state a person reads: a live code that is full or past its date says so
type Shown = "live" | "stopped" | "paused" | "full" | "ended";
function shownState(c: TrialCode): Shown {
  if (c.state !== "live") return c.state;
  if (!zeroTime(c.until) && Date.parse(c.until) < Date.now()) return "ended";
  if (c.cap > 0 && given(c) >= c.cap) return "full";
  return "live";
}
const STATE_CLS: Record<Shown, string> = {
  live: "border-ok/40 text-ok",
  stopped: "text-muted-foreground",
  paused: "border-destructive/40 text-destructive",
  full: "border-warn/40 text-warn",
  ended: "text-muted-foreground",
};
function StateBadge({ c }: { c: TrialCode }) {
  const s = shownState(c);
  return (
    <Badge variant="outline" className={cn("font-normal", STATE_CLS[s])}>
      {t(`tc.st.${s}` as MsgKey)}
    </Badge>
  );
}

// a pause's why, "34/30" (trials in 10 minutes / the alarm line), in words
const burstWhy = (why = "") => {
  const [n, limit] = why.split("/");
  return limit ? t("tc.burst", { n, limit }) : why;
};

export function secs(n: number): string {
  if (n < 60) return t("tc.sec", { n });
  return t("tc.min", { n: Math.floor(n / 60), s: n % 60 });
}

const STEPS: (keyof TrialFunnel)[] = ["scans", "follows", "granted", "first", "converted"];
// the funnel as five small bars, the 开通 one in the accent colour
function Funnel({ f }: { f: TrialFunnel }) {
  const top = Math.max(1, ...STEPS.map((k) => f[k]));
  return (
    <div className="flex items-end gap-0.5" aria-label={STEPS.map((k) => f[k]).join(" › ")}>
      {STEPS.map((k) => (
        <div key={k} className="flex w-6 flex-col items-center gap-0.5">
          <div className={cn("w-4.5 rounded-t-sm", k === "granted" ? "bg-clay" : "bg-clay-soft")} style={{ height: Math.max(2, Math.round((26 * f[k]) / top)) }} />
          <span className="text-[11px] text-muted-foreground tabular-nums">{f[k]}</span>
        </div>
      ))}
    </div>
  );
}

// fleet.apply.trial, a code's plan when it names none (the list's read sets it)
let defaultTerms = "days=7,tokens=3000000,sessions=1";

const columns: ColumnDef<TrialCode, any>[] = [
  {
    accessorKey: "channel",
    header: () => t("tc.col.channel"),
    cell: ({ row: { original: c } }) => (
      <div className="min-w-0">
        <div className="truncate font-medium">{c.channel}</div>
        <div className="flex gap-1.5 text-xs text-muted-foreground">
          {c.approval && <span>{t("tc.approval")}</span>}
          {c.kind === "temp" && <span>{t("tc.temp")}</span>}
        </div>
      </div>
    ),
  },
  {
    id: "code",
    header: () => t("tc.col.code"),
    enableSorting: false,
    cell: ({ row: { original: c } }) => <img src={c.image} alt="" className="size-10 rounded border bg-white p-0.5" />,
  },
  { id: "terms", accessorFn: (c) => planShort(c.terms || defaultTerms), header: () => t("tc.col.terms"), enableSorting: false, cell: ({ getValue }) => <span className="block max-w-[8.5rem] text-sm whitespace-normal text-muted-foreground">{getValue()}</span> },
  {
    id: "given",
    accessorFn: given,
    header: () => t("tc.col.given"),
    cell: ({ row: { original: c } }) => (
      <div className="w-24">
        <span className="tabular-nums">
          {given(c)} / {c.cap > 0 ? c.cap : t("tc.noCap")}
        </span>
        {c.cap > 0 && <Progress value={Math.min(100, (100 * given(c)) / c.cap)} className="mt-1 h-1.5" />}
      </div>
    ),
  },
  {
    id: "funnel",
    accessorFn: (c) => c.funnel.granted,
    header: () => <span className="block max-w-[10.5rem] text-left leading-tight whitespace-normal">{t("tc.col.funnel")}</span>,
    cell: ({ row }) => <Funnel f={row.original.funnel} />,
  },
  { id: "until", accessorFn: (c) => (zeroTime(c.until) ? Infinity : Date.parse(c.until)), header: () => t("tc.col.until"), cell: ({ row: { original: c } }) => <span className="text-sm text-muted-foreground tabular-nums">{day(c.until) || t("tc.noEnd")}</span> },
  { id: "state", accessorFn: shownState, header: () => t("tc.col.state"), cell: ({ row }) => <StateBadge c={row.original} /> },
  {
    id: "ops",
    header: () => "",
    enableSorting: false,
    // 下载 · 停用 right in the row; a click here does not open the drawer
    cell: ({ row: { original: c } }) => (
      <span className="whitespace-nowrap text-sm font-medium text-clay" onClick={(e) => e.stopPropagation()}>
        <a href={c.image} download={`${c.channel}.png`} className="hover:underline">{t("tc.op.download")}</a>
        {" · "}
        <button type="button" className="hover:underline" onClick={() => rowFlip?.(c)}>
          {t(c.state === "live" ? "tc.op.stop" : "tc.op.resume")}
        </button>
      </span>
    ),
  },
];
// the page's stop / resume, for the row's button (set while the page is up)
let rowFlip: ((c: TrialCode) => void) | null = null;

const filters: Filter<TrialCode>[] = [
  { key: "live", label: t("tc.filter.live"), test: (c) => shownState(c) === "live" },
  { key: "off", label: t("tc.filter.off"), test: (c) => shownState(c) !== "live" },
];

export function TrialCodesPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [meta, setMeta] = React.useState<TrialCodesList | null>(null);
  const fetchRows = React.useCallback(async () => {
    const v = await api<TrialCodesList>(BASE);
    defaultTerms = v.terms || defaultTerms;
    setMeta(v);
    return v.codes || [];
  }, []);
  const reloadRef = React.useRef<() => void>(() => {});
  React.useEffect(() => {
    rowFlip = async (c) => {
      const verb = c.state === "live" ? "stop" : "resume";
      try {
        await api(`${BASE}/${encodeURIComponent(c.id)}/${verb}`, { json: {} });
        toast.success(t(verb === "stop" ? "tc.d.stopped" : "tc.d.resumed", { name: c.channel }));
        reloadRef.current();
      } catch (e) {
        toast.error(t("err.action", { e: (e as Error).message }));
      }
    };
    return () => { rowFlip = null; };
  }, []);
  const d = meta?.days ?? 7;
  const tot = meta?.totals;
  const pct = (a = 0, b = 0) => (b > 0 ? <span className="ml-2 font-sans text-xs font-normal text-ok">{Math.round((100 * a) / b)}%</span> : null);

  return (
    <AdminTablePage<TrialCode>
      title={t("page.trialCodes")}
      lead={t("tc.lead")}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      searchText={(c) => [c.channel, terms(c), String(c.scene)].join(" ")}
      rowId={(c) => c.id}
      openId={id ? decodeURIComponent(id) : null}
      onOpen={(x) => nav(x ? `/trial-codes/${encodeURIComponent(x)}` : "/trial-codes")}
      emptyText={t("tc.empty")}
      actions={(reload) => {
        reloadRef.current = reload;
        return meta && <NewCodeSheet meta={meta} onMade={(c) => { reload(); nav(`/trial-codes/${encodeURIComponent(c.id)}`); }} />;
      }}
      aside={(rows) => (
        <>
          {meta && !meta.ready && (
            <Alert>
              <WifiOff />
              <AlertTitle>{t("tc.notReady")}</AlertTitle>
              <AlertDescription>{t("tc.notReadySub")}</AlertDescription>
            </Alert>
          )}
          {(rows || [])
            .filter((c) => c.state === "paused")
            .map((c) => (
              <Alert key={c.id} variant="destructive">
                <AlertTriangle />
                <AlertDescription>{t("tc.alert.sub", { name: c.channel, why: burstWhy(c.paused_why) })}</AlertDescription>
              </Alert>
            ))}
        </>
      )}
      kpis={() => [
        { label: t("tc.kpi.scans", { d }), value: tot?.scans ?? 0 },
        { label: t("tc.kpi.granted", { d }), value: <>{tot?.granted ?? 0}{pct(tot?.granted, tot?.scans)}</> },
        { label: t("tc.kpi.first", { d }), value: <>{tot?.first ?? 0}{pct(tot?.first, tot?.granted)}</> },
        { label: t("tc.kpi.converted", { d }), value: <>{tot?.converted ?? 0}{pct(tot?.converted, tot?.granted)}</> },
      ]}
      drawer={(c, ctx) => <CodeDrawer key={c.id} c={c} {...ctx} />}
    />
  );
}

function Field({ k, children }: { k: MsgKey; children: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{t(k)}</dt>
      <dd className="min-w-0 break-words">{children}</dd>
    </>
  );
}

const FUNNEL_WORDS: Record<string, { zh: string; en: string }> = {
  scans: { zh: "扫码", en: "Scanned" },
  follows: { zh: "扫码关注", en: "Followed" },
  granted: { zh: "开通试用", en: "Started" },
  first: { zh: "发出第一句", en: "First line" },
  converted: { zh: "转正", en: "Member" },
};

function CodeDrawer({ c, close, reload }: { c: TrialCode; close: () => void; reload: () => void }) {
  const [d, setD] = React.useState<TrialCodeDetail | null>(null);
  const [busy, setBusy] = React.useState(false);
  React.useEffect(() => {
    api<TrialCodeDetail>(`${BASE}/${encodeURIComponent(c.id)}`).then(setD, () => setD(null));
  }, [c.id]);
  const f = (d || c).funnel;
  const flip = async (verb: "stop" | "resume") => {
    setBusy(true);
    try {
      const got = await api<TrialCodeDetail>(`${BASE}/${encodeURIComponent(c.id)}/${verb}`, { json: {} });
      setD(got);
      toast.success(t(verb === "stop" ? "tc.d.stopped" : "tc.d.resumed", { name: c.channel }));
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  const state = (d || c).state;
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{c.channel}</SheetTitle>
        <SheetDescription className="flex flex-wrap items-center gap-2">
          <StateBadge c={d || c} />
          <span className="font-mono text-xs">{c.scene}</span>
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <div className="flex items-center gap-4">
          <img src={c.image} alt={c.channel} className="size-36 rounded-lg border bg-white p-2" />
          <Button variant="outline" asChild>
            <a href={c.image} download={`${c.channel}.png`}>
              <Download />
              {t("tc.d.download")}
            </a>
          </Button>
        </div>
        {state === "paused" && c.paused_why && (
          <Alert variant="destructive">
            <AlertTriangle />
            <AlertDescription>{t("tc.d.paused", { why: burstWhy(c.paused_why) })}</AlertDescription>
          </Alert>
        )}
        <dl className="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="tc.d.terms">{terms(c)}</Field>
          <Field k="tc.d.cap">{c.cap > 0 ? c.cap : t("tc.noCap")}</Field>
          <Field k="tc.d.until">{day(c.until) || t("tc.noEnd")}</Field>
          <Field k="tc.d.kind">{t(c.kind === "temp" ? "tc.d.kindTemp" : "tc.d.kindLimit")}</Field>
          <Field k="tc.d.approval">{t(c.approval ? "tc.d.yes" : "tc.d.no")}</Field>
        </dl>
        <Separator />
        <section className="grid gap-3">
          <h3 className="font-display text-base font-semibold">{t("tc.d.funnel")}</h3>
          <ol className="grid gap-1.5 text-sm">
            {STEPS.map((k) => (
              <li key={k} className="flex items-center gap-3">
                <span className="w-24 text-muted-foreground">{FUNNEL_WORDS[k][lang === "zh" ? "zh" : "en"]}</span>
                <div className="h-2 flex-1 rounded bg-muted">
                  <div className={cn("h-2 rounded", k === "granted" ? "bg-clay" : "bg-clay-soft")} style={{ width: `${(100 * f[k]) / Math.max(1, f.scans)}%` }} />
                </div>
                <span className="w-10 text-right tabular-nums">{f[k]}</span>
              </li>
            ))}
          </ol>
          <p className="text-sm text-muted-foreground">
            {t("tc.d.p50")}：{f.p50_secs ? <b className="text-foreground">{secs(f.p50_secs)}</b> : t("tc.d.p50None")}
            {f.queued > 0 && <> · {t("tc.d.queued", { n: f.queued })}</>}
            {f.pending > 0 && <> · {t("tc.d.pending", { n: f.pending })}</>}
          </p>
        </section>
        <Separator />
        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("tc.d.people")}</h3>
          {!d ? (
            <Skeleton className="h-4 w-48" />
          ) : d.people.length === 0 ? (
            <p className="text-sm text-muted-foreground">{t("tc.d.peopleNone")}</p>
          ) : (
            <ul className="grid gap-1.5 text-sm">
              {d.people.map((p, i) => (
                <li key={p.principal || i} className="flex flex-wrap items-center gap-2">
                  {p.principal ? (
                    <a className="font-medium text-primary underline-offset-4 hover:underline" href={`/admin/people/${encodeURIComponent(p.principal)}`} onClick={close}>
                      {p.login || p.principal}
                    </a>
                  ) : (
                    <span className="text-muted-foreground">—</span>
                  )}
                  <span className="text-xs text-muted-foreground">{when(p.scanned_at)}</span>
                  {p.state !== "granted" && <Badge variant="secondary" className="font-normal">{t(p.state === "queued" ? "tc.d.queued" : "tc.d.pending", { n: "" }).trim()}</Badge>}
                  {!zeroTime(p.first_at) && (
                    <Badge variant="outline" className="font-normal">
                      {t("tc.d.first")} {secs(Math.round((Date.parse(p.first_at) - Date.parse(p.scanned_at)) / 1000))}
                    </Badge>
                  )}
                  {p.member && <Badge variant="outline" className="border-ok/40 font-normal text-ok">{t("tc.d.member")}</Badge>}
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
      <SheetFooter className="sticky bottom-0 mt-auto border-t bg-background p-4">
        {state === "live" ? (
          <Button variant="outline" disabled={busy} onClick={() => flip("stop")}>
            {t("tc.d.stop")}
          </Button>
        ) : (
          <Button disabled={busy} onClick={() => flip("resume")}>
            {t("tc.d.resume")}
          </Button>
        )}
      </SheetFooter>
    </>
  );
}

// the plan's three parts as the form edits them, from "days=7,tokens=3000000,sessions=1"
function planOf(terms: string) {
  const m = Object.fromEntries(terms.split(",").map((p) => p.split("=").map((x) => x.trim())));
  return { days: m.days || "", wan: m.tokens ? String(Number(m.tokens) / 10_000) : "", sessions: m.sessions || "" };
}

function NewCodeSheet({ meta, onMade }: { meta: TrialCodesList; onMade: (c: TrialCode) => void }) {
  const base = planOf(meta.terms);
  const [open, setOpen] = React.useState(false);
  const [channel, setChannel] = React.useState("");
  const [plan, setPlan] = React.useState(base);
  const [cap, setCap] = React.useState(String(meta.cap));
  const [until, setUntil] = React.useState("");
  const [kind, setKind] = React.useState<"limit" | "temp">("limit");
  const [days, setDays] = React.useState("14");
  const [approval, setApproval] = React.useState(false);
  const [busy, setBusy] = React.useState(false);
  const [err, setErr] = React.useState("");
  const reset = () => {
    setChannel("");
    setPlan(base);
    setCap(String(meta.cap));
    setUntil("");
    setKind("limit");
    setApproval(false);
    setErr("");
  };
  const termsOut = () => {
    const same = plan.days === base.days && plan.wan === base.wan && plan.sessions === base.sessions;
    if (same) return "";
    const p = [];
    if (plan.days) p.push(`days=${plan.days}`);
    if (plan.wan) p.push(`tokens=${Math.round(Number(plan.wan) * 10_000)}`);
    if (plan.sessions) p.push(`sessions=${plan.sessions}`);
    return p.join(",");
  };
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      const c = await api<TrialCode>(BASE, {
        json: { channel: channel.trim(), terms: termsOut(), cap: Number(cap || 0), until, approval, kind, ...(kind === "temp" ? { days: Number(days) } : {}) },
      });
      // 生成并下载: the picture goes down at once
      const a = document.createElement("a");
      a.href = c.image;
      a.download = `${c.channel}.png`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      toast.success(t("tc.d.created", { name: c.channel }));
      setOpen(false);
      reset();
      onMade(c);
    } catch (e2) {
      setErr(t("err.action", { e: (e2 as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  const num = (set: (s: string) => void) => (e: React.ChangeEvent<HTMLInputElement>) => set(e.target.value.replace(/[^\d.]/g, ""));
  const unit = (v: string, w: string) => (
    <span className="pointer-events-none absolute top-1/2 right-3 -translate-y-1/2 text-xs text-muted-foreground">{w}</span>
  );
  return (
    <Sheet
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) reset();
      }}
    >
      <SheetTrigger asChild>
        <Button disabled={!meta.ready}>
          <QrCode />
          {t("tc.new")}
        </Button>
      </SheetTrigger>
      <SheetContent className="w-full overflow-y-auto sm:max-w-[520px]">
        <form className="flex min-h-full flex-col" onSubmit={submit}>
          <SheetHeader className="p-6 pb-2">
            <SheetTitle className="font-display text-xl">{t("tc.f.title")}</SheetTitle>
            <SheetDescription>{t("tc.f.sub")}</SheetDescription>
          </SheetHeader>
          <div className="grid gap-5 px-6 py-2">
            <div className="grid gap-2">
              <Label htmlFor="tc-channel">{t("tc.f.channel")}</Label>
              <Input id="tc-channel" value={channel} maxLength={40} onChange={(e) => setChannel(e.target.value)} placeholder={t("tc.f.channelPh")} />
            </div>
            <div className="grid gap-2">
              <Label>{t("tc.f.terms")}</Label>
              <div className="grid grid-cols-3 gap-2">
                <div className="relative">
                  <Input inputMode="numeric" value={plan.days} onChange={num((v) => setPlan({ ...plan, days: v }))} className="pr-10" aria-label={t("tc.f.days")} />
                  {unit(plan.days, t("tc.f.days"))}
                </div>
                <div className="relative">
                  <Input inputMode="decimal" value={plan.wan} onChange={num((v) => setPlan({ ...plan, wan: v }))} className="pr-20" aria-label={t("tc.f.tokens")} />
                  {unit(plan.wan, t("tc.f.tokens"))}
                </div>
                <div className="relative">
                  <Input inputMode="numeric" value={plan.sessions} onChange={num((v) => setPlan({ ...plan, sessions: v }))} className="pr-24" aria-label={t("tc.f.sessions")} />
                  {unit(plan.sessions, t("tc.f.sessions"))}
                </div>
              </div>
              <p className="text-xs text-muted-foreground">{t("tc.f.termsHint", { w: planShort(meta.terms) })}</p>
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="grid gap-2">
                <Label htmlFor="tc-cap">{t("tc.f.cap")}</Label>
                <div className="relative">
                  <Input id="tc-cap" inputMode="numeric" value={cap} onChange={num(setCap)} className="pr-10" />
                  {unit(cap, t("tc.f.people"))}
                </div>
              </div>
              <div className="grid gap-2">
                <Label htmlFor="tc-until">{t("tc.f.until")}</Label>
                <Input id="tc-until" type="date" value={until} onChange={(e) => setUntil(e.target.value)} />
              </div>
            </div>
            <div className="grid gap-2">
              <Label>{t("tc.f.kind")}</Label>
              <RadioGroup value={kind} onValueChange={(v) => setKind(v as "limit" | "temp")} className="grid grid-cols-2 gap-2">
                {(["limit", "temp"] as const).map((k) => (
                  <Label key={k} htmlFor={`tc-k-${k}`} className={cn("flex cursor-pointer items-start gap-2 rounded-lg border p-3 font-normal", kind === k && "border-clay bg-clay-soft")}>
                    <RadioGroupItem value={k} id={`tc-k-${k}`} className="mt-0.5" />
                    <span className="grid gap-0.5">
                      <span className="font-medium">{t(k === "limit" ? "tc.f.kindLimit" : "tc.f.kindTemp")}</span>
                      <span className="text-xs text-muted-foreground">{k === "limit" ? t("tc.f.kindLimitSub") : t("tc.f.kindTempSub", { n: meta.temp_days_max })}</span>
                    </span>
                  </Label>
                ))}
              </RadioGroup>
              {kind === "temp" && (
                <div className="flex items-center gap-2">
                  <Label htmlFor="tc-days" className="font-normal">
                    {t("tc.f.tempDays")}
                  </Label>
                  <Input id="tc-days" inputMode="numeric" className="w-20" value={days} onChange={num(setDays)} />
                </div>
              )}
            </div>
            <div className="grid gap-2">
              <Label htmlFor="tc-approval">{t("tc.f.approval")}</Label>
              <div className="flex items-center gap-3">
                <Switch id="tc-approval" checked={approval} onCheckedChange={setApproval} />
                <span className="text-sm text-muted-foreground">{t("tc.f.approvalSub")}</span>
              </div>
            </div>
            {err && <p className="text-sm text-destructive">{err}</p>}
          </div>
          <SheetFooter className="mt-auto flex-row gap-2 p-6">
            <Button type="submit" disabled={busy || !channel.trim()}>
              {t("tc.f.ok")}
            </Button>
            <SheetClose asChild>
              <Button type="button" variant="outline">
                {t("tc.f.cancel")}
              </Button>
            </SheetClose>
          </SheetFooter>
        </form>
      </SheetContent>
    </Sheet>
  );
}
