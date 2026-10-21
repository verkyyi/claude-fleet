// Pool — 订阅池, /admin/pool and /admin/pool/:id (EPIC #3923 C12; the old
// /app/subscriptions and /app/subscriptions/<id> move here). One table of
// every subscription — its 5-hour and weekly use, live sessions, who may use
// it — filtered to 快满 in one click; a row's drawer pauses / resumes it,
// revokes its credential, renames it, and edits the allow list in place (one
// switch per person and node, written at once through the audited
// cred-policy route). Only today's reads and writes: /v1/limits · /v1/accounts ·
// /v1/fleet/credentials · /v1/live · /v1/fleet/users · /v1/account-switches ·
// /v1/fleet/settings (pool.paused.<account>, pool.skip_pct) ·
// /v1/admin/overview · /v1/fleet/cred-policy · /v1/nodes · /v1/accounts/label.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { ArrowRight, Bot, Cpu, Pause, Pencil, Play, Settings2, ShieldAlert, User } from "lucide-react";
import { Link, useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Alert, AlertDescription } from "@/components/ui/alert";
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
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { ConfirmByName } from "../ConfirmByName";
import { api, ApiError, type HubUser, type PolicyView, type UsersList } from "../api";
import { ago, inTime, t, when, type MsgKey } from "../i18n";
import {
  credState,
  entryOf,
  fingerprint,
  grantOf,
  leasesOf,
  room,
  settingOf,
  stateOf,
  subscriptions,
  togglePayload,
  userTargets,
  withOverview,
  type Account,
  type AccountLimits,
  type AccountSwitch,
  type Grant,
  type LiveSession,
  type OverviewPool,
  type PoolCredential,
  type State,
  type Sub,
  type Target,
  type Window,
} from "../pool";
import { monthlyLabel, planName } from "../plan";
import { AddSubscriptionDialog } from "./AddSubscriptionDialog";

const POLICY = "/v1/fleet/cred-policy";

type Row = Sub & { state: State; who: string };

// What a load carries besides the rows: the drawer's lists, the policy and
// the skip line (快满) — read once per load, never per row.
type World = {
  skip: number;
  view: PolicyView | null;
  targets: Target[];
  users: HubUser[];
  live: LiveSession[];
  switches: AccountSwitch[];
  vaultError: string;
  names: Map<string, string>; // account uuid → the row's name, for the switch list
};

// ---- small pieces ----

const STATE: Record<State, string> = {
  ok: "border-ok/40 text-ok",
  near: "border-warn/50 text-warn",
  limited: "border-destructive/50 text-destructive",
  reauth: "border-destructive/50 text-destructive",
  paused: "border-clay-line bg-clay-soft text-clay",
  unmanaged: "text-muted-foreground",
  unread: "text-muted-foreground",
};

function StateBadge({ s }: { s: State }) {
  return (
    <Badge variant="outline" className={cn("font-normal", STATE[s])}>
      {t(`pool.state.${s}` as MsgKey)}
    </Badge>
  );
}

function Bar({ w, skip, wide }: { w: Window | null; skip: number; wide?: boolean }) {
  if (!w || w.p == null) return <span className="text-muted-foreground">—</span>;
  return (
    <div className="flex items-center gap-2">
      <Progress
        value={w.p}
        className={cn(
          "h-1.5",
          wide ? "w-28" : "w-20",
          w.p >= 100 ? "[&>[data-slot=progress-indicator]]:bg-destructive" : w.p >= skip && "[&>[data-slot=progress-indicator]]:bg-warn",
        )}
      />
      <span className="font-mono text-xs text-muted-foreground tabular-nums">{w.p}%</span>
    </div>
  );
}

const serviceOf = (s: Sub) => s.prov === "codex" ? "Codex" : "Claude Code";
const priceOf = (s: Sub) => monthlyLabel(s.monthly, s.currency, t("pool.plan.per"));
const planOf = (s: Sub) => [planName(s.prov, s.plan, s.planTier) || t(s.plan ? "pool.plan.unknown" : "pool.plan.none"), priceOf(s)].filter(Boolean).join(" · ");
// ownerName is a member's own subscription's owner as the people page names them (claude-fleet#4035).
const ownerName = (w: World, principal: string) => w.users.find((u) => u.principal_id === principal)?.login || principal;
const uuidOf = (s: Sub) => s.cred?.account_uuid || s.cred?.credential_id || (s.id.startsWith("cred:") || s.id.startsWith("own:") ? String(s.cred?.account_uuid || "").toLowerCase() : s.id.toLowerCase());

