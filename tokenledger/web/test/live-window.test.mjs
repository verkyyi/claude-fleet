import test from 'node:test';
import assert from 'node:assert/strict';
import { windowOf, ago } from '../dist/lib/format.js';
import { liveUnknown, selectLive } from '../dist/lib/providers.js';
import { useLocale } from '../dist/lib/i18n.js';

// #59: the "Right now" card asserted "active" without ever saying what active
// meant, and a hub that had just restarted reported a confident 0. Both are
// claims the page had not measured.

test('windowOf states a duration, not a timestamp', () => {
  useLocale('en');
  // The live card's own window and the roster's, the two values that ship.
  assert.equal(windowOf(180), '3 minutes');
  assert.equal(windowOf(3600), '1 hour');
  // Singular is not cosmetic here: "1 hours" in a sentence about a threshold
  // reads as a typo and costs the sentence its authority.
  assert.equal(windowOf(60), '1 minute');
  assert.equal(windowOf(1), '1 second');
  // Largest unit that divides EXACTLY. 90s is a minute and a half, and
  // rounding it to "2 minutes" would state a threshold nobody configured.
  assert.equal(windowOf(90), '90 seconds');
  assert.equal(windowOf(5400), '90 minutes');
  assert.equal(windowOf(null), '');
});

test('windowOf is not `ago` — Chinese makes the difference visible', () => {
  useLocale('zh-CN');
  assert.equal(windowOf(180), '3 分钟');
  assert.equal(ago(180), '3 分钟前');
  assert.notEqual(windowOf(180), ago(180));
  useLocale('en');
});

test('an unheard-from hub is unknown; a hub that has heard is zero', () => {
  // Fresh hub: nothing on disk, nobody has reported.
  assert.equal(liveUnknown({ ever_reported: false, active_sessions: 0 }), true);
  // An agent has spoken, and says nothing is running. That is a measurement.
  assert.equal(liveUnknown({ ever_reported: true, active_sessions: 0 }), false);
  // No snapshot at all is not the same claim — nothing is rendered yet.
  assert.equal(liveUnknown(null), false);
  assert.equal(liveUnknown(undefined), false);
});

test('a hub too old to carry the field keeps its old behaviour', () => {
  // Absent means "this hub cannot tell us", not "it just restarted". Treating
  // a missing field as unknown would put every un-upgraded deployment
  // permanently into the restart state.
  assert.equal(liveUnknown({ active_sessions: 0 }), false);
  assert.equal(liveUnknown({ ever_reported: undefined }), false);
});

test('scoping cannot make an unheard-from hub informative', () => {
  const snap = {
    ever_reported: false, active_window_sec: 180, started_at: '2026-09-19T00:00:00Z',
    sessions: [], active_sessions: 0,
  };
  const scoped = selectLive(snap, { machine: 'ep1' }, 'acct-a');
  assert.equal(liveUnknown(scoped), true, 'a chip narrows which sessions count, not what the hub knows');
  assert.equal(scoped.active_window_sec, 180, 'the card still has to state its window while scoped');
  assert.equal(scoped.started_at, snap.started_at);
});

test('the window the card states is the server\'s, not a copy', () => {
  // The whole point of shipping active_window_sec: change it on the server and
  // the sentence changes with it, because nothing here knows the number.
  const snap = { ever_reported: true, active_window_sec: 300, sessions: [], active_sessions: 0 };
  assert.equal(selectLive(snap, {}, 'all').active_window_sec, 300);
  useLocale('en');
  assert.equal(windowOf(300), '5 minutes');
});
