// NewPersonDialog — 开号 / 邀请, the two calls the old users page made
// (claude-fleet#1990, #2261): a GitHub username gets an account at once
// (POST /v1/fleet/users); anyone else gets an invite (POST /v1/fleet/invites),
// its command shown this once.
import * as React from "react";
import { Check, Copy, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { api, type InviteCreated, type UsersList } from "../api";
import { t, when } from "../i18n";

export const GH_LOGIN_RE = /^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,38}$/i;
export const cleanLogin = (s: string) =>
  String(s || "")
    .trim()
    .replace(/^https?:\/\/github\.com\//i, "")
    .replace(/^@/, "")
    .replace(/\/+$/, "");
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function NewPersonDialog(p: { known: string[]; onChanged: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [tab, setTab] = React.useState("add");
  const [login, setLogin] = React.useState("");
  const [forWho, setForWho] = React.useState("");
  const [err, setErr] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const [minted, setMinted] = React.useState<InviteCreated | null>(null);
  const [copied, setCopied] = React.useState(false);

  const reset = () => {
    setLogin("");
    setForWho("");
    setErr("");
    setMinted(null);
    setCopied(false);
  };

  const add = async (e: React.FormEvent) => {
    e.preventDefault();
    const l = cleanLogin(login);
    if (!GH_LOGIN_RE.test(l)) return setErr(t("new.loginBad"));
    if (p.known.some((k) => k.toLowerCase() === l.toLowerCase())) return setErr(t("new.loginHave", { login: l }));
    setBusy(true);
    try {
      const out = await api<UsersList>("/v1/fleet/users", { json: { login: l } });
      toast.success(t("new.added", { login: out.added || l, id: out.github_id || "—" }));
      p.onChanged();
      setOpen(false);
      reset();
    } catch (e) {
      setErr(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  const invite = async (e: React.FormEvent) => {
    e.preventDefault();
    const w = forWho.trim();
    let json: Record<string, string> = {};
    if (w && EMAIL_RE.test(w)) json = { email: w };
    else if (w && GH_LOGIN_RE.test(cleanLogin(w))) json = { github_login: cleanLogin(w) };
    else if (w) return setErr(t("new.inviteForBad"));
    setBusy(true);
    try {
      setMinted(await api<InviteCreated>("/v1/fleet/invites", { json }));
      setErr("");
      p.onChanged();
    } catch (e) {
      setErr(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) reset();
      }}
    >
      <DialogTrigger asChild>
        <Button>
          <Plus />
          {t("people.new")}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t("new.title")}</DialogTitle>
          <DialogDescription>{t("new.sub")}</DialogDescription>
        </DialogHeader>
        {minted ? (
          <div className="grid gap-3">
            <p className="text-sm">{t("new.inviteRun")}</p>
            <div className="flex items-start gap-2 rounded-lg border bg-muted/40 p-3">
              <code className="min-w-0 flex-1 font-mono text-xs break-all">{minted.command}</code>
              <Button
                size="icon"
                variant="ghost"
                className="size-7 shrink-0"
                aria-label={t("new.copy")}
                onClick={async () => {
                  await navigator.clipboard?.writeText(minted.command).catch(() => {});
                  setCopied(true);
                  toast(t("new.copied"));
                }}
              >
                {copied ? <Check /> : <Copy />}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              {t("new.inviteOnce", { when: when(minted.expires_at) })} · {t("new.inviteNote")}
            </p>
            <DialogFooter>
              <Button
                onClick={() => {
                  setOpen(false);
                  reset();
                }}
              >
                {t("new.done")}
              </Button>
            </DialogFooter>
          </div>
        ) : (
          <Tabs
            value={tab}
            onValueChange={(v) => {
              setTab(v);
              setErr("");
            }}
          >
            <TabsList className="w-full">
              <TabsTrigger value="add">{t("new.tabAdd")}</TabsTrigger>
              <TabsTrigger value="invite">{t("new.tabInvite")}</TabsTrigger>
            </TabsList>
            <TabsContent value="add">
              <form className="grid gap-2 pt-3" onSubmit={add}>
                <Label htmlFor="new-login">{t("new.login")}</Label>
                <Input
                  id="new-login"
                  value={login}
                  onChange={(e) => setLogin(e.target.value)}
                  placeholder={t("new.loginPh")}
                  autoComplete="off"
                  spellCheck={false}
                  aria-invalid={!!err}
                />
                {err && <p className="text-sm text-destructive">{err}</p>}
                <DialogFooter className="mt-2">
                  <Button type="submit" disabled={busy || !login.trim()}>
                    {t("new.add")}
                  </Button>
                </DialogFooter>
              </form>
            </TabsContent>
            <TabsContent value="invite">
              <form className="grid gap-2 pt-3" onSubmit={invite}>
                <Label htmlFor="new-for">{t("new.inviteFor")}</Label>
                <Input
                  id="new-for"
                  value={forWho}
                  onChange={(e) => setForWho(e.target.value)}
                  placeholder={t("new.inviteForPh")}
                  autoComplete="off"
                  spellCheck={false}
                  aria-invalid={!!err}
                />
                {err && <p className="text-sm text-destructive">{err}</p>}
                <DialogFooter className="mt-2">
                  <Button type="submit" disabled={busy}>
                    {t("new.inviteMint")}
                  </Button>
                </DialogFooter>
              </form>
            </TabsContent>
          </Tabs>
        )}
      </DialogContent>
    </Dialog>
  );
}
