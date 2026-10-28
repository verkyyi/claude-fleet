import { getJSON } from "@/shared/api";

// A task address opens its conversation; the separate Shell route remains native shell access.
import { lazy, useEffect, useState } from "react";
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
import { SHELL_REF } from "../legacy";

const TerminalPage = lazy(() => import("./terminal"));
// a session's identity (<fleet>/<id>) is a worker its terminal opens as it is
const isFID = (ref: string) => /^fid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ref);
const isWorker = (ref: string) => ref.includes("/");
const fresh = (worker: string): Row => ({ id: worker, code: "", title: tr("新会话", "New session"), group: "work", tag: ["回答中", "Replying"],
  glyph: "work", tone: "ok", line: "", quote: false, kids: [], at: Date.now(), origin: "web",
  board: { id: worker, title: "", group: "work", tag: "working", words: ["回答中", "Replying"], worker_id: worker, at: Date.now() / 1000 } });

export default function SessionPage() {
  const { ref = "" } = useParams();
  if (ref === SHELL_REF) return <TerminalPage key={SHELL_REF} worker={null} />;
  return <OneSession key={ref} ref_={ref} />;
}

function OneSession({ ref_: ref }: { ref_: string }) {
  const { rows, markSeen, setOpenRow } = useWorkRows();
  const [found, setFound] = useState<Row | null | undefined>(undefined);
  const lookup = isFID(ref) ? ref.slice(4) : ref;
  const inList = rows ? findRow(rows, lookup) : undefined;
  const r = inList || found || undefined;
  usePage(r?.title || tr("会话", "Session"));

  useEffect(() => {
    if (!rows || findRow(rows, lookup)) return;
    let on = true;
    if (isFID(ref)) {
      const history: Row = { ...fresh(ref), title: tr("会话", "Session"), glyph: "idle", tag: ["会话", "Session"], origin: "terminal", group: "gone", board: { ...fresh(ref).board!, group: "gone", tag: "unknown", state: "unknown", history: { id: ref.slice(4), status: "unknown", resume_id: "" } } };
      setFound(history);
      void getJSON<{run: {id: string; schedule_id: string; title: string}}>(`/v1/schedules?session_id=${encodeURIComponent(ref.slice(4))}`).then(data => {
        if (on && data) setFound({ ...history, title: data.run.title || history.title, board: { ...history.board!, schedule_id: data.run.schedule_id, run_id: data.run.id } });
      });
      return () => { on = false; };
    }
    findTask(ref).then((f) => { if (on) setFound(f.kind === "one" ? rowOf(f.task, undefined, undefined, writtenCode(f.task)) : null); });
    return () => { on = false; };
  }, [rows, ref, lookup]);
  // opened is seen: the row reads plain again in the list
  const mark = inList ? `${inList.id}\t${inList.tag[1]}\t${inList.at}` : "";
  useEffect(() => { if (inList) markSeen(inList); }, [mark]); // eslint-disable-line react-hooks/exhaustive-deps
  // the one looked at never says 新回复: its reply is on screen
  const openID = inList?.id || "";
  useEffect(() => { setOpenRow(openID); return () => setOpenRow(""); }, [openID, setOpenRow]);

  if (!rows || (!inList && found === undefined)) return <div className="mx-auto max-w-3xl px-4 py-6"><Loading /></div>;
  // a session just opened from 新会话 (会话合一 Y01K) the list does not carry yet: read by its worker
  if (!r && isWorker(ref)) return <Workspace key={ref} r={fresh(ref)} />;
  if (!r) return (
    <div className="mx-auto max-w-3xl px-4 py-6">
      <Empty icon={<ArrowLeft />} title={tr("没找到这个会话", "No such session")}
        body={tr(`「${ref}」不在你的会话里。`, `“${ref}” is not one of your sessions.`)}
        action={<Button asChild size="sm" variant="outline"><Link to="/">{tr("回到会话列表", "Back to the list")}</Link></Button>} />
    </div>
  );
  return <Workspace key={r.id} r={r} />;
}
