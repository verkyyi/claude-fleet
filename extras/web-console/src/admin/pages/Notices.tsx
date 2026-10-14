// Notices — 发通知, /admin/notices (claude-fleet#4063, EPIC #4048 R1). An admin
// tells every member, or a few, one plain sentence about their account
// (「周六 2 点维护 30 分钟」): the hub sends each copy down the notice desk's
// roads — WeChat to one who bound it, else a mail, else only the record. The
// table is what went out and how it went; 发通知 opens the Dialog that writes
// one. At most `limit` in 24 hours; the hub refuses past it (429) and audits
// every one. Reads and writes /v1/admin/notices only.
import * as React from "react";
import type { ColumnDef } from "@tanstack/react-table";
import { Megaphone } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { AdminTablePage } from "../AdminTablePage";
import { api, type NoticeMember, type NoticesList, type ServiceNotice } from "../api";
import { t, when, type MsgKey } from "../i18n";

const BASE = "/v1/admin/notices";
// the hub's own bounds (admin_notices.go): the words, and a link's
const BODY_MAX = 300;
const URL_IN_WORDS = /(https?:\/\/|www\.)/i;

function Went({ n }: { n: ServiceNotice }) {
  const d = n.delivery;
  const wx = (d.via["wechat-tpl"] || 0) + (d.via["wechat-kf"] || 0);
  const mail = d.via.email || 0;
  return (
    <div className="grid gap-1">
      <span className="text-sm tabular-nums">{t("nt.went", { sent: d.sent, pending: d.pending, undelivered: d.undelivered })}</span>
      <span className="flex flex-wrap gap-1">
        {wx > 0 && (
          <Badge variant="secondary" className="font-normal">
            {t("nt.via.wechat", { n: wx })}
          </Badge>
        )}
        {mail > 0 && (
          <Badge variant="secondary" className="font-normal">
            {t("nt.via.email", { n: mail })}
          </Badge>
        )}
      </span>
    </div>
  );
}

const columns: ColumnDef<ServiceNotice, any>[] = [
  {
    accessorKey: "body",
    header: () => t("nt.col.body"),
    enableSorting: false,
    cell: ({ row: { original: n } }) => (
      <div className="max-w-md">
        <p className="text-sm whitespace-pre-wrap">{n.body}</p>
        {n.link && (
          <a href={n.link} target="_blank" rel="noreferrer" className="text-xs break-all text-primary underline-offset-4 hover:underline">
            {n.link}
          </a>
        )}
      </div>
    ),
  },
  {
    id: "to",
    accessorFn: (n) => n.recipients.length,
    header: () => t("nt.col.to"),
    cell: ({ row: { original: n } }) => (
      <Badge variant="outline" className="font-normal">
        {n.audience === "all" ? t("nt.to.all", { n: n.recipients.length }) : t("nt.to.some", { n: n.recipients.length })}
      </Badge>
    ),
  },
  { id: "went", accessorFn: (n) => n.delivery.sent, header: () => t("nt.col.went"), cell: ({ row }) => <Went n={row.original} /> },
  {
    id: "at",
    accessorFn: (n) => Date.parse(n.created_at),
    header: () => t("nt.col.at"),
    cell: ({ row }) => <span className="text-muted-foreground tabular-nums">{when(row.original.created_at)}</span>,
  },
];

export function NoticesPage() {
  const [meta, setMeta] = React.useState<NoticesList | null>(null);
  const fetchRows = React.useCallback(async () => {
    const v = await api<NoticesList>(BASE);
    setMeta(v);
    return v.notices || [];
  }, []);
  const members = meta?.members || [];
  const limit = meta?.limit ?? 3;

  return (
    <AdminTablePage<ServiceNotice>
      title={t("page.notices")}
      lead={t("nt.lead", { n: limit })}
      columns={columns}
      fetch={fetchRows}
      searchText={(n) => [n.body, n.link || ""].join(" ")}
      rowId={(n) => n.id}
      emptyText={t("nt.empty")}
      kpis={() => [
        { label: t("nt.kpi.today"), value: `${meta?.today ?? 0} / ${limit}` },
        { label: t("nt.kpi.members"), value: members.length },
        { label: t("nt.kpi.reach"), value: members.filter((m) => m.reach === "wechat").length },
      ]}
      actions={(reload) => <NewNoticeDialog members={members} left={Math.max(0, limit - (meta?.today ?? 0))} limit={limit} onSent={reload} />}
    />
  );
}

