// sessions.tsx — 会话 (EPIC #3923 C4, issue #3927; T769): everything the person
// sent out and every session they have, ONE list — a task and its session one
// row (src/app/work.ts joins them), grouped as ⌘P's panel groups them: ✦ 消息 ·
// 等你 · 在干活 · 排队中 · 已收起 (folded), an EPIC's members under it. A row
// opens its details beside the list (from 1024 px) or in a sheet (below): what
// it asks, the person's own words, its report, its PR, its members, its
// session, the ways in, and every field the old 任务 page showed, folded.
// 新建 opens a task through the write door (worker_start with a coding agent:
// the hub writes the record first). /tasks (and its ?q=) lands here, the row
// opened. Stock shadcn/ui only.
import { useEffect, useMemo, useState, type FC, type ReactNode } from "react";
import { Link, useSearchParams } from "react-router";
import {
  ArrowUpRight, ChevronDown, ChevronRight,
  Layers, Loader, MessageCircle, Plus, RotateCcw, Search, Sparkles, TerminalSquare, Trash2,
} from "lucide-react";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { fmtTokens, tr } from "@/shared/i18n";
import { sessionWrite } from "@/shared/sessions";
import { terminalLink } from "@/shared/terminal";
import { viewAs } from "@/shared/viewAs";
import { usePage } from "../Shell";
import { shellPath } from "../legacy";
import { Empty, Failed, Loading, PageHeader, ago } from "../parts";
import { agentMismatch, taskBlockerItems, taskLanding, taskPR, taskStatus, taskTicket, writtenCode, type Task } from "../task-state";
import { findTask } from "../use-tasks";
import { NewDialog, reposOf } from "../NewDialog";
import { GLYPH, TONE } from "../SessionList";
import { useWorkRows } from "../work-rows";
import { CopyLine, useInstallLine } from "../cli";
import { openLine } from "../session-list";
import { GROUPS, findRow, messagesOf, nestedKids, rowOf, rowsIn, taskWords, type Row, type Tone } from "../work";

const BADGE: Record<Tone, string> = {
  ask: "text-clay border-clay-line bg-clay-soft", fail: "text-destructive border-destructive/40", ok: "text-ok", muted: "text-muted-foreground",
};
const ASK_KIND: Record<string, [string, string]> = {
  permission: ["它在请你批准", "It asks your permission"],
  question: ["它在问你", "It asks you"],
  auth: ["它要你登录", "It needs you to sign in"],
};
const STATUS: Record<string, [string, string]> = {
  accepted: ["已接收", "Accepted"], starting: ["正在开", "Starting"], running: ["在做", "Working"], waiting: ["等待中", "Waiting"],
  succeeded: ["已完成", "Completed"], failed: ["失败", "Failed"], cancelled: ["已取消", "Cancelled"], refused: ["没开成", "Didn't start"],
  unknown: ["还不清楚", "Unknown"],
};
const statusWords = (state: string) => tr(...(STATUS[state] || STATUS.unknown));
const unknown = () => statusWords("unknown");

const when = (r: Row) => (r.live?.born ? ago(new Date(r.live.born * 1000).toISOString()) : r.ended?.ended ? ago(r.ended.ended) : ago(r.task?.created_at));
const machineOf = (r: Row) => r.live?.machine || r.ended?.machine || r.task?.machine || "";
function metaOf(r: Row, standalone: boolean) {
  const pr = r.task ? taskPR(r.task) : null;
  return [r.kids.length ? tr(`${r.kids.length} 项`, `${r.kids.length} items`) : "",
    standalone && r.parentTitle ? tr(`属于「${r.parentTitle}」`, `in “${r.parentTitle}”`) : "",
    r.board?.agent_words ? tr(...r.board.agent_words) : "",
    r.board?.context ? tr(...r.board.context) : "", machineOf(r), pr ? `PR #${pr.n}` : "", when(r)].filter(Boolean).join(" · ");
}

