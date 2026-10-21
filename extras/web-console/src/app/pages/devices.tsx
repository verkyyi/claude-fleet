// devices.tsx — 设备 (EPIC #3923 C7, issue #3930): one page, four tabs
// (?tab=pc|phone|keys|home), in place of four old ones — 设备与 SSH
// (/app/connect), 从手机连 (/fleet/keys), 我的连接 (/fleet/connection) and
// 我的机器 (/app/machines):
//   电脑      /v1/fleet/connect's one-line install, the computers registered to
//             the person (/v1/fleet/devices, 收回 = POST …/revoke), the
//             ~/.ssh config snippet and a certificate issued by hand (/v1/fleet/cert);
//   手机      what Termius asks for and its QR code — GET /v1/fleet/entry/keys's door;
//   公钥      the person's keys there: list, add (POST), delete (DELETE …/<id>);
//   我的机器  their home (/v1/fleet/entry/home) and every machine of theirs off
//             /v1/nodes — whether it takes sessions, its load, its sessions.
// Only the person's own: every read is cut to them by the hub. Stock shadcn/ui only.
import { useCallback, useEffect, useState, type FC, type ReactNode } from "react";
import { useSearchParams } from "react-router";
import {
  Check, Copy, KeyRound, Laptop, LoaderCircle, Plus, Server, Smartphone, Trash2, type LucideIcon,
} from "lucide-react";
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { useCopyToClipboard } from "@/hooks/use-copy-to-clipboard";
import { cn } from "@/lib/utils";
import { lang, tr } from "@/shared/i18n";
import { isAdmin, sendJSON, useLoad, type Device, type Me } from "@/shared/api";
import { usePage, useShell } from "../Shell";
import { ago as agoText, Failed, Loading, PageHeader } from "../parts";

// ---- the reads ----------------------------------------------------------

type Read<T> = { data: T | null; status: number; loading: boolean; retry: () => void };

// useBook GETs the entry book (and again on bump): its answer and its status —
// a 404 is an answer here (the phone's door is off on this hub), not a failure,
// which useLoad cannot tell apart.
function useBook<T>(url: string, bump = 0): Read<T> {
  const [n, setN] = useState(0);
  const [s, set] = useState<{ data: T | null; status: number; loading: boolean }>({ data: null, status: 0, loading: true });
  useEffect(() => {
    let live = true;
    fetch(url, { headers: { Accept: "application/json" } }).catch(() => null).then(async (r) => {
      if (r?.status === 401) { location.assign("/app/signin"); return; }
      const data = r?.ok ? ((await r.json().catch(() => null)) as T | null) : null;
      if (live) set({ data, status: r ? r.status : 0, loading: false });
    });
    return () => { live = false; };
  }, [url, n, bump]);
  return { ...s, retry: () => setN((x) => x + 1) };
}

type Connect = {
  install_command?: string; install_ready?: boolean; problem?: string; ca_enabled?: boolean;
  cert_ttl_sec?: number; ssh_config?: string; config_path?: string; signed_in?: boolean;
};
type EntryKey = { id: string; fp: string; type: string; name: string; created: string; last_used?: string; revoked_at?: string };
type Door = {
  domain?: string; address?: string; port: number; login?: string; home_name?: string; home_why?: string;
  home_down?: string; state: string; why?: string; qr?: string[]; jump?: string; host_fp?: string;
  shared?: Shared;
};
// the door's one address for everyone (A5SQ): the same host and port, the person's own login, the door's host key
type Shared = { address: string; port: number; login: string; host_fp?: string; qr?: string[] };
type HomeChoice = { machine: string; login: string; online: boolean; name?: string };
type Entry = {
  name?: string; suggested_name?: string; home: { machine: string; login: string; set_by: string } | null;
  home_choices: HomeChoice[]; keys: EntryKey[]; door?: Door;
};
type Node = {
  endpoint_id: string; hostname: string; os_user: string; status: string; compute_off?: boolean; admit?: boolean;
  personal?: boolean; machine_link?: boolean; load1: number; ncpu: number; sessions: number | null;
  fleet_version?: string; last_heartbeat?: string;
};
type Nodes = { nodes?: Node[]; machines?: { hostname: string; alias?: string; role?: string }[] };

const ENTRY_KEYS = "/v1/fleet/entry/keys";

// ---- small parts ----------------------------------------------------------

const ago = (iso?: string) => agoText(iso) || tr("从没", "never");
const shortFP = (fp: string) => (fp.length > 22 ? `${fp.slice(0, 15)}…${fp.slice(-6)}` : fp);

const CopyButton: FC<{ text: string; label?: string; className?: string }> = ({ text, label, className }) => {
  const { isCopied, copyToClipboard } = useCopyToClipboard({ copiedDuration: 1500 });
  return (
    <Button type="button" size={label ? "sm" : "icon"} variant="ghost" className={cn(label ? "" : "size-8 shrink-0", className)}
      aria-label={isCopied ? tr("已复制", "Copied") : tr("复制", "Copy")} onClick={() => copyToClipboard(text)}>
      {isCopied ? <Check /> : <Copy />}{label ? (isCopied ? tr("已复制", "Copied") : label) : null}
    </Button>
  );
};

