// ticket.tsx — one ticket under 任务 (EPIC #3923 C5, claude-fleet#3928), at
// /app/tasks/tickets/<owner>/<name>/<N>, where an old /fleet/tickets/… link
// lands: its words, its thread, a comment box (the session doing it reads the
// comment on its next turn) and close / reopen — the old page's forms as JSON
// calls on /v1/fleet/tickets/<owner>/<name>/<N>. A ticket whose home is
// GitHub is read here and written there. Someone else's is the same as none.
// Stock shadcn/ui only.
import { useEffect, useState, type FC } from "react";
import { Link, useParams } from "react-router";
import { ArrowUpRight, Check, ChevronLeft, CircleSlash, RotateCcw, SearchX, Send } from "lucide-react";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { getJSON, sendJSON } from "@/shared/api";
import { usePage, useShell } from "../Shell";
import { Empty, Failed, ago } from "../parts";
import { onGitHub, ticketState, type Ticket, type TicketComment } from "../tickets";

type Read = { state: "loading" } | { state: "gone" } | { state: "failed" } | { state: "ok"; ticket: Ticket; comments: TicketComment[] };

// The ticket and its thread: 404 is 「没有这张单子」, anything else unanswered is a retry.
function useTicket(path: string) {
  const [r, set] = useState<Read>({ state: "loading" });
  const [n, setN] = useState(0);
  useEffect(() => {
    let live = true;
    fetch(path, { headers: { Accept: "application/json" } }).then(async (res) => {
      if (res.status === 401) { location.assign("/app/signin"); return; }
      if (!live) return;
      if (res.status === 404) { set({ state: "gone" }); return; }
      const j = res.ok ? await res.json().catch(() => null) : null;
      if (live) set(j?.ticket ? { state: "ok", ticket: j.ticket, comments: j.comments || [] } : { state: "failed" });
    }).catch(() => live && set({ state: "failed" }));
    return () => { live = false; };
  }, [path, n]);
  return { read: r, reload: () => setN((x) => x + 1), set };
}

const backLink = (
  <Link to="/tasks?tab=tickets" className="text-muted-foreground hover:text-foreground -ms-1 mb-3 inline-flex items-center gap-0.5 text-sm no-underline">
    <ChevronLeft className="size-4" aria-hidden />{tr("单子", "Tickets")}
  </Link>
);

const Comment: FC<{ c: TicketComment; me: string }> = ({ c, me }) => {
  const bot = c.source === "fleet" || c.author.includes(" (node:");
  const mine = !bot && c.author === me;
  const who = mine ? tr("你", "You") : bot ? `${tr("会话", "Session")} ${c.author.split(" (node:")[0]}` : c.author;
  return (
    <li className="flex gap-3">
      <Avatar className="mt-0.5 size-7">
        <AvatarFallback className={cn("text-[11px]", bot ? "bg-clay-soft text-clay" : "")}>{bot ? "S" : (who[0] || "·").toUpperCase()}</AvatarFallback>
      </Avatar>
      <div className="min-w-0 flex-1">
        <p className="text-muted-foreground text-[13px]"><span className="text-foreground font-medium">{who}</span> · {ago(c.created_at)}</p>
        <p className="mt-1 text-[15px] leading-relaxed break-words whitespace-pre-wrap">{c.body}</p>
      </div>
    </li>
  );
};

