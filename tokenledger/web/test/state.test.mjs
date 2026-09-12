import test from 'node:test';
import assert from 'node:assert/strict';
import { parse, format, withChip, withoutChip, apiQuery, DEFAULTS } from '../dist/lib/state.js';

test('parse defaults on empty and junk', () => {
  assert.deepEqual(parse(''), DEFAULTS);
  assert.deepEqual(parse('#/nowhere?span=1y&sub=&g1=bogus'), { ...DEFAULTS });
});

test('round-trips every field', () => {
  const s = { view: 'review', session: null, sub: 'abc', span: '7d', from: 1788300000000, to: 1788380000000,
    chips: { machine: 'ep1', project: '/Users/x/p q' }, g1: 'login', g2: 'branch', sort: 'cost' };
  const h = format(s);
  assert.match(h, /^#\/review\?/);
  assert.deepEqual(parse(h), s);
});

test('session route', () => {
  const s = parse('#/review/session/abc-123?sub=all');
  assert.equal(s.view, 'review');
  assert.equal(s.session, 'abc-123');
  assert.equal(format(s), '#/review/session/abc-123');
});

test('chips: one value per dimension, ordered, removable', () => {
  let s = withChip(DEFAULTS, 'model', 'opus');
  s = withChip(s, 'machine', 'ep1');
  s = withChip(s, 'model', 'haiku');
  assert.deepEqual(s.chips, { machine: 'ep1', model: 'haiku' });
  assert.equal(format(s), '#/now?machine=ep1&model=haiku');
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
