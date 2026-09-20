// web/dist/lib/dismiss.js — "this viewer closed that notice", and nothing else.
//
// localStorage rather than the URL, for the reason app.js's ops fold gives: the
// scope in the hash is what a link MEANS ("this account, this window"), and
// pasting a link must not reach into which notices the recipient had already
// read. Per-viewer convenience, so it is also fine that it never leaves the
// browser it was written in.
//
// Every access is wrapped, and the property itself is read inside the try: a
// private window throws on `localStorage` before any method is called, and site
// data can be cleared between two reads. Both directions fail CLOSED to "not
// dismissed" -- a banner that explains how to read the numbers is worth showing
// one extra time, and is never worth HIDING because a store was unreadable.
const PREFIX = 'ccquota-dismissed-';

/** store() is the seam the tests use: a Storage-shaped object, or null when
 *  this browser will not give us one. */
const store = () => { try { return globalThis.localStorage || null; } catch { return null; } };

export function isDismissed(key, s = store()) {
  try { return s ? s.getItem(PREFIX + key) === '1' : false; } catch { return false; }
}

export function setDismissed(key, on, s = store()) {
  try { if (s) s.setItem(PREFIX + key, on ? '1' : '0'); } catch {}
}
