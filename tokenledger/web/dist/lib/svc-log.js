// web/dist/lib/svc-log.js — a service's log, live (claude-fleet#2797, EPIC
// #2792 C5), the page half. The machine page picks a row of 服务与定时任务 and
// this follows its log: GET /v1/nodes/<host>/services/<login>/<name>/log, an
// EventSource the hub feeds — the node reads the file, the hub masks every
// credential-shaped string and cuts it to the viewer (another login's entry
// is 403 「只有管理员看得到」; the page never sees the file system).
//
// First a HEAD (an EventSource cannot read a status): 403 / 404 / 503 are
// words, not a retry loop. Then the stream: its first `lines` after every
// (re)connect is the hub's recent lines — the buffer starts over from it —
// and every later one is new lines. `end` (the node stopped, the link went),
// an error, or WATCHDOG_MS with nothing heard (the hub pings every 20 s) is
// a reconnect on BACKOFF. older() reads the page before the first line
// (?before=<offset>) — PAGE lines at a time, MAX_LINES in all.
//
// No DOM here: machine.js draws it, web/test/svc-log.test.mjs pins it.

/** PAGE is one page of lines (the first screen, and each page scrolled up);
 *  MAX_LINES the most the view holds. */
export const PAGE = 200;
export const MAX_LINES = 2000;
/** WATCHDOG_MS: this long with nothing heard and the stream is down. */
export const WATCHDOG_MS = 45000;
/** BACKOFF is the wait before each reconnect, the last repeated. */
export const BACKOFF = [1000, 2000, 4000, 8000, 15000];

/** logPath is a register entry's log route. */
export function logPath(host, login, name) {
  const e = encodeURIComponent;
  return `/v1/nodes/${e(host)}/services/${e(login)}/${e(name)}/log`;
}

/** refusal is what a HEAD's status means: '' (go ahead) or a reason —
 *  denied (403, another login's), gone (404), offline (503: the login's node
 *  program is not connected, or too old). */
export function refusal(status) {
  if (status === 403) return 'denied';
  if (status === 404) return 'gone';
  if (status === 503) return 'offline';
  return status && status >= 400 ? 'error' : '';
}

/** atBottom is whether a scrolled box shows its last line. */
export function atBottom(box, slack = 8) {
  return box.scrollHeight - box.scrollTop - box.clientHeight <= slack;
}

const ms = (v) => { const n = v ? Date.parse(v) : NaN; return Number.isFinite(n) && n > 0 ? n : null; };
const toLine = (l) => ({ text: String((l && l.text) || ''), ts: ms(l && l.ts) });

/** createLog follows one entry's log. Seams: ES (EventSource), head(url) →
 *  status, getJSON(url) → body, T (timers), now. onChange(kind, lines) hears
 *  every change: reset (the whole buffer), append (new lines at the end),
 *  prepend (older lines at the start), status. */
export function createLog({ url, ES = globalThis.EventSource, head, getJSON, T = globalThis,
  now = () => Date.now(), onChange = () => {} } = {}) {
  const st = {
    lines: [], from: 0, start: false, follow: true, mode: 'connecting', why: '', skipped: 0,
    lastAt: null, olderBusy: false, retries: 0,
  };
  let es = null, wd = 0, retryT = 0, stopped = false, fresh = true;

  const emit = (kind, lines) => { try { onChange(kind, lines || [], st); } catch { /* the page's fault is its own */ } };
  const setMode = (m, why = '') => { st.mode = m; st.why = why; emit('status'); };

  function closeES() {
    if (es) { try { es.close(); } catch { /* gone */ } es = null; }
    if (wd) { T.clearTimeout(wd); wd = 0; }
  }
  function armWatchdog() {
    if (wd) T.clearTimeout(wd);
    wd = T.setTimeout(() => { wd = 0; fail(); }, WATCHDOG_MS);
  }
  function heard() {
    st.lastAt = now();
    st.retries = 0;
    armWatchdog();
    if (st.mode !== 'live') setMode('live');
  }
  function trim() {
    const k = st.lines.length - MAX_LINES;
    if (k > 0) { st.lines.splice(0, k); st.start = false; return true; }
    return false;
  }

  function onLines(e) {
    let f;
    try { f = JSON.parse(e.data); } catch { return; }
    heard();
    const lines = (Array.isArray(f.lines) ? f.lines : []).map(toLine);
    st.skipped += f.skipped || 0;
    if (fresh || f.rotated) {
      // The hub's recent lines after a (re)connect, or a new file: the view
      // starts over from them.
      fresh = false;
      st.lines = lines;
      st.from = Number(f.from) || 0;
      st.start = !!f.start;
      trim();
      emit('reset', st.lines);
      return;
    }
    if (f.skipped) lines.unshift({ text: '', ts: null, skipped: f.skipped });
    st.lines.push(...lines);
    if (trim()) { emit('reset', st.lines); return; }
    emit('append', lines);
  }

  async function connect() {
    retryT = 0;
    if (stopped) return;
    closeES();
    if (head) {
      let status = 0;
      try { status = await head(url); } catch (e) { status = (e && e.status) || 0; }
      if (stopped) return;
      const why = refusal(status);
      if (why === 'denied' || why === 'gone') { setMode('refused', why); return; }
      if (why) { retry(why); return; }
    }
    if (typeof ES !== 'function') { setMode('refused', 'nostream'); return; }
    fresh = true;
    try { es = new ES(url); } catch { retry('error'); return; }
    const mine = es;
    es.addEventListener('lines', (e) => { if (es === mine) onLines(e); });
    es.addEventListener('ping', () => { if (es === mine) heard(); });
    es.addEventListener('end', (e) => {
      if (es !== mine) return;
      let why = '';
      try { why = JSON.parse(e.data).error || ''; } catch { /* plain end */ }
      fail(why ? 'error' : '');
    });
    es.onerror = () => { if (es === mine) fail(); };
    armWatchdog();
  }

  function retry(why) {
    setMode(why === 'offline' ? 'offline' : 'down', why);
    const d = BACKOFF[Math.min(st.retries, BACKOFF.length - 1)];
    st.retries++;
    if (retryT) T.clearTimeout(retryT);
    retryT = T.setTimeout(connect, d);
  }
  function fail(why = '') {
    if (stopped) return;
    closeES();
    retry(why);
  }

  return {
    state: st,
    start() { if (!es && !retryT && !stopped) connect(); return this; },
    stop() {
      stopped = true;
      closeES();
      if (retryT) { T.clearTimeout(retryT); retryT = 0; }
    },
    /** setFollow says whether the view keeps to the newest line. */
    setFollow(v) { if (st.follow !== !!v) { st.follow = !!v; emit('status'); } },
    /** canOlder: there is a page before the first line, and room for it. */
    canOlder: () => !st.start && !st.olderBusy && st.lines.length < MAX_LINES && !!getJSON && st.mode !== 'connecting',
    /** older reads the page before the first line; false when there is none. */
    async older() {
      if (!this.canOlder()) return false;
      st.olderBusy = true;
      const at = st.from;
      try {
        const p = await getJSON(url + '?before=' + at);
        if (stopped || st.from !== at) return false;
        const lines = (Array.isArray(p && p.lines) ? p.lines : []).map(toLine).slice(-(MAX_LINES - st.lines.length));
        st.lines.unshift(...lines);
        st.from = Number(p && p.from) || 0;
        st.start = !!(p && p.start) || lines.length === 0;
        emit('prepend', lines);
        return lines.length > 0;
      } catch {
        return false;
      } finally {
        st.olderBusy = false;
      }
    },
  };
}
