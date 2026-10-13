// Requests — 申请, /admin/requests and /admin/requests/:id (claude-fleet#4052,
// EPIC #4048 C4). What people the list does not name asked for at /apply:
// waiting, approved, turned down. A row opens its drawer — the request, the
// person's sign-ins, their trial and whether its conversation is still kept,
// their earlier requests — where 通过，加入名单 is one step and 不通过 asks for
// the words the person will read and when they may ask again. Reads and
// writes /v1/admin/requests only; every decision is audited by the hub.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { BellOff, GitBranch, Mail, MessageCircle } from "lucide-react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type AccessRequest, type Me, type RequestDetail, type RequestsList } from "../api";
import { lang, t, when, type MsgKey } from "../i18n";

const BASE = "/v1/admin/requests";
// a request waiting longer than this is drawn in the warning colour
const LONG_WAIT_MS = 24 * 3600_000;

const wayOf = (kind: string): "github" | "email" | "wechat" => (kind === "github" ? "github" : kind === "email" ? "email" : "wechat");
const WAY_ICON = { github: GitBranch, email: Mail, wechat: MessageCircle };

function Way({ r }: { r: AccessRequest }) {
  const w = wayOf(r.kind);
  const Icon = WAY_ICON[w];
  return (
    <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
      <Icon className="size-3.5" />
      {t(`req.way.${w}` as MsgKey)}
      {w === "github" && r.display ? ` @${r.display}` : ""}
    </span>
  );
}

// waited is how long, in words, from iso to now ("2 小时" / "2 h").
function waited(iso: string, now = Date.now()): string {
  const m = Math.max(0, Math.floor((now - Date.parse(iso)) / 60_000));
  const zh = lang === "zh";
  if (m < 60) return zh ? `${m} 分钟` : `${m} min`;
  if (m < 1440) return zh ? `${Math.floor(m / 60)} 小时` : `${Math.floor(m / 60)} h`;
  return zh ? `${Math.floor(m / 1440)} 天` : `${Math.floor(m / 1440)} d`;
}

const day = (iso?: string) =>
  iso && !iso.startsWith("0001-") ? new Date(iso).toLocaleDateString(lang === "zh" ? "zh-CN" : "en", { month: "short", day: "numeric" }) : "";

const notifyText = (r: AccessRequest) => t(`req.notify.${["wechat", "email"].includes(r.notify_channel) ? r.notify_channel : "page"}` as MsgKey);

function StateCell({ r }: { r: AccessRequest }) {
  if (r.state === "pending") {
    const long = Date.now() - Date.parse(r.created_at) > LONG_WAIT_MS;
    return <span className={cn("tabular-nums", long && "text-warn")}>{waited(r.created_at)}</span>;
  }
  const cls = r.state === "approved" ? "border-ok/40 text-ok" : "text-muted-foreground";
  return (
    <Badge variant="outline" className={cn("font-normal", cls)}>
      {t(`req.st.${r.state}` as MsgKey)}
    </Badge>
  );
}

const columns: ColumnDef<AccessRequest, any>[] = [
  {
    accessorKey: "display",
    header: () => t("req.col.who"),
    cell: ({ row: { original: r } }) => (
      <div className="flex items-center gap-3">
        <Avatar className="size-7">
          <AvatarFallback className="bg-muted text-xs font-medium">{[...(r.display || "?")][0]?.toUpperCase()}</AvatarFallback>
        </Avatar>
        <div className="min-w-0">
          <div className="flex items-center gap-1.5 font-medium">
            <span className="truncate">{r.display}</span>
            {r.trial && (
              <Badge variant="outline" className="border-clay-line bg-clay-soft font-normal text-clay">
                {t("req.trial")}
              </Badge>
            )}
          </div>
          <Way r={r} />
        </div>
      </div>
    ),
  },
  {
    accessorKey: "use",
    header: () => t("req.col.use"),
    enableSorting: false,
    cell: ({ getValue }) => <p className="line-clamp-2 max-w-sm text-sm whitespace-normal">{getValue()}</p>,
  },
  { accessorKey: "team", header: () => t("req.col.team"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue() || "—"}</span> },
  { id: "notify", accessorFn: notifyText, header: () => t("req.col.notify"), cell: ({ getValue }) => <Badge variant="secondary" className="font-normal">{getValue()}</Badge> },
  {
    id: "state",
    accessorFn: (r) => (r.state === "pending" ? Date.parse(r.created_at) : Date.parse(r.decided_at) + 1e13),
    header: () => t("req.col.state"),
    cell: ({ row }) => <StateCell r={row.original} />,
  },
];

