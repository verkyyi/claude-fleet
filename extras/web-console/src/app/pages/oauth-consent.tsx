// oauth-consent.tsx — 授权 Agent (T4DN): where the hub's /oauth/authorize sends
// a signed-in person's browser, carrying the agent's whole OAuth request. One
// card, no sidebar (main.tsx draws it outside the shell, like a sign-in page):
// who asks (GET /v1/me/oauth/request?<query>), what it may do (read locked on,
// answer ticked only when asked, with its warning), for how long, 拒绝 | 允许
// (POST /v1/me/oauth/approve) — then the browser goes where the hub says. A
// request the hub refuses is said plainly, with no buttons. The query is sent
// back VERBATIM: the hub checks the very string it handed out.
import { useEffect, useState } from "react";
import { CircleAlert, LoaderCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardFooter, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { BRAND } from "@/shared/brand";
import { lang, tr } from "@/shared/i18n";
import { sendJSON, useMe } from "@/shared/api";
import { Wordmark } from "@/shared/Wordmark";
import { DEFAULT_DAYS, PERMS, initialPerms, rawQuery } from "../agents";
import { ExpirySelect, PermBoxes } from "../agent-parts";

type Ask = {
  client: { id: string; name: string; kind: "cimd" | "dcr"; host: string };
  redirect_uri: string; permissions?: string[]; all_permissions?: string[]; days?: number;
};
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
        setPerms(initialPerms(ask.permissions, ask.all_permissions?.length ? ask.all_permissions : PERMS));
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
              <CardHeader>
                <CardTitle className="font-display text-xl leading-snug">
                  {tr(`「${ask.client.name}」想以你的身份使用 ${BRAND}`, `${ask.client.name} wants to use ${BRAND} as you`)}
                </CardTitle>
                <CardDescription className="break-words">
                  {ask.client.host ? <span className="font-mono">{ask.client.host}</span> : null}
                  {who ? <>{ask.client.host ? " · " : ""}{tr(`登录身份：${who}`, `signed in as ${who}`)}</> : null}
                </CardDescription>
              </CardHeader>
              <CardContent className="grid gap-4">
                <PermBoxes all={ask.all_permissions?.length ? ask.all_permissions : PERMS} value={perms} onChange={setPerms} disabled={!!busy} />
                <ExpirySelect value={days} onChange={setDays} disabled={!!busy} />
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
