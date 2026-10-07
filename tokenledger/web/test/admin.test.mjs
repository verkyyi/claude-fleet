// The five admin pages (claude-fleet#1990): Subscriptions' cards, headroom and
// the add-a-subscription flow (a fake machine delivers the credential),
// Machines' cards and the join wait, Users, Settings, Audit's days — and
// source checks that each page mounts as its menu id, asks before every
// destructive write, draws an empty state, and says every word through t().
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  pct, level, fmtIn, windowsOf, subscriptions, subState, credState, headroom, leaseRows, switchRows,
  addSubCommands, arrived, LABEL_RE, machineCards, joined, countdown, cleanLogin, GH_LOGIN_RE,
  userRows, settingValue, SETTING_GROUPS, AUDIT_KINDS, auditDays, auditWho,
} from '../dist/lib/admin.js';
import { useLocale } from '../dist/lib/i18n.js';
import { en } from '../dist/lib/i18n/en.js';
import { zhCN } from '../dist/lib/i18n/zh-CN.js';

const NOW = Date.parse('2026-10-07T12:00:00Z');
const iso = (ms) => new Date(ms).toISOString();

const LIMITS = {
  per_account: [
    { account_uuid: 'u-a', label: 'max-a', limits: { available: true, plan: 'Claude Max 20×', five_hour: { utilization: 0.42, resets_at: iso(NOW + 78 * 60000) }, seven_day: { utilization: 61, resets_at: iso(NOW + 3 * 86400000) } } },
    { account_uuid: 'codex:account:x', label: 'codex-1', limits: { available: true, source: 'codex', windows: [{ id: 'primary', minutes: 300, utilization: 0.9 }, { id: 'secondary', minutes: 10080, utilization: 0.2 }] } },
    { account_uuid: 'u-b', label: 'Personal', limits: { available: false, reason: 'no reading' } },
  ],
};
const ACCOUNTS = [{ account_uuid: 'u-a', email: 'a@example.com', subscription_type: 'max' }, { account_uuid: 'u-b', email: 'bee@example.com' }];
const CREDS = {
  credentials: [
    { principal_id: 'pool', provider: 'claude', account: 'max-a', created_at: iso(NOW - 86400000) },
    { principal_id: 'pool', provider: 'codex', account: 'codex-1', created_at: iso(NOW - 86400000), refresh_error: 'invalid_grant' },
    { principal_id: 'pool', provider: 'claude', account: 'spare', created_at: iso(NOW), secret_expires_at: iso(NOW + 5 * 86400000) },
    { principal_id: 'gh:7', provider: 'claude', account: 'mine', created_at: iso(NOW) },
    { principal_id: 'pool', provider: 'github', account: 'bot', created_at: iso(NOW) },
  ],
  paused: ['spare'],
};
const LIVE = { sessions: [
  { account: 'u-a', os_user: 'alice-mac', worktree: '/w/claude-fleet-issue-1950', started_at: iso(NOW - 600000) },
  { account: 'u-a', os_user: 'verkyyi', cwd: '/w/scratch-6', started_at: iso(NOW - 60000) },
  { account: '', os_user: 'x', session_id: 'abc' },
] };

test('utilization reads either scale; bars colour by the skip threshold', () => {
  assert.equal(pct(0.42), 42);
  assert.equal(pct(61), 61);
  assert.equal(pct(null), null);
  assert.equal(pct(-1), null);
  assert.equal(level(50), '');
  assert.equal(level(75), 'warn');
  assert.equal(level(90, 90), 'bad');
});

test('a Codex account\'s windows come from its window list', () => {
  const w = windowsOf(LIMITS.per_account[1].limits);
  assert.deepEqual([w.h5.p, w.h7.p], [90, 20]);
  assert.deepEqual(windowsOf({ available: false }), { h5: null, h7: null });
});

