// web/dist/lib/stream.js — the app's push channel, the page half
// (claude-fleet#2794, EPIC #2792 C2). One EventSource per tab on
// /v1/fleet/stream carries the topics a page draws from — `nodes` (/v1/nodes),
// `sessions` (fleet_sessions), `usage` (/v1/live) — already cut to the viewer
// by the hub. A page takes a topic with ctx.subscribe(topic, fn) (the shell
// drops it when the page is left); fn gets { body, observedAt, at }: the
// answer, when its source measured it (epoch ms, null = 时间未知), when it
// arrived here.
//
// The channel is never trusted to be alive because it is open (EPIC #2792
// risk: a proxy that holds the stream neither sends nor closes). Anything at
// all — an event, the hub's 20 s ping — re-arms a 30 s watchdog; past it, or
// on an error, the channel is down (the top bar goes yellow) and reconnects
// after 1, 2, 4, 8, then every 15 s. The hub answers every connect with the
// whole current picture, so a reconnect is the catch-up. A browser with no
// EventSource, or POLL_AFTER attempts in a row that stayed silent to the
// watchdog without a single word (a proxy that buffers the stream — an
// unplugged network errors at once and stays on the backoff), polls the
// topics' own routes every 10 s instead — the top bar says 轮询 — and tries
// the stream again every minute.
//
// No DOM here: app-shell.js runs it, web/test/stream.test.mjs pins it.

/** TOPICS are the topics the stream carries, in the hub's order. */
export const TOPICS = ['nodes', 'sessions', 'usage'];
/** WATCHDOG_MS: this long with nothing heard and the channel is down. */
export const WATCHDOG_MS = 30000;
/** BACKOFF is the wait before each reconnect, the last repeated. */
export const BACKOFF = [1000, 2000, 4000, 8000, 15000];
/** POLL_MS is the fallback's period; POLL_AFTER deaf attempts start it. */
export const POLL_MS = 10000;
export const POLL_AFTER = 2;
/** PROBE_EVERY: in poll mode, every this many polls the stream is tried again. */
export const PROBE_EVERY = 6;
/** POLL_URLS are each topic's own route, for the fallback. */
export const POLL_URLS = { nodes: '/v1/nodes', sessions: '/v1/fleet/fleet_sessions', usage: '/v1/live' };

const ms = (v) => { const n = v ? Date.parse(v) : NaN; return Number.isFinite(n) && n > 0 ? n : null; };
const newest = (xs, key) => {
  let best = null;
  for (const x of Array.isArray(xs) ? xs : []) { const n = ms(x && x[key]); if (n !== null && (best === null || n > best)) best = n; }
  return best;
};

/** observedOf is when a topic's body was measured at its source (epoch ms,
 *  null when it does not say) — what the hub puts in observed_at, worked out
 *  the same way for an answer the fallback read itself. */
export function observedOf(topic, body) {
  if (!body) return null;
  if (topic === 'nodes') return newest(body.nodes, 'last_heartbeat');
  if (topic === 'sessions') return newest(body.nodes, 'observed_at');
  if (topic === 'usage') return newest(body.sessions, 'seen_at');
  return null;
}

/** createStream is the channel. Seams: ES (the EventSource class), fetchJSON
 *  (the fallback's reads), T (timers), now; onStatus hears every change of
 *  status() — { mode: connecting | live | down | poll, lastAt, retries }. */
