import assert from 'node:assert/strict';
import { chatCache, memoryBackend, mayCache, mayShow, trim, MAX_ITEMS } from '../src/app/chat/local.ts';

// task KSQG: the conversation kept in this browser — hit, miss, sign-out, nobody else's.

// layers: local < copy < home; the home always lands, a lower one never replaces a higher
assert.equal(mayShow('local', null), true, 'local draws an empty page');
assert.equal(mayShow('copy', 'local'), true, 'the copy replaces local');
assert.equal(mayShow('local', 'copy'), false, 'local never replaces the copy');
assert.equal(mayShow('copy', 'home'), false, 'a copy landing after the home is dropped (#5171)');
assert.equal(mayShow('local', 'home'), false, 'so is a late local read');
assert.equal(mayShow('home', 'home'), true, 'the home is read again and again');

// who may keep it: the person's own page only
assert.equal(mayCache({ person: 'p:a' }), true);
assert.equal(mayCache(null), false, 'unknown: no cache');
assert.equal(mayCache({}), false, 'no person: no cache');
assert.equal(mayCache({ person: 'p:a', read_only: true }), false, 'a read-only ticket neither reads nor writes');
assert.equal(mayCache({ person: 'p:a', view_as: { person: 'p:a' } }), false, 'a view neither reads nor writes');
assert.equal(mayCache({ person: 'p:a' }, 'p:b'), false, 'a tab looking through someone (?as=) neither');

// what is kept follows the entry's copy
const big = 'data:image/jpeg;base64,' + 'A'.repeat(40 << 10);
const small = 'data:image/jpeg;base64,AAAA';
const kept = trim([
  { t: 'user', text: 'hi', images: [{ thumb: small, w: 1 }, { thumb: big }] },
  { t: 'tool', id: 't1', name: 'Bash', summary: 'ls', input: { command: 'cat secret' } },
  { t: 'tool_result', id: 't1', text: 'SECRET OUTPUT', error: false },
  { t: 'image', id: 'i1', ref: 'home/file.png', thumb: small, w: 2 },
  { t: 'files', files: { a: 'b' } },
  { t: 'page', title: 'P', url: 'u', status: 'live', preview: 'ref', embed: 'x' },
  { t: 'text', d: 'ok' },
]);
assert.deepEqual(kept[0].images, [{ thumb: small, w: 1 }, {}], 'a preview over 32 KB is not kept');
assert.equal(kept[1].input, undefined, "a tool's input is not kept");
assert.deepEqual(kept[2], { t: 'tool_result', id: 't1', error: false }, "a tool's output is not kept");
assert.deepEqual(kept[3], { thumb: small, w: 2, t: 'image', id: 'i1' }, "an image keeps its preview, never its ref");
assert.ok(!kept.some((x) => x.t === 'files'), 'what the copy drops, this drops');
assert.deepEqual(kept[4], { t: 'page', title: 'P', url: 'u', status: 'live' }, "a page card without its preview");
const many = [];
for (let i = 0; i < 150; i++) many.push({ t: 'user', text: `q${i}` }, { t: 'text', d: `a${i}` });
const tr200 = trim(many);
assert.ok(tr200.length <= MAX_ITEMS, 'at most MAX_ITEMS items');
assert.equal(tr200[0].t, 'user', 'starts at a user line');
assert.equal(tr200.at(-1).d, 'a149', 'the newest are kept');

const b = memoryBackend();
const c = chatCache(b);

// miss: nothing kept yet
assert.equal(await c.read('p:a', 'claude'), null, 'a first visit: nothing');

// hit: what the home said comes back, per side
await c.write('p:a', 'claude', { session: 's1', cwd: '/w', models: [{ id: 'm', label: 'M' }], default: 'm', items: [{ t: 'user', text: 'hello' }] });
await c.write('p:a', 'codex', { session: 'x1', items: [{ t: 'user', text: 'codex side' }] });
const hit = await c.read('p:a', 'claude');
assert.equal(hit.session, 's1');
assert.deepEqual(hit.items, [{ t: 'user', text: 'hello' }]);
assert.equal(hit.default, 'm');
assert.deepEqual((await c.read('p:a', 'codex')).items, [{ t: 'user', text: 'codex side' }], 'each side its own');

// stale: a new session (新对话) replaces the old one's record
await c.write('p:a', 'claude', { session: 's2', items: [] });
assert.deepEqual((await c.read('p:a', 'claude')).items, [], 'the current session is the new one');
assert.ok(![...b.map.keys()].some((k) => k.includes('s1')), "the old session's record is gone");

// nobody else's: another person on this browser reads nothing, and their write drops ours
assert.equal(await c.read('p:b', 'claude'), null, "another person never reads p:a's keys");
await c.write('p:b', 'claude', { session: 'b1', items: [{ t: 'user', text: 'mine' }] });
assert.equal(await c.read('p:a', 'claude'), null, "p:a's history left when p:b kept theirs");
assert.equal(await c.read('p:a', 'codex'), null);
assert.ok([...b.map.keys()].every((k) => k.includes('p:b')), 'one person per browser');
assert.equal(await c.read('', 'claude'), null, 'no principal: nothing');

// read before /v1/me: the one person kept, for the caller to match against /v1/me
const any = await c.readAny('claude');
assert.equal(any.principal, 'p:b', "the kept person's name rides along");
assert.deepEqual(any.snap.items, [{ t: 'user', text: 'mine' }]);
assert.equal(await c.readAny('codex'), null, 'nothing kept on that side');
b.map.set('cur\u001fp:x\u001fclaude', 'z');
assert.equal(await c.readAny('claude'), null, 'two people kept (never written so): nothing drawn');
b.map.delete('cur\u001fp:x\u001fclaude');

// sign-out: everything goes
await c.clear();
assert.equal(b.map.size, 0, 'sign-out clears it all');
assert.equal(await c.read('p:b', 'claude'), null);
console.log('chat-local: ok');
