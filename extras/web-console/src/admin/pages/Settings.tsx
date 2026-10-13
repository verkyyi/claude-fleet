// Settings — 入口设置, /admin/settings and /admin/settings/:k (EPIC #3923 C15;
// the old /app/admin/settings moves here). The hub's own settings
// (/v1/fleet/settings, applied at once, one audit row a change): the public
// counter and badges, the pool's skip threshold and failover, where a
// newcomer lands, spare logins, SPOT machines. The team layer
// (/v1/fleet/team-bundle): publish a file as its next version, go back to an
// older one — one step, audited. And, read-only (部署写死), what the deploy
// sets: the admins and the ways in (/v1/access). When and by whom a row last
// changed comes from the audit (/v1/admin/audit).
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { History, Lock, RotateCcw, Upload } from "lucide-react";
import { useNavigate, useParams } from "react-router";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type AccessAnswer, type AuditAnswer, type AuditEvent, type HubSetting, type SettingsAnswer, type TeamBundle, type UsersList } from "../api";
import { ago, t, when, type MsgKey } from "../i18n";
import { auditWho, OutcomeBadge } from "./Audit";

type Type = "onoff" | "pct" | "count" | "hosts" | "names";
type Group = "public" | "pool" | "people" | "team" | "deploy";

// The settings this page edits — the old page's, in its order.
const EDITABLE: { key: string; type: Type; group: Group }[] = [
  { key: "hub.public_meter", type: "onoff", group: "public" },
  { key: "hub.public_badges", type: "onoff", group: "public" },
  { key: "pool.skip_pct", type: "pct", group: "pool" },
  { key: "pool.move_when_full", type: "onoff", group: "pool" },
  { key: "fleet.auto_assign", type: "hosts", group: "people" },
  { key: "fleet.machine_names", type: "names", group: "people" },
  { key: "fleet.spot", type: "onoff", group: "people" },
  { key: "fleet.spares", type: "onoff", group: "people" },
  { key: "fleet.spare_max", type: "count", group: "people" },
];

type Row = {
  id: string;
  group: Group;
  name: string;
  help: string;
  value: string; // as shown
  raw?: string; // as stored
  type?: Type;
  source?: HubSetting["source"];
  env?: string; // a deploy row's variable
  changed?: string;
  by?: string;
  history?: AuditEvent[];
  team?: TeamBundle | null;
};

const show = (type: Type | undefined, v: string) =>
  type === "onoff" ? t(v === "on" ? "set.on" : "set.off") : v === "" ? t("set.none") : type === "pct" ? `${v}%` : v;

// teamItems flattens a team bundle into [kind, text] lines (the old page's bundleItems).
function teamItems(b?: Record<string, any>): [string, string][] {
  const out: [string, string][] = [];
  const obj = (k: string) => (b && b[k] && typeof b[k] === "object" && !Array.isArray(b[k]) ? b[k] : {});
  const short = (v: unknown) => {
    const s = typeof v === "string" ? v : JSON.stringify(v);
    return s.length > 80 ? s.slice(0, 77) + "…" : s;
  };
  for (const n of Object.keys(obj("mcp")).sort()) out.push(["mcp", n]);
  for (const [ev, list] of Object.entries(obj("hooks")))
    for (const h of Array.isArray(list) ? list : []) out.push(["hook", `${ev}${h?.matcher ? " " + h.matcher : ""} · ${short(h?.command || "")}`]);
  for (const n of Object.keys(obj("hook_scripts")).sort()) out.push(["script", n]);
  for (const n of Object.keys(obj("skills")).sort()) out.push(["skill", n]);
  for (const [k, v] of Object.entries(obj("claude_settings"))) out.push(["claude", `${k} = ${short(v)}`]);
  for (const [k, v] of Object.entries(obj("codex_config"))) out.push(["codex", `${k} = ${short(v)}`]);
  return out;
}

const SOURCE: Record<string, { key: MsgKey; cls: string }> = {
  default: { key: "set.src.default", cls: "text-muted-foreground" },
  legacy: { key: "set.src.legacy", cls: "border-warn/50 text-warn" },
  deploy: { key: "set.src.deploy", cls: "text-muted-foreground" },
};

