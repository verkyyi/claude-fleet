// tasks.tsx — 任务 (EPIC #3923 C5, claude-fleet#3928): everything the person
// sent out (the hub's task records, T<n>, /v1/fleet/tasks) and their tickets
// (/v1/fleet/tickets) on one page, two tabs — 我派出的 · 单子 — the tab in the
// address (?tab=tickets, where the old 我的单子 bookmark lands). A task links
// to its session and its ticket; one with no ticket can be given one
// (POST /v1/fleet/tasks/<T>/issue, the old page's 「建 GitHub 单」).
// Stock shadcn/ui only.
import { useMemo, useState, type FC } from "react";
import { Link, useSearchParams } from "react-router";
import { ArrowUpRight, ListChecks, Plus, Ticket as TicketIcon } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { sendJSON, useLoad } from "@/shared/api";
import { usePage } from "../Shell";
import { PAGES } from "../routes";
import { Empty, Failed, Loading, PageHeader, ago } from "../parts";
import { parseRef, ticketPath, ticketState, type Ticket } from "../tickets";

// One task record as /v1/fleet/tasks answers it, with its session's live word.
type Live = { key?: string; state?: string; needs?: string; status_kind?: string };
type Task = {
  id: string; title: string; via: string; device: string; repo: string;
  session_key: string; state: string; issue: string; parked: string; asked: string;
  created_at: string; live?: Live | null;
};

// The words and colour of where a task stands: its session's own word while
// the fleet still lists it, else the record's.
function taskState(t: Task): { label: string; tone: string } {
  const ok = "text-ok";
  const ask = "text-clay border-clay-line bg-clay-soft";
  const quiet = "text-muted-foreground";
  if (t.parked) return { label: tr("停放", "Parked"), tone: quiet };
  const live = t.live;
  if (live?.state) {
    if (live.needs || live.state.startsWith("needs") || live.status_kind === "blocked") return { label: tr("在问你", "Asking you"), tone: ask };
    if (live.state === "working") return { label: tr("在做", "Working"), tone: ok };
    return { label: tr("做完了", "Done"), tone: quiet };
  }
  switch (t.state) {
    case "placing": return { label: tr("正在开", "Starting"), tone: quiet };
    case "refused": return { label: tr("没开成", "Didn't start"), tone: "text-destructive border-destructive/40" };
    case "unknown": return { label: tr("还不清楚", "Unknown"), tone: quiet };
  }
  return { label: tr("做完了", "Done"), tone: quiet };
}

// 会话: its page here once it has one (C4), the old page until then
const sessions = PAGES.find((x) => x.id === "sessions")!;

