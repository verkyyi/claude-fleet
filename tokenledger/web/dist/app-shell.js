// web/dist/app-shell.js — the signed-in app's frame (claude-fleet#1989):
// sidebar (the menu /v1/me lists), top bar (the page's title and a live
// line), the phone-width drawer, and the layers every page shares (toast,
// side drawer, confirm). A page is one call:
//
//   import { Shell } from './app-shell.js';
//   export default Shell.mount('sessions', async (ctx) => { ctx.el.innerHTML = '…'; });
//
// ctx is { me, admin, el, api, toast, drawer, modal, confirm, close, refresh,
// navigate, every, after, on, subscribe }. The page draws into ctx.el; refresh() runs it
// again. The shell is the same for the admin pages (#1990) — they mount the
// same way.
//
// One document, many pages (claude-fleet#2793): the frame is drawn once and
// /v1/me read once; a click on a page the route table (PAGES' `module`) knows
// swaps only ctx.el — history.pushState, the page's module import()ed once
// and kept. The page left is disposed: its every/after/on timers cleared, its
// own dispose() run, an open drawer closed. Its reads stay 30 s, so a page
// just seen draws at once and then reads again. Shell.mount is both the
// registration and, opened by its own old .html, the start.
//
// Data moves by itself (claude-fleet#2794): one push channel per tab
// (lib/stream.js) carries nodes, sessions and usage; a page takes a topic
// with ctx.subscribe(topic, fn[, {min}]) and loses it when it is left. The
// top bar says how fresh it all is (「N 秒前更新」, yellow while it reconnects,
// 轮询 on the fallback) and every block's [data-fresh-at] is repainted each
// second (lib/shell.js freshTag).
//
// Fails closed: no /v1/me, no menu — the page says it could not tell who you
// are and offers to sign in again, rather than drawing a menu that guesses.
import { esc, ic, ICONS, PAGES, navFor, pageAllowed, titleOf, isAdmin, viewer, liveLine, otherView, freshness, streamLine } from './lib/shell.js';
import { createStream } from './lib/stream.js';
import { routeFor, intercept, timerBag, readCache, isRead, CACHE_TTL } from './lib/router.js';
import { t, locale, chooseLocale } from './lib/i18n.js';

/** api fetches a same-origin JSON endpoint; a non-2xx throws an Error whose
 *  message is the hub's own line ({error} or the status). */
export async function api(url, opts = {}) {
  const init = { credentials: 'same-origin', headers: { Accept: 'application/json' }, ...opts };
  if (opts.json !== undefined) {
    init.method = init.method || 'POST';
    init.headers = { ...init.headers, 'Content-Type': 'application/json' };
    init.body = JSON.stringify(opts.json);
    delete init.json;
  }
  const r = await fetch(url, init);
  const text = await r.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  if (!r.ok) {
    // a fleet tool's refusal is {error: {code, message}} (claude-fleet#2527)
    const why = body && (body.error && typeof body.error === 'object' ? body.error.message : (body.error || body.message));
    const e = new Error(why || `${r.status} ${r.statusText}`.trim());
    e.status = r.status;
    throw e;
  }
  return body;
}

const $ = (s, r) => (r || document).querySelector(s);

function toast(msg) {
  let box = $('#toasts');
  if (!box) { box = document.createElement('div'); box.id = 'toasts'; box.className = 'toasts'; box.setAttribute('aria-live', 'polite'); document.body.appendChild(box); }
  const t = document.createElement('div');
  t.className = 'toast';
  t.innerHTML = ic('check') + '<span></span>';
  t.lastChild.textContent = msg;
  box.appendChild(t);
  setTimeout(() => t.remove(), 3600);
}

function layer() {
  let l = $('#layer');
  if (!l) { l = document.createElement('div'); l.id = 'layer'; document.body.appendChild(l); }
  return l;
}
function close() { layer().innerHTML = ''; }
function drawer(html) {
  layer().innerHTML = `<div class="scrim drawer-scrim" data-shell="scrim"><div class="drawer" role="dialog" aria-modal="true">${html}</div></div>`;
}
/** modal opens a dialog of the page's own (head, body, foot already drawn). */
function modal(html) {
  layer().innerHTML = `<div class="scrim" data-shell="scrim"><div class="modal" role="dialog" aria-modal="true">${html}</div></div>`;
}
function confirm(title, body, label, fn) {
  layer().innerHTML = `<div class="scrim" data-shell="scrim"><div class="modal" role="dialog" aria-modal="true">
    <div class="modal-h"><h3>${esc(title)}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>
    <div class="modal-b"><p>${body}</p></div>
    <div class="modal-f"><button class="btn ghost" data-shell="close">${esc(t('ui.cancel'))}</button><button class="btn danger solid" data-shell="confirm">${esc(label)}</button></div></div></div>`;
  layer()._confirm = fn;
  const b = $('[data-shell="confirm"]'); if (b) b.focus();
}

