// subs.tsx — 我自己的订阅 (EPIC #3923 C21, issue #4035): a member connects a
// Claude or ChatGPT subscription of their OWN, signed in in their own browser
// (the account's password never passes through us), and it is theirs alone —
// the vault holds it under their principal, so no one else's session can lease
// it. Then they see its two windows (5 hours · week), pause / resume it, and
// disconnect it (typing its name). Only the person's own reads and writes,
// /v1/me/subscriptions*; the steps are C12's 接一个订阅 (admin side,
// AddSubscriptionDialog) with the node command replaced by the browser sign-in —
// a twin here, since no admin code rides in the member bundle.
// Stock shadcn/ui only: Card, Progress, Dialog, AlertDialog, RadioGroup, Badge.
import { useEffect, useId, useState, type FC, type FormEvent } from "react";
import { useSearchParams } from "react-router";
import { Check, CircleAlert, CircleCheck, ExternalLink, KeyRound, Loader2, Pause, Play, Plus, RotateCw, Unplug } from "lucide-react";
import { toast } from "sonner";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Progress } from "@/components/ui/progress";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { fmtWhen, tr } from "@/shared/i18n";
import { sendJSON, useLoad } from "@/shared/api";

export type Prov = "claude" | "codex";
type Win = { used_pct?: number | null; resets_at?: string };
// GET /v1/me/subscriptions' rows (me_subs.go): the person's own vault rows only
export type MySub = {
  provider: Prov; account: string; account_uuid?: string; plan?: string;
  state: "ok" | "near" | "limited" | "paused" | "reauth" | "unread";
  paused?: boolean; five_hour?: Win; seven_day?: Win; observed_at?: string; created_at?: string; sessions?: number;
};
type Login = { flow: string; authorize_url: string; paste: "code" | "url"; expires_at?: string };

const LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/;
const provName = (p: Prov) => (p === "codex" ? "ChatGPT" : "Claude");
const NEAR = 80;

// ── one window's bar: how much of it is used, and when it comes back ──
const WinLine: FC<{ name: string; w?: Win; paused: boolean }> = ({ name, w, paused }) => {
  const p = w?.used_pct == null ? null : Math.max(0, Math.min(100, Math.round(w.used_pct)));
  const tone = paused ? "[&>[data-slot=progress-indicator]]:bg-muted-foreground"
    : p != null && p >= 100 ? "[&>[data-slot=progress-indicator]]:bg-destructive"
      : p != null && p >= NEAR ? "[&>[data-slot=progress-indicator]]:bg-[var(--fleet-warn)]" : "";
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3 text-[13px]">
        <span className="text-muted-foreground">{name}</span>
        <span className="font-mono">{p == null ? "—" : tr(`用了 ${p}%`, `${p}% used`)}</span>
      </div>
      <Progress value={p ?? 0} className={cn("mt-1.5 h-2", tone)} aria-label={name} />
      <p className="text-muted-foreground mt-1 text-[12px]">
        {w?.resets_at ? (p != null && p >= 100 ? tr(`${fmtWhen(w.resets_at)} 恢复`, `Back ${fmtWhen(w.resets_at)}`) : tr(`${fmtWhen(w.resets_at)} 重置`, `Resets ${fmtWhen(w.resets_at)}`))
          : p == null ? tr("还没读到", "Not read yet") : tr("没用，不计时", "Unused — no clock running")}
      </p>
    </div>
  );
};

const STATE: Record<MySub["state"], [string, string, string]> = {
  ok: ["正常", "Active", ""],
  near: ["快满", "Nearly full", "border-[var(--fleet-warn)]/50 text-[var(--fleet-warn)]"],
  limited: ["暂时用尽", "Used up for now", "border-destructive/50 text-destructive"],
  paused: ["已暂停", "Paused", "text-muted-foreground"],
  reauth: ["要重新登录", "Sign in again", "border-destructive/50 text-destructive"],
  unread: ["还没读到用量", "No reading yet", "text-muted-foreground"],
};

