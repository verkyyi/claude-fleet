// agents.tsx — 我的 · Agent (T4DN): the outside agents a person lets into
// their Tokenman — Claude Code, Codex, Gemini CLI, claude.ai — over the hub's
// MCP door. One list (GET /v1/me/agents: key or browser sign-in, what each may
// do, when it was last used, when it lapses), 连接 (POST /v1/me/agents: the key
// is shown ONCE, with that agent's snippet) and 收回 (POST …/revoke). Only the
// person's own: the hub cuts every read to them. Stock shadcn/ui only.
import { useState, type FC, type FormEvent } from "react";
import { Bot, Globe, KeyRound, LoaderCircle, Plus } from "lucide-react";
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
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { cn } from "@/lib/utils";
import { lang, tr } from "@/shared/i18n";
import { sendJSON, useLoad } from "@/shared/api";
import { usePage } from "../Shell";
import { ago, Empty, Failed, Loading, PageHeader } from "../parts";
import {
  CLIENTS, DEFAULT_DAYS, OAUTH_CLIENTS, PERMS, clientName, expiresText, initialPerms, permLabel, snippetFor,
  type Agent, type AgentCreated, type AgentList, type Client,
} from "../agents";
import { CopyButton, CopyLine, ExpirySelect, PermBoxes } from "../agent-parts";

const LIST = "/v1/me/agents";

// The hub says why it refused, in Chinese; an English page says it plainly.
const refusal = (error: string) => (lang === "zh" && error ? error : tr("没成功，稍后再试。", "That didn't work; try again."));

const used = (a: Agent) => (a.last_call_at ? tr(`${ago(a.last_call_at)}用过`, `used ${ago(a.last_call_at)}`) : tr("还没用过", "never used"));

const AgentRow: FC<{ a: Agent; onRevoke: () => void }> = ({ a, onRevoke }) => (
  <div className="flex items-start gap-3 py-3 first:pt-0 last:pb-0">
    {a.kind === "oauth" ? <Globe className="text-muted-foreground mt-0.5 size-5 shrink-0" aria-hidden /> : <KeyRound className="text-muted-foreground mt-0.5 size-5 shrink-0" aria-hidden />}
    <div className="min-w-0 flex-1">
      <p className="truncate font-medium">{a.name || clientName(a.client)}</p>
      <p className="text-muted-foreground truncate text-[13px]">
        {clientName(a.client)} · {a.kind === "oauth" ? tr("浏览器登录", "browser sign-in") : tr("密钥", "key")} · {used(a)} · {expiresText(a.expires_at)}
      </p>
      <div className="mt-1.5 flex flex-wrap gap-1">
        {a.permissions.map((p) => <Badge key={p} variant="secondary" className="font-normal">{permLabel(p)}</Badge>)}
      </div>
    </div>
    <Button size="sm" variant="ghost" className="text-destructive hover:text-destructive shrink-0" onClick={onRevoke}>{tr("收回", "Revoke")}</Button>
  </div>
);