// One thing to copy: a command or a value, on one line, scrolled inside itself.
const CopyLine: FC<{ text: string }> = ({ text }) => (
  <div className="bg-muted/60 flex min-w-0 items-center gap-1 rounded-lg border ps-3 pe-1">
    <code className="min-w-0 flex-1 overflow-x-auto py-2 font-mono text-[13px] whitespace-nowrap">{text}</code>
    <CopyButton text={text} />
  </div>
);

const Note: FC<{ tone?: "ok" | "warn" | "bad" | "info"; children: ReactNode }> = ({ tone = "info", children }) => (
  <p role="status" className={cn("rounded-lg border px-3 py-2 text-[13px] leading-relaxed",
    tone === "ok" && "border-ok/40 text-foreground bg-ok/10",
    tone === "warn" && "border-warn/50 bg-warn/10 text-foreground",
    tone === "bad" && "border-destructive/40 bg-destructive/10 text-destructive",
    tone === "info" && "bg-muted/50 text-muted-foreground")}>{children}</p>
);

// Confirm: the one AlertDialog every take-back on this page goes through.
type Ask = { title: string; body: string; yes: string; run: () => Promise<void> } | null;
const Confirm: FC<{ ask: Ask; close: () => void }> = ({ ask, close }) => {
  const [busy, setBusy] = useState(false);
  return (
    <AlertDialog open={!!ask} onOpenChange={(o) => !o && !busy && close()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{ask?.title}</AlertDialogTitle>
          <AlertDialogDescription>{ask?.body}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>{tr("先不", "Not now")}</AlertDialogCancel>
          <AlertDialogAction variant="destructive" disabled={busy}
            onClick={async (e) => { e.preventDefault(); setBusy(true); await ask?.run(); setBusy(false); close(); }}>
            {busy ? <LoaderCircle className="animate-spin" /> : null}{ask?.yes}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
};

const Row: FC<{ icon: LucideIcon; title: ReactNode; sub?: ReactNode; end?: ReactNode }> = ({ icon: Icon, title, sub, end }) => (
  <div className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
    <Icon className="text-muted-foreground size-5 shrink-0" aria-hidden />
    <div className="min-w-0 flex-1">
      <p className="truncate font-medium">{title}</p>
      {sub ? <p className="text-muted-foreground truncate text-[13px]">{sub}</p> : null}
    </div>
    {end}
  </div>
);

// The hub says why it refused, in Chinese; an English page says it plainly.
const refusal = (error: string) => (lang === "zh" && error ? error : tr("没成功，稍后再试。", "That didn't work; try again."));

// ---- 电脑 -------------------------------------------------------------------

const PcTab: FC<{ setAsk: (a: Ask) => void }> = ({ setAsk }) => {
  const conn = useLoad<Connect>("/v1/fleet/connect");
  const devs = useLoad<{ devices?: Device[] }>("/v1/fleet/devices");
  const c = conn.data;
  const list = (devs.data?.devices || []).filter((d) => !d.revoked_at && !d.host);
  if (conn.loading && devs.loading) return <Loading n={2} />;
  return (
    <div className="flex flex-col gap-3">
      {conn.failed ? <Failed what={tr("安装命令", "the install command")} onRetry={conn.reload} /> : !c ? <Loading n={1} /> : <Card>
        <CardHeader>
          <CardTitle className="text-base">{tr("在电脑上装 fleet", "Install fleet on a computer")}</CardTitle>
          <CardDescription>{tr("打开终端，粘贴这一行；装好后输入 fleet，扫码登录就能看到你的会话。",
            "Open a terminal and paste this line; then type fleet and scan to sign in — your sessions are there.")}</CardDescription>
        </CardHeader>
        <CardContent>
          {c.install_command && c.install_ready !== false ? <CopyLine text={c.install_command} />
            : <Note tone="warn">{c.problem || tr("这个入口还不能装客户端：要先有 SSH 证书和 GitHub 登录。", "This hub can't install the client yet: it needs its SSH CA and GitHub sign-in.")}</Note>}
        </CardContent>
      </Card>}
      {devs.failed ? <Failed what={tr("设备", "devices")} onRetry={devs.reload} /> : !devs.data ? <Loading n={1} /> : <Card>
        <CardHeader>
          <CardTitle className="text-base">{tr("已连上的电脑", "Connected computers")}</CardTitle>
          <CardDescription>{tr("扫码登录过的电脑。收回后它立刻断开，要再扫一次码才能连。",
            "Computers you scanned in from. Revoke one and it is cut off at once until it scans again.")}</CardDescription>
        </CardHeader>
        <CardContent>
          {list.length ? (
              <div className="divide-y">
                {list.map((d) => (
                  <Row key={d.fingerprint} icon={Laptop} title={d.name || shortFP(d.fingerprint)}
                    sub={tr(`上次连接 ${ago(d.last_used_at)} · 登记于 ${ago(d.registered_at)}`, `Last used ${ago(d.last_used_at)} · added ${ago(d.registered_at)}`)}
                    end={<Button size="sm" variant="ghost" className="text-destructive hover:text-destructive" onClick={() => setAsk({
                      title: tr(`收回「${d.name || shortFP(d.fingerprint)}」？`, `Revoke “${d.name || shortFP(d.fingerprint)}”?`),
                      body: tr("这台电脑会立刻断开，之后要重新扫码登录才能连。", "This computer is cut off at once; it has to scan in again to connect."),
                      yes: tr("收回", "Revoke"),
                      run: async () => { await sendJSON("POST", "/v1/fleet/devices/revoke", { fingerprint: d.fingerprint }); devs.reload(); },
                    })}>{tr("收回", "Revoke")}</Button>} />
                ))}
              </div>
            ) : <p className="text-muted-foreground text-sm">{tr("还没有电脑连上来。装好 fleet、扫码登录后会出现在这里。", "No computer yet. Install fleet and scan in; it shows up here.")}</p>}
        </CardContent>
      </Card>}
      {c?.ssh_config ? (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{tr("SSH 配置", "SSH config")}</CardTitle>
            <CardDescription>{tr(`fleet login 会写好它；手动用 ssh 时放进 ${c.config_path || "~/.ssh/fleet-ssh-config"}。`,
              `fleet login writes it; for plain ssh it goes in ${c.config_path || "~/.ssh/fleet-ssh-config"}.`)}</CardDescription>
            <CardAction><CopyButton text={c.ssh_config} label={tr("复制", "Copy")} /></CardAction>
          </CardHeader>
          <CardContent>
            <pre className="bg-muted/60 max-h-64 overflow-auto rounded-lg border p-3 font-mono text-[12px] leading-relaxed">{c.ssh_config}</pre>
          </CardContent>
        </Card>
      ) : null}
      {c?.ca_enabled ? <CertByHand ttl={c.cert_ttl_sec || 43200} /> : null}
    </div>
  );
};

// A certificate signed by hand for a pasted public key — the old page's, kept.
const CertByHand: FC<{ ttl: number }> = ({ ttl }) => {
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [out, setOut] = useState<{ cert?: string; until?: string; err?: string } | null>(null);
  const hours = Math.round(ttl / 3600);
  const issue = async () => {
    setBusy(true);
    const r = await sendJSON<{ certificate?: string; valid_before?: string }>("POST", "/v1/fleet/cert", { public_key: key.trim() });
    setBusy(false);
    setOut(r.ok && r.data?.certificate ? { cert: r.data.certificate, until: r.data.valid_before } : { err: refusal(r.ok ? "" : r.error) });
  };
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{tr("手动签一张证书", "Issue a certificate by hand")}</CardTitle>
        <CardDescription>{tr(`贴一行公钥，签出 ${hours} 小时有效的 SSH 证书。用 fleet 客户端时不需要。`,
          `Paste a public key for an SSH certificate valid ${hours} hours. Not needed with the fleet client.`)}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        <div className="flex gap-2">
          <Input value={key} onChange={(e) => setKey(e.target.value)} placeholder="ssh-ed25519 AAAA… you@laptop"
            className="font-mono text-[13px]" spellCheck={false} autoComplete="off" aria-label={tr("公钥", "Public key")} />
          <Button variant="outline" disabled={busy || !key.trim()} onClick={issue}>{busy ? <LoaderCircle className="animate-spin" /> : null}{tr("签发", "Issue")}</Button>
        </div>
        {out?.err ? <Note tone="bad">{out.err}</Note> : null}
        {out?.cert ? (
          <>
            <Textarea readOnly rows={4} value={out.cert} className="font-mono text-[12px]" aria-label={tr("证书", "Certificate")} />
            <div className="flex items-center gap-2">
              <CopyButton text={out.cert} label={tr("复制证书", "Copy certificate")} />
              {out.until ? <span className="text-muted-foreground text-[13px]">{tr(`有效到 ${new Date(out.until).toLocaleString("zh-CN")}`, `Valid until ${new Date(out.until).toLocaleString("en")}`)}</span> : null}
            </div>
          </>
        ) : null}
      </CardContent>
    </Card>
  );
};

// ---- 手机 ---------------------------------------------------------------------

// The door's state, as the keys page says it.
const DoorState: FC<{ d: Door }> = ({ d }) => {
  switch (d.state) {
    case "ok": return <Note tone="ok">{tr("入口开着，外面连得上。", "The door is open and reachable from outside.")}</Note>;
    case "nokey": return <Note>{tr("先在「公钥」里加上手机的公钥，家机器就会为你打开入口。", "Add your phone's public key under Keys first; your home machine then opens the door for you.")}</Note>;
    case "opening": return <Note tone="warn">{tr("正在为你打开入口，约 1 分钟。", "Opening the door for you — about a minute.")}</Note>;
    case "down": return <Note tone="bad">{tr(`家机器 ${d.home_name} ${d.home_down || ""}连不上（关机、睡着或断网），你的地址也就连不上。它回来就好。`,
      `Your home machine ${d.home_name} is unreachable (off, asleep or offline), so your address is too. It's fine once it's back.`)}</Note>;
    case "nohome": return <Note tone="warn">{tr("你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来。",
      "You have no home yet: it is a machine with your login and fleet running on it. Start fleet on one first.")}</Note>;
    case "far": return <Note tone="bad">{tr(`外面还连不上：${d.why || ""}`, `Not reachable from outside yet. ${d.why || ""}`)}</Note>;
  }
  return null;
};

// The QR code, drawn from the hub's matrix (rows of '#' and '.').
const QR: FC<{ rows: string[] }> = ({ rows }) => {
  const n = rows.length, q = 2;
  return (
    <svg viewBox={`${-q} ${-q} ${n + 2 * q} ${n + 2 * q}`} className="size-full" shapeRendering="crispEdges" role="img"
      aria-label={tr("扫码在手机的终端 App 里打开", "Scan to open in your phone's terminal app")}>
      <rect x={-q} y={-q} width={n + 2 * q} height={n + 2 * q} fill="white" />
      <path fill="black" d={rows.flatMap((r, y) => [...r].map((c, x) => (c === "#" ? `M${x} ${y}h1v1h-1z` : ""))).join("")} />
    </svg>
  );
};

const DoorOff: FC<{ me: Me | null }> = ({ me }) => (
  <Card>
    <CardHeader>
      <CardTitle className="text-base">{tr("从手机直连还没开", "Direct phone access is off")}</CardTitle>
      <CardDescription>{isAdmin(me)
        ? tr("你是管理员：点一下就打开（设置 fleet.entry，随时可以在设置里关掉）。", "You're an admin: one press turns it on (the fleet.entry setting; turn it off any time in settings).")
        : tr("这个入口还没打开「从手机直连」，请管理员打开它（设置里的 fleet.entry）。", "This hub hasn't turned on direct phone access; ask an admin to (the fleet.entry setting).")}</CardDescription>
    </CardHeader>
    {isAdmin(me) ? (
      <CardContent>
        {/* the keys page's own switch: a form POST, answered by a redirect back here */}
        <form method="post" action="/fleet/keys">
          <input type="hidden" name="do" value="enable" />
          <Button type="submit">{tr("打开直连入口", "Turn it on")}</Button>
        </form>
      </CardContent>
    ) : null}
  </Card>
);

const NameForm: FC<{ suggested?: string; domain?: string; done: () => void }> = ({ suggested, domain, done }) => {
  const [name, setName] = useState(suggested || "");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const save = async () => {
    setBusy(true);
    const r = await sendJSON("PUT", "/v1/fleet/entry/name", { name });
    setBusy(false);
    if (r.ok) done(); else setErr(refusal(r.error));
  };
  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor="addr-name">{tr("先给你的地址起个名字", "First, name your address")}</Label>
      <div className="flex gap-2">
        <Input id="addr-name" value={name} maxLength={20} autoCapitalize="off" autoCorrect="off" spellCheck={false}
          onChange={(e) => setName(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))} className="font-mono" />
        <Button disabled={busy || name.length < 3} onClick={save}>{tr("就用这个", "Use it")}</Button>
      </div>
      <p className="text-muted-foreground text-[13px]">{tr(`小写字母、数字和「-」，3–20 个。地址会是 ${name || "…"}.${domain || "…"}`,
        `3–20 lowercase letters, digits or “-”. Your address: ${name || "…"}.${domain || "…"}`)}</p>
      {err ? <Note tone="bad">{err}</Note> : null}
    </div>
  );
};

