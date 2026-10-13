// settings.tsx — 设置 (EPIC #3923 C8, claude-fleet#3931): who the person is, the
// ways they sign in (WeChat, email, GitHub — add one, change the address, take
// one off, never the last), their own configuration that follows them to every
// machine (export to a file, import one back — the team's is the admins'), light
// or dark (this device only) and the language (their account's), and sign-out.
// Only the entry's existing reads and writes (rule 7): /v1/me,
// /v1/me/identities, /v1/fleet/person-bundle, /auth/*/start?link=1, ?lang=,
// POST /app/logout. Stock shadcn/ui only.
import { useCallback, useEffect, useRef, useState, type FC, type FormEvent, type ReactNode } from "react";
import { CircleAlert, Download, KeyRound, LogOut, Mail, MessageCircle, RefreshCw, Upload, type LucideIcon } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Avatar, AvatarFallback } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { lang, tr } from "@/shared/i18n";
import { isAdmin, sendJSON } from "@/shared/api";
import { setThemePick, themePick, type ThemePick } from "@/shared/theme";
import { SignOut, usePage, useShell } from "../Shell";

declare const __PROTO__: boolean;

// ── the reads ──────────────────────────────────────────────────────────────

// /v1/me/identities (person.go IdentitiesView)
type Identity = { kind: string; subject: string; label: string; verified_at?: string };
type Identities = { person: string; identities: Identity[]; can_add: string[] };
// /v1/fleet/person-bundle (TeamBundleResponse)
type Bundle = { version: number; created?: string; bundle: Record<string, unknown> | null };

// A read that can be waiting, there, missing (404: this login has no person)
// or failed — each drawn its own way.
type Read<T> = { state: "loading" } | { state: "ok"; data: T } | { state: "none"; why: string } | { state: "failed" };

function useRead<T>(url: string | null): [Read<T>, () => void] {
  const [r, set] = useState<Read<T>>({ state: "loading" });
  const [n, bump] = useState(0);
  useEffect(() => {
    if (!url) return;
    let live = true;
    set({ state: "loading" });
    fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then(async (res) => {
        if (!live) return;
        if (res.status === 401) { location.assign("/app/signin"); return; }
        const j = await res.json().catch(() => null);
        if (res.ok && j) set({ state: "ok", data: j as T });
        else if (res.status === 404 || res.status === 403) set({ state: "none", why: (j && j.error) || "" });
        else set({ state: "failed" });
      })
      .catch(() => live && set({ state: "failed" }));
    return () => { live = false; };
  }, [url, n]);
  return [r, useCallback(() => bump((x) => x + 1), [])];
}

// ── pieces ─────────────────────────────────────────────────────────────────

const Title: FC<{ children: ReactNode }> = ({ children }) => (
  <h1 className="font-display mb-1 text-[26px] leading-tight font-semibold tracking-tight">
    {children}<span className="text-clay">.</span>
  </h1>
);

const Failed: FC<{ what: string; onRetry: () => void }> = ({ what, onRetry }) => (
  <div className="flex items-start gap-3">
    <CircleAlert className="text-destructive mt-0.5 size-5 shrink-0" aria-hidden />
    <div className="min-w-0 flex-1">
      <p className="font-medium">{tr(`读不到${what}`, `Couldn't load ${what}`)}</p>
      <p className="text-muted-foreground text-sm">{tr("入口暂时没有回应，别的页面不受影响。", "The entry did not answer; other pages are unaffected.")}</p>
    </div>
    <Button size="sm" variant="outline" onClick={onRetry}><RefreshCw />{tr("重试", "Retry")}</Button>
  </div>
);

const Lines: FC<{ n?: number }> = ({ n = 2 }) => (
  <div className="space-y-3">
    {Array.from({ length: n }, (_, i) => (
      <div key={i} className="flex items-center gap-3"><Skeleton className="size-5 rounded-full" /><Skeleton className="h-4 w-2/5" /></div>
    ))}
  </div>
);

// A one-line outcome under a card's buttons: done, or what went wrong.
type Note = { tone: "ok" | "bad"; text: string } | null;
const NoteLine: FC<{ note: Note }> = ({ note }) =>
  note ? (
    <Alert variant={note.tone === "bad" ? "destructive" : "default"} className="mt-3" role="status">
      {note.tone === "bad" ? <CircleAlert /> : null}
      <AlertDescription className={note.tone === "ok" ? "text-foreground" : undefined}>{note.text}</AlertDescription>
    </Alert>
  ) : null;

