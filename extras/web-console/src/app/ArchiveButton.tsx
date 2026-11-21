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
import { archiveTreePlan } from "./archive";
import { stopRow } from "./task-stop-api";
import type { Row } from "./work";

// Archive = stop + hide (task DDBQ). Still doing something ⇒ ask first; idle ⇒
// just goes. Unarchive only shows it again. The sessions it opened go with it:
// stopped the same way, written in one call (every one or none).
export function ArchiveButton({ row }: { row: Row }) {
  const { rows, reload, archiveLocal } = useWorkRows();
  const { me } = useMe();
  const [busy, setBusy] = useState(false);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState("");
  if (!row.board) return null;
  const archived = !!row.board.archived;
  const label = archived ? tr("取消归档", "Unarchive") : tr("归档", "Archive");
  const Icon = archived ? ArchiveRestore : Archive;
  const plan = archiveTreePlan(rows ?? [row], row);
  const family = plan.ids.length - 1;
  const run = async () => {
    setBusy(true); setError("");
    try {
      for (const r of plan.stop) {
        const stopped = await stopRow(r);
        if (!stopped.ok) { setError(tr(`没能停止「${r.title}」，未归档：${stopped.error}`, `Could not stop "${r.title}"; not archived: ${stopped.error}`)); return; }
      }
      const body = family ? { ids: plan.ids, archived: !archived } : { id: row.board!.id, archived: !archived };
      const res = await sendJSON("POST", "/v1/fleet/session_archive", body);
      if (res.ok) { for (const id of plan.ids) archiveLocal(id, !archived); reload(); } else setError(res.error);
    } catch { setError(tr("未能保存归档，请重试", "Could not save archive; retry")); }
    finally { setBusy(false); }
  };
  return <span className="flex shrink-0 flex-col items-end">
    <Button variant="ghost" size="icon" aria-label={label} title={archived ? (family ? tr(`取消归档（连同它开的 ${family} 个会话）`, `Unarchive (with the ${family} it opened)`) : label)
      : family ? tr(`归档：停止并隐藏这个会话和它开的 ${family} 个会话`, `Archive: stop and hide this session and the ${family} it opened`)
      : tr("归档：停止会话并从列表隐藏", "Archive: stop the session and hide it")}
      disabled={busy || !me || !!me.read_only || !!me.view_as || !!viewAs}
      onClick={() => plan.confirm.length ? setAsking(true) : void run()}><Icon className="size-4" /></Button>
    {error ? <span role="alert" className="text-destructive max-w-48 text-xs">{error}</span> : null}
    <AlertDialog open={asking} onOpenChange={setAsking}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{plan.confirm.length > 1 || plan.confirm[0] !== row
            ? tr(`${plan.confirm.length} 个会话还在运行，归档并停止？`, `${plan.confirm.length} sessions still running — stop and archive?`)
            : tr("会话还在运行，归档并停止？", "Still running — stop and archive?")}</AlertDialogTitle>
          <AlertDialogDescription>
            {family
              ? tr(`归档会停止并隐藏这个会话和它开的 ${family} 个会话。之后可以取消归档、再继续。`,
                `Archiving stops and hides this session and the ${family} it opened. You can unarchive and continue later.`)
              : tr("归档会停止这个会话，再从列表里隐藏。之后可以取消归档、再继续它。",
                "Archiving stops this session, then hides it. You can unarchive and continue it later.")}
          </AlertDialogDescription>
          {plan.confirm.length > 1 || plan.confirm[0] !== row
            ? <ul className="text-muted-foreground list-disc pl-5 text-sm">{plan.confirm.map((r) => <li key={r.id}>{r.title}</li>)}</ul>
            : null}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{tr("取消", "Cancel")}</AlertDialogCancel>
          <AlertDialogAction onClick={() => void run()}>{tr("停止并归档", "Stop and archive")}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </span>;
}
