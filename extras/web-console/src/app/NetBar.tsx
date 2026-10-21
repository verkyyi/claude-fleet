// NetBar.tsx — the shell's band when the network is not there (GR5E C8):
//「网络不太好，正在重连… 下面是 N 分钟前的样子」, under the bars, on every
// screen. While it shows it asks the entry again every few seconds (and at
// once when the browser says online); the first answer takes it down and says
// so in one line. The state is shared/net.ts — every read reports there.
import { useEffect, useState, type FC } from "react";
import { WifiOff } from "lucide-react";
import { toast } from "sonner";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { minutesAgo, netMiss, netOk, netState, netSubscribe, type Net } from "@/shared/net";

const ASK_MS = 5000;

export const netWords = (n: number) => n < 1
  ? tr("网络不太好，正在重连… 下面是刚才的样子", "The network is weak — reconnecting… below is how it looked a moment ago")
  : tr(`网络不太好，正在重连… 下面是 ${n} 分钟前的样子`, `The network is weak — reconnecting… below is how it looked ${n} min ago`);

async function ask() {
  const r = await fetch("/v1/me", { headers: { Accept: "application/json" }, cache: "no-store" }).catch(() => null);
  if (r) netOk(); else netMiss();
}

// top: nothing sits above it on this screen (a whole screen's own head is
// below it), so it clears the notch itself.
export const NetBar: FC<{ top?: boolean }> = ({ top }) => {
  const [net, setNet] = useState<Net>(netState);
  const [, tick] = useState(0);
  useEffect(() => netSubscribe((n) => {
    setNet((was) => { if (was.bad && !n.bad) toast(tr("网络接上了", "Back online")); return n; });
  }), []);
  useEffect(() => {
    if (!net.bad) return;
    const t = window.setInterval(() => { ask(); tick((x) => x + 1); }, ASK_MS);
    window.addEventListener("online", ask);
    return () => { clearInterval(t); window.removeEventListener("online", ask); };
  }, [net.bad]);
  if (!net.bad) return null;
  return (
    <div role="status" aria-live="polite" data-net-bar
      className={cn("border-clay-line bg-clay/10 text-clay flex flex-none items-center gap-2 border-b px-4 pb-1.5 text-[13px]",
        top ? "pt-[calc(env(safe-area-inset-top)+0.375rem)] md:pt-1.5" : "pt-1.5")}>
      <WifiOff className="size-4 shrink-0" aria-hidden />
      <span className="min-w-0 flex-1 truncate">{netWords(minutesAgo(net.lastOk))}</span>
    </div>
  );
};
