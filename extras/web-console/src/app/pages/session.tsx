// session.tsx — one session, /app/s/<ref> (GR5E C2): what a row of the session
// list opens — its workspace (C4, Workspace.tsx), 对话 | 终端 switched in place
// by ?view=, 详情 in a drawer. <ref> is a code, a task's ID or a session's
// identity (work.ts findRow); one the list no longer holds is asked of the
// hub's resolver.
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { ArrowLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { tr } from "@/shared/i18n";
import { usePage } from "../Shell";
import { Empty, Loading } from "../parts";
import { writtenCode } from "../task-state";
import { findTask } from "../use-tasks";
import { findRow, rowOf, type Row } from "../work";
import { useWorkRows } from "../work-rows";
import { Workspace } from "../Workspace";

export default function SessionPage() {
  const { ref = "" } = useParams();
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
  return <Workspace key={r.id} r={r} />;
}
