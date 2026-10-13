// Audit — 审计, /admin/audit (EPIC #3923 C15; the old /app/admin/audit moves
// here). Everything that changed access, money or machines — the hub's own
// audit, the fleet audit, the credential and the device audit, merged by
// /v1/admin/audit — newest first. Filter by kind (?kind=, the old page's),
// by person (?who=) and by time (?range=today|7|30|60); the CSV export
// carries the same three (?kind= &actor= &since=). Stored text is shown as
// recorded, never translated.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { Check, ChevronsUpDown, Download, UserRound } from "lucide-react";
import { useSearchParams } from "react-router";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type AuditAnswer, type AuditEvent, type AuditKind } from "../api";
import { ago, lang, t, when, type MsgKey } from "../i18n";

const KINDS: AuditKind[] = ["user", "sub", "mach", "dev", "set", "sess"];
const RANGES = ["today", "7", "30", "60"] as const;
type Range = (typeof RANGES)[number];

// auditWho is the actor a row names, without the principal's "(gh:…)".
export const auditWho = (e: Pick<AuditEvent, "actor">) => String(e.actor || "").replace(/\s*\((gh|wecom|p)[^)]*\)$/, "") || "—";

type Outcome = "ok" | "denied" | "fail" | "other" | "none";
export function outcomeOf(e: Pick<AuditEvent, "action" | "outcome">): Outcome {
  const o = (e.outcome || "").toLowerCase();
  if (e.action === "role_denied" || o === "refused" || o === "denied") return "denied";
  if (o === "ok" || o === "success") return "ok";
  if (o === "error" || o === "failed" || o === "fail") return "fail";
  return o ? "other" : "none";
}

const OUTCOME: Record<Exclude<Outcome, "other" | "none">, { key: MsgKey; cls: string }> = {
  ok: { key: "outcome.ok", cls: "border-ok/40 text-ok" },
  denied: { key: "outcome.denied", cls: "border-destructive/50 text-destructive" },
  fail: { key: "outcome.fail", cls: "border-warn/50 text-warn" },
};

export function OutcomeBadge({ e }: { e: AuditEvent }) {
  const o = outcomeOf(e);
  if (o === "none") return <span className="text-muted-foreground">—</span>;
  if (o === "other")
    return (
      <Badge variant="outline" className="font-mono font-normal text-muted-foreground">
        {e.outcome}
      </Badge>
    );
  return (
    <Badge variant="outline" className={cn("font-normal", OUTCOME[o].cls)}>
      {t(OUTCOME[o].key)}
    </Badge>
  );
}

// since is where a range starts: today is local midnight.
function since(r: Range, now = new Date()): Date {
  if (r === "today") return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return new Date(now.getTime() - Number(r) * 86_400_000);
}

const hhmm = (iso: string) => new Date(iso).toLocaleTimeString(lang === "zh" ? "zh-CN" : "en", { hour: "2-digit", minute: "2-digit", hour12: false });
const day = (iso: string) => new Date(iso).toLocaleDateString(lang === "zh" ? "zh-CN" : "en", { month: "short", day: "numeric" });
const isToday = (iso: string) => new Date(iso) >= since("today");

type Row = AuditEvent & { id: string; who: string };

const columns: ColumnDef<Row, any>[] = [
  {
    id: "at",
    accessorFn: (r) => Date.parse(r.at),
    header: () => t("col.at"),
    cell: ({ row: { original: r } }) => (
      <div className="leading-tight" title={when(r.at)}>
        <span className="font-mono text-xs tabular-nums">{isToday(r.at) ? hhmm(r.at) : `${day(r.at)} ${hhmm(r.at)}`}</span>
        <span className="block text-xs text-muted-foreground">{ago(r.at)}</span>
      </div>
    ),
  },
  { accessorKey: "who", header: () => t("col.actor"), cell: ({ getValue }) => <span className="font-medium">{getValue()}</span> },
  { accessorKey: "action", header: () => t("col.action"), cell: ({ getValue }) => <span className="font-mono text-xs">{getValue()}</span> },
  {
    accessorKey: "target",
    header: () => t("col.target"),
    cell: ({ row: { original: r } }) => <span className="block max-w-72 truncate font-mono text-xs text-muted-foreground">{r.target || "—"}</span>,
  },
  {
    accessorKey: "kind",
    header: () => t("col.kind"),
    cell: ({ getValue }) => (
      <Badge variant="secondary" className="font-normal">
        {t(`audit.k.${getValue()}` as MsgKey)}
      </Badge>
    ),
  },
  { id: "outcome", accessorFn: (r) => outcomeOf(r), header: () => t("col.outcome"), cell: ({ row }) => <OutcomeBadge e={row.original} /> },
];

const filters: Filter<Row>[] = KINDS.map((k) => ({ key: k, label: t(`audit.k.${k}` as MsgKey), test: (r: Row) => r.kind === k }));

