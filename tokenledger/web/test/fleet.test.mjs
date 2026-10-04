import test from 'node:test';
import assert from 'node:assert/strict';
import { fleetCell, FLEET_STALE_SEC } from '../dist/lib/fleet.js';
import { withLocale } from '../dist/lib/i18n.js';

const NOW = Date.parse('2026-09-24T10:00:00Z');
const iso = (secsAgo) => new Date(NOW - secsAgo * 1000).toISOString();
const row = (over = {}) => ({
  endpoint_id: 'ep-1', last_seen: iso(30),
  fleet_head: '0164208', fleet_behind: 12, fleet_verdict: 'BEHIND', fleet_follow: 'OK',
  fleet_fetched: true, fleet_seen_at: iso(120), ...over,
});

test('a login that never reported an install is a dash, not a reading', () => {
  assert.equal(fleetCell({ endpoint_id: 'ep', last_seen: iso(1) }, NOW), null);
  assert.equal(fleetCell(row({ fleet_head: '' }), NOW), null);
});

test('behind: head and the count', () => {
  const c = fleetCell(row(), NOW);
  assert.equal(c.text, '0164208 · 12 behind');
  assert.equal(c.flag, null);
  assert.equal(c.stale, false);
});

// The whole reason `behind` is nullable: a count that could not be read is
// "unknown", and rendering it as 0 says "current" about an install nobody
// measured (claude-fleet#635).
test('behind null is "unknown", never 0, with the reason in the tooltip', () => {
  const c = fleetCell(row({ fleet_behind: null, fleet_verdict: 'UNKNOWN', fleet_error: 'no upstream configured' }), NOW);
  assert.equal(c.text, '0164208 · unknown');
  assert.doesNotMatch(c.text, /\b0\b/);
  assert.match(c.title, /no upstream configured/);
});

test('a real zero is "current"', () => {
  assert.equal(fleetCell(row({ fleet_behind: 0, fleet_verdict: 'CURRENT' }), NOW).text, '0164208 · current');
});

test('fetched:false is said out loud on every known count, current most of all', () => {
  assert.equal(fleetCell(row({ fleet_fetched: false }), NOW).text, '0164208 · 12 behind (not fetched)');
  assert.equal(fleetCell(row({ fleet_behind: 0, fleet_verdict: 'CURRENT', fleet_fetched: false }), NOW).text,
    '0164208 · current (not fetched)');
  // …but an unknown count has nothing to qualify.
  assert.equal(fleetCell(row({ fleet_behind: null, fleet_verdict: 'UNKNOWN', fleet_fetched: false }), NOW).text,
    '0164208 · unknown');
});

test('ahead and diverged say so', () => {
  assert.equal(fleetCell(row({ fleet_behind: 0, fleet_verdict: 'AHEAD' }), NOW).text, '0164208 · ahead');
  assert.equal(fleetCell(row({ fleet_behind: 4, fleet_verdict: 'DIVERGED' }), NOW).text, '0164208 · diverged, 4 behind');
});

test('install-sync STUCK / OFF is a flag carrying the daemon\'s own sentence; OK / UNSEEN / null are not', () => {
  const stuck = fleetCell(row({ fleet_follow: 'STUCK', fleet_follow_text: 'on · no-daemon · … [STUCK]' }), NOW);
  assert.equal(stuck.flag.verdict, 'STUCK');
  assert.match(stuck.title, /install-sync is stuck: on · no-daemon/);
  assert.equal(fleetCell(row({ fleet_follow: 'OFF' }), NOW).flag.verdict, 'OFF');
  for (const f of ['OK', 'UNSEEN', 'UNKNOWN', '', undefined]) {
    assert.equal(fleetCell(row({ fleet_follow: f }), NOW).flag, null, `follow=${f}`);
  }
});

test('a reading much older than the row\'s own last report is stale', () => {
  const fresh = fleetCell(row({ fleet_seen_at: iso(300) }), NOW);
  assert.equal(fresh.stale, false);
  assert.match(fresh.title, /reported 5m ago/);
  const old = fleetCell(row({ fleet_seen_at: iso(30 + FLEET_STALE_SEC + 60) }), NOW);
  assert.equal(old.stale, true);
  assert.match(old.title, /not since/);
  // Age alone is not staleness: an endpoint that itself went quiet an hour
  // ago has a reading exactly as old as its last report.
  const quiet = fleetCell(row({ last_seen: iso(7200), fleet_seen_at: iso(7300) }), NOW);
  assert.equal(quiet.stale, false);
});

test('zh-CN: null is 未知, not 0', () => {
  withLocale('zh-CN', () => {
    assert.equal(fleetCell(row({ fleet_behind: null, fleet_verdict: 'UNKNOWN' }), NOW).text, '0164208 · 未知');
    assert.equal(fleetCell(row({ fleet_fetched: false }), NOW).text, '0164208 · 落后 12 （未 fetch）');
  });
});