/** copyText copies to the clipboard and says so. */
export function copyText(text) {
  const ok = () => toast(t('ui.toast.copied'));
  try { navigator.clipboard.writeText(text).then(ok, () => toast(t('ui.toast.copyManual'))); } catch { toast(t('ui.toast.copyManual')); }
}

function frame(me, page) {
  const v = viewer(me);
  const nav = navFor(me && me.pages).map((x) => x.heading
    ? `<div class="nav-h">${esc(x.heading)}</div>`
    : `<a class="navi" href="${esc(x.href)}" data-page="${esc(x.id)}"${x.id === page ? ' aria-current="page"' : ''}>${ic(x.icon)}<span>${esc(x.label)}</span><span class="cnt" data-cnt="${esc(x.id)}"></span></a>`).join('');
  // The language switch (claude-fleet#2023): chooseLocale writes the cookie
  // and reloads with ?lang=, which the hub saves on the account.
  const zh = locale() === 'zh-CN';
  const langsw = `<div class="langsw" role="group" aria-label="${esc(t('ui.lang'))}"><button type="button" data-shell="lang" data-lang="zh-CN" lang="zh-CN" aria-pressed="${zh}">中文</button><button type="button" data-shell="lang" data-lang="en" lang="en" aria-pressed="${!zh}">EN</button></div>`;
  const foot = v ? `<div class="side-foot">${langsw}${v.logout
    ? `<form method="post" action="/logout"><button class="me" type="submit" title="${esc(t('ui.me.signout'))}"><span class="av" style="background:var(--brand)">${esc(v.initials)}</span><span class="who"><b>${esc(v.name)}</b><span>${esc(v.sub)}</span></span>${ic('out')}</button></form>`
    : `<div class="me"><span class="av" style="background:var(--brand)">${esc(v.initials)}</span><span class="who"><b>${esc(v.name)}</b><span>${esc(v.sub)}</span></span></div>`}</div>` : '';
  return `<div class="app" id="app">
    <aside class="side" id="side"><a class="logo" href="/"><span class="logo-mark"><svg viewBox="0 0 24 24">${ICONS.fleet}</svg></span>claudefleet</a>
      <div class="fleet-sw"><b>${esc(t('ui.fleet', { name: v ? v.name : '' }))}</b><span>${esc(location.host)}</span></div>
      <nav class="nav" aria-label="${esc(t('ui.nav.label'))}">${nav}</nav>${foot}</aside>
    <div class="main"><header class="top"><button class="btn ghost sm menu-btn" data-shell="menu" aria-label="${esc(t('ui.nav.menu'))}">${ic('menu')}</button><h1>${esc(titleOf(page))}</h1><span class="spacer"></span><span id="viewslot">${viewSwitch(me, page)}</span><span class="live" id="live" hidden><span class="dot ok pulse"></span><span class="txt"></span></span><span class="live" id="streamst" hidden><span class="fresh"></span></span></header>
      <div class="content" id="content" aria-live="polite"><div class="ghostrow">${esc(t('ui.loading'))}</div></div></div>
    <div class="scrim nav-scrim" data-shell="menu" hidden style="z-index:44"></div>
  </div>`;
}

// viewSwitch is the top bar's way to an admin's daily page's whole-hub half
// and back, one click apart (claude-fleet#2515).
function viewSwitch(me, page) {
  const sw = otherView(me, page);
  return sw ? `<a class="btn sm${sw.admin ? '' : ' ghost'}" id="viewsw" href="${esc(sw.href)}">${ic(sw.admin ? 'shield' : 'home')}${esc(sw.label)}</a>` : '';
}

// skeleton is what the content shows between a click and the page's data.
const skeleton = () => `<div class="skel" aria-busy="true" aria-label="${esc(t('ui.loading'))}"><i style="width:38%"></i><div class="panel"><i></i><i></i><i style="width:72%"></i><i style="width:56%"></i></div></div>`;

