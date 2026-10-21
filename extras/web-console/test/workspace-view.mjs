// workspace-view.mjs — one session's workspace (GR5E C4, src/app/workspace-view.ts):
// ?view= picks 对话 or 终端 (anything but term is the conversation); a terminal
// left for 对话 stays connected KEEP_MS and no longer; the 终端 side is the live
// session's terminal, still opening, or ended.
// Run: node --experimental-strip-types test/workspace-view.mjs
import assert from 'node:assert/strict';
import { KEEP_MS, LANDSCAPE, termKept, termOf, viewOf } from '../src/app/workspace-view.ts';

assert.equal(viewOf('term'), 'term');
for (const p of [null, '', 'chat', 'TERM', 'terminal']) assert.equal(viewOf(p), 'chat', `view=${p}`);

assert.equal(KEEP_MS, 60_000, 'the terminal stays 60 s behind the conversation');
const now = 1_000_000;
assert.equal(termKept('term', null, now), true, 'looked at');
assert.equal(termKept('chat', null, now), false, 'never opened');
assert.equal(termKept('chat', now - 59_999, now), true, 'left under a minute ago');
assert.equal(termKept('chat', now - 60_000, now), false, 'left a minute ago');

const row = (o) => ({ id: 'x', code: 'K3F9', title: 't', group: 'work', tag: ['', ''], glyph: 'work', tone: 'ok', line: '', quote: false, kids: [], at: 0, ...o });
assert.deepEqual(termOf(row({ live: { id: 'fleet/abc' } })), { kind: 'live', worker: 'fleet/abc' });
assert.deepEqual(termOf(row({})), { kind: 'opening' }, 'started from 新建, not up yet');
assert.deepEqual(termOf(row({ group: 'gone' })), { kind: 'ended' });

assert.match(LANDSCAPE, /orientation: landscape/);
console.log('workspace-view: ok');
