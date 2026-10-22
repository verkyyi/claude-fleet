// Emergency — 紧急开关, /admin/emergency (WACK C5; the old /app/admin/emergency
// moves on here). Four switches for an incident, the one pressed most often
// first: stop every new trial (and resume), stop one 试用二维码, stop one
// person and end their sessions at once, pause one machine for new people.
// Each press asks first, saying how many people it touches; the hub writes a
// fleet_audit row and tells every admin on WeChat. A failure says why and
// changes nothing. Reads and writes /v1/admin/emergency only.
import * as React from "react";
import { AlertCircle, Check, ChevronsUpDown } from "lucide-react";
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
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { api, ApiError, type EmergencyAction, type EmergencyView } from "../api";
import { lang, t, type MsgKey } from "../i18n";

const BASE = "/v1/admin/emergency";

// a press waiting on its confirm, or one that failed (kept to retry)
type Press = { action: EmergencyAction; target?: string; name?: string; n: number };

const clock = (iso?: string) =>
  iso ? new Date(iso).toLocaleTimeString(lang === "zh" ? "zh-CN" : "en", { hour: "2-digit", minute: "2-digit", hour12: false }) : "";

// why a press failed, in words: the network's own failure is the entry service out of reach
function whyFailed(e: unknown): string {
  if (e instanceof ApiError && e.status !== 502 && e.status !== 503 && e.status !== 504) return e.message;
  return t("em.fail.unreachable");
}