function LockedBadge() {
  return (
    <Badge variant="outline" className="gap-1 font-normal text-muted-foreground">
      <Lock className="size-3" />
      {t("set.locked")}
    </Badge>
  );
}

const columns: ColumnDef<Row, any>[] = [
  {
    accessorKey: "name",
    header: () => t("col.setting"),
    cell: ({ row: { original: r } }) => (
      <div className="leading-tight">
        <span className="font-medium">{r.name}</span>
        <span className="block text-xs text-muted-foreground">{t(`set.g.${r.group}` as MsgKey)}</span>
      </div>
    ),
  },
  {
    accessorKey: "value",
    header: () => t("col.value"),
    cell: ({ row: { original: r } }) => (
      <div className="flex items-center gap-2">
        <span className={cn("max-w-72 truncate", r.type && r.type !== "onoff" && r.type !== "pct" && "font-mono text-xs", r.raw === "" && "text-muted-foreground")}>{r.value}</span>
        {r.source && SOURCE[r.source] && (
          <Badge variant="outline" className={cn("font-normal", SOURCE[r.source].cls)}>
            {t(SOURCE[r.source].key)}
          </Badge>
        )}
      </div>
    ),
  },
  {
    id: "changed",
    accessorFn: (r) => (r.changed ? Date.parse(r.changed) : 0),
    header: () => t("col.changed"),
    sortUndefined: "last",
    cell: ({ row: { original: r } }) => (
      <span className="text-muted-foreground" title={r.changed ? when(r.changed) : undefined}>
        {r.changed ? ago(r.changed) : "—"}
      </span>
    ),
  },
  {
    accessorKey: "by",
    header: () => t("col.changedBy"),
    cell: ({ row: { original: r } }) => (r.group === "deploy" ? <LockedBadge /> : <span>{r.by || "—"}</span>),
  },
];

const filters: Filter<Row>[] = [
  { key: "editable", label: t("filter.editable"), test: (r) => r.group !== "deploy" },
  { key: "readonly", label: t("filter.readonly"), test: (r) => r.group === "deploy" },
];

const WAYS: ["wechat" | "email" | "github", MsgKey][] = [
  ["wechat", "via.wechat"],
  ["email", "via.email"],
  ["github", "via.github"],
];

type Extra = { autoAssign: string; team: string; meter: string; ways: string };