const PhoneTab: FC<{ entry: Read<Entry>; me: Me | null; reload: () => void }> = ({ entry, me, reload }) => {
  if (entry.loading && !entry.data) return <Loading n={1} />;
  if (entry.status === 404) return <DoorOff me={me} />;
  if (!entry.data?.door) return <Failed what={tr("手机的连接方式", "the phone's way in")} onRetry={entry.retry} />;
  const v = entry.data, d = entry.data.door;
  const rows: [string, string | number | undefined][] = [[tr("地址", "Host"), d.address], [tr("端口", "Port"), d.port], [tr("用户名", "User"), d.login]];
  const direct = (
    <>
      <div className={cn("grid gap-4", d.qr ? "sm:grid-cols-[160px_1fr]" : "")}>
        {d.qr ? (
          <div className="mx-auto aspect-square w-40 overflow-hidden rounded-xl border bg-white p-1.5 sm:mx-0"><QR rows={d.qr} /></div>
        ) : null}
        <div className="flex min-w-0 flex-col text-sm">
          {rows.map(([k, val]) => (
            <div key={k} className="flex min-h-11 items-center gap-2 border-b py-1 last:border-b-0">
              <span className="text-muted-foreground w-16 shrink-0">{k}</span>
              {val !== undefined && val !== "" ? (
                <>
                  <span className="min-w-0 flex-1 truncate font-mono">{val}</span>
                  <CopyButton text={String(val)} />
                </>
              ) : <span className="text-warn flex-1">{k === tr("用户名", "User") ? tr("还没有家", "No home yet") : !d.domain ? tr("地址还没配好", "Not configured") : tr("还没起名", "Not named yet")}</span>}
            </div>
          ))}
          {d.qr ? <p className="text-muted-foreground pt-2 text-[13px]">{tr("用手机相机扫左边的码，在 App 里打开就填好这三项。", "Scan the code with your phone's camera to open these three in the app.")}</p> : null}
          {d.host_fp ? (
            <p className="text-muted-foreground pt-2 text-[13px]">
              {tr(`主机钥匙（${d.home_name || "你的家"}的入口）：`, `Host key (${d.home_name || "your home"}'s entry): `)}<span className="font-mono break-all">{d.host_fp}</span>
            </p>
          ) : null}
          {d.shared ? (
            <p className="text-muted-foreground pt-1 text-[13px]">{tr("这条直连跟着家走：换家后它后面是新家那台机器，主机钥匙会不同——对上这里的指纹再接受。",
              "This direct way follows your home: after a home move it reaches the new machine, with another host key — accept it only when it matches the one here.")}</p>
          ) : null}
        </div>
      </div>
      {d.jump ? (
        <div className="flex flex-col gap-1 text-sm">
          <span className="text-muted-foreground text-[13px]">{tr("经门跳转（App 里的 Jump host，或电脑上直接 ssh）：", "Through the door's jump (an app's Jump host, or plain ssh):")}</span>
          <div className="flex min-h-11 items-center gap-2 rounded-lg border px-2">
            <span className="min-w-0 flex-1 truncate font-mono text-[13px]">{d.jump}</span>
            <CopyButton text={d.jump} />
          </div>
        </div>
      ) : null}
    </>
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{tr("用手机的终端连", "Connect from your phone's terminal")}</CardTitle>
        <CardDescription>{tr("Termius、Blink 这类 App 都行。先把手机的公钥加到「公钥」里，再照下面填。",
          "Termius, Blink or any SSH app. Add your phone's public key under Keys first, then fill these in.")}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {!v.name ? <NameForm suggested={v.suggested_name} domain={d.domain} done={reload} /> : null}
        {d.shared ? (
          <>
            <SharedWay s={d.shared} home={d.home_name} />
            <details className="text-sm">
              <summary className="text-primary cursor-pointer text-[13px]">{tr("高级：直连这台机器（路由器转发的地址、tailnet）", "Advanced: straight to this machine (a forwarded port, a tailnet)")}</summary>
              <div className="flex flex-col gap-4 pt-3">{direct}</div>
            </details>
          </>
        ) : direct}
        {!d.domain && !d.shared ? <Note tone="warn">{tr("这个入口还没设地址用的域名（设置 fleet.entry_domain）：请管理员配好。", "This hub has no address domain yet (the fleet.entry_domain setting); ask an admin.")}</Note> : null}
        <DoorState d={d} />
        <p className="text-muted-foreground text-[13px]">
          {tr("第一次连会问要不要信任主机钥匙：点 Accept。没装 App？", "The first connection asks to trust the host key: tap Accept. No app yet? ")}
          <a href="https://apps.apple.com/app/termius-terminal-ssh-client/id549039908" rel="noopener" className="text-primary underline-offset-4 hover:underline">{tr("在 App Store 装 Termius", "Get Termius on the App Store")}</a>
        </p>
        <p className="text-muted-foreground text-[13px]">{tr("连上后按 F12 或 ⌃] p（先按 Ctrl+]，再按 p）打开面板。在 Termius 键盘上方那一排（扩展键）里加一个 F12，点一下就开。",
          "Once connected, press F12 or ⌃] p (Ctrl+], then p) to open the panel. Add F12 to the extra-keys row above Termius's keyboard and one tap opens it.")}</p>
      </CardContent>
    </Card>
  );
};