// `kids`: the members drawn under it (its own group's, the search's) — none ⇒ no
// ▸, the glyph instead, and a tap opens the EPIC itself (C25B)
const RowLine: FC<{ r: Row; kids?: Row[]; on: boolean; open: boolean; onOpen: () => void; onFold?: () => void; child?: boolean }> = ({ r, kids = [], on, open, onOpen, onFold, child }) => {
  const Icon = GLYPH[r.glyph];
  return (
    <div role="button" tabIndex={0} onClick={onOpen} onKeyDown={(e) => { if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); onOpen(); } }}
      data-row={r.code || r.id} data-group={r.group} {...(r.task ? { "data-task-id": r.task.fid || r.task.id } : {})} aria-current={on || undefined}
      className={cn("hover:bg-muted/60 aria-[current]:bg-muted flex cursor-pointer gap-2.5 px-3 py-3 text-left transition-colors", child && "ps-9")}>
      <span className="flex w-4 shrink-0 justify-center pt-0.5">
        {kids.length ? (
          <button type="button" aria-label={tr("展开 / 收起成员", "Show / hide members")} aria-expanded={open}
            onClick={(e) => { e.stopPropagation(); onFold?.(); }} className="text-muted-foreground hover:text-foreground">
            {open ? <ChevronDown className="size-4" /> : <ChevronRight className="size-4" />}
          </button>
        ) : <Icon className={cn("size-4", TONE[r.tone])} aria-hidden />}
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-baseline gap-2">
          {r.code ? <span className="text-clay shrink-0 font-mono text-xs" title={r.task ? writtenCode(r.task) : undefined}>{r.code}</span> : null}
          <span className="min-w-0 flex-1 truncate font-medium">{r.title}</span>
          <Badge variant="outline" className={cn("shrink-0 rounded-full", BADGE[r.tone])}>
            {kids.length ? <Icon className="size-3" aria-hidden /> : null}{tr(...r.tag)}
          </Badge>
        </span>
        {r.line ? <span className={cn("mt-0.5 block text-sm break-words", r.quote ? "text-foreground line-clamp-2" : "text-muted-foreground truncate")}>
          {r.quote ? tr(`「${r.line}」`, `“${r.line}”`) : r.line}</span> : null}
        {r.task && agentMismatch(r.task) ? <span className="text-destructive mt-0.5 block text-[12.5px]">{tr("代理不一致", "Agent mismatch")}</span> : null}
        <span className="text-muted-foreground mt-0.5 block truncate text-[12.5px]">{metaOf(r, !child)}</span>
      </span>
    </div>
  );
};

// ✦ 消息 (⌘P's first row): asks, failures, and what finished today — one line
// each, a tap opens its row.
const Messages: FC<{ rows: Row[]; onOpen: (r: Row) => void }> = ({ rows, onOpen }) => {
  const [open, setOpen] = useState(false);
  const msgs = messagesOf(rows);
  if (!msgs.length) return null;
  const n = (k: string) => msgs.filter((m) => m.kind === k).length;
  const glyph = { ask: ["!", "text-clay"], fail: ["✖", "text-destructive"], done: ["✓", "text-ok"] } as const;
  return (
    <Card className="gap-0 py-0">
      <button type="button" onClick={() => setOpen(!open)} aria-expanded={open}
        className="hover:bg-muted/60 flex w-full items-center gap-2.5 rounded-xl px-3 py-3 text-left">
        <Sparkles className="text-clay size-4" aria-hidden />
        <span className="font-medium">{tr("消息", "Messages")}</span>
        <span className="bg-clay text-primary-foreground rounded-full px-1.5 font-mono text-xs leading-5">{msgs.length}</span>
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-sm">
          {[n("ask") ? tr(`${n("ask")} 个在等你`, `${n("ask")} waiting on you`) : "", n("fail") ? tr(`${n("fail")} 个没做成`, `${n("fail")} failed`) : "",
            n("done") ? tr(`${n("done")} 个做完了`, `${n("done")} done`) : ""].filter(Boolean).join(" · ")}
        </span>
        {open ? <ChevronDown className="text-muted-foreground size-4" /> : <ChevronRight className="text-muted-foreground size-4" />}
      </button>
      {open ? <div className="border-t">
        {msgs.map((m) => (
          <button key={m.row.id + m.kind} type="button" onClick={() => onOpen(m.row)} className="hover:bg-muted/60 flex w-full gap-2.5 px-3 py-2 text-left text-sm">
            <span className={cn("w-4 text-center font-mono", glyph[m.kind][1])}>{glyph[m.kind][0]}</span>
            {m.row.code ? <span className="text-clay font-mono text-xs leading-5">{m.row.code}</span> : null}
            <span className="min-w-0 flex-1 truncate">{m.row.line || m.row.title}</span>
          </button>
        ))}
      </div> : null}
    </Card>
  );
};