export default function TicketPage() {
  const { owner = "", name = "", n = "" } = useParams();
  const repo = `${owner}/${name}`;
  const api = `/v1/fleet/tickets/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/${encodeURIComponent(n)}`;
  const { me } = useShell();
  const { read, reload, set } = useTicket(api);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState<"" | "comment" | "state">("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  usePage(read.state === "ok" ? `#${read.ticket.number} ${read.ticket.title}` : tr("单子", "Ticket"));

  if (read.state === "loading") {
    return (
      <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8" aria-busy="true">
        {backLink}
        <Skeleton className="h-7 w-3/4" />
        <Skeleton className="mt-2 h-4 w-1/2" />
        <Card className="mt-5"><CardContent className="space-y-2"><Skeleton className="h-4 w-full" /><Skeleton className="h-4 w-4/5" /></CardContent></Card>
      </div>
    );
  }
  if (read.state !== "ok") {
    return (
      <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8">
        {backLink}
        {read.state === "gone" ? (
          <Empty icon={<SearchX />} title={tr("没有这张单子", "No such ticket")}
            body={tr("它不存在，或者不是你的。", "It doesn't exist, or it isn't yours.")}
            action={<Button asChild variant="outline"><Link to="/tasks?tab=tickets" className="no-underline">{tr("回到单子", "Back to tickets")}</Link></Button>} />
        ) : <Failed what={tr("这张单子", "this ticket")} onRetry={reload} />}
      </div>
    );
  }

  const t = read.ticket;
  const st = ticketState(t);
  const gh = onGitHub(t);
  const closed = t.state === "closed";
  const meID = me?.person || "";

  const comment = async () => {
    const body = draft;
    if (!body.trim() || busy) return;
    setBusy("comment"); setMsg(null);
    const r = await sendJSON<TicketComment>("POST", `${api}/comments`, { body });
    setBusy("");
    if (!r.ok) { setMsg({ ok: false, text: tr(`没送出：${r.error || "入口没有回应"}`, `Not sent: ${r.error || "the hub didn't answer"}`) }); return; }
    setDraft("");
    set({ ...read, comments: [...read.comments, r.data] });
    setMsg({ ok: true, text: tr("已送出。正在做这张单的会话下一轮会看到。", "Sent. The session working on it sees it on its next turn.") });
  };
  const setState = async (state: "open" | "closed", reason: "completed" | "not_planned" | "reopened") => {
    setBusy("state"); setMsg(null);
    const r = await sendJSON<Ticket>("PATCH", api, { state, state_reason: reason });
    setBusy("");
    if (!r.ok) { setMsg({ ok: false, text: tr(`没改成：${r.error || "入口没有回应"}`, `Not changed: ${r.error || "the hub didn't answer"}`) }); return; }
    set({ ...read, ticket: r.data });
    setMsg({ ok: true, text: state === "closed" ? tr("已关上。", "Closed.") : tr("已重新打开。", "Reopened.") });
  };

  return (
    <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8">
      {backLink}
      <div className="flex items-start gap-2">
        <h1 className="font-display min-w-0 flex-1 text-[22px] leading-snug font-semibold tracking-tight break-words">
          <span className="text-muted-foreground me-1.5 font-mono text-base font-normal">#{t.number}</span>{t.title}
        </h1>
        <Badge variant="outline" className={cn("mt-1 shrink-0 rounded-full", st.tone)}>{st.label}</Badge>
      </div>
      <p className="text-muted-foreground mt-1.5 text-[13px] break-words">
        {repo} · {tr(`开于 ${ago(t.created_at)}`, `opened ${ago(t.created_at)}`)}
        {t.assignee && !closed ? ` · ${tr("在做", "Working")} ${t.assignee}` : ""}
      </p>

      {gh ? (
        <Card className="border-clay-line bg-clay-soft mt-4 gap-0 py-3">
          <CardContent className="flex items-center gap-3 text-sm">
            <p className="min-w-0 flex-1">{tr("这张单的家在 GitHub 上，评论和关单请到那里。", "This ticket lives on GitHub; comment and close it there.")}</p>
            {t.url?.startsWith("https://github.com/") ? (
              <Button asChild size="sm" variant="outline">
                <a href={t.url} target="_blank" rel="noopener noreferrer" className="no-underline">GitHub <ArrowUpRight /></a>
              </Button>
            ) : null}
          </CardContent>
        </Card>
      ) : null}

      <Card className="mt-4 gap-0 py-4">
        <CardContent>
          {t.body.trim()
            ? <p className="text-[15px] leading-relaxed break-words whitespace-pre-wrap">{t.body}</p>
            : <p className="text-muted-foreground text-sm">{tr("没有写正文。", "No description.")}</p>}
        </CardContent>
      </Card>

      {!gh ? (
        <>
          <h2 className="font-display mt-6 mb-3 text-base font-semibold">
            {tr("讨论", "Discussion")} <span className="text-muted-foreground font-sans text-sm font-normal">{read.comments.length}</span>
          </h2>
          {read.comments.length ? (
            <ul className="space-y-4">{read.comments.map((c) => <Comment key={c.id} c={c} me={meID} />)}</ul>
          ) : (
            <p className="text-muted-foreground text-sm">{tr("还没有人说话。", "Nobody has said anything yet.")}</p>
          )}
          <Separator className="my-5" />
          {closed ? (
            <p className="text-muted-foreground mb-3 text-sm">{tr("这张单子已经关上。还有话就写在下面；要接着做，点「重新打开」。", "This ticket is closed. You can still write below; to carry on, reopen it.")}</p>
          ) : null}
          <form onSubmit={(e) => { e.preventDefault(); comment(); }} className="space-y-3">
            <Textarea value={draft} onChange={(e) => setDraft(e.target.value)} rows={3} maxLength={65536}
              placeholder={tr("写点什么…正在做这张单的会话下一轮会看到。", "Write something… the session working on it sees it next turn.")}
              aria-label={tr("评论", "Comment")} className="min-h-24 text-[15px]" />
            {msg ? <p role="status" className={cn("text-sm", msg.ok ? "text-ok" : "text-destructive")}>{msg.text}</p> : null}
            <div className="flex flex-wrap items-center gap-2">
              <Button type="submit" disabled={!draft.trim() || !!busy}><Send />{busy === "comment" ? tr("正在送…", "Sending…") : tr("送出", "Send")}</Button>
              <span className="ms-auto" />
              {closed ? (
                <Button type="button" variant="outline" disabled={!!busy} onClick={() => setState("open", "reopened")}>
                  <RotateCcw />{tr("重新打开", "Reopen")}
                </Button>
              ) : (
                <>
                  <Button type="button" variant="outline" disabled={!!busy} onClick={() => setState("closed", "not_planned")}>
                    <CircleSlash />{tr("不做了", "Won't do")}
                  </Button>
                  <Button type="button" variant="outline" disabled={!!busy} onClick={() => setState("closed", "completed")}>
                    <Check />{tr("做完了，关掉", "Done, close")}
                  </Button>
                </>
              )}
            </div>
          </form>
        </>
      ) : null}
    </div>
  );
}