const filters: Filter<AccessRequest>[] = [
  { key: "pending", label: t("req.filter.pending"), test: (r) => r.state === "pending" },
  { key: "approved", label: t("req.filter.approved"), test: (r) => r.state === "approved" },
  { key: "rejected", label: t("req.filter.rejected"), test: (r) => r.state === "rejected" },
];

export function RequestsPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [meta, setMeta] = React.useState<RequestsList | null>(null);
  // an admin with no WeChat to reach them hears of no new request (C9)
  const [noReach, setNoReach] = React.useState(false);
  React.useEffect(() => {
    api<Me>("/v1/me").then((me) => setNoReach(!!me.reach && !me.reach.wechat), () => {});
  }, []);

  const fetchRows = React.useCallback(async () => {
    const v = await api<RequestsList>(BASE);
    setMeta(v);
    return v.requests || [];
  }, []);

  return (
    <AdminTablePage<AccessRequest>
      title={t("page.requests")}
      lead={t("req.lead")}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      defaultFilter="pending"
      searchText={(r) => [r.display, r.subject, r.use, r.team, r.referrer].join(" ")}
      rowId={(r) => r.id}
      openId={id ? decodeURIComponent(id) : null}
      onOpen={(x) => nav(x ? `/requests/${encodeURIComponent(x)}` : "/requests")}
      emptyText={t("req.empty")}
      aside={() =>
        noReach && (
          <Alert>
            <BellOff />
            <AlertTitle>{t("req.noReach")}</AlertTitle>
            <AlertDescription>
              <span>
                {t("req.noReachSub")}{" "}
                <a href="/app/settings#logins" className="font-medium text-primary underline-offset-4 hover:underline">
                  {t("req.noReachGo")}
                </a>
              </span>
            </AlertDescription>
          </Alert>
        )
      }
      kpis={() => [
        { label: t("req.kpi.pending"), value: meta?.pending ?? 0 },
        { label: t("req.kpi.oldest"), value: meta?.oldest_pending ? waited(meta.oldest_pending) : <span className="text-muted-foreground">—</span> },
        {
          label: t("req.kpi.week"),
          value: (
            <>
              {meta?.decided_7d ?? 0}
              <span className="ml-2 font-sans text-xs font-normal text-muted-foreground">{t("req.kpi.weekOk", { n: meta?.approved_7d ?? 0 })}</span>
            </>
          ),
        },
      ]}
      drawer={(r, ctx) => <RequestDrawer key={r.id} r={r} cooldownDays={meta?.cooldown_days ?? 30} {...ctx} />}
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

function RequestDrawer({ r, cooldownDays, close, reload }: { r: AccessRequest; cooldownDays: number; close: () => void; reload: () => void }) {
  const [d, setD] = React.useState<RequestDetail | null>(null);
  const [busy, setBusy] = React.useState(false);
  React.useEffect(() => {
    api<RequestDetail>(`${BASE}/${encodeURIComponent(r.id)}`).then(setD, () => setD(null));
  }, [r.id]);
  const none = <span className="text-muted-foreground">{t("req.d.none")}</span>;

  const approve = async () => {
    setBusy(true);
    try {
      await api(`${BASE}/${encodeURIComponent(r.id)}/approve`, { json: {} });
      toast.success(t("req.approved", { name: r.display }));
      close();
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  const trial = d?.trial_of;
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{r.display}</SheetTitle>
        <SheetDescription className="flex flex-wrap items-center gap-2">
          <Way r={r} />
          {r.trial && (
            <Badge variant="outline" className="border-clay-line bg-clay-soft font-normal text-clay">
              {t("req.trial")}
            </Badge>
          )}
          {r.state !== "pending" && <StateCell r={r} />}
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="req.d.use">
            <span className="whitespace-pre-wrap">{r.use}</span>
          </Field>
          <Field k="req.d.team">{r.team || none}</Field>
          <Field k="req.d.ref">{r.referrer || none}</Field>
          <Field k="req.d.notify">
            {notifyText(r)}
            {r.notify_channel === "email" && r.notify_addr && <span className="ml-1 font-mono text-xs text-muted-foreground">{r.notify_addr}</span>}
          </Field>
          <Field k="req.d.at">{when(r.created_at)}</Field>
        </dl>

        <Separator />
        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("req.d.person")}</h3>
          {!d ? (
            <div className="grid gap-2">
              <Skeleton className="h-4 w-56" />
              <Skeleton className="h-4 w-40" />
            </div>
          ) : (
            <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
              <Field k="req.d.signins">{d.signins.count ? t("req.d.signinsN", { first: when(d.signins.first), n: d.signins.count }) : t("req.d.signinsNone")}</Field>
              <Field k="req.d.trial">
                {trial
                  ? t("req.d.trialLine", { from: when(trial.started_at), min: trial.minutes }) +
                    (trial.messages != null ? t("req.d.trialMsgs", { n: trial.messages }) : "") +
                    (trial.ended ? t("req.d.trialEnded") : "")
                  : t("req.d.trialNone")}
              </Field>
              {r.trial && <Field k="req.d.convo">{d.convo_until ? t("req.d.convoKept", { until: when(d.convo_until) }) : t("req.d.convoGone")}</Field>}
              <Field k="req.d.earlier">
                {d.earlier.length ? (
                  <ul className="grid gap-1">
                    {d.earlier.map((e) => (
                      <li key={e.id}>
                        {day(e.created_at)} · {t(`req.st.${e.state}` as MsgKey)}
                        {e.reason && <span className="text-muted-foreground"> · {e.reason}</span>}
                      </li>
                    ))}
                  </ul>
                ) : (
                  t("req.d.earlierNone")
                )}
              </Field>
              {r.state !== "pending" && (
                <Field k="req.d.decided">
                  <span className="font-mono text-xs">{r.decided_by || "—"}</span> · {when(r.decided_at)}
                  {r.reason && <p className="mt-1 text-muted-foreground">{r.reason}</p>}
                  {r.state === "rejected" && day(r.cooldown_until) && <p className="text-muted-foreground">{t("req.d.again", { day: day(r.cooldown_until) })}</p>}
                </Field>
              )}
            </dl>
          )}
        </section>
      </div>
      {r.state === "pending" && (
        // on a phone (the 「新申请待审核」 notice opens here, claude-fleet#4062)
        // the drawer is the whole screen and the two buttons stay at its
        // bottom, thumb-sized, above the home bar
        <SheetFooter className="sticky bottom-0 mt-auto gap-2 border-t bg-background p-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
          <div className="grid grid-cols-2 gap-2 sm:flex sm:justify-end">
            <RejectDialog r={r} cooldownDays={cooldownDays} close={close} reload={reload} />
            <Button className="h-11 sm:h-9" disabled={busy} onClick={approve}>
              {t("req.approve")}
            </Button>
          </div>
          <p className="text-xs text-muted-foreground">{t("req.approveNote")}</p>
        </SheetFooter>
      )}
    </>
  );
}

const PRESETS = ["team", "use", "other"] as const;

function RejectDialog({ r, cooldownDays, close, reload }: { r: AccessRequest; cooldownDays: number; close: () => void; reload: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [preset, setPreset] = React.useState<(typeof PRESETS)[number]>("team");
  const [words, setWords] = React.useState(t("req.rj.t.team"));
  const [days, setDays] = React.useState(String(cooldownDays));
  const [busy, setBusy] = React.useState(false);
  const choices = Array.from(new Set([0, 7, cooldownDays, 90])).sort((a, b) => a - b);
  const dayAfter = (n: number) => day(new Date(Date.now() + n * 86_400_000).toISOString());

  const pick = (p: string) => {
    if (!p) return;
    setPreset(p as (typeof PRESETS)[number]);
    setWords(p === "other" ? "" : t(`req.rj.t.${p}` as MsgKey));
  };
  const submit = async () => {
    setBusy(true);
    try {
      await api(`${BASE}/${encodeURIComponent(r.id)}/reject`, { json: { reason: words.trim(), cooldown_days: Number(days) } });
      toast.success(t("req.rejected"));
      setOpen(false);
      close();
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="h-11 sm:h-9">
          {t("req.rejectOpen")}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("req.rj.title", { name: r.display })}</AlertDialogTitle>
          <AlertDialogDescription>{t("req.rj.sub")}</AlertDialogDescription>
        </AlertDialogHeader>
        <div className="grid gap-4">
          <ToggleGroup type="single" variant="outline" size="sm" value={preset} onValueChange={pick} className="flex-wrap justify-start">
            {PRESETS.map((p) => (
              <ToggleGroupItem key={p} value={p} className="px-3">
                {t(`req.rj.p.${p}` as MsgKey)}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
          <div className="grid gap-1.5">
            <Label htmlFor="rj-words">{t("req.rj.words")}</Label>
            <Textarea id="rj-words" rows={3} maxLength={500} value={words} onChange={(e) => setWords(e.target.value)} />
          </div>
          <div className="grid gap-1.5">
            <Label>{t("req.rj.again")}</Label>
            <Select value={days} onValueChange={setDays}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {choices.map((n) => (
                  <SelectItem key={n} value={String(n)}>
                    {n === 0 ? t("req.rj.now") : t("req.rj.days", { n, day: dayAfter(n) })}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </div>
        <AlertDialogFooter>
          <AlertDialogCancel>{t("req.rj.cancel")}</AlertDialogCancel>
          <Button variant="destructive" disabled={busy || !words.trim()} onClick={submit}>
            {t("req.rj.ok")}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
