// WeChatBind.tsx — a person on the list binds the service account's WeChat
// (claude-fleet#4057, EPIC #4048 C9): the home's band until they have, and the
// dialog that draws a bind code (POST /v1/me/wechat/bind-qr) and polls it
// (GET /v1/me/wechat/bind-poll) until they scanned — the same two-second
// polling as the sign-in page. Settings opens the same dialog. Stock
// shadcn/ui Alert + Dialog + sonner only.
import { useEffect, useRef, useState, type FC } from "react";
import { CircleAlert, CircleCheck, MessageCircle, RotateCcw } from "lucide-react";
import { toast } from "sonner";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { getJSON, sendJSON } from "@/shared/api";
import { tr } from "@/shared/i18n";

// the dialog's states: drawing, waiting for the scan, and how it ended
type Phase = "draw" | "wait" | "expired" | "down" | "taken";

// the WeChat mark on the code's middle, as the sign-in page draws it
const Mark: FC = () => (
  <span className="absolute inset-0 grid place-items-center">
    <b className="grid size-10 place-items-center rounded-[10px] border-[3px] border-white bg-[#07c160]">
      <MessageCircle className="size-5 text-white" aria-hidden />
    </b>
  </span>
);

export const BindWeChatDialog: FC<{ open: boolean; onClose: () => void; onBound: () => void }> = ({ open, onClose, onBound }) => {
  const [phase, setPhase] = useState<Phase>("draw");
  const [code, setCode] = useState<{ s: number; qr: string } | null>(null);
  const [downs, setDowns] = useState(0);
  const [tick, setTick] = useState(0);
  const gen = useRef(0);

  const draw = async () => {
    const my = ++gen.current;
    setPhase("draw"); setCode(null); setDowns(0);
    const r = await sendJSON<{ s: number; qr: string }>("POST", "/v1/me/wechat/bind-qr");
    if (my !== gen.current) return;
    if (!r.ok) { setPhase("down"); return; }
    setCode(r.data); setPhase("wait");
  };
  useEffect(() => {
    if (open) void draw();
    else gen.current++;
  }, [open]);

  // ask about the code every two seconds while it waits
  useEffect(() => {
    if (!open || phase !== "wait" || !code) return;
    const my = gen.current;
    const t = setTimeout(async () => {
      const j = await getJSON<{ s: string }>(`/v1/me/wechat/bind-poll?s=${code.s}`);
      if (my !== gen.current) return;
      const s = j?.s || "down";
      if (s === "bound") { gen.current++; onBound(); return; }
      if (s === "expired" || s === "taken") { setPhase(s); return; }
      setDowns((n) => (s === "down" ? n + 1 : 0));
      setTick((n) => n + 1);
    }, 2000);
    return () => clearTimeout(t);
  }, [open, phase, code, tick]);

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-[22rem] text-center sm:max-w-[22rem]">
        <DialogHeader className="items-center text-center sm:text-center">
          <DialogTitle className="font-display text-lg">{tr("用微信扫一扫", "Scan with WeChat")}</DialogTitle>
          <DialogDescription>
            {tr("关注「二四网络科技」就绑上了；已关注的直接扫。", "Follow 二四网络科技 and it's bound; already following? Just scan.")}
          </DialogDescription>
        </DialogHeader>
        <div className="relative mx-auto size-[180px] overflow-hidden rounded-[10px] border bg-white" data-testid="wx-bind-qr">
          {code ? (
            <>
              <span className="block size-full fill-black [&_svg]:size-full" dangerouslySetInnerHTML={{ __html: code.qr }} />
              <Mark />
            </>
          ) : null}
          {phase === "expired" || phase === "draw" && !code ? (
            <span className="bg-card/90 text-foreground absolute inset-0 flex flex-col items-center justify-center gap-2 text-sm font-medium">
              {phase === "expired" ? (
                <>
                  {tr("二维码已过期", "This code has expired")}
                  <Button size="sm" onClick={() => void draw()}><RotateCcw />{tr("换一个", "Get a new one")}</Button>
                </>
              ) : tr("正在生成…", "Drawing…")}
            </span>
          ) : null}
        </div>
        <p className="text-muted-foreground text-[13px] sm:hidden">
          {tr("在这台手机上：长按二维码存到相册，再在微信「扫一扫」里选「相册」。", "On this phone: long-press the code to save it, then in WeChat's Scan pick Album.")}
        </p>
        {phase === "taken" ? (
          <Alert variant="destructive" className="text-left">
            <CircleAlert />
            <AlertDescription>{tr("这个微信已经是别人的登录方式了，换一个微信再扫。", "That WeChat already signs someone else in — scan with another one.")}</AlertDescription>
          </Alert>
        ) : phase === "down" || downs >= 3 ? (
          <Alert variant="destructive" className="text-left">
            <CircleAlert />
            <AlertDescription>{tr("微信那边暂时没有回应，过一分钟再试。", "WeChat isn't answering right now — try again in a minute.")}</AlertDescription>
          </Alert>
        ) : null}
        <DialogFooter className="sm:justify-center">
          {phase === "taken" || phase === "down" ? <Button onClick={() => void draw()}><RotateCcw />{tr("再来一次", "Try again")}</Button> : null}
          <Button variant="outline" onClick={onClose}>{tr("取消", "Cancel")}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

// what the person sees once it bound
export function toastBound() {
  toast.success(tr("微信已绑定", "WeChat bound"), {
    description: tr("以后通知发到微信，也可以扫码登录。", "Notices now go to your WeChat, and you can sign in by scanning."),
    icon: <CircleCheck className="size-4" />,
  });
}

// the band stays away 30 days once closed
const LATER_KEY = "fleet.wxbind.later";
const LATER_MS = 30 * 864e5;
const laterNow = () => {
  try { return Date.now() - Number(localStorage.getItem(LATER_KEY) || 0) < LATER_MS; } catch { return false; }
};

// BindWeChatBanner: the home's band for a person the notices cannot find yet.
export const BindWeChatBanner: FC<{ unbound: boolean }> = ({ unbound }) => {
  const [hidden, setHidden] = useState(laterNow);
  const [open, setOpen] = useState(false);
  if (!unbound || hidden) return null;
  const later = () => {
    try { localStorage.setItem(LATER_KEY, String(Date.now())); } catch { /* private mode: this visit only */ }
    setHidden(true);
  };
  return (
    <div className="px-4 pt-3">
      <Alert className="border-clay-line bg-clay-soft mx-auto max-w-3xl" role="status" data-testid="wx-bind-banner">
        <MessageCircle className="text-[#07c160]" />
        <AlertTitle className="line-clamp-none">{tr("绑定微信，通知发到微信", "Bind WeChat to get notices there")}</AlertTitle>
        <AlertDescription>
          <p>{tr("申请结果、服务变动会发到「二四网络科技」公众号；以后也能扫码登录。",
            "Application results and service changes go to the 二四网络科技 account; you can also sign in by scanning.")}</p>
          <div className="mt-1.5 flex gap-2">
            <Button size="sm" className="rounded-full" onClick={() => setOpen(true)}>{tr("绑定微信", "Bind WeChat")}</Button>
            <Button size="sm" variant="ghost" className="rounded-full" onClick={later}>{tr("以后再说", "Later")}</Button>
          </div>
        </AlertDescription>
      </Alert>
      <BindWeChatDialog open={open} onClose={() => setOpen(false)}
        onBound={() => { setOpen(false); setHidden(true); toastBound(); }} />
    </div>
  );
};