// how a person signed in, as /v1/me's via says it (me.tsx says it the same way)
const VIA: Record<string, [string, string]> = {
  github: ["用 GitHub 登录", "Signed in with GitHub"],
  wechat: ["用微信登录", "Signed in with WeChat"],
  email: ["用邮箱登录", "Signed in with email"],
  token: ["用口令登录", "Signed in with a token"],
  open: ["免登录", "No sign-in"],
};

const KINDS: Record<string, { icon: LucideIcon; label: () => string; tint?: string }> = {
  wechat: { icon: MessageCircle, label: () => tr("微信", "WeChat"), tint: "text-[#07c160]" },
  email: { icon: Mail, label: () => tr("邮箱", "Email") },
  github: { icon: KeyRound, label: () => "GitHub" },
};
const kindOf = (k: string) => KINDS[k] || { icon: KeyRound, label: () => k };

// what a sign-in flow that came back here says went wrong (settingsBack, the hub)
const BACK_ERR: Record<string, [string, string]> = {
  taken: ["这个地址或账号已经是别人的登录方式了。", "That address or account already signs someone else in."],
  github: ["没能绑上 GitHub，再试一次。", "GitHub could not be added — try again."],
  "wechat-taken": ["这个微信已经是别人的登录方式了。", "That WeChat already signs someone else in."],
  wechat: ["没能绑上微信，再试一次。", "WeChat could not be added — try again."],
};

// ── 资料 ───────────────────────────────────────────────────────────────────

const Profile: FC = () => {
  const { me } = useShell();
  const name = me?.name || me?.login || "";
  const via = me?.via ? VIA[me.via] : undefined;
  return (
    <Card>
      <CardHeader><CardTitle className="text-base">{tr("资料", "Profile")}</CardTitle></CardHeader>
      <CardContent className="flex items-center gap-4">
        {me ? (
          <>
            <Avatar className="size-12"><AvatarFallback className="text-lg font-medium">{(name[0] || "·").toUpperCase()}</AvatarFallback></Avatar>
            <div className="min-w-0">
              <p className="font-display truncate text-[18px] leading-tight font-semibold">{name || tr("（没有名字）", "(no name)")}</p>
              <p className="text-muted-foreground mt-1 truncate text-[13px]">
                {isAdmin(me) ? tr("管理员", "Admin") : tr("成员", "Member")}{via ? ` · ${tr(...via)}` : ""}
              </p>
            </div>
          </>
        ) : (
          <>
            <Skeleton className="size-12 rounded-full" />
            <div className="flex flex-col gap-2"><Skeleton className="h-5 w-28" /><Skeleton className="h-4 w-40" /></div>
          </>
        )}
      </CardContent>
    </Card>
  );
};

// ── 登录方式 ───────────────────────────────────────────────────────────────

const EmailDialog: FC<{ open: boolean; change: boolean; onClose: () => void; onSent: (addr: string, mailed: boolean) => void }> =
  ({ open, change, onClose, onSent }) => {
    const [addr, setAddr] = useState("");
    const [busy, setBusy] = useState(false);
    const [err, setErr] = useState("");
    useEffect(() => { if (open) { setAddr(""); setErr(""); } }, [open]);
    const send = async (e: FormEvent) => {
      e.preventDefault();
      const a = addr.trim();
      if (!a) return;
      setBusy(true); setErr("");
      const r = await sendJSON<{ mail_sent?: boolean }>("POST", "/v1/me/identities", { kind: "email", subject: a });
      setBusy(false);
      if (!r.ok) {
        setErr(r.status === 429 ? tr("刚给这个地址发过一封，等一分钟再试。", "A mail went there a moment ago — wait a minute.")
          : r.status === 409 ? tr("这个地址已经是别人的登录方式了。", "That address already signs someone else in.")
          : r.status === 400 ? tr("这不是一个邮箱地址。", "That is not an email address.")
          : r.error || tr("没发出去，再试一次。", "Could not send — try again."));
        return;
      }
      onSent(a, r.status === 202 || !!r.body?.mail_sent);
    };
    return (
      <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
        <DialogContent>
          <form onSubmit={send} className="grid gap-4">
            <DialogHeader>
              <DialogTitle>{change ? tr("换一个邮箱", "Change email") : tr("绑定邮箱", "Add an email")}</DialogTitle>
              <DialogDescription>
                {tr("我们会往这个地址发一封信，在这个浏览器里点开信里的链接就绑上了，以后能用它登录。",
                  "We'll mail a link to this address; open it in this browser and it is added — you can sign in with it from then on.")}
                {change ? tr("绑上之后，可以把旧的去掉。", " Once it's added, you can take the old one off.") : null}
              </DialogDescription>
            </DialogHeader>
            <div className="grid gap-2">
              <Label htmlFor="email-addr">{tr("邮箱地址", "Email address")}</Label>
              <Input id="email-addr" type="email" inputMode="email" autoComplete="email" required autoFocus
                placeholder="name@example.com" value={addr} onChange={(e) => setAddr(e.target.value)} aria-invalid={!!err} />
              {err ? <p className="text-destructive text-[13px]" role="alert">{err}</p> : null}
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={onClose}>{tr("取消", "Cancel")}</Button>
              <Button type="submit" disabled={busy || !addr.trim()}>{busy ? tr("发送中…", "Sending…") : tr("发登录链接", "Send the link")}</Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    );
  };

