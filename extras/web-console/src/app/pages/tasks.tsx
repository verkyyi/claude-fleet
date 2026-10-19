// tasks.tsx — 任务 (EPIC #3923 C5, claude-fleet#3928): everything the person
// sent out — the hub's task records, T<n>, /v1/fleet/tasks. A task links to its
// session and, when it has one, its GitHub issue; the record is its ticket (the
// hub's own tickets and 「建 GitHub 单」 left with claude-fleet#4898, T477).
// Stock shadcn/ui only.
import type { FC } from "react";
import { Link } from "react-router";
import { ArrowUpRight, ListChecks } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { usePage } from "../Shell";
import { Empty, Failed, Loading, PageHeader, ago } from "../parts";
import { terminalLink } from "@/shared/terminal";
import { agentMismatch, taskBlockerItems, taskLanding, taskPR, taskStatus, taskTicket, type Task } from "../task-state";
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

const TaskCard: FC<{ t: Task; stale?: boolean }> = ({ t, stale }) => {
  const state = taskStatus(t);
  const ref = taskTicket(t);
  const pr = taskPR(t);
  const landing = taskLanding(t);
  const mismatch = agentMismatch(t);
  const blockers = taskBlockerItems(t);
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
            /^[\w.-]+\/[\w.-]+$/.test(ref.repo) ? <a href={`https://github.com/${ref.repo}/issues/${ref.n}`} target="_blank" rel="noopener noreferrer" className={cn(linkCls, "break-all")}>
              {ref.repo}#{ref.n} <ArrowUpRight className="inline size-3.5 align-[-2px]" aria-hidden />
            </a> : <span className="break-all">{ref.repo}#{ref.n}</span>
          ) : null}
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
            <dt>{tr("会话观测", "Session observation")}</dt><dd>
              {t.live?.stale || stale ? tr("陈旧 / last-known · ", "Stale / last-known · ") : ""}{observedWords(t)}
              {" · "}{t.live?.source || "unknown"}{" · "}{t.live?.observed_at || "unknown"}
            </dd>
            <dt>{tr("运行证据", "Runtime evidence")}</dt><dd>{tr("未知 · inventory 未提供原生同源快照", "Unknown · inventory has no shared native snapshot")}</dd>
            <dt>{tr("接受/投递", "Acceptance/delivery")}</dt><dd>{tr("未知 · 缺少 controller 回执", "Unknown · controller receipt unavailable")}</dd>
            <dt>{tr("循环计划", "Loop schedule")}</dt><dd>{tr("未知 · 未提供计划证据，运行不表示已接受", "Unknown · schedule evidence unavailable; running does not mean accepted")}</dd>
            <dt>{tr("回收保留", "Reap retention")}</dt><dd>{tr("未知 · 未提供同源 proof；不授权关闭", "Unknown · shared proof unavailable; no permission to close")}</dd>
            <dt>{tr("部署 / 现场", "Deployment / live")}</dt><dd>{tr("未知 · PR 合并不等于上线", "Unknown · PR merged does not mean deployed")}</dd>
            <dt>{tr("来源", "Source")}</dt><dd>{tr("任务：hub 权威 GET；会话：inventory（与 native runtime 独立）", "Task: authoritative hub GET; session: inventory (separate from native runtime)")}</dd>
            <dt>{tr("任务更新于", "Task updated")}</dt><dd>{t.updated_at || statusWords("unknown")}</dd>
            <dt>{tr("任务阻塞", "Task blockers")}</dt><dd>
              {stale ? <p>{tr("陈旧 · 以下仅为 last-known，不代表阻塞已解除", "Stale · last-known only; no blocker resolution inferred")}</p> : null}
              {blockers === null ? tr("未知 · 缺少本代 task-blockers.v1", "Unknown · current task-blockers.v1 unavailable")
                : blockers.length === 0 ? tr("本代没有显式阻塞；会话提问和批准独立保留", "No explicit blockers in this generation; questions and approvals remain independent")
                : blockers.map((b) => <p key={b.blocker_id} className="break-words">
                  {b.blocker_id}{" · "}{b.state}{b.reason ? ` · ${b.reason}` : ""}{" · "}
                  {b.resolved_at || b.revoked_at || b.created_at || statusWords("unknown")}
                </p>)}
            </dd>
            {t.asked ? <><dt>{tr("提问 / 批准", "Question / approval")}</dt><dd>{t.asked}</dd></> : null}
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

export default function TasksPage() {
  usePage(tr("任务", "Tasks"));
  const tasks = useTasks();
  const stale = tasks.failed || tasks.data?.stale;
  const taskList = tasks.data?.tasks || [];

  return (
    <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("任务", "Tasks")} sub={tr("你派出的每件事", "Everything you've sent out")} />
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
          {taskList.map((t) => <TaskCard key={t.id} t={t} stale={stale} />)}
        </div>
      ) : (
        <Empty icon={<ListChecks />} title={stale ? tr("任务数量未知", "Task count unknown") : tr("还没派过任务", "No tasks yet")}
          body={stale ? tr("当前来源不可用，请重试读取。空的陈旧快照不代表没有任务。", "The source is unavailable. Retry the read; an empty stale snapshot does not mean zero tasks.")
            : tr("派出去的每件事都会在这里留一条记录，编号以 T 开头。", "Everything you send out leaves a record here, numbered from T.")}
          action={<Button asChild><Link to="/" className="no-underline">{tr("去派一件", "Send one")}</Link></Button>} />
      )}
    </div>
  );
}