test('one card per subscription: usage joined to its pool credential, paused, live sessions', () => {
  const cards = subscriptions({ limits: LIMITS, accounts: ACCOUNTS, creds: CREDS, live: LIVE });
  assert.deepEqual(cards.map((c) => c.label), ['max-a', 'Personal', 'spare', 'codex-1']);
  const a = cards[0];
  assert.equal(a.cred.account, 'max-a');
  assert.equal(a.sessions, 2);
  assert.equal(a.h5.p, 42);
  assert.equal(a.paused, false);
  // usage with no pool credential: shown, but nothing to pause or remove
  assert.equal(cards[1].cred, null);
  // a pool credential no usage names yet is a card of its own, paused here
  const spare = cards[2];
  assert.equal(spare.h5, null);
  assert.equal(spare.paused, true);
  assert.equal(subState(spare), 'paused');
  // personal and GitHub credentials are not the pool
  assert.ok(!cards.some((c) => c.label === 'mine' || c.label === 'bot'));
  assert.equal(subState(cards[3], 85), 'full');
  assert.equal(subState(a, 85), 'active');
  assert.deepEqual(subscriptions({}), []);
});

test('the credential line says what is wrong with it', () => {
  useLocale('en');
  assert.equal(credState(null).tone, 'warn');
  assert.equal(credState({ refresh_error: 'x' }).tone, 'bad');
  assert.equal(credState({ refresh_error: 'invalid_grant', reauth_required: true }).text, 'Needs a new login');
  assert.equal(credState({ secret_expires_at: iso(NOW - 1) }, NOW).text, 'Expired');
  assert.equal(credState({ secret_expires_at: iso(NOW + 5 * 86400000), created_at: iso(NOW) }, NOW).tone, 'warn');
  assert.equal(credState({ created_at: iso(NOW) }, NOW).tone, 'ok');
});

test('pool headroom: the mean free share and the soonest reset, paused cards left out', () => {
  const cards = subscriptions({ limits: LIMITS, accounts: ACCOUNTS, creds: CREDS, live: LIVE });
  const h5 = headroom(cards, 'h5', NOW);
  assert.equal(h5.free, Math.round(((100 - 42) + (100 - 90)) / 2));
  assert.equal(h5.next, NOW + 78 * 60000);
  assert.equal(headroom([], 'h5', NOW), null);
  assert.equal(fmtIn(NOW + 78 * 60000, NOW), 'in 1h 18m');
  assert.equal(fmtIn(NOW - 1, NOW), '');
  try { useLocale('zh-CN'); assert.equal(fmtIn(NOW + 78 * 60000, NOW), '1 小时 18 分后'); } finally { useLocale('en'); }
});

test('who is on which: live sessions named by their GitHub account, newest first', () => {
  const cards = subscriptions({ limits: LIMITS, accounts: ACCOUNTS, creds: CREDS, live: LIVE });
  const rows = leaseRows(LIVE, cards, { users: [{ login: 'alice', machine_login: 'alice-mac' }] });
  assert.deepEqual(rows.map((r) => [r.session, r.person, r.sub]), [['scratch-6', 'verkyyi', 'max-a'], ['claude-fleet-issue-1950', 'alice', 'max-a']]);
  assert.deepEqual(leaseRows(null, cards, null), []);
  const sw = switchRows([{ from_account: 'u-a', to_account: 'codex:account:x', observed_at: iso(NOW) }], cards);
  assert.deepEqual([sw[0].from, sw[0].to], ['max-a', 'codex-1']);
});

