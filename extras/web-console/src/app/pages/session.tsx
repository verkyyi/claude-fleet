// session.tsx — one session, /app/s/<ref> (GR5E C2): what a row of the session
// list opens. Until the session's own workspace (C4) switches 对话 | 终端 in
// place, it shows the row's details — the same card 会话 shows, with its ways
// in — and ?view=term goes straight to its terminal. <ref> is a code, a task's
// ID or a session's identity (work.ts findRow); one the list no longer holds is
// asked of the hub's resolver.
import { useEffect, useState } from "react";
import { Link, Navigate, useNavigate, useParams, useSearchParams } from "react-router";
import { ArrowLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { tr } from "@/shared/i18n";
import { terminalLink } from "@/shared/terminal";
import { usePage } from "../Shell";
import { Empty, Loading } from "../parts";
import { rowMeta } from "../session-list";
import { sessionPath } from "../SessionList";
import { writtenCode } from "../task-state";
import { findTask } from "../use-tasks";
import { findRow, rowOf, type Row } from "../work";
import { useWorkRows } from "../work-rows";
import { RowPanel } from "./sessions";

export default function SessionPage() {
  const { ref = "" } = useParams();
  const [params] = useSearchParams();
  const go = useNavigate();
  const { rows, markSeen } = useWorkRows();
  const [found, setFound] = useState<Row | null | undefined>(undefined);
  const inList = rows ? findRow(rows, ref) : undefined;
  const r = inList || found || undefined;
  usePage(r?.title || tr("会话", "Session"));

  useEffect(() => {
    if (!rows || findRow(rows, ref)) return;
    let on = true;
    findTask(ref).then((f) => { if (on) setFound(f.kind === "one" ? rowOf(f.task, undefined, undefined, writtenCode(f.task)) : null); });
    return () => { on = false; };
  }, [rows, ref]);
  // opened is seen: the row reads plain again in the list
  const mark = inList ? `${inList.id}\t${inList.tag[1]}\t${inList.at}` : "";
  useEffect(() => { if (inList) markSeen(inList); }, [mark]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!rows || (!inList && found === undefined)) return <div className="mx-auto max-w-3xl px-4 py-6"><Loading /></div>;
  if (!r) return (
    <div className="mx-auto max-w-3xl px-4 py-6">
      <Empty icon={<ArrowLeft />} title={tr("没找到这个会话", "No such session")}
        body={tr(`「${ref}」不在你的会话里。`, `“${ref}” is not one of your sessions.`)}
        action={<Button asChild size="sm" variant="outline"><Link to="/">{tr("回到会话列表", "Back to the list")}</Link></Button>} />
    </div>
  );
  if (params.get("view") === "term" && r.live) return <Navigate to={terminalLink(r.live.id)} state={{ title: r.title }} replace />;
  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-4 md:px-6 md:py-8">
      <div className="mb-4 flex items-center gap-2 md:hidden">
        <Button variant="ghost" size="icon" className="-ms-2 size-8" aria-label={tr("返回", "Back")}
          onClick={() => (history.length > 1 ? go(-1) : go("/"))}><ArrowLeft /></Button>
        <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">{rowMeta(r)}</span>
      </div>
      <RowPanel r={r} onOpen={(k) => go(sessionPath(k))} />
    </div>
  );
}
