// local.ts — the conversation kept in this browser (task KSQG): opening the
// chat again draws the last history at once, from IndexedDB, before any answer
// comes back. Three layers, each only ever replaced by a later one:
//
//   local (this browser) < copy (the entry's, ?cached=1) < home (the record)
//
// What is kept follows the entry's copy (chat_mirror.go) item for item: the
// person's words, the reply's text, one line per tool step — never a tool's
// output, never an image's bytes or the name the home serves it by (its small
// preview only, ≤32 KB each, 2 MB in all, newest first) — and only the newest
// MAX_ITEMS items. A record's key is «principal · provider · session»; a
// pointer per «principal · provider» says which session is current. Writing
// for one person drops every other person's records, so a browser holds one
// person's history at most. Sign-out and 「清除本机缓存」 delete all of it. A
// view (以他的视角看) and a read-only ticket neither read nor write — the
// caller decides that (mayCache). Pure but for the IndexedDB backend at the
// bottom, so test/chat-local.mjs runs it as it is.

export const MAX_ITEMS = 200;
const THUMB_ONE = 32 << 10;
const THUMB_ALL = 2 << 20;
const JPEG = "data:image/jpeg;base64,";

export type Layer = "local" | "copy" | "home";
const RANK: Record<Layer, number> = { local: 0, copy: 1, home: 2 };

// may a layer's answer go on the page, given the best one already shown?
// The home's always does (it is the record, read again and again); a lower
// layer never replaces a higher one, nor one of its own kind that came first.
export function mayShow(next: Layer, shown: Layer | null): boolean {
  if (next === "home") return true;
  return shown === null || RANK[next] > RANK[shown];
}

// may this page keep the conversation in the browser? Only the person's own
// page: not a view, not a read-only ticket, not before /v1/me said who it is.
export function mayCache(me: { person?: string; read_only?: boolean; view_as?: unknown } | null, viewAs = ""): boolean {
  return !!me?.person && !me.read_only && !me.view_as && !viewAs;
}

// KEY_SEP joins a key's parts; its second part is always the principal, so a
// write for one person drops every other person's keys — the list's too
// (list-local.ts keeps «lst · principal» in this same store).
export const KEY_SEP = "\u001f";
const sep = KEY_SEP;
export const pointerKey = (principal: string, provider: string) => `cur${sep}${principal}${sep}${provider}`;
export const recordKey = (principal: string, provider: string, session: string) =>
  `rec${sep}${principal}${sep}${provider}${sep}${session || "-"}`;
const principalOf = (key: string) => key.split(sep)[1] || "";

type Obj = Record<string, unknown>;

function pic(g: Obj, left: { n: number }): Obj {
  const out: Obj = {};
  for (const k of ["w", "h", "big"]) if (k in g) out[k] = g[k];
  const th = g.thumb;
  if (typeof th === "string" && th.startsWith(JPEG) && th.length <= THUMB_ONE && th.length <= left.n) {
    out.thumb = th;
    left.n -= th.length;
  }
  return out;
}

// one item as the copy would keep it, or null when the copy keeps none
function keepItem(it: Obj, left: { n: number }): Obj | null {
  switch (it.t) {
    case "user": {
      const o = { ...it };
      if (Array.isArray(it.images)) o.images = (it.images as Obj[]).map((g) => pic(g || {}, left));
      return o;
    }
    case "image": {
      const o = pic(it, left);
      o.t = "image";
      if ("id" in it) o.id = it.id;
      return o;
    }
    case "image_more": return { t: "image_more", n: it.n };
    case "page": {
      const o: Obj = { t: "page" };
      for (const k of ["id", "title", "url", "status", "proposal", "version", "note"]) if (k in it) o[k] = it[k];
      return o;
    }
    case "text": case "stopped": case "error": return { ...it };
    case "tool": { const o = { ...it }; delete o.input; return o; }
    case "tool_result": return { t: "tool_result", id: it.id, error: it.error };
    default: return null;
  }
}

// trim: the newest MAX_ITEMS items the copy would keep, starting at a user line
// when one is in reach (so the first message drawn is never half a reply).
export function trim(items: unknown[], max = MAX_ITEMS): Obj[] {
  const left = { n: THUMB_ALL };
  const out: Obj[] = [];
  for (let i = items.length - 1; i >= 0 && out.length < max; i--) {
    const it = items[i];
    if (!it || typeof it !== "object") continue;
    const k = keepItem(it as Obj, left);
    if (k) out.push(k);
  }
  out.reverse();
  if (out.length >= max) {
    const u = out.findIndex((x) => x.t === "user");
    if (u > 0) out.splice(0, u);
  }
  return out;
}

export type Snapshot = { session: string; cwd?: string; models?: unknown[]; default?: string; items: Obj[]; at: number };

