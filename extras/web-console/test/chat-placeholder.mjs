// chat-placeholder.mjs — the composer's empty-box words (T841,
// src/app/chat/placeholder.ts): an English page says every one in English,
// the plain 「说点什么…」 included (i18n settles its language once per process).
// Run: node --experimental-strip-types test/chat-placeholder.mjs
import assert from 'node:assert/strict';

globalThis.location = { search: '?lang=en' };
const en = await import('../src/app/chat/placeholder.ts');
assert.equal(en.composerPlaceholder(null, false), 'Say something…', 'English: the plain box');
assert.equal(en.composerPlaceholder(undefined, undefined), 'Say something…', 'English: nothing said yet');
assert.equal(en.SAY_SOMETHING(), 'Say something…', "English: Thread's default");
assert.equal(en.composerPlaceholder({ busy: true }, false), 'The terminal is answering; read-only here');
assert.equal(en.composerPlaceholder({ busy: false }, false), 'Tap “Continue here” to take it over');
assert.equal(en.composerPlaceholder(null, true), 'You can go on once the limit frees up');
for (const v of [en.composerPlaceholder(null, false), en.composerPlaceholder({}, true), en.composerPlaceholder(null, true)])
  assert.doesNotMatch(v, /[一-鿿]/, `no Chinese on an English page: ${v}`);
console.log('chat-placeholder: ok');
