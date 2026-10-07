// The app shell's decisions (claude-fleet#1989): the menu by role, what the
// sidebar says about the viewer, and the shared string builders.
import test from 'node:test';
import assert from 'node:assert/strict';
import { useLocale, fmtCompact, fmtDate, fmtAgo } from '../dist/lib/i18n.js';
import { navFor, pageAllowed, isAdmin, viewer, fmtTokens, spark, ctxBar, liveLine, esc, titleOf, PAGES } from '../dist/lib/shell.js';

const USER = ['overview', 'sessions', 'devices', 'config'];
const ADMIN = [...USER, 'subscriptions', 'machines', 'people', 'settings', 'audit'];

test('a user sees their four pages and no Admin group', () => {
  const nav = navFor(USER);
  assert.deepEqual(nav.map((x) => x.id), ['overview', 'sessions', 'devices', 'config']);
  assert.ok(!nav.some((x) => x.heading), 'no Admin heading for a user');
  assert.deepEqual(nav.map((x) => x.href), ['/', '/sessions', '/connect', '/config']);
});

test('an admin also sees the Admin group: the five admin pages (#1990)', () => {
  const nav = navFor(ADMIN);
  const i = nav.findIndex((x) => x.heading === 'Admin');
  assert.equal(i, 4);
  const admin = nav.slice(i + 1);
  assert.deepEqual(admin.map((x) => x.id), ['subscriptions', 'machines', 'people', 'settings', 'audit']);
  assert.deepEqual(admin.map((x) => x.href), ['/subscriptions', '/nodes', '/admin/users', '/admin/settings', '/admin/audit']);
  // The old admin pages are gone from the menu, not hidden.
  assert.deepEqual(navFor([...ADMIN, 'credentials', 'access']).length, nav.length);
  assert.ok(nav.every((x) => x.heading || x.href), 'every item links somewhere');
});

test('no pages, or a broken answer, is no menu', () => {
  assert.deepEqual(navFor([]), []);
  assert.deepEqual(navFor(undefined), []);
  assert.deepEqual(navFor(['nonsense']), []);
});

test('the page gate reads /v1/me pages, not the role', () => {
  const user = { role: 'user', pages: USER };
  assert.ok(pageAllowed(user, 'sessions'));
  assert.ok(!pageAllowed(user, 'machines'));
  assert.ok(!pageAllowed(null, 'overview'));
  assert.ok(!pageAllowed({ role: 'admin' }, 'overview'), 'no pages listed = nothing allowed');
});

test('roles: admin and the operator token are admins, a user is not', () => {
  assert.ok(isAdmin({ role: 'admin' }));
  assert.ok(isAdmin({ role: 'operator' }));
  assert.ok(!isAdmin({ role: 'user' }));
  assert.ok(!isAdmin(null));
});

test('the viewer line: name, role · door, sign-out only with a cookie', () => {
  assert.deepEqual(viewer({ via: 'github', role: 'user', name: 'alice', can_logout: true }),
    { name: 'alice', sub: 'User · GitHub', initials: 'AL', logout: true });
  assert.equal(viewer({ via: 'token', role: 'operator' }).sub, 'Admin · token');
  assert.equal(viewer({ via: 'token', role: 'operator' }).logout, false);
  assert.equal(viewer(null), null);
});

test('every page has a title', () => {
  for (const p of PAGES) assert.ok(titleOf(p.id));
  assert.equal(titleOf('devices'), 'Devices & SSH');
});

test('token counts read like the tiles', () => {
  assert.equal(fmtTokens(0), '0');
  assert.equal(fmtTokens(950), '950');
  assert.equal(fmtTokens(38_200_000), '38.2M');
  assert.equal(fmtTokens(212_400_000), '212.4M');
  assert.equal(fmtTokens(1_310_000_000), '1.31B');
  assert.equal(fmtTokens(2_000_000), '2M');
});

test('spark and ctx bar survive empty input', () => {
  assert.match(spark([], 'red'), /<svg class="spark"/);
  assert.match(spark([5], 'red', true), /opacity=".12"/);
  assert.equal(ctxBar(null), '<span class="ctx">—</span>');
  assert.match(ctxBar(67), /class="warn" style="width:67%"/);
  assert.match(ctxBar(140), /width:100%/);
});

test('the live line counts sessions and online machines', () => {
  assert.equal(liveLine(null), '');
  assert.equal(liveLine({ sessions: [{}], nodes: [] }), 'Live · 1 session');
  assert.equal(liveLine({ sessions: [{}, {}], nodes: [{ availability: 'online' }, { availability: 'lost' }] }), 'Live · 2 sessions · 1 of 2 machines online');
});

test('esc escapes markup', () => {
  assert.equal(esc('<a href="x">&\'</a>'), '&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;');
  assert.equal(esc(null), '');
});

test('numbers and times follow the reader: 2.12 亿 · 10月6日 18:20 · 6 分钟前', () => {
  assert.equal(fmtCompact(212_400_000, 'zh-CN'), '2.12 亿');
  assert.equal(fmtCompact(1_310_000_000, 'zh-CN'), '13.1 亿');
  assert.equal(fmtCompact(38_200, 'zh-CN'), '3.82 万');
  assert.equal(fmtCompact(950, 'zh-CN'), '950');
  assert.equal(fmtCompact(42_400_000, 'zh-CN'), '4240 万');
  assert.equal(fmtCompact(4_240_000, 'zh-CN'), '424 万');
  assert.equal(fmtCompact(1.234e12, 'zh-CN'), '12340 亿');
  const at = new Date(2026, 9, 6, 18, 20).getTime();
  assert.equal(fmtDate(at, 'zh-CN'), '10月6日 18:20');
  assert.equal(fmtDate(at, 'en'), 'Oct 6, 18:20');
  assert.equal(fmtDate(at, 'en', false), 'Oct 6');
  assert.equal(fmtDate('nope', 'en'), '—');
  assert.equal(fmtAgo(at - 6 * 60000, at, 'zh-CN'), '6 分钟前');
  assert.equal(fmtAgo(at - 6 * 60000, at, 'en'), '6 min ago');
  assert.equal(fmtAgo(at, at, 'zh-CN'), '刚刚');
});

test('the menu and the viewer line speak Chinese too', () => {
  try {
    useLocale('zh-CN');
    assert.deepEqual(navFor(['overview', 'devices']).map((x) => x.label), ['概览', '设备与 SSH']);
    assert.equal(viewer({ via: 'github', role: 'user', name: 'alice' }).sub, '使用者 · GitHub');
    assert.equal(liveLine({ sessions: [{}, {}], nodes: [{ availability: 'online' }, { availability: 'lost' }] }), '实时 · 2 个会话 · 2 台机器 1 台在线');
    assert.equal(titleOf('config'), '配置');
  } finally { useLocale('en'); }
});
