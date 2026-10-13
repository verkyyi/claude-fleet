// AddSubscriptionDialog — 接一个订阅, the old page's three steps carried over
// as a shadcn Dialog (claude-fleet#1990, #2084): 选服务 (provider + a name) →
// 登录 (one command to run on any fleet node; the dialog polls the
// credential audit, /v1/fleet/credentials/audit, until that put arrives) →
// 完成. Nothing is written from here: the node's `fleet account add` hands the
// credential to the hub, which audits it.
import * as React from "react";
import { Check, CircleCheck, Copy, Loader2, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { cn } from "@/lib/utils";
import { api } from "../api";
import { t, type MsgKey } from "../i18n";
import { addCommand, arrived, LABEL_RE, type AuditRow, type Prov } from "../pool";

const POLL_MS = 3000;

export function AddSubscriptionDialog(p: { known: string[]; onAdded: () => void }) {
  const [open, setOpen] = React.useState(false);
  const [step, setStep] = React.useState(0);
  const [prov, setProv] = React.useState<Prov>("claude");
  const [label, setLabel] = React.useState("");
  const [err, setErr] = React.useState("");
  const [since, setSince] = React.useState(0);
  const [from, setFrom] = React.useState("");
  const [copied, setCopied] = React.useState(false);
  const fid = React.useId();

  const reset = () => {
    setStep(0);
    setLabel("");
    setErr("");
    setFrom("");
    setCopied(false);
  };

  // step 1 waits for the node's put; a blip is not an answer, keep waiting
  React.useEffect(() => {
    if (!open || step !== 1) return;
    let stop = false;
    let timer = 0;
    const poll = async () => {
      try {
        const a = await api<{ audit?: AuditRow[] }>("/v1/fleet/credentials/audit?limit=50");
        const row = arrived(a, prov, label, since);
        if (row && !stop) {
          setFrom(row.hostname || row.detail || "");
          setStep(2);
          toast.success(t("pool.add.inPool", { label }));
          p.onAdded();
          return;
        }
      } catch {
        /* keep waiting */
      }
      if (!stop) timer = window.setTimeout(poll, POLL_MS);
    };
    void poll();
    return () => {
      stop = true;
      clearTimeout(timer);
    };
  }, [open, step, prov, label, since]);

  const next = (e: React.FormEvent) => {
    e.preventDefault();
    const l = label.trim();
    if (!LABEL_RE.test(l)) return setErr(t("pool.add.badLabel"));
    if (p.known.includes(`${prov}/${l}`)) return setErr(t("pool.add.exists", { label: l }));
    setLabel(l);
    setErr("");
    setSince(Date.now());
    setStep(1);
    // the prototype's node answers on its own a few seconds later (demo.ts)
    if (import.meta.env.VITE_DEMO === "1") (window as any).__DEMO_ADD = { prov, label: l, at: Date.now() };
  };

  const steps: MsgKey[] = ["pool.add.s1", "pool.add.s2", "pool.add.s3"];
  const cmd = addCommand(prov, label);

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
          {t("pool.add")}
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{t("pool.add.title")}</DialogTitle>
          <DialogDescription asChild>
            <ol className="flex items-center gap-2 pt-1">
              {steps.map((k, i) => (
                <li key={k} className="flex items-center gap-2">
                  <span
                    className={cn(
                      "flex size-5 items-center justify-center rounded-full border text-[11px] font-medium tabular-nums",
                      i < step && "border-ok/50 text-ok",
                      i === step && "border-clay-line bg-clay-soft text-clay",
                    )}
                  >
                    {i < step ? <Check className="size-3" /> : i + 1}
                  </span>
                  <span className={cn("text-xs", i === step ? "text-foreground" : "text-muted-foreground")}>{t(k)}</span>
                  {i < steps.length - 1 && <span className="h-px w-6 bg-border" />}
                </li>
              ))}
            </ol>
          </DialogDescription>
        </DialogHeader>

        {step === 0 && (
          <form onSubmit={next} className="grid gap-4">
            <RadioGroup value={prov} onValueChange={(v) => setProv(v as Prov)} className="grid grid-cols-2 gap-2">
              {(["claude", "codex"] as const).map((v) => (
                <Label
                  key={v}
                  className="flex cursor-pointer items-start gap-3 rounded-lg border p-3 font-normal has-[[data-state=checked]]:border-clay-line has-[[data-state=checked]]:bg-clay-soft"
                >
                  <RadioGroupItem value={v} className="mt-0.5" />
                  <span className="grid gap-0.5">
                    <span className="font-medium">{v === "claude" ? "Claude" : "Codex"}</span>
                    <span className="text-xs text-muted-foreground">{t(v === "claude" ? "pool.add.claudePlans" : "pool.add.codexPlans")}</span>
                  </span>
                </Label>
              ))}
            </RadioGroup>
            <div className="grid gap-2">
              <Label htmlFor={fid}>{t("pool.add.label")}</Label>
              <Input
                id={fid}
                value={label}
                onChange={(e) => setLabel(e.target.value)}
                placeholder={prov === "codex" ? "codex-2" : "max-e"}
                className="font-mono"
                autoComplete="off"
                spellCheck={false}
                autoFocus
                aria-invalid={!!err}
              />
              <p className={cn("text-xs", err ? "text-destructive" : "text-muted-foreground")}>{err || t("pool.add.labelHint")}</p>
            </div>
            <DialogFooter>
              <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
                {t("confirm.cancel")}
              </Button>
              <Button type="submit">{t("pool.add.continue")}</Button>
            </DialogFooter>
          </form>
        )}

        {step === 1 && (
          <div className="grid gap-3">
            <p className="text-sm">{t("pool.add.run")}</p>
            <div className="flex items-start gap-2 rounded-lg border bg-muted/40 p-3">
              <code className="min-w-0 flex-1 font-mono text-xs break-all">{cmd}</code>
              <Button
                size="icon"
                variant="ghost"
                className="size-7 shrink-0"
                aria-label={t("new.copy")}
                onClick={async () => {
                  await navigator.clipboard?.writeText(cmd).catch(() => {});
                  setCopied(true);
                  toast(t("new.copied"));
                }}
              >
                {copied ? <Check /> : <Copy />}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">{t("pool.add.needs")}</p>
            <div className="flex items-center gap-2 rounded-lg border border-dashed px-3 py-2.5 text-sm text-muted-foreground">
              <Loader2 className="size-4 animate-spin" />
              {t("pool.add.waiting")}
            </div>
            <DialogFooter>
              <Button variant="ghost" onClick={() => setOpen(false)}>
                {t("confirm.cancel")}
              </Button>
            </DialogFooter>
          </div>
        )}

        {step === 2 && (
          <div className="grid gap-4">
            <div className="flex items-center gap-3">
              <CircleCheck className="size-9 shrink-0 text-ok" />
              <div>
                <p className="font-medium">{t("pool.add.inPool", { label })}</p>
                <p className="text-sm text-muted-foreground">{t("pool.add.sealed", { from: from || "—" })}</p>
              </div>
            </div>
            <DialogFooter>
              <Button onClick={() => setOpen(false)}>{t("pool.add.done")}</Button>
            </DialogFooter>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
