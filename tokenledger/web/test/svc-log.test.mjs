// A service's log, live (claude-fleet#2797): the follow, the refusals, the
// reconnect, scrolling up, and the machine page wiring it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createLog, logPath, refusal, atBottom, PAGE, MAX_LINES, WATCHDOG_MS, BACKOFF } from '../dist/lib/svc-log.js';
import { useLocale, t } from '../dist/lib/i18n.js';

useLocale('zh-CN');

// fakeTimers runs timeouts by hand.
function fakeTimers() {
  let id = 0;
  const due = new Map();
  return {
    setTimeout(fn, ms) { due.set(++id, { fn, ms }); return id; },
    clearTimeout(i) { due.delete(i); },
    pending: () => [...due.values()].map((x) => x.ms).sort((a, b) => a - b),
    run(ms) { for (const [i, x] of [...due]) if (x.ms === ms) { due.delete(i); x.fn(); } },
    get size() { return due.size; },
  };
}

// FakeES is an EventSource a test drives.
function fakeES() {
  const made = [];
  class ES {
    constructor(url) { this.url = url; this.l = {}; this.closed = false; made.push(this); }
    addEventListener(n, fn) { (this.l[n] = this.l[n] || []).push(fn); }
    fire(n, data) { for (const fn of this.l[n] || []) fn({ data: JSON.stringify(data) }); }
    close() { this.closed = true; }
  }
  return { ES, made };
}

const flush = () => new Promise((r) => setImmediate(r));
const lines = (...xs) => xs.map((text) => ({ text }));

test('logPath encodes every part; refusal reads a HEAD status', () => {
  assert.equal(logPath('macmini.ts.net', 'twentyfour', 'sms-watch'), '/v1/nodes/macmini.ts.net/services/twentyfour/sms-watch/log');
  assert.equal(logPath('m4', 'a/b', 'x y'), '/v1/nodes/m4/services/a%2Fb/x%20y/log');
  assert.equal(refusal(200), '');
  assert.equal(refusal(403), 'denied');
  assert.equal(refusal(404), 'gone');
  assert.equal(refusal(503), 'offline');
  assert.equal(refusal(500), 'error');
  assert.equal(t('ui.log.st.denied'), '只有管理员看得到');
});

test('the first lines reset the view, later ones append; past MAX_LINES the oldest go', async () => {
  const T = fakeTimers(), { ES, made } = fakeES(), seen = [];
  const log = createLog({ url: '/v1/x/log', ES, T, head: async () => 200, onChange: (k, ls) => seen.push([k, ls.length]) }).start();
  await flush();
  assert.equal(made.length, 1);
  assert.equal(made[0].url, '/v1/x/log');
  made[0].fire('lines', { lines: lines('a', 'b'), from: 100, at: '2026-10-10T00:00:00Z' });
  assert.equal(log.state.mode, 'live');
  assert.deepEqual(log.state.lines.map((l) => l.text), ['a', 'b']);
  assert.equal(log.state.from, 100);
  made[0].fire('lines', { lines: [{ text: 'c', ts: '2026-10-10T00:00:01Z' }], from: 120 });
  assert.deepEqual(log.state.lines.map((l) => l.text), ['a', 'b', 'c']);
  assert.ok(log.state.lines[2].ts > 0, 'a new line keeps the time it was read');
  assert.deepEqual(seen.filter(([k]) => k !== 'status'), [['reset', 2], ['append', 1]]);
  // A burst the node cut: 「跳过 N 行」 in place.
  made[0].fire('lines', { lines: lines('d'), skipped: 37, from: 200 });
  assert.equal(log.state.lines[3].skipped, 37);
  made[0].fire('lines', { lines: Array.from({ length: MAX_LINES }, (_, i) => ({ text: 'n' + i })), from: 300 });
  assert.equal(log.state.lines.length, MAX_LINES);
  assert.equal(log.state.lines[MAX_LINES - 1].text, 'n' + (MAX_LINES - 1));
  assert.equal(log.state.start, false);
  log.stop();
  assert.equal(T.size, 0, 'stop leaves no timer');
  assert.ok(made[0].closed);
});