// whoText is the table's 谁能用: the people and the nodes the policy lets use
// the subscription, in a few words.
function whoText(world: World, s: Sub): string {
  if (s.owner) return ownerName(world, s.owner); // a member's own: them alone
  if (!s.managed || !world.view) return t("pool.who.unknown");
  const uuid = uuidOf(s);
  const part = (scope: "user" | "node", all: MsgKey, none: MsgKey) => {
    const ts = world.targets.filter((x) => x.scope === scope && !x.service);
    const ok = ts.map((x) => grantOf(world.view!, x, uuid)).filter((g) => g.allowed);
    if (ts.length && ok.length === ts.length) return t(all);
    if (!ok.length) return t(none);
    const names = ok.slice(0, 2).map((g) => g.label);
    return ok.length > 2 ? t("pool.who.more", { names: names.join(" · "), n: ok.length - 2 }) : names.join(" · ");
  };
  return `${part("node", "pool.who.allMachines", "pool.who.noMachine")} · ${part("user", "pool.who.everyone", "pool.who.nobody")}`;
}

// machineTargets resolves each enrolled machine's identity once (a hostname
// is never an authorization key): the policy's own node ids, plus every
// endpoint /v1/nodes lists asked through cred-policy?endpoint_id=.
async function machineTargets(view: PolicyView): Promise<Target[]> {
  const out = new Map<string, Target>((view.nodes || []).map((n) => [n.id, { scope: "node", id: n.id, label: n.id }]));
  const snap = await api<{ nodes?: { endpoint_id?: string; hostname?: string }[] }>("/v1/nodes").catch(() => ({ nodes: [] }));
  const eps = [...new Map((snap.nodes || []).filter((n) => n.endpoint_id).map((n) => [n.endpoint_id!, n])).values()];
  const answers = await Promise.allSettled(eps.map((n) => api<{ effective?: { machine?: string } }>(`${POLICY}?endpoint_id=${encodeURIComponent(n.endpoint_id!)}`)));
  answers.forEach((a, i) => {
    const id = a.status === "fulfilled" ? a.value.effective?.machine : "";
    if (id) out.set(id, { scope: "node", id, label: id });
    else
      out.set(`unresolved:${eps[i].endpoint_id}`, {
        scope: "node",
        id: `unresolved:${eps[i].endpoint_id}`,
        label: eps[i].hostname || eps[i].endpoint_id!,
        error: a.status === "rejected" ? (a.reason as Error).message : "unknown",
      });
  });
  return [...out.values()];
}

// ---- the page ----

