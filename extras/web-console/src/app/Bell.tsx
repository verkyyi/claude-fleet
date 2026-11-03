// Bell.tsx — 通知 (task PV5W): a bell beside the list's search (the computer's
// sidebar head, the phone's top bar) instead of bars over the page. Its badge
// counts what wants the person — asking, new results, failed schedule runs
// (notices.ts); opened, a popover (computer) or a sheet (phone) lists 在问你 ·
// 新结果 · 定时任务 · 说明. ReplyToast, TrialBar and NetBar stay as they were.
import { createContext, useContext, useState, type FC, type ReactNode } from "react";
import { useNavigate } from "react-router";
import { Bell as BellIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle, SheetTrigger } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { tr } from "@/shared/i18n";
import { bellGroups } from "./notices";
import { LegacyNoticeText, useLegacyMigration, type LegacyNotice } from "./chat/legacy";
import { readSchedule, schedulePath, useSchedules } from "./schedules";
import { GLYPH, TONE, sessionPath } from "./SessionList";
import { useWorkRows } from "./work-rows";
import type { Row } from "./work";

// The old chats' migration runs once for the whole page; its words wait in the
// bell's 说明 until seen once (this browser).
const LegacyCtx = createContext<LegacyNotice | null>(null);
export const NoticesProvider: FC<{ children: ReactNode }> = ({ children }) =>
  <LegacyCtx.Provider value={useLegacyMigration()}>{children}</LegacyCtx.Provider>;
const LEGACY_SEEN = "fleet.console.legacy-seen";
const legacyKind = (n: LegacyNotice) => (n.busy ? "busy" : "failed");
const readLegacySeen = () => { try { return localStorage.getItem(LEGACY_SEEN) || ""; } catch { return ""; } };

const Group: FC<{ title: string; children: ReactNode }> = ({ title, children }) => (
  <section className="py-1">
    <h3 className="text-muted-foreground px-3 pt-2 pb-1 text-xs">{title}</h3>
    <ul>{children}</ul>
  </section>
);
const itemCls = "hover:bg-muted/60 flex w-full items-start gap-2 rounded-md px-3 py-2 text-start text-sm";

export const Bell: FC<{ phone?: boolean; className?: string }> = ({ phone, className }) => {
  const { rows, replied, markSeen } = useWorkRows();
  const { rows: schedules, unread, read, refresh } = useSchedules();
  const legacy = useContext(LegacyCtx);
  const go = useNavigate();
  const [open, setOpen] = useState(false);
  const [legacySeen, setLegacySeen] = useState(readLegacySeen);
  const names = Object.fromEntries((schedules || []).map((s) => [s.spec.id, s.spec.name]));
  const g = bellGroups(rows, replied, unread, names);
  const showLegacy = !!legacy && legacySeen !== legacyKind(legacy);
  const toggle = (o: boolean) => {
    setOpen(o);
    // seen once: closed, it does not come back until it says something else
    if (!o && legacy && showLegacy) { try { localStorage.setItem(LEGACY_SEEN, legacyKind(legacy)); } catch { /* private mode */ } setLegacySeen(legacyKind(legacy)); }
  };
  const openRow = (r: Row, seen: boolean) => { if (seen) markSeen(r); toggle(false); go(sessionPath(r)); };
  const openSchedule = (id: string) => { toggle(false); go(schedulePath(id)); void readSchedule(read, id).then(() => refresh()); };
  const allRead = async () => {
    for (const r of g.results) markSeen(r);
    await Promise.all(g.schedules.map((s) => readSchedule(read, s.id)));
    await refresh();
  };
  const empty = !g.asking.length && !g.results.length && !g.schedules.length && !showLegacy;
  const rowItem = (r: Row, seen: boolean) => {
    const Icon = GLYPH[r.glyph];
    return <li key={r.id}><button type="button" className={itemCls} onClick={() => openRow(r, seen)}>
      <Icon className={cn("mt-0.5 size-4 shrink-0", TONE[r.tone])} aria-hidden />
      <span className="min-w-0 flex-1"><span className="block truncate">{r.title}</span>
        {r.line ? <span className="text-muted-foreground block truncate text-xs">{r.line}</span> : null}</span>
    </button></li>;
  };
  const list = (
    <div data-testid="bell-list" className="max-h-[70vh] overflow-y-auto">
      {g.asking.length ? <Group title={tr(`在问你 · ${g.asking.length}`, `Asking you · ${g.asking.length}`)}>{g.asking.map((r) => rowItem(r, false))}</Group> : null}
      {g.results.length ? <Group title={tr(`新结果 · ${g.results.length}`, `New results · ${g.results.length}`)}>{g.results.map((r) => rowItem(r, true))}</Group> : null}
      {g.schedules.length ? <Group title={tr("定时任务", "Schedules")}>{g.schedules.map((s) => (
        <li key={s.id}><button type="button" className={itemCls} onClick={() => openSchedule(s.id)}>
          <span className={cn("min-w-0 flex-1", s.failed && "text-destructive")}>
            <span className="block truncate">{s.failed ? "✗ " : ""}{s.label}</span>
            {s.line ? <span className="text-muted-foreground block truncate text-xs">{s.line}</span> : null}
          </span>
        </button></li>
      ))}</Group> : null}
      {showLegacy ? <Group title={tr("说明", "Notes")}><li className="px-3 py-2 text-sm"><LegacyNoticeText n={legacy!} /></li></Group> : null}
      {empty ? <p className="text-muted-foreground px-3 py-6 text-center text-sm">{tr("没有新通知", "Nothing new")}</p> : null}
      {g.results.length || g.schedules.length ? <div className="border-t px-1 pt-1">
        <Button variant="ghost" size="sm" className="w-full" onClick={() => void allRead()}>{tr("全部已读", "Mark all read")}</Button>
      </div> : null}
    </div>
  );
  const trigger = (
    <Button variant="ghost" size="icon" className={cn("relative size-8", open && "text-clay", className)} aria-pressed={open}
      aria-label={g.count ? tr(`通知 · ${g.count}`, `Notifications · ${g.count}`) : tr("通知", "Notifications")} title={tr("通知", "Notifications")}>
      <BellIcon />
      {g.count ? <span data-bell-count className="bg-clay text-primary-foreground absolute top-0.5 end-0.5 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[10px] leading-none font-medium">{g.count > 99 ? "99+" : g.count}</span> : null}
    </Button>
  );
  if (phone) return (
    <Sheet open={open} onOpenChange={toggle}>
      <SheetTrigger asChild>{trigger}</SheetTrigger>
      <SheetContent side="bottom" className="gap-0 rounded-t-2xl pb-[calc(env(safe-area-inset-bottom)+1rem)]">
        <SheetHeader className="px-5 pt-5 pb-1"><SheetTitle>{tr("通知", "Notifications")}</SheetTitle>
          <SheetDescription className="sr-only">{tr("在问你、新结果和定时任务", "Asking you, new results and schedules")}</SheetDescription></SheetHeader>
        <div className="px-2">{list}</div>
      </SheetContent>
    </Sheet>
  );
  return (
    <Popover open={open} onOpenChange={toggle}>
      <PopoverTrigger asChild>{trigger}</PopoverTrigger>
      <PopoverContent align="end" className="w-80 p-1">{list}</PopoverContent>
    </Popover>
  );
};

