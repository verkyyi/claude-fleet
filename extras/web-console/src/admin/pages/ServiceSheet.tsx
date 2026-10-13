// ServiceSheet — one registered service or task of a machine (EPIC #3923 C11;
// the old machine page's row drawer and its log, lib/services.js +
// lib/svc-log.js): what it is, its state, the buttons the daemon takes
// (service_control: 起 · 停 · 重启 · 现在跑一次 · 改计划 — the hub refuses another
// login's entry), and its log, live: a HEAD first (403 / 404 / 503 are words,
// not a retry loop), then the hub's EventSource — its first `lines` after each
// (re)connect is the recent lines, the view starts over from them; every
// later one appends; `end`, an error or 45 s of silence reconnects on backoff.
// The hub masks every credential-shaped string and cuts it to the viewer.
import * as React from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { cn } from "@/lib/utils";
import { api } from "../api";
import { ago, when } from "../i18n";
import { tm, type MKey } from "../machines/i18n";
import { DemoEventSource } from "../machines/demo";
import { actionsFor, logPath, svcRequest, SVC_STATES, type ServiceRow } from "../machines/model";

// the prototype (VITE_DEMO=1) has no hub to stream from
const ES: typeof EventSource = import.meta.env.VITE_DEMO === "1" ? (DemoEventSource as unknown as typeof EventSource) : globalThis.EventSource;

export const svcStateWord = (r: ServiceRow) => {
  const w = tm(`svc.st.${SVC_STATES.includes(r.state) ? r.state : "unknown"}` as MKey);
  return r.state === "down" && r.rc ? `${w} (rc ${r.rc})` : w;
};

export function ServiceSheet({ r, machine, close, reload }: { r: ServiceRow; machine: string; close: () => void; reload: () => void }) {
  const acts = actionsFor(r);
  const [sched, setSched] = React.useState(false);
  const [at, setAt] = React.useState("");
  const [tz, setTz] = React.useState("");
  const cmd = `fleet ${r.kind === "task" ? "task" : "service"} logs ${r.name} -n 200`;

  const act = async (action: string, extra: Record<string, string> = {}) => {
    const what = tm(`svc.act.${action}` as MKey);
    try {
      const op = await api<{ status?: string; result?: { error?: { message?: string } } }>("/v1/fleet/service_control", { json: svcRequest(r, action, extra) });
      if (op?.status === "failed") toast.error(tm("svc.refused", { what, why: op.result?.error?.message || "" }));
      else if (op?.status === "succeeded") toast.success(tm(action === "run_now" ? "svc.ranNow" : "svc.done", { what, name: r.name }));
      else toast(tm("svc.sent", { what, name: r.name }));
    } catch (e) {
      toast.error(tm("svc.refused", { what, why: (e as Error).message }));
    }
    close();
    reload();
  };

  return (
    <>
      <SheetHeader className="border-b p-6">
        <SheetTitle className="font-display font-mono text-xl">{r.name}</SheetTitle>
        <SheetDescription className="font-mono text-xs">
          {machine} · {r.login} · {tm(r.kind === "task" ? "svc.task" : "svc.service")}
        </SheetDescription>
      </SheetHeader>
      <div className="grid gap-5 p-6">
        <dl className="grid grid-cols-[6rem_1fr] gap-x-4 gap-y-2.5 text-sm">
          <dt className="text-muted-foreground">{tm("svc.state")}</dt>
          <dd className={cn(r.failed && "text-destructive")}>
            {svcStateWord(r)}
            {r.why && <span className="block text-xs text-muted-foreground">{r.why}</span>}
          </dd>
          <dt className="text-muted-foreground">{tm("svc.last")}</dt>
          <dd>{ago(r.lastRun || undefined) || "—"}</dd>
          <dt className="text-muted-foreground">{tm("svc.next")}</dt>
          <dd>{r.nextRun ? when(r.nextRun) : "—"}</dd>
          {r.kind === "service" && (
            <>
              <dt className="text-muted-foreground">{tm("svc.restarts")}</dt>
              <dd className="font-mono text-xs">{r.restarts}</dd>
            </>
          )}
        </dl>
        <LiveLog r={r} />
        <div className="grid gap-1.5">
          <p className="text-xs text-muted-foreground">{tm("svc.more", { machine })}</p>
          <code className="rounded-md border bg-muted/40 px-3 py-2 font-mono text-xs">{cmd}</code>
        </div>
        {sched && (
          <div className="flex flex-wrap items-end gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="svc-at">{tm("svc.at")}</Label>
              <Input id="svc-at" className="w-24 font-mono" placeholder="07:00" value={at} onChange={(e) => setAt(e.target.value)} />
            </div>
            <div className="grid gap-1.5">
              <Label htmlFor="svc-tz">{tm("svc.tz")}</Label>
              <Input id="svc-tz" className="w-44 font-mono" placeholder="Asia/Shanghai" value={tz} onChange={(e) => setTz(e.target.value)} />
            </div>
            <Button
              size="sm"
              onClick={() => {
                if (!/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(at.trim())) return toast.error(tm("svc.badAt"));
                void act("set_schedule", tz.trim() ? { at: at.trim(), tz: tz.trim() } : { at: at.trim() });
              }}
            >
              {tm("svc.save")}
            </Button>
          </div>
        )}
      </div>
      {!!acts.length && (
        <SheetFooter className="mt-auto flex-row flex-wrap justify-end gap-2 border-t p-4">
          {acts.map((a) => (
            <Button key={a} variant={a === "stop" ? "destructive" : "outline"} onClick={() => (a === "set_schedule" ? setSched(true) : void act(a))}>
              {tm(`svc.act.${a}` as MKey)}
            </Button>
          ))}
        </SheetFooter>
      )}
    </>
  );
}