const Field: FC<{ label: string; children: ReactNode }> = ({ label, children }) => (
  <section className="space-y-1">
    <h3 className="text-muted-foreground text-xs font-medium">{label}</h3>
    <div className="text-sm break-words">{children}</div>
  </section>
);

const linkCls = "text-clay hover:text-clay/80 no-underline";

// The old 任务 page's fields, all of them, folded under the details.
const TaskFacts: FC<{ t: Task; stale: boolean }> = ({ t, stale }) => {
  const st = taskStatus(t);
  const blockers = taskBlockerItems(t);
  const observed = () => {
    if (!t.live?.state) return tr("无当前会话观测", "No current session observation");
    if (t.live.needs || t.live.state.startsWith("needs")) return tr("在问你", "Asking you");
    const words: Record<string, [string, string]> = {
      working: ["在做", "Working"], idle: ["空闲", "Idle"], done: ["本轮结束", "Turn ended"], exited: ["会话退出", "Session exited"], blocked: ["被卡住", "Blocked"],
    };
    return tr(...(words[t.live.state] || STATUS.unknown));
  };
  return (
    <details className="text-muted-foreground text-[13px]">
      <summary className="cursor-pointer rounded-sm focus-visible:outline-2 focus-visible:outline-ring">{tr("技术详情", "Technical details")}</summary>
      <dl className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 [&>dd]:break-words">
        <dt>{tr("编号", "Code")}</dt><dd className="font-mono">{writtenCode(t)}{t.fid ? <span className="break-all"> · {t.fid}</span> : null}</dd>
        {t.short ? <><dt>{tr("旧编号", "Old number")}</dt><dd className="font-mono">{t.task || t.id}</dd></> : null}
        <dt>{tr("任务状态", "Task state")}</dt><dd>{statusWords(st)}</dd>
        <dt>{tr("请求代理", "Requested agent")}</dt><dd>{t.requested_agent || unknown()}</dd>
        <dt>{tr("确定代理", "Resolved agent")}</dt><dd>{t.resolved_agent || unknown()}</dd>
        <dt>{tr("已核实代理", "Verified actual agent")}</dt><dd>{t.actual_agent || unknown()}</dd>
        <dt>{tr("会话观测", "Session observation")}</dt><dd>
          {t.live?.stale || stale ? tr("陈旧 / last-known · ", "Stale / last-known · ") : ""}{observed()}
          {" · "}{t.live?.source || "unknown"}{" · "}{t.live?.observed_at || "unknown"}
        </dd>
        <dt>{tr("运行证据", "Runtime evidence")}</dt><dd>{tr("未知 · inventory 未提供原生同源快照", "Unknown · inventory has no shared native snapshot")}</dd>
        <dt>{tr("接受/投递", "Acceptance/delivery")}</dt><dd>{tr("未知 · 缺少 controller 回执", "Unknown · controller receipt unavailable")}</dd>
        <dt>{tr("循环计划", "Loop schedule")}</dt><dd>{tr("未知 · 未提供计划证据，运行不表示已接受", "Unknown · schedule evidence unavailable; running does not mean accepted")}</dd>
        <dt>{tr("回收保留", "Reap retention")}</dt><dd>{tr("未知 · 未提供同源 proof；不授权关闭", "Unknown · shared proof unavailable; no permission to close")}</dd>
        <dt>{tr("部署 / 现场", "Deployment / live")}</dt><dd>{tr("未知 · PR 合并不等于上线", "Unknown · PR merged does not mean deployed")}</dd>
        <dt>{tr("来源", "Source")}</dt><dd>{tr("任务：hub 权威 GET；会话：inventory（与 native runtime 独立）", "Task: authoritative hub GET; session: inventory (separate from native runtime)")}</dd>
        <dt>{tr("任务更新于", "Task updated")}</dt><dd>{t.updated_at || unknown()}</dd>
        <dt>{tr("任务阻塞", "Task blockers")}</dt><dd>
          {stale ? <p>{tr("陈旧 · 以下仅为 last-known，不代表阻塞已解除", "Stale · last-known only; no blocker resolution inferred")}</p> : null}
          {blockers === null ? tr("未知 · 缺少本代 task-blockers.v1", "Unknown · current task-blockers.v1 unavailable")
            : blockers.length === 0 ? tr("本代没有显式阻塞；会话提问和批准独立保留", "No explicit blockers in this generation; questions and approvals remain independent")
            : blockers.map((b) => <p key={b.blocker_id} className="break-words">
              {b.blocker_id}{" · "}{b.state}{b.reason ? ` · ${b.reason}` : ""}{" · "}{b.resolved_at || b.revoked_at || b.created_at || unknown()}
            </p>)}
        </dd>
        {t.asked ? <><dt>{tr("提问 / 批准", "Question / approval")}</dt><dd>{t.asked}</dd></> : null}
        {t.generation ? <><dt>{tr("执行代次", "Attempt")}</dt><dd>{t.generation}</dd></> : null}
        {t.worker_id ? <><dt>{tr("会话身份", "Session identity")}</dt><dd className="break-all!">{t.worker_id}</dd></> : null}
        {t.cancel_request && st !== "cancelled" ? <><dt>{tr("取消", "Cancellation")}</dt><dd>{tr("已请求，尚未确认停止", "Requested; stopping is not confirmed")}</dd></> : null}
        {t.parked ? <><dt>{tr("停放", "Parked")}</dt><dd>{t.parked}</dd></> : null}
      </dl>
    </details>
  );
};