const SignInWays: FC = () => {
  const { me } = useShell();
  const [ids, reload] = useRead<Identities>(me?.person ? "/v1/me/identities" : null);
  const [email, setEmail] = useState<{ open: boolean; change: boolean }>({ open: false, change: false });
  const [drop, setDrop] = useState<Identity | null>(null);
  const [note, setNote] = useState<Note>(() => {
    const e = new URLSearchParams(location.search).get("e");
    return e && BACK_ERR[e] ? { tone: "bad", text: tr(...BACK_ERR[e]) } : null;
  });
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => { if (location.hash === "#logins") ref.current?.scrollIntoView({ block: "start" }); }, []);
  if (!me?.person) return null; // a token or an open door has no ways of its own

  const remove = async (i: Identity) => {
    setDrop(null);
    const r = await sendJSON("DELETE", `/v1/me/identities?kind=${encodeURIComponent(i.kind)}&subject=${encodeURIComponent(i.subject)}`);
    const what = `${kindOf(i.kind).label()} ${i.label || i.subject}`;
    setNote(r.ok ? { tone: "ok", text: tr(`已去掉 ${what}。`, `${what} taken off.`) }
      : { tone: "bad", text: r.status === 409 ? tr("这是你唯一的登录方式，先加一种再去。", "It's your only way to sign in — add another first.") : r.error || tr("没去掉，再试一次。", "Could not take it off — try again.") });
    reload();
  };

  const body = () => {
    if (ids.state === "loading") return <Lines />;
    if (ids.state === "failed") return <Failed what={tr("登录方式", "sign-in methods")} onRetry={reload} />;
    if (ids.state === "none") return <p className="text-muted-foreground text-sm">{tr("这个登录没有可管的登录方式。", "This sign-in has no methods to manage.")}</p>;
    const { identities, can_add } = ids.data;
    const only = identities.length <= 1;
    const hasEmail = identities.some((i) => i.kind === "email");
    const rows: ReactNode[] = identities.map((i) => {
      const k = kindOf(i.kind);
      return (
        <div key={`${i.kind}:${i.subject}`} className="flex min-h-11 items-center gap-3 py-3 first:pt-0 last:pb-0">
          <k.icon className={`size-5 shrink-0 ${k.tint || "text-muted-foreground"}`} aria-hidden />
          <span className="min-w-0 flex-1 truncate">
            {k.label()}{i.kind !== "wechat" ? <span className="text-muted-foreground"> {i.label || i.subject}</span> : null}
          </span>
          {i.kind === "email" && can_add.includes("email") ? (
            <Button size="sm" variant="ghost" onClick={() => setEmail({ open: true, change: true })}>{tr("换一个", "Change")}</Button>
          ) : null}
          {only ? <Badge variant="outline" className="rounded-full">{tr("已绑定", "Added")}</Badge>
            : <Button size="sm" variant="ghost" className="text-destructive hover:text-destructive" onClick={() => setDrop(i)}>{tr("去掉", "Remove")}</Button>}
        </div>
      );
    });
    for (const k of can_add) {
      if (k === "email" && hasEmail) continue;
      const kk = kindOf(k);
      const label = k === "email" ? tr("绑定邮箱", "Add email") : k === "wechat" ? tr("绑定微信", "Add WeChat") : tr("绑定 GitHub", "Add GitHub");
      rows.push(
        <div key={`add:${k}`} className="flex min-h-11 items-center gap-3 py-3 first:pt-0 last:pb-0">
          <kk.icon className={`size-5 shrink-0 ${kk.tint || "text-muted-foreground"}`} aria-hidden />
          <span className="text-muted-foreground flex-1">{kk.label()}</span>
          {k === "email"
            ? <Button size="sm" variant="outline" onClick={() => setEmail({ open: true, change: false })}>{label}</Button>
            : <Button size="sm" variant="outline" asChild><a href={`/auth/${k}/start?link=1`} className="no-underline">{label}</a></Button>}
        </div>,
      );
    }
    return <div className="divide-y">{rows}</div>;
  };

  return (
    <Card ref={ref} id="logins" className="scroll-mt-4">
      <CardHeader>
        <CardTitle className="text-base">{tr("登录方式", "Sign-in methods")}</CardTitle>
        <CardDescription>{tr("至少留一种。多一种，丢了手机也能登录。", "Keep at least one. With two, losing your phone won't lock you out.")}</CardDescription>
      </CardHeader>
      <CardContent>
        {body()}
        <NoteLine note={note} />
      </CardContent>
      <EmailDialog open={email.open} change={email.change} onClose={() => setEmail({ open: false, change: false })}
        onSent={(a, mailed) => {
          setEmail({ open: false, change: false });
          setNote({ tone: "ok", text: mailed ? tr(`登录链接已发到 ${a}，在这个浏览器里点开就绑上了。`, `A sign-in link went to ${a}; open it in this browser to add it.`)
            : tr(`已绑上 ${a}。`, `${a} added.`) });
          reload();
        }} />
      <AlertDialog open={!!drop} onOpenChange={(o) => !o && setDrop(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{drop ? tr(`去掉「${kindOf(drop.kind).label()} ${drop.label || drop.subject}」？`, `Remove ${kindOf(drop.kind).label()} ${drop.label || drop.subject}?`) : ""}</AlertDialogTitle>
            <AlertDialogDescription>{tr("之后不能再用它登录，其他登录方式不受影响。", "You won't be able to sign in with it; your other methods stay.")}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{tr("先不", "Keep it")}</AlertDialogCancel>
            <AlertDialogAction className="bg-destructive hover:bg-destructive/90 text-white" onClick={() => drop && remove(drop)}>{tr("去掉", "Remove")}</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  );
};

// ── 我的配置 ───────────────────────────────────────────────────────────────

const EXPORT_NAME = "my-fleet-config.json";

// readImport reads an exported file back: the whole GET answer ({version,
// bundle}) or the bare bundle — the old 配置 page's files too.
function readImport(text: string): Record<string, unknown> {
  let v: unknown;
  try { v = JSON.parse(text); } catch { throw new Error(tr("这不是一个 JSON 文件。", "That is not a JSON file.")); }
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error(tr("文件里不是一份配置。", "The file does not hold a configuration."));
  const o = v as Record<string, unknown>;
  return o.bundle && typeof o.bundle === "object" && !Array.isArray(o.bundle) ? (o.bundle as Record<string, unknown>) : o;
}

const when = (iso?: string) => {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? "" : d.toLocaleDateString(lang === "zh" ? "zh-CN" : "en", { year: "numeric", month: "short", day: "numeric" });
};

const MyConfig: FC = () => {
  const [b, reload] = useRead<Bundle>("/v1/fleet/person-bundle");
  const [note, setNote] = useState<Note>(null);
  const [busy, setBusy] = useState(false);
  const file = useRef<HTMLInputElement>(null);

  const exportIt = () => {
    if (b.state !== "ok") return;
    const url = URL.createObjectURL(new Blob([JSON.stringify({ version: b.data.version, bundle: b.data.bundle || {} }, null, 2) + "\n"], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url; a.download = EXPORT_NAME; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setNote({ tone: "ok", text: tr(`已导出 ${EXPORT_NAME}。`, `Exported ${EXPORT_NAME}.`) });
  };
  const importIt = async (f: File) => {
    if (b.state !== "ok") return;
    setBusy(true);
    try {
      const bundle = readImport(await f.text());
      const r = await sendJSON("PUT", "/v1/fleet/person-bundle", { bundle, base: b.data.version || 0, note: `Imported ${f.name}` });
      if (r.ok) setNote({ tone: "ok", text: tr("已导入，下一个会话起生效。", "Imported — it applies from your next session.") });
      else setNote({ tone: "bad", text: r.status === 409 ? tr("配置刚在别处改过，已重新读取，请再导一次。", "It changed elsewhere a moment ago — reloaded; import again.")
        : tr(`没导进去：${r.error || "入口没有回应"}`, `Not imported: ${r.error || "the entry did not answer"}`) });
    } catch (e) {
      setNote({ tone: "bad", text: tr(`没导进去：${(e as Error).message}`, `Not imported: ${(e as Error).message}`) });
    }
    setBusy(false);
    reload();
  };

  const meta = b.state === "ok" && b.data.version
    ? `v${b.data.version}${b.data.created ? ` · ${tr("更新于", "updated")} ${when(b.data.created)}` : ""}` : "";
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{tr("我的配置", "My configuration")}</CardTitle>
        <CardDescription>{tr("常用工具和提示语，跟着你到每台机器。团队配置由管理员维护。", "Your tools and prompts, on every machine you work from. The team's configuration is kept by admins.")}</CardDescription>
      </CardHeader>
      <CardContent>
        {b.state === "loading" ? <Skeleton className="h-9 w-48" />
          : b.state === "failed" ? <Failed what={tr("我的配置", "your configuration")} onRetry={reload} />
          : b.state === "none" ? <p className="text-muted-foreground text-sm">{tr("这个登录没有绑定到一个人，没有个人配置。", "This sign-in is not bound to a person, so it has no configuration of its own.")}</p>
          : (
            <>
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="outline" onClick={exportIt}><Download />{tr("导出", "Export")}</Button>
                <Button variant="outline" disabled={busy} onClick={() => file.current?.click()}><Upload />{busy ? tr("导入中…", "Importing…") : tr("导入…", "Import…")}</Button>
                {meta ? <span className="text-muted-foreground ms-auto font-mono text-[12px]">{meta}</span> : null}
                <input ref={file} type="file" accept="application/json,.json" hidden aria-label={tr("选一个配置文件", "Choose a configuration file")}
                  onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ""; if (f) void importIt(f); }} />
              </div>
              <NoteLine note={note} />
            </>
          )}
      </CardContent>
    </Card>
  );
};