export function createStream({ url = '/v1/fleet/stream', topics = TOPICS, ES = globalThis.EventSource,
  fetchJSON, T = globalThis, now = () => Date.now(), onStatus = () => {} } = {}) {
  const subs = new Map(); // topic → Set(fn)
  const last = new Map(); // topic → { body, observedAt, at }
  let es = null, wd = 0, retryT = 0, pollT = 0, polls = 0;
  let mode = 'connecting', lastAt = null, retries = 0, deaf = 0, heardThis = false, stopped = false;

  const status = () => ({ mode, lastAt, retries });
  const emit = () => { try { onStatus(status()); } catch { /* a listener's fault is its own */ } };
  const setMode = (m) => { mode = m; emit(); };

  function deliver(topic, entry) {
    last.set(topic, entry);
    for (const fn of [...(subs.get(topic) || [])]) {
      try { fn(entry); } catch { /* one page's fault does not stop the rest */ }
    }
  }

  function armWatchdog() {
    if (wd) T.clearTimeout(wd);
    wd = T.setTimeout(() => { wd = 0; fail(true); }, WATCHDOG_MS);
  }

  function closeES() {
    if (es) { try { es.close(); } catch { /* already gone */ } es = null; }
    if (wd) { T.clearTimeout(wd); wd = 0; }
  }

  function stopPoll() { if (pollT) { T.clearInterval(pollT); pollT = 0; } }

  // heard is anything at all arriving: the channel is alive.
  function heard() {
    lastAt = now();
    armWatchdog();
    if (!heardThis) { heardThis = true; deaf = 0; retries = 0; }
    if (mode !== 'live') { stopPoll(); setMode('live'); } else emit();
  }

  function onEvent(topic, e) {
    let f;
    try { f = JSON.parse(e.data); } catch { return; }
    heard();
    deliver(topic, { body: f.body, observedAt: ms(f.observed_at), at: lastAt });
  }

  function connect() {
    retryT = 0;
    if (stopped) return;
    if (typeof ES !== 'function') { poll(); return; }
    closeES();
    const q = (url.includes('?') ? '&' : '?') + 'topics=' + topics.join(',');
    try { es = new ES(url + q); } catch { es = null; poll(); return; }
    heardThis = false;
    const mine = es;
    for (const tp of topics) es.addEventListener(tp, (e) => { if (es === mine) onEvent(tp, e); });
    es.addEventListener('ping', () => { if (es === mine) heard(); });
    // The browser's own retry is not ours to wait on: a channel that errs is
    // closed and reconnected on BACKOFF.
    es.onerror = () => { if (es === mine) fail(); };
    armWatchdog();
  }

  // fail is the channel gone quiet (silent: the watchdog) or broken: down,
  // and back on BACKOFF — or, after POLL_AFTER silent attempts that never
  // heard a word, the fallback.
  function fail(silent) {
    if (stopped) return;
    closeES();
    if (silent && !heardThis) deaf++;
    if (mode === 'poll') return; // a probe that failed: the poll goes on
    if (deaf >= POLL_AFTER) { poll(); return; }
    setMode(lastAt === null ? 'connecting' : 'down');
    const d = BACKOFF[Math.min(retries, BACKOFF.length - 1)];
    retries++;
    if (retryT) T.clearTimeout(retryT);
    retryT = T.setTimeout(connect, d);
  }

  function poll() {
    if (stopped) return;
    closeES();
    if (mode !== 'poll') setMode('poll');
    if (pollT || !fetchJSON) return;
    const tick = async () => {
      polls++;
      await Promise.all(topics.map(async (tp) => {
        try {
          const body = await fetchJSON(POLL_URLS[tp]);
          if (mode !== 'poll') return; // the stream came back meanwhile
          lastAt = now();
          deliver(tp, { body, observedAt: observedOf(tp, body), at: lastAt });
        } catch { /* the next tick tries again */ }
      }));
      if (mode === 'poll') emit();
      if (mode === 'poll' && polls % PROBE_EVERY === 0 && typeof ES === 'function') connect();
    };
    pollT = T.setInterval(tick, POLL_MS);
    tick();
  }

  return {
    start() { if (!es && !pollT && !retryT && !stopped) connect(); return this; },
    stop() { stopped = true; closeES(); stopPoll(); if (retryT) { T.clearTimeout(retryT); retryT = 0; } },
    /** subscribe calls fn with each answer of topic; returns the off. */
    subscribe(topic, fn) {
      if (!subs.has(topic)) subs.set(topic, new Set());
      subs.get(topic).add(fn);
      return () => { const s = subs.get(topic); if (s) s.delete(fn); };
    },
    /** latest is topic's last answer, or undefined. */
    latest: (topic) => last.get(topic),
    status,
    /** subscribers is how many fns hold topic (a test's read). */
    subscribers: (topic) => (subs.get(topic) ? subs.get(topic).size : 0),
  };
}