// The door's one address (A5SQ): the same for everyone, the person's own login,
// the door's host key — a home move changes nothing on the phone.
const SharedWay: FC<{ s: Shared; home?: string }> = ({ s, home }) => {
  const rows: [string, string | number][] = [[tr("地址", "Host"), s.address], [tr("端口", "Port"), s.port], [tr("用户名", "User"), s.login]];
  return (
    <div className={cn("grid gap-4", s.qr ? "sm:grid-cols-[160px_1fr]" : "")}>
      {s.qr ? (
        <div className="mx-auto aspect-square w-40 overflow-hidden rounded-xl border bg-white p-1.5 sm:mx-0"><QR rows={s.qr} /></div>
      ) : null}
      <div className="flex min-w-0 flex-col text-sm">
        {rows.map(([k, val]) => (
          <div key={k} className="flex min-h-11 items-center gap-2 border-b py-1 last:border-b-0">
            <span className="text-muted-foreground w-16 shrink-0">{k}</span>
            <span className="min-w-0 flex-1 truncate font-mono">{val}</span>
            <CopyButton text={String(val)} />
          </div>
        ))}
        <p className="text-muted-foreground pt-2 text-[13px]">
          {home
            ? tr(`所有人都填这个地址，用户名填你自己的。会接到你的家（现在是 ${home}），换家不用改。`, `Everyone uses this address with their own user name. It takes you to your home (now ${home}); a home move changes nothing here.`)
            : tr("所有人都填这个地址，用户名填你自己的；换家不用改。", "Everyone uses this address with their own user name; a home move changes nothing here.")}
        </p>
        {s.host_fp ? (
          <p className="text-muted-foreground text-[13px]">
            {tr("主机钥匙（门的，不会变）：", "Host key (the door's, it never changes): ")}<span className="font-mono">{s.host_fp}</span>
          </p>
        ) : null}
      </div>
    </div>
  );
};

