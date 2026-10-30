import { useState } from "react";
import { Archive, ArchiveRestore } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { sendJSON, useMe } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";
import { tr } from "@/shared/i18n";
import { useWorkRows } from "./work-rows";
import { archivePlan } from "./archive";
import { stopRow } from "./task-stop-api";
import type { Row } from "./work";

// Archive = stop + hide (task DDBQ). Still doing something ⇒ ask first; idle ⇒
// just goes. Unarchive only shows it again.
export function ArchiveButton({ row }: { row: Row }) {
  const { reload } = useWorkRows();
  const { me } = useMe();
  const [busy, setBusy] = useState(false);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState("");
  if (!row.board) return null;
  const archived = !!row.board.archived;
  const label = archived ? tr("取消归档", "Unarchive") : tr("归档", "Archive");
  const Icon = archived ? ArchiveRestore : Archive;
  const plan = archivePlan(row);
  const run = async () => {
    setBusy(true); setError("");
    try {
      if (plan.stop) {
        const stopped = await stopRow(row);
        if (!stopped.ok) { setError(tr(`没能停止，未归档：${stopped.error}`, `Could not stop; not archived: ${stopped.error}`)); return; }
      }
      const res = await sendJSON("POST", "/v1/fleet/session_archive", { id: row.board!.id, archived: !archived });
      if (res.ok) reload(); else setError(res.error);
    } catch { setError(tr("未能保存归档，请重试", "Could not save archive; retry")); }
    finally { setBusy(false); }
  };
  return <span className="flex shrink-0 flex-col items-end">
    <Button variant="ghost" size="icon" aria-label={label} title={archived ? label : tr("归档：停止会话并从列表隐藏", "Archive: stop the session and hide it")}
      disabled={busy || !me || !!me.read_only || !!me.view_as || !!viewAs}
      onClick={() => plan.confirm ? setAsking(true) : void run()}><Icon className="size-4" /></Button>
    {error ? <span role="alert" className="text-destructive max-w-48 text-xs">{error}</span> : null}
    <AlertDialog open={asking} onOpenChange={setAsking}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{tr("会话还在运行，归档并停止？", "Still running — stop and archive?")}</AlertDialogTitle>
          <AlertDialogDescription>
            {tr("归档会停止这个会话，再从列表里隐藏。之后可以取消归档、再继续它。",
              "Archiving stops this session, then hides it. You can unarchive and continue it later.")}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{tr("取消", "Cancel")}</AlertDialogCancel>
          <AlertDialogAction onClick={() => void run()}>{tr("停止并归档", "Stop and archive")}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </span>;
}
