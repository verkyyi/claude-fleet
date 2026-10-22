// talk.mjs — 会话合一 (Y01K): the web talks to any session (src/app/chat/talk.ts).
// A line shows as it will land until the record carries it; a queued one is
// faded with why; one the session did not take within 20 s is said, with 重试.
// Run: node --experimental-strip-types test/talk.mjs
import assert from 'node:assert/strict';
import { afterSay, askOf, bubbles, failWords, settle, userLines, waitWords, WAKE_MS } from '../src/app/chat/talk.ts';

const P = (x) => ({ id: 'p1', text: '第二段再短一点', pics: [], at: 0, base: 0, state: 'sending', ...x });
const said = [{ t: 'user', text: '把周报初稿写成三段' }, { t: 'text', d: '好的' }];

// the entry's answer
assert.deepEqual(afterSay(P({}), { ok: true, delivery: 'd1', state: 'sent' }, 5), P({ delivery: 'd1', state: 'sent', sentAt: 5 }));
assert.equal(afterSay(P({}), { ok: true, delivery: 'd1', state: 'queued', reason: 'typing' }, 5).why, 'typing');
assert.equal(afterSay(P({}), { ok: true, state: 'refused', reason: 'wake_timeout' }, 5).state, 'failed');
assert.equal(afterSay(P({}), { ok: false, code: 'home_down' }, 5).why, 'home_down');

// sent → dropped once the record carries it (counted from what it had when said)
const sent = P({ state: 'sent', sentAt: 0, delivery: 'd1' });
assert.equal(settle([sent], said, [], 1000)[0].state, 'sent');
assert.deepEqual(settle([sent], [...said, { t: 'user', text: '第二段再短一点' }], [], 1000), []);
assert.equal(userLines([...said, { t: 'user', text: ' 第二段再短一点 ' }], '第二段再短一点'), 1);
// the same words said before do not count: only one more than when it was said
const again = P({ state: 'sent', sentAt: 0, base: 1 });
assert.equal(settle([again], [{ t: 'user', text: '第二段再短一点' }], [], 1000).length, 1);
// not in the record past WAKE_MS: did not go through (a parked session that did not come back)
assert.deepEqual(settle([sent], said, [], WAKE_MS + 1).map((p) => [p.state, p.why]), [['failed', 'wake_timeout']]);
// queued: waits while the session's queue holds it, sent (clock from then) once it leaves
const q = P({ state: 'queued', delivery: 'd1', why: 'busy' });
assert.equal(settle([q], said, [{ delivery: 'd1', text: 'x' }], WAKE_MS * 3)[0].state, 'queued', 'a queued line has no clock');
assert.equal(settle([q], said, [], 7000)[0].state, 'queued', 'a queue read before it listed the line says nothing about it');
const seenQ = settle([q], said, [{ delivery: 'd1', text: 'x' }], 6000)[0];
assert.ok(seenQ.seen);
const out = settle([seenQ], said, [], 7000)[0];
assert.deepEqual([out.state, out.sentAt], ['sent', 7000]);
// nothing changed ⇒ the same array (no render)
const ps = [sent];
assert.equal(settle(ps, said, [], 10), ps);

// what is drawn after the record: mine, and the session's queue from elsewhere, faded with why
const b = bubbles([q, P({ id: 'p2', state: 'sent', delivery: 'd2' })], [{ delivery: 'd1', text: '第二段再短一点', why: 'busy' }, { delivery: 'd9', text: '别的标签页', why: 'typing' }]);
assert.deepEqual(b.map((x) => x.id), ['p1', 'p2', 'q-d9']);
assert.ok(b[0].wait && !b[1].wait && b[2].wait);
assert.match(waitWords('busy'), /等这一轮说完就发出|Sends when this turn ends/);
assert.match(waitWords('typing'), /终端里有人正在输入，等他发出后再送|Someone is typing in the terminal/);
// the failure line: the 20 s sentence with 重试; a session too old has no 重试
assert.match(failWords('wake_timeout').text, /这一句没送到：会话没能在 20 秒内回来。|didn't come back within 20 s/);
assert.ok(failWords('wake_timeout').retry && !failWords('old_session').retry);

// its question as the chat's ask: the fingerprint is the rid an answer names
assert.equal(askOf(null), null);
assert.deepEqual(askOf({ fp: 'f1', questions: [{ question: '先做哪一条？', options: [{ label: '第 3 条（推荐）' }] }] }),
  { t: 'ask', rid: 'f1', kind: 'question', questions: [{ question: '先做哪一条？', options: [{ label: '第 3 条（推荐）' }] }] });

console.log('ok talk.mjs');
