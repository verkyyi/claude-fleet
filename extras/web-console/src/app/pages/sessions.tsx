// sessions.tsx — 我的会话 (EPIC #3923 C4, issue #3927): one list of cards,
// filtered 全部 · 在跑 · 在问你 · 已结束; a card opens a Sheet that 回收s a live
// session (an AlertDialog asks first) or 接回s an ended one. Every session on
// every machine wears the same card — the machine is a plain word in its line
// (EPIC #3923 拍板 13). Stock shadcn/ui only.
import { useEffect, useMemo, useState, type FC } from "react";
import { Link } from "react-router";
import { Layers, Loader, RotateCcw, Trash2 } from "lucide-react";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { lang, tr } from "@/shared/i18n";
import { sessionWrite, useSessions, type Group, type SessionRow } from "@/shared/sessions";
import { usePage } from "../Shell";
import { Empty, Failed, Loading, PageHeader } from "../parts";

type Filter = "all" | Group;

const STATE: Record<string, { label: [string, string]; tone: string }> = {
  working: { label: ["在干活", "Working"], tone: "text-[var(--fleet-ok)]" },
  needs: { label: ["在问你", "Asking you"], tone: "text-clay border-clay-line bg-clay-soft" },
  blocked: { label: ["被卡住", "Blocked"], tone: "text-clay border-clay-line bg-clay-soft" },
  idle: { label: ["空闲", "Idle"], tone: "text-muted-foreground" },
  done: { label: ["做完了", "Done"], tone: "text-muted-foreground" },
  ended: { label: ["已结束", "Ended"], tone: "text-muted-foreground" },
  unknown: { label: ["状态未知", "Unknown"], tone: "text-muted-foreground" },
};
const stateOf = (s: string) => STATE[s] || STATE.unknown;
const ASK_KIND: Record<string, [string, string]> = {
  permission: ["它在请你批准", "It asks your permission"],
  question: ["它在问你", "It asks you"],
  auth: ["它要你登录", "It needs you to sign in"],
};

const fmtTokens = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : String(n));
const hhmm = (d: Date) => d.toLocaleTimeString(lang === "zh" ? "zh-CN" : "en", { hour: "2-digit", minute: "2-digit", hour12: false });
function when(d: Date) {
  const days = Math.floor((Date.now() - d.getTime()) / 864e5);
  if (days < 1 && new Date().getDate() === d.getDate()) return hhmm(d);
  if (days < 2) return tr(`昨天 ${hhmm(d)}`, `yesterday ${hhmm(d)}`);
  return d.toLocaleDateString(lang === "zh" ? "zh-CN" : "en", { month: "numeric", day: "numeric" });
}
function metaLine(r: SessionRow) {
  const parts = [r.ended ? tr(`结束于 ${when(new Date(r.ended))}`, `ended ${when(new Date(r.ended))}`)
    : r.born ? tr(`开始于 ${when(new Date(r.born * 1000))}`, `started ${when(new Date(r.born * 1000))}`) : ""];
  if (r.machine) parts.push(r.machine);
  if (r.tokens) parts.push(tr(`今天 ${fmtTokens(r.tokens)} tokens`, `${fmtTokens(r.tokens)} tokens today`));
  return parts.filter(Boolean).join(" · ");
}

const StateBadge: FC<{ state: string }> = ({ state }) => {
  const s = stateOf(state);
  return (
    <Badge variant="outline" className={cn("shrink-0 rounded-full", s.tone)}>
      {state === "working" ? <Loader className="animate-spin [animation-duration:2.4s]" aria-hidden /> : null}
      {tr(...s.label)}
    </Badge>
  );
};

const SessionCard: FC<{ r: SessionRow; onOpen: () => void }> = ({ r, onOpen }) => (
  <Card role="button" tabIndex={0} onClick={onOpen} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(); } }}
    data-session={r.key} data-group={r.group}
    className={cn("hover:border-clay-line cursor-pointer gap-0 py-4 transition-colors", r.group === "ask" && "border-clay-line")}>
    <CardContent className="space-y-1.5 px-4">
      <div className="flex items-center gap-2">
        <p className="min-w-0 flex-1 truncate font-medium">{r.title}</p>
        <StateBadge state={r.state} />
      </div>
      {r.ask?.msg ? <p className="text-foreground line-clamp-3 text-sm break-words">{tr(`「${r.ask.msg}」`, `“${r.ask.msg}”`)}</p> : null}
      <p className="text-muted-foreground truncate text-[13px]">{metaLine(r)}</p>
    </CardContent>
  </Card>
);