export function PoolPage() {
  const { id } = useParams();
  const nav = useNavigate();
  const [world, setWorld] = React.useState<World>({
    skip: 85,
    view: null,
    targets: [],
    users: [],
    live: [],
    switches: [],
    vaultError: "",
    names: new Map(),
  });

  const fetchRows = React.useCallback(async (): Promise<Row[]> => {
    const val = <T,>(r: PromiseSettledResult<T>): T | null => (r.status === "fulfilled" ? r.value : null);
    const [lim, acc, cr, live, us, sw, set, ov, pol] = await Promise.allSettled([
      api<{ per_account?: AccountLimits[] }>("/v1/limits?account=all"),
      api<Account[]>("/v1/accounts"),
      api<{ credentials?: PoolCredential[]; paused?: string[] }>("/v1/fleet/credentials"),
      api<{ sessions?: LiveSession[] }>("/v1/live"),
      api<UsersList>("/v1/fleet/users"),
      api<AccountSwitch[]>("/v1/account-switches?limit=50"),
      api("/v1/fleet/settings"),
      api<{ pool?: OverviewPool[] }>("/v1/admin/overview?since=1d"),
      api<PolicyView>(POLICY),
    ]);
    // a hub with neither usage nor a vault has nothing to draw: say why
    if (lim.status === "rejected" && cr.status === "rejected") throw lim.reason;
    const skip = Number(settingOf(val(set), "pool.skip_pct")) || 85;
    const view = val(pol);
    const users = val(us);
    const targets = view ? [...userTargets(view, users?.users || [], users?.admins || []), ...(await machineTargets(view))] : [];
    const w: World = {
      skip,
      view,
      targets,
      users: users?.users || [],
      live: val(live)?.sessions || [],
      switches: Array.isArray(val(sw)) ? val(sw)! : [],
      vaultError: cr.status === "rejected" ? (cr.reason as Error).message : "",
      names: new Map(),
    };
    const subs = withOverview(subscriptions({ limits: val(lim), accounts: val(acc), creds: val(cr), live: val(live) }), val(ov)?.pool);
    w.names = new Map(subs.map((s) => [s.id, s.label]));
    setWorld(w);
    return subs.map((s) => ({ ...s, state: stateOf(s, skip), who: whoText(w, s) }));
  }, []);

  const columns: ColumnDef<Row, any>[] = React.useMemo(
    () => [
      {
        accessorKey: "label",
        header: () => t("pool.col.sub"),
        cell: ({ row, getValue }) => (
          <span className="flex items-center gap-2">
            <span className="font-mono text-sm font-medium">{getValue()}</span>
            {row.original.owner && <Badge variant="outline" className="font-normal text-muted-foreground">{t("pool.own.badge", { name: ownerName(world, row.original.owner) })}</Badge>}
          </span>
        ),
      },
      { id: "service", accessorFn: serviceOf, header: () => t("pool.col.service") },
      { id: "plan", accessorFn: planOf, header: () => t("pool.col.plan"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue()}</span> },
      { id: "h5", accessorFn: (r) => r.h5?.p ?? undefined, sortUndefined: "last", header: () => t("pool.col.h5"), cell: ({ row }) => <Bar w={row.original.h5} skip={world.skip} /> },
      { id: "h7", accessorFn: (r) => r.h7?.p ?? undefined, sortUndefined: "last", header: () => t("pool.col.h7"), cell: ({ row }) => <Bar w={row.original.h7} skip={world.skip} /> },
      {
        accessorKey: "sessions",
        header: () => t("pool.col.sessions"),
        cell: ({ getValue }) => <span className="block pr-2 text-right font-mono tabular-nums">{getValue()}</span>,
      },
      {
        accessorKey: "who",
        header: () => t("pool.col.who"),
        enableSorting: false,
        cell: ({ getValue }) => (
          <span className="block max-w-52 truncate text-muted-foreground" title={getValue()}>
            {getValue()}
          </span>
        ),
      },
      { accessorKey: "state", header: () => t("pool.col.state"), cell: ({ row }) => <StateBadge s={row.original.state} /> },
    ],
    [world.skip, world.users],
  );

  const filters: Filter<Row>[] = React.useMemo(
    () => [
      { key: "claude", label: t("pool.filter.claude"), test: (r) => r.prov === "claude" },
      { key: "codex", label: t("pool.filter.codex"), test: (r) => r.prov === "codex" },
      { key: "near", label: t("pool.filter.near"), test: (r) => r.state === "near" || r.state === "limited" },
      { key: "paused", label: t("pool.filter.paused"), test: (r) => r.state === "paused" },
    ],
    [],
  );

  return (
    <>
      {world.vaultError && (
        <div className="mx-auto w-full max-w-6xl px-6 pt-6 md:px-8">
          <Alert>
            <ShieldAlert />
            <AlertDescription>{t("pool.vaultOff", { e: world.vaultError })}</AlertDescription>
          </Alert>
        </div>
      )}
      <AdminTablePage<Row>
        title={t("page.pool")}
        lead={t("pool.lead")}
        columns={columns}
        fetch={fetchRows}
        filters={filters}
        searchText={(r) => [r.label, serviceOf(r), planOf(r), r.who, r.people.join(" "), r.cred?.account, r.id, r.owner && ownerName(world, r.owner)].join(" ")}
        rowId={(r) => r.id}
        openId={id ? decodeURIComponent(id) : null}
        onOpen={(x) => nav(x ? `/pool/${encodeURIComponent(x)}` : "/pool")}
        emptyText={t("pool.empty")}
        kpis={(rows) => {
          const managed = rows.filter((r) => r.managed && !r.owner); // the pool's: a member's own is theirs
          const h5 = room(managed, "h5");
          const people = new Set<string>();
          for (const r of managed) for (const p of r.people) people.add(p);
          if (!people.size) for (const s of world.live) if (s.account && s.os_user) people.add(`${s.hostname}/${s.os_user}`);
          return [
            { label: t("pool.kpi.subs"), value: managed.length },
            { label: t("pool.kpi.h5"), value: h5 ? `${h5.left}%` : <span className="text-muted-foreground">—</span> },
            { label: t("pool.kpi.paused"), value: managed.filter((r) => r.paused).length },
            { label: t("pool.kpi.people"), value: people.size },
          ];
        }}
        actions={(reload, rows) => (
          <>
            <Button variant="outline" asChild>
              <Link to="/pool/settings">
                <Settings2 />
                {t("pool.settings")}
              </Link>
            </Button>
            <AddSubscriptionDialog known={rows.filter((r) => r.cred && !r.owner).map((r) => `${r.cred!.provider}/${r.cred!.account}`)} onAdded={reload} />
          </>
        )}
        drawer={(r, ctx) => <PoolDrawer r={r} world={world} {...ctx} />}
      />
    </>
  );
}