// The add flow, run against a fake machine: the page polls the credential
// audit; nothing older than the start, of another provider or another label
// answers; the machine's put does.
test('adding a subscription: the commands, then the wait ends when a fake machine delivers', () => {
  assert.ok(LABEL_RE.test('max-e') && !LABEL_RE.test('has space') && !LABEL_RE.test('.dot') && !LABEL_RE.test(''));
  const claude = addSubCommands('claude', 'max-e');
  assert.deepEqual(claude.cmds, ['claude setup-token', '~/.claude/fleet/bin/fleet-creds-import.sh max-e']);
  assert.match(claude.note, /accounts\/max-e/);
  assert.deepEqual(addSubCommands('codex', 'cx2').cmds, ['CODEX_HOME=~/.codex-accounts/cx2 codex login', '~/.claude/fleet/bin/fleet-creds-import.sh --codex cx2']);

  const since = NOW;
  const audit = { audit: [
    { action: 'put', provider: 'claude', account: 'max-e', at: iso(since - 60000) }, // before the wait began
    { action: 'issue', provider: 'claude', account: 'max-e', at: iso(since + 1000) }, // a lease, not a delivery
    { action: 'put', provider: 'codex', account: 'max-e', at: iso(since + 1000) },   // another provider
  ] };
  assert.equal(arrived(audit, 'claude', 'max-e', since), null);
  // The fake machine runs the import: the hub records its put.
  audit.audit.unshift({ action: 'put', provider: 'claude', account: 'max-e', at: iso(since + 4000), detail: 'by operator' });
  const hit = arrived(audit, 'claude', 'max-e', since);
  assert.ok(hit);
  assert.equal(hit.detail, 'by operator');
  assert.equal(arrived(null, 'claude', 'max-e', since), null);
});

test('machines: lost last, load per core, trend and version carried', () => {
  const ms = machineCards({ machines: [
    { hostname: 'm5.lan', status: 'lost', load1: 0, ncpu: 8, sessions: 0, kind: 'fixed' },
    { hostname: 'mini2.tail.ts.net', status: 'online', load1: 4, ncpu: 8, sessions: 3, kind: 'fixed', load_hist: [0.1, 0.5] },
    { hostname: 'm4', status: 'maintenance', load1: 1, ncpu: 4, sessions: null, kind: 'ephemeral', maintenance: { reason: 'upgrade', by: 'verkyyi' } },
  ], nodes: [{ hostname: 'mini2.tail.ts.net', fleet_version: '0.4.1', endpoint_id: 'ep_a' }, { hostname: 'mini2.tail.ts.net', agent_version: '0.3.9', endpoint_id: 'ep_b' }] });
  assert.deepEqual(ms.map((m) => [m.name, m.status]), [['mini2', 'online'], ['m4', 'maintenance'], ['m5', 'lost']]);
  assert.equal(ms[0].loadCore, 0.5);
  assert.deepEqual(ms[0].hist, [0.1, 0.5]);
  assert.equal(ms[0].version, '0.4.1');
  assert.equal(ms[1].sessions, null);
  // Every enrollment on the machine: 「移除」 retires them all (claude-fleet#1928).
  assert.deepEqual(ms[0].eps, ['ep_a', 'ep_b']);
  assert.deepEqual(ms[2].eps, []);
  assert.deepEqual(machineCards(null), []);
});

test('the join wait ends when the code it minted is used; the countdown counts down', () => {
  const codes = { codes: [{ label: 'web-1', used_at: null }, { label: 'web-0', used_at: iso(NOW), joined_host: 'old' }] };
  assert.equal(joined(codes, 'web-1'), null);
  codes.codes[0].used_at = iso(NOW); codes.codes[0].joined_host = 'm5';
  assert.equal(joined(codes, 'web-1').joined_host, 'm5');
  assert.equal(countdown(NOW + 1800000, NOW), '30:00');
  assert.equal(countdown(NOW + 61000, NOW), '1:01');
  assert.equal(countdown(NOW - 5, NOW), '0:00');
});

test('users: a typed name is cleaned and checked; deploy admins first', () => {
  assert.equal(cleanLogin(' @octocat '), 'octocat');
  assert.equal(cleanLogin('https://github.com/octo-cat/'), 'octo-cat');
  assert.ok(GH_LOGIN_RE.test('octo-cat'));
  assert.ok(!GH_LOGIN_RE.test('-bad') && !GH_LOGIN_RE.test('a--b') && !GH_LOGIN_RE.test('x'.repeat(40)));
  const rows = userRows({ users: [{ login: 'zed', role: 'user' }, { login: 'amy', role: 'user' }, { login: 'verkyyi', role: 'admin', deploy: true }] });
  assert.deepEqual(rows.map((u) => u.login), ['verkyyi', 'amy', 'zed']);
  assert.deepEqual(userRows(null), []);
});