// ---- 公钥 ---------------------------------------------------------------------

const KeysTab: FC<{ entry: Read<Entry>; me: Me | null; reload: () => void; setAsk: (a: Ask) => void }> = ({ entry, me, reload, setAsk }) => {
  const [line, setLine] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ tone: "ok" | "bad"; text: string } | null>(null);
  if (entry.status === 404) return <DoorOff me={me} />;
  if (entry.loading && !entry.data) return <Loading n={1} />;
  if (!entry.data) return <Failed what={tr("公钥", "keys")} onRetry={entry.retry} />;
  const keys = (entry.data?.keys || []).filter((k) => !k.revoked_at);
  const add = async () => {
    // a private key never leaves the page
    if (/PRIVATE KEY|BEGIN OPENSSH/i.test(line)) { setMsg({ tone: "bad", text: tr("这是私钥：只贴公钥（以 ssh-ed25519 开头的一行）。私钥留在手机上。", "That's a private key: paste only the public one (the ssh-ed25519 line). Keep the private key on your phone.") }); return; }
    setBusy(true);
    const r = await sendJSON<EntryKey>("POST", ENTRY_KEYS, { public_key: line.trim() });
    setBusy(false);
    if (r.ok) {
      setLine("");
      // the same key again answers the one already there
      setMsg({ tone: "ok", text: !keys.some((k) => k.id === r.data?.id) ? tr("已加上。家机器正在为你打开入口，约 1 分钟。", "Added. Your home machine is opening the door for you — about a minute.") : tr("这把钥匙已经在你的列表里了。", "That key is already yours.") });
      reload();
    } else setMsg({ tone: "bad", text: refusal(r.error) });
  };
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">{tr("我的 SSH 公钥", "My SSH public keys")}</CardTitle>
        <CardDescription>{tr("加在这里的公钥，可以从手机直接连进你的会话。", "A key added here connects straight into your sessions from a phone.")}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {keys.length ? (
            <div className="divide-y">
              {keys.map((k) => (
                <Row key={k.id} icon={KeyRound} title={k.name || tr("（没起名）", "(unnamed)")}
                  sub={<span className="font-mono text-[12px]">{k.type.replace(/^ssh-/, "")} · {shortFP(k.fp)} · {tr(`上次用 ${ago(k.last_used)}`, `used ${ago(k.last_used)}`)}</span>}
                  end={<Button size="icon" variant="ghost" className="size-8" aria-label={tr("删掉", "Delete")} onClick={() => setAsk({
                    title: tr(`删掉「${k.name || shortFP(k.fp)}」？`, `Delete “${k.name || shortFP(k.fp)}”?`),
                    body: tr("几秒内家机器不再认它；正用它连着的入口连接也会断开（会话本身不受影响）。", "Within seconds your home machine stops accepting it, and a connection using it is closed (your sessions are unaffected)."),
                    yes: tr("删掉", "Delete"),
                    run: async () => { await sendJSON("DELETE", `${ENTRY_KEYS}/${encodeURIComponent(k.id)}`); reload(); },
                  })}><Trash2 className="size-4" /></Button>} />
              ))}
            </div>
          ) : <p className="text-muted-foreground text-sm">{tr("还没有公钥。", "No keys yet.")}</p>}
        <Separator />
        <Label htmlFor="pk">{tr("加一把公钥", "Add a public key")}</Label>
        <div className="flex gap-2">
          <Input id="pk" value={line} onChange={(e) => { setLine(e.target.value); setMsg(null); }} placeholder={tr("ssh-ed25519 AAAA… 我的手机", "ssh-ed25519 AAAA… my-phone")}
            className="font-mono text-[13px]" spellCheck={false} autoComplete="off" autoCapitalize="off" autoCorrect="off"
            onKeyDown={(e) => { if (e.key === "Enter" && line.trim()) add(); }} />
          <Button disabled={busy || !line.trim()} onClick={add}>{busy ? <LoaderCircle className="animate-spin" /> : <Plus />}{tr("加上", "Add")}</Button>
        </div>
        <p className="text-muted-foreground text-[13px]">{tr("在 Termius 的 Keychain 里点开手机那把钥匙，复制公钥贴到这里；行尾的备注就是它的名字。",
          "In Termius's Keychain open your phone's key, copy its public key and paste it here; the comment at the end becomes its name.")}</p>
        {msg ? <Note tone={msg.tone}>{msg.text}</Note> : null}
      </CardContent>
    </Card>
  );
};

