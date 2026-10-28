import { useState } from "react";
import { Archive, ArchiveRestore } from "lucide-react";
import { Button } from "@/components/ui/button";
import { sendJSON, useMe } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";
import { tr } from "@/shared/i18n";
import { useWorkRows } from "./work-rows";
import type { Row } from "./work";

export function ArchiveButton({ row }: { row: Row }) {
  const { reload } = useWorkRows();
  const { me } = useMe();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  if (!row.board) return null;
  const archived = !!row.board.archived;
  const label = archived ? tr("取消归档", "Unarchive") : tr("归档", "Archive");
  const Icon = archived ? ArchiveRestore : Archive;
  return <span className="flex shrink-0 flex-col items-end">
    <Button variant="ghost" size="icon" aria-label={label} title={archived ? label : tr("归档：隐藏列表，会话继续运行", "Archive: hide from lists, keep running")}
      disabled={busy || !me || !!me.read_only || !!me.view_as || !!viewAs}
      onClick={async () => {
        setBusy(true); setError("");
        try {
          const res = await sendJSON("POST", "/v1/fleet/session_archive", { id: row.board!.id, archived: !archived });
          if (res.ok) reload(); else setError(res.error);
        } catch { setError(tr("未能保存归档，请重试", "Could not save archive; retry")); }
        finally { setBusy(false); }
      }}><Icon className="size-4" /></Button>
    {error ? <span role="alert" className="text-destructive max-w-48 text-xs">{error}</span> : null}
  </span>;
}
