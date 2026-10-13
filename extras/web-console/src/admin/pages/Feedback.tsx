// Feedback — 反馈, /admin/feedback and /admin/feedback/:id (EPIC #3923 C15;
// the old /app/admin/feedback moves here). Every /fleet-feedback the hub
// took, newest first: 待处理 (not filed yet, or filed and open) and 已回复
// (closed — the reply went back). A row opens what the public issue never
// says — who, the login, the machine, the session — the attachments, the
// GitHub issue and the reply, plus 「在 GitHub 打开」 and 「标为重复」, as
// today. /v1/admin/feedback; an admin's.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { Copy, Download, ExternalLink, Eye, Paperclip } from "lucide-react";
import { useNavigate, useParams } from "react-router";
import { toast } from "sonner";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { AdminTablePage, type Filter } from "../AdminTablePage";
import { api, type Feedback, type FeedbackDetail, type FeedbackPage } from "../api";
import { ago, t, when, type MsgKey } from "../i18n";

// one read holds at most this many pages of 200
const MAX_PAGES = 5;

const STATE: Record<Feedback["state"], { key: MsgKey; cls: string }> = {
  received: { key: "fb.s.received", cls: "border-warn/50 text-warn" },
  filed: { key: "fb.s.filed", cls: "border-clay-line bg-clay-soft text-clay" },
  closed: { key: "fb.s.closed", cls: "border-ok/40 text-ok" },
};

function StateBadge({ s }: { s: Feedback["state"] }) {
  const st = STATE[s] || { key: "fb.s.received", cls: "" };
  return (
    <Badge variant="outline" className={cn("font-normal", st.cls)}>
      {t(st.key)}
    </Badge>
  );
}

const kindOf = (k?: string) => {
  const key = ({ "managed-mac": "fb.k.mac", "managed-linux": "fb.k.linux", own: "fb.k.own" } as Record<string, MsgKey>)[k || ""];
  return key ? t(key) : k || "";
};