function wire() {
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-shell]');
    if (!el) return;
    const a = el.dataset.shell;
    if (a === 'scrim' && e.target !== el) return;
    if (a === 'menu') {
      const app = $('#app'); const open = !app.classList.contains('nav-open');
      app.classList.toggle('nav-open', open);
      const s = $('.nav-scrim'); if (s) s.hidden = !open;
    } else if (a === 'close' || a === 'scrim') close();
    else if (a === 'confirm') { const fn = layer()._confirm; close(); if (fn) fn(); }
    else if (a === 'lang') { if (el.getAttribute('aria-pressed') !== 'true') chooseLocale(el.dataset.lang); }
    else if (a === 'copy') copyText(el.dataset.text || '');
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
}

/** setLive writes the top bar's live line ("Live · 3 sessions …"); empty hides it. */
export function setLive(text) {
  const l = $('#live'); if (!l) return;
  l.hidden = !text; l.querySelector('.txt').textContent = text || '';
}

// paintStream writes the push channel's word into the top bar.
function paintStream() {
  const box = $('#streamst');
  if (!box || !R.stream) return;
  const st = R.stream.status();
  const l = streamLine(st);
  box.hidden = !l.text;
  box.dataset.mode = st.mode;
  const dot = 'dot' + (l.tone === 'ok' ? (st.mode === 'live' ? ' ok pulse' : ' ok') : l.tone === 'warn' ? ' warn' : '');
  // 「实时 · N 个会话」's dot is only as live as the channel behind it.
  const ld = $('#live .dot'); if (ld) ld.className = dot;
  const f = box.querySelector('.fresh');
  f.className = 'fresh ' + l.tone;
  f.textContent = l.text;
}

// paintFresh repaints every block's age (lib/shell.js freshTag).
function paintFresh() {
  const now = Date.now();
  for (const el of document.querySelectorAll('[data-fresh-at]')) {
    const v = el.dataset.freshAt;
    const f = freshness(/^\d+$/.test(v) ? Number(v) : v, now);
    el.className = 'fresh ' + f.tone;
    el.textContent = f.text;
  }
}

/** setCount writes a menu item's count. */
export function setCount(id, n) {
  const c = document.querySelector(`[data-cnt="${id}"]`);
  if (c) c.textContent = n == null ? '' : String(n);
}

// The app, once per document: who is looking, the frame, the page shown.
const R = { started: null, me: null, err: null, cur: null, seq: 0, pages: new Map(), cache: readCache(), fleetP: null, fleetAt: 0, perf: false, stream: null };

// The fleet's session list, shared by every page and the top bar's live line;
// a read younger than the cache's 30 s answers a page's first draw.
function fleet(fresh) {
  if (!R.fleetP || fresh || Date.now() - R.fleetAt > CACHE_TTL) {
    R.fleetAt = Date.now();
    R.fleetP = api('/v1/fleet/fleet_sessions');
    R.fleetP.catch(() => { R.fleetP = null; });
  }
  return R.fleetP;
}

/** mount registers a page — { id, title, render, dispose } — and returns it,
 *  so a module ends `export default Shell.mount(…)`. Opened by its own old
 *  .html (nothing started yet), it starts the app on itself. */
function mount(id, render, opts = {}) {
  const page = Object.freeze({ id, title: titleOf(id), render, dispose: opts.dispose || (() => {}) });
  R.pages.set(id, page);
  if (!R.started) start(id);
  return page;
}

/** start draws the frame and the page the address names (else `fallback`).
 *  app.html calls it with nothing; a page's old .html through mount. */