// ---- 我的机器 -----------------------------------------------------------------

type Machine = { hostname: string; label: string; login: string; takes: "on" | "paused" | "maint" | "coord" | "lost"; load: number | null; sessions: number | null | undefined; version: string };
const TAKES_RANK = { on: 0, paused: 1, maint: 2, coord: 3, lost: 4 };
const takesOf = (n: Node): Machine["takes"] =>
  n.compute_off ? "coord" : n.status === "lost" ? "lost" : n.status === "maintenance" ? "maint" : n.admit === false ? "paused" : "on";
const TAKES: Record<Machine["takes"], [string, string, string]> = {
  on: ["正常", "Online", "text-ok border-ok/40"], paused: ["暂停接新会话", "Paused", "text-warn border-warn/50"],
  maint: ["维护中", "Maintenance", "text-warn border-warn/50"], coord: ["只协调", "Coordinates only", ""],
  lost: ["连不上", "Offline", "text-destructive border-destructive/40"],
};

// One row per machine of the person's (their logins on it), as 我的机器 drew it:
// a person's own laptop only coordinates; a client machine is a device, not here.
function myMachines(snap: Nodes | null, me: Me | null): Machine[] {
  const pairs = me?.logins?.length ? me.logins : null;
  const alias = new Map((snap?.machines || []).map((m) => [m.hostname, m.alias || ""]));
  const client = new Set((snap?.machines || []).filter((m) => m.role === "client").map((m) => m.hostname));
  const by = new Map<string, Node[]>();
  for (const n of snap?.nodes || []) {
    if (n.machine_link || client.has(n.hostname) || (pairs && !pairs.some((p) => p.machine === n.hostname && p.login === n.os_user))) continue;
    by.set(n.hostname, [...(by.get(n.hostname) || []), n]);
  }
  return [...by.entries()].map(([hostname, ns]) => {
    const best = ns.reduce((b, n) => (TAKES_RANK[takesOf(n)] < TAKES_RANK[takesOf(b)] ? n : b));
    const heard = ns.filter((n) => n.status !== "lost" && n.ncpu > 0 && !n.personal)
      .sort((a, b) => (Date.parse(b.last_heartbeat || "") || 0) - (Date.parse(a.last_heartbeat || "") || 0))[0];
    let sessions: number | null | undefined = null;
    for (const n of ns) {
      if (takesOf(n) === "coord" || sessions === undefined) continue;
      sessions = n.sessions == null ? undefined : (sessions || 0) + n.sessions;
    }
    return {
      hostname, label: alias.get(hostname) || hostname, login: [...new Set(ns.map((n) => n.os_user))].sort().join(" · "),
      takes: takesOf(best), load: heard ? (Number(heard.load1) || 0) / heard.ncpu : null, sessions,
      version: (ns.find((n) => n.fleet_version)?.fleet_version || "").slice(0, 7),
    };
  }).sort((a, b) => Number(a.takes === "coord") - Number(b.takes === "coord") || a.label.localeCompare(b.label));
}

