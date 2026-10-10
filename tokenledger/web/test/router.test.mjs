// In-page navigation (claude-fleet#2793): which path is which page, which
// click the shell takes over, the timers a page owns, the 30 s read cache —
// and, read as source, that no page keeps a timer the shell cannot stop.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PAGES } from '../dist/lib/shell.js';
import { routeFor, pathParam, intercept, timerBag, readCache, isRead, CACHE_TTL } from '../dist/lib/router.js';

// A prefix page's path is one name under its href (/machines/<host>, claude-fleet#2796).
const pathOf = (p) => (p.prefix ? p.href + 'm4' : p.href);

const ORIGIN = 'https://hub.example';
const anchor = (href, attrs = {}) => ({ href, target: attrs.target || '', hasAttribute: (n) => n in attrs });
const click = (mods = {}) => ({ button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, defaultPrevented: false, ...mods });

test('every page in the menu is a route, and its path is its href', () => {
  for (const p of PAGES) {
    assert.ok(p.module && p.module.startsWith('/') && p.module.endsWith('.js'), `${p.id} names its module`);
    assert.equal(routeFor(pathOf(p)), p, pathOf(p));
  }
  assert.equal(routeFor('/sessions/'), routeFor('/sessions'), 'a trailing slash is the same page');
  assert.equal(routeFor(''), routeFor('/'));
  for (const p of ['/signin', '/sessions.html', '/v1/me', '/no-such', '/admin']) assert.equal(routeFor(p), null, p);
});

test('one machine is a page under /machines/; the bare path stays the list (claude-fleet#2796)', () => {
  const one = PAGES.find((p) => p.id === 'machine');
  assert.equal(routeFor('/machines').id, 'mymachines');
  assert.equal(routeFor('/machines/').id, 'mymachines', 'a trailing slash is still the list');
  assert.equal(routeFor('/machines/macmini'), one);
  assert.equal(routeFor('/machines/macmini/'), one);
  assert.equal(routeFor('/machines/a/b'), null, 'one name, no deeper');
  assert.equal(pathParam('/machines/macmini', one), 'macmini');
  assert.equal(pathParam('/machines/m%C3%A9', one), 'mé');
  assert.equal(pathParam('/sessions', routeFor('/sessions')), '');
  const hit = intercept(click(), anchor(ORIGIN + '/machines/macmini?from=nodes'), ORIGIN);
  assert.equal(hit.page, one);
  assert.equal(hit.url, '/machines/macmini?from=nodes');
});

test('a plain click on a page link opens it in place; between every pair of pages', () => {
  for (const from of PAGES) {
    for (const to of PAGES) {
      if (from === to) continue;
      const hit = intercept(click(), anchor(ORIGIN + pathOf(to)), ORIGIN);
      assert.ok(hit, `${from.id} → ${to.id}`);
      assert.equal(hit.page, to);
      assert.equal(hit.url, pathOf(to));
    }
  }
  // The query rides along (Audit's ?kind=).
  assert.equal(intercept(click(), anchor(ORIGIN + '/admin/audit?kind=fleet'), ORIGIN).url, '/admin/audit?kind=fleet');
});

test('the browser keeps ⌘/⌃/⇧/⌥-clicks, middle clicks, new tabs, downloads, other origins and non-pages', () => {
  const a = anchor(ORIGIN + '/sessions');
  for (const m of ['metaKey', 'ctrlKey', 'shiftKey', 'altKey']) assert.equal(intercept(click({ [m]: true }), a, ORIGIN), null, m);
  assert.equal(intercept(click({ button: 1 }), a, ORIGIN), null, 'middle click');
  assert.equal(intercept(click({ defaultPrevented: true }), a, ORIGIN), null, 'a page handled it');
  assert.equal(intercept(click(), anchor(ORIGIN + '/sessions', { target: '_blank' }), ORIGIN), null, 'new tab');
  assert.equal(intercept(click(), anchor(ORIGIN + '/sessions', { download: '' }), ORIGIN), null, 'download');
  assert.equal(intercept(click(), anchor('https://github.com/sessions'), ORIGIN), null, 'another origin');
  assert.equal(intercept(click(), anchor(ORIGIN + '/v1/admin/audit?format=csv'), ORIGIN), null, 'not a page');
  assert.equal(intercept(click(), anchor(ORIGIN + '/signin'), ORIGIN), null, 'not a page');
  assert.equal(intercept(click(), null, ORIGIN), null, 'not a link');
});

