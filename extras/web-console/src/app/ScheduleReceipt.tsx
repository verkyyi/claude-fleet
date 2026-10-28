import { Link } from "react-router";
import { Button } from "@/components/ui/button";
import { tr } from "@/shared/i18n";
import type { ScheduleReceipt as Receipt } from "@/shared/schedule-receipt";
import { scheduleDate, schedulePath } from "./schedules";

export function ScheduleReceipt({ receipt: r }: { receipt: Receipt }) {
  return <section aria-label={tr("定时任务创建回执", "Schedule creation receipt")} className="my-3 space-y-3 rounded-xl border border-clay/35 bg-card p-4 text-sm">
    <h3 className="font-semibold">⏰ {tr("已创建", "Created")}「{r.name}」</h3>
    {!r.synced && <p role="status" className="text-xs text-muted-foreground">{tr("已保存，等待运行环境确认登记。", "Saved; waiting for the runtime to confirm registration.")}</p>}
    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
      <dt className="text-muted-foreground">{tr("周期", "Repeat")}</dt><dd>{r.cron || `${tr("每天", "Daily")} ${r.at}`} · {r.timezone === "Asia/Shanghai" ? tr("北京时间", "Beijing time") : r.timezone}</dd>
      <dt className="text-muted-foreground">{tr("首次", "First run")}</dt><dd>{r.next ? scheduleDate(r.next, r.timezone) : tr("登记后在任务详情查看", "Available in details after registration")}</dd>
      <dt className="text-muted-foreground">Agent</dt><dd>{r.agent === "claude" ? "Claude" : r.agent === "codex" ? "Codex" : tr("跟随 fleet 默认", "Fleet default")}</dd>
      <dt className="text-muted-foreground">{tr("结果", "Delivery")}</dt><dd>{tr("站内通知", "In-app notice")}{r.delivery.wechat && tr(" · 本人微信", " · My WeChat")}{r.delivery.livepage && tr(" · 私密活页", " · Private live page")}</dd>
    </dl>
    <div className="flex gap-2"><Button asChild size="sm" variant="outline"><Link to={schedulePath(r.id)}>{tr("在列表中查看", "View in list")}</Link></Button><Button asChild size="sm" variant="outline"><Link to={`${schedulePath(r.id)}&edit=1`}>{tr("改时间", "Change time")}</Link></Button></div>
  </section>;
}
