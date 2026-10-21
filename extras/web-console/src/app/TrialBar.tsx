// TrialBar.tsx — a trial member's own limits, always in sight (claude-fleet
// T796): one line over every page, phone and computer alike — 「试用 · 剩 6 天 ·
// 已用 12 万 / 150 万 tokens · 同时 1 个会话」. A day or less left, or 80 % of the
// tokens used, turns it clay; ended or used up, red, saying why. From 将到期 on
// it offers 申请转正 (POST /v1/me/trial/upgrade), which marks the person's row
// in the admin's 成员 list; asked, it says so. Off /v1/me/usage's `trial`;
// nothing when the person is on no trial.
import { useState, type FC } from "react";
import { Link } from "react-router";
import { toast } from "sonner";
import { Hourglass } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { fmtTokens, fmtWhen, tr } from "@/shared/i18n";
import { sendJSON, type Trial } from "@/shared/api";
import { viewAs } from "@/shared/viewAs";

const days = (n: number) => (n <= 0 ? tr("今天到期", "ends today") : tr(`剩 ${n} 天`, n === 1 ? "1 day left" : `${n} days left`));

// The line's parts, in order; the person reads them left to right.
export function trialParts(t: Trial): string[] {
  const p: string[] = [];
  if (t.state === "expired") p.push(tr(`已于 ${fmtWhen(t.until)} 结束`, `ended ${fmtWhen(t.until)}`));
  else if (t.days_left != null) p.push(days(t.days_left));
  if (t.tokens) p.push(tr(`已用 ${fmtTokens(t.used_tokens)} / ${fmtTokens(t.tokens)} tokens`, `${fmtTokens(t.used_tokens)} / ${fmtTokens(t.tokens)} tokens used`));
  else if (t.usd) p.push(tr(`已用 $${(t.spent_usd || 0).toFixed(2)} / $${t.usd}`, `$${(t.spent_usd || 0).toFixed(2)} / $${t.usd} used`));
  if (t.sessions) p.push(tr(`同时 ${t.sessions} 个会话`, t.sessions === 1 ? "1 session at a time" : `${t.sessions} sessions at a time`));
  return p;
}

// What the person may do about it, said when it binds.
function trialWhy(t: Trial): string {
  if (t.state === "expired") return tr("新的请求会被拒，申请转正后继续使用。", "New requests are refused — ask to become a member to carry on.");
  if (t.state === "spent") return tr("试用额度已用完，新的请求会被拒，申请转正后继续使用。", "Your trial tokens are used up — new requests are refused until you become a member.");
  return "";
}

export const TrialBar: FC<{ trial: Trial | null; onAsked: (t: Trial) => void }> = ({ trial, onAsked }) => {
  const [busy, setBusy] = useState(false);
  if (!trial) return null;
  const over = trial.state === "expired" || trial.state === "spent";
  const soon = trial.state === "soon";
  const ask = async () => {
    setBusy(true);
    const r = await sendJSON<{ upgrade_asked: string }>("POST", "/v1/me/trial/upgrade", {});
    setBusy(false);
    if (r.ok) {
      onAsked({ ...trial, upgrade_asked: r.data.upgrade_asked });
      toast.success(tr("已提交转正申请，管理员会尽快处理", "Asked — an admin will take it from here"));
    } else toast.error(r.error || tr("没提交上，稍后再试", "Could not send it — try again later"));
  };
  return (
    <div role="status" data-trial={trial.state}
      className={cn("flex flex-none flex-wrap items-center gap-x-2.5 gap-y-1 border-b px-4 py-1.5 text-xs",
        over ? "border-destructive/30 bg-destructive/10 text-destructive" : soon ? "border-clay-line bg-clay-soft text-clay" : "border-border/70 bg-muted/40 text-muted-foreground")}>
      <Hourglass className="size-3.5 shrink-0" aria-hidden />
      <span className="min-w-0 flex-1">
        <b className="font-semibold">{tr("试用", "Trial")}</b>
        {trialParts(trial).map((p) => <span key={p}> · {p}</span>)}
        {over ? <span className="block sm:inline"> <span className="hidden sm:inline">— </span>{trialWhy(trial)}</span> : null}
      </span>
      {trial.upgrade_asked ? (
        <span className="shrink-0 opacity-90">{tr("已申请转正", "Asked to become a member")}</span>
      ) : over || soon ? (
        <Button size="sm" variant={over ? "destructive" : "outline"} className="h-6 shrink-0 rounded-full px-2.5 text-[11px]"
          disabled={busy || !!viewAs} onClick={ask}>
          {tr("申请转正", "Ask to become a member")}
        </Button>
      ) : (
        <Link to="/usage" className="shrink-0 underline-offset-2 hover:underline">{tr("用量", "Usage")}</Link>
      )}
    </div>
  );
};