function NewNoticeDialog({ members, left, limit, onSent }: { members: NoticeMember[]; left: number; limit: number; onSent: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [body, setBody] = React.useState("");
  const [link, setLink] = React.useState("");
  const [audience, setAudience] = React.useState<"all" | "some">("all");
  const [picked, setPicked] = React.useState<Set<string>>(new Set());
  const [err, setErr] = React.useState("");
  const [busy, setBusy] = React.useState(false);

  const reset = () => {
    setBody("");
    setLink("");
    setAudience("all");
    setPicked(new Set());
    setErr("");
  };

  const to = audience === "all" ? members : members.filter((m) => picked.has(m.principal_id));
  const count = (r: NoticeMember["reach"]) => to.filter((m) => m.reach === r).length;
  const words = body.trim();
  const bodyErr = URL_IN_WORDS.test(words) ? t("nt.d.bodyLink") : "";
  const linkErr = link.trim() && !/^https:\/\/\S+$/i.test(link.trim()) ? t("nt.d.linkBad") : "";
  const ready = words && [...words].length <= BODY_MAX && !bodyErr && !linkErr && to.length > 0 && left > 0;

  const send = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!ready) return;
    setBusy(true);
    try {
      await api(BASE, { json: { body: words, link: link.trim(), to: audience === "all" ? "all" : to.map((m) => m.principal_id) } });
      toast.success(t("nt.sent", { n: to.length }));
      setOpen(false);
      reset();
      onSent();
    } catch (e) {
      setErr(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) reset();
      }}
    >
      <DialogTrigger asChild>
        <Button>
          <Megaphone />
          {t("nt.new")}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{t("nt.d.title")}</DialogTitle>
          <DialogDescription>{t("nt.d.sub")}</DialogDescription>
        </DialogHeader>
        <form className="grid gap-4" onSubmit={send}>
          <div className="grid gap-2">
            <div className="flex items-baseline justify-between">
              <Label htmlFor="nt-body">{t("nt.d.body")}</Label>
              <span className={cn("text-xs text-muted-foreground tabular-nums", [...words].length > BODY_MAX && "text-destructive")}>
                {t("nt.d.count", { n: [...words].length, max: BODY_MAX })}
              </span>
            </div>
            <Textarea id="nt-body" value={body} onChange={(e) => setBody(e.target.value)} placeholder={t("nt.d.bodyPh")} rows={3} aria-invalid={!!bodyErr} />
            {bodyErr && <p className="text-sm text-destructive">{bodyErr}</p>}
          </div>
          <div className="grid gap-2">
            <Label htmlFor="nt-link">{t("nt.d.link")}</Label>
            <Input
              id="nt-link"
              value={link}
              onChange={(e) => setLink(e.target.value)}
              placeholder={t("nt.d.linkPh")}
              inputMode="url"
              autoComplete="off"
              spellCheck={false}
              aria-invalid={!!linkErr}
            />
            {linkErr && <p className="text-sm text-destructive">{linkErr}</p>}
          </div>
          <div className="grid gap-2">
            <Label>{t("nt.d.to")}</Label>
            <RadioGroup value={audience} onValueChange={(v) => setAudience(v as "all" | "some")} className="flex gap-6">
              <div className="flex items-center gap-2">
                <RadioGroupItem value="all" id="nt-all" />
                <Label htmlFor="nt-all" className="font-normal">
                  {t("nt.d.toAll")}
                </Label>
              </div>
              <div className="flex items-center gap-2">
                <RadioGroupItem value="some" id="nt-some" />
                <Label htmlFor="nt-some" className="font-normal">
                  {t("nt.d.toSome")}
                </Label>
              </div>
            </RadioGroup>
            {audience === "some" && (
              <div className="grid max-h-48 gap-2 overflow-y-auto rounded-lg border p-3">
                {members.map((m) => (
                  <div key={m.principal_id} className="flex items-center gap-2">
                    <Checkbox
                      id={`nt-m-${m.principal_id}`}
                      checked={picked.has(m.principal_id)}
                      onCheckedChange={(c) => {
                        const next = new Set(picked);
                        if (c) next.add(m.principal_id);
                        else next.delete(m.principal_id);
                        setPicked(next);
                      }}
                    />
                    <Label htmlFor={`nt-m-${m.principal_id}`} className="min-w-0 flex-1 truncate font-normal">
                      {m.login}
                    </Label>
                    <span className={cn("text-xs text-muted-foreground", m.reach === "none" && "text-warn")}>{t(`nt.d.reach.${m.reach}` as MsgKey)}</span>
                  </div>
                ))}
              </div>
            )}
            <p className="text-xs text-muted-foreground">
              {t("nt.d.summary", { n: to.length, w: count("wechat"), e: count("email"), x: count("none") })}
            </p>
          </div>
          <p className={cn("text-xs", left > 0 ? "text-muted-foreground" : "text-destructive")}>
            {left > 0 ? t("nt.d.left", { n: left }) : t("nt.d.spent", { n: limit })}
          </p>
          {err && <p className="text-sm text-destructive">{err}</p>}
          <DialogFooter>
            <DialogClose asChild>
              <Button type="button" variant="outline">
                {t("nt.d.cancel")}
              </Button>
            </DialogClose>
            <Button type="submit" disabled={busy || !ready}>
              {t("nt.d.send")}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
