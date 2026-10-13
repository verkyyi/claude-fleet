// Machines — 机器与 pod, /admin/machines (EPIC #3923 C11; the old /app/nodes
// and its ?tab=clients — once /app/admin/devices — move here). Three tabs on
// one table frame: 服务节点 (the fixed machines that run sessions), pod (SPOT
// pods the cluster rents and people's own pods, with the SPOT switch), 客户端
// (every person's client devices, revoke). State, load, sessions, version,
// whether its door is open; a row opens its page (/admin/machines/:host).
// 「添加机器」 is today's one-time join code flow. Reads /v1/nodes · /version ·
// /v1/fleet/settings · /v1/admin/devices · /v1/fleet/users (owners); writes
// fleet.spot, /v1/fleet/nodes/join-codes, /v1/fleet/devices/revoke — every
// write audited by the hub.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { ArrowRight, Check, Copy, Loader2, Plus } from "lucide-react";
import { useNavigate, useSearchParams } from "react-router";
import { toast } from "sonner";
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
import { Card, CardContent } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter, type Kpi } from "../AdminTablePage";
import { api, type UsersList } from "../api";
import { ago, t as ta, when } from "../i18n";
import { tm, type MKey } from "../machines/i18n";
import {
  clientRows,
  machineRows,
  type ClientRow,
  type DevicesResponse,
  type JoinCode,
  type JoinCodes,
  type MachineRow,
  type NodesSnapshot,
  type SettingsView,
  type Status,
  type VersionInfo,
} from "../machines/model";

type Tab = "nodes" | "pods" | "clients";

type Loaded = {
  snap: NodesSnapshot | null;
  machines: MachineRow[];
  clients: ClientRow[] | null;
  spotOn: boolean | null;
};

async function loadAll(): Promise<Loaded> {
  const [snapR, verR, setR, devR, usersR] = await Promise.allSettled([
    api<NodesSnapshot>("/v1/nodes"),
    api<VersionInfo>("/version"),
    api<SettingsView>("/v1/fleet/settings"),
    api<DevicesResponse>("/v1/admin/devices"),
    api<UsersList>("/v1/fleet/users"),
  ]);
  const snap = snapR.status === "fulfilled" ? snapR.value : null;
  const ver = verR.status === "fulfilled" ? verR.value : null;
  const owners = new Map<string, string>();
  if (usersR.status === "fulfilled") for (const u of usersR.value.users || []) owners.set(u.principal || `gh:${u.github_id}`, u.login);
  const spot = setR.status === "fulfilled" ? (setR.value.hub || []).find((h) => h.key === "fleet.spot") : undefined;
  return {
    snap,
    machines: snap ? machineRows(snap, ver) : [],
    clients: devR.status === "fulfilled" ? clientRows(devR.value, snap, owners) : null,
    spotOn: setR.status === "fulfilled" ? spot?.value === "on" : null,
    // the tab's own read failing fails the tab (below); the others are a courtesy
    ...(snapR.status === "rejected" ? { snapErr: snapR.reason } : {}),
    ...(devR.status === "rejected" ? { devErr: devR.reason } : {}),
  } as Loaded;
}

// ---- cells ------------------------------------------------------------------

const STATUS: Record<Status, { key: MKey; cls: string }> = {
  online: { key: "status.online", cls: "border-ok/40 text-ok" },
  maintenance: { key: "status.maintenance", cls: "border-warn/50 text-warn" },
  lost: { key: "status.lost", cls: "border-destructive/50 text-destructive" },
  starting: { key: "status.starting", cls: "text-muted-foreground" },
  reclaim: { key: "status.reclaim", cls: "border-clay-line bg-clay-soft text-clay" },
  releasing: { key: "status.releasing", cls: "border-clay-line bg-clay-soft text-clay" },
  reclaiming: { key: "status.reclaiming", cls: "border-destructive/50 text-destructive" },
};

export function StatusBadge({ r }: { r: Pick<MachineRow, "status" | "reclaimMin"> }) {
  const s = STATUS[r.status];
  return (
    <Badge variant="outline" className={cn("font-normal", s.cls)}>
      {tm(s.key, { n: r.reclaimMin ?? 0 })}
    </Badge>
  );
}

export const kindText = (k: MachineRow["kind"]) => tm(k === "fixed" ? "kind.fixed" : k === "spot" ? "kind.spot" : "kind.person");

