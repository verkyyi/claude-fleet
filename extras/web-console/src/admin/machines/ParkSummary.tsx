import * as React from "react";

export type ParkReading = {
  sessions_working?: number;
  sessions_idle?: number;
  sessions_parked?: number;
  idle_rss_mb?: number | null;
  parked_saved_mb?: number | null;
  idle_reasons?: Record<string, number>;
};

const reasons: Record<string, [string, string]> = {
  sampling: ["等待内存采样", "waiting for sample"],
  watched: ["有人在看着", "being viewed"],
  background: ["跑着后台命令", "background job"],
  "old-shell": ["老外壳", "older wrapper"],
  "idle-delay": ["等待停放", "waiting to park"],
  draft: ["有未发出的字", "unsent draft"],
  dialog: ["等你回答", "waiting for an answer"],
  failed: ["接回失败", "resume failed"],
};

export function ParkSummary({ reading: r, lang }: { reading: ParkReading; lang: "zh" | "en" }) {
  if (r.sessions_working == null || r.sessions_idle == null || r.sessions_parked == null) return null;
  const zh = lang === "zh";
  const total = r.sessions_working + r.sessions_idle + r.sessions_parked;
  const saved = r.parked_saved_mb == null ? (zh ? "节省量未采到" : "savings unavailable")
    : (zh ? `省 ${(r.parked_saved_mb / 1024).toFixed(1)} GB` : `${(r.parked_saved_mb / 1024).toFixed(1)} GB saved`);
  const why = Object.entries(r.idle_reasons || {}).filter(([, n]) => n > 0)
    .map(([k, n]) => `${reasons[k]?.[zh ? 0 : 1] || (zh ? "等待停放" : "waiting to park")} ${n}`).join(" · ");
  const rss = r.idle_rss_mb == null ? (zh ? "内存读不到" : "memory unavailable") : `${(r.idle_rss_mb / 1024).toFixed(1)} GB`;
  return (
    <div data-park-summary className="flex min-w-0 flex-col gap-x-4 gap-y-1 text-sm sm:flex-row sm:flex-wrap">
      <span>{zh ? `会话 ${total} 个 · 在算 ${r.sessions_working}` : `${total} sessions · ${r.sessions_working} working`}</span>
      {r.sessions_parked > 0 && <span>{zh ? `已停放 ${r.sessions_parked} · ${saved}` : `${r.sessions_parked} parked · ${saved}`}</span>}
      <span className={r.sessions_idle > 0 ? "text-warn" : "text-muted-foreground"}>
        {zh ? `空闲常驻 ${r.sessions_idle}` : `${r.sessions_idle} idle in memory`}
        {r.sessions_idle > 0 && ` · ${rss} · ${why || (zh ? "原因未报" : "reason unavailable")}`}
      </span>
    </div>
  );
}