// ---- the live log -------------------------------------------------------------

type Line = { text: string; ts: number | null; skipped?: number };
type Mode = "connecting" | "live" | "down" | "offline" | "denied" | "gone" | "nostream";

const MAX_LINES = 2000;
const WATCHDOG_MS = 45_000;
const BACKOFF = [1000, 2000, 4000, 8000, 15000];
const ms = (v: unknown) => {
  const n = v ? Date.parse(String(v)) : NaN;
  return Number.isFinite(n) && n > 0 ? n : null;
};
const toLine = (l: any): Line => ({ text: String(l?.text || ""), ts: ms(l?.ts) });
const hms = (t: number) => new Date(t).toLocaleTimeString([], { hour12: false });

async function headStatus(url: string): Promise<number> {
  try {
    await api(url, { method: "HEAD" });
    return 200;
  } catch (e) {
    return (e as { status?: number }).status || 0;
  }
}

function LiveLog({ r }: { r: ServiceRow }) {
  const [lines, setLines] = React.useState<Line[]>([]);
  const [mode, setMode] = React.useState<Mode>("connecting");
  const [follow, setFollow] = React.useState(true);
  const box = React.useRef<HTMLPreElement>(null);
  const followRef = React.useRef(follow);
  followRef.current = follow;

  React.useEffect(() => {
    const url = logPath(r.host, r.login, r.name);
    let es: EventSource | null = null;
    let wd = 0;
    let retryT = 0;
    let retries = 0;
    let fresh = true;
    let stopped = false;
    const closeES = () => {
      es?.close();
      es = null;
      clearTimeout(wd);
    };
    const retry = (why: Mode) => {
      if (stopped) return;
      closeES();
      setMode(why);
      retryT = window.setTimeout(connect, BACKOFF[Math.min(retries++, BACKOFF.length - 1)]);
    };
    const heard = () => {
      retries = 0;
      clearTimeout(wd);
      wd = window.setTimeout(() => retry("down"), WATCHDOG_MS);
      setMode("live");
    };
    async function connect() {
      if (stopped) return;
      closeES();
      const s = await headStatus(url);
      if (stopped) return;
      if (s === 403) return setMode("denied");
      if (s === 404) return setMode("gone");
      if (s === 503) return retry("offline");
      if (s >= 400 || s === 0) return retry("down");
      if (typeof ES !== "function") return setMode("nostream");
      fresh = true;
      const mine = new ES(url);
      es = mine;
      mine.addEventListener("lines", (e) => {
        if (es !== mine) return;
        let f: any;
        try {
          f = JSON.parse((e as MessageEvent).data);
        } catch {
          return;
        }
        heard();
        const ls: Line[] = (Array.isArray(f.lines) ? f.lines : []).map(toLine);
        if (fresh || f.rotated) {
          fresh = false;
          setLines(ls.slice(-MAX_LINES));
          return;
        }
        if (f.skipped) ls.unshift({ text: "", ts: null, skipped: f.skipped });
        setLines((old) => [...old, ...ls].slice(-MAX_LINES));
      });
      mine.addEventListener("ping", () => es === mine && heard());
      mine.addEventListener("end", () => es === mine && retry("down"));
      mine.onerror = () => es === mine && retry("down");
      wd = window.setTimeout(() => retry("down"), WATCHDOG_MS);
    }
    setLines([]);
    setMode("connecting");
    void connect();
    return () => {
      stopped = true;
      closeES();
      clearTimeout(retryT);
    };
  }, [r.host, r.login, r.name]);

  React.useEffect(() => {
    if (followRef.current && box.current) box.current.scrollTop = box.current.scrollHeight;
  }, [lines]);

  const word: Record<Mode, string> = {
    connecting: tm("log.loading"),
    live: tm("log.live"),
    down: tm("log.st.down"),
    offline: tm("log.st.offline"),
    denied: tm("log.st.denied"),
    gone: tm("log.st.gone"),
    nostream: tm("log.st.nostream"),
  };
  return (
    <section className="grid gap-2">
      <div className="flex items-center justify-between gap-3">
        <h3 className="font-display text-base font-semibold">{tm("log.title")}</h3>
        <div className="flex items-center gap-3">
          <Badge
            variant="outline"
            className={cn("font-normal", mode === "live" ? "border-ok/40 text-ok" : mode === "denied" || mode === "gone" ? "border-destructive/50 text-destructive" : "border-warn/50 text-warn")}
          >
            {word[mode]}
          </Badge>
          <Label className="gap-1.5 text-xs font-normal text-muted-foreground">
            <Checkbox
              checked={follow}
              onCheckedChange={(v) => {
                setFollow(!!v);
                if (v && box.current) box.current.scrollTop = box.current.scrollHeight;
              }}
            />
            {tm("log.follow")}
          </Label>
        </div>
      </div>
      <pre
        ref={box}
        tabIndex={0}
        onScroll={(e) => {
          const b = e.currentTarget;
          setFollow(b.scrollHeight - b.scrollTop - b.clientHeight <= 8);
        }}
        className="h-72 overflow-auto rounded-lg border bg-muted/40 p-3 font-mono text-xs leading-relaxed whitespace-pre-wrap"
      >
        {lines.length ? (
          lines.map((l, i) =>
            l.skipped ? (
              <div key={i} className="text-muted-foreground italic">
                {tm("log.skipped", { n: l.skipped })}
              </div>
            ) : (
              <div key={i}>
                {l.ts && <span className="mr-2 text-muted-foreground">{hms(l.ts)}</span>}
                {l.text || " "}
              </div>
            ),
          )
        ) : (
          <span className="text-muted-foreground">{mode === "live" ? tm("log.empty") : mode === "connecting" ? tm("log.loading") : r.line || tm("svc.noLine")}</span>
        )}
      </pre>
    </section>
  );
}
