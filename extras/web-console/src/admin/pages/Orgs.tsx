// Orgs — 组织, /admin/orgs and /admin/orgs/:o (task PNWW). One level above
// people: each person belongs to exactly one organization; an organization
// owns pools and a budget. Only the hub's own reads and writes:
// /v1/fleet/orgs · /v1/fleet/orgs/budget · /v1/fleet/pools — every write
// audited by the hub. Who is in which organization is set on the People page.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { AdminTablePage } from "../AdminTablePage";
import { ConfirmByName } from "../ConfirmByName";
import { api, type Org, type OrgPool } from "../api";
import { t, type MsgKey } from "../i18n";

const columns: ColumnDef<Org, any>[] = [
  {
    accessorKey: "org_id",
    header: () => t("orgs.col.id"),
    cell: ({ row: { original: o } }) => (
      <span className="flex items-center gap-2">
        <span className="font-medium">{o.name || o.org_id}</span>
        <span className="font-mono text-xs text-muted-foreground">{o.org_id}</span>
        {o.status === "disabled" && (
          <Badge variant="outline" className="font-normal text-destructive">
            {t("orgs.status.disabled")}
          </Badge>
        )}
      </span>
    ),
  },
  { id: "kind", accessorFn: (o) => t(`orgs.kind.${o.kind}` as MsgKey), header: () => t("orgs.col.kind") },
  { accessorKey: "members", header: () => t("orgs.col.members"), cell: ({ getValue }) => <span className="font-mono tabular-nums">{getValue()}</span> },
  { accessorKey: "pools", header: () => t("orgs.col.pools"), cell: ({ getValue }) => <span className="font-mono tabular-nums">{getValue()}</span> },
  {
    accessorKey: "budget",
    header: () => t("orgs.col.budget"),
    cell: ({ getValue }) => <span className="font-mono text-xs text-muted-foreground">{getValue() || "—"}</span>,
  },
  {
    id: "platform",
    accessorFn: (o) => (o.allow_platform_pool ? t("orgs.yes") : t("orgs.no")),
    header: () => t("orgs.col.platform"),
  },
];

export function OrgsPage() {
  const { o } = useParams();
  const nav = useNavigate();
  const fetchRows = React.useCallback(async () => (await api<{ orgs: Org[] }>("/v1/fleet/orgs")).orgs || [], []);
  return (
    <AdminTablePage<Org>
      title={t("page.orgs")}
      lead={t("orgs.lead")}
      columns={columns}
      fetch={fetchRows}
      searchText={(r) => [r.org_id, r.name, r.kind].join(" ")}
      rowId={(r) => r.org_id}
      openId={o ? decodeURIComponent(o) : null}
      onOpen={(id) => nav(id ? `/orgs/${encodeURIComponent(id)}` : "/orgs")}
      kpis={(rows) => [
        { label: t("orgs.kpi.orgs"), value: rows.length },
        { label: t("orgs.kpi.customers"), value: rows.filter((r) => r.kind === "customer").length },
        { label: t("orgs.kpi.members"), value: rows.reduce((a, r) => a + r.members, 0) },
      ]}
      actions={(reload) => <NewOrgDialog onDone={reload} />}
      drawer={(r, ctx) => <OrgDrawer o={r} {...ctx} />}
    />
  );
}

