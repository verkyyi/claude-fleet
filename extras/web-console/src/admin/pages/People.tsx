// People — 成员与开号, /admin/people and /admin/people/:p (EPIC #3923 C10;
// the old /app/admin/users and /app/admin/users/<principal> move here). Who
// may sign in, how, where their home is, how much they used this week; add,
// invite, remove, sign out everywhere, which subscriptions they may use; how
// many spare logins wait. Only today's reads and writes: /v1/fleet/users ·
// /v1/fleet/invites · /v1/fleet/users/sessions · /v1/fleet/person-usage ·
// /v1/nodes (spares) · /v1/fleet/cred-policy — every write audited by the hub.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { ConfirmByName } from "../ConfirmByName";
import { api, type HubUser, type Invite, type NodeMachine, type PersonBudget, type UsersList } from "../api";
import { ago, t, when, type MsgKey } from "../i18n";
import { NewPersonDialog } from "./NewPersonDialog";
import { PolicyEditor } from "./PolicyEditor";

type Status = "ok" | "near" | "over" | "never" | "invited";

type Row = {
  id: string; // a person's principal, or an invite's id
  name: string;
  admin: boolean;
  via: string[];
  home: string;
  week: number | null; // % of the weekly limit
  usedWeek?: number;
  limitWeek?: number;
  seen?: string;
  status: Status;
  user?: HubUser;
  invite?: Invite;
};

const NEAR = 80;

function rowOf(u: HubUser, b?: PersonBudget): Row {
  const home = u.logins.find((l) => l.home) || u.logins.find((l) => l.kind === "node");
  const week = b?.limit_week ? Math.min(100, Math.round(((b.used_week || 0) / b.limit_week) * 100)) : null;
  const status: Status = b?.over || (week ?? 0) >= 100 ? "over" : (week ?? 0) >= NEAR ? "near" : !u.last_seen ? "never" : "ok";
  return {
    id: u.principal || `gh:${u.github_id}`,
    name: u.login,
    admin: u.role === "admin" || !!u.deploy,
    via: u.via || (u.github_id ? ["github"] : []),
    home: home?.hostname || "",
    week,
    usedWeek: b?.used_week,
    limitWeek: b?.limit_week,
    seen: u.last_seen,
    status,
    user: u,
  };
}

const inviteRow = (i: Invite): Row => ({
  id: i.id,
  name: i.email || i.github_login || t("invite.anyone"),
  admin: false,
  via: i.email ? ["email"] : i.github_login ? ["github"] : [],
  home: "",
  week: null,
  status: "invited",
  invite: i,
});

