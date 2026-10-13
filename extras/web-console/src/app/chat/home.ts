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