// A fake clock for timerBag: counts what is live.
function fakeTimers() {
  let n = 0;
  const live = new Map();
  return {
    live,
    setInterval: (fn) => { live.set(++n, fn); return n; },
    setTimeout: (fn) => { live.set(++n, fn); return n; },
    clearInterval: (id) => live.delete(id),
    clearTimeout: (id) => live.delete(id),
    fire: (id) => { const fn = live.get(id); live.delete(id); fn(); },
  };
}

test('leaving a page leaves no timer and no listener; a late read starts none', () => {
  const T = fakeTimers();
  const bag = timerBag(T);
  const target = { n: 0, addEventListener() { this.n++; }, removeEventListener() { this.n--; } };
  bag.every(15000, () => {});
  bag.every(30000, () => {});
  const once = bag.after(3000, () => {});
  bag.on(target, 'click', () => {});
  assert.equal(bag.count(), 4);
  assert.equal(T.live.size, 3);
  assert.equal(target.n, 1);
  T.fire(once);
  assert.equal(bag.count(), 3, 'a fired after() is forgotten');
  bag.clear();
  assert.equal(bag.count(), 0);
  assert.equal(T.live.size, 0, 'no timer survives the page');
  assert.equal(target.n, 0, 'no listener survives the page');
  // The page's read lands after it was left: whatever it tries to start, nothing runs.
  assert.equal(bag.every(1000, () => {}), 0);
  assert.equal(bag.after(1000, () => {}), 0);
  bag.on(target, 'click', () => {});
  assert.equal(T.live.size, 0);
  assert.equal(target.n, 0);
  assert.ok(bag.dead);
});

test('a read is good for 30 s, a write empties every read', () => {
  let now = 0;
  const c = readCache(CACHE_TTL, () => now);
  assert.equal(CACHE_TTL, 30000);
  c.set('/v1/nodes', { a: 1 });
  now = 29999;
  assert.deepEqual(c.get('/v1/nodes'), { a: 1 });
  now = 30001;
  assert.equal(c.get('/v1/nodes'), undefined, 'older than 30 s is not drawn');
  c.set('/v1/nodes', { a: 2 });
  c.clear();
  assert.equal(c.get('/v1/nodes'), undefined);
  assert.ok(isRead());
  assert.ok(isRead({}));
  assert.ok(isRead({ method: 'GET' }));
  assert.ok(!isRead({ method: 'PUT', json: {} }));
  assert.ok(!isRead({ json: { a: 1 } }), 'a json body is a POST');
  assert.ok(!isRead({ method: 'DELETE' }));
});

// The pages, read as source: every module registers itself as its default
// export, and every timer or document listener goes through the page's ctx
// (or its dispose) — a bare setInterval would outlive the page in place.
test('every page module exports its page and owns no stray timer', () => {
  const read = (m) => readFileSync(new URL('../dist' + m, import.meta.url), 'utf8');
  const sources = PAGES.map((p) => [p.module, read(p.module)]);
  sources.push(['/lib/sessions-view.js', read('/lib/sessions-view.js')]);
  for (const [m, src] of sources) {
    const p = PAGES.find((x) => x.module === m);
    if (p) assert.match(src, new RegExp(`export default Shell\\.mount\\('${p.id}'`), m);
    assert.ok(!/\bsetInterval\(/.test(src), `${m}: a bare setInterval (use ctx.every)`);
    assert.ok(!/document\.on\w+\s*=/.test(src), `${m}: a document handler (use ctx.on)`);
    assert.ok(!/\blocation\.(href|assign|replace)\b/.test(src), `${m}: a full page load (use ctx.navigate or a link)`);
  }
});

test('the shell reads /v1/me once per document and swaps only the content', () => {
  const shell = readFileSync(new URL('../dist/app-shell.js', import.meta.url), 'utf8');
  assert.equal((shell.match(/api\('\/v1\/me'\)/g) || []).length, 1, 'one /v1/me read');
  assert.match(shell, /history\.pushState/);
  assert.match(shell, /addEventListener\('popstate'/);
  assert.match(shell, /await import\(entry\.module\)/);
  // Leaving a page clears what it holds.
  assert.match(shell, /c\.timers\.clear\(\);/);
  assert.match(shell, /c\.page\.dispose\(\)/);
});