// The store underneath: IndexedDB in a browser, a Map in the test.
export interface Backend {
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  del(key: string): Promise<void>;
  keys(): Promise<string[]>;
  clear(): Promise<void>;
}

export function memoryBackend(): Backend & { map: Map<string, unknown> } {
  const map = new Map<string, unknown>();
  return {
    map,
    get: async (k) => (map.has(k) ? structuredClone(map.get(k)) : undefined),
    put: async (k, v) => { map.set(k, structuredClone(v)); },
    del: async (k) => { map.delete(k); },
    keys: async () => [...map.keys()],
    clear: async () => { map.clear(); },
  };
}

export function chatCache(b: Backend) {
  return {
    // the current session's history of this person on this side, or null
    async read(principal: string, provider: string): Promise<Snapshot | null> {
      if (!principal) return null;
      const cur = await b.get(pointerKey(principal, provider));
      if (typeof cur !== "string") return null;
      const s = (await b.get(recordKey(principal, provider, cur))) as Snapshot | undefined;
      return s && Array.isArray(s.items) && (s.session || "") === cur ? s : null;
    },
    // the one person this browser keeps (write drops every other's) and their
    // history on this side — read BEFORE /v1/me answers, so the two run side by
    // side; the caller draws it only when /v1/me names that same person
    async readAny(provider: string): Promise<{ principal: string; snap: Snapshot } | null> {
      const ks = (await b.keys()).filter((k) => k.startsWith(`cur${sep}`) && k.endsWith(`${sep}${provider}`));
      if (ks.length !== 1) return null;
      const principal = principalOf(ks[0]);
      const snap = await this.read(principal, provider);
      return snap ? { principal, snap } : null;
    },
    // keep the home's answer: this session becomes the current one; this side's
    // older sessions and every other person's records go
    async write(principal: string, provider: string, snap: Omit<Snapshot, "items" | "at"> & { items: unknown[] }, now = Date.now()): Promise<void> {
      if (!principal) return;
      const session = snap.session || "";
      const rk = recordKey(principal, provider, session);
      const mine = `rec${sep}${principal}${sep}${provider}${sep}`;
      for (const k of await b.keys()) {
        if (principalOf(k) !== principal) await b.del(k);
        else if (k.startsWith(mine) && k !== rk) await b.del(k);
      }
      await b.put(rk, { session, cwd: snap.cwd, models: snap.models, default: snap.default, items: trim(snap.items), at: now } satisfies Snapshot);
      await b.put(pointerKey(principal, provider), session);
    },
    clear: () => b.clear(),
  };
}

// ---- the browser's IndexedDB (absent, blocked or private mode ⇒ no cache) ----

const DB = "fleet-chat";
const STORE = "kv";

function idbBackend(): Backend | null {
  if (typeof indexedDB === "undefined") return null;
  let opened: Promise<IDBDatabase> | null = null;
  const db = () => (opened ??= new Promise<IDBDatabase>((ok, no) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => { r.result.createObjectStore(STORE); };
    r.onsuccess = () => ok(r.result);
    r.onerror = () => no(r.error);
    r.onblocked = () => no(new Error("blocked"));
  }));
  const run = <T>(mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest<T>) =>
    db().then((d) => new Promise<T>((ok, no) => {
      const t = d.transaction(STORE, mode);
      const q = f(t.objectStore(STORE));
      t.oncomplete = () => ok(q.result);
      t.onerror = () => no(t.error);
      t.onabort = () => no(t.error);
    }));
  return {
    get: (k) => run("readonly", (s) => s.get(k)),
    put: (k, v) => run("readwrite", (s) => s.put(v, k)).then(() => {}),
    del: (k) => run("readwrite", (s) => s.delete(k)).then(() => {}),
    keys: () => run("readonly", (s) => s.getAllKeys()).then((ks) => ks.map(String)),
    clear: () => run("readwrite", (s) => s.clear()).then(() => {}),
  };
}

let backend: Backend | null | undefined;
// the browser's one store (the chat's and the session list's), or null
export function browserBackend(): Backend | null {
  if (backend === undefined) backend = idbBackend();
  return backend;
}
let shared: ReturnType<typeof chatCache> | null | undefined;
// the browser's cache, or null where there is none
export function browserCache(): ReturnType<typeof chatCache> | null {
  if (shared === undefined) { const b = browserBackend(); shared = b ? chatCache(b) : null; }
  return shared;
}

// clearBrowserCache: sign-out and 「清除本机缓存」 — everything this browser kept
// (the conversation and the session list: one store).
// Bounded: a sign-out waits at most `ms` for it, then goes anyway.
export async function clearBrowserCache(ms = 800): Promise<boolean> {
  const c = browserCache();
  if (!c) return true;
  return Promise.race([
    c.clear().then(() => true, () => false),
    new Promise<boolean>((ok) => setTimeout(() => ok(false), ms)),
  ]);
}