// ── one subscription: name, state, two windows, pause / resume, disconnect ──
const SubRow: FC<{ s: MySub; onChange: () => void; onReconnect: (s: MySub) => void }> = ({ s, onChange, onReconnect }) => {
  const [busy, setBusy] = useState(false);
  const [cut, setCut] = useState(false);
  const [typed, setTyped] = useState("");
  const paused = !!s.paused || s.state === "paused";
  const [zh, en, cls] = STATE[paused ? "paused" : s.state] || STATE.ok;
  const pause = async () => {
    setBusy(true);
    const r = await sendJSON("POST", "/v1/me/subscriptions/pause", { provider: s.provider, account: s.account, paused: !paused });
    setBusy(false);
    if (!r.ok) return void toast.error(r.error || tr("没改成，再试一次", "Didn't change — try again"));
    toast.success(paused ? tr(`${s.account} 恢复了`, `${s.account} resumed`) : tr(`${s.account} 暂停了`, `${s.account} paused`));
    onChange();
  };
  const disconnect = async () => {
    setBusy(true);
    const r = await sendJSON("POST", "/v1/me/subscriptions/delete", { provider: s.provider, account: s.account });
    setBusy(false);
    if (!r.ok) return void toast.error(r.error || tr("没断开，再试一次", "Didn't disconnect — try again"));
    setCut(false);
    toast.success(tr(`${s.account} 断开了`, `${s.account} disconnected`));
    onChange();
  };
  return (
    <div className="py-4 first:pt-1 last:pb-1">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate font-mono text-[15px] font-medium">{s.account}</p>
          <p className="text-muted-foreground mt-0.5 text-[12.5px]">
            {[provName(s.provider), s.plan, s.sessions ? tr(`${s.sessions} 个会话在用`, `${s.sessions} session${s.sessions > 1 ? "s" : ""} on it`) : ""].filter(Boolean).join(" · ")}
          </p>
        </div>
        <Badge variant="outline" className={cn("shrink-0", cls)}>{tr(zh, en)}</Badge>
      </div>
      {s.state === "reauth" ? (
        <div className="border-destructive/40 bg-destructive/5 mt-3 flex items-start gap-2.5 rounded-lg border p-3 text-[13px]">
          <CircleAlert className="text-destructive mt-0.5 size-4 shrink-0" aria-hidden />
          <div className="min-w-0 flex-1">
            <p>{tr("这份订阅的登录失效了（改过密码、或在别处退出了），会话暂时用不上它。", "This subscription's sign-in expired (a password change, or signed out elsewhere); sessions can't use it for now.")}</p>
            <Button size="sm" className="mt-2" onClick={() => onReconnect(s)}><KeyRound />{tr("重新登录", "Sign in again")}</Button>
          </div>
        </div>
      ) : (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <WinLine name={tr("5 小时", "5 hours")} w={s.five_hour} paused={paused} />
          <WinLine name={tr("每周", "Week")} w={s.seven_day} paused={paused} />
        </div>
      )}
      {paused ? <p className="text-muted-foreground mt-3 text-[12.5px]">{tr("暂停中：你的会话不会用它，恢复后立即可用。", "Paused: your sessions won't use it; resume and it's back at once.")}</p> : null}
      <div className="mt-3 flex flex-wrap gap-2">
        {s.state === "reauth" ? null : (
          <Button size="sm" variant="outline" disabled={busy} onClick={pause}>
            {busy ? <Loader2 className="animate-spin" /> : paused ? <Play /> : <Pause />}{paused ? tr("恢复", "Resume") : tr("暂停", "Pause")}
          </Button>
        )}
        <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={busy} onClick={() => { setTyped(""); setCut(true); }}>
          <Unplug />{tr("断开", "Disconnect")}
        </Button>
      </div>
      <AlertDialog open={cut} onOpenChange={setCut}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{tr(`断开 ${s.account}？`, `Disconnect ${s.account}?`)}</AlertDialogTitle>
            <AlertDialogDescription>
              {tr("我们会删掉保存的登录凭据；正在用它的会话换回订阅池。订阅本身不受影响，想再用就重新接上。", "We delete the saved sign-in; sessions on it move back to the pool. The subscription itself is untouched — connect it again any time.")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <div className="grid gap-2">
            <Label htmlFor={`cut-${s.provider}-${s.account}`} className="font-normal">
              {tr("输入它的名字确认：", "Type its name to confirm:")}<span className="font-mono font-medium">{s.account}</span>
            </Label>
            <Input id={`cut-${s.provider}-${s.account}`} value={typed} onChange={(e) => setTyped(e.target.value)} className="font-mono" autoComplete="off" spellCheck={false} />
          </div>
          <AlertDialogFooter>
            <AlertDialogCancel>{tr("取消", "Cancel")}</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={typed.trim() !== s.account || busy}
              onClick={(e) => { e.preventDefault(); void disconnect(); }}>
              {busy ? <Loader2 className="animate-spin" /> : <Unplug />}{tr("断开", "Disconnect")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

// ── 接上我自己的订阅: 选服务 → 在你的浏览器登录 → 接上了 ──
const STEPS: [string, string][] = [["选服务", "Pick"], ["在你的浏览器登录", "Sign in"], ["接上了", "Connected"]];

export const ConnectDialog: FC<{
  open: boolean; onOpenChange: (o: boolean) => void; known: string[]; onConnected: () => void;
  preset?: { provider: Prov; account?: string };
}> = ({ open, onOpenChange, known, onConnected, preset }) => {
  const [step, setStep] = useState(0);
  const [prov, setProv] = useState<Prov>("claude");
  const [name, setName] = useState("");
  const [err, setErr] = useState("");
  const [login, setLogin] = useState<Login | null>(null);
  const [paste, setPaste] = useState("");
  const [busy, setBusy] = useState(false);
  const [opened, setOpened] = useState(false);
  const fid = useId();
  const again = !!preset?.account; // a reconnect: same name, straight to the sign-in

  const begin = async (p: Prov, n: string) => {
    setBusy(true); setErr("");
    const r = await sendJSON<Login>("POST", "/v1/me/subscriptions/login", { provider: p, account: n, again });
    setBusy(false);
    if (!r.ok) { setErr(r.error || tr("登录页没开出来，再试一次", "Couldn't start the sign-in — try again")); return false; }
    setLogin(r.data); setStep(1); return true;
  };
  useEffect(() => {
    if (!open) return;
    setStep(0); setErr(""); setLogin(null); setPaste(""); setOpened(false); setBusy(false);
    const p = preset?.provider || "claude";
    setProv(p);
    const n = preset?.account || suggest(p, known);
    setName(n);
    if (preset) void begin(p, n);
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps

  const next = (e: FormEvent) => {
    e.preventDefault();
    const n = name.trim();
    if (!LABEL_RE.test(n)) return setErr(tr("名字用字母、数字、点、横线，40 个字以内", "Letters, digits, dots and dashes, up to 40"));
    if (known.includes(`${prov}/${n}`)) return setErr(tr(`你已经有一份叫 ${n} 的订阅了`, `You already have one called ${n}`));
    setName(n);
    void begin(prov, n);
  };
  const finish = async (e: FormEvent) => {
    e.preventDefault();
    if (!login || !paste.trim()) return;
    setBusy(true); setErr("");
    const r = await sendJSON("POST", "/v1/me/subscriptions/login/finish", { flow: login.flow, paste: paste.trim() });
    setBusy(false);
    if (!r.ok) return setErr(r.error || tr("没接上：贴的内容不对，或者登录过期了。重新打开登录页再来一次。", "Didn't connect: what you pasted didn't work, or the sign-in expired. Open the sign-in page again."));
    setStep(2);
    onConnected();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{again ? tr(`重新登录 ${name}`, `Sign in to ${name} again`) : tr("接上我自己的订阅", "Connect my own subscription")}</DialogTitle>
          <DialogDescription asChild>
            <ol className="flex flex-wrap items-center gap-x-2 gap-y-1 pt-1">
              {STEPS.map(([zh, en], i) => (
                <li key={zh} className="flex items-center gap-2">
                  <span className={cn("flex size-5 items-center justify-center rounded-full border text-[11px] font-medium tabular-nums",
                    i < step && "border-ok/50 text-ok", i === step && "border-clay-line bg-clay-soft text-clay")}>
                    {i < step ? <Check className="size-3" /> : i + 1}
                  </span>
                  <span className={cn("text-xs", i === step ? "text-foreground" : "text-muted-foreground")}>{tr(zh, en)}</span>
                  {i < STEPS.length - 1 ? <span className="bg-border h-px w-4 sm:w-6" /> : null}
                </li>
              ))}
            </ol>
          </DialogDescription>
        </DialogHeader>

        {step === 0 && !preset ? (
          <form onSubmit={next} className="grid gap-4">
            <RadioGroup value={prov} onValueChange={(v) => { const p = v as Prov; setProv(p); setName((n) => (n === suggest(prov, known) ? suggest(p, known) : n)); }} className="grid grid-cols-2 gap-2">
              {(["claude", "codex"] as const).map((v) => (
                <Label key={v} className="has-[[data-state=checked]]:border-clay-line has-[[data-state=checked]]:bg-clay-soft flex cursor-pointer items-start gap-3 rounded-lg border p-3 font-normal">
                  <RadioGroupItem value={v} className="mt-0.5" />
                  <span className="grid gap-0.5">
                    <span className="font-medium">{provName(v)}</span>
                    <span className="text-muted-foreground text-xs">{v === "claude" ? "Pro · Max" : "Plus · Pro"}</span>
                  </span>
                </Label>
              ))}
            </RadioGroup>
            <div className="grid gap-2">
              <Label htmlFor={fid}>{tr("给它起个名字", "Name it")}</Label>
              <Input id={fid} value={name} onChange={(e) => setName(e.target.value)} className="font-mono" autoComplete="off" spellCheck={false} aria-invalid={!!err} />
              <p className={cn("text-xs", err ? "text-destructive" : "text-muted-foreground")}>{err || tr("只是你自己认得出的名字，比如 my-max。", "Just a name you'll recognise, like my-max.")}</p>
            </div>
            <p className="text-muted-foreground bg-muted/50 rounded-lg px-3 py-2.5 text-[12.5px]">
              {tr("接上以后只给你自己用：别人的会话用不到它。账号密码在你自己的浏览器里输入，不经过我们。", "Once connected it's yours alone — no one else's session can use it. You type the account's password in your own browser; it never passes through us.")}
            </p>
            <DialogFooter>
              <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>{tr("取消", "Cancel")}</Button>
              <Button type="submit" disabled={busy}>{busy ? <Loader2 className="animate-spin" /> : null}{tr("下一步", "Continue")}</Button>
            </DialogFooter>
          </form>
        ) : null}

        {step === 0 && preset ? (
          <div className="grid gap-3">
            {err ? <p className="text-destructive text-sm">{err}</p> : (
              <div className="text-muted-foreground flex items-center gap-2 py-6 text-sm"><Loader2 className="size-4 animate-spin" />{tr("正在打开登录页…", "Opening the sign-in…")}</div>
            )}
            <DialogFooter>
              <Button variant="ghost" onClick={() => onOpenChange(false)}>{tr("取消", "Cancel")}</Button>
              {err ? <Button onClick={() => void begin(prov, name)}><RotateCw />{tr("再试一次", "Try again")}</Button> : null}
            </DialogFooter>
          </div>
        ) : null}

        {step === 1 && login ? (
          <form onSubmit={finish} className="grid gap-4">
            <div className="grid gap-2">
              <p className="text-sm"><span className="text-muted-foreground me-1.5 font-mono text-xs">1</span>{tr(`在你的浏览器里登录 ${provName(prov)}，同意授权。`, `Sign in to ${provName(prov)} in your browser and approve.`)}</p>
              <Button asChild variant={opened ? "outline" : "default"} className="justify-self-start">
                <a href={login.authorize_url} target="_blank" rel="noreferrer noopener" onClick={() => setOpened(true)}>
                  <ExternalLink />{tr(`打开 ${provName(prov)} 登录页`, `Open the ${provName(prov)} sign-in`)}
                </a>
              </Button>
            </div>
            <div className="grid gap-2">
              <Label htmlFor={`${fid}-paste`} className="font-normal">
                <span className="text-muted-foreground me-1.5 font-mono text-xs">2</span>
                {login.paste === "url"
                  ? tr("登录后浏览器会跳到一个打不开的页面——把地址栏里整条地址贴到这里。", "After you sign in the browser lands on a page that won't load — paste that whole address from the address bar here.")
                  : tr("登录后页面上会给你一串代码——复制，贴到这里。", "After you sign in the page shows a code — copy it and paste it here.")}
              </Label>
              <Input id={`${fid}-paste`} value={paste} onChange={(e) => setPaste(e.target.value)} className="font-mono text-xs"
                placeholder={login.paste === "url" ? "http://localhost:1455/auth/callback?code=…" : tr("贴上代码", "Paste the code")}
                autoComplete="off" spellCheck={false} aria-invalid={!!err} />
              {err ? <p className="text-destructive text-xs">{err}</p> : (
                <p className="text-muted-foreground text-xs">{tr("这串只能用一次，十分钟内有效。", "It works once, within ten minutes.")}</p>
              )}
            </div>
            <DialogFooter>
              <Button type="button" variant="ghost" onClick={() => onOpenChange(false)}>{tr("取消", "Cancel")}</Button>
              <Button type="submit" disabled={busy || !paste.trim()}>{busy ? <Loader2 className="animate-spin" /> : null}{busy ? tr("正在接上…", "Connecting…") : tr("接上", "Connect")}</Button>
            </DialogFooter>
          </form>
        ) : null}

        {step === 2 ? (
          <div className="grid gap-4">
            <div className="flex items-center gap-3">
              <CircleCheck className="size-9 shrink-0 text-ok" />
              <div>
                <p className="font-medium">{again ? tr(`${name} 重新登录好了`, `${name} is signed in again`) : tr(`${name} 接上了`, `${name} is connected`)}</p>
                <p className="text-muted-foreground text-sm">{tr("只给你自己用。你的会话会先用它，用满了再走订阅池。", "Yours alone. Your sessions use it first, and the pool once it's full.")}</p>
              </div>
            </div>
            <DialogFooter><Button onClick={() => onOpenChange(false)}>{tr("好", "Done")}</Button></DialogFooter>
          </div>
        ) : null}
      </DialogContent>
    </Dialog>
  );
};

// my-claude, my-claude-2, …: the first name that is free
function suggest(p: Prov, known: string[]) {
  const base = p === "codex" ? "my-chatgpt" : "my-claude";
  for (let i = 1; ; i++) { const n = i === 1 ? base : `${base}-${i}`; if (!known.includes(`${p}/${n}`)) return n; }
}

// ── the card on 用量: the person's own subscriptions, or the way to connect one ──
export const MySubsCard: FC = () => {
  const subs = useLoad<{ subscriptions?: MySub[] }>("/v1/me/subscriptions");
  const [qs, setQs] = useSearchParams();
  const [open, setOpen] = useState(false);
  const [preset, setPreset] = useState<{ provider: Prov; account?: string } | undefined>();
  const list = subs.data?.subscriptions || [];
  const known = list.map((s) => `${s.provider}/${s.account}`);
  // ?connect=1 (or =claude / =codex) opens the dialog — the site's 「用自己的订阅」 links here
  useEffect(() => {
    const c = qs.get("connect");
    if (!c) return;
    setPreset(c === "claude" || c === "codex" ? { provider: c } : undefined);
    setOpen(true);
    setQs((q) => { const n = new URLSearchParams(q); n.delete("connect"); return n; }, { replace: true });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const connect = () => { setPreset(undefined); setOpen(true); };
  return (
    <Card className="gap-3">
      <CardHeader className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <CardTitle className="text-base">{tr("我自己的订阅", "My own subscriptions")}</CardTitle>
          <CardDescription className="mt-1">{tr("你自己的 Claude / ChatGPT 订阅，只给你用", "Your own Claude / ChatGPT subscription, for you alone")}</CardDescription>
        </div>
        {list.length ? <Button size="sm" variant="outline" className="shrink-0" onClick={connect}><Plus />{tr("再接一份", "Add another")}</Button> : null}
      </CardHeader>
      <CardContent>
        {subs.failed && !subs.data ? (
          <div className="flex items-center justify-between gap-3 py-4 text-[13px]">
            <span className="text-muted-foreground">{tr("读不到你的订阅", "Couldn't load your subscriptions")}</span>
            <Button variant="outline" size="sm" onClick={subs.reload}><RotateCw />{tr("再试一次", "Try again")}</Button>
          </div>
        ) : !subs.data ? (
          <div className="flex flex-col gap-3 py-1"><Skeleton className="h-4 w-1/3" /><Skeleton className="h-2 w-full" /><Skeleton className="h-2 w-full" /></div>
        ) : !list.length ? (
          <div className="flex flex-col items-center px-2 py-6 text-center">
            <div className="bg-muted text-muted-foreground mb-3 grid size-11 place-items-center rounded-2xl"><KeyRound className="size-5" /></div>
            <p className="font-display text-[17px] font-semibold">{tr("用你自己的订阅", "Use your own subscription")}</p>
            <p className="text-muted-foreground mt-1 max-w-sm text-[13px]">
              {tr("已经有 Claude Pro / Max 或 ChatGPT Plus / Pro？接上以后你的会话先用它，只给你自己用；账号密码在你自己的浏览器里输入。", "Already pay for Claude Pro / Max or ChatGPT Plus / Pro? Connect it and your sessions use it first, for you alone; you sign in in your own browser.")}
            </p>
            <Button className="mt-4" onClick={connect}><Plus />{tr("接上我自己的订阅", "Connect my own subscription")}</Button>
          </div>
        ) : (
          <div className="divide-y">
            {list.map((s) => <SubRow key={`${s.provider}/${s.account}`} s={s} onChange={subs.reload}
              onReconnect={(x) => { setPreset({ provider: x.provider, account: x.account }); setOpen(true); }} />)}
          </div>
        )}
      </CardContent>
      <ConnectDialog open={open} onOpenChange={setOpen} known={preset?.account ? [] : known} preset={preset} onConnected={subs.reload} />
    </Card>
  );
};
