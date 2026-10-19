// PolicyEditor — 可用订阅: which subscriptions one person's sessions may use,
// moved here from the old person page (tokenledger/hub/web/dist/lib/cred-policy.js,
// claude-fleet#3713) so the page keeps what it did. The hub owns every verdict;
// this writes one scope through PUT /v1/fleet/cred-policy and never guesses an
// ID from a label.
import * as React from "react";
import { toast } from "sonner";
import { Alert, AlertDescription } from "@/components/ui/alert";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Skeleton } from "@/components/ui/skeleton";
import { api, ApiError, type Credential, type Limits, type PolicyEntry, type PolicyView } from "../api";
import { t, type MsgKey } from "../i18n";

const PATH = "/v1/fleet/cred-policy";
type Mode = "deny" | "selected" | "all";
type Choice = { id: string; label: string };

const validID = (id: string) => /^(?:[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}|codex:account:[a-f0-9]{32})$/.test(id);
const modeOf = (e?: PolicyEntry): Mode | "invalid" => (!e ? "deny" : e.error ? "invalid" : e.all ? "all" : e.allow.length ? "selected" : "deny");
const fingerprint = (e?: PolicyEntry) => JSON.stringify(e ? { all: !!e.all, allow: [...e.allow].sort(), error: e.error || "" } : null);

// The pool's subscriptions and the person's own; a selected one no longer
// there stays listed, so an unrelated edit cannot drop it.
function choicesFor(creds: Credential[], entry: PolicyEntry | undefined, id: string): { ok: Choice[]; missing: string[] } {
  const ok = new Map<string, Choice>();
  const missing: string[] = [];
  for (const c of creds) {
    if (!["claude", "codex"].includes(c.provider) || !["pool", id].includes(c.principal_id || "")) continue;
    const uuid = String(c.account_uuid || "").toLowerCase();
    const label = `${c.provider === "claude" ? "Claude" : "Codex"} · ${c.account}`;
    if (!validID(uuid)) {
      missing.push(label);
      continue;
    }
    const old = ok.get(uuid);
    ok.set(uuid, { id: uuid, label: old ? `${old.label} / ${label}` : label });
  }
  for (const uuid of entry?.allow || []) if (!ok.has(uuid)) ok.set(uuid, { id: uuid, label: t("policy.unavailable") });
  return { ok: [...ok.values()], missing };
}

const pct = (u: unknown) => {
  const n = Number(u);
  return u == null || u === "" || !Number.isFinite(n) || n < 0 ? null : Math.min(100, Math.round(n <= 1 ? n * 100 : n));
};
function windows(lim: Record<string, any> | undefined) {
  if (!lim || lim.available === false) return { h5: null, h7: null };
  let h5 = lim.five_hour || null;
  let h7 = lim.seven_day || null;
  for (const w of Array.isArray(lim.windows) ? lim.windows : []) {
    const mins = Number(w.minutes) || 0;
    if (!h5 && (mins === 300 || /5h|five|primary/i.test(w.id || w.label || ""))) h5 = w;
    else if (!h7 && (mins === 10080 || /week|seven|secondary/i.test(w.id || w.label || ""))) h7 = w;
  }
  return { h5: h5 ? pct(h5.utilization) : null, h7: h7 ? pct(h7.utilization) : null };
}