function NewOrgDialog({ onDone }: { onDone: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [id, setId] = React.useState("");
  const [name, setName] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const create = async () => {
    setBusy(true);
    try {
      await api("/v1/fleet/orgs", { json: { org_id: id.trim(), name: name.trim(), kind: "customer" } });
      toast.success(t("orgs.saved"));
      setOpen(false);
      setId("");
      setName("");
      onDone();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>{t("orgs.new")}</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t("orgs.new")}</DialogTitle>
          <DialogDescription>{t("orgs.newLead")}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="org-id">{t("orgs.col.id")}</Label>
            <Input id="org-id" placeholder="acme" value={id} onChange={(e) => setId(e.target.value)} />
          </div>
          <div className="grid gap-1">
            <Label htmlFor="org-name">{t("orgs.name")}</Label>
            <Input id="org-name" placeholder="Acme Inc." value={name} onChange={(e) => setName(e.target.value)} />
          </div>
        </div>
        <DialogFooter>
          <Button disabled={busy || !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(id.trim())} onClick={create}>
            {t("orgs.save")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function OrgDrawer({ o, close, reload }: { o: Org; close: () => void; reload: () => void }) {
  const [name, setName] = React.useState(o.name);
  const [platform, setPlatform] = React.useState(o.allow_platform_pool);
  const [disabled, setDisabled] = React.useState(o.status === "disabled");
  const [budget, setBudget] = React.useState(o.budget || "");
  const [pools, setPools] = React.useState<OrgPool[]>([]);
  const [poolId, setPoolId] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const loadPools = React.useCallback(() => {
    api<{ pools: OrgPool[] }>("/v1/fleet/pools")
      .then((b) => setPools((b.pools || []).filter((p) => p.owner_kind === "org" && p.owner_id === o.org_id)))
      .catch(() => setPools([]));
  }, [o.org_id]);
  React.useEffect(loadPools, [loadPools]);

  const run = async (fn: () => Promise<unknown>, done: string, after?: () => void) => {
    setBusy(true);
    try {
      await fn();
      toast.success(done);
      (after || reload)();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  const save = () =>
    run(async () => {
      if (o.manage && (name !== o.name || platform !== o.allow_platform_pool || disabled !== (o.status === "disabled"))) {
        await api("/v1/fleet/orgs", { json: { org_id: o.org_id, name, allow_platform_pool: platform, status: disabled ? "disabled" : "active" } });
      }
      if (budget !== (o.budget || "")) await api("/v1/fleet/orgs/budget", { json: { org_id: o.org_id, budget } });
    }, t("orgs.saved"));
  const pool = (p: Partial<OrgPool> & { pool_id: string }) =>
    run(() => api("/v1/fleet/pools", { json: { owner_kind: "org", owner_id: o.org_id, ...p } }), t("orgs.saved"), () => {
      setPoolId("");
      loadPools();
      reload();
    });

  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{o.name || o.org_id}</SheetTitle>
        <SheetDescription className="font-mono text-xs">
          {t(`orgs.kind.${o.kind}` as MsgKey)} · {o.org_id}
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6">
        <section className="grid gap-3">
          <div className="grid gap-1">
            <Label htmlFor="org-edit-name" className="text-xs">{t("orgs.name")}</Label>
            <Input id="org-edit-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <label className="flex items-center gap-2 text-sm">
            <Switch checked={platform} onCheckedChange={setPlatform} />
            {t("orgs.allowPlatform")}
          </label>
          <label className="flex items-center gap-2 text-sm">
            <Switch checked={disabled} onCheckedChange={setDisabled} />
            {t("orgs.disabled")}
          </label>
          <div className="grid gap-1">
            <Label htmlFor="org-budget" className="text-xs">{t("orgs.budget")}</Label>
            <Input id="org-budget" placeholder="5h=2M,week=20M,month=60M" value={budget} onChange={(e) => setBudget(e.target.value)} />
            <p className="text-xs text-muted-foreground">{t("orgs.budgetHint")}</p>
          </div>
          <div>
            <Button size="sm" disabled={busy} onClick={save}>
              {t("orgs.save")}
            </Button>
          </div>
        </section>

        <Separator />
        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("orgs.pools")}</h3>
          {pools.length ? (
            <ul className="grid gap-1.5">
              {pools.map((p) => (
                <li key={p.pool_id} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm">
                  <span className="min-w-0 flex-1 truncate">
                    {p.name} <span className="font-mono text-xs text-muted-foreground">{p.pool_id}</span>
                  </span>
                  <span className="font-mono text-xs text-muted-foreground tabular-nums" title={t("orgs.priority")}>
                    #{p.priority} · {p.credentials}
                  </span>
                  <Switch checked={p.enabled} disabled={busy || !p.manage} onCheckedChange={(v) => pool({ pool_id: p.pool_id, enabled: v })} />
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("orgs.noPools")}</p>
          )}
          {o.manage && (
            <div className="flex items-center gap-2">
              <Input placeholder={`${o.org_id}-pro`} value={poolId} onChange={(e) => setPoolId(e.target.value)} className="w-56" aria-label={t("orgs.poolId")} />
              <Button size="sm" variant="outline" disabled={busy || !poolId.trim()} onClick={() => pool({ pool_id: poolId.trim() })}>
                {t("orgs.newPool")}
              </Button>
            </div>
          )}
        </section>
      </div>
      {o.manage && o.kind === "customer" && (
        <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
          <ConfirmByName
            name={o.org_id}
            title={t("orgs.delete")}
            body={t("orgs.lead")}
            ok={t("orgs.delete")}
            onConfirm={() =>
              run(() => api("/v1/fleet/orgs", { json: { action: "delete", org_id: o.org_id } }), t("orgs.deleted"), () => {
                close();
                reload();
              })
            }
          >
            <Button variant="destructive">{t("orgs.delete")}</Button>
          </ConfirmByName>
        </SheetFooter>
      )}
    </>
  );
}