const tokens = (n?: number) => (n == null ? "—" : n >= 1e6 ? `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(n));

const STATUS: Record<Status, { key: MsgKey; cls: string }> = {
  ok: { key: "status.ok", cls: "border-ok/40 text-ok" },
  near: { key: "status.near", cls: "border-warn/50 text-warn" },
  over: { key: "status.over", cls: "border-destructive/50 text-destructive" },
  never: { key: "status.never", cls: "text-muted-foreground" },
  invited: { key: "status.invited", cls: "border-clay-line bg-clay-soft text-clay" },
};

function StatusBadge({ s }: { s: Status }) {
  return (
    <Badge variant="outline" className={cn("font-normal", STATUS[s].cls)}>
      {t(STATUS[s].key)}
    </Badge>
  );
}

function WeekBar({ r }: { r: Row }) {
  if (r.week == null) return <span className="text-muted-foreground">{r.usedWeek != null ? tokens(r.usedWeek) : "—"}</span>;
  return (
    <div className="flex items-center gap-2">
      <Progress value={r.week} className={cn("h-1.5 w-20", r.week >= NEAR && "[&>[data-slot=progress-indicator]]:bg-warn")} />
      <span className="font-mono text-xs text-muted-foreground tabular-nums">{r.week}%</span>
    </div>
  );
}

const viaText = (via: string[]) => (via.length ? via.map((v) => t(`via.${v}` as MsgKey)).join(" · ") : "—");

const columns: ColumnDef<Row, any>[] = [
  {
    accessorKey: "name",
    header: () => t("col.name"),
    cell: ({ row: { original: r } }) => (
      <div className="flex items-center gap-3">
        <Avatar className="size-7">
          <AvatarFallback className="bg-muted text-xs font-medium">{[...r.name][0]?.toUpperCase()}</AvatarFallback>
        </Avatar>
        <span className="font-medium">{r.name}</span>
        {r.admin && (
          <Badge variant="outline" className="border-clay-line bg-clay-soft font-normal text-clay">
            {t("role.admin")}
          </Badge>
        )}
      </div>
    ),
  },
  { id: "via", accessorFn: (r) => viaText(r.via), header: () => t("col.via"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue()}</span> },
  { accessorKey: "home", header: () => t("col.home"), cell: ({ getValue }) => <span className="font-mono text-xs">{getValue() || "—"}</span> },
  { accessorKey: "week", header: () => t("col.week"), sortUndefined: "last", cell: ({ row }) => <WeekBar r={row.original} /> },
  {
    id: "seen",
    accessorFn: (r) => (r.seen ? Date.parse(r.seen) : 0),
    header: () => t("col.seen"),
    cell: ({ row: { original: r } }) => <span className="text-muted-foreground">{r.status === "invited" ? "—" : ago(r.seen) || t("seen.never")}</span>,
  },
  { accessorKey: "status", header: () => t("col.status"), cell: ({ row }) => <StatusBadge s={row.original.status} /> },
];

const filters: Filter<Row>[] = [
  { key: "admin", label: t("filter.admin"), test: (r) => r.admin },
  { key: "near", label: t("filter.near"), test: (r) => r.status === "near" || r.status === "over" },
  { key: "invited", label: t("filter.invited"), test: (r) => r.status === "invited" },
];

type Extra = { spare: number; target: number } | null;

export function PeoplePage() {
  const { p } = useParams();
  const nav = useNavigate();
  const [spares, setSpares] = React.useState<Extra | undefined>(undefined);

  const fetchRows = React.useCallback(async (): Promise<Row[]> => {
    const [users, invites, usage, nodes] = await Promise.all([
      api<UsersList>("/v1/fleet/users"),
      api<{ invites: Invite[] }>("/v1/fleet/invites"),
      api<{ people: PersonBudget[] }>("/v1/fleet/person-usage").catch(() => ({ people: [] as PersonBudget[] })),
      api<{ machines?: NodeMachine[] }>("/v1/nodes").catch(() => null),
    ]);
    const ms = (nodes?.machines || []).filter((m) => m.spare_target != null || m.spare != null);
    setSpares(ms.length ? { spare: ms.reduce((a, m) => a + (m.spare || 0), 0), target: ms.reduce((a, m) => a + (m.spare_target || 0), 0) } : null);
    const budget = new Map((usage.people || []).map((b) => [b.principal, b]));
    const rows = (users.users || []).map((u) => rowOf(u, budget.get(u.principal || `gh:${u.github_id}`)));
    rows.sort((a, b) => Number(!!b.user?.deploy) - Number(!!a.user?.deploy) || Number(b.admin) - Number(a.admin) || a.name.localeCompare(b.name));
    return [...rows, ...(invites.invites || []).filter((i) => i.state === "active").map(inviteRow)];
  }, []);

  return (
    <AdminTablePage<Row>
      title={t("page.people")}
      lead={t("people.lead")}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      searchText={(r) => [r.name, r.id, r.home, viaText(r.via), r.user?.logins.map((l) => l.login).join(" ")].join(" ")}
      rowId={(r) => r.id}
      openId={p ? decodeURIComponent(p) : null}
      onOpen={(id) => nav(id ? `/people/${encodeURIComponent(id)}` : "/people")}
      kpis={(rows) => [
        { label: t("kpi.members"), value: rows.filter((r) => r.user).length },
        { label: t("kpi.admins"), value: rows.filter((r) => r.admin).length },
        { label: t("kpi.invites"), value: rows.filter((r) => r.invite).length },
        spares
          ? { label: t("kpi.spares"), value: `${spares.spare} / ${spares.target}` }
          : { label: t("kpi.sparesOff"), value: <span className="text-muted-foreground">—</span> },
      ]}
      actions={(reload, rows) => <NewPersonDialog known={rows.filter((r) => r.user).map((r) => r.name)} onChanged={reload} />}
      drawer={(r, ctx) => (r.invite ? <InviteDrawer r={r} {...ctx} /> : <PersonDrawer r={r} {...ctx} />)}
    />
  );
}

function Field({ k, children }: { k: MsgKey; children: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{t(k)}</dt>
      <dd className="min-w-0">{children}</dd>
    </>
  );
}

function PersonDrawer({ r, close, reload }: { r: Row; close: () => void; reload: () => void }) {
  const u = r.user!;
  const key = u.principal || u.login;
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{r.name}</SheetTitle>
        <SheetDescription className="font-mono text-xs">
          {u.deploy ? t("role.deploy") : t(r.admin ? "role.admin" : "role.user")} · {r.id}
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="drawer.via">{viaText(r.via)}</Field>
          <Field k="drawer.home">
            <span className="font-mono text-xs">{r.home || "—"}</span>
          </Field>
          <Field k="drawer.week">
            <WeekBar r={r} />
          </Field>
          <Field k="drawer.limit">{r.limitWeek ? `${tokens(r.usedWeek)} / ${tokens(r.limitWeek)} tokens` : t("drawer.noLimit")}</Field>
          <Field k="drawer.seen">{ago(r.seen) || t("seen.never")}</Field>
          <Field k="drawer.added">
            <span className="font-mono text-xs">{u.added_by || "—"}</span>
          </Field>
          <Field k="drawer.addedAt">{when(u.added_at)}</Field>
        </dl>

        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("drawer.logins")}</h3>
          {u.logins.length ? (
            <ul className="grid gap-1.5">
              {u.logins.map((l) => (
                <li key={`${l.hostname}/${l.login}/${l.kind}`} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm">
                  <span className="min-w-0 flex-1 truncate font-mono text-xs">
                    {l.hostname} · {l.login}
                  </span>
                  {l.home && (
                    <Badge variant="outline" className="border-clay-line bg-clay-soft font-normal text-clay">
                      {t("drawer.home")}
                    </Badge>
                  )}
                  <Badge variant="secondary" className="font-normal">
                    {t(`login.kind.${l.kind}` as MsgKey)}
                  </Badge>
                  <Badge
                    variant="outline"
                    className={cn("font-normal", l.state === "active" ? "text-ok" : l.state === "failed" ? "text-destructive" : "text-muted-foreground")}
                  >
                    {t(`login.state.${["active", "failed", "removed"].includes(l.state) ? l.state : "unknown"}` as MsgKey)}
                  </Badge>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("drawer.noLogins")}</p>
          )}
        </section>

        <Separator />
        <PolicyEditor id={key} />
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        {u.deploy ? (
          <p className="mr-auto text-xs text-muted-foreground">{t("drawer.deployLocked")}</p>
        ) : (
          <>
            <ConfirmByName
              name={r.name}
              title={t("signout.title", { name: r.name })}
              body={t("signout.body")}
              ok={t("signout.ok")}
              onConfirm={async () => {
                try {
                  await api("/v1/fleet/users/sessions", { json: { login: key } });
                  toast.success(t("signout.done", { name: r.name }));
                } catch (e) {
                  toast.error(t("err.action", { e: (e as Error).message }));
                }
              }}
            >
              <Button variant="outline">{t("drawer.signout")}</Button>
            </ConfirmByName>
            <ConfirmByName
              name={r.name}
              title={t("remove.title", { name: r.name })}
              body={t("remove.body")}
              ok={t("remove.ok")}
              onConfirm={async () => {
                try {
                  const out = await api<UsersList>(`/v1/fleet/users?login=${encodeURIComponent(key)}`, { method: "DELETE" });
                  toast.success(t("remove.done", { name: r.name, n: out.devices_revoked ?? 0 }));
                  close();
                  reload();
                } catch (e) {
                  toast.error(t("err.action", { e: (e as Error).message }));
                }
              }}
            >
              <Button variant="destructive">{t("drawer.remove")}</Button>
            </ConfirmByName>
          </>
        )}
      </SheetFooter>
    </>
  );
}

function InviteDrawer({ r, close, reload }: { r: Row; close: () => void; reload: () => void }) {
  const i = r.invite!;
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{r.name}</SheetTitle>
        <SheetDescription className="flex items-center gap-2 font-mono text-xs">
          <StatusBadge s="invited" /> {i.id}
        </SheetDescription>
      </SheetHeader>
      <div className="p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="drawer.inviteFor">{i.email || i.github_login || t("invite.anyone")}</Field>
          <Field k="drawer.invitedBy">
            <span className="font-mono text-xs">{i.created_by || "—"}</span>
          </Field>
          <Field k="drawer.addedAt">{when(i.created_at)}</Field>
          <Field k="drawer.inviteExpires">{when(i.expires_at)}</Field>
        </dl>
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        <ConfirmByName
          name={r.name}
          title={t("revoke.title", { name: r.name })}
          body={t("revoke.body")}
          ok={t("revoke.ok")}
          onConfirm={async () => {
            try {
              await api(`/v1/fleet/invites?id=${encodeURIComponent(i.id)}`, { method: "DELETE" });
              toast.success(t("revoke.done"));
              close();
              reload();
            } catch (e) {
              toast.error(t("err.action", { e: (e as Error).message }));
            }
          }}
        >
          <Button variant="destructive">{t("drawer.revoke")}</Button>
        </ConfirmByName>
      </SheetFooter>
    </>
  );
}