// scope is whose rule: a person's (user) or a machine's (node, C11's machine
// page — its id the hub's machine identity); bare drops the heading for a
// page that gives the block its own.
export function PolicyEditor({ id, scope = "user", bare = false }: { id: string; scope?: "user" | "node"; bare?: boolean }) {
  const [view, setView] = React.useState<PolicyView | null>(null);
  const [creds, setCreds] = React.useState<Credential[]>([]);
  const [limits, setLimits] = React.useState<Limits | null>(null);
  const [err, setErr] = React.useState("");
  const [mode, setMode] = React.useState<Mode | "legacy" | "invalid">("deny");
  const [selected, setSelected] = React.useState<string[]>([]);
  const [busy, setBusy] = React.useState(false);
  const [force, setForce] = React.useState<{ message: string; payload: unknown } | null>(null);

  const listOf = (v: PolicyView | null | undefined) => (scope === "node" ? v?.nodes : v?.users);
  const entry = listOf(view)?.find((x) => x.id === id);
  const legacyUnset = !!view && !entry && view.mode === "legacy";

  const load = React.useCallback(async () => {
    setErr("");
    try {
      const [v, c] = await Promise.all([api<PolicyView>(PATH), api<{ credentials: Credential[] }>("/v1/fleet/credentials")]);
      const e = listOf(v)?.find((x) => x.id === id);
      setView(v);
      setCreds(c.credentials || []);
      setMode(!e && v.mode === "legacy" ? "legacy" : modeOf(e));
      setSelected([...(e?.allow || [])]);
      api<Limits>("/v1/limits?account=all").then(setLimits, () => setLimits({}));
    } catch (e) {
      setErr((e as Error).message);
    }
  }, [id, scope]);
  React.useEffect(() => {
    void load();
  }, [load]);

  if (err) return <p className="text-sm text-destructive">{err}</p>;
  if (!view) return <Skeleton className="h-32 w-full" />;

  const { ok: choices, missing } = choicesFor(creds, entry, id);
  const before = modeOf(entry);
  const changed =
    ["deny", "selected", "all"].includes(mode) &&
    (legacyUnset || mode !== before || (mode === "selected" && JSON.stringify([...selected].sort()) !== JSON.stringify([...(entry?.allow || [])].sort())));
  const chip = legacyUnset ? t("policy.pending") : before === "selected" ? t("policy.count", { n: entry!.allow.length }) : t(`policy.${before}` as MsgKey);

  const put = async (payload: unknown) => {
    setBusy(true);
    try {
      await api(PATH, { method: "PUT", json: payload });
      toast.success(t("policy.saved"));
      await load();
    } catch (e) {
      // a list that takes a provider's last subscription away is refused until the admin says so (#3713)
      if (e instanceof ApiError && e.status === 409 && /would keep no/.test(e.message) && !(payload as any).force) {
        setForce({ message: e.message, payload: { ...(payload as object), force: true } });
      } else toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    if (mode === "selected" && !selected.length) return toast.error(t("policy.chooseSome"));
    const latest = await api<PolicyView>(PATH).catch(() => null);
    if (!latest || fingerprint(listOf(latest)?.find((x) => x.id === id)) !== fingerprint(entry)) {
      toast.error(t("policy.changed"));
      return load();
    }
    const allow = mode === "all" ? null : mode === "deny" ? [] : [...new Set(selected)].sort();
    await put(mode === "all" ? { scope, id, allow, all: true } : { scope, id, allow });
  };

  return (
    <section className="grid gap-3">
      <div className={bare ? "flex justify-end" : "flex items-start justify-between gap-3"}>
        {!bare && (
          <div>
            <h3 className="font-display text-base font-semibold">{t("policy.title")}</h3>
            <p className="text-xs text-muted-foreground">{t("policy.lead")}</p>
          </div>
        )}
        <Badge variant="outline">{chip}</Badge>
      </div>
      {view.mode === "legacy" && (
        <Alert>
          <AlertDescription className="text-xs">{t("policy.legacy")}</AlertDescription>
        </Alert>
      )}
      <RadioGroup value={mode} onValueChange={(v) => setMode(v as Mode)} className="gap-2">
        {(["deny", "selected", "all"] as const).map((m) => (
          <Label key={m} className="flex cursor-pointer items-start gap-3 rounded-lg border p-3 font-normal has-[[data-state=checked]]:border-clay-line has-[[data-state=checked]]:bg-clay-soft">
            <RadioGroupItem value={m} className="mt-0.5" />
            <span className="grid gap-0.5">
              <span className="font-medium">{t(`policy.${m}` as MsgKey)}</span>
              <span className="text-xs text-muted-foreground">{t(`policy.${m}Hint` as MsgKey)}</span>
            </span>
          </Label>
        ))}
      </RadioGroup>
      {mode === "selected" && (
        <div className="grid gap-1.5 rounded-lg border p-2">
          {choices.map((c) => {
            const lim = windows(limits?.per_account?.find((a) => String(a.account_uuid || "").toLowerCase() === c.id)?.limits);
            return (
              <Label key={c.id} className="flex cursor-pointer items-center gap-3 rounded-md px-2 py-1.5 font-normal hover:bg-accent">
                <Checkbox
                  checked={selected.includes(c.id)}
                  onCheckedChange={(on) => setSelected((s) => (on ? [...s, c.id] : s.filter((x) => x !== c.id)))}
                />
                <span className="min-w-0 flex-1 truncate">{c.label}</span>
                <span className="font-mono text-[11px] text-muted-foreground">
                  {limits ? [lim.h5 != null && t("policy.h5", { p: lim.h5 }), lim.h7 != null && t("policy.week", { p: lim.h7 })].filter(Boolean).join(" · ") || "—" : "…"}
                </span>
              </Label>
            );
          })}
          {missing.map((label) => (
            <Label key={label} className="flex items-center gap-3 px-2 py-1.5 font-normal text-muted-foreground">
              <Checkbox disabled />
              <span className="min-w-0 flex-1 truncate">{label}</span>
              <span className="text-[11px]">{t("policy.missingID")}</span>
            </Label>
          ))}
        </div>
      )}
      <div className="flex items-center justify-end gap-3">
        {changed && <span className="text-xs text-muted-foreground">{t("policy.unsaved")}</span>}
        <Button size="sm" disabled={!changed || busy} onClick={save}>
          {t("policy.save")}
        </Button>
      </div>
      <AlertDialog open={!!force} onOpenChange={(o) => !o && setForce(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("policy.forceTitle")}</AlertDialogTitle>
            <AlertDialogDescription>{force?.message}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const p = force?.payload;
                setForce(null);
                if (p) void put(p);
              }}
            >
              {t("policy.forceOk")}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}
