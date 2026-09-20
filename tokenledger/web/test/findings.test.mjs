import test from 'node:test';
import assert from 'node:assert/strict';
import { ownerLine } from '../dist/lib/findings.js';
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