test('403 / 404 are words, not a retry loop; 503 retries', async () => {
  for (const [status, mode, why] of [[403, 'refused', 'denied'], [404, 'refused', 'gone']]) {
    const T = fakeTimers(), { ES, made } = fakeES();
    const log = createLog({ url: '/u', ES, T, head: async () => status }).start();
    await flush();
    assert.equal(made.length, 0, `${status}: no stream opened`);
    assert.equal(log.state.mode, mode);
    assert.equal(log.state.why, why);
    assert.equal(T.size, 0, `${status}: nothing scheduled`);
  }
  const T = fakeTimers(), { ES, made } = fakeES();
  let status = 503;
  const log = createLog({ url: '/u', ES, T, head: async () => status }).start();
  await flush();
  assert.equal(log.state.mode, 'offline');
  assert.deepEqual(T.pending(), [BACKOFF[0]]);
  status = 200;
  T.run(BACKOFF[0]);
  await flush();
  assert.equal(made.length, 1);
  log.stop();
});

test('end, an error or a silent stream reconnect; the hub\'s recent lines start the view over', async () => {
  const T = fakeTimers(), { ES, made } = fakeES();
  const log = createLog({ url: '/u', ES, T, head: async () => 200 }).start();
  await flush();
  made[0].fire('lines', { lines: lines('a', 'b'), from: 0, start: true });
  made[0].fire('end', { error: 'the machine\'s link closed' });
  assert.ok(made[0].closed);
  assert.equal(log.state.mode, 'down');
  T.run(BACKOFF[0]);
  await flush();
  assert.equal(made.length, 2);
  made[1].fire('lines', { lines: lines('a', 'b', 'c'), from: 0, start: true });
  assert.deepEqual(log.state.lines.map((l) => l.text), ['a', 'b', 'c'], 'no line twice after a reconnect');
  // Nothing at all for WATCHDOG_MS: down, and back.
  assert.ok(T.pending().includes(WATCHDOG_MS));
  T.run(WATCHDOG_MS);
  assert.ok(made[1].closed);
  assert.equal(log.state.mode, 'down');
  log.stop();
  assert.equal(T.size, 0);
});

test('older reads the page before the first line, until the start or MAX_LINES', async () => {
  const T = fakeTimers(), { ES, made } = fakeES(), asked = [];
  const getJSON = async (u) => {
    asked.push(u);
    return u.endsWith('before=500') ? { lines: lines('x', 'y'), from: 20 } : { lines: lines('w'), from: 0, start: true };
  };
  const log = createLog({ url: '/u', ES, T, head: async () => 200, getJSON }).start();
  await flush();
  made[0].fire('lines', { lines: lines('a'), from: 500 });
  assert.ok(log.canOlder());
  assert.equal(await log.older(), true);
  assert.deepEqual(log.state.lines.map((l) => l.text), ['x', 'y', 'a']);
  assert.equal(await log.older(), true);
  assert.deepEqual(asked, ['/u?before=500', '/u?before=20']);
  assert.equal(log.state.start, true);
  assert.equal(log.canOlder(), false, 'nothing before the start');
  assert.equal(await log.older(), false);
  log.stop();
});

test('following: off when scrolled up, on at the bottom', () => {
  assert.equal(atBottom({ scrollHeight: 1000, scrollTop: 600, clientHeight: 400 }), true);
  assert.equal(atBottom({ scrollHeight: 1000, scrollTop: 300, clientHeight: 400 }), false);
  const log = createLog({ url: '/u', ES: null, T: fakeTimers() });
  assert.equal(log.state.follow, true);
  log.setFollow(false);
  assert.equal(log.state.follow, false);
  assert.equal(PAGE, 200);
});

test('the machine page follows a picked row below its 10 s redraw, and stops with the page', () => {
  const src = readFileSync(new URL('../dist/machine.js', import.meta.url), 'utf8');
  assert.match(src, /createLog\(/);
  assert.match(src, /dispose: stopLog/, 'the follow ends when the page is left');
  assert.match(src, /id="md-main"/, 'the redraw has its own place, the log panel is drawn once');
  assert.match(src, /ctx\.on\(box, 'scroll'/);
  assert.doesNotMatch(src, /setInterval|new EventSource/, 'timers and the stream live in lib/svc-log.js and the shell\'s bag');
});
