import assert from 'node:assert/strict';
import { legacyReader } from '../src/app/chat/legacy-request.ts';

function fixture(who, replies, viewing = false) {
  const calls = [];
  const run = legacyReader(async () => who, async (url, opts) => {
    calls.push([url, opts?.method || 'GET']);
    const [status, body] = replies.shift();
    return new Response(JSON.stringify(body), { status });
  }, viewing);
  return { run, calls };
}
const pending = [200, { ok: true, migrated: false }];
const done = { ok: true, migrated: true, fid: 'claude', codex_fid: 'codex' };
const normal = fixture({}, [pending, [200, done]]);
assert.deepEqual(await Promise.all([normal.run(), normal.run()]), [done, done]);
assert.deepEqual(await normal.run(), done);
assert.deepEqual(normal.calls, [['/v1/chat/migration', 'GET'], ['/v1/chat/migrate', 'POST']]);
const retry = fixture({}, [pending, [200, { ok: false, why: 'busy' }], pending, [200, done]]);
assert.equal((await retry.run()).why, 'busy');
assert.equal((await retry.run()).fid, 'claude');
const offline = fixture({}, [[503, {}], pending, [200, done]]);
assert.equal((await offline.run()).ok, false);
assert.equal((await offline.run()).ok, true);
for (const status of [pending, [200, done]]) {
  const ro = fixture({ read_only: true }, [status]);
  assert.equal((await ro.run()).readOnly, true);
  assert.deepEqual(ro.calls, [['/v1/chat/migration', 'GET']]);
}
for (const who of [null, { view_as: { person: 'someone' } }]) {
  const f = fixture(who, []);
  assert.equal((await f.run()).readOnly, true);
  assert.equal(f.calls.length, 0);
}
const noHome = fixture({}, [[409, { code: 'no_home' }]]);
assert.equal((await noHome.run()).ok, true);
assert.equal(noHome.calls.length, 1);
console.log('chat-migration: ok');
