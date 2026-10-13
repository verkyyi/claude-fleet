// ConfirmByName — every dangerous act on the admin side asks this way (EPIC
// #3923 C10): an AlertDialog that opens only once the name is typed back.
import * as React from "react";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { t } from "./i18n";

export function ConfirmByName(p: {
  name: string;
  title: string;
  body: string;
  ok: string;
  onConfirm: () => Promise<void>;
  children: React.ReactNode;
}) {
  const [open, setOpen] = React.useState(false);
  const [typed, setTyped] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const id = React.useId();
  const match = typed.trim() === p.name;
  return (
    <AlertDialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (!o) setTyped("");
      }}
    >
      <AlertDialogTrigger asChild>{p.children}</AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{p.title}</AlertDialogTitle>
          <AlertDialogDescription>{p.body}</AlertDialogDescription>
        </AlertDialogHeader>
        <form
          className="grid gap-2"
          onSubmit={async (e) => {
            e.preventDefault();
            if (!match || busy) return;
            setBusy(true);
            try {
              await p.onConfirm();
              setOpen(false);
            } finally {
              setBusy(false);
            }
          }}
        >
          <Label htmlFor={id} className="text-muted-foreground">
            {t("confirm.typeName", { name: p.name })}
          </Label>
          <Input id={id} value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} className="font-mono" />
          <AlertDialogFooter className="mt-2">
            <AlertDialogCancel type="button">{t("confirm.cancel")}</AlertDialogCancel>
            <Button type="submit" variant="destructive" disabled={!match || busy}>
              {p.ok}
            </Button>
          </AlertDialogFooter>
        </form>
      </AlertDialogContent>
    </AlertDialog>
  );
}
