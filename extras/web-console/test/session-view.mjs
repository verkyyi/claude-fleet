// session-view.mjs — 只读 (task F481, src/app/chat/view-stream.ts): the
// service's SSE blocks read, and each batch laid onto what the page holds — the
// first answer may start past 0 (the last 600), a page back from a drop asks
// ?from=<what it holds> and an overlap never shows twice.
// Run: node --experimental-strip-types test/session-view.mjs
import assert from 'node:assert/strict';
import { mergeView, parseEvent } from '../src/app/chat/view-stream.ts';

assert.deepEqual(parseEvent('id: 7\ndata: {"t":"items","from":5}'), { id: 7, data: { t: 'items', from: 5 } });
assert.deepEqual(parseEvent('data: {"t":"state","busy":true}'), { id: undefined, data: { t: 'state', busy: true } });
assert.deepEqual(parseEvent(': ping'), { id: undefined });
assert.deepEqual(parseEvent('data: {broken'), { id: undefined });

let h = { base: 0, n: 0 };
let m = mergeView(h, 0, ['a', 'b']);
assert.deepEqual(m, { replace: false, held: { base: 0, n: 2 }, fresh: ['a', 'b'] }, 'from the start');
m = mergeView(m.held, 2, ['c']);
assert.deepEqual(m.fresh, ['c'], 'appended');
m = mergeView(m.held, 1, ['b', 'c', 'd']);
assert.deepEqual(m, { replace: false, held: { base: 0, n: 4 }, fresh: ['d'] }, 'an overlap shows only the new');
m = mergeView(m.held, 4, []);
assert.deepEqual(m.fresh, [], 'nothing new after a reconnect');
assert.deepEqual(mergeView({ base: 0, n: 0 }, 900, ['x']), { replace: true, held: { base: 900, n: 1 }, fresh: ['x'] }, 'the last 600 only');
assert.deepEqual(mergeView({ base: 0, n: 3 }, 9, ['y']), { replace: true, held: { base: 9, n: 1 }, fresh: ['y'] }, 'a gap starts over there');
console.log('session-view: ok');
