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
import { Empty, Failed, Loading, PageHeader, ago } from "../parts";
import { ticketPath, ticketState, type Ticket } from "../tickets";
import { terminalLink } from "@/shared/terminal";
import { agentMismatch, taskLanding, taskPR, taskStatus, taskTicket, type Task } from "../task-state";
import { useTasks } from "../use-tasks";

const STATUS: Record<string, [string, string]> = {
  accepted: ["已接收", "Accepted"], starting: ["正在开", "Starting"],
  running: ["在做", "Working"], waiting: ["等待中", "Waiting"],
  succeeded: ["已完成", "Completed"], failed: ["失败", "Failed"],
  cancelled: ["已取消", "Cancelled"], refused: ["没开成", "Didn't start"],
  unknown: ["还不清楚", "Unknown"],
};
const statusWords = (state: string) => tr(...(STATUS[state] || STATUS.unknown));
const observedWords = (t: Task) => {
  if (!t.live?.state) return tr("无当前会话观测", "No current session observation");
  if (t.live.needs || t.live.state.startsWith("needs")) return tr("在问你", "Asking you");
  const words: Record<string, [string, string]> = {
    working: ["在做", "Working"], idle: ["空闲", "Idle"], done: ["本轮结束", "Turn ended"],
    exited: ["会话退出", "Session exited"], blocked: ["被卡住", "Blocked"],
  };
  return tr(...(words[t.live.state] || STATUS.unknown));
};

