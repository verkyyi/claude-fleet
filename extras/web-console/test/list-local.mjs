import assert from 'node:assert/strict';
import { chatCache, memoryBackend, mayCache } from '../src/app/chat/local.ts';
import { listCache, listKey, MAX_AGE_MS } from '../src/app/list-local.ts';

// task T47B: the session list kept in this browser — hit, expired, sign-out, nobody else's.

const row = (id) => ({ id, key: id, title: id, repo: '', machine: 'm', state: 'working', group: 'run', ask: null, born: 1, ended: '', tokens: 0 });
const board = { rows: [{ id: 'mine', title: '我的对话', group: 'pin', tag: 'chat', words: ['对话', ''], at: 1 },
  { id: 'a', title: 'A', group: 'work', tag: 'working', words: ['在做', ''], at: 2 }], count: 2, groups: { pin: 1, work: 1 }, gone_days: 14, digest: 'd1' };
const snap = { live: [row('a')], ended: [], board, etag: '"1-1-0-bd1"', tasks: { tasks: [{ id: 't1', title: 'T', created_at: 'x' }] } };

const b = memoryBackend();
const c = listCache(b);
const now = 1_800_000_000_000;

// miss: nothing kept yet
assert.equal(await c.readAny(now), null, 'a first visit: nothing');

// hit: the board comes back as it was — rows, groups, order, count, digest, etag
await c.write('p:a', snap, now);
const hit = await c.readAny(now + 1000);
assert.equal(hit.principal, 'p:a');
assert.deepEqual(hit.snap.board, board, 'the board, order and counts as the hub sent them');
assert.equal(hit.snap.board.rows[0].id, 'mine', '「我的对话」 stays on top: the order is the hub\'s');
assert.equal(hit.snap.etag, '"1-1-0-bd1"', 'the ETag rides along for If-None-Match');
assert.deepEqual(hit.snap.live, snap.live);
assert.deepEqual(hit.snap.tasks, snap.tasks);
assert.deepEqual(await c.read('p:a', now), hit.snap);

// a newer answer replaces it
await c.write('p:a', { ...snap, etag: '"2"', board: { ...board, digest: 'd2' } }, now + 2000);
assert.equal((await c.read('p:a', now + 2000)).board.digest, 'd2', 'the newest answer is kept');

// expired: older than MAX_AGE is not drawn, and goes
assert.equal(await c.readAny(now + 2000 + MAX_AGE_MS + 1), null, 'an old list is not drawn');
assert.equal(b.map.size, 0, 'and is dropped');
// broken: dropped too
b.map.set(listKey('p:a'), { live: 'x' });
assert.equal(await c.readAny(now), null, 'a broken record is not drawn');
assert.equal(b.map.size, 0);

// nobody else's: another person reads nothing, and their write drops ours
await c.write('p:a', snap, now);
assert.equal(await c.read('p:b', now), null, "another person never reads p:a's list");
await c.write('p:b', snap, now);
assert.equal(await c.read('p:a', now), null, "p:a's list left when p:b kept theirs");
assert.deepEqual([...b.map.keys()], [listKey('p:b')], 'one person per browser');

// one store with the conversation (KSQG): one person's write drops the other's of both
const chat = chatCache(b);
await chat.write('p:a', 'claude', { session: 's', items: [{ t: 'user', text: 'hi' }] });
assert.equal(await c.read('p:b', now), null, "p:a's conversation drops p:b's list");
await c.write('p:b', snap, now);
assert.equal(await chat.read('p:a', 'claude'), null, "p:b's list drops p:a's conversation");
await chat.write('p:b', 'claude', { session: 's', items: [] });
assert.ok(await c.read('p:b', now), "a person's own conversation keeps their list");

// a view and a read-only ticket neither read nor write: the caller's gate
assert.equal(mayCache({ person: 'p:a', read_only: true }), false);
assert.equal(mayCache({ person: 'p:a', view_as: { person: 'p:b' } }), false);
assert.equal(mayCache({ person: 'p:a' }, 'p:b'), false);
assert.equal(mayCache({ person: 'p:a' }), true);
await c.write('', snap, now);
assert.ok(![...b.map.keys()].some((k) => k === listKey('')), 'no principal: nothing written');

// sign-out / 清除本机缓存: the store's clear takes the list too
await chat.clear();
assert.equal(b.map.size, 0, 'sign-out clears it all');
assert.equal(await c.readAny(now), null);
console.log('list-local: ok');
