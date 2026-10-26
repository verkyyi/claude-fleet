// start-clock.ts — a new web session's wait (task PNWW): from the press on 新会话
// to the first words of the reply on screen, with two stages inside it — open
// (/v1/chat/open answered) and shown (the session's own page drawn). The clock
// lives in this tab (sessionStorage, by the session's worker), crosses the
// page change, and is sent once: POST /v1/chat/timing {ms, open_ms, shown_ms,
// agent, tz}. The words are never in it; the hub keeps no person with it.

export type Clock = { t0: number; open?: number; shown?: number; agent?: string };
type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

// The same session may be read as <fleet>/<fid> or fid:<fid> once its
// history row arrives. Keep the clock under that lifelong identity.
const KEY = (worker: string) => `fleet:start-clock:${worker.startsWith("fid:") ? worker.slice(4) : worker.includes("/") ? worker.slice(worker.lastIndexOf("/") + 1) : worker}`;
// a clock not stopped within this long was not one sitting (the hub's bound)
export const CLOCK_MAX_MS = 600 * 1000;

function store(): Store | null {
  try { return typeof sessionStorage === "undefined" ? null : sessionStorage; } catch { return null; }
}

export function readClock(worker: string, s: Store | null = store(), now = Date.now()): Clock | null {
  if (!worker || !s) return null;
  try {
    const c = JSON.parse(s.getItem(KEY(worker)) || "null") as Clock | null;
    if (!c || typeof c.t0 !== "number" || now - c.t0 > CLOCK_MAX_MS || now < c.t0) { s.removeItem(KEY(worker)); return null; }
    return c;
  } catch { return null; }
}

// the open answered: the clock is filed under the session it opened
export function clockOpened(worker: string, t0: number, agent: string, s: Store | null = store(), now = Date.now()) {
  if (!worker || !s) return;
  try { s.setItem(KEY(worker), JSON.stringify({ t0, open: now - t0, agent } satisfies Clock)); } catch { /* private mode */ }
}

// the session's own page drawn: once
export function clockShown(worker: string, s: Store | null = store(), now = Date.now()) {
  const c = readClock(worker, s, now);
  if (!c || c.shown != null || !s) return;
  try { s.setItem(KEY(worker), JSON.stringify({ ...c, shown: now - c.t0 })); } catch { /* private mode */ }
}

// the first words of the reply: the clock stops and goes, once — what to send, or null
export function clockReplied(worker: string, s: Store | null = store(), now = Date.now(), tz = zone()) {
  const c = readClock(worker, s, now);
  if (!c || !s) return null;
  s.removeItem(KEY(worker));
  const ms = now - c.t0;
  const within = (v?: number) => (typeof v === "number" && v >= 0 && v <= ms ? Math.round(v) : 0);
  return { ms: Math.max(1, Math.round(ms)), open_ms: within(c.open), shown_ms: within(c.shown), agent: c.agent || "", tz };
}

function zone(): string {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ""; } catch { return ""; }
}

// Keep completed clocks until acknowledged; a stable id makes an ambiguous
// response safe to retry. No transcript or user identifier enters the queue.
const OUTBOX = "fleet:timing-outbox";
type Pending = NonNullable<ReturnType<typeof clockReplied>> & { id: string };
let memory: Pending[] = [];
let sending = false;
function pending(): Pending[] {
  try { return JSON.parse(store()?.getItem(OUTBOX) || "null") || memory; } catch { return memory; }
}
function keep(xs: Pending[]) {
  memory = xs.slice(-50);
  try { store()?.setItem(OUTBOX, JSON.stringify(memory)); } catch { /* memory fallback */ }
}
export async function flushClocks() {
  if (sending) return;
  sending = true;
  try {
    for (const body of pending()) {
      const r = await fetch("/v1/chat/timing", { method: "POST", cache: "no-store", keepalive: true,
        headers: { "X-Fleet-Webchat": "1", "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!r.ok && r.status !== 400 && r.status !== 413) break;
      keep(pending().filter((x) => x.id !== body.id));
    }
  } catch { /* retry on the next tick, reconnect or page load */ }
  finally { sending = false; }
}
export function sendClock(body: ReturnType<typeof clockReplied>) {
  if (!body) return;
  keep([...pending(), { ...body, id: crypto.randomUUID() }]);
  void flushClocks();
}
if (typeof window !== "undefined") {
  window.addEventListener("online", () => void flushClocks());
  window.setInterval(() => void flushClocks(), 15000);
  void flushClocks();
}

// a reply has begun: any assistant words in what the page holds
export const replied = (items: { t: string; d?: string }[]) => items.some((i) => i.t === "text" && !!(i.d || "").trim());