test('settings read what applies: stored, old variable or default', () => {
  const answer = { hub: [{ key: 'pool.skip_pct', value: '90', source: 'set' }, { key: 'fleet.spot', value: 'off', source: 'default' }] };
  assert.deepEqual(settingValue(answer, 'pool.skip_pct'), { value: '90', source: 'set' });
  assert.deepEqual(settingValue(answer, 'fleet.spot'), { value: 'off', source: 'default' });
  assert.deepEqual(settingValue({}, 'hub.public_meter'), { value: '', source: 'default' });
  // every setting drawn has its name and help in both languages
  for (const g of SETTING_GROUPS) {
    assert.ok(en['ui.set.g.' + g.id] && zhCN['ui.set.g.' + g.id], g.id);
    for (const it of g.items) for (const p of ['ui.set.k.', 'ui.set.h.']) assert.ok(en[p + it.key] && zhCN[p + it.key], p + it.key);
  }
});

test('audit: grouped by day, newest first; actors without their principal', () => {
  const d1 = new Date(2026, 9, 7, 15, 0).getTime(), d2 = new Date(2026, 9, 6, 9, 0).getTime();
  const days = auditDays([{ at: iso(d1), action: 'a' }, { at: iso(d1 - 3600000), action: 'b' }, { at: iso(d2), action: 'c' }]);
  assert.equal(days.length, 2);
  assert.deepEqual(days[0].events.map((e) => e.action), ['a', 'b']);
  assert.deepEqual(auditDays(undefined), []);
  assert.equal(auditWho({ actor: 'verkyyi (gh:100)' }), 'verkyyi');
  assert.equal(auditWho({ actor: '' }), '—');
  for (const k of AUDIT_KINDS) assert.ok(en['ui.aud.k.' + k] && zhCN['ui.aud.k.' + k], k);
});