export function SettingsPage() {
  const { k } = useParams();
  const nav = useNavigate();
  const [extra, setExtra] = React.useState<Extra | null>(null);

  const fetchRows = React.useCallback(async (): Promise<Row[]> => {
    const [set, users, access, team, audit] = await Promise.all([
      api<SettingsAnswer>("/v1/fleet/settings"),
      api<UsersList>("/v1/fleet/users").catch(() => null),
      api<AccessAnswer>("/v1/access").catch(() => null),
      // no team layer on this hub: a 404, the row says so
      api<TeamBundle>("/v1/fleet/team-bundle?history=1").catch((e) => (e.status === 404 ? null : Promise.reject(e))),
      api<AuditAnswer>("/v1/admin/audit?kind=all").catch(() => ({ events: [] as AuditEvent[] }) as AuditAnswer),
    ]);
    const changes = new Map<string, AuditEvent[]>();
    for (const e of audit.events || []) {
      const key = e.action === "setting" ? e.target || "" : e.action === "team_bundle_put" ? "team" : "";
      if (key) changes.set(key, [...(changes.get(key) || []), e]);
    }
    const valueOf = (key: string) => {
      const h = (set.hub || []).find((x) => x.key === key);
      if (h) return { value: h.value, source: h.source };
      const v = set.settings?.[key];
      return { value: v == null ? "" : String(v), source: (v == null ? "default" : "set") as HubSetting["source"] };
    };
    const rows: Row[] = EDITABLE.map((it) => {
      const { value, source } = valueOf(it.key);
      const hist = changes.get(it.key) || [];
      return {
        id: it.key,
        group: it.group,
        type: it.type,
        name: t(`set.k.${it.key}` as MsgKey),
        help: t(`set.h.${it.key}` as MsgKey),
        value: show(it.type, value),
        raw: value,
        source,
        changed: hist[0]?.at,
        by: hist[0] && auditWho(hist[0]),
        history: hist,
      };
    });
    const items = team ? teamItems(team.bundle).length : 0;
    rows.push({
      id: "team",
      group: "team",
      name: t("set.g.team"),
      help: t("team.lead"),
      value: team?.version ? t("team.value", { v: team.version, n: items }) : t("team.none"),
      raw: team?.version ? String(team.version) : "",
      changed: team?.created,
      by: team?.actor ? auditWho({ actor: team.actor }) : undefined,
      history: changes.get("team") || [],
      team,
    });
    const hub = access?.hub;
    const ways = hub ? WAYS.filter(([w]) => hub[w]).map(([, key]) => t(key)).join(" · ") || "—" : "—";
    const conf = (on?: boolean) => (on == null ? "—" : t(on ? "set.configured" : "set.notConfigured"));
    rows.push(
      { id: "deploy.admins", group: "deploy", name: t("set.admins"), help: "", value: (users?.admins || []).map((a) => a.login).join(" · ") || "—", env: "CCQUOTA_GITHUB_ADMINS" },
      { id: "deploy.ways", group: "deploy", name: t("set.ways"), help: t("set.waysSub"), value: ways, env: "CCQUOTA_WECHAT_* · CCQUOTA_SMTP_* · CCQUOTA_GITHUB_CLIENT_*" },
      { id: "deploy.github", group: "deploy", name: t("set.ghApp"), help: t("set.ghAppSub"), value: conf(hub?.github), env: "CCQUOTA_GITHUB_CLIENT_ID · CCQUOTA_GITHUB_CLIENT_SECRET" },
      { id: "deploy.secrets", group: "deploy", name: t("set.secrets"), help: t("set.secretsSub"), value: t("set.k8s"), env: "k8s Secret" },
    );
    setExtra({
      autoAssign: valueOf("fleet.auto_assign").value || t("set.none"),
      team: team?.version ? `v${team.version}` : "—",
      meter: show("onoff", valueOf("hub.public_meter").value),
      ways,
    });
    return rows;
  }, []);

  return (
    <AdminTablePage<Row>
      title={t("page.settings")}
      lead={t("entry.lead")}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      searchText={(r) => [r.name, r.id, r.value, r.help, r.by].join(" ")}
      rowId={(r) => r.id}
      openId={k ? decodeURIComponent(k) : null}
      onOpen={(id) => nav(id ? `/settings/${encodeURIComponent(id)}` : "/settings")}
      kpis={() =>
        extra
          ? [
              { label: t("kpi.autoAssign"), value: <span className="block truncate">{extra.autoAssign}</span> },
              { label: t("kpi.team"), value: extra.team },
              { label: t("kpi.meter"), value: extra.meter },
              { label: t("kpi.ways"), value: <span className="block truncate">{extra.ways}</span> },
            ]
          : []
      }
      drawer={(r, ctx) =>
        r.group === "team" ? (
          <TeamDrawer key={`${r.id}@${r.raw}`} r={r} reload={ctx.reload} />
        ) : r.group === "deploy" ? (
          <DeployDrawer r={r} />
        ) : (
          <SettingDrawer key={`${r.id}@${r.raw}`} r={r} reload={ctx.reload} />
        )
      }
    />
  );
}

function Head({ r }: { r: Row }) {
  return (
    <SheetHeader className="border-b p-6">
      <SheetTitle className="font-display text-xl">{r.name}</SheetTitle>
      <SheetDescription className="font-mono text-xs">{r.group === "deploy" ? r.env : r.group === "team" ? "/v1/fleet/team-bundle" : r.id}</SheetDescription>
    </SheetHeader>
  );
}