function start(fallback) {
  if (R.started) return R.started;
  R.started = (async () => {
    try {
      const q = new URLSearchParams(location.search).get('perf');
      if (q !== null) sessionStorage.setItem('fleet.perf', q === '0' ? '' : '1');
      R.perf = sessionStorage.getItem('fleet.perf') === '1';
    } catch { R.perf = false; }
    document.body.innerHTML = '';
    try { R.me = await api('/v1/me'); } catch (e) { R.err = e; }
    if (R.me) R.stream = createStream({ fetchJSON: (u) => api(u), onStatus: paintStream });
    const first = routeFor(location.pathname);
    const id = first ? first.id : (fallback || 'overview');
    if (!first && !fallback) history.replaceState(null, '', '/' + location.search + location.hash);
    document.body.innerHTML = frame(R.me, id);
    wire();
    document.addEventListener('click', onLink);
    window.addEventListener('popstate', () => { const p = routeFor(location.pathname); if (p) show(p.id); });
    await show(id);
    if (R.me) prefetch(R.me);
    if (R.me) {
      const live = (fs) => { setLive(liveLine(fs)); setCount('sessions', (fs.sessions || []).length); };
      fleet().then(live, () => setLive(''));
      // The session list moves by itself (claude-fleet#2794): every answer the
      // channel brings is the shared read and the top bar's line.
      R.stream.subscribe('sessions', (e) => {
        if (!e.body) return;
        R.fleetP = Promise.resolve(e.body); R.fleetAt = Date.now();
        live(e.body);
      });
      R.stream.start();
      setInterval(() => { if (!document.hidden) { paintStream(); paintFresh(); } }, 1000);
    }
  })();
  return R.started;
}

// prefetch loads the menu's other page modules once the first page is drawn
// and the browser is idle, so a first visit costs only its own reads. A
// module only registers its page; nothing draws until it is shown.
function prefetch(me) {
  const idle = window.requestIdleCallback || ((fn) => setTimeout(fn, 200));
  idle(() => {
    for (const p of PAGES) {
      if (p.module && pageAllowed(me, p.id) && !R.pages.has(p.id)) import(p.module).catch(() => {});
    }
  });
}

// onLink opens a same-origin page link in place; everything else (⌘-click,
// a new tab, a download, a path the app has no page for) is the browser's.
function onLink(e) {
  const a = e.target.closest && e.target.closest('a[href]');
  const hit = intercept(e, a, location.origin);
  if (!hit) return;
  e.preventDefault();
  navigate(hit.url);
}

/** navigate shows the page at url (a path, with its query) in place, and
 *  writes it to the history; a path the app has no page for is a real load. */
function navigate(url) {
  const u = new URL(url, location.origin);
  const p = routeFor(u.pathname);
  if (!p) { location.assign(u.href); return Promise.resolve(); }
  if (R.perf) performance.mark('nav-click');
  const same = u.pathname + u.search + u.hash === location.pathname + location.search + location.hash;
  if (!same) history.pushState(null, '', u.pathname + u.search + u.hash);
  const app = $('#app'); if (app) app.classList.remove('nav-open');
  const s = $('.nav-scrim'); if (s) s.hidden = true;
  return show(p.id);
}

// leave disposes the page shown: its timers and listeners, its own
// dispose(), and an open drawer or dialog.
function leave() {
  const c = R.cur;
  if (!c) return;
  R.cur = null;
  c.timers.clear();
  try { c.page && c.page.dispose(); } catch { /* the page is gone either way */ }
  close();
}

