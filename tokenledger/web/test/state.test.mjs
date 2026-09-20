import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, format, withChip, withoutChip, apiQuery, DEFAULTS, VIEWS } from '../dist/lib/state.js';
import { SECTIONS } from '../dist/lib/nav.js';

test('parse defaults on empty and junk', () => {
  assert.deepEqual(parse(''), DEFAULTS);
  assert.deepEqual(parse('#/nowhere?span=1y&sub=&g1=bogus'), { ...DEFAULTS });
});

test('round-trips every field', () => {
  const s = { view: 'usage', session: null, sub: 'abc', span: '7d', from: 1788300000000, to: 1788380000000,
    chips: { machine: 'ep1', project: '/Users/x/p q' }, g1: 'login', g2: 'branch', sort: 'cost', csort: 'tokens',
    repo: 'verkyyi/tokenledger', rsort: 'comments', rlabel: 'priority:p0', rshipped: '1' };
  const h = format(s);
  assert.match(h, /^#\/\?/);
  assert.deepEqual(parse(h), s);
});

test('session route', () => {
  const s = parse('#/review/session/abc-123?sub=all');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/session/abc-123');
});

test('chips: one value per dimension, ordered, removable', () => {
  let s = withChip(DEFAULTS, 'model', 'opus');
  s = withChip(s, 'machine', 'ep1');
  s = withChip(s, 'model', 'haiku');
  assert.deepEqual(s.chips, { machine: 'ep1', model: 'haiku' });
  assert.equal(format(s), '#/?machine=ep1&model=haiku');
  assert.deepEqual(withoutChip(s, 'machine').chips, { model: 'haiku' });
});

test('apiQuery maps chips and honours omitDim', () => {
  const s = { ...DEFAULTS, sub: 'acct', chips: { machine: 'ep1', login: 'u', project: '/p' } };
  const q = apiQuery(s, { from: 0, to: 3600000 });
  // URLSearchParams also percent-encodes the ':' in ISO timestamps (%3A); the
  // Go server's net/url decodes it like any other percent-escape.
  assert.equal(q, 'account=acct&since=1970-01-01T00%3A00%3A00.000Z&until=1970-01-01T01%3A00%3A00.000Z&endpoint=ep1&user=u&project=%2Fp');
  assert.ok(!apiQuery(s, { from: 0, to: 1, omitDim: 'machine' }).includes('endpoint='));
  assert.ok(apiQuery(s, { from: 0, to: 1, extra: { by: 'project', compare: 1 } }).endsWith('&by=project&compare=1'));
});

test('source selection survives navigation and scopes API requests', () => {
  const state = parse('#/review?source=codex&g1=source');
  assert.equal(state.chips.source, 'codex');
  assert.equal(state.g1, 'source');
  assert.deepEqual(parse(format(state)), state);
  assert.match(apiQuery(state, { from: 0, to: 3600000 }), /&source=codex/);
  assert.ok(!apiQuery(state, { from: 0, to: 3600000, omitDim: 'source' }).includes('&source='));
});

// The view is a QUERY KEY and never a path segment, which is the correction to
// what `/now` and `/review` were. A segment is exclusive -- it cannot sit
// beside `session/<id>`, which is why the grammar above still carries a branch
// for the retired pair. A key is orthogonal, and the tests below hold it to it.
test('the view is a query key, not a path segment', () => {
  const s = parse('#/?view=usage&sub=abc&span=7d');
  assert.equal(s.view, 'usage');
  assert.equal(s.sub, 'abc');
  assert.equal(format(s), '#/?view=usage&sub=abc&span=7d');
  // A path segment named after a view is still not a route: it falls through
  // the grammar to the default page, exactly as `#/nowhere` does.
  assert.equal(parse('#/usage').view, DEFAULTS.view);
});

test('the default view stays out of the hash, and an unknown one falls back', () => {
  assert.equal(format({ ...DEFAULTS }), '#/');
  assert.equal(format({ ...DEFAULTS, view: 'all' }), '#/', 'the nav must not stamp view=all on every link');
  assert.equal(parse('#/').view, 'all');
  assert.equal(parse('#/?view=bogus').view, DEFAULTS.view);
  assert.equal(parse('#/?view=').view, DEFAULTS.view);
});

// Every value the nav can write must be a value parse() accepts. These are two
// files that a reader of either one would expect to agree, so the derivation in
// state.js is checked rather than assumed: a SECTIONS entry whose view fell out
// of VIEWS would be a nav button that silently resets itself on the next route.
test('every nav entry names a view the router accepts', () => {
  assert.deepEqual(VIEWS, ['all', 'ledger', 'usage', 'progress', 'ops']);
  for (const { view, target } of SECTIONS) {
    assert.ok(VIEWS.includes(view), `${target} writes an unroutable view: ${view}`);
    assert.equal(parse(`#/?view=${view}`).view, view);
  }
});

// The point of #97: a view switch must not be paid for with the reader's
// filters. Everything else in the hash is spread across it untouched.
test('switching view keeps the whole scope', () => {
  const s = parse('#/?sub=acct&span=7d&project=%2Fx&model=opus&g1=login&rlabel=priority%3Ap0');
  const moved = { ...s, view: 'ops' };
  assert.equal(format(moved), '#/?view=ops&sub=acct&span=7d&project=%2Fx&model=opus&g1=login&rlabel=priority%3Ap0');
  const back = parse(format(moved));
  for (const k of ['sub', 'span', 'g1', 'rlabel']) assert.equal(back[k], s[k], k);
  assert.deepEqual(back.chips, s.chips);
});

// The session overlay is orthogonal to the view, not nested under it -- it can
// open on any view and closing it lands back on the one it opened from. That is
// the property the path segment could never have had.
test('the session overlay opens on any view and closes back to it', () => {
  for (const view of VIEWS) {
    const s = parse(`#/session/abc-123?view=${view}&span=7d`);
    assert.equal(s.session, 'abc-123');
    assert.equal(s.view, view);
    // Closing the overlay is session:null and nothing else (session.js:50).
    assert.equal(parse(format({ ...s, session: null })).view, view, view);
    assert.equal(parse(format({ ...s, session: null })).span, '7d', view);
  }
});

test('a session still round-trips', () => {
  const s = parse('#/session/abc-123?span=7d');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/session/abc-123?span=7d');
});

// Old links are the only reason anyone types a URL twice. They must land on
// the same page with the same scope, not on a blank one.
test('old #/now and #/review links keep their scope', () => {
  for (const old of ['#/now?sub=abc&span=7d', '#/review?sub=abc&span=7d']) {
    const s = parse(old);
    assert.equal(s.sub, 'abc', old);
    assert.equal(s.span, '7d', old);
    assert.equal(format(s), '#/?sub=abc&span=7d', old);
  }
});

test('an old review session link keeps its session', () => {
  const s = parse('#/review/session/abc-123');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/session/abc-123');
});

// The stalled table's filter lives in the URL because the progress tier
// re-renders on the page's 60-second timer: a picker holding its own value
// would silently reset itself every minute, and a narrowed list nobody can
// paste to a colleague is half a view on a page whose point is being shared.
test('the stalled filter survives a reload and a paste', () => {
  const s = parse('#/?rsort=comments&rlabel=security&rshipped=1');
  assert.equal(s.rsort, 'comments');
  assert.equal(s.rlabel, 'security');
  assert.equal(s.rshipped, '1');
  assert.equal(format(s), '#/?rsort=comments&rlabel=security&rshipped=1');
});

test('defaults stay out of the hash, so a clean link reads clean', () => {
  assert.equal(format({ ...DEFAULTS }), '#/');
  assert.equal(format({ ...DEFAULTS, rsort: 'age' }), '#/', 'the default sort is not written');
  assert.equal(format({ ...DEFAULTS, rshipped: null }), '#/');
});

// A sort axis is one of a fixed set and is checked; a LABEL is data and is
// not. A repository grows labels without state.js hearing about it, so an
// allowlist here would quietly drop filters that are perfectly valid.
test('an unknown sort axis falls back, an unknown label is honoured', () => {
  assert.equal(parse('#/?rsort=bogus').rsort, DEFAULTS.rsort);
  assert.equal(parse('#/?rlabel=a-label-this-file-never-heard-of').rlabel, 'a-label-this-file-never-heard-of');
  // Only the literal '1' turns the toggle on: anything else is a malformed
  // link, and a truthy-string check would make `rshipped=0` mean "on".
  assert.equal(parse('#/?rshipped=0').rshipped, null);
  assert.equal(parse('#/?rshipped=true').rshipped, null);
});

// A label with a slash, a colon or a space round-trips: GitHub labels have all
// three, and `priority:p0` is on five of the stalled issues this was built for.
test('labels with punctuation survive the hash', () => {
  for (const label of ['priority:p0', 'area:api+web', 'needs triage', 'a/b']) {
    assert.equal(parse(format({ ...DEFAULTS, rlabel: label })).rlabel, label, label);
  }
});

// dataKey is what app.js uses to tell "redraw" from "re-fetch". Getting it
// wrong in one direction costs a round trip per click; in the other it serves
// a stale page after a real navigation, which is worse.
test('dataKey ignores presentation, and nothing else', async () => {
  const { dataKey, PRESENTATION_KEYS } = await import('../dist/lib/state.js');
  const base = { ...DEFAULTS, sub: 'acct', span: '7d', repo: 'o/r' };
  const k = dataKey(base);
  for (const [key, value] of [['rsort', 'comments'], ['rlabel', 'security'], ['rshipped', '1'],
    // csort reorders provider rows already in memory (rows.js sortRows) and
    // appears in no query string -- the same shape as the three above, and it
    // sat outside this list for long enough to cost 19 requests per click.
    ['csort', 'tokens'],
    // ...and `view`, which is the key this list now exists for. Every band on
    // every view asks about the same account, window and chips, so switching
    // one changes not a character of a single request URL. Out of this list, a
    // view would be a full reload of the page -- the csort mistake at four
    // times the price. Checked against EVERY view, not one: the list is
    // derived from the nav, so a section added later is covered here the day
    // it is added rather than the day someone remembers to extend this test.
    ...VIEWS.map((v) => ['view', v])]) {
    assert.equal(dataKey({ ...base, [key]: value }), k, `${key}=${value} must not force a re-fetch`);
  }
  // ...and every key that DOES change a request still moves it. This half is
  // the guard against over-reaching: a short circuit that swallowed one of
  // these would serve rows from the wrong period, account or grouping.
  assert.notEqual(dataKey({ ...base, repo: 'o/other' }), k, 'the repo picker changes both requests');
  assert.notEqual(dataKey({ ...base, span: '30d' }), k);
  assert.notEqual(dataKey({ ...base, sub: 'other' }), k);
  assert.notEqual(dataKey({ ...base, sort: 'cost' }), k, '/v1/sessions is sorted server-side');
  assert.notEqual(dataKey({ ...base, from: 1788300000000, to: 1788380000000 }), k, 'the brush moves the range');
  assert.notEqual(dataKey({ ...base, g1: 'model' }), k, 'the group-by is the by= parameter');
  assert.notEqual(dataKey({ ...base, g2: 'team' }), k);
  assert.notEqual(dataKey({ ...base, chips: { project: '/x' } }), k, 'a chip filters every card');
  // The session id is not part of it either way: opening the detail pane is
  // route()'s business, and it already excludes it from its own key.
  assert.equal(dataKey({ ...base, session: 'abc' }), k);
  assert.deepEqual(PRESENTATION_KEYS, ['rsort', 'rlabel', 'rshipped', 'csort', 'view']);
  // The other half of "switching view is free": route() re-renders on a key
  // that DOES include the view, so the page still redraws -- it just redraws
  // from the rows it already has. A view that moved neither key would be a
  // button that does nothing at all.
  assert.notEqual(format({ ...base, view: 'ops', session: null }), format({ ...base, session: null }));
});

// #92: on a hub with one subscription, `sub` was pinned to 'all' by
// construction -- DEFAULTS.sub is 'all', format() omits a default, so `#/`
// parses back to 'all', and the old fallback rewrote every unrecognised sub to
// 'all' including where there was only one to choose. The banner explaining
// cross-subscription arithmetic was therefore permanent, and the two limits
// banners (gated on `sub !== 'all'`) were permanently unreachable.
test('resolveSub selects the only account, and keeps a real one', async () => {
  const { resolveSub, accountsInScope } = await import('../dist/lib/state.js');
  const one = [{ account_uuid: 'a1', source: 'claude' }];
  const two = [...one, { account_uuid: 'b2', source: 'claude' }];

  // The fix itself: one subscription is not a set to aggregate.
  assert.equal(resolveSub(DEFAULTS, one), 'a1');
  assert.equal(resolveSub(parse('#/'), one), 'a1');
  // ...and the resolved state round-trips, so the correction runs ONCE rather
  // than on every reload. This is the assertion that would have caught the bug:
  // under the old rule this hash came back as 'all' forever.
  assert.equal(parse(format({ ...DEFAULTS, sub: resolveSub(DEFAULTS, one) })).sub, 'a1');

  // More than one, none, and an unknown uuid all still land on 'all'.
  assert.equal(resolveSub(DEFAULTS, two), 'all');
  assert.equal(resolveSub(DEFAULTS, []), 'all');
  assert.equal(resolveSub({ ...DEFAULTS, sub: 'gone' }, two), 'all');
  // An explicitly chosen account that exists is never second-guessed.
  assert.equal(resolveSub({ ...DEFAULTS, sub: 'b2' }, two), 'b2');

  // The source chip takes an account OUT of scope without naming it, so it
  // narrows both the validity check and the count. Two accounts, one per
  // source: pinning a source leaves exactly one, and that one gets selected.
  const mixed = [{ account_uuid: 'a1', source: 'claude' }, { account_uuid: 'g9', source: 'gateway' }];
  assert.equal(resolveSub({ ...DEFAULTS, chips: { source: 'gateway' } }, mixed), 'g9');
  assert.equal(resolveSub({ ...DEFAULTS, sub: 'a1', chips: { source: 'gateway' } }, mixed), 'g9');
  assert.equal(resolveSub(DEFAULTS, mixed), 'all');
  // A row written before the source column existed reads as Claude, the same
  // rule model.UsageSource applies in Go.
  assert.equal(resolveSub({ ...DEFAULTS, chips: { source: 'claude' } }, [{ account_uuid: 'old' }]), 'old');

  // scope.js counts the same set to decide whether to offer "all" at all --
  // one function, so the picker cannot offer a choice the router would undo.
  assert.equal(accountsInScope(mixed, DEFAULTS).length, 2);
  assert.equal(accountsInScope(mixed, { ...DEFAULTS, chips: { source: 'claude' } }).length, 1);
  assert.deepEqual(accountsInScope(null, DEFAULTS), []);
});