function Changes({ list }: { list: AuditEvent[] }) {
  return (
    <section className="grid gap-2">
      <h3 className="flex items-center gap-1.5 font-display text-base font-semibold">
        <History className="size-4" />
        {t("set.recent")}
      </h3>
      {list.length ? (
        <ul className="grid gap-1.5">
          {list.slice(0, 6).map((e, i) => (
            <li key={i} className="grid gap-0.5 rounded-lg border px-3 py-2 text-sm">
              <div className="flex items-center gap-2">
                <span className="font-medium">{auditWho(e)}</span>
                <span className="text-xs text-muted-foreground" title={when(e.at)}>
                  {ago(e.at)}
                </span>
                <span className="ml-auto">
                  <OutcomeBadge e={e} />
                </span>
              </div>
              {e.detail && <span className="font-mono text-xs break-all text-muted-foreground">{e.detail}</span>}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">{t("set.noRecent")}</p>
      )}
    </section>
  );
}

function SettingDrawer({ r, reload }: { r: Row; reload: () => void }) {
  const [draft, setDraft] = React.useState(r.raw || "");
  const [busy, setBusy] = React.useState(false);
  const field = React.useId();
  const dirty = draft.trim() !== (r.raw || "");
  const save = async () => {
    setBusy(true);
    try {
      await api("/v1/fleet/settings", { method: "PUT", json: { key: r.id, value: draft.trim() } });
      toast.success(t("entry.saved"));
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <Head r={r} />
      <div className="grid gap-6 p-6 [&>*]:min-w-0">
        <p className="text-sm text-muted-foreground">{r.help}</p>
        <div className="grid gap-2">
          <Label htmlFor={field}>{t("col.value")}</Label>
          {r.type === "onoff" ? (
            <div className="flex items-center gap-3">
              <Switch id={field} checked={draft === "on"} onCheckedChange={(on) => setDraft(on ? "on" : "off")} />
              <span className="text-sm">{t(draft === "on" ? "set.on" : "set.off")}</span>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <Input
                id={field}
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                inputMode={r.type === "pct" || r.type === "count" ? "numeric" : undefined}
                placeholder={r.type === "names" ? "mac-a.local=mac-a, mac-b.local=mac-b" : r.type === "hosts" ? "least-busy · mac-a, mac-b · none" : undefined}
                className={cn(r.type === "pct" || r.type === "count" ? "w-24 text-right tabular-nums" : "font-mono text-xs")}
                onKeyDown={(e) => e.key === "Enter" && dirty && save()}
              />
              {r.type === "pct" && <span className="text-sm text-muted-foreground">%</span>}
            </div>
          )}
          {r.source && SOURCE[r.source] && (
            <p className="text-xs text-muted-foreground">
              {t(SOURCE[r.source].key)} · <code className="font-mono">{r.id}</code>
            </p>
          )}
        </div>
        <Changes list={r.history || []} />
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        <Button variant="outline" disabled={!dirty || busy} onClick={() => setDraft(r.raw || "")}>
          {t("confirm.cancel")}
        </Button>
        <Button disabled={!dirty || busy} onClick={save}>
          {t("entry.save")}
        </Button>
      </SheetFooter>
    </>
  );
}

function TeamDrawer({ r, reload }: { r: Row; reload: () => void }) {
  const tb = r.team;
  const file = React.useRef<HTMLInputElement>(null);
  const [busy, setBusy] = React.useState(false);
  const base = tb?.version || 0;
  const items = tb ? teamItems(tb.bundle) : [];
  const history = tb?.history || [];
  const prev = tb?.prev || history.find((h) => h.version < base)?.version || 0;

  const restore = async (v: number) => {
    setBusy(true);
    try {
      const out = await api<TeamBundle>("/v1/fleet/team-bundle", { method: "PUT", json: { restore: v, base } });
      toast.success(t("team.restored", { v, n: out?.version ?? "" }));
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };
  const publish = async (f: File) => {
    setBusy(true);
    try {
      let v: any;
      try {
        v = JSON.parse(await f.text());
      } catch {
        throw new Error(t("team.notJson"));
      }
      if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error(t("team.notJson"));
      const bundle = v.bundle && typeof v.bundle === "object" ? v.bundle : v;
      const out = await api<TeamBundle>("/v1/fleet/team-bundle", { method: "PUT", json: { bundle, base, note: `Published ${f.name}` } });
      toast.success(t("team.published", { v: out?.version ?? "" }));
      reload();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
      if (file.current) file.current.value = "";
    }
  };

  return (
    <>
      <Head r={r} />
      <div className="grid gap-6 p-6 [&>*]:min-w-0">
        <p className="text-sm text-muted-foreground">{r.help}</p>
        <section className="grid gap-2">
          <h3 className="flex items-center gap-2 font-display text-base font-semibold">
            {t("team.items")}
            {base > 0 && (
              <Badge variant="outline" className="border-clay-line bg-clay-soft font-mono font-normal text-clay">
                v{base}
              </Badge>
            )}
          </h3>
          {items.length ? (
            <ul className="grid gap-1">
              {items.map(([kind, text], i) => (
                <li key={i} className="flex items-center gap-2 rounded-md border px-3 py-1.5 text-sm">
                  <Badge variant="secondary" className="w-14 justify-center font-mono font-normal">
                    {kind}
                  </Badge>
                  <span className="min-w-0 truncate font-mono text-xs">{text}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{base ? t("team.empty") : t("team.none")}</p>
          )}
        </section>
        {history.length > 0 && (
          <section className="grid gap-2">
            <h3 className="flex items-center gap-1.5 font-display text-base font-semibold">
              <History className="size-4" />
              {t("team.history")}
            </h3>
            <ol className="grid gap-1.5">
              {history.map((h) => (
                <li key={h.version} className={cn("flex items-center gap-3 rounded-lg border px-3 py-2 text-sm", h.version === base && "border-clay-line bg-clay-soft")}>
                  <span className="font-mono font-medium">v{h.version}</span>
                  <div className="min-w-0 flex-1 leading-tight">
                    <span className="block truncate">{h.note || "—"}</span>
                    <span className="text-xs text-muted-foreground">
                      {h.actor ? auditWho({ actor: h.actor }) : "—"} · <span title={when(h.created)}>{ago(h.created)}</span>
                    </span>
                  </div>
                  {h.version === base ? (
                    <Badge variant="outline" className="border-clay-line font-normal text-clay">
                      {t("team.current")}
                    </Badge>
                  ) : (
                    <RestoreButton v={h.version} busy={busy} onConfirm={restore} variant="ghost" size="sm" label={t("team.restore", { v: h.version })} />
                  )}
                </li>
              ))}
            </ol>
          </section>
        )}
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        <input ref={file} type="file" accept="application/json,.json" hidden onChange={(e) => e.target.files?.[0] && publish(e.target.files[0])} />
        <Button variant="outline" disabled={busy} onClick={() => file.current?.click()}>
          <Upload />
          {t("team.publish")}
        </Button>
        {prev > 0 ? (
          <RestoreButton v={prev} busy={busy} onConfirm={restore} label={t("team.back")} icon />
        ) : (
          <Button disabled>{t("team.noPrev")}</Button>
        )}
      </SheetFooter>
    </>
  );
}

function RestoreButton(p: {
  v: number;
  busy: boolean;
  onConfirm: (v: number) => void;
  label: string;
  icon?: boolean;
  variant?: "default" | "ghost";
  size?: "default" | "sm";
}) {
  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button variant={p.variant || "default"} size={p.size || "default"} disabled={p.busy}>
          {p.icon && <RotateCcw />}
          {p.label}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t("team.restoreTitle", { v: p.v })}</AlertDialogTitle>
          <AlertDialogDescription>{t("team.restoreBody", { v: p.v })}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
          <AlertDialogAction onClick={() => p.onConfirm(p.v)}>{t("team.restore", { v: p.v })}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function DeployDrawer({ r }: { r: Row }) {
  return (
    <>
      <Head r={r} />
      <div className="grid gap-4 p-6">
        {r.help && <p className="text-sm text-muted-foreground">{r.help}</p>}
        <div className="flex items-center gap-3 rounded-lg border px-4 py-3">
          <span className="min-w-0 flex-1 break-words">{r.value}</span>
          <LockedBadge />
        </div>
        <p className="text-xs text-muted-foreground">{t("set.lockedHint", { env: r.env || "" })}</p>
      </div>
    </>
  );
}
