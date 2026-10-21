// sessions.ts — 会话's data (EPIC #3923 C4, issue #3927; T769): the person's own
// live sessions (/v1/fleet/sessions, kept fresh by the push channel's
// `sessions` topic, /v1/fleet/stream, under a watchdog — a 10 s poll when the
// channel is not there), their ended ones of the last 14 days (?state=ended), and the two
// writes through the write door (/v1/fleet/write): 回收 = worker_reap, 接回 =
// worker_resume. Every read is already cut to the person by the hub. With
// onTasks the same channel carries the person's task records too (`tasks`,
// T769) — one stream, one watchdog; the poll that stands in reads both.
import { useCallback, useEffect, useRef, useState } from "react";
import { getJSON, sendJSON } from "./api";
import { withAs } from "./viewAs";

// The push channel's watchdog (BREAK-IT hub-stream-silent): no event for
// 30 s — the hub pings every 20 s — is a stream something in between holds
// silent; it is opened again after 1 → 2 → 4 → 8 → 15 s.
export const WATCHDOG_MS = 30_000;
const BACKOFF_MS = [1000, 2000, 4000, 8000, 15000];

export type Group = "run" | "ask" | "ended";
export type Ask = { kind: string; msg: string };
export type SessionRow = {
  id: string;           // the key-form id 接回 takes (ended), the live worker_id (live)
  key: string;
  title: string;
  repo: string;
  machine: string;
  state: string;        // working · needs · blocked · idle · done · unknown · ended
  group: Group;
  ask: Ask | null;
  born: number;         // epoch s, a live row
  ended: string;        // ISO, an ended row
  tokens: number;       // today's pool tokens, a live row
  say?: string;         // its last word while working (status_msg)
  wid?: string;         // an ended row's worker_id: the task record's join
};

type LiveBody = { sessions?: { machine_name?: string; tokens_today?: number; worker?: Record<string, unknown> }[] };
type EndedBody = { sessions?: { worker_id?: string; resume_id: string; key: string; title?: string; repo?: string; machine_name?: string; ended_at?: string }[] };

const ASK_KINDS = ["permission", "question", "auth"];
const NEEDS_KIND: Record<string, string> = { perm: "permission", ask: "question", auth: "auth" };
const str = (v: unknown) => (typeof v === "string" ? v : "");

// What a waiting session asks, in its own words (#2538): the agent's report
// (status_kind / status_msg), else its needs subtype and detail.
function askOf(w: Record<string, unknown>): Ask | null {
  const kind = ASK_KINDS.includes(str(w.status_kind)) ? str(w.status_kind) : NEEDS_KIND[str(w.needs)] || "";
  const raw = str(w.status_msg).trim() ? str(w.status_msg) : str(w.detail);
  // eslint-disable-next-line no-control-regex
  const msg = raw.replace(/[\x00-\x1f\x7f]+/g, " ").trim().slice(0, 200);
  return kind || msg ? { kind, msg } : null;
}

export function liveRows(body: LiveBody | null): SessionRow[] {
  const out: SessionRow[] = [];
  for (const s of body?.sessions || []) {
    const w = s.worker || {};
    const state = str(w.state) || "unknown";
    const asking = state === "needs" || state === "blocked";
    const key = str(w.key) || str(w.name) || "—";
    out.push({
      id: str(w.worker_id) || key, key, title: str(w.title) || str(w.name) || key, repo: str(w.repo),
      machine: s.machine_name || "", state, group: asking ? "ask" : "run", ask: asking ? askOf(w) : null,
      born: Number(w.born) || 0, ended: "", tokens: Number(s.tokens_today) > 0 ? Number(s.tokens_today) : 0,
      say: asking ? "" : str(w.status_msg).slice(0, 200),
    });
  }
  return out.sort((a, b) => b.born - a.born || a.key.localeCompare(b.key));
}

export function endedRows(body: EndedBody | null): SessionRow[] {
  return (body?.sessions || []).map((e) => ({
    id: e.resume_id, key: e.key, title: e.title || e.key, repo: e.repo || "", machine: e.machine_name || "",
    state: "ended", group: "ended" as const, ask: null, born: 0, ended: e.ended_at || "", tokens: 0, wid: e.worker_id || "",
  }));
}

const keysOf = (rows: SessionRow[]) => new Set(rows.map((r) => `${r.machine}\t${r.key}`));

export type SessionsState = { live: SessionRow[] | null; ended: SessionRow[] | null; failed: boolean; reload: () => void };

