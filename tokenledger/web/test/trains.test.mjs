// The /trains page's computations (claude-fleet#3870): the bars, the 5-minute
// scale, the pill, the hub's 「卡在…」 line and the KPIs — off the stats shape
// GET /v1/fleet/release/stats answers.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fmtSecs, scaleOf, bars, state, whyLine, kpis, lanes, stageKind, SLOW_SECS } from '../dist/lib/trains.js';
import { useLocale } from '../dist/lib/i18n.js';
import { PAGES, navFor } from '../dist/lib/shell.js';

const slow = {
  run_id: '902', sha: 'ab'.repeat(20), conclusion: 'success', total_secs: 360, started_at: '2026-10-13T08:00:00Z',
  merges: [{ sha: 'cd'.repeat(20), subject: 'a change' }],
  stages: [
    { name: 'board', offset_secs: 0, secs: 10, budget_secs: 30 },
    { name: 'Linux', offset_secs: 20, secs: 240, budget_secs: 150, queue_secs: 40 },
    { name: 'node image', offset_secs: 300, secs: 900, budget_secs: 120, off_path: true },
    { name: 'release', offset_secs: 280, secs: 70, budget_secs: 90 },
  ],
  bottleneck: { stage: 'Linux', secs: 240, why: '超预算 90 秒（预算 150 秒）' },
};
const red = { run_id: '901', sha: 'ef'.repeat(20), conclusion: 'failure', total_secs: 100, merges: [],
  stages: [{ name: 'Linux', offset_secs: 10, secs: 80, result: 'failure' }],
  bottleneck: { stage: 'Linux', secs: 80, why: 'dash-marker-selftest.sh' } };

test('seconds read as minutes and seconds, a missing number as a dash', () => {
  useLocale('zh-CN');
  assert.equal(fmtSecs(135), '2 分 15 秒');
  assert.equal(fmtSecs(45), '45 秒');
  assert.equal(fmtSecs(null), '—');
  useLocale('en');
  assert.equal(fmtSecs(65), '1m 05s');
});

test('the scale is past 5 minutes and never stretched by what is off the path', () => {
  assert.equal(scaleOf([]), SLOW_SECS * 1.1);
  assert.equal(scaleOf([slow]), 360);
  const b = bars(slow, scaleOf([slow]));
  assert.equal(b.length, 4);
  const lin = b.find((x) => x.name === 'Linux');
  assert.equal(lin.kind, 'lin');
  assert.ok(Math.abs(lin.width - (240 / 360) * 100) < 1e-9);
  assert.ok(lin.queue > 0 && lin.queue < lin.width, 'the runner wait is its own piece');
  const img = b.find((x) => x.name === 'node image');
  assert.ok(img.off && img.left + img.width <= 100, 'clipped to the bar');
  assert.ok(bars(red, 330)[0].red);
  assert.equal(stageKind('mac follow'), 'mac');
});

test('a slow train and a red one each say where they stuck', () => {
  useLocale('zh-CN');
  assert.equal(whyLine(slow), '卡在「Linux」：4 分 00 秒——超预算 90 秒（预算 150 秒）');
  assert.equal(whyLine(red), '卡在「Linux」：1 分 20 秒——dash-marker-selftest.sh');
  assert.equal(whyLine({ bottleneck: { stage: '', why: '没发出' } }), '没发出：没发出');
  assert.equal(whyLine({ bottleneck: null }), '');
  assert.deepEqual(state(red), ['bad', '没发']);
  assert.deepEqual(state(slow), ['warn', '超时']);
  assert.deepEqual(state({ conclusion: 'success', total_secs: 120 }), ['ok', '已发']);
});

test('the four KPIs and the two lanes', () => {
  useLocale('zh-CN');
  const k = kpis({ merge_to_stable_p50: 250, merge_to_stable_p95: 470, merge_to_stable_n: 12, runs_started: 10, runs_shipped: 9,
    run_p50_secs: 190, runs_slow: 2, runs_slow_said: 2 });
  assert.deepEqual(k.map((x) => x.value), ['4 分 10 秒', '9/10', '3 分 10 秒', '2']);
  assert.equal(k[0].sub, '最慢一成 7 分 50 秒 · 12 次合并');
  assert.equal(k[3].sub, '2/2 说出了卡在哪段');
  assert.deepEqual(kpis({}).map((x) => x.value), ['—', '0/0', '—', '0']);
  const [lx, mac] = lanes({ lanes: { stable: 'a'.repeat(40), stable_macos: 'b'.repeat(40) } });
  assert.equal(lx.sha, 'aaaaaaa');
  assert.equal(mac.cls, 'warn');
  assert.equal(lanes({ lanes: { stable: 'a'.repeat(40) } })[1].note, '同一版');
});

test('the page is an admin item, after Feedback, under /app/trains', () => {
  const p = PAGES.find((x) => x.id === 'trains');
  assert.equal(p.group, 'admin');
  assert.equal(p.href, '/app/trains');
  assert.equal(p.module, '/admin/trains.js');
  assert.ok(!navFor(['overview']).some((x) => x.id === 'trains'), 'not without the hub listing it');
  // phone width: no fixed widths that would scroll a 390px screen sideways
  const css = readFileSync(new URL('../dist/app.css', import.meta.url), 'utf8');
  const block = css.slice(css.indexOf('发布列车'));
  assert.ok(!/[{;]\s*(min-)?width:\s*\d{3,}px/.test(block), 'a fixed width in the trains CSS');
  assert.ok(/@media\(max-width:620px\)\{\.tr-kpis\{grid-template-columns:repeat\(2/.test(block), 'two KPI columns on a phone');
});
