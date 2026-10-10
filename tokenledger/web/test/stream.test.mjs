// The push channel's page half (claude-fleet#2794): answers reach the pages
// that subscribed, a silent or broken channel goes yellow and reconnects on
// the backoff, the reconnect is the catch-up, and a channel that cannot be
// built falls back to a 10 s poll. Plus the freshness words (lib/shell.js).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createStream, observedOf, WATCHDOG_MS, BACKOFF, POLL_MS, POLL_AFTER, PROBE_EVERY, POLL_URLS, TOPICS } from '../dist/lib/stream.js';
import { freshness, freshTag, streamLine, FRESH } from '../dist/lib/shell.js';
import { timerBag } from '../dist/lib/router.js';
import { useLocale } from '../dist/lib/i18n.js';

// clock is a virtual setTimeout / setInterval: advance(ms) runs what falls due.
function clock() {
  let now = 1_000_000, n = 0;
  const due = new Map(); // id → { at, fn, every }
  const T = {
    setTimeout: (fn, ms) => { due.set(++n, { at: now + ms, fn }); return n; },
    clearTimeout: (id) => { due.delete(id); },
    setInterval: (fn, ms) => { due.set(++n, { at: now + ms, fn, every: ms }); return n; },
    clearInterval: (id) => { due.delete(id); },
  };
  return {
    T, now: () => now,
    pending: () => due.size,
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        let id = null, next = null;
        for (const [k, v] of due) if (v.at <= end && (next === null || v.at < next.at)) { id = k; next = v; }
        if (!next) break;
        now = next.at;
        if (next.every) next.at += next.every; else due.delete(id);
        next.fn();
        await new Promise((r) => setImmediate(r));
      }
      now = end;
    },
  };
}

// FakeES records every connection the channel makes.
function fakeES() {
  const made = [];
  class ES {
    constructor(url) { this.url = url; this.l = {}; this.closed = false; made.push(this); }
    addEventListener(type, fn) { (this.l[type] ||= []).push(fn); }
    close() { this.closed = true; }
    send(type, data) { for (const fn of this.l[type] || []) fn({ data: JSON.stringify(data) }); }
    fail() { if (this.onerror) this.onerror(new Event('error')); }
  }
  return { ES, made, last: () => made[made.length - 1] };
}

const frame = (body, observed = '2026-10-09T10:00:00Z') => ({ observed_at: observed, sent_at: '2026-10-09T10:00:01Z', body });

test('answers reach the pages that took the topic, with when they were measured', async () => {
  const c = clock(), f = fakeES(), seen = [];
  const s = createStream({ ES: f.ES, T: c.T, now: c.now }).start();
  assert.equal(f.made.length, 1);
  assert.match(f.last().url, /^\/v1\/fleet\/stream\?topics=nodes,sessions,usage$/);
  assert.equal(s.status().mode, 'connecting');
  const off = s.subscribe('nodes', (e) => seen.push(e));
  f.last().send('nodes', frame({ nodes: [] }));
  f.last().send('sessions', frame({ sessions: [] }));
  assert.equal(seen.length, 1, 'only the topic it took');
  assert.equal(seen[0].observedAt, Date.parse('2026-10-09T10:00:00Z'));
  assert.equal(s.status().mode, 'live');
  assert.equal(s.latest('sessions').body.sessions.length, 0);
  f.last().send('nodes', frame({ nodes: [] }, null));
  assert.equal(seen[1].observedAt, null, 'no time from the source is 时间未知, never now');
  off();
  f.last().send('nodes', frame({ nodes: [1] }));
  assert.equal(seen.length, 2, 'unsubscribed');
  assert.equal(s.subscribers('nodes'), 0);
});