export function useSessions(onTasks?: (body: unknown) => void, pollTasks?: () => void): SessionsState {
  const [live, setLive] = useState<SessionRow[] | null>(null);
  const [ended, setEnded] = useState<SessionRow[] | null>(null);
  const [failed, setFailed] = useState(false);
  const prev = useRef<Set<string>>(new Set());
  const timers = useRef<number[]>([]);

  const readEnded = useCallback(() => {
    getJSON<EndedBody>("/v1/fleet/sessions?state=ended").then((b) => { if (b) setEnded(endedRows(b)); });
  }, []);
  // a session that left the live list is reaped: its machine hands the hub its
  // history row a moment later, so the ended list is read again twice
  const onLive = useCallback((b: LiveBody) => {
    const rows = liveRows(b);
    const now = keysOf(rows);
    let gone = false;
    prev.current.forEach((k) => { if (!now.has(k)) gone = true; });
    prev.current = now;
    setLive(rows);
    setFailed(false);
    if (gone) for (const ms of [1500, 6000]) timers.current.push(window.setTimeout(readEnded, ms));
  }, [readEnded]);
  const reload = useCallback(() => {
    getJSON<LiveBody>("/v1/fleet/sessions").then((b) => (b ? onLive(b) : setFailed(true)));
    readEnded();
  }, [onLive, readEnded]);

  useEffect(() => {
    reload();
    let es: EventSource | null = null;
    let poll = 0, dog = 0, retry = 0, silent = 0, tries = 0, gone = false;
    const startPoll = () => {
      if (!poll) poll = window.setInterval(() => { getJSON<LiveBody>("/v1/fleet/sessions").then((b) => b && onLive(b)); pollTasks?.(); }, 10000);
    };
    const stopPoll = () => { if (poll) { clearInterval(poll); poll = 0; } };
    const drop = () => { es?.close(); es = null; clearTimeout(dog); };
    const later = (ms: number) => { clearTimeout(retry); retry = window.setTimeout(open, ms); };
    // a channel a proxy holds open but silent (BREAK-IT hub-stream-silent):
    // dropped and opened again, and twice silent in a row the route's poll,
    // the stream tried again every minute
    const quiet = () => {
      drop();
      if (++silent >= 2) { startPoll(); later(60_000); return; }
      later(BACKOFF_MS[Math.min(tries++, BACKOFF_MS.length - 1)]);
    };
    // anything that arrives — the hub's 20 s ping too — says it is alive
    const alive = () => { silent = 0; tries = 0; stopPoll(); clearTimeout(dog); dog = window.setTimeout(quiet, WATCHDOG_MS); };
    function open() {
      if (gone) return;
      if (typeof EventSource === "undefined") { startPoll(); return; }
      es = new EventSource(withAs(onTasks ? "/v1/fleet/stream?topics=sessions,tasks" : "/v1/fleet/stream?topics=sessions"));
      dog = window.setTimeout(quiet, WATCHDOG_MS);
      es.addEventListener("ping", alive);
      es.addEventListener("sessions", (e) => {
        alive();
        try { const f = JSON.parse((e as MessageEvent).data); if (f?.body) onLive(f.body); } catch { /* the next event */ }
      });
      if (onTasks) es.addEventListener("tasks", (e) => {
        alive();
        try { const f = JSON.parse((e as MessageEvent).data); if (f?.body) onTasks(f.body); } catch { /* the next event */ }
      });
      // a stream the hub or a proxy will not hold: the route's own poll
      // meanwhile, the stream again after a backoff (its first event the
      // whole list: the catch-up)
      es.onerror = () => {
        if (es && es.readyState === EventSource.CLOSED) {
          drop();
          startPoll();
          later(BACKOFF_MS[Math.min(tries++, BACKOFF_MS.length - 1)]);
        }
      };
    }
    open();
    const t = timers.current;
    return () => { gone = true; drop(); stopPoll(); clearTimeout(retry); t.forEach(clearTimeout); };
    // onTasks / pollTasks are read once, at the stream's opening
  }, [reload, onLive]);

  return { live, ended, failed, reload };
}

// One write through the write door, as the signed-in person. Resolves to null
// when the hub took it, else the reason in words.
export async function sessionWrite(tool: "worker_reap" | "worker_resume", workerID: string): Promise<string | null> {
  const idem = (crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`).replace(/[^A-Za-z0-9-]/g, "");
  const r = await sendJSON<{ status?: string; result?: { error?: { message?: string } } }>("POST", "/v1/fleet/write",
    { tool, args_json: JSON.stringify({ worker_id: workerID, idempotency_key: idem }) });
  if (!r.ok) return r.error || (r.status ? `HTTP ${r.status}` : "network");
  if (r.data?.status === "failed") return r.data.result?.error?.message || "failed";
  return null;
}