const TaskCard: FC<{ t: Task; ticket?: Ticket; onFile: (t: Task) => void }> = ({ t, ticket, onFile }) => {
  const state = taskStatus(t);
  const ref = taskTicket(t);
  const pr = taskPR(t);
  const landing = taskLanding(t);
  const mismatch = agentMismatch(t);
  const tone = state === "failed" || state === "refused" ? "text-destructive border-destructive/40"
    : state === "running" || state === "succeeded" ? "text-ok" : "text-muted-foreground";
  const key = t.live?.key || t.session_key;
  const meta = [t.via, t.device, ago(t.created_at)].filter(Boolean).join(" · ");
  const linkCls = "text-clay hover:text-clay/80 no-underline";
  return (
    <Card className="gap-2 py-4" data-task-id={t.id}>
      <CardContent className="space-y-2">
        <div className="flex items-start gap-2">
          <span className="text-muted-foreground mt-0.5 font-mono text-xs">{t.id}</span>
          <p className="min-w-0 flex-1 leading-snug font-medium break-words">{t.title}</p>
          <Badge variant="outline" className={cn("shrink-0 rounded-full", tone)}>{statusWords(state)}</Badge>
        </div>
        <div className="text-muted-foreground flex flex-wrap items-center gap-x-3 gap-y-1 text-[13px]">
          {meta ? <span>{meta}</span> : null}
          {t.worker_id ? (
            <Link to={terminalLink(t.worker_id)} className={cn(linkCls, "break-all")}>
              {tr("会话", "Session")} {key || t.worker_id} ›
            </Link>
          ) : null}
          {ref ? (
            ticket && ticket.backend === ref.backend
              ? <Link to={ticketPath(ticket.repo, ticket.number)} className={cn(linkCls, "break-all")}>{ref.backend}:{ref.repo}#{ref.n} ›</Link>
              : ref.backend === "gh" && /^[\w.-]+\/[\w.-]+$/.test(ref.repo) ? <a href={`https://github.com/${ref.repo}/issues/${ref.n}`} target="_blank" rel="noopener noreferrer" className={cn(linkCls, "break-all")}>
                  {ref.backend}:{ref.repo}#{ref.n} <ArrowUpRight className="inline size-3.5 align-[-2px]" aria-hidden />
                </a> : <span className="break-all">{ref.backend}:{ref.repo}#{ref.n}</span>
          ) : t.repo || t.authority_version ? null : (
            <Button size="sm" variant="outline" className="h-7" onClick={() => onFile(t)}>
              <Plus />{tr("建一张单子", "Open a ticket")}
            </Button>
          )}
        </div>
        {mismatch ? <p className="text-destructive text-sm">{tr("代理不一致：实际运行与选择不符。", "Agent mismatch: the verified agent differs from the selection.")}</p> : null}
        {landing === "waiting" ? <p className="text-clay text-sm">{tr("等待 GitHub · PR 尚未确认合并", "Waiting for GitHub · PR merge is not confirmed")}</p> : null}
        {landing === "merged" ? <p className="text-ok text-sm">{tr("PR 已合并", "PR merged")}</p> : null}
        {pr && landing === "unverified" ? <p className="text-muted-foreground text-sm">{tr("PR 合并状态未知", "PR merge status unknown")}</p> : null}
        {pr ? <a href={pr.url} target="_blank" rel="noopener noreferrer" className={cn(linkCls, "block break-all text-sm")}>
          PR {pr.repo}#{pr.n} <ArrowUpRight className="inline size-3.5" aria-hidden />
        </a> : null}
        <details className="text-muted-foreground text-[13px]">
          <summary className="cursor-pointer rounded-sm focus-visible:outline-2 focus-visible:outline-ring">{tr("任务详情", "Task details")}</summary>
          <dl className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 [&>dd]:break-words">
            <dt>{tr("请求代理", "Requested agent")}</dt><dd>{t.requested_agent || statusWords("unknown")}</dd>
            <dt>{tr("确定代理", "Resolved agent")}</dt><dd>{t.resolved_agent || statusWords("unknown")}</dd>
            <dt>{tr("已核实代理", "Verified actual agent")}</dt><dd>{t.actual_agent || statusWords("unknown")}</dd>
            <dt>{tr("会话观测", "Session observation")}</dt><dd>{observedWords(t)}</dd>
            <dt>{tr("任务更新于", "Task updated")}</dt><dd>{t.updated_at || statusWords("unknown")}</dd>
            {t.generation ? <><dt>{tr("执行代次", "Attempt")}</dt><dd>{t.generation}</dd></> : null}
            {t.worker_id ? <><dt>{tr("会话身份", "Session identity")}</dt><dd className="break-all!">{t.worker_id}</dd></> : null}
            {t.cancel_request && state !== "cancelled" ? <><dt>{tr("取消", "Cancellation")}</dt><dd>{tr("已请求，尚未确认停止", "Requested; stopping is not confirmed")}</dd></> : null}
            {t.parked ? <><dt>{tr("停放", "Parked")}</dt><dd>{t.parked}</dd></> : null}
          </dl>
        </details>
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
  const tasks = useTasks();
  const stale = tasks.failed || tasks.data?.stale;
  // my own, an admin's too (an admin's list is everyone's without ?mine)
  const tickets = useLoad<{ tickets: Ticket[] }>("/v1/fleet/tickets?mine=1");
  const [filing, setFiling] = useState<Task | null>(null);
  const [filed, setFiled] = useState("");

  const ticketList = tickets.data?.tickets || [];
  const byRef = useMemo(() => {
    const m = new Map<string, Ticket>();
    for (const t of ticketList) m.set(`${t.backend}:${t.repo.toLowerCase()}#${t.number}`, t);
    return m;
  }, [ticketList]);
  const repos = useMemo(() => [...new Set(ticketList.map((t) => t.repo))].sort(), [ticketList]);
  const ticketOf = (t: Task) => { const r = taskTicket(t); return r ? byRef.get(`${r.backend}:${r.repo.toLowerCase()}#${r.n}`) : undefined; };
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
          {tasks.data ? <div className="mb-3 flex flex-wrap items-center justify-between gap-2 text-sm">
            <p role={stale ? "status" : undefined} className={stale ? "text-clay" : "text-muted-foreground"}>
              {stale ? tr("暂时无法更新 · 保留上次确认的状态", "Stale information · showing the last confirmed state") : tr("读取于", "Read at")}
              {" · "}<time dateTime={tasks.data.observed_at}>{tasks.data.observed_at || statusWords("unknown")}</time>
            </p>
            <Button size="sm" variant="outline" disabled={tasks.loading} onClick={tasks.reload}>
              {tasks.loading ? tr("正在读取…", "Reading…") : stale ? tr("重试读取", "Retry read") : tr("刷新", "Refresh")}
            </Button>
          </div> : null}
          {!tasks.data && tasks.loading ? <Loading /> : !tasks.data && tasks.failed ? <Failed what={tr("任务", "tasks")} onRetry={tasks.reload} /> : taskList.length ? (
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