const bytes = (n: number) => (n < 1024 ? `${n} B` : n < 1024 * 1024 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`);

const pending = (f: Feedback) => f.state !== "closed";
const thisWeek = (f: Feedback) => Date.now() - Date.parse(f.created_at) < 7 * 86_400_000;

const columns: ColumnDef<Feedback, any>[] = [
  {
    id: "at",
    accessorFn: (f) => Date.parse(f.created_at),
    header: () => t("col.at"),
    cell: ({ row: { original: f } }) => (
      <span className="text-muted-foreground" title={when(f.created_at)}>
        {ago(f.created_at)}
      </span>
    ),
  },
  {
    accessorKey: "who",
    header: () => t("col.actor"),
    cell: ({ row: { original: f } }) => (
      <div className="leading-tight">
        <span className="font-medium">{f.who || f.login}</span>
        <span className="block font-mono text-xs text-muted-foreground">{f.host || "—"}</span>
      </div>
    ),
  },
  {
    accessorKey: "text",
    header: () => t("col.text"),
    cell: ({ row: { original: f } }) => (
      <div className="flex max-w-xl items-center gap-2">
        <span className="truncate">{f.text}</span>
        {f.attachments > 0 && (
          <span className="flex shrink-0 items-center gap-0.5 text-xs text-muted-foreground" title={t("fb.nAttach", { n: f.attachments })}>
            <Paperclip className="size-3.5" />
            {f.attachments}
          </span>
        )}
      </div>
    ),
  },
  {
    id: "issue",
    accessorFn: (f) => f.gh_number || 0,
    header: () => t("col.issue"),
    cell: ({ row: { original: f } }) =>
      f.gh_url ? (
        <a href={f.gh_url} target="_blank" rel="noopener" className="font-mono text-xs text-clay hover:underline" onClick={(e) => e.stopPropagation()}>
          #{f.gh_number}
        </a>
      ) : (
        <span className="text-muted-foreground">—</span>
      ),
  },
  { accessorKey: "state", header: () => t("col.status"), cell: ({ getValue }) => <StateBadge s={getValue()} /> },
];

const filters: Filter<Feedback>[] = [
  { key: "pending", label: t("filter.pending"), test: pending },
  { key: "replied", label: t("filter.replied"), test: (f) => !pending(f) },
];

export function FeedbackPage() {
  const { id } = useParams();
  const nav = useNavigate();

  const fetchRows = React.useCallback(async (): Promise<Feedback[]> => {
    let out: Feedback[] = [];
    let before = "";
    for (let i = 0; i < MAX_PAGES; i++) {
      const a = await api<FeedbackPage>(`/v1/admin/feedback?limit=200${before ? `&before=${encodeURIComponent(before)}` : ""}`);
      out = out.concat(a.feedback || []);
      if (!a.next) break;
      before = a.next;
    }
    return out;
  }, []);

  return (
    <AdminTablePage<Feedback>
      title={t("page.feedback")}
      lead={t("fb.lead")}
      columns={columns}
      fetch={fetchRows}
      filters={filters}
      defaultFilter="pending"
      searchText={(f) => [f.id, f.who, f.login, f.host, f.text, f.gh_number ? `#${f.gh_number}` : "", f.reply].join(" ")}
      rowId={(f) => f.id}
      openId={id ? decodeURIComponent(id) : null}
      onOpen={(v) => nav(v ? `/feedback/${encodeURIComponent(v)}` : "/feedback")}
      emptyText={t("fb.empty")}
      kpis={(rows) => [
        { label: t("kpi.pending"), value: rows.filter(pending).length },
        { label: t("kpi.week"), value: rows.filter(thisWeek).length },
        { label: t("kpi.filed"), value: rows.filter((f) => f.state === "filed").length },
        { label: t("kpi.replied"), value: rows.filter((f) => !pending(f)).length },
      ]}
      drawer={(f, ctx) => <FeedbackDrawer key={f.id} f={f} {...ctx} />}
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

const mono = (v?: string) => (v ? <span className="font-mono text-xs">{v}</span> : "—");

function FeedbackDrawer({ f, close, reload }: { f: Feedback; close: () => void; reload: () => void }) {
  const [d, setD] = React.useState<FeedbackDetail | null>(null);
  const [err, setErr] = React.useState("");
  const [peek, setPeek] = React.useState<string | null>(null);

  React.useEffect(() => {
    api<FeedbackDetail>(`/v1/admin/feedback/${encodeURIComponent(f.id)}`).then(setD, (e: Error) => setErr(e.message));
  }, [f.id]);

  const x = d || f;
  const c = d?.ctx || {};
  const look = async (url: string) => {
    try {
      const r = await fetch(`${url}?inline=1`, { credentials: "same-origin" });
      const ty = r.headers.get("Content-Type") || "";
      setPeek(!r.ok ? String(r.status) : ty.startsWith("text/") ? (await r.text()).slice(0, 65536) : t("fb.binary"));
    } catch (e) {
      setPeek((e as Error).message);
    }
  };

  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="flex items-center gap-2 font-mono text-xl">
          {x.id} <StateBadge s={x.state} />
        </SheetTitle>
        <SheetDescription>{when(x.created_at)}</SheetDescription>
      </SheetHeader>
      <div className="grid gap-6 p-6 [&>*]:min-w-0">
        <p className="text-sm whitespace-pre-wrap">{x.text}</p>
        {err && (
          <Alert variant="destructive">
            <AlertDescription className="font-mono text-xs">{err}</AlertDescription>
          </Alert>
        )}
        <dl className="grid grid-cols-[6.5rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <Field k="fb.who">{x.who || "—"}</Field>
          <Field k="fb.login">{mono(x.login)}</Field>
          <Field k="fb.host">{mono(x.host)}</Field>
          <Field k="fb.kind">{[kindOf(x.machine_kind), x.agent].filter(Boolean).join(" · ") || "—"}</Field>
          <Field k="fb.session">{d ? [c.window, c.cc_session].filter(Boolean).join(" · ") ? mono([c.window, c.cc_session].filter(Boolean).join(" · ")) : "—" : <Skeleton className="h-4 w-32" />}</Field>
          <Field k="fb.worker">{d ? mono(c.worker_id) : <Skeleton className="h-4 w-40" />}</Field>
          <Field k="fb.version">{d ? mono(c.fleet_version) : <Skeleton className="h-4 w-20" />}</Field>
          <Field k="fb.issue">
            {x.gh_url ? (
              <a href={x.gh_url} target="_blank" rel="noopener" className="font-mono text-xs text-clay hover:underline">
                #{x.gh_number}
              </a>
            ) : (
              <span className="text-muted-foreground">{t("fb.notFiled")}</span>
            )}
          </Field>
          <Field k="fb.reply">
            {x.reply ? (
              <>
                {x.reply}{" "}
                <span className="text-xs text-muted-foreground">
                  ({x.replied_at && !x.replied_at.startsWith("0001-") ? t("fb.delivered", { at: ago(x.replied_at) }) : t("fb.notDelivered")})
                </span>
              </>
            ) : (
              "—"
            )}
          </Field>
        </dl>

        <section className="grid gap-2">
          <h3 className="font-display text-base font-semibold">{t("fb.attach")}</h3>
          {!d ? (
            <Skeleton className="h-9 w-full" />
          ) : d.attach?.length ? (
            <ul className="grid gap-1.5">
              {d.attach.map((a) => (
                <li key={a.name} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm">
                  <Paperclip className="size-4 text-muted-foreground" />
                  <span className="min-w-0 flex-1 truncate font-mono text-xs">{a.name}</span>
                  <span className="font-mono text-xs text-muted-foreground">{bytes(a.size)}</span>
                  <Button variant="ghost" size="sm" onClick={() => look(a.url)}>
                    <Eye />
                    {t("fb.peek")}
                  </Button>
                  <Button variant="ghost" size="icon" asChild>
                    <a href={a.url} download aria-label={a.name}>
                      <Download />
                    </a>
                  </Button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">{t("fb.noAttach")}</p>
          )}
          {peek != null && <pre className="max-h-[40vh] overflow-auto rounded-lg border bg-muted/40 p-3 font-mono text-xs whitespace-pre-wrap">{peek}</pre>}
        </section>
      </div>
      <SheetFooter className="mt-auto flex-row justify-end gap-2 border-t p-4">
        {x.gh_url && (
          <Button variant="outline" asChild>
            <a href={x.gh_url} target="_blank" rel="noopener">
              <ExternalLink />
              {t("fb.openGH")}
            </a>
          </Button>
        )}
        {x.state !== "closed" && (
          <DuplicateDialog
            id={x.id}
            onDone={() => {
              close();
              reload();
            }}
          />
        )}
      </SheetFooter>
    </>
  );
}

function DuplicateDialog({ id, onDone }: { id: string; onDone: () => void }) {
  const [of, setOf] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [open, setOpen] = React.useState(false);
  const field = React.useId();
  const submit = async () => {
    setBusy(true);
    try {
      const out = await api<{ note?: string; reply?: string }>(`/v1/admin/feedback/${encodeURIComponent(id)}/duplicate`, { json: { of: of.trim() } });
      toast.success(out.note || t("fb.dupDone", { reply: out.reply || "" }));
      setOpen(false);
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
        <Button>
          <Copy />
          {t("fb.dup")}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t("fb.dup")} · <span className="font-mono">{id}</span>
          </DialogTitle>
          <DialogDescription>{t("fb.dupBody")}</DialogDescription>
        </DialogHeader>
        <form
          className="grid gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (of.trim()) submit();
          }}
        >
          <Label htmlFor={field}>{t("fb.dupOf")}</Label>
          <Input id={field} value={of} onChange={(e) => setOf(e.target.value)} placeholder="F3" className="font-mono" autoFocus />
        </form>
        <DialogFooter>
          <DialogClose asChild>
            <Button variant="outline">{t("confirm.cancel")}</Button>
          </DialogClose>
          <Button disabled={!of.trim() || busy} onClick={submit}>
            {t("fb.dup")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