// nothing under this filter: what it holds, and for an empty list the way in
const NoSessions: FC<{ filter: Filter }> = ({ filter }) => (
  <Empty icon={<Layers />}
    title={filter === "all" ? tr("还没有会话", "No sessions yet") : tr("这里没有会话", "Nothing here")}
    body={filter === "all" ? tr("在「对话」里说一件要做的事，就会开出第一个会话。", "Ask for something in Chat and the first session opens.")
      : filter === "ended" ? tr("近 14 天回收或做完收起的会话会在这里，可以接回。", "Sessions closed in the last 14 days show here, ready to resume.")
        : tr("换个筛选看看。", "Try another filter.")}
    action={filter === "all" ? <Button asChild size="sm" className="no-underline"><Link to="/">{tr("去说一句", "Go to Chat")}</Link></Button> : undefined} />
);

export default function SessionsPage() {
  usePage(tr("会话", "Sessions"));
  const { live, ended, failed, reload } = useSessions();
  // what this page just did, until the lists say it too: a reaped session shows
  // as ended at once, a resumed one leaves 已结束 at once
  const [reaped, setReaped] = useState<SessionRow[]>([]);
  const [resumed, setResumed] = useState<string[]>([]);
  const [filter, setFilter] = useState<Filter | null>(null);
  const [open, setOpen] = useState<SessionRow | null>(null);
  const [confirm, setConfirm] = useState<SessionRow | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);

  // once the lists say it themselves, the page's own word goes
  useEffect(() => {
    const endedIDs = new Set((ended || []).map((r) => `${r.machine}\t${r.key}`));
    const liveIDs = new Set((live || []).map((r) => `${r.machine}\t${r.key}`));
    setReaped((x) => (x.some((r) => endedIDs.has(`${r.machine}\t${r.key}`)) ? x.filter((r) => !endedIDs.has(`${r.machine}\t${r.key}`)) : x));
    setResumed((x) => (x.some((k) => liveIDs.has(k)) ? x.filter((k) => !liveIDs.has(k)) : x));
  }, [live, ended]);

  const rows = useMemo(() => {
    if (!live) return null;
    const liveKeys = new Set(live.map((r) => `${r.machine}\t${r.key}`));
    const gone = new Set(reaped.map((r) => `${r.machine}\t${r.key}`));
    const out = live.filter((r) => !gone.has(`${r.machine}\t${r.key}`));
    const endedKeys = new Set<string>();
    for (const r of ended || []) {
      const k = `${r.machine}\t${r.key}`;
      if (liveKeys.has(k) || resumed.includes(k)) continue;
      endedKeys.add(k);
      out.push(r);
    }
    for (const r of reaped) {
      const k = `${r.machine}\t${r.key}`;
      if (!endedKeys.has(k) && !liveKeys.has(k)) out.push({ ...r, state: "ended", group: "ended", ask: null, ended: new Date().toISOString(), tokens: 0 });
    }
    return out;
  }, [live, ended, reaped, resumed]);

  const count = (g: Group) => (rows ? rows.filter((r) => r.group === g).length : 0);
  // a person who opens the page while something asks them lands on it
  const f: Filter = filter ?? (rows && count("ask") ? "ask" : "all");
  const shown = (rows || []).filter((r) => f === "all" || r.group === f);

  const act = async (r: SessionRow, tool: "worker_reap" | "worker_resume") => {
    setBusy(true);
    setNote(null);
    const why = await sessionWrite(tool, r.id);
    setBusy(false);
    setOpen(null);
    setConfirm(null);
    if (why) {
      setNote({ ok: false, text: tool === "worker_reap" ? tr(`没能回收：${why}`, `Could not close it: ${why}`) : tr(`没能接回：${why}`, `Could not resume it: ${why}`) });
      return;
    }
    if (tool === "worker_reap") {
      setReaped((x) => [...x, r]);
      setNote({ ok: true, text: tr("已回收，放进「已结束」——之后还能接回。", "Closed — it is under Ended and can be resumed.") });
    } else {
      setResumed((x) => [...x, `${r.machine}\t${r.key}`]);
      setReaped((x) => x.filter((y) => !(y.machine === r.machine && y.key === r.key)));
      setNote({ ok: true, text: tr("已接回，会话重新开始干活。", "Resumed — the session is back at work.") });
    }
    reload();
  };

  const tabs: [Filter, string, number | null][] = [
    ["all", tr("全部", "All"), rows ? rows.length : null],
    ["run", tr("在跑", "Running"), rows ? count("run") : null],
    ["ask", tr("在问你", "Asking"), rows ? count("ask") : null],
    ["ended", tr("已结束", "Ended"), rows ? count("ended") : null],
  ];

  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("我的会话", "My sessions")} sub={tr("每件事一个会话，关掉页面也照常跑", "One session per job — they keep running when you close the page")} />
      <Tabs value={f} onValueChange={(v) => setFilter(v as Filter)}>
        <TabsList className="w-full sm:w-auto">
          {tabs.map(([v, label, n]) => (
            <TabsTrigger key={v} value={v} className="px-2.5">
              {label}{n === null ? null : <span className="text-muted-foreground font-mono text-xs">{n}</span>}
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>
      {note ? <p role="status" className={cn("text-sm", note.ok ? "text-muted-foreground" : "text-destructive")}>{note.text}</p> : null}
      {rows === null ? (
        failed ? <Failed what={tr("会话", "your sessions")} onRetry={reload} /> : <Loading />
      ) : shown.length ? (
        <div className="space-y-3">{shown.map((r) => <SessionCard key={`${r.group}:${r.machine}:${r.key}`} r={r} onOpen={() => setOpen(r)} />)}</div>
      ) : (
        <NoSessions filter={f} />
      )}

      <Sheet open={!!open} onOpenChange={(o) => !o && setOpen(null)}>
        <SheetContent side="bottom" className="mx-auto max-h-[85svh] max-w-xl overflow-y-auto rounded-t-2xl">
          {open ? (
            <>
              <SheetHeader>
                <SheetTitle className="font-display pe-6 text-xl">{open.title}</SheetTitle>
                <SheetDescription>
                  {[tr(...stateOf(open.state).label), open.machine, open.repo].filter(Boolean).join(" · ")}
                </SheetDescription>
              </SheetHeader>
              <div className="space-y-3 px-4 text-sm">
                {open.ask?.msg ? (
                  <Card className="border-clay-line bg-clay-soft gap-0 py-3">
                    <CardContent className="px-4">
                      <p className="text-muted-foreground mb-1 text-xs">{tr(...(ASK_KIND[open.ask.kind] || ASK_KIND.question))}</p>
                      <p className="break-words whitespace-pre-wrap">{open.ask.msg}</p>
                    </CardContent>
                  </Card>
                ) : null}
                <p className="text-muted-foreground text-[13px]">{metaLine(open)}</p>
                {open.group !== "ended" ? (
                  <>
                    <div className="bg-muted rounded-lg p-3 font-mono text-[12px] break-all select-all">
                      {open.group === "ask" ? `fleet answer ${open.key}` : `fleet open ${open.key}`}
                    </div>
                    <p className="text-muted-foreground text-xs">
                      {open.group === "ask" ? tr("在电脑的终端里粘贴这一行，回答它。", "Paste this in a terminal on your computer to answer it.")
                        : tr("在电脑的终端里粘贴这一行，接着这个会话。", "Paste this in a terminal on your computer to pick the session up.")}
                    </p>
                  </>
                ) : (
                  <p className="text-muted-foreground text-xs">{tr("接回会在原来那台机器上重新开起这个会话，接着它做过的事。", "Resuming reopens it on the same machine, where it left off.")}</p>
                )}
              </div>
              <SheetFooter className="flex-row gap-2">
                {open.group === "ended" ? (
                  <Button className="flex-1" disabled={busy} onClick={() => act(open, "worker_resume")}>
                    <RotateCcw />{tr("接回", "Resume")}
                  </Button>
                ) : (
                  <Button variant="outline" className="flex-1" disabled={busy} onClick={() => { setConfirm(open); setOpen(null); }}>
                    <Trash2 />{tr("回收", "Close")}
                  </Button>
                )}
              </SheetFooter>
            </>
          ) : null}
        </SheetContent>
      </Sheet>

      <AlertDialog open={!!confirm} onOpenChange={(o) => !o && !busy && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{tr(`回收「${confirm?.title ?? ""}」？`, `Close “${confirm?.title ?? ""}”?`)}</AlertDialogTitle>
            <AlertDialogDescription>
              {tr("会话停下、腾出位置。它做过的事都留着，之后可以在「已结束」里接回。",
                "The session stops and frees its place. Its work is kept; you can resume it from Ended.")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>{tr("先不", "Not now")}</AlertDialogCancel>
            <AlertDialogAction disabled={busy} onClick={(e) => { e.preventDefault(); if (confirm) act(confirm, "worker_reap"); }}>
              {busy ? <Loader className="animate-spin" aria-hidden /> : null}{tr("回收", "Close")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
