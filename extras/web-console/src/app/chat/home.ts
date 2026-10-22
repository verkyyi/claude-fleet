// home.ts — where the conversation runs (issue #3646): /v1/chat/home, the
// entry's own answer, no relay; and when a window frees up, in the reader's time.
import { useEffect, useState } from "react";
import { getJSON } from "@/shared/api";
import { lang, tr } from "@/shared/i18n";

export type Home = { machine: string; login: string; state: "ok" | "offline" | "maintenance" | "old_agent" };
export function useHome(key: unknown) {
  const [h, setH] = useState<Home | null>(null);
  useEffect(() => { getJSON<Home>("/v1/chat/home").then((j) => setH(j && j.machine ? j : null)); }, [key]);
  return h;
}

// "周一 08:00", "今天 08:00", "明天 08:00" — when a window frees up, in the reader's own time.
export function whenLocal(iso: string | undefined, now = new Date()): string {
  const t = iso ? new Date(iso) : null;
  if (!t || Number.isNaN(t.getTime())) return "";
  const hm = `${String(t.getHours()).padStart(2, "0")}:${String(t.getMinutes()).padStart(2, "0")}`;
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(t) - day(now)) / 86400000);
  if (days === 0) return tr(`今天 ${hm}`, `today ${hm}`);
  if (days === 1) return tr(`明天 ${hm}`, `tomorrow ${hm}`);
  if (days > 1 && days < 7) return lang === "zh" ? `周${"日一二三四五六"[t.getDay()]} ${hm}` : `${t.toLocaleDateString("en", { weekday: "short" })} ${hm}`;
  return lang === "zh" ? `${t.getMonth() + 1}月${t.getDate()}日 ${hm}` : `${t.toLocaleDateString("en", { month: "short", day: "numeric" })} ${hm}`;
}

// 会话合一 (Y01K): the entry says on /v1/chat/home whether its new road is on
// (`unified`, the hub setting fleet.chat.unified): a chat is then a session of
// the one list and the web talks to any session by /v1/chat/say. Off, or an
// older entry that says nothing, the page keeps the old road — the one
// conversation at /chat, a terminal session followed read-only. Read once per page.
let homeRead: Promise<(Home & { unified?: boolean }) | null> | null = null;
export const chatHome = () => (homeRead ??= getJSON<Home & { unified?: boolean }>("/v1/chat/home").catch(() => null)
  .then((j) => { if (!j) homeRead = null; return j || null; }));   // a failed read is asked again next time
export function useUnified(): boolean | null {
  const [on, setOn] = useState<boolean | null>(null);
  useEffect(() => { let live = true; void chatHome().then((h) => { if (live) setOn(h?.unified === true); }); return () => { live = false; }; }, []);
  return on;
}
