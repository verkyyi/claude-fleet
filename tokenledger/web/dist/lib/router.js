// web/dist/lib/router.js — the in-page navigation's decisions, with no DOM
// (claude-fleet#2793): which page a path is, which click the shell takes over
// instead of the browser, the timers a page owns, and the short read cache
// that lets a page just seen draw at once. app-shell.js runs them;
// web/test/router.test.mjs pins them.
//
// The route table is PAGES (lib/shell.js): a page's `href` is its path and its
// `module` the script that draws it — there is no second table.
import { PAGES } from './shell.js';

/** CACHE_TTL is how long a page's reads are good for a revisit (ms). */
export const CACHE_TTL = 30000;

/** routeFor is the page a path draws, or null when the app has none there. */
export function routeFor(pathname) {
  const p = String(pathname || '/').replace(/\/+$/, '') || '/';
  return PAGES.find((x) => x.href === p && x.module) || null;
}

/** intercept is the page a click should open in place, or null to let the
 *  browser have it: a modified click (⌘/⌃/⇧/⌥, a middle button), a link to a
 *  new tab, a download, another origin, a path the app has no page for. */
export function intercept(ev, a, origin) {
  if (!ev || !a || ev.defaultPrevented) return null;
  if (ev.button !== undefined && ev.button !== 0) return null;
  if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return null;
  if (a.target && a.target !== '_self') return null;
  if (a.hasAttribute ? a.hasAttribute('download') : a.download) return null;
  let u;
  try { u = new URL(a.href, origin); } catch { return null; }
  if (u.origin !== origin) return null;
  const page = routeFor(u.pathname);
  return page ? { page, url: u.pathname + u.search + u.hash } : null;
}

/** timerBag is the timers one page holds: every / after / on, all gone at
 *  clear(). After clear() it starts nothing, so a read that lands after the
 *  page was left cannot leave a poll behind. */
export function timerBag(T = globalThis) {
  const ivs = new Set(), tos = new Set(), offs = new Set();
  let dead = false;
  return {
    every(ms, fn) {
      if (dead) return 0;
      const id = T.setInterval(fn, ms); ivs.add(id); return id;
    },
    after(ms, fn) {
      if (dead) return 0;
      const id = T.setTimeout(() => { tos.delete(id); fn(); }, ms); tos.add(id); return id;
    },
    on(target, type, fn, opts) {
      if (dead || !target) return;
      target.addEventListener(type, fn, opts);
      offs.add(() => target.removeEventListener(type, fn, opts));
    },
    count: () => ivs.size + tos.size + offs.size,
    get dead() { return dead; },
    clear() {
      dead = true;
      for (const id of ivs) T.clearInterval(id);
      for (const id of tos) T.clearTimeout(id);
      for (const off of offs) off();
      ivs.clear(); tos.clear(); offs.clear();
    },
  };
}

/** readCache keeps GET answers for CACHE_TTL. get() answers only a fresh one;
 *  any write empties it, so what a page shows after a change is never older
 *  than the change. */
export function readCache(ttl = CACHE_TTL, now = () => Date.now()) {
  const m = new Map();
  return {
    get(url) {
      const e = m.get(url);
      if (!e) return undefined;
      if (now() - e.at > ttl) { m.delete(url); return undefined; }
      return e.body;
    },
    set(url, body) { m.set(url, { at: now(), body }); },
    clear() { m.clear(); },
    get size() { return m.size; },
  };
}

/** isRead is whether an api() call is a plain GET the cache may answer. */
export const isRead = (opts) => !opts || ((!opts.method || String(opts.method).toUpperCase() === 'GET') && opts.json === undefined && opts.body === undefined);