const same = (a: string, b: string) => a.toLowerCase().split(".")[0] === b.toLowerCase().split(".")[0];

const Stat: FC<{ label: string; value: string }> = ({ label, value }) => (
  <Card className="gap-0 py-4">
    <CardContent className="px-4">
      <p className="text-muted-foreground text-xs">{label}</p>
      <p className="font-display mt-1 truncate text-xl font-semibold">{value}</p>
    </CardContent>
  </Card>
);

const HomeTab: FC<{ entry: Read<Entry>; me: Me | null; reload: () => void; setAsk: (a: Ask) => void }> = ({ entry, me, reload, setAsk }) => {
  const nodes = useLoad<Nodes>("/v1/nodes");
  const [moved, setMoved] = useState("");
  const machines = myMachines(nodes.data, me);
  const home = entry.data?.home || null;
  const door = entry.data?.door;
  const hm = home ? machines.find((m) => same(m.hostname, home.machine)) : undefined;
  const choices = entry.data?.home_choices || [];
  const homeOnline = home ? (choices.find((c) => same(c.machine, home.machine) && c.login === home.login)?.online ?? (hm ? hm.takes !== "lost" : false)) : false;
  const moveTo = (c: HomeChoice) => setAsk({
    title: tr(`把家换到 ${c.name || c.machine}？`, `Make ${c.name || c.machine} your home?`),
    body: tr("你的地址几分钟内指向它，对话也在它上面跑。和现在的家在同一个路由器后面时，要把路由器的公网端口转发改到新家（换完后这页会写出新家的局域网地址）；手机第一次连会说主机钥匙变了，核对这页的指纹后接受一次。",
      "Your address points to it within minutes and your conversation runs there. Behind the same router as your current home, point the router's public port forward at the new one (this page then shows its LAN address); your phone asks once to trust its new host key — check it against the fingerprint here."),
    yes: tr("换过去", "Move"),
    run: async () => {
      const r = await sendJSON("PUT", "/v1/fleet/entry/home", { machine: c.machine, login: c.login });
      setMoved(r.ok ? tr("已换家。你的地址几分钟内指向它。", "Home moved. Your address points to it within minutes.") : refusal(r.error));
      reload();
    },
  });
  return (
    <div className="flex flex-col gap-3">
      {entry.loading && !entry.data ? <Loading n={1} />
        : home ? (
          <>
            <Card>
              <CardContent className="flex items-center gap-3">
                <Server className="text-muted-foreground size-6 shrink-0" aria-hidden />
                <div className="min-w-0 flex-1">
                  <p className="font-display truncate text-lg font-semibold">{door?.home_name || hm?.label || home.machine}</p>
                  <p className="text-muted-foreground text-[13px]">{tr(`你的会话和对话都在这台机器上跑 · 登录 ${home.login}`, `Your sessions and conversation run here · login ${home.login}`)}</p>
                </div>
                <Badge variant="outline" className={cn("rounded-full", homeOnline ? TAKES.on[2] : TAKES.lost[2])}>{homeOnline ? tr("正常", "Online") : tr("连不上", "Offline")}</Badge>
              </CardContent>
            </Card>
            <div className="grid grid-cols-3 gap-3">
              <Stat label={tr("在跑会话", "Sessions")} value={hm?.sessions == null ? "—" : String(hm.sessions)} />
              <Stat label={tr("负载 / 核", "Load / core")} value={hm?.load == null ? "—" : hm.load.toFixed(2)} />
              <Stat label={tr("版本", "Version")} value={hm?.version || "—"} />
            </div>
          </>
        ) : entry.status === 200 ? (
          <Note tone="warn">{tr("你还没有家：家是你有登录、上面开着 fleet 的那台机器。先在一台机器上把 fleet 开起来，这里就会写出来。",
            "You have no home yet: it is a machine with your login and fleet running on it. Start fleet on one and it shows here.")}</Note>
        ) : null}
      {moved ? <Note>{moved}</Note> : null}
      {nodes.failed ? <Failed what={tr("机器", "machines")} onRetry={nodes.reload} /> : !nodes.data ? <Loading n={1} /> : <Card>
        <CardHeader>
          <CardTitle className="text-base">{tr("我的机器", "My machines")}</CardTitle>
          <CardDescription>{tr("你有登录的机器。家之外的那台只在家离线时临时接你。", "Machines you have a login on. One other than your home takes you only while your home is away.")}</CardDescription>
        </CardHeader>
        <CardContent>
          {machines.length ? (
              <div className="divide-y">
                {machines.map((m) => {
                  const isHome = !!home && same(m.hostname, home.machine);
                  const c = choices.find((x) => same(x.machine, m.hostname));
                  return (
                    <Row key={m.hostname} icon={Server} title={<>{m.label}{isHome ? <Badge variant="secondary" className="ms-2 rounded-full align-middle">{tr("家", "Home")}</Badge> : null}</>}
                      sub={[m.login, TAKES[m.takes][lang === "zh" ? 0 : 1], m.load == null ? "" : tr(`负载 ${m.load.toFixed(2)}/核`, `load ${m.load.toFixed(2)}/core`),
                        m.sessions == null ? "" : tr(`${m.sessions} 个会话`, `${m.sessions} sessions`)].filter(Boolean).join(" · ")}
                      end={!isHome && c && entry.status === 200 ? <Button size="sm" variant="outline" onClick={() => moveTo(c)}>{tr("设为家", "Make home")}</Button> : null} />
                  );
                })}
              </div>
            ) : <p className="text-muted-foreground text-sm">{tr("还没有你的机器：管理员给你开好登录后，它会出现在这里。", "No machine of yours yet: once an admin opens a login for you, it shows here.")}</p>}
        </CardContent>
      </Card>}
    </div>
  );
};