export function DoorText({ d }: { d: MachineRow["door"] }) {
  if (d.state === "open") return <span className="font-mono text-xs">{tm("door.open", { port: d.port || 22 })}</span>;
  if (d.state === "cluster") return <span>{tm("door.cluster")}</span>;
  return <span className="text-muted-foreground">{tm(d.state === "off" ? "door.off" : "door.unknown")}</span>;
}

export function VersionText({ r }: { r: MachineRow }) {
  if (!r.version) return <span className="text-muted-foreground">—</span>;
  return (
    <span className="inline-flex items-center gap-1.5 font-mono text-xs">
      {r.version}
      {r.behind && r.stableShort && r.stableShort !== r.version && (
        <span className="inline-flex items-center gap-1 text-warn">
          <ArrowRight className="size-3" />
          {r.stableShort}
        </span>
      )}
      {r.behind && (!r.stableShort || r.stableShort === r.version) && <span className="size-1.5 rounded-full bg-warn" />}
    </span>
  );
}

const machineColumns: ColumnDef<MachineRow, any>[] = [
  {
    accessorKey: "label",
    header: () => tm("col.name"),
    cell: ({ row: { original: r } }) => (
      <div className="flex items-baseline gap-2">
        <span className="font-mono text-sm font-medium">{r.label}</span>
        {r.label !== r.id && <span className="font-mono text-xs text-muted-foreground">{r.id}</span>}
      </div>
    ),
  },
  { id: "kind", accessorFn: (r) => kindText(r.kind), header: () => tm("col.kind"), cell: ({ getValue }) => <span className="text-muted-foreground">{getValue()}</span> },
  { accessorKey: "status", header: () => tm("col.status"), cell: ({ row }) => <StatusBadge r={row.original} /> },
  {
    accessorKey: "loadCore",
    header: () => <span className="block text-right">{tm("col.load")}</span>,
    sortUndefined: "last",
    cell: ({ row: { original: r } }) => (
      <span className={cn("block text-right font-mono text-xs tabular-nums", (r.loadCore ?? 0) >= 1 && "text-warn")}>{r.loadCore == null ? "—" : r.loadCore.toFixed(2)}</span>
    ),
  },
  {
    accessorKey: "sessions",
    header: () => <span className="block text-right">{tm("col.sessions")}</span>,
    sortUndefined: "last",
    cell: ({ row: { original: r } }) => (
      <span className="block text-right font-mono text-xs tabular-nums">
        {r.sessions == null ? "—" : r.cap ? `${r.sessions} / ${r.cap}` : r.sessions}
      </span>
    ),
  },
  { id: "version", accessorFn: (r) => r.version, header: () => tm("col.version"), cell: ({ row }) => <VersionText r={row.original} /> },
  { id: "door", accessorFn: (r) => r.door.state, header: () => tm("col.door"), cell: ({ row }) => <DoorText d={row.original.door} /> },
];

const clientColumns: ColumnDef<ClientRow, any>[] = [
  {
    accessorKey: "name",
    header: () => tm("col.device"),
    cell: ({ row: { original: r } }) => (
      <div className="min-w-0">
        <p className="truncate font-medium">{r.name}</p>
        <p className="truncate font-mono text-xs text-muted-foreground" title={r.kind === "machine" ? undefined : r.id}>
          {r.kind === "machine" ? tm("kind.clientMachine") : r.id.length > 22 ? r.id.slice(0, 21) + "…" : r.id}
        </p>
      </div>
    ),
  },
  { accessorKey: "owner", header: () => tm("col.owner"), cell: ({ getValue }) => <span className="font-mono text-xs">{getValue() || "—"}</span> },
  {
    id: "registered",
    accessorFn: (r) => (r.registered ? Date.parse(r.registered) : 0),
    header: () => tm("col.registered"),
    cell: ({ row: { original: r } }) => <span className="text-muted-foreground">{r.registered ? when(r.registered) : "—"}</span>,
  },
  {
    id: "lastUsed",
    accessorFn: (r) => (r.lastUsed ? Date.parse(r.lastUsed) : 0),
    header: () => tm("col.lastUsed"),
    cell: ({ row: { original: r } }) => <span className="text-muted-foreground">{ago(r.lastUsed || undefined) || "—"}</span>,
  },
  { accessorKey: "lastMachine", header: () => tm("col.lastMachine"), cell: ({ getValue }) => <span className="font-mono text-xs">{getValue() || "—"}</span> },
  {
    accessorKey: "renewals",
    header: () => <span className="block text-right">{tm("col.renewals")}</span>,
    cell: ({ getValue }) => <span className="block text-right font-mono text-xs tabular-nums">{getValue() ?? "—"}</span>,
  },
  {
    accessorKey: "revoked",
    header: () => tm("col.status"),
    cell: ({ row: { original: r } }) => (
      <Badge variant="outline" className={cn("font-normal", r.revoked ? "border-destructive/50 text-destructive" : "border-ok/40 text-ok")}>
        {tm(r.revoked ? "status.revoked" : "status.active")}
      </Badge>
    ),
  },
];