const TaskCard: FC<{ t: Task; ticket?: Ticket; onFile: (t: Task) => void }> = ({ t, ticket, onFile }) => {
  const st = taskState(t);
  const ref = parseRef(t.issue);
  const key = t.live?.key || t.session_key;
  const meta = [t.via, t.device, ago(t.created_at)].filter(Boolean).join(" · ");
  const linkCls = "text-clay hover:text-clay/80 no-underline";
  return (
    <Card className="gap-2 py-4">
      <CardContent className="space-y-2">
        <div className="flex items-start gap-2">
          <span className="text-muted-foreground mt-0.5 font-mono text-xs">{t.id}</span>
          <p className="min-w-0 flex-1 leading-snug font-medium break-words">{t.title}</p>
          <Badge variant="outline" className={cn("shrink-0 rounded-full", st.tone)}>{st.label}</Badge>
        </div>
        <div className="text-muted-foreground flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px]">
          {meta ? <span>{meta}</span> : null}
          {key ? (
            sessions.page
              ? <Link to={sessions.path} className={linkCls}>{tr("会话", "Session")} {key} ›</Link>
              : <a href={sessions.href} className={linkCls}>{tr("会话", "Session")} {key} ›</a>
          ) : null}
          {ref ? (
            ticket
              ? <Link to={ticketPath(ticket.repo, ticket.number)} className={linkCls}>{tr("单子", "Ticket")} #{ref.n} ›</Link>
              : <a href={`https://github.com/${ref.repo}/issues/${ref.n}`} target="_blank" rel="noopener noreferrer" className={linkCls}>
                  {tr("单子", "Ticket")} #{ref.n} <ArrowUpRight className="inline size-3.5 align-[-2px]" aria-hidden />
                </a>
          ) : t.repo ? null : (
            <Button size="sm" variant="outline" className="h-7" onClick={() => onFile(t)}>
              <Plus />{tr("建一张单子", "Open a ticket")}
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  );
};

const TicketCard: FC<{ t: Ticket; showRepo: boolean }> = ({ t, showRepo }) => {
  const st = ticketState(t);
  const n = t.comments ?? 0;
  return (
    <Link to={ticketPath(t.repo, t.number)} className="text-foreground block no-underline">
      <Card className="hover:border-clay-line gap-2 py-4 transition-colors">
        <CardContent className="space-y-1.5">
          <div className="flex items-center gap-2">
            <span className="text-muted-foreground font-mono text-xs">#{t.number}</span>
            <p className="min-w-0 flex-1 truncate font-medium">{t.title}</p>
            <Badge variant="outline" className={cn("rounded-full", st.tone)}>{st.label}</Badge>
          </div>
          <p className="text-muted-foreground truncate text-[13px]">
            {showRepo ? `${t.repo} · ` : ""}
            {tr(`${n} 条讨论`, `${n} comment${n === 1 ? "" : "s"}`)} · {tr(`更新于 ${ago(t.updated_at)}`, `updated ${ago(t.updated_at)}`)}
          </p>
        </CardContent>
      </Card>
    </Link>
  );
};

// 「建一张单子」: a task with no repo asks which one; the hub files it through
// the task's machine and hangs it on the record.
const FileDialog: FC<{ task: Task | null; repos: string[]; onClose: () => void; onDone: () => void }> = ({ task, repos, onClose, onDone }) => {
  const [repo, setRepo] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const valid = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo.trim());
  const submit = async () => {
    if (!task || !valid) return;
    setBusy(true); setErr("");
    const r = await sendJSON(`POST`, `/v1/fleet/tasks/${encodeURIComponent(task.id)}/issue`, { repo: repo.trim() });
    setBusy(false);
    if (r.ok) { setRepo(""); onDone(); return; }
    setErr(r.error || tr("没建成，稍后再试。", "Couldn't open it; try again later."));
  };
  return (
    <Dialog open={!!task} onOpenChange={(o) => { if (!o && !busy) { setErr(""); onClose(); } }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{tr("建一张单子", "Open a ticket")}</DialogTitle>
          <DialogDescription>
            {task ? tr(`为 ${task.id}「${task.title}」建一张单子，挂在这条任务上。建在哪个仓库？`,
              `A ticket for ${task.id} “${task.title}”, hung on this task. Which repo?`) : null}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={(e) => { e.preventDefault(); submit(); }} className="space-y-2">
          <Input value={repo} onChange={(e) => setRepo(e.target.value)} placeholder="team/app" list="task-repos"
            autoFocus autoCapitalize="off" autoCorrect="off" spellCheck={false} aria-invalid={!!err || undefined}
            aria-label={tr("仓库", "Repo")} />
          <datalist id="task-repos">{repos.map((r) => <option key={r} value={r} />)}</datalist>
          <p className={cn("text-[13px]", err ? "text-destructive" : "text-muted-foreground")}>
            {err || tr("写成 owner/name，例如 team/app。", "Written owner/name, e.g. team/app.")}
          </p>
          <DialogFooter className="pt-2">
            <Button type="button" variant="outline" disabled={busy} onClick={onClose}>{tr("先不", "Not now")}</Button>
            <Button type="submit" disabled={!valid || busy}>{busy ? tr("正在建…", "Opening…") : tr("建单", "Open it")}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
};

export default function TasksPage() {
  usePage(tr("任务", "Tasks"));
  const [qs, setQs] = useSearchParams();
  const tab = qs.get("tab") === "tickets" ? "tickets" : "mine";
  const tasks = useLoad<{ tasks: Task[] }>("/v1/fleet/tasks");
  // my own, an admin's too (an admin's list is everyone's without ?mine)
  const tickets = useLoad<{ tickets: Ticket[] }>("/v1/fleet/tickets?mine=1");
  const [filing, setFiling] = useState<Task | null>(null);
  const [filed, setFiled] = useState("");

  const ticketList = tickets.data?.tickets || [];
  const byRef = useMemo(() => {
    const m = new Map<string, Ticket>();
    for (const t of ticketList) m.set(`${t.repo.toLowerCase()}#${t.number}`, t);
    return m;
  }, [ticketList]);
  const repos = useMemo(() => [...new Set(ticketList.map((t) => t.repo))].sort(), [ticketList]);
  const ticketOf = (t: Task) => { const r = parseRef(t.issue); return r ? byRef.get(`${r.repo.toLowerCase()}#${r.n}`) : undefined; };
  const taskList = tasks.data?.tasks || [];

  return (
    <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("任务", "Tasks")} sub={tr("你派出的每件事，和挂在上面的单子", "Everything you've sent out, and the tickets on it")} />
      <Tabs value={tab} onValueChange={(v) => setQs(v === "tickets" ? { tab: "tickets" } : {}, { replace: true })}>
        <TabsList className="mb-4">
          <TabsTrigger value="mine">{tr("我派出的", "Sent by me")}</TabsTrigger>
          <TabsTrigger value="tickets">{tr("单子", "Tickets")}</TabsTrigger>
        </TabsList>
        <TabsContent value="mine">
          {filed ? <p role="status" className="text-ok mb-3 text-sm">{filed}</p> : null}
          {tasks.loading ? <Loading /> : tasks.failed ? <Failed what={tr("任务", "tasks")} onRetry={tasks.reload} /> : taskList.length ? (
            <div className="space-y-3">
              {taskList.map((t) => <TaskCard key={t.id} t={t} ticket={ticketOf(t)} onFile={(x) => { setFiled(""); setFiling(x); }} />)}
            </div>
          ) : (
            <Empty icon={<ListChecks />} title={tr("还没派过任务", "No tasks yet")}
              body={tr("派出去的每件事都会在这里留一条记录，编号以 T 开头。", "Everything you send out leaves a record here, numbered from T.")}
              action={<Button asChild><Link to="/" className="no-underline">{tr("去派一件", "Send one")}</Link></Button>} />
          )}
        </TabsContent>
        <TabsContent value="tickets">
          {tickets.loading ? <Loading n={2} /> : tickets.failed ? <Failed what={tr("单子", "tickets")} onRetry={tickets.reload} /> : ticketList.length ? (
            <div className="space-y-3">
              {ticketList.map((t) => <TicketCard key={t.id} t={t} showRepo={repos.length > 1} />)}
            </div>
          ) : (
            <Empty icon={<TicketIcon />} title={tr("没有单子", "No tickets")}
              body={tr("需要留个记录、或要别人一起看的事，可以建一张单子。", "For something worth a record, or that others should see too, open a ticket.")} />
          )}
        </TabsContent>
      </Tabs>
      <FileDialog task={filing} repos={repos} onClose={() => setFiling(null)}
        onDone={() => { setFiled(tr(`已为 ${filing?.id} 建了一张单子`, `Opened a ticket for ${filing?.id}`)); setFiling(null); tasks.reload(); tickets.reload(); }} />
    </div>
  );
}
