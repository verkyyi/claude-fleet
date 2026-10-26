// session-view.mjs — 只读 (task F481, src/app/chat/view-stream.ts): the
// service's SSE blocks read, and each frame laid onto what the page holds — the
// first answer is the newest stretch in place (task YP39: read from the record's
// end), a page back from a drop asks ?at=<the byte it holds> and what it held
// is never shown twice; ?before= draws the page before above it.
// Run: node --experimental-strip-types test/session-view.mjs
import assert from 'node:assert/strict';
import { NOTHING, applyFrame, parseEvent, prependOlder, writeAccess } from '../src/app/chat/view-stream.ts';

assert.equal(writeAccess(null, true), 'checking');
assert.equal(writeAccess({ can_talk: null }, true), 'checking');
assert.equal(writeAccess({ can_talk: false, talk_reason: 'unreachable' }, true), 'stalled', 'the session not answering is not the home being out of reach (YASF)');
assert.equal(writeAccess({ can_talk: false, talk_reason: 'start_blocked' }, true), 'stalled', 'a session that never started says so (YASF)');
assert.equal(writeAccess({ can_talk: false, talk_reason: 'start_blocked' }, true, 'offline'), 'offline', 'a dropped stream is still the home');
assert.equal(writeAccess({ can_talk: true }, null), 'checking', 'permission still loading is not a read-only login');
assert.equal(writeAccess({ can_talk: true }, true, 'offline'), 'offline', 'a disconnected stream cannot keep a stale write capability');
assert.equal(writeAccess({ can_talk: false }, true, 'checking'), 'checking', 'a new connection waits for its own capability frame');
assert.equal(writeAccess({ can_talk: true }, true, 'live'), 'writable', 'a recovered state frame enables sending again');
assert.equal(writeAccess({ can_talk: true }, false, 'offline'), 'readonly', 'transport failure never lifts the read-only login restriction');
for (const agent of ['codex', 'claude']) {
  assert.equal(writeAccess({ agent, can_talk: true }, true), 'writable');
  assert.equal(writeAccess({ agent, can_talk: false, talk_reason: 'old_version' }, true), 'readonly');
}
assert.equal(writeAccess({}, true), 'readonly', 'old service stays read-only');
assert.equal(writeAccess({ can_talk: true }, false), 'readonly', 'read-only ticket / view-as cannot write');

assert.deepEqual(parseEvent('id: 7\ndata: {"t":"items","at":5}'), { id: 7, data: { t: 'items', at: 5 } });
assert.deepEqual(parseEvent('data: {"t":"state","busy":true}'), { id: undefined, data: { t: 'state', busy: true } });
assert.deepEqual(parseEvent(': ping'), { id: undefined });
assert.deepEqual(parseEvent('data: {broken'), { id: undefined });

// a local record or a copy on screen, then the machine's first answer: in place
let m = applyFrame(NOTHING, ['local-a', 'local-b'], { replace: true, items: ['a', 'b'], at: 100, older: 40, session: 's1' });
assert.deepEqual(m, { held: { at: 100, session: 's1', older: 40 }, items: ['a', 'b'] }, 'the first answer replaces what was drawn');
let cur = m.items;
m = applyFrame(m.held, cur, { items: ['c'], at: 130, session: 's1' });
assert.deepEqual(m, { held: { at: 130, session: 's1', older: 40 }, items: ['a', 'b', 'c'] }, 'appended');
cur = m.items;
// back from a drop at 130: nothing new, and a frame for a byte already read changes nothing
assert.equal(applyFrame(m.held, cur, { items: [], at: 130, session: 's1' }).items, null, 'nothing new after a reconnect');
assert.equal(applyFrame(m.held, cur, { items: ['c'], at: 120, session: 's1' }).items, null, 'never twice');
// another conversation in that window: its stretch, in place, even without replace
m = applyFrame(m.held, cur, { items: ['x'], at: 9, session: 's2' });
assert.deepEqual(m, { held: { at: 9, session: 's2', older: 0 }, items: ['x'] }, 'a new conversation starts over');

// the page before: only the one asked for, of the same conversation
const h = { at: 100, session: 's1', older: 40 };
assert.deepEqual(prependOlder(h, ['a'], 40, { items: ['y', 'z'], older: 0, session: 's1' }),
  { held: { at: 100, session: 's1', older: 0 }, items: ['y', 'z', 'a'] }, 'the page before, above');
assert.equal(prependOlder(h, ['a'], 30, { items: ['y'], older: 0, session: 's1' }), null, 'a stale page is dropped');
assert.equal(prependOlder(h, ['a'], 40, { items: ['y'], older: 0, session: 's9' }), null, 'another conversation\'s page is dropped');
assert.equal(prependOlder(NOTHING, ['a'], 0, { items: ['y'], session: '' }), null, 'nothing from the machine yet: no page before');
console.log('session-view: ok');

// beside the title (T981): a history read to its end is in sync though its
// stream is closed; a live stream that dropped still says 同步中, then offline
import { syncRaw } from '../src/app/chat/view-stream.ts';
assert.equal(syncRaw({ live: false, read: true, access: 'readonly', count: 4 }), '', 'a finished history is not 家机器暂时连不上');
assert.equal(syncRaw({ live: false, read: false, access: 'readonly', count: 4 }), 'syncing', 'a dropped stream is not in sync');
assert.equal(syncRaw({ live: true, access: 'writable', layer: 'home' }), '');
assert.equal(syncRaw({ live: false, read: true, gate: { code: 'home_down' } }), 'offline', 'a down home still says so');
assert.equal(syncRaw({ live: true, access: 'offline' }), 'offline');