// ---- the drawer ----

function Field({ k, children }: { k: MsgKey; children: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{t(k)}</dt>
      <dd className="min-w-0">{children}</dd>
    </>
  );
}

function WindowField({ k, w, skip }: { k: MsgKey; w: Window | null; skip: number }) {
  const r = inTime(w?.resets);
  return (
    <Field k={k}>
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        {w?.p == null ? <span className="text-muted-foreground">{t("pool.d.noReading")}</span> : <Bar w={w} skip={skip} wide />}
        {r && <span className="text-xs text-muted-foreground">{t("pool.d.resets", { when: r })}</span>}
      </div>
    </Field>
  );
}

const CRED_TONE = { ok: "text-ok", warn: "text-warn", bad: "text-destructive" };

function PoolDrawer({ r, world, close, reload }: { r: Row; world: World; close: () => void; reload: () => void }) {
  const cs = credState(r.cred);
  const [refreshing, setRefreshing] = React.useState(false);
  const refresh = async () => {
    setRefreshing(true);
    try {
      const result = await api<{ quota: string }>("/v1/admin/subscriptions/refresh", { json: { provider: r.prov, account: r.cred!.account } });
      toast(t(result.quota === "ready" ? "pool.web.ready" : "pool.web.pending"));
      reload();
    } catch (e) { toast.error((e as Error).message); } finally { setRefreshing(false); }
  };
  const leases = leasesOf(world.live, r.id, world.users);
  const names = world.names;
  const switches = world.switches.filter((x) => x.from_account === r.id || x.to_account === r.id).slice(0, 6);

  const setPaused = async (on: boolean) => {
    try {
      await api("/v1/fleet/settings", { method: "PUT", json: { key: `pool.paused.${r.cred!.account}`, value: on ? "on" : "" } });
      toast.success(t(on ? "pool.paused" : "pool.resumed", { label: r.label }));
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    }
  };

  return (
    <>
      <SheetHeader className="border-b p-6">
        <div className="flex items-center gap-2 pr-8">
          <SheetTitle className="font-mono text-xl">{r.label}</SheetTitle>
          {!r.id.startsWith("cred:") && !r.owner && <RenameDialog r={r} onDone={reload} />}
        </div>
        <SheetDescription className="flex items-center gap-2">
          {serviceOf(r)} · {planOf(r)} <StateBadge s={r.state} />
        </SheetDescription>
      </SheetHeader>

      <div className="grid gap-6 p-6">
        {!r.managed && (
          <Alert>
            <AlertDescription className="text-xs">{t("pool.unmanagedHint")}</AlertDescription>
          </Alert>
        )}
        {r.owner && (
          <Alert>
            <AlertDescription className="text-xs">{t("pool.own.hint", { name: ownerName(world, r.owner) })}</AlertDescription>
          </Alert>
        )}
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="pool.plan.raw">{r.plan || "—"}{r.planTier && ` · ${r.planTier}`}</Field>
          <Field k="pool.plan.monthly">{priceOf(r) || t("pool.plan.none")}</Field>
          <Field k="pool.plan.source">{t(!r.plan ? "pool.plan.none" : r.planSource === "provider" ? "pool.plan.provider" : r.planSource === "admin" ? "pool.plan.admin" : "pool.plan.legacy")}</Field>
          <Field k="pool.plan.observed">{r.planAt ? when(r.planAt) : t("pool.plan.none")}</Field>
          <Field k="pool.web.expiry">{r.cred?.secret_expires_at ? when(r.cred.secret_expires_at) : t("pool.plan.none")}</Field>
          <WindowField k="pool.d.h5" w={r.h5} skip={world.skip} />
          <WindowField k="pool.d.h7" w={r.h7} skip={world.skip} />
          <Field k="pool.d.cred">
            <span className={CRED_TONE[cs.tone]}>{t(`pool.cred.${cs.key}` as MsgKey, { when: when(cs.at) })}</span>
          </Field>
          {(r.readAt || r.readStatus || r.readNote) && (
            <Field k="pool.d.read">
              <span title={r.readNote}>
                {r.readAt ? ago(r.readAt) : t("pool.d.unread")}
                {r.readVia && ` · ${t(r.readVia === "hub" ? "pool.d.viaHub" : "pool.d.viaNode")}`}
              </span>
              {r.readStatus === "failed" && <span className="block text-destructive">{t("pool.d.readFailed")}{r.readAttemptAt && ` · ${ago(r.readAttemptAt)}`}</span>}
              {r.readStatus === "stale" && <span className="block text-muted-foreground">{t("pool.d.stale")}</span>}
              {r.readNote && <span className="block text-xs text-muted-foreground">{r.readNote}</span>}
            </Field>
          )}
          <Field k="pool.d.sessions">
            <span className="font-mono tabular-nums">{r.sessions}</span>
          </Field>
          {r.people.length > 0 && <Field k="pool.d.people">{r.people.join(" · ")}</Field>}
          <Field k="pool.d.id">
            <span className="font-mono text-xs break-all text-muted-foreground">{uuidOf(r) || r.id}</span>
          </Field>
        </dl>

        {r.managed && !r.owner && world.view && (
          <>
            <Separator />
            <AccessEditor sub={r} view={world.view} targets={world.targets} onChanged={reload} />
          </>
        )}

        <Separator />
        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("pool.leases.title")}</h3>
          {leases.length ? (
            <ul className="grid gap-1.5">
              {leases.map((l, i) => (
                <li key={i} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm">
                  <span className="min-w-0 flex-1 truncate font-mono text-xs">{l.session}</span>
                  <span>{l.person}</span>
                  <span className="font-mono text-xs text-muted-foreground">{l.host}</span>
                  <span className="text-xs text-muted-foreground">{ago(l.since)}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("pool.leases.none")}</p>
          )}
        </section>

        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("pool.switches.title")}</h3>
          {switches.length ? (
            <ul className="grid gap-1.5 text-sm">
              {switches.map((x, i) => (
                <li key={i} className="flex items-center gap-2">
                  <span className="font-mono text-xs">{names.get(x.from_account || "") || x.from_account || "—"}</span>
                  <ArrowRight className="size-3.5 text-muted-foreground" />
                  <span className="font-mono text-xs">{names.get(x.to_account || "") || x.to_account || "—"}</span>
                  <span className="ml-auto text-xs text-muted-foreground">
                    {ago(x.observed_at)}
                    {x.endpoint_id && ` · ${x.endpoint_id}`}
                  </span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("pool.switches.none")}</p>
          )}
        </section>
      </div>

      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        {r.cred && !r.owner && <>
          <Button variant="outline" disabled={refreshing} onClick={refresh}>{t("pool.web.refresh")}</Button>
          <AddSubscriptionDialog known={[]} replace={{ provider: r.prov, account: r.cred.account }} onAdded={reload} />
        </>}

        {r.cred ? (
          <>
            {r.owner ? null : r.paused ? (
              <Button variant="outline" onClick={() => setPaused(false)}>
                <Play />
                {t("pool.resume")}
              </Button>
            ) : (
              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button variant="outline">
                    <Pause />
                    {t("pool.pause")}
                  </Button>
                </AlertDialogTrigger>
                <AlertDialogContent>
                  <AlertDialogHeader>
                    <AlertDialogTitle>{t("pool.pauseQ", { label: r.label })}</AlertDialogTitle>
                    <AlertDialogDescription>{t("pool.pauseBody", { n: r.sessions })}</AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
                    <AlertDialogAction onClick={() => setPaused(true)}>{t("pool.pause")}</AlertDialogAction>
                  </AlertDialogFooter>
                </AlertDialogContent>
              </AlertDialog>
            )}
            <ConfirmByName
              name={r.label}
              title={t("pool.revokeQ", { label: r.label })}
              body={t("pool.revokeBody")}
              ok={t("pool.revoke")}
              onConfirm={async () => {
                try {
                  await api("/v1/fleet/credentials", { json: { action: "delete", principal_id: r.owner || "pool", provider: r.cred!.provider, account: r.cred!.account } });
                  if (r.paused) await api("/v1/fleet/settings", { method: "PUT", json: { key: `pool.paused.${r.cred!.account}`, value: "" } }).catch(() => {});
                  toast.success(t("pool.revoked", { label: r.label }));
                  close();
                  reload();
                } catch (e) {
                  toast.error(t("err.action", { e: (e as Error).message }));
                }
              }}
            >
              <Button variant="destructive">{t("pool.revoke")}</Button>
            </ConfirmByName>
          </>
        ) : (
          <p className="mr-auto text-xs text-muted-foreground">{t("pool.notPool")}</p>
        )}
      </SheetFooter>
    </>
  );
}

// ---- 谁能用: one switch per person and node ----

function AccessEditor({ sub, view: first, targets, onChanged }: { sub: Sub; view: PolicyView; targets: Target[]; onChanged: () => void }) {
  const [view, setView] = React.useState(first);
  const [busy, setBusy] = React.useState("");
  const [force, setForce] = React.useState<{ message: string; g: Grant; on: boolean } | null>(null);
  React.useEffect(() => setView(first), [first]);
  const uuid = uuidOf(sub);
  const grants = targets.map((x) => grantOf(view, x, uuid));

  const write = async (g: Grant, on: boolean, forced = false) => {
    const body = togglePayload(g, uuid, on);
    if (!body) return;
    setBusy(`${g.scope}:${g.id}`);
    try {
      // no revision token: compare the rule just before writing (as the old page did)
      const latest = await api<PolicyView>(POLICY);
      if (fingerprint(entryOf(latest, g.scope, g.id)) !== fingerprint(g.entry)) {
        setView(latest);
        toast.error(t("policy.changed"));
        return;
      }
      await api(POLICY, { method: "PUT", json: forced ? { ...body, force: true } : body });
      setView(await api<PolicyView>(POLICY));
      toast.success(t(on ? "pool.access.on" : "pool.access.off", { name: g.label, sub: sub.label }));
      onChanged();
    } catch (e) {
      // a list that takes a provider's last subscription away is refused until the admin says so (#3713)
      if (e instanceof ApiError && e.status === 409 && /would keep no/.test(e.message) && !forced) setForce({ message: e.message, g, on });
      else toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy("");
    }
  };

  // three groups: people · services (svc:<name>, claude-fleet#4085 — a user scope of its own) · machines
  const group = (scope: "user" | "service" | "node") => {
    const gs = grants
      .filter((g) => (scope === "service" ? !!g.service : g.scope === scope && !g.service))
      .sort((a, b) => Number(b.allowed) - Number(a.allowed) || a.label.localeCompare(b.label));
    if (scope === "service" && !gs.length) return null; // a hub with no service shows no such group
    const Icon = scope === "user" ? User : scope === "service" ? Bot : Cpu;
    return (
      <div className="grid gap-1.5">
        <h4 className="flex items-center gap-2 text-sm font-medium">
          {t(scope === "user" ? "pool.access.people" : scope === "service" ? "pool.access.services" : "pool.access.machines")}
          <Badge variant="secondary" className="font-mono font-normal">
            {gs.filter((g) => g.allowed).length} / {gs.length}
          </Badge>
        </h4>
        {scope === "service" && <p className="text-xs text-muted-foreground">{t("pool.access.servicesLead")}</p>}
        {gs.length ? (
          <ul className="grid gap-1">
            {gs.map((g) => {
              const fixed = !togglePayload(g, uuid, !g.allowed);
              const key = `${g.scope}:${g.id}`;
              return (
                <li key={key} className="flex items-center gap-3 rounded-lg border px-3 py-2">
                  <Icon className="size-4 shrink-0 text-muted-foreground" />
                  <div className="grid min-w-0 flex-1">
                    <span className="truncate text-sm">{g.label}</span>
                    <span className="text-xs text-muted-foreground">{t(`pool.access.${g.why}` as MsgKey)}</span>
                  </div>
                  {fixed && g.why !== "unknown" && scope !== "service" ? (
                    scope === "user" ? (
                      <Button variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
                        <Link to={`/people/${encodeURIComponent(g.id)}`}>{t("pool.access.editAll")}</Link>
                      </Button>
                    ) : (
                      <Button variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
                        <Link to={`/machines/${encodeURIComponent(g.id)}`}>{t("pool.access.editAll")}</Link>
                      </Button>
                    )
                  ) : null}
                  <Switch
                    checked={g.allowed}
                    disabled={fixed || busy !== ""}
                    aria-label={g.label}
                    onCheckedChange={(on) => void write(g, on)}
                  />
                </li>
              );
            })}
          </ul>
        ) : (
          <p className="text-sm text-muted-foreground">{t("pool.access.none")}</p>
        )}
      </div>
    );
  };

  return (
    <section className="grid gap-3">
      <div>
        <h3 className="font-display text-base font-semibold">{t("pool.access.title")}</h3>
        <p className="text-xs text-muted-foreground">{t("pool.access.lead")}</p>
      </div>
      {view.mode === "legacy" && (
        <Alert>
          <AlertDescription className="text-xs">
            {t("pool.access.legacyNote")}{" "}
            <Link to="/pool/settings" className="underline underline-offset-2">
              {t("pool.settings")}
            </Link>
          </AlertDescription>
        </Alert>
      )}
      {group("user")}
      {group("service")}
      {group("node")}
      <AlertDialog open={!!force} onOpenChange={(o) => !o && setForce(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("policy.forceTitle")}</AlertDialogTitle>
            <AlertDialogDescription>{force?.message}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const f = force;
                setForce(null);
                if (f) void write(f.g, f.on, true);
              }}
            >
              {t("policy.forceOk")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}

// ---- 改名: /v1/accounts/label ----

function RenameDialog({ r, onDone }: { r: Sub; onDone: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [label, setLabel] = React.useState(r.label);
  const [busy, setBusy] = React.useState(false);
  const fid = React.useId();
  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (o) setLabel(r.label);
      }}
    >
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" className="size-7" aria-label={t("pool.rename")}>
          <Pencil className="size-3.5" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t("pool.renameTitle", { label: r.label })}</DialogTitle>
          <DialogDescription>{t("pool.renameHint")}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-2">
          <Label htmlFor={fid}>{t("pool.add.label")}</Label>
          <Input id={fid} value={label} onChange={(e) => setLabel(e.target.value)} className="font-mono" autoComplete="off" spellCheck={false} />
        </div>
        <DialogFooter>
          <Button
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              try {
                await api("/v1/accounts/label", { json: { account: r.id, label: label.trim() } });
                toast.success(t("pool.renamed"));
                setOpen(false);
                onDone();
              } catch (e) {
                toast.error(t("err.action", { e: (e as Error).message }));
              } finally {
                setBusy(false);
              }
            }}
          >
            {t("set.save")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