export default function AgentsPage() {
  usePage(tr("Agent 连接", "Agents"));
  const list = useLoad<AgentList>(LIST);
  const [open, setOpen] = useState(false);
  const [cut, setCut] = useState<Agent | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const agents = list.data?.agents || [];
  const all = list.data?.permissions?.length ? list.data.permissions : PERMS;
  const mcp = list.data?.mcp_url || "";
  const connect = (
    <Button size="sm" onClick={() => setOpen(true)} disabled={!list.data}><Plus />{tr("连接 Agent", "Connect an agent")}</Button>
  );
  const revoke = async () => {
    if (!cut) return;
    setBusy(true);
    const r = await sendJSON<{ revoked: boolean }>("POST", "/v1/me/agents/revoke", { id: cut.id });
    setBusy(false);
    if (!r.ok) { setErr(refusal(r.error)); return; }
    setCut(null);
    list.reload();
  };
  return (
    <div className="mx-auto w-full max-w-2xl px-4 py-5 md:px-6 md:py-8">
      <PageHeader title={tr("已连接的 Agent", "Connected agents")}
        sub={tr("让 Claude Code、Codex、Gemini CLI、claude.ai 等 Agent 看你的会话、替你发消息。", "Let Claude Code, Codex, Gemini CLI, claude.ai and others see your sessions and talk to them for you.")}
        action={agents.length ? connect : undefined} />
      {list.failed ? <Failed what={tr("已连接的 Agent", "your connected agents")} onRetry={list.reload} />
        : !list.data ? <Loading n={2} />
        : agents.length ? (
          <Card><CardContent><div className="divide-y">
            {agents.map((a) => <AgentRow key={a.id} a={a} onRevoke={() => { setErr(""); setCut(a); }} />)}
          </div></CardContent></Card>
        ) : (
          <Card><CardContent>
            <Empty icon={<Bot />} title={tr("还没有 Agent 连上来", "No agent connected yet")}
              body={tr("连上以后，你在电脑上用的 Agent 可以通过 Tokenman 查看和操作你的会话，权限由你来定。",
                "Once connected, an agent you use elsewhere can see and work your Tokenman sessions — with the permissions you choose.")}
              action={connect} />
          </CardContent></Card>
        )}
      {mcp ? (
        <Card className="mt-3">
          <CardHeader>
            <CardTitle className="text-base">{tr("MCP 地址", "MCP address")}</CardTitle>
            <CardDescription>{tr("claude.ai、Claude Code、Gemini CLI 可以直接添加这个地址，用浏览器登录授权，不用密钥。",
              "claude.ai, Claude Code and Gemini CLI can just add this address and sign in in a browser — no key needed.")}</CardDescription>
          </CardHeader>
          <CardContent><CopyLine text={mcp} /></CardContent>
        </Card>
      ) : null}
      <ConnectDialog open={open} onOpenChange={setOpen} all={all} mcp={mcp} onCreated={list.reload} />
      <AlertDialog open={!!cut} onOpenChange={(o) => !o && !busy && setCut(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{tr(`收回「${cut?.name || ""}」？`, `Revoke “${cut?.name || ""}”?`)}</AlertDialogTitle>
            <AlertDialogDescription>{tr("它会立刻失去对你会话的访问；要再用得重新连接。", "It loses access to your sessions at once; connect it again to use it.")}</AlertDialogDescription>
          </AlertDialogHeader>
          {err ? <p role="alert" className="text-destructive text-sm">{err}</p> : null}
          <AlertDialogFooter>
            <AlertDialogCancel disabled={busy}>{tr("先不", "Not now")}</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={busy} onClick={(e) => { e.preventDefault(); void revoke(); }}>
              {busy ? <LoaderCircle className="animate-spin" /> : null}{tr("收回", "Revoke")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

// 连接 Agent: pick it, name it, tick what it may do, how long → the key once
// and that agent's snippet. claude.ai takes no key: its URL and a browser sign-in.
const ConnectDialog: FC<{ open: boolean; onOpenChange: (o: boolean) => void; all: readonly string[]; mcp: string; onCreated: () => void }> = ({ open, onOpenChange, all, mcp, onCreated }) => {
  const [client, setClient] = useState<Client>("claude-code");
  const [name, setName] = useState("");
  const [perms, setPerms] = useState<string[]>(() => initialPerms(undefined, all));
  const [days, setDays] = useState(DEFAULT_DAYS);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [made, setMade] = useState<AgentCreated | null>(null);
  const reset = () => { setClient("claude-code"); setName(""); setPerms(initialPerms(undefined, all)); setDays(DEFAULT_DAYS); setErr(""); setMade(null); };
  const close = (o: boolean) => { if (busy) return; onOpenChange(o); if (!o) reset(); };
  const url = made?.mcp_url || mcp;
  const browserOnly = client === "claude-ai";
  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setErr("");
    const r = await sendJSON<AgentCreated>("POST", LIST, { name: name.trim() || clientName(client), client, permissions: perms, days });
    setBusy(false);
    if (!r.ok) { setErr(refusal(r.error)); return; }
    setMade(r.data);
    onCreated();
  };
  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{made ? tr("连好了", "Connected") : tr("连接一个 Agent", "Connect an agent")}</DialogTitle>
          <DialogDescription>{made
            ? tr("密钥只显示这一次，关掉就看不到了。像密码一样保管它。", "The key is shown this once — close this and it's gone. Keep it like a password.")
            : tr("选你用的 Agent，给它你愿意给的权限。", "Pick the agent you use and give it only what you want it to do.")}</DialogDescription>
        </DialogHeader>
        {made ? (
          <div className="grid min-w-0 gap-4">
            <div className="grid gap-2">
              <Label>{tr("密钥", "Key")}</Label>
              <CopyLine text={made.key} />
            </div>
            {snippetFor(made.agent.client || client, made.snippets) ? (
              <div className="grid gap-2">
                <div className="flex items-center justify-between gap-2">
                  <Label>{tr(`在 ${clientName(made.agent.client || client)} 里这样配置`, `Set it up in ${clientName(made.agent.client || client)}`)}</Label>
                  <CopyButton text={snippetFor(made.agent.client || client, made.snippets)} label={tr("复制", "Copy")} />
                </div>
                <pre className="bg-muted/60 max-h-56 overflow-auto rounded-lg border p-3 font-mono text-[12px] leading-relaxed whitespace-pre">{snippetFor(made.agent.client || client, made.snippets)}</pre>
              </div>
            ) : null}
            {url ? <OAuthNote url={url} /> : null}
            <DialogFooter><Button onClick={() => close(false)}>{tr("完成", "Done")}</Button></DialogFooter>
          </div>
        ) : (
          <form onSubmit={create} className="grid min-w-0 gap-4">
            <RadioGroup value={client} onValueChange={(v) => setClient(v as Client)} className="grid grid-cols-2 gap-2" aria-label={tr("Agent", "Agent")}>
              {CLIENTS.map((c) => (
                <Label key={c.id} className="has-[[data-state=checked]]:border-clay-line has-[[data-state=checked]]:bg-clay-soft flex cursor-pointer items-center gap-3 rounded-lg border p-3 font-normal">
                  <RadioGroupItem value={c.id} />
                  <span className="font-medium">{c.name}</span>
                </Label>
              ))}
            </RadioGroup>
            {browserOnly ? (
              <>
                <OAuthNote url={url} only />
                <DialogFooter><Button type="button" onClick={() => close(false)}>{tr("完成", "Done")}</Button></DialogFooter>
              </>
            ) : (
              <>
                <div className="grid gap-2">
                  <Label htmlFor="agent-name">{tr("名字", "Name")}</Label>
                  <Input id="agent-name" value={name} placeholder={clientName(client)} onChange={(e) => setName(e.target.value)} maxLength={60} autoComplete="off" />
                </div>
                <PermBoxes all={all} value={perms} onChange={setPerms} disabled={busy} />
                <ExpirySelect value={days} onChange={setDays} disabled={busy} />
                {OAUTH_CLIENTS.includes(client) && url ? <OAuthNote url={url} /> : null}
                {err ? <p role="alert" className="text-destructive text-sm">{err}</p> : null}
                <DialogFooter>
                  <Button type="button" variant="ghost" onClick={() => close(false)} disabled={busy}>{tr("取消", "Cancel")}</Button>
                  <Button type="submit" disabled={busy}>{busy ? <LoaderCircle className="animate-spin" /> : null}{tr("生成密钥", "Create key")}</Button>
                </DialogFooter>
              </>
            )}
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
};

// claude.ai / Claude Code / Gemini CLI can skip the key: add the URL, sign in in a browser.
const OAuthNote: FC<{ url: string; only?: boolean }> = ({ url, only }) => (
  <div className={cn("grid gap-2 rounded-lg border p-3", only ? "" : "bg-muted/40")}>
    <p className="text-muted-foreground text-[13px] leading-relaxed">{only
      ? tr("claude.ai 不用密钥：在它的「连接器」里添加下面这个地址，然后在浏览器里登录 Tokenman、确认权限就好。",
        "claude.ai needs no key: add this address under its Connectors, then sign in to Tokenman in the browser and confirm the permissions.")
      : tr("也可以不用密钥：claude.ai、Claude Code、Gemini CLI 直接添加这个地址，用浏览器登录授权。",
        "Or skip the key: claude.ai, Claude Code and Gemini CLI can add this address and sign in in a browser.")}</p>
    {url ? <CopyLine text={url} /> : null}
  </div>
);
