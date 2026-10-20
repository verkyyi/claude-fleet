// PoolSettings — 订阅池设置, /admin/pool/settings (EPIC #3923 C12; the old
// /app/subscriptions/settings moves here): the subscription access rules
// (strict, or legacy with its one-time migration review — cred-policy,
// claude-fleet#3713) and how the pool picks a subscription (pool.skip_pct;
// pool.move_when_full is retired, T543). Every write goes through today's
// audited routes:
// PUT /v1/fleet/cred-policy {action: activate} and PUT /v1/fleet/settings.
import * as React from "react";
import { AlertCircle, ArrowLeft } from "lucide-react";
import { Link } from "react-router";
import { toast } from "sonner";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
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
import { Card, CardAction, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { api, type PolicyView } from "../api";
import { t } from "../i18n";
import { settingOf } from "../pool";

const POLICY = "/v1/fleet/cred-policy";

type Migration = { revision?: string | number; objects: { key: string; scope: "user" | "node"; id: string; label?: string }[] };
type View = PolicyView & { migration?: Migration };

export function PoolSettingsPage() {
  return (
    <div className="mx-auto flex w-full max-w-4xl flex-col gap-6 p-6 md:p-8">
      <div>
        <Button variant="link" size="sm" className="h-auto px-0 text-muted-foreground" asChild>
          <Link to="/pool">
            <ArrowLeft />
            {t("set.back")}
          </Link>
        </Button>
        <h1 className="mt-1 font-display text-3xl font-semibold tracking-tight">
          {t("set.title")}
          <span className="text-primary">.</span>
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">{t("set.lead")}</p>
      </div>
      <PolicyCard />
      <PoolCard />
    </div>
  );
}

function Failed({ e, retry }: { e: string; retry: () => void }) {
  return (
    <Alert variant="destructive">
      <AlertCircle />
      <AlertTitle>{t("state.error")}</AlertTitle>
      <AlertDescription className="flex flex-wrap items-center gap-3">
        <span className="font-mono text-xs">{e}</span>
        <Button size="sm" variant="outline" onClick={retry}>
          {t("state.retry")}
        </Button>
      </AlertDescription>
    </Alert>
  );
}

function PolicyCard() {
  const [view, setView] = React.useState<View | null>(null);
  const [err, setErr] = React.useState("");
  const [pick, setPick] = React.useState<Record<string, string>>({});
  const [ask, setAsk] = React.useState(false);
  const [busy, setBusy] = React.useState(false);

  const load = React.useCallback(() => {
    setErr("");
    api<View>(POLICY).then(
      (v) => {
        setView(v);
        setPick({});
      },
      (e: Error) => setErr(e.message),
    );
  }, []);
  React.useEffect(load, [load]);

  const objects = view?.migration?.objects || [];
  const retain = objects.filter((o) => pick[o.key] === "retain").map((o) => o.key);
  const allChosen = objects.every((o) => pick[o.key]);

  const activate = async () => {
    setBusy(true);
    try {
      await api(POLICY, { method: "PUT", json: { action: "activate", revision: view?.migration?.revision, retain } });
      toast.success(t("set.policy.activated"));
      load();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-display text-lg">{t("set.policy.title")}</CardTitle>
        <CardDescription>{t("set.policy.defaults")}</CardDescription>
        {view && (
          <CardAction>
            <Badge variant="outline" className={view.mode === "legacy" ? "border-warn/50 text-warn" : "border-ok/40 text-ok"}>
              {t(view.mode === "legacy" ? "set.policy.legacy" : "set.policy.strict")}
            </Badge>
          </CardAction>
        )}
      </CardHeader>
      <CardContent className="grid gap-4">
        {err ? (
          <Failed e={err} retry={load} />
        ) : !view ? (
          <Skeleton className="h-24 w-full" />
        ) : view.mode !== "legacy" ? (
          <>
            <p className="text-sm">{t("set.policy.strictHint")}</p>
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" asChild>
                <Link to="/people">{t("set.policy.byUser")}</Link>
              </Button>
              <Button variant="outline" asChild>
                <Link to="/machines">{t("set.policy.byMachine")}</Link>
              </Button>
            </div>
          </>
        ) : (
          <>
            <p className="text-sm">{t("set.policy.migrateHint")}</p>
            <div className="overflow-hidden rounded-xl border">
              <Table>
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    <TableHead className="px-4">{t("set.policy.object")}</TableHead>
                    <TableHead className="w-72 px-4">{t("set.policy.after")}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {objects.map((o) => (
                    <TableRow key={o.key}>
                      <TableCell className="px-4 py-2.5">
                        <div className="font-medium">{o.label || o.id}</div>
                        <div className="font-mono text-xs text-muted-foreground">
                          {t(o.scope === "user" ? "set.policy.user" : "set.policy.node")} · {o.id}
                        </div>
                      </TableCell>
                      <TableCell className="px-4 py-2.5">
                        <Select value={pick[o.key] || ""} onValueChange={(v) => setPick((p) => ({ ...p, [o.key]: v }))}>
                          <SelectTrigger className="w-full" aria-label={o.label || o.id}>
                            <SelectValue placeholder={t("set.policy.decision")} />
                          </SelectTrigger>
                          <SelectContent>
                            <SelectItem value="retain">{t("set.policy.retain")}</SelectItem>
                            <SelectItem value="revoke">{t("set.policy.revoke")}</SelectItem>
                          </SelectContent>
                        </Select>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className="max-w-lg text-xs text-muted-foreground">{t("set.policy.migrateNote")}</p>
              <Button disabled={busy} onClick={() => (allChosen ? setAsk(true) : toast.error(t("set.policy.chooseAll")))}>
                {t("set.policy.activate")}
              </Button>
            </div>
            <AlertDialog open={ask} onOpenChange={setAsk}>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>{t("set.policy.activate")}</AlertDialogTitle>
                  <AlertDialogDescription>{t("set.policy.confirm", { keep: retain.length, revoke: objects.length - retain.length })}</AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
                  <AlertDialogAction onClick={() => void activate()}>{t("set.policy.activate")}</AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          </>
        )}
      </CardContent>
    </Card>
  );
}

function PoolCard() {
  const [skip, setSkip] = React.useState<string | null>(null);
  const [saved, setSaved] = React.useState("");
  const [err, setErr] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const fid = React.useId();

  const load = React.useCallback(() => {
    setErr("");
    api("/v1/fleet/settings").then(
      (s) => {
        const v = settingOf(s, "pool.skip_pct") || "85";
        setSkip(v);
        setSaved(v);
      },
      (e: Error) => setErr(e.message),
    );
  }, []);
  React.useEffect(load, [load]);

  const put = async (key: string, value: string) => {
    setBusy(true);
    try {
      await api("/v1/fleet/settings", { method: "PUT", json: { key, value } });
      toast.success(t("set.saved"));
      load();
    } catch (e) {
      toast.error(t("err.action", { e: (e as Error).message }));
      load();
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-display text-lg">{t("set.pool.title")}</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-5">
        {err ? (
          <Failed e={err} retry={load} />
        ) : skip == null ? (
          <Skeleton className="h-20 w-full" />
        ) : (
          <>
            <form
              className="flex flex-wrap items-center justify-between gap-4"
              onSubmit={(e) => {
                e.preventDefault();
                void put("pool.skip_pct", skip);
              }}
            >
              <div className="grid gap-0.5">
                <Label htmlFor={fid}>{t("set.pool.skip")}</Label>
                <p className="text-xs text-muted-foreground">{t("set.pool.skipHint")}</p>
              </div>
              <div className="flex items-center gap-2">
                <Input id={fid} type="number" min={1} max={100} required value={skip} onChange={(e) => setSkip(e.target.value)} className="w-20 font-mono" />
                <span className="text-sm text-muted-foreground">%</span>
                <Button type="submit" size="sm" disabled={busy || skip === saved}>
                  {t("set.save")}
                </Button>
              </div>
            </form>
          </>
        )}
      </CardContent>
    </Card>
  );
}
