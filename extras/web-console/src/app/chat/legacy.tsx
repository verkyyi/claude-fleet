import { useEffect, useRef, useState } from "react";
import { meOnce } from "@/shared/api";
import { tr } from "@/shared/i18n";
import { viewAs } from "@/shared/viewAs";
import { useWorkRows } from "../work-rows";
import { useUnified } from "./home";
import { legacyReader, type Migration } from "./legacy-request";

export const migrateLegacy = legacyReader(meOnce, (...args) => fetch(...args), !!viewAs);

// One migration on the person's own page. Tickets and view-as never write.
// Failures stay visible and retryable; the new session entry remains available.
export function LegacyMigrationNotice() {
  const unified = useUnified();
  const { reload } = useWorkRows();
  const refresh = useRef(reload);
  refresh.current = reload;
  const [result, setResult] = useState<Migration | null>(null);
  const [attempt, retry] = useState(0);
  useEffect(() => {
    if (!unified) return;
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    void migrateLegacy().then((r) => {
      if (!alive) return;
      setResult(r);
      if (r.ok && !r.readOnly) refresh.current();
      if (!r.ok && r.why === "busy") timer = setTimeout(() => retry((n) => n + 1), 5000);
    });
    return () => { alive = false; clearTimeout(timer); };
  }, [unified, attempt]);
  if (!unified || !result || result.ok || result.readOnly) return null;
  return <div role="status" className="border-border border-b px-4 py-2 text-sm">
    {result.why === "busy" ? tr("以前的对话还在回复，答完后会加入会话列表。", "Your previous chat is replying; it will join the list when it finishes.")
      : <>{tr("以前的对话暂时无法加入列表。", "Your previous chats could not join the list yet.")}{" "}
        <button type="button" className="underline" onClick={() => retry((n) => n + 1)}>{tr("重试", "Retry")}</button></>}
  </div>;
}