// The pages themselves, read as source: what a DOM test would pin, without a DOM.
const PAGES = [
  { file: 'subscriptions.js', id: 'subscriptions', confirms: 2, empty: 'ui.sub.empty' },
  { file: 'nodes.js', id: 'machines', confirms: 2, empty: 'ui.mach.empty' },
  { file: 'users.js', id: 'people', confirms: 1, empty: 'ui.usr.empty' },
  { file: 'settings.js', id: 'settings', confirms: 0, empty: null },
  { file: 'audit.js', id: 'audit', confirms: 0, empty: 'ui.aud.empty' },
];
for (const p of PAGES) {
  test(`${p.file}: mounts as ${p.id}, confirms destructive writes, has an empty state, no bare words`, () => {
    const src = readFileSync(new URL('../dist/' + p.file, import.meta.url), 'utf8');
    assert.match(src, new RegExp(`Shell\\.mount\\('${p.id}'`));
    assert.equal((src.match(/ctx\.confirm\(/g) || []).length, p.confirms, 'confirm dialogs');
    if (p.empty) assert.ok(src.includes(`'${p.empty}'`), 'an empty state');
    // An error state is the shell's: a page whose read fails throws, and the
    // shell draws 「加载失败」 with a retry — so no page swallows its main read.
    assert.ok(!/catch\s*\{\s*\}/.test(src), 'no silent catch');
    // Every user-visible word goes through t(): no English sentence in markup.
    const markup = src.replace(/\/\/.*$/gm, '').match(/>[^<>${}`'"]*[A-Za-z]{3,}[^<>${}`'"]*</g) || [];
    // Names stay as they are: products, and an environment variable.
    assert.deepEqual(markup.filter((m) => !/^>\s*(Claude|Codex|SPOT|CSV|C|X|[A-Z][A-Z0-9_]+)\s*</.test(m)), [], 'bare words in markup');
    // Every key the page asks for exists in both dictionaries.
    for (const m of src.matchAll(/t\('(ui\.[\w.-]*\w)'/g)) assert.ok(m[1] in en && m[1] in zhCN, m[1]);
  });
}

test('a user never reaches an admin page from the menu, and a direct visit shows the lock', () => {
  const shell = readFileSync(new URL('../dist/app-shell.js', import.meta.url), 'utf8');
  assert.match(shell, /if \(!pageAllowed\(me, page\)\)/);
  assert.match(shell, /ui\.err\.notOnMenu/);
});

test('vault labels find their own account — four Claude + one Codex is five cards (claude-fleet#2104)', () => {
  // The hub's real shape on 2026-10-07: setup tokens named after the mail
  // provider, the one Codex login "default", and one Codex account whose
  // e-mail equals a Claude account's.
  const acct = (u, email, source = 'claude') => ({ account_uuid: u, email, source });
  const limits = { per_account: [
    { account_uuid: 'u-icloud', label: 'ylianghui@icloud.com', limits: { available: true } },
    { account_uuid: 'u-gmail', label: 'verky.yi@gmail.com', limits: { available: true } },
    { account_uuid: 'u-24h', label: 'verky@24helpful.com', limits: { available: true } },
    { account_uuid: 'codex:account:a0', label: 'verky.yi@gmail.com', limits: { available: true, source: 'codex' } },
    { account_uuid: 'u-gu', label: 'ly297@georgetown.edu', limits: { available: true } },
  ] };
  const accounts = [acct('u-icloud', 'ylianghui@icloud.com'), acct('u-gmail', 'verky.yi@gmail.com'), acct('u-24h', 'verky@24helpful.com'),
    acct('codex:account:a0', 'verky.yi@gmail.com', 'codex'), acct('u-gu', 'ly297@georgetown.edu')];
  const pool = (provider, account) => ({ principal_id: 'pool', provider, account, created_at: iso(NOW) });
  const creds = { credentials: [pool('claude', '24helpful'), pool('claude', 'gmail'), pool('claude', 'icloud'), pool('claude', 'ly297'), pool('codex', 'default')] };
  const cards = subscriptions({ limits, accounts, creds });
  assert.equal(cards.filter((c) => c.prov === 'claude').length, 4);
  assert.equal(cards.filter((c) => c.prov === 'codex').length, 1);
  const by = Object.fromEntries(cards.map((c) => [c.id, c.cred && c.cred.account]));
  assert.deepEqual(by, { 'u-icloud': 'icloud', 'u-gmail': 'gmail', 'u-24h': '24helpful', 'codex:account:a0': 'default', 'u-gu': 'ly297' });
});

test('the hub counts what its vault holds — 4 Claude · 1 Codex, the rest 未纳管 (claude-fleet#2127)', () => {
  // The hub's shape on 2026-10-07: four Claude setup tokens and the one Codex
  // "default" in the vault; the agents report five Claude accounts (one a
  // win_ fingerprint), two Codex accounts (one a teammate's own login) and
  // codex:local.
  const acct = (u, email, source = 'claude') => ({ account_uuid: u, email, source });
  const row = (u, label, source) => ({ account_uuid: u, label, limits: { available: true, ...(source ? { source } : {}) } });
  const limits = { per_account: [
    row('u-icloud', 'ylianghui@icloud.com'), row('u-gmail', 'verky.yi@gmail.com'), row('u-24h', 'verky@24helpful.com'),
    row('u-gu', 'ly297@georgetown.edu'), row('win_cf27aa', 'win_cf27aa'),
    row('codex:account:a0', 'verky.yi@gmail.com', 'codex'), row('codex:account:98', 'keep.cj@gmail.com', 'codex'),
    row('codex:local', 'Codex (local usage)', 'codex'),
  ] };
  const accounts = [acct('u-icloud', 'ylianghui@icloud.com'), acct('u-gmail', 'verky.yi@gmail.com'), acct('u-24h', 'verky@24helpful.com'),
    acct('u-gu', 'ly297@georgetown.edu'), acct('codex:account:a0', 'verky.yi@gmail.com', 'codex'), acct('codex:account:98', 'keep.cj@gmail.com', 'codex')];
  const pool = (provider, account, uuid) => ({ principal_id: 'pool', provider, account, created_at: iso(NOW), ...(uuid ? { account_uuid: uuid } : {}) });
  // by identity: the Codex one from its id_token, one Claude one recorded at import
  // under a label that names nothing ("spare-1" would otherwise be its own card)
  const creds = { credentials: [pool('claude', '24helpful'), pool('claude', 'gmail'), pool('claude', 'spare-1', 'u-icloud'), pool('claude', 'ly297'),
    pool('codex', 'default', 'codex:account:a0')] };
  const cards = subscriptions({ limits, accounts, creds });
  const managed = cards.filter((c) => c.managed), other = cards.filter((c) => !c.managed);
  assert.equal(managed.filter((c) => c.prov === 'claude').length, 4);
  assert.equal(managed.filter((c) => c.prov === 'codex').length, 1);
  assert.deepEqual(Object.fromEntries(managed.map((c) => [c.id, c.cred.account])),
    { 'u-icloud': 'spare-1', 'u-gmail': 'gmail', 'u-24h': '24helpful', 'u-gu': 'ly297', 'codex:account:a0': 'default' });
  assert.deepEqual(other.map((c) => c.id).sort(), ['codex:account:98', 'codex:local', 'win_cf27aa']);
  assert.ok(other.every((c) => c.cred === null));
  // no account_uuid (an older import, no id_token): the label guess again — two
  // real Codex accounts, so "default" fits neither and is a card of its own
  for (const c of creds.credentials) delete c.account_uuid;
  creds.credentials[2].account = 'icloud';
  const guess = subscriptions({ limits, accounts, creds });
  assert.ok(guess.some((c) => c.id === 'cred:codex/default' && c.managed));
  assert.equal(guess.find((c) => c.id === 'u-icloud').cred.account, 'icloud');
  assert.equal(guess.find((c) => c.id === 'codex:account:a0').managed, false);
});

test('a vault guess that fits two accounts, or a stand-in row, matches nothing', () => {
  const limits = { per_account: [
    { account_uuid: 'u-1', label: 'a@gmail.com', limits: {} },
    { account_uuid: 'u-2', label: 'b@gmail.com', limits: {} },
    { account_uuid: 'win_0123', label: 'win_0123', limits: {} },
    { account_uuid: 'codex:local', label: 'Codex (local usage)', limits: { source: 'codex' } },
  ] };
  const accounts = [{ account_uuid: 'u-1', email: 'a@gmail.com' }, { account_uuid: 'u-2', email: 'b@gmail.com' }];
  const creds = { credentials: [
    { principal_id: 'pool', provider: 'claude', account: 'gmail' },
    { principal_id: 'pool', provider: 'codex', account: 'default' },
  ] };
  const cards = subscriptions({ limits, accounts, creds });
  // two gmail accounts: the label could be either, so it is its own card
  assert.ok(cards.some((c) => c.id === 'cred:claude/gmail'));
  // codex:local is a pool of unattributed usage, not the credential's account
  assert.ok(cards.some((c) => c.id === 'cred:codex/default'));
  assert.equal(cards.find((c) => c.id === 'codex:local').cred, null);
  // a Claude credential never lands on a Codex card, however its label reads
  const x = subscriptions({ limits: { per_account: [{ account_uuid: 'codex:account:z', label: 'z@gmail.com', limits: { source: 'codex' } }] },
    accounts: [{ account_uuid: 'codex:account:z', email: 'z@gmail.com', source: 'codex' }],
    creds: { credentials: [{ principal_id: 'pool', provider: 'claude', account: 'z' }] } });
  assert.equal(x.find((c) => c.id === 'codex:account:z').cred, null);
});