const machineFilters: Filter<MachineRow>[] = [
  { key: "online", label: tm("filter.online"), test: (r) => r.status === "online" || r.status === "reclaim" },
  { key: "maint", label: tm("filter.maint"), test: (r) => r.status === "maintenance" },
  { key: "lost", label: tm("filter.lost"), test: (r) => r.status === "lost" },
  { key: "behind", label: tm("filter.behind"), test: (r) => r.behind },
  { key: "door", label: tm("filter.doorOpen"), test: (r) => r.door.state === "open" || r.door.state === "cluster" },
];

const clientFilters: Filter<ClientRow>[] = [
  { key: "active", label: tm("filter.active"), test: (r) => !r.revoked },
  { key: "revoked", label: tm("filter.revoked"), test: (r) => r.revoked },
];

// ---- the page ---------------------------------------------------------------

export function MachinesPage() {
  const [sp, setSp] = useSearchParams();
  const nav = useNavigate();
  const raw = sp.get("tab");
  const tab: Tab = raw === "clients" ? "clients" : raw === "pods" ? "pods" : "nodes";
  const [data, setData] = React.useState<Loaded | null>(null);

  const setTab = (v: string) => {
    const q = new URLSearchParams(sp);
    if (v === "nodes") q.delete("tab");
    else q.set("tab", v);
    nav({ pathname: "/machines", search: q.toString() ? `?${q}` : "" });
  };

  const counts = data
    ? {
        nodes: data.machines.filter((r) => r.kind === "fixed").length,
        pods: data.machines.filter((r) => r.kind !== "fixed").length,
        clients: data.clients ? data.clients.filter((r) => !r.revoked).length : null,
      }
    : null;

  const tabs = (
    <Tabs value={tab} onValueChange={setTab}>
      <TabsList>
        {(["nodes", "pods", "clients"] as Tab[]).map((k) => (
          <TabsTrigger key={k} value={k} className="gap-2 px-3">
            {tm(`tab.${k}` as MKey)}
            {counts && counts[k] != null && <span className="font-mono text-xs text-muted-foreground tabular-nums">{counts[k]}</span>}
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  );

  const kpis = (): Kpi[] => {
    const ms = data?.machines || [];
    return [
      { label: tm("kpi.machines"), value: ms.filter((r) => r.kind === "fixed").length },
      { label: tm("kpi.pods"), value: ms.filter((r) => r.kind !== "fixed").length },
      { label: tm("kpi.maint"), value: ms.filter((r) => r.status === "maintenance").length },
      { label: tm("kpi.behind"), value: <span className={cn(ms.some((r) => r.behind) && "text-warn")}>{ms.filter((r) => r.behind).length}</span> },
    ];
  };

  const fetchMachines = React.useCallback(
    async (pods: boolean) => {
      const d = await loadAll();
      setData(d);
      if ((d as any).snapErr) throw (d as any).snapErr;
      return d.machines.filter((r) => (r.kind !== "fixed") === pods);
    },
    [],
  );
  const fetchClients = React.useCallback(async () => {
    const d = await loadAll();
    setData(d);
    if ((d as any).devErr) throw (d as any).devErr;
    return d.clients || [];
  }, []);

  if (tab === "clients") {
    return (
      <AdminTablePage<ClientRow>
        key="clients"
        title={ta("page.machines")}
        lead={tm("lead")}
        nav={tabs}
        kpis={kpis}
        columns={clientColumns}
        fetch={fetchClients}
        filters={clientFilters}
        searchText={(r) => [r.name, r.id, r.owner, r.lastMachine].join(" ")}
        rowId={(r) => r.id}
        openId={sp.get("device")}
        onOpen={(id) => {
          const q = new URLSearchParams(sp);
          if (id) q.set("device", id);
          else q.delete("device");
          setSp(q, { replace: true });
        }}
        emptyText={tm("empty.clients")}
        drawer={(r, ctx) => <ClientDrawer r={r} {...ctx} />}
      />
    );
  }

  const pods = tab === "pods";
  return (
    <AdminTablePage<MachineRow>
      key={tab}
      title={ta("page.machines")}
      lead={tm("lead")}
      nav={tabs}
      kpis={kpis}
      columns={machineColumns}
      fetch={() => fetchMachines(pods)}
      filters={machineFilters}
      searchText={(r) => [r.label, r.id, r.host, kindText(r.kind), r.version, r.logins.join(" ")].join(" ")}
      rowId={(r) => r.id}
      onOpen={(id) => {
        const r = data?.machines.find((x) => x.id === id);
        if (r?.m) nav(`/machines/${encodeURIComponent(id!)}`);
      }}
      emptyText={tm(pods ? "empty.pods" : "empty.nodes")}
      actions={(reload) => <AddMachine onJoined={reload} />}
      aside={() => (pods ? <SpotCard snap={data?.snap || null} on={data?.spotOn ?? null} onChanged={(on) => setData((d) => (d ? { ...d, spotOn: on } : d))} /> : null)}
    />
  );
}

// ---- SPOT -------------------------------------------------------------------

function SpotCard({ snap, on, onChanged }: { snap: NodesSnapshot | null; on: boolean | null; onChanged: (on: boolean) => void }) {
  const [busy, setBusy] = React.useState(false);
  const spot = snap?.spot;
  const n = (spot?.nodes || []).length;
  const line = !snap ? "" : !spot ? tm("spot.none") : on ? tm("spot.on", { max: spot.max || 0, idle: spot.idle_minutes || 30, n }) : tm("spot.off", { n });
  return (
    <Card className="gap-0 py-4">
      <CardContent className="flex items-center justify-between gap-6 px-5">
        <div className="min-w-0">
          <p className="font-display text-base font-semibold">{tm("spot.title")}</p>
          <p className="text-xs text-muted-foreground">{tm("spot.sub")}</p>
          {line && <p className="mt-1.5 text-sm">{line}</p>}
        </div>
        <Switch
          checked={!!on}
          disabled={on == null || busy}
          aria-label={tm("spot.title")}
          onCheckedChange={async (v) => {
            setBusy(true);
            try {
              await api("/v1/fleet/settings", { method: "PUT", json: { key: "fleet.spot", value: v ? "on" : "off" } });
              toast.success(tm(v ? "spot.onToast" : "spot.offToast"));
              onChanged(v);
            } catch (e) {
              toast.error(tm("err.action", { e: (e as Error).message }));
            } finally {
              setBusy(false);
            }
          }}
        />
      </CardContent>
    </Card>
  );
}

// ---- 添加机器 -----------------------------------------------------------------

const countdown = (expires: string, now = Date.now()) => {
  const s = Math.max(0, Math.round((Date.parse(expires) - now) / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

function AddMachine({ onJoined }: { onJoined: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [j, setJ] = React.useState<JoinCode | null>(null);
  const [joined, setJoined] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [copied, setCopied] = React.useState(false);
  const [, tick] = React.useState(0);
  const label = React.useRef("");

  // the code's countdown, and the wait for the machine to come in
  React.useEffect(() => {
    if (!open || !j || joined) return;
    const t1 = setInterval(() => tick((x) => x + 1), 1000);
    const t2 = setInterval(async () => {
      try {
        const codes = await api<JoinCodes>("/v1/fleet/join-codes");
        const hit = (codes.codes || []).find((c) => c.label === label.current && c.used_at);
        if (hit) {
          setJoined(hit.joined_host || "—");
          toast.success(tm("add.joined", { host: hit.joined_host || "—" }));
          onJoined();
        }
      } catch {
        /* keep waiting */
      }
    }, 3000);
    return () => {
      clearInterval(t1);
      clearInterval(t2);
    };
  }, [open, j, joined, onJoined]);

  const start = async () => {
    setBusy(true);
    try {
      // 托管 (claude-fleet#2214): the code carries trust — no separate 「标记可信」 step
      label.current = "web-" + Date.now().toString(36);
      const code = await api<JoinCode>("/v1/fleet/nodes/join-codes", { json: { label: label.current } });
      setJ(code);
      setJoined("");
      setOpen(true);
    } catch (e) {
      toast.error(tm("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Button onClick={start} disabled={busy}>
        {busy ? <Loader2 className="animate-spin" /> : <Plus />}
        {tm("add.btn")}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle className="font-display">{tm("add.title")}</DialogTitle>
            <DialogDescription>{tm("add.run")}</DialogDescription>
          </DialogHeader>
          {j && (
            <div className="grid gap-4">
              <div className="flex items-center gap-2 rounded-lg border bg-muted/40 p-2 pl-3">
                <code className="min-w-0 flex-1 font-mono text-xs break-all">{j.command}</code>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={async () => {
                    await navigator.clipboard?.writeText(j.command).catch(() => {});
                    setCopied(true);
                    setTimeout(() => setCopied(false), 1500);
                  }}
                >
                  {copied ? <Check /> : <Copy />}
                  {tm(copied ? "add.copied" : "add.copy")}
                </Button>
              </div>
              <dl className="grid grid-cols-[6rem_1fr] gap-x-4 gap-y-2 text-sm">
                <dt className="text-muted-foreground">{tm("add.code")}</dt>
                <dd className="font-mono">{j.code}</dd>
                <dt className="text-muted-foreground">{tm("add.works")}</dt>
                <dd>{tm("add.once")}</dd>
                <dt className="text-muted-foreground">{tm("add.expires")}</dt>
                <dd className="font-mono tabular-nums">{countdown(j.expires_at)}</dd>
              </dl>
              <div className={cn("flex items-center gap-2 rounded-lg border px-3 py-2.5 text-sm", joined ? "border-ok/40 text-ok" : "text-muted-foreground")}>
                {joined ? <Check className="size-4" /> : <Loader2 className="size-4 animate-spin" />}
                {joined ? tm("add.joined", { host: joined }) : tm("add.waiting")}
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              {tm("add.close")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

// ---- a client ---------------------------------------------------------------

function ClientDrawer({ r, close, reload }: { r: ClientRow; close: () => void; reload: () => void }) {
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display text-xl">{r.name}</SheetTitle>
        <SheetDescription className="font-mono text-xs break-all">{r.kind === "machine" ? tm("kind.clientMachine") : r.id}</SheetDescription>
      </SheetHeader>
      <div className="p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <dt className="text-muted-foreground">{tm("col.owner")}</dt>
          <dd className="font-mono text-xs">{r.owner || "—"}</dd>
          <dt className="text-muted-foreground">{tm("col.registered")}</dt>
          <dd>{r.registered ? when(r.registered) : "—"}</dd>
          <dt className="text-muted-foreground">{tm("col.lastUsed")}</dt>
          <dd>{ago(r.lastUsed || undefined) || "—"}</dd>
          <dt className="text-muted-foreground">{tm("col.lastMachine")}</dt>
          <dd className="font-mono text-xs">{r.lastMachine || "—"}</dd>
          <dt className="text-muted-foreground">{tm("col.renewals")}</dt>
          <dd className="font-mono text-xs">{r.renewals ?? "—"}</dd>
          <dt className="text-muted-foreground">{tm("col.status")}</dt>
          <dd>{tm(r.revoked ? "status.revoked" : "status.active")}</dd>
          {r.revoked && r.revokedBy && (
            <>
              <dt className="text-muted-foreground">{tm("client.revokedBy")}</dt>
              <dd className="font-mono text-xs">{r.revokedBy}</dd>
            </>
          )}
        </dl>
        {r.kind === "machine" && <p className="mt-4 text-sm text-muted-foreground">{tm("client.machineNote")}</p>}
      </div>
      {r.kind === "device" && !r.revoked && (
        <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="destructive">{tm("revoke.btn")}</Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>{tm("revoke.q", { name: r.name })}</AlertDialogTitle>
                <AlertDialogDescription>{tm("revoke.body")}</AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>{tm("confirm.cancel")}</AlertDialogCancel>
                <AlertDialogAction
                  className="bg-destructive text-white hover:bg-destructive/90"
                  onClick={async () => {
                    try {
                      await api("/v1/fleet/devices/revoke", { json: { fingerprint: r.id } });
                      toast.success(tm("revoke.done", { name: r.name }));
                      close();
                      reload();
                    } catch (e) {
                      toast.error(tm("revoke.fail", { e: (e as Error).message }));
                    }
                  }}
                >
                  {tm("revoke.ok")}
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </SheetFooter>
      )}
    </>
  );
}