export function EmergencyPage() {
  const [view, setView] = React.useState<EmergencyView | null>(null);
  const [loadErr, setLoadErr] = React.useState("");
  const [ask, setAsk] = React.useState<Press | null>(null);
  const [failed, setFailed] = React.useState<(Press & { why: string }) | null>(null);
  const [busy, setBusy] = React.useState(false);
  const [code, setCode] = React.useState("");
  const [person, setPerson] = React.useState("");
  const [machine, setMachine] = React.useState("");

  const load = React.useCallback(() => {
    setLoadErr("");
    api<EmergencyView>(BASE).then(setView, (e: Error) => setLoadErr(whyFailed(e)));
  }, []);
  React.useEffect(load, [load]);

  const machines = view?.machines || [];
  const pickedMachine = machine || machines.find((m) => !m.paused)?.hostname || machines[0]?.hostname || "";

  const run = async (p: Press) => {
    setBusy(true);
    setAsk(null);
    try {
      const v = await api<EmergencyView>(BASE, { json: { action: p.action, target: p.target } });
      setView(v);
      setFailed(null);
      if (p.action === "code_disable") setCode("");
      if (p.action === "person_stop") setPerson("");
      toast.success(t(`em.done.${p.action}` as MsgKey, { name: p.name || p.target || "", n: v.done?.stopped ?? 0 }));
    } catch (e) {
      setFailed({ ...p, why: whyFailed(e) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mx-auto flex w-full max-w-4xl flex-col gap-6 p-6 md:p-8">
      <div>
        <h1 className="font-display text-3xl font-semibold tracking-tight">
          {t("page.emergency")}
          <span className="text-primary">.</span>
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">{t("em.lead")}</p>
      </div>

      {failed && (
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>{t(failed.action === "trial_resume" ? "em.fail.resume" : "em.fail.title")}</AlertTitle>
          <AlertDescription className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <span>{t("em.fail.body", { why: failed.why })}</span>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => run(failed)}>
              {t("em.retry")}
            </Button>
          </AlertDescription>
        </Alert>
      )}

      {loadErr ? (
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>{t("em.loadFail")}</AlertTitle>
          <AlertDescription className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <span>{t("em.fail.body", { why: loadErr })}</span>
            <Button size="sm" variant="outline" onClick={load}>
              {t("em.retry")}
            </Button>
          </AlertDescription>
        </Alert>
      ) : !view ? (
        <Card>
          <CardContent className="grid gap-4">
            <p className="text-sm text-muted-foreground" role="status">
              {t("em.loading")}
            </p>
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-14 w-full" />
            ))}
          </CardContent>
        </Card>
      ) : (
        <Card className="py-0">
          <CardContent className="divide-y px-0">
            <Row title={t(view.trial.stopped ? "em.trial.stopped" : "em.trial.title")}
              desc={view.trial.stopped ? t("em.trial.stoppedBy", { time: clock(view.trial.at), who: view.trial.by || "—", n: view.trial.saw }) : t("em.trial.desc")}>
              {view.trial.stopped ? (
                <Button variant="outline" disabled={busy} onClick={() => setAsk({ action: "trial_resume", n: 0 })}>
                  {t("em.trial.resume")}
                </Button>
              ) : (
                <Button variant="destructive" disabled={busy} onClick={() => setAsk({ action: "trial_stop", n: view.trial.trying })}>
                  {t("em.trial.stop")}
                </Button>
              )}
            </Row>

            <Row title={t("em.code.title")} desc={t("em.code.desc")}>
              <Select value={code} onValueChange={setCode}>
                <SelectTrigger className="min-w-0 flex-1 md:w-52 md:flex-none" aria-label={t("em.code.title")}>
                  <SelectValue placeholder={t("em.code.pick")} />
                </SelectTrigger>
                <SelectContent>
                  {view.codes.filter((c) => c.state !== "stopped").length === 0 && (
                    <div className="px-2 py-1.5 text-sm text-muted-foreground">{t("em.code.none")}</div>
                  )}
                  {view.codes
                    .filter((c) => c.state !== "stopped")
                    .map((c) => (
                      <SelectItem key={c.id} value={c.id}>
                        {c.channel}
                        {c.state === "paused" && <span className="text-xs text-destructive">{t("tc.st.paused")}</span>}
                      </SelectItem>
                    ))}
                </SelectContent>
              </Select>
              <Button variant="outline" disabled={busy || !code}
                onClick={() => {
                  const c = view.codes.find((x) => x.id === code);
                  setAsk({ action: "code_disable", target: code, name: c?.channel, n: c?.granted ?? 0 });
                }}>
                {t("em.code.go")}
              </Button>
            </Row>

            <Row title={t("em.person.title")} desc={t("em.person.desc")}>
              <PersonPicker people={view.people} value={person} onPick={setPerson} />
              <Button variant="outline" disabled={busy || !person}
                onClick={() => {
                  const p = view.people.find((x) => x.principal === person);
                  setAsk({ action: "person_stop", target: person, name: p?.login, n: p?.sessions ?? 0 });
                }}>
                {t("em.person.go")}
              </Button>
            </Row>

            <Row title={t("em.machine.title")} desc={t("em.machine.desc")}>
              <Select value={pickedMachine} onValueChange={setMachine} disabled={machines.length === 0}>
                <SelectTrigger className="min-w-0 flex-1 md:w-52 md:flex-none" aria-label={t("em.machine.title")}>
                  <SelectValue placeholder={t("em.machine.none")} />
                </SelectTrigger>
                <SelectContent>
                  {machines.map((m) => (
                    <SelectItem key={m.hostname} value={m.hostname}>
                      {m.hostname}
                      {m.paused && <span className="text-xs text-muted-foreground">{t("em.machine.paused")}</span>}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button variant="outline" disabled={busy || !pickedMachine || !!machines.find((m) => m.hostname === pickedMachine)?.paused}
                onClick={() => {
                  const m = machines.find((x) => x.hostname === pickedMachine);
                  setAsk({ action: "machine_pause", target: pickedMachine, name: pickedMachine, n: m?.sessions ?? 0 });
                }}>
                {t("em.machine.go")}
              </Button>
            </Row>
          </CardContent>
        </Card>
      )}

      <AlertDialog open={!!ask} onOpenChange={(o) => !o && setAsk(null)}>
        <AlertDialogContent>
          {ask && (
            <>
              <AlertDialogHeader>
                <AlertDialogTitle>{t(`em.c.${ask.action}.title` as MsgKey, { name: ask.name || "" })}</AlertDialogTitle>
                <AlertDialogDescription>{t(`em.c.${ask.action}.body` as MsgKey, { name: ask.name || "", n: ask.n })}</AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>{t("confirm.cancel")}</AlertDialogCancel>
                <AlertDialogAction className={cn(ask.action !== "trial_resume" && "bg-destructive text-white hover:bg-destructive/90")}
                  onClick={() => run(ask)}>
                  {t(`em.c.${ask.action}.ok` as MsgKey)}
                </AlertDialogAction>
              </AlertDialogFooter>
            </>
          )}
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

// Row is one switch: what it does on the left, its controls on the right —
// under it on a phone.
function Row(p: { title: string; desc: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-3 px-5 py-4 md:flex-row md:items-center md:justify-between md:gap-6">
      <div className="min-w-0">
        <div className="font-medium">{p.title}</div>
        <p className="mt-0.5 text-sm text-muted-foreground">{p.desc}</p>
      </div>
      <div className="flex shrink-0 items-center gap-2">{p.children}</div>
    </div>
  );
}

function PersonPicker({ people, value, onPick }: { people: EmergencyView["people"]; value: string; onPick: (v: string) => void }) {
  const [open, setOpen] = React.useState(false);
  const picked = people.find((p) => p.principal === value);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button variant="outline" role="combobox" aria-expanded={open} className="min-w-0 flex-1 justify-between font-normal md:w-52 md:flex-none">
          <span className={cn("truncate", !picked && "text-muted-foreground")}>{picked ? picked.login : t("em.person.pick")}</span>
          <ChevronsUpDown className="size-3.5 opacity-50" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-64 p-0" align="end">
        <Command>
          <CommandInput placeholder={t("em.person.pick")} />
          <CommandList>
            <CommandEmpty>{t("em.person.none")}</CommandEmpty>
            <CommandGroup>
              {people.map((p) => (
                <CommandItem key={p.principal} value={`${p.login} ${p.principal}`}
                  onSelect={() => {
                    onPick(p.principal);
                    setOpen(false);
                  }}>
                  <Check className={cn("size-4", value === p.principal ? "opacity-100" : "opacity-0")} />
                  <span className="flex-1 truncate">{p.login}</span>
                  {p.trial && <span className="text-xs text-muted-foreground">{t("em.person.trial")}</span>}
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
