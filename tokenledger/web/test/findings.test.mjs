import test from 'node:test';
import assert from 'node:assert/strict';
import { isMuted, muteLine, ownerLine, splitMuted } from '../dist/lib/findings.js';
import { useLocale } from '../dist/lib/i18n.js';
import { en } from '../dist/lib/i18n/en.js';

// The two shapes the backend actually sends, and the one thing the page must
// never do with them: invent a name. `owner` is absent on every finding whose
// subject is shared (a model, a project, a whole period), and absent has to
// render as NOTHING — an "unknown" placeholder reads like missing data and
// would sit on every one of those cards forever.
test('no owner renders no line at all', () => {
  assert.equal(ownerLine({ kind: 'unpriced_model', title: 'x' }), null);
  assert.equal(ownerLine({ owner: {} }), null);
  assert.equal(ownerLine({ owner: { user: '', team: '' } }), null);
  // Whitespace is not a name. A blank-but-present value would otherwise print
  // "who to ask:" followed by nothing.
  assert.equal(ownerLine({ owner: { user: '   ' } }), null);
  assert.equal(ownerLine({}), null);
  assert.equal(ownerLine(null), null);
  assert.equal(ownerLine(undefined), null);
});

test('a known login and team both appear', () => {
  const line = ownerLine({ owner: { user: 'verky', team: 'infra' } });
  assert.match(line, /verky/);
  assert.match(line, /infra/);
});

// Half-known is the normal state of an endpoint nobody has allocated yet, and
// "go find verky" is worth strictly more than "go find somebody".
test('either half alone still renders', () => {
  assert.match(ownerLine({ owner: { user: 'verky' } }), /verky/);
  assert.match(ownerLine({ owner: { team: 'infra' } }), /infra/);
  // A team with no login must not be mistaken for a person's name.
  assert.notEqual(ownerLine({ owner: { team: 'infra' } }), ownerLine({ owner: { user: 'infra' } }));
});

// A login and a team name are somebody's ACTUAL names — the same rule
// internal/findings keeps for severity/kind/scope. The surrounding words
// translate; the names pass through byte for byte.
test('names are not translated, only the words around them', () => {
  const f = { owner: { user: 'verky', team: 'infra' } };
  useLocale('zh-CN');
  const zh = ownerLine(f);
  useLocale('en');
  const eng = ownerLine(f);
  assert.notEqual(zh, eng, 'zh-CN must have its own wording');
  for (const line of [zh, eng]) {
    assert.match(line, /verky/);
    assert.match(line, /infra/);
  }
  assert.equal(eng, en['findings.owner.both'].replace('{user}', 'verky').replace('{team}', 'infra'));
});

/* ------------------------------------------------------------------ muting */

// `muted` follows the same absent-key contract as `owner`: a finding nobody
// silenced simply has no such key, and there is no `muted: false` to guard
// against. Asking only for truthiness would let a future null through.
test('muted is detected by the key, not by a flag', () => {
  assert.equal(isMuted({ kind: 'stale_agent' }), false);
  assert.equal(isMuted({ muted: null }), false);
  assert.equal(isMuted({}), false);
  assert.equal(isMuted(null), false);
  assert.equal(isMuted({ muted: { until: '2026-09-20T00:00:00Z' } }), true);
});

// The server ranks muted findings after the live ones, but the page must not
// DEPEND on that ordering to render correctly — a partition is right whatever
// order the list arrives in.
test('splitMuted partitions rather than slicing at a boundary', () => {
  const list = [
    { id: 'a' },
    { id: 'b', muted: { until: '2026-09-20T00:00:00Z' } },
    { id: 'c' },
  ];
  const { live, muted } = splitMuted(list);
  assert.deepEqual(live.map((f) => f.id), ['a', 'c']);
  assert.deepEqual(muted.map((f) => f.id), ['b']);
  // An empty or missing list is the normal state of a healthy fleet.
  assert.deepEqual(splitMuted([]), { live: [], muted: [] });
  assert.deepEqual(splitMuted(null), { live: [], muted: [] });
});

// The expiry is the whole point of the line. A muted finding that only said
// "muted" would be indistinguishable from a deleted one, which is exactly what
// every mute expiring is meant to prevent.
test('the mute line always states when the silence ends', () => {
  useLocale('en');
  const now = Date.parse('2026-09-19T10:00:00Z');
  const at = (until) => muteLine({ muted: { until } }, now);

  assert.match(at('2026-09-19T12:30:00Z'), /2h/, 'hours, rounded down');
  assert.match(at('2026-09-21T10:00:00Z'), /2d/, 'days past a day');
  assert.match(at('2026-09-19T10:20:00Z'), /20m/, 'minutes under an hour');
});

// Rounded DOWN, never up. "1h left" that is really 1h59m is a pleasant
// surprise; "2h left" that expires in 61 minutes is a lie the operator plans
// around.
test('remaining time never overstates itself', () => {
  useLocale('en');
  const now = Date.parse('2026-09-19T10:00:00Z');
  assert.match(muteLine({ muted: { until: '2026-09-19T11:59:00Z' } }, now), /1h/);
  assert.match(muteLine({ muted: { until: '2026-09-21T09:59:00Z' } }, now), /1d/);
});

// A past or unparseable expiry must not print a negative countdown. The server
// filters on the clock before annotating, so this is the belt to that braces —
// say it is muted, decline to invent a duration.
test('a lapsed or malformed expiry degrades to a plain statement', () => {
  useLocale('en');
  const now = Date.parse('2026-09-19T10:00:00Z');
  for (const until of ['2026-09-19T09:00:00Z', 'not a date', undefined]) {
    const line = muteLine({ muted: { until } }, now);
    assert.ok(line, 'still says it is muted');
    assert.doesNotMatch(line, /-\d/, `negative countdown for ${until}`);
  }
  // Who silenced it survives even when the expiry does not parse — that is
  // the half the operator can still act on.
  assert.match(muteLine({ muted: { until: 'nope', by: 'alice' } }, now), /alice/);
});

test('a finding that is not muted has no mute line', () => {
  assert.equal(muteLine({ kind: 'stale_agent' }), null);
  assert.equal(muteLine(null), null);
});

// Same rule as owner: a login passes through byte for byte, the words around
// it translate.
test('the muter name is not translated', () => {
  const f = { muted: { until: '2026-09-21T10:00:00Z', by: 'verky' } };
  const now = Date.parse('2026-09-19T10:00:00Z');
  useLocale('zh-CN');
  const zh = muteLine(f, now);
  useLocale('en');
  const eng = muteLine(f, now);
  assert.notEqual(zh, eng, 'zh-CN must have its own wording');
  for (const line of [zh, eng]) assert.match(line, /verky/);
});