export function AuditPage() {
  const [q, setQ] = useSearchParams();
  const kind = KINDS.includes(q.get("kind") as AuditKind) ? (q.get("kind") as AuditKind) : "all";
  const who = q.get("who") || "";
  const range: Range = RANGES.includes(q.get("range") as Range) ? (q.get("range") as Range) : "60";
  const [days, setDays] = React.useState(60);
  const [actors, setActors] = React.useState<[string, number][]>([]);
  const [open, setOpen] = React.useState<string | null>(null);

  const set = (k: string, v: string, dflt: string) =>
    setQ(
      (p) => {
        const n = new URLSearchParams(p);
        if (v === dflt) n.delete(k);
        else n.set(k, v);
        return n;
      },
      { replace: true },
    );

  const fetchRows = React.useCallback(async (): Promise<Row[]> => {
    const a = await api<AuditAnswer>("/v1/admin/audit");
    setDays(a.days || 60);
    const rows = (a.events || []).map((e, i) => ({ ...e, id: `${e.at}#${i}`, who: auditWho(e) }));
    const n = new Map<string, number>();
    for (const r of rows) n.set(r.who, (n.get(r.who) || 0) + 1);
    setActors([...n.entries()].sort((x, y) => y[1] - x[1] || x[0].localeCompare(y[0])));
    return rows;
  }, []);

  const from = since(range);
  const inScope = React.useCallback((r: Row) => new Date(r.at) >= from && (!who || r.who === who), [from.getTime(), who]);

  const csv = new URLSearchParams({ format: "csv" });
  if (kind !== "all") csv.set("kind", kind);
  if (who) csv.set("actor", who);
  if (range !== "60") csv.set("since", from.toISOString());

  return (
    <AdminTablePage<Row>
      title={t("page.audit")}
      lead={t("audit.lead", { days })}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      defaultFilter={kind}
      onFilter={(v) => set("kind", v, "all")}
      where={inScope}
      toolbar={
        <>
          <WhoPicker actors={actors} who={who} onPick={(v) => set("who", v, "")} />
          <ToggleGroup type="single" variant="outline" size="sm" value={range} onValueChange={(v) => v && set("range", v, "60")}>
            {RANGES.map((r) => (
              <ToggleGroupItem key={r} value={r} className="px-3">
                {t(`audit.range.${r}` as MsgKey)}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </>
      }
      searchText={(r) => [r.who, r.actor, r.action, r.target, r.outcome, r.detail].join(" ")}
      rowId={(r) => r.id}
      openId={open}
      onOpen={setOpen}
      emptyText={t("audit.empty")}
      kpis={(rows) => {
        const scoped = rows.filter(inScope);
        return [
          { label: t("kpi.today"), value: rows.filter((r) => isToday(r.at) && (!who || r.who === who)).length },
          { label: t("kpi.inRange"), value: scoped.length },
          { label: t("kpi.actors"), value: new Set(scoped.map((r) => r.who)).size },
          { label: t("kpi.denied"), value: scoped.filter((r) => outcomeOf(r) === "denied").length },
        ];
      }}
      actions={() => (
        <Button asChild>
          <a href={`/v1/admin/audit?${csv}`} download>
            <Download />
            {t("audit.csv")}
          </a>
        </Button>
      )}
      drawer={(r, ctx) => (
        <AuditDrawer
          r={r}
          onlyThis={() => {
            set("who", r.who, "");
            ctx.close();
          }}
        />
      )}
    />
  );
}

function WhoPicker({ actors, who, onPick }: { actors: [string, number][]; who: string; onPick: (v: string) => void }) {
  const [open, setOpen] = React.useState(false);
  const pick = (v: string) => {
    onPick(v);
    setOpen(false);
  };
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" role="combobox" aria-expanded={open} className={cn("min-w-36 justify-between font-normal", who && "border-clay-line bg-clay-soft text-clay")}>
          <span className="flex items-center gap-1.5 truncate">
            <UserRound className="size-3.5" />
            {who || t("audit.who")}
          </span>
          <ChevronsUpDown className="size-3.5 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-60 p-0" align="start">
        <Command>
          <CommandInput placeholder={t("audit.whoSearch")} />
          <CommandList>
            <CommandEmpty>{t("audit.whoNone")}</CommandEmpty>
            <CommandGroup>
              <CommandItem value={`\u0000${t("audit.who")}`} onSelect={() => pick("")}>
                <Check className={cn("size-4", who ? "opacity-0" : "opacity-100")} />
                {t("audit.who")}
              </CommandItem>
              {actors.map(([a, n]) => (
                <CommandItem key={a} value={a} onSelect={() => pick(a)}>
                  <Check className={cn("size-4", who === a ? "opacity-100" : "opacity-0")} />
                  <span className="flex-1 truncate">{a}</span>
                  <span className="font-mono text-xs text-muted-foreground tabular-nums">{n}</span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
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

function AuditDrawer({ r, onlyThis }: { r: Row; onlyThis: () => void }) {
  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-mono text-lg">{r.action}</SheetTitle>
        <SheetDescription>{when(r.at)}</SheetDescription>
      </SheetHeader>
      <div className="p-6">
        <dl className="grid grid-cols-[7rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="col.actor">
            <span className="font-medium">{r.who}</span>
            {r.actor !== r.who && <span className="block font-mono text-xs text-muted-foreground">{r.actor}</span>}
          </Field>
          <Field k="col.target">
            <span className="font-mono text-xs">{r.target || "—"}</span>
          </Field>
          <Field k="col.outcome">
            <OutcomeBadge e={r} />
          </Field>
          <Field k="col.kind">{t(`audit.k.${r.kind}` as MsgKey)}</Field>
          <Field k="audit.source">{["hub", "fleet", "credential", "device"].includes(r.source) ? t(`audit.src.${r.source}` as MsgKey) : r.source}</Field>
          <Field k="audit.detail">
            <span className="font-mono text-xs whitespace-pre-wrap">{r.detail || "—"}</span>
          </Field>
        </dl>
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        <Button variant="outline" onClick={onlyThis}>
          <UserRound />
          {t("audit.onlyThis")}
        </Button>
      </SheetFooter>
    </>
  );
}
