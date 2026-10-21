import assert from 'node:assert/strict';
import { fromThreadMessageLike } from '@assistant-ui/core';
import { picSrc, linkFiles } from '../src/app/chat/media.ts';

// task T773: an image the home keeps reaches the page as an image part that
// assistant-ui KEEPS — its converter drops a relative URL (the first release
// showed no image at all). Run through the library's own converter.
const base = 'https://hub.example.com/app';
const ref = '7484cbce772837594e8d72678273a894.png';
const src = picSrc({ ref, w: 1, h: 1 }, base);
assert.equal(src, `https://hub.example.com/v1/chat/file?ref=${ref}`);
const thumb = 'data:image/jpeg;base64,/9j/AAAA';
assert.equal(picSrc({ thumb }, base), thumb);
const kept = (role, image) => {
  const warn = console.warn; console.warn = () => {};
  try { return fromThreadMessageLike({ role, content: [{ type: 'image', image }, { type: 'text', text: 'x' }] }, 'm', { type: 'complete', reason: 'unknown' })
    .content.filter((p) => p.type === 'image').length; } finally { console.warn = warn; }
};
assert.equal(kept('assistant', src), 1, 'a reply image must survive the converter');
assert.equal(kept('user', src), 1, "the person's own picture must survive the converter");
assert.equal(kept('assistant', thumb), 1, 'a preview must survive the converter');
assert.equal(kept('assistant', `/v1/chat/file?ref=${ref}`), 0, 'the converter still drops a relative URL — keep picSrc absolute');

const files = new Map([['/Users/x/form.css', 'f' + 'a'.repeat(32)]]);
assert.equal(linkFiles('改在 [form.css](/Users/x/form.css) 和 [网](https://e.com)', files, base),
  `改在 [form.css](https://hub.example.com/v1/chat/file?ref=f${'a'.repeat(32)}) 和 [网](https://e.com)`);
assert.equal(linkFiles('[a](/Users/x/other.css)', files, base), '[a](/Users/x/other.css)');
// a terminal session read along (task YP39): its files are read from the
// machine it runs on — the entry is told which session
const w = 'c7d372cf-903b-5229-8e55-3e286e9c026d/o-r:scratch-3';
assert.equal(picSrc({ ref }, base, w), `https://hub.example.com/v1/chat/file?ref=${ref}&worker=${encodeURIComponent(w)}`);
assert.equal(linkFiles('[form.css](/Users/x/form.css)', files, base, w),
  `[form.css](https://hub.example.com/v1/chat/file?ref=f${'a'.repeat(32)}&worker=${encodeURIComponent(w)})`);
assert.equal(kept('assistant', picSrc({ ref }, base, w)), 1, 'a session image must survive the converter');
console.log('chat-media: ok');
