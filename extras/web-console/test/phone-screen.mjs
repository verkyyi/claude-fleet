// phone-screen.mjs — a phone's screens (GR5E C7, src/app/phone-screen.ts): the
// list wears the top bar, a session and 新建 are whole screens with their own
// head, everything else a back bar; 返回 steps back, or to the list in place
// on the tab's first entry (never history.back() off it — WeChat closes the page).
// Run: node --experimental-strip-types test/phone-screen.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { backStep, phoneBar } from '../src/app/phone-screen.ts';

assert.equal(phoneBar('/'), 'list');
assert.equal(phoneBar('/', '?about=K3F9'), 'back', 'a link into the conversation is not the list');
for (const p of ['/new', '/s/K3F9', '/s/T12']) assert.equal(phoneBar(p), 'none', p);
for (const p of ['/chat', '/me/account', '/me/usage', '/sessions', '/terminal']) assert.equal(phoneBar(p), 'back', p);

assert.equal(backStep('default'), '/', 'the first entry goes to the list, in place');
assert.equal(backStep(undefined), '/');
assert.equal(backStep('k2x9a'), -1);

// no bottom bar on the phone, and every 返回 goes through the one rule
const shell = readFileSync(new URL('../src/app/Shell.tsx', import.meta.url), 'utf8');
assert.doesNotMatch(shell, /BottomBar/, 'no bottom bar');
for (const f of ['Workspace.tsx', 'NewSession.tsx', 'Shell.tsx']) {
  const src = readFileSync(new URL(`../src/app/${f}`, import.meta.url), 'utf8');
  assert.doesNotMatch(src, /history\.length/, `${f}: 返回 by useBack, not history.length`);
}
console.log('phone-screen: ok');
