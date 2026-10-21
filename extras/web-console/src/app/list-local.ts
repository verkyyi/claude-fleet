// list-local.ts — the session list kept in this browser (task T47B): opening
// the console again draws the last list at once — rows, groups, order, counts,
// the board's digest and the answer's ETag — from IndexedDB, before the hub has
// answered; the hub's answer then replaces it (a 304 to If-None-Match keeps it).
//
// The same store as the conversation's (chat/local.ts, task KSQG) and the same
// rules: one key «lst · principal»; writing for one person drops every other
// person's keys (theirs the conversation's too, and a chat write for another
// person drops this one), so a browser holds one person's list at most.
// Sign-out and 「清除本机缓存」 clear the whole store. A view (以他的视角看) and
// a read-only ticket neither read nor write — mayCache, decided by the caller.
// A list older than MAX_AGE is not drawn. Pure but for browserBackend, so
// test/list-local.mjs runs it as it is.
import type { Board, SessionRow } from "@/shared/sessions";
import type { TasksResponse } from "./task-state.ts"; // .ts: test/list-local.mjs runs this file as it is
import { KEY_SEP, browserBackend, type Backend } from "./chat/local.ts";

export const MAX_AGE_MS = 7 * 24 * 3600_000;

export type ListSnap = {
  live: SessionRow[];
  ended: SessionRow[] | null;
  board: Board | null;
  etag: string;           // the live answer's ETag: sent back as If-None-Match
  tasks: TasksResponse;
  at: number;
};

export const listKey = (principal: string) => `lst${KEY_SEP}${principal}`;
const principalOf = (key: string) => key.split(KEY_SEP)[1] || "";

function valid(v: unknown): v is ListSnap {
  const s = v as ListSnap | null;
  return !!s && typeof s === "object" && Array.isArray(s.live) && typeof s.at === "number"
    && !!s.tasks && Array.isArray(s.tasks.tasks) && (s.ended === null || Array.isArray(s.ended))
    && (s.board === null || (!!s.board && Array.isArray(s.board.rows) && typeof s.board.count === "number"))
    && typeof s.etag === "string";
}

export function listCache(b: Backend) {
  return {
    // the one person's list this browser keeps — read BEFORE /v1/me answers, so
    // the two run side by side; the caller draws it only when /v1/me names that
    // same person. An expired or broken one is dropped.
    async readAny(now = Date.now()): Promise<{ principal: string; snap: ListSnap } | null> {
      const ks = (await b.keys()).filter((k) => k.startsWith(`lst${KEY_SEP}`));
      if (ks.length !== 1) return null;
      const snap = await b.get(ks[0]);
      if (!valid(snap) || now - snap.at > MAX_AGE_MS || snap.at > now + 60_000) { await b.del(ks[0]); return null; }
      return { principal: principalOf(ks[0]), snap };
    },
    async read(principal: string, now = Date.now()): Promise<ListSnap | null> {
      const any = principal ? await this.readAny(now) : null;
      return any && any.principal === principal ? any.snap : null;
    },
    // keep the hub's answer; every other person's keys go
    async write(principal: string, snap: Omit<ListSnap, "at">, now = Date.now()): Promise<void> {
      if (!principal) return;
      for (const k of await b.keys()) if (principalOf(k) !== principal) await b.del(k);
      await b.put(listKey(principal), { ...snap, at: now } satisfies ListSnap);
    },
  };
}

let shared: ReturnType<typeof listCache> | null | undefined;
export function browserListCache(): ReturnType<typeof listCache> | null {
  if (shared === undefined) { const b = browserBackend(); shared = b ? listCache(b) : null; }
  return shared;
}

// The first time the list is on the page, and from where: window.__fleetListFirst
// (the before / after measure of T47B) and a performance mark.
let marked = false;
export function markListFirst(layer: "local" | "net") {
  if (marked) return;
  marked = true;
  try {
    performance.mark(`list:first:${layer}`);
    const w = window as unknown as { __fleetListFirst?: { layer: string; ms: number } };
    w.__fleetListFirst ??= { layer, ms: Math.round(performance.now()) };
  } catch { /* no performance API */ }
}