test('hub-stream-silent: a stream a proxy holds open but never feeds is down within 30 s and reconnects; the reconnect is the catch-up', async () => {
  const c = clock(), f = fakeES(), seen = [], modes = [];
  const s = createStream({ ES: f.ES, T: c.T, now: c.now, onStatus: (st) => modes.push(st.mode) }).start();
  s.subscribe('sessions', (e) => seen.push(e.body));
  f.last().send('sessions', frame({ n: 1 }));
  // pings keep it alive past the watchdog
  for (let i = 0; i < 3; i++) { await c.advance(20000); f.last().send('ping', { sent_at: 'x' }); }
  assert.equal(s.status().mode, 'live');
  assert.equal(f.made.length, 1);
  // now the proxy holds it: nothing, no close
  await c.advance(WATCHDOG_MS - 1);
  assert.equal(s.status().mode, 'live');
  await c.advance(1);
  assert.equal(s.status().mode, 'down', 'yellow at 30 s of silence');
  assert.ok(f.made[0].closed, 'the held stream is closed');
  await c.advance(BACKOFF[0]);
  assert.equal(f.made.length, 2, 'reconnected after the first backoff');
  f.last().send('sessions', frame({ n: 2 }));
  assert.equal(s.status().mode, 'live');
  assert.deepEqual(seen.map((b) => b.n), [1, 2], 'the reconnect delivered the current picture');
  assert.ok(modes.includes('down'));
});

test('a broken channel backs off 1, 2, 4, 8, then 15 s, and a word heard resets it', async () => {
  const c = clock(), f = fakeES();
  const s = createStream({ ES: f.ES, T: c.T, now: c.now }).start();
  f.last().send('ping', {});
  const gaps = [];
  for (let i = 0; i < 6; i++) {
    const before = f.made.length;
    f.last().fail();
    assert.equal(s.status().mode, 'down');
    let waited = 0;
    while (f.made.length === before) { await c.advance(500); waited += 500; }
    gaps.push(waited);
  }
  assert.deepEqual(gaps, [1000, 2000, 4000, 8000, 15000, 15000]);
  assert.equal(s.status().mode, 'down', 'an error is the backoff, never the poll');
  f.last().send('ping', {});
  f.last().fail();
  await c.advance(BACKOFF[0]);
  assert.equal(f.made.length, 8, 'heard again: back to 1 s');
});

test('no EventSource at all: the topics are polled every 10 s, 轮询 in the top bar', async () => {
  const c = clock(), asked = [];
  const bodies = { '/v1/nodes': { nodes: [{ last_heartbeat: '2026-10-09T10:00:05Z' }] }, '/v1/fleet/fleet_sessions': { nodes: [{ observed_at: '2026-10-09T10:00:03Z' }], sessions: [] }, '/v1/live': { sessions: [] } };
  const fetchJSON = async (u) => { asked.push(u); return bodies[u]; };
  const seen = [];
  const s = createStream({ ES: undefined, fetchJSON, T: c.T, now: c.now });
  s.subscribe('nodes', (e) => seen.push(e));
  s.start();
  await c.advance(0);
  assert.equal(s.status().mode, 'poll');
  assert.deepEqual(asked.sort(), Object.values(POLL_URLS).sort());
  assert.equal(seen[0].observedAt, Date.parse('2026-10-09T10:00:05Z'), 'observed_at worked out as the hub does');
  await c.advance(POLL_MS);
  assert.equal(asked.length, 6);
  assert.equal(streamLine(s.status(), c.now()).text.startsWith('polling') || streamLine(s.status(), c.now()).text.startsWith('轮询'), true);
});

