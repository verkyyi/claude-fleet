// web/dist/app-shell.js — the signed-in app's frame (claude-fleet#1989):
// sidebar (the menu /v1/me lists), top bar (the page's title and a live
// line), the phone-width drawer, and the layers every page shares (toast,
// side drawer, confirm). A page is one call:
//
//   import { Shell } from './app-shell.js';
//   Shell.mount('sessions', async (ctx) => { ctx.el.innerHTML = '…'; });
//
// ctx is { me, admin, el, api, toast, drawer, modal, confirm, close, refresh }.
// The page draws into ctx.el; refresh() runs it again. The shell is the same
// for the admin pages (#1990) — they mount the same way.
//
// Fails closed: no /v1/me, no menu — the page says it could not tell who you
// are and offers to sign in again, rather than drawing a menu that guesses.
import { esc, ic, ICONS, navFor, pageAllowed, titleOf, isAdmin, viewer, liveLine, otherView } from './lib/shell.js';
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
    const e = new Error((body && (body.error || body.message)) || `${r.status} ${r.statusText}`.trim());
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
  // An admin's daily page and its whole-hub half, one click apart (claude-fleet#2515).
  const sw = otherView(me, page);
  const nav = navFor(me && me.pages).map((x) => x.heading
    ? `<div class="nav-h">${esc(x.heading)}</div>`
    : `<a class="navi" href="${esc(x.href)}"${x.id === page ? ' aria-current="page"' : ''}>${ic(x.icon)}<span>${esc(x.label)}</span><span class="cnt" data-cnt="${esc(x.id)}"></span></a>`).join('');
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
    <div class="main"><header class="top"><button class="btn ghost sm menu-btn" data-shell="menu" aria-label="${esc(t('ui.nav.menu'))}">${ic('menu')}</button><h1>${esc(titleOf(page))}</h1><span class="spacer"></span>${sw ? `<a class="btn sm${sw.admin ? '' : ' ghost'}" id="viewsw" href="${esc(sw.href)}">${ic(sw.admin ? 'shield' : 'home')}${esc(sw.label)}</a>` : ''}<span class="live" id="live" hidden><span class="dot ok pulse"></span><span class="txt"></span></span></header>
      <div class="content" id="content" aria-live="polite"><div class="ghostrow">${esc(t('ui.loading'))}</div></div></div>
    <div class="scrim nav-scrim" data-shell="menu" hidden style="z-index:44"></div>
  </div>`;
}

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

/** setCount writes a menu item's count. */
export function setCount(id, n) {
  const c = document.querySelector(`[data-cnt="${id}"]`);
  if (c) c.textContent = n == null ? '' : String(n);
}

async function mount(page, render) {
  document.body.innerHTML = '';
  let me = null, err = null;
  try { me = await api('/v1/me'); } catch (e) { err = e; }
  document.body.innerHTML = frame(me, page);
  document.title = `${titleOf(page)} · claudefleet`;
  wire();
  const el = $('#content');
  if (!me) {
    el.innerHTML = `<div class="panel"><div class="empty">${ic('alert')}<b>${esc(t('ui.err.who'))}</b><span>${esc(err ? err.message : '')}</span><a class="btn" href="/signin">${esc(t('ui.err.signinAgain'))}</a></div></div>`;
    return;
  }
  if (!pageAllowed(me, page)) {
    el.innerHTML = `<div class="panel"><div class="empty">${ic('lock')}<b>${esc(t('ui.err.notOnMenu'))}</b><span>${esc(t('ui.err.askAdmin'))}</span><a class="btn" href="/">${esc(t('ui.err.goOverview'))}</a></div></div>`;
    return;
  }
  const ctx = { me, admin: isAdmin(me), el, api, toast, drawer, modal, confirm, close, copy: copyText, setLive, setCount };
  // The fleet's session list, read once per draw and shared by the page and
  // the top bar's live line. A hub without the fleet module answers 404:
  // the line stays hidden and a page shows its empty state.
  let fleetP = null;
  ctx.fleet = (fresh) => {
    if (!fleetP || fresh) fleetP = api('/v1/fleet/fleet_sessions');
    return fleetP;
  };
  const live = (fresh) => ctx.fleet(fresh).then((fs) => { setLive(liveLine(fs)); setCount('sessions', (fs.sessions || []).length); }, () => setLive(''));
  ctx.refresh = async () => {
    try { await render(ctx); } catch (e) {
      el.innerHTML = `<div class="panel"><div class="empty">${ic('alert')}<b>${esc(t('ui.err.load'))}</b><span class="err">${esc(e.message)}</span><button class="btn" data-shell-retry>${esc(t('ui.err.retry'))}</button></div></div>`;
      const b = el.querySelector('[data-shell-retry]'); if (b) b.onclick = () => ctx.refresh();
    }
  };
  await ctx.refresh();
  live();
  setInterval(() => { if (!document.hidden) live(true); }, 30000);
}

export const Shell = Object.freeze({ mount, api, toast, setLive, setCount, copy: copyText });
if (typeof window !== 'undefined') window.Shell = Shell;
