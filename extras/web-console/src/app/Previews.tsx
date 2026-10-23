import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { getJSON } from "@/shared/api";
import { tr } from "@/shared/i18n";

type Preview = { id: string; socket: string; url: string; online: boolean; expires: number };
type Read = { enabled: boolean; previews: Preview[] };

export function Previews({ task }: { task: string }) {
  const [read, setRead] = useState<Read | null>(null);
  const [error, setError] = useState(false);
  const [busy, setBusy] = useState("");
  const url = `/v1/fleet/previews?task=${encodeURIComponent(task)}`;
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => { void getJSON<Read>(url, controller.signal).then((r) => {
      if (!controller.signal.aborted) { setRead(r); setError(!r); }
    }); };
    refresh();
    const timer = setInterval(refresh, 5000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [url]);
  async function action(id: string, action: string) {
    setBusy(id);
    const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id, action }) }).catch(() => null);
    setError(!response?.ok);
    if (response?.ok) setRead(await getJSON<Read>(url));
    setBusy("");
  }
  return <section className="space-y-2" aria-label={tr("实时预览", "Live previews")} data-testid="task-previews">
    <h3 className="font-medium">{tr("实时预览 · 仅自己可见", "Live previews · Only you")}</h3>
    <p className="text-muted-foreground text-xs">{tr("访问这个任务正在运行的应用。保存的 HTML / Markdown 成果仍在 Space / 活页。", "Open this task’s running application. Saved HTML / Markdown remains in Space / LivePage.")}</p>
    {error ? <p role="alert">{tr("暂时无法读取预览，请稍后重试。", "Previews are unavailable. Please retry shortly.")}</p> : !read ? <p>{tr("正在读取…", "Loading…")}</p> : !read.enabled ? <p>{tr("私人实时预览尚未启用。", "Private live previews are not enabled yet.")}</p> : !read.previews.length ? <p>{tr("这个任务还没有实时预览。", "This task has no live previews yet.")}</p> : read.previews.map((p) => <div key={p.id} className="flex flex-wrap items-center gap-2 rounded-lg border p-3">
      <span className="min-w-0 flex-1 break-all">{p.socket} · {p.online ? tr("在线", "Online") : tr("离线", "Offline")}</span>
      <span className="text-muted-foreground text-xs">{tr("到期", "Expires")} {new Date(p.expires * 1000).toLocaleTimeString()}</span>
      {p.online ? <Button asChild size="sm"><a href={p.url} target="_blank" rel="noopener noreferrer">{tr("打开预览", "Open preview")}</a></Button> : null}
      <Button size="sm" variant="outline" disabled={busy === p.id} onClick={() => void action(p.id, "renew")}>{tr("续期", "Renew")}</Button>
      <Button size="sm" variant="outline" disabled={busy === p.id} onClick={() => void action(p.id, "close")}>{tr("关闭", "Close")}</Button>
    </div>)}
  </section>;
}