test('an EventSource that throws, or stays silent twice, falls back to the poll and keeps probing the stream', async () => {
  const c = clock();
  const throwing = createStream({ ES: class { constructor() { throw new Error('blocked'); } }, fetchJSON: async () => ({}), T: c.T, now: c.now }).start();
  await c.advance(0);
  assert.equal(throwing.status().mode, 'poll');
  throwing.stop();

  const f = fakeES();
  const s = createStream({ ES: f.ES, fetchJSON: async () => ({ nodes: [] }), T: c.T, now: c.now }).start();
  for (let i = 0; i < POLL_AFTER; i++) {
    assert.notEqual(s.status().mode, 'poll');
    await c.advance(WATCHDOG_MS);           // a buffering proxy: not a word
    await c.advance(BACKOFF[BACKOFF.length - 1]);
  }
  assert.equal(s.status().mode, 'poll');
  const made = f.made.length;
  let waited = 0;
  while (f.made.length === made && waited < POLL_MS * (PROBE_EVERY + 1)) { await c.advance(POLL_MS); waited += POLL_MS; }
  assert.equal(f.made.length, made + 1, 'tried the stream again');
  assert.ok(waited <= POLL_MS * PROBE_EVERY, `the probe came within a minute of polls (${waited} ms)`);
  assert.equal(s.status().mode, 'poll', 'still polling while the probe is out');
  f.last().send('nodes', frame({ nodes: [] }));
  assert.equal(s.status().mode, 'live', 'the stream back: polling stops');
  const timers = c.pending();
  await c.advance(POLL_MS * 2);
  assert.equal(c.pending(), timers, 'no poll left running');
});

test('observedOf reads each topic the way the hub does', () => {
  assert.equal(observedOf('nodes', { nodes: [{ last_heartbeat: '2026-10-09T10:00:00Z' }, { last_heartbeat: '2026-10-09T10:00:09Z' }, { last_heartbeat: null }] }), Date.parse('2026-10-09T10:00:09Z'));
  assert.equal(observedOf('sessions', { nodes: [{ observed_at: '2026-10-09T09:00:00Z' }] }), Date.parse('2026-10-09T09:00:00Z'));
  assert.equal(observedOf('usage', { sessions: [] }), null);
  assert.equal(observedOf('nodes', null), null);
  assert.deepEqual(TOPICS, ['nodes', 'sessions', 'usage']);
});

test('freshness: N s ago, yellow past a minute, grey 数据旧了 past five, 时间未知 without a time', () => {
  useLocale('zh-CN');
  const now = Date.parse('2026-10-09T10:10:00Z');
  assert.deepEqual(freshness(now - 12000, now), { cls: '', text: '12 秒前' });
  assert.equal(freshness(now - FRESH.warn - 1000, now).cls, 'warn');
  const old = freshness(now - FRESH.stale - 1000, now);
  assert.equal(old.cls, 'stale');
  assert.match(old.text, /^数据旧了/);
  assert.deepEqual(freshness(null, now), { cls: 'unknown', text: '时间未知' });
  assert.equal(freshness('2026-10-09T10:09:50Z', now).text, '10 秒前');
  assert.match(freshTag(null, now), /data-fresh-at=""/);
  assert.equal(streamLine({ mode: 'live', lastAt: now - 3000 }, now).text, '3 秒前更新');
  assert.equal(streamLine({ mode: 'down', lastAt: now - 40000 }, now).cls, 'warn');
  assert.match(streamLine({ mode: 'poll', lastAt: now - 3000 }, now).text, /^轮询/);
  useLocale('en');
  assert.equal(streamLine({ mode: 'live', lastAt: now - 3000 }, now).text, 'updated 3 s ago');
});

test('a page\'s subscriptions are dropped when it is left (timerBag.hold)', () => {
  const bag = timerBag({ setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {} });
  let off = 0;
  bag.hold(() => off++);
  assert.equal(bag.count(), 1);
  bag.clear();
  assert.equal(off, 1);
  bag.hold(() => off++);
  assert.equal(off, 2, 'a hold after the page left runs at once');
});

test('the pages that used to poll take the push channel instead', () => {
  const src = (f) => readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
  for (const f of ['machines.js', 'lib/sessions-view.js']) {
    assert.ok(/ctx\.subscribe\('(nodes|sessions)'/.test(src(f)), `${f} subscribes`);
    assert.ok(!/ctx\.every\(/.test(src(f)), `${f} no longer polls`);
  }
  assert.ok(!/setInterval\(\(\) => \{ if \(!document\.hidden\) live\(true\)/.test(src('app-shell.js')), 'the top bar no longer polls fleet_sessions');
});
