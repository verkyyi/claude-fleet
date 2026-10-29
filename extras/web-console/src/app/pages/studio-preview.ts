import { useCallback, useEffect, useRef, useState } from "react";

export type PreviewVersion = { version_id: string; embed?: string; embed_exp?: string; renewable?: boolean; preview_error?: string };
type Target = { fid: string; proposal_id?: string };
type Request = <T>(path: string, body?: unknown) => Promise<T>;

// No model turn for renewable previews. Existing short links get one coalesced
// bootstrap request through the native Agent; writes never use this controller.
export function useStudioPreview(target: Target | undefined, version: PreviewVersion | undefined, request: Request, refresh: () => Promise<void>) {
  const [message, setMessage] = useState("");
  const [now, setNow] = useState(Date.now());
  const current = useRef({ target, version, request, refresh });
  current.current = { target, version, request, refresh };
  const attempts = useRef(new Map<string, number>());
  const running = useRef(false);
  const renew = useCallback(async (force = false) => {
    const { target: t, version: v, request: req, refresh: read } = current.current;
    if (!t?.proposal_id || !v || running.current || document.visibilityState !== "visible" || !navigator.onLine) return;
    const id = `${t.fid}:${v.version_id}`;
    if (!force && ((attempts.current.get(id) || 0) > Date.now() || Date.parse(v.embed_exp || "") > Date.now() + 5 * 60_000)) return;
    running.current = true;
    attempts.current.set(id, Date.now() + 30_000);
    setMessage("正在恢复预览…");
    try {
      const a = { fid: t.fid, proposal_id: t.proposal_id, version_id: v.version_id };
      const result = await req<{ state: string; error?: string }>("/preview", a);
      // Do not update another project's UI after the response arrives late.
      if (current.current.target?.fid !== t.fid || current.current.version?.version_id !== v.version_id) return;
      if (result.state === "ready") { await read(); setMessage(""); }
      else if (result.state === "authorization_required") {
        attempts.current.set(id, Date.now() + 10 * 60_000);
        await req("/action", { ...a, id: crypto.randomUUID(), action: "preview", confirmed: false });
        await read();
        setMessage("正在请 Agent 恢复预览授权；会话停止时，请先接回会话。");
      } else { setMessage("预览暂时连不上，正在自动重试。"); }
    } catch { setMessage("暂时连不上家机器，连接恢复后会自动重试。"); }
    finally { running.current = false; setNow(Date.now()); }
  }, []);
  useEffect(() => {
    setMessage("");
    const tick = () => { setNow(Date.now()); void renew(); };
    tick();
    const timer = setInterval(tick, 15_000);
    window.addEventListener("online", tick);
    window.addEventListener("focus", tick);
    document.addEventListener("visibilitychange", tick);
    return () => { clearInterval(timer); window.removeEventListener("online", tick); window.removeEventListener("focus", tick); document.removeEventListener("visibilitychange", tick); };
  }, [target?.fid, version?.version_id, version?.embed_exp, renew]);
  return { message, renew, expired: !(Date.parse(version?.embed_exp || "") > now) };
}