// ---- the page ---------------------------------------------------------------

const TABS: { id: string; icon: LucideIcon; label: string }[] = [
  { id: "pc", icon: Laptop, label: tr("电脑", "Computer") },
  { id: "phone", icon: Smartphone, label: tr("手机", "Phone") },
  { id: "keys", icon: KeyRound, label: tr("公钥", "Keys") },
  { id: "home", icon: Server, label: tr("我的机器", "Machines") },
];

export default function DevicesPage() {
  usePage(tr("设备", "Devices"));
  const { me } = useShell();
  const [qs, setQs] = useSearchParams();
  const tab = TABS.some((t) => t.id === qs.get("tab")) ? qs.get("tab")! : "pc";
  const [bump, setBump] = useState(0);
  const reload = useCallback(() => setBump((x) => x + 1), []);
  // the phone's door, the keys and the home are one book: read once, shared
  const entry = useBook<Entry>(ENTRY_KEYS, bump);
  const [ask, setAsk] = useState<Ask>(null);
  return (
    <div className="mx-auto flex w-full max-w-2xl flex-col px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("设备", "Devices")} sub={tr("在电脑和手机上连进来", "Connect from your computer and phone")} />
      <Tabs value={tab} onValueChange={(v) => setQs((q) => { const n = new URLSearchParams(q); n.set("tab", v); return n; }, { replace: true })}>
        <TabsList className="mb-1 grid w-full grid-cols-4 sm:inline-flex sm:w-auto">
          {TABS.map((t) => <TabsTrigger key={t.id} value={t.id} className="px-2"><t.icon />{t.label}</TabsTrigger>)}
        </TabsList>
        <TabsContent value="pc"><PcTab setAsk={setAsk} /></TabsContent>
        <TabsContent value="phone"><PhoneTab entry={entry} me={me} reload={reload} /></TabsContent>
        <TabsContent value="keys"><KeysTab entry={entry} me={me} reload={reload} setAsk={setAsk} /></TabsContent>
        <TabsContent value="home"><HomeTab entry={entry} me={me} reload={reload} setAsk={setAsk} /></TabsContent>
      </Tabs>
      <Confirm ask={ask} close={() => setAsk(null)} />
    </div>
  );
}
