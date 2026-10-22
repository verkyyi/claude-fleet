// Administrator-owned browser sign-in. Secrets live only in the input/request,
// never in a URL or browser storage. A closed dialog ignores late responses.
// Claude comes in one way only: the token `claude setup-token` prints, pasted
// here and probed by the hub before it is saved (HXNB); the web sign-in is Codex's.
import * as React from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { api } from "../api";
import { t } from "../i18n";
import { LABEL_RE, type Prov } from "../pool";

const BASE = "/v1/admin/subscriptions";
type Flow = { flow: string; authorize_url: string; paste: string; expires_at: string };
type Answer = { account: string; quota: "ready" | "pending"; duplicate?: boolean };

// primary: the update is the thing to do now (a subscription that needs a new sign-in, FKS6)
export function AddSubscriptionDialog(p: { known: string[]; onAdded: () => void; replace?: { provider: Prov; account: string }; primary?: boolean; size?: "sm" | "default" }) {
  const [open, setOpen] = React.useState(false);
  const [prov, setProv] = React.useState<Prov>(p.replace?.provider || "claude");
  const [label, setLabel] = React.useState(p.replace?.account || "");
  const [mode, setMode] = React.useState("login");
  const [secret, setSecret] = React.useState("");
  const [flow, setFlow] = React.useState<Flow | null>(null);
  const [answer, setAnswer] = React.useState<Answer | null>(null);
  const [err, setErr] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const epoch = React.useRef(0);
  const how = prov === "claude" ? "token" : mode;
  const fid = React.useId();
  const changeOpen = (o: boolean) => {
    epoch.current++;
    setOpen(o); setSecret(""); setFlow(null); setAnswer(null); setErr(""); setBusy(false);
    setLabel(p.replace?.account || ""); setProv(p.replace?.provider || "claude"); setMode("login");
  };
  React.useEffect(() => () => { epoch.current++; }, []);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (busy) return;
    const account = label.trim();
    if (!LABEL_RE.test(account)) return setErr(t("pool.add.badLabel"));
    if (!p.replace && p.known.includes(`${prov}/${account}`)) return setErr(t("pool.web.exists"));
    const generation = epoch.current;
    const value = secret;
    setSecret(""); setBusy(true); setErr("");
    try {
      if (how === "login" && !flow) {
        const result = await api<Flow>(BASE + "/login", { json: { provider: prov, account, again: !!p.replace } });
        if (generation === epoch.current) setFlow(result);
      } else {
        const result = await api<Answer>(BASE + (flow ? "/login/finish" : "/token"), {
          json: flow ? { flow: flow.flow, paste: value } : { provider: prov, account, token: value, again: !!p.replace },
        });
        p.onAdded();
        if (generation === epoch.current) { setAnswer(result); setFlow(null); }
      }
    } catch (e) {
      if (generation === epoch.current) setErr((e as Error).message);
    } finally {
      if (generation === epoch.current) setBusy(false);
    }
  };
  return <Dialog open={open} onOpenChange={changeOpen}>
    <DialogTrigger asChild><Button size={p.size} variant={p.replace && !p.primary ? "outline" : "default"}>{!p.replace && <Plus />}{t(p.replace ? "pool.web.update" : "pool.add")}</Button></DialogTrigger>
    <DialogContent className="sm:max-w-lg">
      <DialogHeader><DialogTitle>{t(p.replace ? "pool.web.update" : "pool.add.title")}</DialogTitle><DialogDescription>{t(prov === "claude" ? "pool.web.descriptionClaude" : "pool.web.description")}</DialogDescription></DialogHeader>
      {answer ? <div className="grid gap-4" role="status">
        <p>{t("pool.add.inPool", { label: answer.account })}</p>
        {answer.duplicate && <p>{t("pool.web.duplicate")}</p>}
        <p>{t(answer.quota === "ready" ? "pool.web.ready" : "pool.web.pending")}</p>
        <Button onClick={() => changeOpen(false)}>{t("pool.add.done")}</Button>
      </div> : <form onSubmit={submit} className="grid gap-4">
        {!flow && <>
          <Label htmlFor={fid + "provider"}>{t("pool.col.service")}</Label>
          <select id={fid + "provider"} value={prov} disabled={busy || !!p.replace} onChange={e => setProv(e.target.value as Prov)} className="rounded-md border p-2">
            <option value="claude">Claude Code</option><option value="codex">Codex</option>
          </select>
          <Label htmlFor={fid}>{t("pool.add.label")}</Label>
          <Input id={fid} value={label} disabled={busy || !!p.replace} onChange={e => setLabel(e.target.value)} autoComplete="off" />
          {p.replace && <p className="text-sm text-muted-foreground">{t("pool.web.replaceHint", { label })}</p>}
          {prov === "codex" && <>
            <Label htmlFor={fid + "mode"}>{t("pool.web.method")}</Label>
            <select id={fid + "mode"} value={mode} disabled={busy} onChange={e => { setMode(e.target.value); setSecret(""); setErr(""); }} className="rounded-md border p-2">
              <option value="login">{t("pool.web.login")}</option><option value="token">{t("pool.web.token")}</option>
            </select>
          </>}
          {prov === "claude" && <p className="text-sm text-muted-foreground">{t("pool.web.setupTokenHow")}</p>}
        </>}
        {flow && <>
          <Button asChild variant="outline"><a href={flow.authorize_url} target="_blank" rel="noopener noreferrer">{t("pool.web.open")}</a></Button>
          <p className="text-sm text-muted-foreground">{t(flow.paste === "url" ? "pool.web.pasteURL" : "pool.web.pasteCode")}</p>
          <p className="text-xs text-muted-foreground">{t("pool.web.expires", { when: new Date(flow.expires_at).toLocaleTimeString() })}</p>
        </>}
        {(flow || how === "token") && <>
          <Label htmlFor={fid + "secret"}>{t(flow ? "pool.web.code" : prov === "codex" ? "pool.web.refreshToken" : "pool.web.setupToken")}</Label>
          <Input id={fid + "secret"} type="password" value={secret} onChange={e => setSecret(e.target.value)} disabled={busy} autoComplete="off" spellCheck={false} placeholder={!flow && prov === "claude" ? "sk-ant-oat01-…" : undefined} required />
          <p className="text-xs text-muted-foreground">{t("pool.web.secretHint")}</p>
        </>}
        {err && <p role="alert" className="text-sm text-destructive">{err}</p>}
        <DialogFooter>
          <Button type="button" variant="ghost" onClick={() => changeOpen(false)}>{t("confirm.cancel")}</Button>
          {flow && <Button type="button" variant="outline" disabled={busy} onClick={() => { setFlow(null); setSecret(""); setErr(""); }}>{t("pool.web.restart")}</Button>}
          <Button type="submit" disabled={busy}>{t(busy ? "pool.web.busy" : flow || how === "token" ? "pool.web.submit" : "pool.add.continue")}</Button>
        </DialogFooter>
      </form>}
    </DialogContent>
  </Dialog>;
}