async function show(id) {
  const seq = ++R.seq;
  leave();
  // The frame's page-dependent parts: the menu's current item, the title,
  // the view switch.
  // A page with no menu item (one machine, claude-fleet#2796) lights the
  // list it was opened from: ?from=nodes the admin's Machines, else the first.
  const entry = PAGES.find((x) => x.id === id);
  const navId = entry && entry.within
    ? (new URLSearchParams(location.search).get('from') === 'nodes' && pageAllowed(R.me, 'machines') ? 'machines' : entry.within.find((w) => pageAllowed(R.me, w)) || id)
    : id;
  for (const a of document.querySelectorAll('a.navi')) {
    if (a.dataset.page === navId) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  }
  const h = $('header.top h1'); if (h) h.textContent = titleOf(id);
  const vs = $('#viewslot'); if (vs) vs.innerHTML = viewSwitch(R.me, id);
  document.title = `${titleOf(id)} · claudefleet`;
  const content = $('#content');
  const el = document.createElement('div');
  el.className = 'page';
  el.dataset.page = id;
  el.innerHTML = skeleton();
  content.replaceChildren(el);
  const me = R.me;
  if (!me) {
    el.innerHTML = `<div class="panel"><div class="empty">${ic('alert')}<b>${esc(t('ui.err.who'))}</b><span>${esc(R.err ? R.err.message : '')}</span><a class="btn" href="/signin">${esc(t('ui.err.signinAgain'))}</a></div></div>`;
    return;
  }
  const page = id;
  if (!pageAllowed(me, page)) {
    el.innerHTML = `<div class="panel"><div class="empty">${ic('lock')}<b>${esc(t('ui.err.notOnMenu'))}</b><span>${esc(t('ui.err.askAdmin'))}</span><a class="btn" href="/">${esc(t('ui.err.goOverview'))}</a></div></div>`;
    return;
  }
  const timers = timerBag();
  const cur = { id, el, timers, page: null, t0: Date.now() };
  R.cur = cur;
  let pg = R.pages.get(id);
  if (!pg) {
    const entry = PAGES.find((x) => x.id === id);
    try {
      const mod = await import(entry.module);
      pg = (mod && mod.default) || R.pages.get(id);
    } catch (e) {
      if (seq !== R.seq) return;
      el.innerHTML = `<div class="panel"><div class="empty">${ic('alert')}<b>${esc(t('ui.err.load'))}</b><span class="err">${esc(e.message)}</span></div></div>`;
      return;
    }
  }
  if (seq !== R.seq || !pg) return;
  cur.page = pg;
  // The page's reads: the first draw may take a read younger than 30 s, so
  // a page just seen is drawn at once; every later read is fresh, and any
  // write empties the cache.
  let warm = true, hit = false;
  const capi = async (url, opts) => {
    if (!isRead(opts)) { R.cache.clear(); R.fleetP = null; return api(url, opts); }
    if (warm) { const b = R.cache.get(url); if (b !== undefined) { hit = true; return b; } }
    const body = await api(url, opts);
    R.cache.set(url, body);
    return body;
  };
  const ctx = {
    me, admin: isAdmin(me), el, api: capi, toast, drawer, modal, confirm, close, copy: copyText, setLive, setCount,
    fleet: (fresh) => { if (!fresh && warm && R.fleetP) hit = true; return fleet(fresh || !warm); },
    navigate, every: timers.every, after: timers.after, on: timers.on, perf: R.perf,
  };
  // subscribe hands fn each answer of a push topic while the page is shown;
  // {min} lets one through at most every min ms (the last one waits). An
  // answer that came while the page was loading is handed over at once.
  ctx.subscribe = (topic, fn, opts = {}) => {
    if (!R.stream || timers.dead) return;
    const min = opts.min || 0;
    let ran = 0, pending = null;
    const run = (e) => {
      if (timers.dead) return;
      const wait = ran + min - Date.now();
      if (min && wait > 0) {
        const had = pending; pending = e;
        if (!had) timers.after(wait, () => { const x = pending; pending = null; if (x) run(x); });
        return;
      }
      ran = Date.now();
      try { fn(e); } catch { /* the next answer tries again */ }
    };
    timers.hold(R.stream.subscribe(topic, run));
    const l = R.stream.latest(topic);
    if (l && l.at >= cur.t0) timers.after(0, () => run(l));
  };
  ctx.refresh = async () => {
    if (timers.dead) return;
    try { await pg.render(ctx); } catch (e) {
      if (timers.dead) return;
      el.innerHTML = `<div class="panel"><div class="empty">${ic('alert')}<b>${esc(t('ui.err.load'))}</b><span class="err">${esc(e.message)}</span><button class="btn" data-shell-retry>${esc(t('ui.err.retry'))}</button></div></div>`;
      const b = el.querySelector('[data-shell-retry]'); if (b) b.onclick = () => ctx.refresh();
    }
  };
  await ctx.refresh();
  warm = false;
  if (R.perf && seq === R.seq) {
    requestAnimationFrame(() => {
      try {
        performance.mark('nav-drawn');
        const m = performance.measure('nav', 'nav-click', 'nav-drawn');
        console.info(`[perf] ${id} ${Math.round(m.duration)}ms${hit ? ' (cache)' : ''}`);
      } catch { /* the first page has no click */ }
      performance.clearMarks(); performance.clearMeasures();
    });
  }
  // Drawn from what was read under 30 s ago: read again now.
  if (hit && seq === R.seq && !timers.dead) ctx.refresh();
}

/** timers is how many timers and listeners the page shown holds (a test's read). */
const timers = () => (R.cur ? R.cur.timers.count() : 0);

export const Shell = Object.freeze({ mount, start, navigate, timers, api, toast, setLive, setCount, copy: copyText });
if (typeof window !== 'undefined') window.Shell = Shell;