// One row's details: what it asks, the person's words, its report, its PR,
// its members, its session, the ways in.
// onTerminal (GR5E C4): inside a session's workspace its terminal is a switch
// away — the buttons switch there instead of opening /terminal
// 命令行接入 (会话合一 Y01K): inside a session's own page its 详情 gives the
// line that opens it in the person's terminal and the install line; the web
// terminal is one small line at the foot (onTerminal), never a big button.
const CliAccess: FC<{ r: Row; onTerminal?: () => void }> = ({ r, onTerminal }) => {
  const install = useInstallLine();
  return (
    <div className="space-y-1.5" data-testid="cli-access">
      <p className="text-muted-foreground text-xs">{tr("在终端里接着用", "Continue in a terminal")}</p>
      <CopyLine text={openLine(r)} />
      <p className="text-muted-foreground pt-1 text-xs">{tr("还没装 fleet？先在 iTerm2 里粘贴：", "No fleet yet? Paste this in iTerm2 first:")}</p>
      <CopyLine text={install} />
      <p className="text-muted-foreground text-xs">{tr("Windows 在 WSL 里粘贴同样两行。", "On Windows, paste the same two lines in WSL.")}</p>
      {onTerminal ? <p className="pt-2 text-[12px]"><button type="button" onClick={onTerminal} data-testid="web-term"
        className="text-muted-foreground hover:text-foreground">{tr("网页终端（备用）", "Web terminal (backup)")}</button></p> : null}
    </div>
  );
};

