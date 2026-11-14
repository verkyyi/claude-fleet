// oauth-consent.tsx — 授权 Agent (T4DN): where the hub's /oauth/authorize sends
// a signed-in person's browser, carrying the agent's whole OAuth request. One
// card, no sidebar (main.tsx draws it outside the shell, like a sign-in page):
// who asks (GET /v1/me/oauth/request?<query>), what it may do (read locked on,
// answer ticked only when asked, with its warning), for how long, 拒绝 | 允许
// (POST /v1/me/oauth/approve) — then the browser goes where the hub says. A
// request the hub refuses is said plainly, with no buttons. The query is sent
// back VERBATIM: the hub checks the very string it handed out.
//
// An unverified agent (registered by itself, kind dcr: its name is whatever
// it says) is led by where it sends the person back to, not by its name; the
// page says it is unverified, its boxes start at read alone with what it asked
// marked beside each, and its expiry offers no more than the hub's max_days.
// A metadata-document agent (kind cimd) is led by the host its document is
// served from — what the hub checked — its name shown as that site's own word;
// one at a host the hub does not list (verified false) also starts at read
// alone, with a note saying the hub does not know it.
import { useEffect, useState } from "react";
import { CircleAlert, LoaderCircle, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { BRAND } from "@/shared/brand";
import { lang, tr } from "@/shared/i18n";
import { sendJSON, useMe } from "@/shared/api";
import { Wordmark } from "@/shared/Wordmark";
import { DEFAULT_DAYS, PERMS, consentPerms, rawQuery, redirectHost } from "../agents";
import { ExpirySelect, PermBoxes } from "../agent-parts";

type Ask = {
  client: { id: string; name: string; kind: "cimd" | "dcr"; host: string };
  redirect_uri: string; permissions?: string[]; all_permissions?: string[]; days?: number;
  max_days?: number; verified?: boolean;
};
// an older hub sends no verified: the kind alone says it
const isVerified = (a: Ask) => a.verified ?? a.client.kind !== "dcr";
type Read = { ask: Ask } | { error: string } | null;

const plain = (j: { error?: string; error_description?: string } | null) =>
  j?.error_description || j?.error || tr("这个授权请求无效。", "This authorization request isn't valid.");

export default function OAuthConsentPage() {
  const query = rawQuery(location.search);
  const { me } = useMe();
  const [read, setRead] = useState<Read>(null);
  const [perms, setPerms] = useState<string[]>([]);
  const [days, setDays] = useState(DEFAULT_DAYS);
  const [busy, setBusy] = useState<"" | "allow" | "deny">("");
  const [err, setErr] = useState("");
  useEffect(() => { document.title = `${tr("授权 Agent", "Authorize an agent")} · ${BRAND}`; }, []);
  useEffect(() => {
    let live = true;
    fetch(`/v1/me/oauth/request?${query}`, { headers: { Accept: "application/json" } }).catch(() => null).then(async (r) => {
      if (r?.status === 401) { location.assign("/app/signin"); return; }
      const j = r ? await r.json().catch(() => null) : null;
      if (!live) return;
      if (r?.ok && j?.client) {
        const ask = j as Ask;
        setRead({ ask });
        setPerms(consentPerms(ask.permissions, isVerified(ask), ask.all_permissions?.length ? ask.all_permissions : PERMS));
        setDays(ask.days || DEFAULT_DAYS);
      } else setRead({ error: r ? plain(j) : tr("入口暂时没有回应，请稍后刷新。", "The hub isn't answering; refresh in a moment.") });
    });
    return () => { live = false; };
  }, [query]);

  const decide = async (approve: boolean) => {
    setBusy(approve ? "allow" : "deny"); setErr("");
    const r = await sendJSON<{ redirect: string }>("POST", "/v1/me/oauth/approve", { query, permissions: perms, days, approve });
    if (r.ok && r.data?.redirect) { window.location.assign(r.data.redirect); return; }
    setBusy("");
    setErr(r.ok ? tr("没拿到返回地址，请重试。", "No address to return to; try again.")
      : (lang === "zh" && r.error) || r.error || tr("没成功，稍后再试。", "That didn't work; try again."));
  };

  const who = me?.name || me?.login || "";
  const ask = read && "ask" in read ? read.ask : null;
  const verified = ask ? isVerified(ask) : true;
  const back = ask ? redirectHost(ask.redirect_uri) : { host: "", local: false };
  return (
    <main className="bg-background flex min-h-dvh items-start justify-center px-4 py-8 sm:items-center">
      <div className="grid w-full max-w-md gap-5">
        <Wordmark className="mx-auto h-[18px]" />
        <Card>
          {!read ? (
            <CardContent className="grid gap-3" aria-busy="true">
              <Skeleton className="h-6 w-3/4" /><Skeleton className="h-4 w-1/2" />
              <Skeleton className="h-10 w-full" /><Skeleton className="h-10 w-full" /><Skeleton className="h-10 w-full" />
            </CardContent>
          ) : "error" in read ? (
            <CardContent className="flex items-start gap-3">
              <CircleAlert className="text-destructive mt-0.5 size-5 shrink-0" aria-hidden />
              <div className="min-w-0">
                <p className="font-medium">{tr("无法授权", "Can't authorize")}</p>
                <p role="alert" className="text-muted-foreground mt-1 text-sm break-words">{read.error}</p>
              </div>
            </CardContent>
          ) : ask ? (
            <>
              {ask.client.kind === "cimd" && ask.client.host ? (
                <CardHeader className="grid gap-3">
                  {verified ? null : (
                    <p role="note" className="border-warn/50 bg-warn/10 flex items-start gap-2 rounded-lg border px-3 py-2 text-[13px] leading-relaxed">
                      <TriangleAlert className="text-warn mt-0.5 size-4 shrink-0" aria-hidden />
                      <span><b>{tr("不在已知名单上", "Not on this hub's known list")}</b>{" — "}{tr(
                        `${BRAND} 只核对了它的资料来自下面这个网站，并不认识这个网站。只有在你刚刚亲手连接它时才允许。`,
                        `${BRAND} only checked that its details come from the site below; it doesn't know that site. Only allow if you just connected it yourself.`)}</span>
                    </p>
                  )}
                  <CardTitle className="font-display text-xl leading-snug">
                    {tr(`一个应用想以你的身份使用 ${BRAND}`, `An app wants to use ${BRAND} as you`)}
                  </CardTitle>
                  <div className="grid gap-1">
                    <p className="text-muted-foreground text-xs">{tr("应用资料所在的网站", "The site its details come from")}</p>
                    <p className="font-mono text-lg font-semibold break-all">{ask.client.host}</p>
                  </div>
                  <CardDescription className="break-words">
                    {ask.client.name && ask.client.name !== ask.client.host
                      ? tr(`名称「${ask.client.name}」由 ${ask.client.host} 提供`, `Name “${ask.client.name}” as given by ${ask.client.host}`) : null}
                    {who ? <>{ask.client.name && ask.client.name !== ask.client.host ? " · " : ""}{tr(`登录身份：${who}`, `signed in as ${who}`)}</> : null}
                  </CardDescription>
                </CardHeader>
              ) : verified ? (
                <CardHeader>
                  <CardTitle className="font-display text-xl leading-snug">
                    {tr(`「${ask.client.name}」想以你的身份使用 ${BRAND}`, `${ask.client.name} wants to use ${BRAND} as you`)}
                  </CardTitle>
                  <CardDescription className="break-words">
                    {ask.client.host ? <span className="font-mono">{ask.client.host}</span> : null}
                    {who ? <>{ask.client.host ? " · " : ""}{tr(`登录身份：${who}`, `signed in as ${who}`)}</> : null}
                  </CardDescription>
                </CardHeader>
              ) : (
                <CardHeader className="grid gap-3">
                  <p role="note" className="border-warn/50 bg-warn/10 flex items-start gap-2 rounded-lg border px-3 py-2 text-[13px] leading-relaxed">
                    <TriangleAlert className="text-warn mt-0.5 size-4 shrink-0" aria-hidden />
                    <span><b>{tr("未验证的应用", "Unverified app")}</b>{" — "}{tr(
                      `它的名字是它自己报的，${BRAND} 无法确认是谁做的。只有在你刚刚亲手连接它时才允许。`,
                      `the name below is self-reported; ${BRAND} can't confirm who made it. Only allow if you just connected it yourself.`)}</span>
                  </p>
                  <CardTitle className="font-display text-xl leading-snug">
                    {tr(`一个应用想以你的身份使用 ${BRAND}`, `An app wants to use ${BRAND} as you`)}
                  </CardTitle>
                  <div className="grid gap-1">
                    <p className="text-muted-foreground text-xs">{tr("授权后会把你送回", "Approving sends you back to")}</p>
                    <p className="font-mono text-lg font-semibold break-all">{back.host || ask.redirect_uri}</p>
                    {back.local ? <p className="text-muted-foreground text-xs">{tr("这台电脑上运行的程序", "a program running on this computer")}</p> : null}
                  </div>
                  <CardDescription className="break-words">
                    {ask.client.name ? tr(`自称「${ask.client.name}」（名字由它自己填写）`, `Calls itself “${ask.client.name}” (name given by the app itself)`) : null}
                    {who ? <>{ask.client.name ? " · " : ""}{tr(`登录身份：${who}`, `signed in as ${who}`)}</> : null}
                  </CardDescription>
                </CardHeader>
              )}
              <CardContent className="grid gap-4">
                <PermBoxes all={ask.all_permissions?.length ? ask.all_permissions : PERMS} value={perms} onChange={setPerms} disabled={!!busy}
                  asked={verified ? undefined : ask.permissions} />
                <ExpirySelect value={days} onChange={setDays} disabled={!!busy} max={ask.max_days} />
                <p className="text-muted-foreground text-[12.5px] leading-relaxed">
                  {tr("随时可以在「我的 · Agent」里收回。", "You can revoke it any time under Me · Agents.")}
                </p>
                {err ? <p role="alert" className="text-destructive text-sm">{err}</p> : null}
              </CardContent>
              <CardFooter className="grid grid-cols-2 gap-2">
                <Button variant="outline" className="h-11 md:h-10" disabled={!!busy} onClick={() => void decide(false)}>
                  {busy === "deny" ? <LoaderCircle className="animate-spin" /> : null}{tr("拒绝", "Deny")}
                </Button>
                <Button className="h-11 md:h-10" disabled={!!busy} onClick={() => void decide(true)}>
                  {busy === "allow" ? <LoaderCircle className="animate-spin" /> : null}{tr("允许", "Allow")}
                </Button>
              </CardFooter>
            </>
          ) : null}
        </Card>
      </div>
    </main>
  );
}
