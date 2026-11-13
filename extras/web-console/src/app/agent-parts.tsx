// agent-parts.tsx — what 我的 · Agent and the OAuth consent page (T4DN) both
// draw: the permission boxes (read locked on, answer with its warning), the
// expiry choice, and a line to copy. Stock shadcn/ui only.
import { useId, type FC } from "react";
import { Check, Copy, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useCopyToClipboard } from "@/hooks/use-copy-to-clipboard";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { LOCKED, PERMS, RISKY, dayChoices, daysLabel, permLabel, riskyWarning, togglePerm } from "./agents";

// asked: the words the requesting agent asked for, each marked beside its box
// (the consent page of an unverified agent, whose boxes start unticked).
export const PermBoxes: FC<{ all?: readonly string[]; value: string[]; onChange: (v: string[]) => void; disabled?: boolean; asked?: readonly string[] }> = ({ all = PERMS, value, onChange, disabled, asked }) => {
  const id = useId();
  return (
    <fieldset className="grid gap-2" disabled={disabled}>
      <legend className="mb-2 text-sm font-medium">{tr("允许它做什么", "What it may do")}</legend>
      {all.map((p) => {
        const on = value.includes(p);
        return (
          <div key={p} className="grid gap-1">
            <Label htmlFor={`${id}-${p}`} className={cn("flex items-center gap-3 rounded-lg border px-3 py-2.5 font-normal",
              p === LOCKED ? "cursor-default" : "cursor-pointer", on && "border-clay-line bg-clay-soft")}>
              <Checkbox id={`${id}-${p}`} checked={on} disabled={disabled || p === LOCKED}
                onCheckedChange={(c) => onChange(togglePerm(value, p, c === true, all))} />
              <span className="text-[14px]">{permLabel(p)}</span>
              {p === LOCKED ? <span className="text-muted-foreground ms-auto text-xs">{tr("总是", "always")}</span>
                : asked?.includes(p) ? <span className="text-muted-foreground ms-auto text-xs">{tr("它请求了", "requested")}</span> : null}
            </Label>
            {p === RISKY && on ? (
              <p role="alert" className="border-warn/50 bg-warn/10 flex items-start gap-2 rounded-lg border px-3 py-2 text-[12.5px] leading-relaxed">
                <TriangleAlert className="text-warn mt-0.5 size-4 shrink-0" aria-hidden />{riskyWarning()}
              </p>
            ) : null}
          </div>
        );
      })}
    </fieldset>
  );
};

export const ExpirySelect: FC<{ value: number; onChange: (d: number) => void; disabled?: boolean; max?: number }> = ({ value, onChange, disabled, max }) => {
  const id = useId();
  return (
    <div className="flex items-center justify-between gap-3">
      <Label htmlFor={id}>{tr("有效期", "Expires after")}</Label>
      <Select disabled={disabled} value={String(value)} onValueChange={(v) => onChange(Number(v))}>
        <SelectTrigger id={id} className="w-32"><SelectValue /></SelectTrigger>
        <SelectContent>{dayChoices(value, max).map((d) => <SelectItem key={d} value={String(d)}>{daysLabel(d)}</SelectItem>)}</SelectContent>
      </Select>
    </div>
  );
};

export const CopyButton: FC<{ text: string; label?: string; className?: string }> = ({ text, label, className }) => {
  const { isCopied, copyToClipboard } = useCopyToClipboard({ copiedDuration: 1500 });
  return (
    <Button type="button" size={label ? "sm" : "icon"} variant="ghost" className={cn(label ? "" : "size-8 shrink-0", className)}
      aria-label={isCopied ? tr("已复制", "Copied") : tr("复制", "Copy")} onClick={() => copyToClipboard(text)}>
      {isCopied ? <Check /> : <Copy />}{label ? (isCopied ? tr("已复制", "Copied") : label) : null}
    </Button>
  );
};

// One value to copy, on one line, scrolled inside itself.
export const CopyLine: FC<{ text: string; label?: string }> = ({ text, label }) => (
  <div className="bg-muted/60 flex min-w-0 items-center gap-1 rounded-lg border ps-3 pe-1" aria-label={label}>
    <code className="min-w-0 flex-1 overflow-x-auto py-2 font-mono text-[13px] whitespace-nowrap">{text}</code>
    <CopyButton text={text} />
  </div>
);