const Detail: FC<{ r: Row; stale: boolean; busy: boolean; onOpen: (r: Row) => void; onReap: (r: Row) => void; onResume: (r: Row) => void; onTerminal?: () => void; cli?: boolean }> = ({ r, stale, busy, onOpen, onReap, onResume, onTerminal, cli }) => {
  const t = r.task, s = r.live || r.ended;
  // a machine's name only for a person with more than one (会话合一 Y01K)
  const { machines } = useWorkRows();
  const machine = machines > 1 ? machineOf(r) : "";
  const pr = t ? taskPR(t) : null;
  const landing = t ? taskLanding(t) : "";
  const ticket = t ? taskTicket(t) : null;
  const asking = r.live && (r.live.state === "needs" || r.live.state === "blocked");
  const words = t ? taskWords(t) : "";
  return (
    <div className="space-y-5">
      <div className="space-y-1">
        <div className="flex items-baseline gap-2">
          {r.code ? <span className="text-clay font-mono text-sm">{r.code}</span> : null}
          <h2 className="font-display text-xl leading-snug font-semibold break-words">{r.title}</h2>
        </div>
        <p className="text-muted-foreground text-sm">{[tr(...r.tag), machine, t?.repo || s?.repo].filter(Boolean).join(" · ")}</p>
        {r.board?.agent_words ? <p className="text-sm">{tr(...r.board.agent_words)}</p> : null}
        {r.board?.context ? <p className="text-sm">{tr(...r.board.context)}</p> : null}
        {r.parentTitle ? <p className="text-muted-foreground text-sm">{tr(`属于「${r.parentTitle}」`, `Part of “${r.parentTitle}”`)}</p> : null}
      </div>
      {asking && r.live ? (
        <Card className="border-clay-line bg-clay-soft gap-2 py-3">
          <CardContent className="space-y-2 px-4">
            <p className="text-muted-foreground text-xs">{tr(...(ASK_KIND[r.live.ask?.kind || ""] || ASK_KIND.question))}</p>
            {r.live.ask?.msg ? <p className="text-sm break-words whitespace-pre-wrap">{r.live.ask.msg}</p> : null}
            {cli ? <p className="text-muted-foreground text-xs">{tr("在对话里点选项回答，或在终端里：", "Pick an option in the chat, or in a terminal:")} <span className="font-mono">{openLine(r)}</span></p>
              : onTerminal ? <Button size="sm" className="w-full" onClick={onTerminal}><TerminalSquare />{tr("去终端回答", "Answer in the terminal")}</Button>
              : <Button asChild size="sm" className="w-full"><Link to={terminalLink(r.live.id)} state={{ title: r.title }}><TerminalSquare />{tr("去终端回答", "Answer in the terminal")}</Link></Button>}
            {cli ? null : <p className="text-muted-foreground font-mono text-[12px] break-all select-all">fleet answer {r.live.key}</p>}
          </CardContent>
        </Card>
      ) : t?.asked && r.group === "ask" ? (
        <Card className="border-clay-line bg-clay-soft gap-0 py-3"><CardContent className="px-4">
          <p className="text-muted-foreground mb-1 text-xs">{tr("它在等你", "It's waiting on you")}</p>
          <p className="text-sm break-words">{t.asked}</p>
        </CardContent></Card>
      ) : null}
      {t && agentMismatch(t) ? <p className="text-destructive text-sm">{tr("代理不一致：实际运行与选择不符。", "Agent mismatch: the verified agent differs from the selection.")}</p> : null}
      {t ? <Field label={tr("你的原话", "Your words")}>
        <p className="bg-muted rounded-lg px-3 py-2 whitespace-pre-wrap">{words}</p>
        <p className="text-muted-foreground mt-1 text-xs">{[t.via, t.device, ago(t.created_at)].filter(Boolean).join(" · ")}</p>
      </Field> : null}
      {t?.evidence ? <Field label={tr("它的回报", "Its report")}>{t.evidence}</Field> : null}
      {pr ? <Field label="PR">
        <a href={pr.url} target="_blank" rel="noopener noreferrer" className={cn(linkCls, "break-all")}>{pr.repo}#{pr.n} <ArrowUpRight className="inline size-3.5" aria-hidden /></a>
        <span className="text-muted-foreground"> · {landing === "merged" ? tr("PR 已合并", "PR merged") : landing === "waiting" ? tr("等待 GitHub · PR 尚未确认合并", "Waiting for GitHub · PR merge is not confirmed") : tr("PR 合并状态未知", "PR merge status unknown")}</span>
      </Field> : null}
      {ticket ? <Field label={tr("GitHub 单", "GitHub issue")}>
        {/^[\w.-]+\/[\w.-]+$/.test(ticket.repo) ? <a href={`https://github.com/${ticket.repo}/issues/${ticket.n}`} target="_blank" rel="noopener noreferrer" className={cn(linkCls, "break-all")}>
          {ticket.repo}#{ticket.n} <ArrowUpRight className="inline size-3.5" aria-hidden /></a> : <span className="break-all">{ticket.repo}#{ticket.n}</span>}
      </Field> : null}
      {r.kids.length ? <Field label={tr(`成员 ${r.kids.length}`, `Members ${r.kids.length}`)}>
        <div className="divide-y rounded-lg border">
          {r.kids.map((k) => {
            const Icon = GLYPH[k.glyph];
            return <button key={k.id} type="button" onClick={() => onOpen(k)} className="hover:bg-muted/60 flex w-full items-center gap-2 px-3 py-2 text-left">
              <Icon className={cn("size-4 shrink-0", TONE[k.tone])} aria-hidden /><span className="text-clay font-mono text-xs">{k.code}</span>
              <span className="min-w-0 flex-1 truncate">{k.title}</span><span className="text-muted-foreground shrink-0 text-xs">{tr(...k.tag)}</span>
            </button>;
          })}
        </div>
      </Field> : null}
      <Field label={tr("会话", "Session")}>
        {s ? <p>{[machines > 1 ? s.machine : "", s.key, r.live?.born ? tr(`开始于 ${ago(new Date(r.live.born * 1000).toISOString())}`, `started ${ago(new Date(r.live.born * 1000).toISOString())}`)
          : r.ended ? tr(`收起于 ${ago(r.ended.ended)}`, `put away ${ago(r.ended.ended)}`) : "",
          r.live?.tokens ? tr(`今天 ${fmtTokens(r.live.tokens)} tokens`, `${fmtTokens(r.live.tokens)} tokens today`) : ""].filter(Boolean).join(" · ")}</p>
          : <p className="text-muted-foreground">{t && r.group === "queue" ? tr("现在看不到它的会话 —— 还没开，或在看不到的机器上", "No session seen now — not open yet, or on a machine not visible") : tr("没有会话", "No session")}</p>}
      </Field>
      <div className="flex flex-wrap gap-2">
        {r.live && !cli ? onTerminal ? <Button className="flex-1" onClick={onTerminal}><TerminalSquare />{tr("终端", "Terminal")}</Button>
          : <Button asChild className="flex-1"><Link to={terminalLink(r.live.id)} state={{ title: r.title }}><TerminalSquare />{tr("终端", "Terminal")}</Link></Button> : null}
        {r.ended ? <Button className="flex-1" disabled={busy || !!viewAs} onClick={() => onResume(r)}><RotateCcw />{tr("接回", "Resume")}</Button> : null}
        {t && !cli ? <Button asChild variant="outline" className="flex-1"><Link to={`/chat?about=${encodeURIComponent(writtenCode(t))}`}><MessageCircle />{tr("在对话里说", "Talk about it")}</Link></Button> : null}
        {r.live ? <Button variant="outline" size="icon" disabled={busy || !!viewAs} onClick={() => onReap(r)} aria-label={tr("回收", "Close")} title={tr("回收", "Close")}><Trash2 /></Button> : null}
      </div>
      {cli && (r.live || r.board?.worker_id) ? <CliAccess r={r} onTerminal={onTerminal} /> : null}
      {t ? <TaskFacts t={t} stale={stale} /> : null}
    </div>
  );
};

// One row's details with their two writes (回收 · 接回) and what came of them —
// 会话's side panel and a session's own page (/s/:ref, GR5E C2) alike.
export const RowPanel: FC<{ r: Row; onOpen: (r: Row) => void; onTerminal?: () => void; cli?: boolean }> = ({ r, onOpen, onTerminal, cli }) => {
  const { stale, reload } = useWorkRows();
  const [confirm, setConfirm] = useState<Row | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const act = async (x: Row, tool: "worker_reap" | "worker_resume") => {
    const id = tool === "worker_reap" ? x.live?.id : x.ended?.id;
    if (!id) return;
    setBusy(true);
    setNote(null);
    const why = await sessionWrite(tool, id);
    setBusy(false);
    setConfirm(null);
    if (why) setNote({ ok: false, text: tool === "worker_reap" ? tr(`没能回收：${why}`, `Could not close it: ${why}`) : tr(`没能接回：${why}`, `Could not resume it: ${why}`) });
    else setNote({ ok: true, text: tool === "worker_reap" ? tr("已回收，放进「已收起」——之后还能接回。", "Closed — it is under Put away and can be resumed.")
      : tr("已接回，会话重新开始干活。", "Resumed — the session is back at work.") });
    reload();
  };
  return (
    <>
      {note ? <p role="status" className={cn("mb-4 text-sm", note.ok ? "text-muted-foreground" : "text-destructive")}>{note.text}</p> : null}
      <Detail r={r} stale={stale} busy={busy} onOpen={onOpen} onReap={setConfirm} onResume={(x) => act(x, "worker_resume")} onTerminal={onTerminal} cli={cli} />
      <AlertDialog open={!!confirm} onOpenChange={(o) => !o && !busy && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{tr(`回收「${confirm?.title ?? ""}」？`, `Close “${confirm?.title ?? ""}”?`)}</AlertDialogTitle>
            <AlertDialogDescription>
              {tr("会话停下、腾出位置。它做过的事都留着，之后可以在「已收起」里接回。",
                "The session stops and frees its place. Its work is kept; you can resume it from Put away.")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>{tr("先不", "Not now")}</AlertDialogCancel>
            <AlertDialogAction disabled={busy} onClick={(e) => { e.preventDefault(); if (confirm) void act(confirm, "worker_reap"); }}>
              {busy ? <Loader className="animate-spin" aria-hidden /> : null}{tr("回收", "Close")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
};

// the details sit beside the list from 1024 px up, in a sheet below that
function useNarrow() {
  const q = "(max-width: 1023px)";
  const [n, setN] = useState(() => matchMedia(q).matches);
  useEffect(() => { const m = matchMedia(q); const f = () => setN(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, []);
  return n;
}

const clock = (ms: number) => (ms ? new Date(ms).toLocaleTimeString("zh-CN", { hour12: false }) : "");

export default function SessionsPage() {
  usePage(tr("会话", "Sessions"));
  const { rows, board, boardAt, tasks, stale, failed, reload } = useWorkRows();
  const narrow = useNarrow();
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState("");
  const [folded, setFolded] = useState<Record<string, boolean>>({});
  const [goneOpen, setGoneOpen] = useState(false);
  const [newOpen, setNewOpen] = useState(false);
  const [sheet, setSheet] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [found, setFound] = useState<Row | null>(null);
  const repos = useMemo(() => reposOf(rows), [rows]);
  const ref = params.get("open") || params.get("q") || "";
  const picked = rows && ref ? findRow(rows, ref) || (found && findRow([found], ref) ? found : undefined) : undefined;

  // a code a link names that the list does not hold (older than 14 days): the
  // hub's resolver, the row drawn from the record alone
  useEffect(() => {
    if (!rows || !ref || findRow(rows, ref)) return;
    let on = true;
    findTask(ref).then((f) => { if (on && f.kind === "one") setFound(rowOf(f.task, undefined, undefined, writtenCode(f.task))); });
    return () => { on = false; };
  }, [rows, ref]);
  // a link that names a row on a phone opens its sheet
  const pickedID = picked?.id;
  useEffect(() => { if (narrow && pickedID) setSheet(true); }, [narrow, pickedID]);

  const match = (r: Row) => !q.trim() || `${r.code} ${r.task ? writtenCode(r.task) : ""} ${r.title}`.toLowerCase().includes(q.trim().toLowerCase());
  const visible = (rows || []).filter((r) => match(r) || r.kids.some(match));
  const current = picked || (!narrow && rows ? rowsIn(visible, "ask")[0] || rowsIn(visible, "work")[0] || visible[0] : undefined);
  const open = (r: Row) => {
    setParams((p) => { p.delete("q"); p.set("open", r.code ? (r.task ? writtenCode(r.task) : r.code) : r.id); return p; }, { replace: true });
    if (narrow) setSheet(true);
  };

  const retry = reload;
  const list = rows === null ? (failed ? <Failed what={tr("会话", "your sessions")} onRetry={retry} /> : <Loading />)
    : !rows.length ? <Empty icon={<Layers />} title={stale ? tr("数量未知", "Count unknown") : tr("还没有会话", "No sessions yet")}
      body={stale ? tr("当前来源不可用，请重试读取。空的陈旧快照不代表没有任务。", "The source is unavailable. Retry the read; an empty stale snapshot does not mean zero tasks.")
        : tr("点「新建」说一件要做的事，或者在「对话」里说一句。", "Tap New and say what needs doing, or ask in Chat.")}
      action={stale ? <Button size="sm" variant="outline" onClick={retry}>{tr("重试读取", "Retry read")}</Button>
        : <Button size="sm" disabled={!!viewAs} onClick={() => setNewOpen(true)}><Plus />{tr("新建", "New")}</Button>} />
    : (
      <div className="space-y-4">
        <Messages rows={rows} onOpen={open} />
        {GROUPS.map(({ g, label }) => {
          const rs = rowsIn(visible, g);
          if (!rs.length) return null;
          const fold = g === "gone" && !goneOpen && !q.trim();
          return (
            <section key={g} className="space-y-1.5" aria-label={tr(...label)}>
              <h2 className="text-muted-foreground flex items-center gap-1.5 px-1 text-xs font-medium">
                {g === "gone" ? <button type="button" onClick={() => setGoneOpen(!goneOpen)} className="hover:text-foreground flex items-center gap-1" aria-expanded={!fold}>
                  {fold ? <ChevronRight className="size-3.5" /> : <ChevronDown className="size-3.5" />}{tr(...label)}
                </button> : tr(...label)}
                <span className="font-mono">{rs.length}</span>
                {g === "gone" ? <span>· {board ? tr(`近 ${board.gone_days} 天 · 不计数`, `last ${board.gone_days} days · not counted`) : tr("近 14 天", "last 14 days")}</span> : null}
              </h2>
              {fold ? null : <Card className={cn("gap-0 divide-y overflow-hidden py-0", g === "ask" && "border-clay-line")}>
                {rs.map((r) => {
                  const kidsOpen = !folded[r.id];
                  const kids = nestedKids(r).filter(match);
                  return (
                    <div key={r.id} className="divide-y">
                      <RowLine r={r} kids={kids} on={!narrow && current?.id === r.id} open={kidsOpen} onOpen={() => open(r)} onFold={() => setFolded({ ...folded, [r.id]: kidsOpen })} />
                      {kidsOpen ? kids.map((k) =>
                        <RowLine key={k.id} r={k} child on={!narrow && current?.id === k.id} open={false} onOpen={() => open(k)} />) : null}
                    </div>
                  );
                })}
              </Card>}
            </section>
          );
        })}
      </div>
    );

  const detail = current ? <RowPanel key={current.id} r={current} onOpen={open} /> : null;
  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("会话", "Sessions")} count={board ? board.count : undefined}
        sub={board ? tr(`和 ⌘P 面板同一份清单 · ${clock(boardAt)}`, `The same list as the ⌘P panel · ${clock(boardAt)}`)
          : tr("你派出的每件事和开着的会话，一件一行", "Everything you sent out and every open session, one line each")}
        action={<Button disabled={!!viewAs} onClick={() => setNewOpen(true)}><Plus />{tr("新建", "New")}</Button>} />
      <div className="lg:grid lg:grid-cols-[minmax(0,1fr)_400px] lg:gap-6">
        <div className="min-w-0 space-y-4">
          <div className="flex gap-2">
            <div className="relative flex-1">
              <Search className="text-muted-foreground pointer-events-none absolute start-2.5 top-1/2 size-4 -translate-y-1/2" aria-hidden />
              <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder={tr("找编号或标题，如 K5", "Find a code or title, e.g. K5")}
                aria-label={tr("找编号或标题", "Find a code or title")} className="ps-8" autoComplete="off" spellCheck={false} />
            </div>
            <Button asChild variant="outline"><Link to={shellPath()}><TerminalSquare />{tr("我的终端", "My Terminal")}</Link></Button>
          </div>
          {tasks.data && stale ? <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
            <p role="status" className="text-clay">{tr("暂时无法更新 · 保留上次确认的状态", "Stale information · showing the last confirmed state")}
              {" · "}<time dateTime={tasks.data.observed_at}>{tasks.data.observed_at || unknown()}</time></p>
            <Button size="sm" variant="outline" disabled={tasks.loading} onClick={retry}>{tasks.loading ? tr("正在读取…", "Reading…") : tr("重试读取", "Retry read")}</Button>
          </div> : null}
          {note ? <p role="status" className={cn("text-sm", note.ok ? "text-muted-foreground" : "text-destructive")}>{note.text}</p> : null}
          {list}
        </div>
        {!narrow && detail ? <aside aria-label={tr("详情", "Details")}>
          <Card className="sticky top-6 py-5"><CardContent className="px-5">{detail}</CardContent></Card>
        </aside> : null}
      </div>
      <Sheet open={narrow && sheet && !!current} onOpenChange={(o) => { setSheet(o); if (!o) setParams((p) => { p.delete("open"); p.delete("q"); return p; }, { replace: true }); }}>
        <SheetContent side="bottom" className="max-h-[88svh] overflow-y-auto rounded-t-2xl">
          <SheetHeader className="sr-only"><SheetTitle>{current?.title}</SheetTitle><SheetDescription>{current ? tr(...current.tag) : ""}</SheetDescription></SheetHeader>
          {narrow ? <div className="px-4 pt-5 pb-6">{detail}</div> : null}
        </SheetContent>
      </Sheet>
      <NewDialog open={newOpen} onOpenChange={setNewOpen} repos={repos} onDone={(ok, text) => { setNote({ ok, text }); if (ok) reload(); }} />
    </div>
  );
}
