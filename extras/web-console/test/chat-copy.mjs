import assert from 'node:assert/strict';
import { cachedCopy } from '../src/app/chat/copy.ts';

// task J091: a first visit has no copy yet — the entry answers 200 with no
// items and mirror null, and the page takes it as «nothing to show», never as
// an (empty) transcript or an error.
assert.equal(cachedCopy(true, { items: [], mirror: null }), null, 'no copy: nothing shown');
assert.equal(cachedCopy(true, { items: [] }), null, 'an answer without mirror is no copy');
assert.equal(cachedCopy(false, { code: 'not_yours' }), null, 'a refusal (view-as 403) is no copy');
assert.equal(cachedCopy(true, null), null, 'an unreadable body is no copy');
const copy = { items: [{ t: 'user', text: 'hi' }], mirror: { at: '2026-10-21T00:00:00Z' } };
assert.equal(cachedCopy(true, copy), copy, 'a kept copy is shown');
console.log('chat-copy: ok');
