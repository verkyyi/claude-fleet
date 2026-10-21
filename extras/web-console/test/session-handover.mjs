// session-handover.mjs — 接管 / 交回 (task VV8F, src/app/chat/handover.ts): the
// stage the workspace's 对话 shows off the 只读 stream's holder, a handover this
// page just made believed until the stream catches up, and the one POST.
// Run: node --experimental-strip-types test/session-handover.mjs
import assert from 'node:assert/strict';
import { handover, stageOf, SURE_MS } from '../src/app/chat/handover.ts';

assert.equal(stageOf(null, null, 0), 'read', 'nothing said yet: read');
assert.equal(stageOf({ holder: '', busy: false }, null, 0), 'read', 'never handed: read');
assert.equal(stageOf({ holder: 'terminal', busy: true }, null, 0), 'wait', 'the terminal answering: wait');
assert.equal(stageOf({ holder: 'webchat', busy: false }, null, 0), 'held', 'webchat holds it: held');
// taken here: held at once, before the stream's next state
assert.equal(stageOf({ holder: '', busy: false }, { held: true, at: 1000 }, 1500), 'held', 'taken here: held at once');
assert.equal(stageOf({ holder: '', busy: false }, { held: true, at: 1000 }, 1000 + SURE_MS + 1), 'read', 'the stream wins after SURE_MS');
// given back here: read at once, though the stream still says webchat
assert.equal(stageOf({ holder: 'webchat' }, { held: false, at: 1000 }, 1200), 'read', 'given back here: read at once');
assert.equal(stageOf({ holder: 'terminal' }, { held: false, at: 1000 }, 1200), 'read', 'agreed: read');

const calls = [];
const ok = async (url, init) => { calls.push([url, init]); return { ok: true, status: 200, json: async () => ({ ok: true, agent: 'codex', session: 't1' }) }; };
assert.deepEqual(await handover('f/u id', 'takeover', ok), { ok: true, agent: 'codex', session: 't1' });
assert.equal(calls[0][0], '/v1/chat/takeover?worker=f%2Fu%20id', 'the worker id, escaped');
assert.equal(calls[0][1].method, 'POST');
assert.equal(calls[0][1].headers['X-Fleet-Webchat'], '1', 'from the page itself');
const busy = async () => ({ ok: false, status: 409, json: async () => ({ code: 'terminal_busy', error: '等它说完' }) });
assert.deepEqual(await handover('w', 'giveback', busy), { ok: false, code: 'terminal_busy', error: '等它说完' });
const down = async () => { throw new Error('offline'); };
assert.deepEqual(await handover('w', 'takeover', down), { ok: false, code: 'offline', error: '' });
console.log('session-handover: ok');
