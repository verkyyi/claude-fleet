// start-clock.mjs — a new web session's wait (task PNWW, src/app/start-clock.ts):
// the press → the open answered → the session's page → the reply's first words;
// stopped and sent once, never a stale clock, each stage inside the whole.
// Run: node --experimental-strip-types test/start-clock.mjs
import assert from 'node:assert/strict';
import { CLOCK_MAX_MS, clockOpened, clockReplied, clockShown, readClock, replied } from '../src/app/start-clock.ts';

const mem = () => { const m = new Map(); return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m }; };
const W = 'fleet-1/966ca8d2-9b50-421d-95a3-ce879a83b992';

// the whole road, once
let s = mem();
clockOpened(W, 1000, 'claude', s, 2400);
clockShown(W, s, 3100);
clockShown(W, s, 9000);                      // drawn again: the first one counts
assert.deepEqual(readClock(W, s, 3200), { t0: 1000, open: 1400, shown: 2100, agent: 'claude' });
assert.deepEqual(clockReplied(W, s, 15000, 'Asia/Shanghai'), { ms: 14000, open_ms: 1400, shown_ms: 2100, agent: 'claude', tz: 'Asia/Shanghai' });
assert.equal(clockReplied(W, s, 16000, 'Asia/Shanghai'), null, 'sent once');

// no clock: a session opened elsewhere, or another tab
assert.equal(clockReplied('fleet-1/other', mem(), 5000), null);
clockShown('fleet-1/other', s, 5000);
assert.equal(s.m.size, 0, 'a page drawn with no clock starts none');

// a stale clock is dropped, never sent
s = mem();
clockOpened(W, 1000, 'codex', s, 2000);
assert.equal(clockReplied(W, s, 1000 + CLOCK_MAX_MS + 1), null);
assert.equal(s.m.size, 0);

// a broken record is nothing
s = mem(); s.setItem(`fleet:start-clock:${W}`, '{nope');
assert.equal(readClock(W, s, 5000), null);

// no storage (private mode): nothing breaks
clockOpened(W, 1000, 'claude', null, 2000);
assert.equal(clockReplied(W, null, 3000), null);

// what counts as the reply begun: assistant words, not the person's line or a tool
assert.equal(replied([{ t: 'user', text: 'hi' }]), false);
assert.equal(replied([{ t: 'user', text: 'hi' }, { t: 'text', d: '  ' }]), false);
assert.equal(replied([{ t: 'user', text: 'hi' }, { t: 'text', d: 'pong' }]), true);

console.log('PASS start-clock');