// ── 界面 ───────────────────────────────────────────────────────────────────

const Look: FC = () => {
  const [theme, setTheme] = useState<ThemePick>(themePick);
  const pickLang = (v: string) => {
    if (v === lang || __PROTO__) return; // the review page has no entry to keep the choice
    // the hub keeps a ?lang= choice on the account and in the cookie (pagelang.go)
    const q = new URLSearchParams(location.search);
    q.set("lang", v);
    location.assign(`${location.pathname}?${q}`);
  };
  return (
    <Card>
      <CardHeader><CardTitle className="text-base">{tr("界面", "Appearance")}</CardTitle></CardHeader>
      <CardContent className="space-y-4">
        <div className="flex items-center justify-between gap-3">
          <Label htmlFor="theme-pick">{tr("深色 / 浅色", "Dark / light")}</Label>
          <Select value={theme} onValueChange={(v) => { setTheme(v as ThemePick); setThemePick(v as ThemePick); }}>
            <SelectTrigger id="theme-pick" className="w-32"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="system">{tr("跟系统", "System")}</SelectItem>
              <SelectItem value="dark">{tr("深色", "Dark")}</SelectItem>
              <SelectItem value="light">{tr("浅色", "Light")}</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <div className="flex items-center justify-between gap-3">
          <Label htmlFor="lang-pick">{tr("语言", "Language")}</Label>
          <Select value={lang} onValueChange={pickLang}>
            <SelectTrigger id="lang-pick" className="w-32"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="zh">中文</SelectItem>
              <SelectItem value="en">English</SelectItem>
            </SelectContent>
          </Select>
        </div>
      </CardContent>
    </Card>
  );
};

export default function SettingsPage() {
  usePage(tr("设置", "Settings"));
  const { me } = useShell();
  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col gap-3 px-4 py-5 md:px-6 md:py-8">
      <Title>{tr("设置", "Settings")}</Title>
      <Profile />
      <SignInWays />
      <MyConfig />
      <Look />
      {me?.can_logout ? (
        <SignOut>
          <Button type="submit" variant="outline" className="h-10 w-full rounded-full">
            <LogOut />{tr("退出登录", "Sign out")}
          </Button>
        </SignOut>
      ) : null}
    </div>
  );
}
