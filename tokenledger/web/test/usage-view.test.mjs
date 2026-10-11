// 我的用量 as one page (claude-fleet#3229, EPIC #3225 C4): the first tile is
// what is left — 「不限额」 with no number left when no limit is set — the 5-hour
// window shows only when one is set, the models carry their provider's
// colour, and where-it-went sums to the range under three ways, its rows
// opening a drawer that says where a task ran without splitting by it. The
// page reads /v1/me/usage only — never /v1/me/quota or person-usage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { useLocale } from '../dist/lib/i18n.js';
import { limitTiles, kpis, dayChart, modelBars, workRows, workTable, workList, workDrawer, rangeOf, repoName, epicNum } from '../dist/lib/usage-view.js';

const WORK = {
  issue: [
    { kind: 'issue', title: '合并额度与用量页', repo: 'verkyyi/claude-fleet', issue: 3188, epic: 'verkyyi/claude-fleet#3139', epic_title: '发布列车', tokens: 4200000, models: [['Opus 5.5', 3900000], ['Haiku 5.5', 300000]], sessions: ['issue-3188'], node: 'macmini', login: 'verky' },
    { kind: 'issue', title: '', repo: 'verkyyi/futu-bot', issue: 412, tokens: 2000000, models: [['GPT-5.4 Codex', 2000000]], sessions: ['issue-412'], node: 'fleet-linux-0', login: 'fleet' },
    { kind: 'orch', title: '', tokens: 1800000, sessions: ['orchestrator', 'steward'] },
    { kind: 'none', title: '', tokens: 2000000, sessions: ['scratch-24'] },
  ],
  repo: [
    { kind: 'repo', title: 'verkyyi/claude-fleet', repo: 'verkyyi/claude-fleet', tokens: 4200000 },
    { kind: 'repo', title: 'verkyyi/futu-bot', repo: 'verkyyi/futu-bot', tokens: 2000000 },
    { kind: 'none', title: '', tokens: 3800000 },
  ],
  epic: [
    { kind: 'epic', title: '发布列车', epic: 'verkyyi/claude-fleet#3139', epic_title: '发布列车', tokens: 4200000 },
    { kind: 'none', title: '', tokens: 5800000 },
  ],
};

const zh = (fn) => { useLocale('zh-CN'); try { fn(); } finally { useLocale('en'); } };

test('no limit set: one 不限额 tile, no number left, and the 5 hours as a record', () => zh(() => {
  for (const lim of [{ set: false, used_week: 21400000, used_5h: 1200000 }, undefined, { set: true }]) {
    const tiles = limitTiles(lim);
    assert.equal(tiles.length, 1);
    assert.match(tiles[0], /我的上限/);
    assert.match(tiles[0], /不限额/);
    assert.doesNotMatch(tiles[0], /剩/);
  }
  const NOW = Date.parse('2026-10-11T14:00:00Z');
  const all = kpis({ since_first: '2026-09-01T00:00:00Z', limit: { set: false, used_5h: 1200000 }, today: 3200000, today_prev: 2860000, week: 21400000, week_prev: 22300000, days: [{ claude: 1, codex: 2 }] }, NOW);
  assert.equal(all.length, 4);
  assert.doesNotMatch(all.join(''), /剩 /, 'no remaining number anywhere');
  assert.match(all[1], /今天用了/);
  assert.match(all[1], /比昨天 \+12%/);
  assert.match(all[2], /比上周 -4%/);
  assert.match(all[2], /class="delta down"/);
  assert.match(all[3], /近 5 小时用了/);
  assert.match(all[3], /只是记录，不限额/);
}));

test('a base not fully recorded says so, never a percent off it (since_first)', () => zh(() => {
  const NOW = Date.parse('2026-10-11T14:00:00Z');
  const u = { limit: {}, today: 3200000, today_prev: 10, week: 21400000, week_prev: 70 };
  for (const since of [undefined, '2026-10-11T02:00:00Z']) {
    const k = kpis({ ...u, since_first: since }, NOW);
    assert.match(k[1], /昨天无完整数据/);
    assert.match(k[2], /上周无完整数据/);
    assert.doesNotMatch(k.join(''), /%/, 'no percent at all');
    assert.match(k[2], /style="color:var\(--muted\)">上周无完整数据/);
  }
  // pool usage from yesterday's start: yesterday compares, last week does not
  const k = kpis({ ...u, since_first: '2026-10-10T00:00:00Z' }, NOW);
  assert.match(k[1], /比昨天 \+/);
  assert.match(k[2], /上周无完整数据/);
}));

test('a limit set: what is left = limit − used, and the 5-hour window only when set', () => zh(() => {
  const week = { set: true, limit_week: 40000000, used_week: 21400000, reset_week: '2026-10-14T07:34:00Z', used_5h: 1200000 };
  const one = limitTiles(week);
  assert.equal(one.length, 1);
  assert.match(one[0], /本周还剩/);
  assert.match(one[0], /剩 1860 万/);
  assert.match(one[0], /width:54%/);
  assert.match(one[0], /上限 4000 万 · 已用 2140 万 · 10月14日/);
  const k = kpis({ limit: week });
  assert.equal(k.length, 4);
  assert.match(k[3], /这一档没设上限/);

  const both = limitTiles({ ...week, limit_5h: 3000000 });
  assert.equal(both.length, 2);
  assert.match(both[1], /5 小时还剩/);
  assert.match(both[1], /剩 180 万/);
  assert.equal(kpis({ limit: { ...week, limit_5h: 3000000 } }).length, 4, 'no record tile once the window has a limit');

  const over = limitTiles({ set: true, limit_week: 1000, used_week: 1500 });
  assert.match(over[0], /剩 0/, 'never below 0');
  assert.match(over[0], /class="bad" style="width:100%"/);
}));

test('the chart is Claude + Codex per day, or the empty state', () => zh(() => {
  assert.match(dayChart([]), /这段时间还没有计入你名下的用量/);
  assert.match(dayChart([{ day: '2026-10-10', claude: 0, codex: 0 }]), /class="empty"/);
  const svg = dayChart([{ day: '2026-10-10', claude: 100, codex: 50 }, { day: '2026-10-11', claude: 200, codex: 0 }]);
  assert.match(svg, /<svg class="chart"/);
  assert.match(svg, /var\(--codex\)/);
}));

test('models by human name, Codex in its own colour, not in the id face', () => {
  const html = modelBars([{ name: 'Opus 5.5', provider: 'claude', tokens: 12 }, { name: 'GPT-5.4 Codex', provider: 'codex', tokens: 6 }, { name: 'idle', provider: 'claude', tokens: 0 }]);
  assert.equal((html.match(/hb-row/g) || []).length, 2);
  assert.match(html, /<span class="name" title="Opus 5.5">/);
  assert.match(html, /width:50%;background:var\(--codex\)/);
});

test('where it went: three ways, each summing to the range; orch and none named and greyed', () => zh(() => {
  const issue = workRows(WORK, 'issue');
  assert.deepEqual(issue.map((r) => r.title), ['#3188 合并额度与用量页', '#412', '编排与管家（你开的）', '没挂在任务上的会话']);
  assert.deepEqual(issue.map((r) => r.pct), [42, 20, 18, 20]);
  assert.equal(issue[0].repo, 'claude-fleet');
  assert.equal(issue[0].epic, '批次 #3139');
  assert.ok(issue[2].muted && issue[3].muted && !issue[0].muted);
  assert.deepEqual(workRows(WORK, 'repo').map((r) => r.title), ['claude-fleet', 'futu-bot', '没声明仓库']);
  assert.deepEqual(workRows(WORK, 'epic').map((r) => r.title), ['#3139 发布列车', '不在批次里']);
  for (const m of ['issue', 'repo', 'epic']) assert.equal(workRows(WORK, m).reduce((s, r) => s + r.tokens, 0), 10000000, `${m} sums to the total`);
  assert.deepEqual(workRows({ issue: [{ kind: 'none', tokens: 0 }] }, 'issue'), [], 'a row at 0 is dropped');
  assert.deepEqual(workRows(null, 'repo'), []);

  const table = workTable(issue, 'issue');
  assert.equal((table.match(/<tr data-row=/g) || []).length, 4);
  assert.match(table, /<th>任务<\/th><th>仓库<\/th><th>批次<\/th>/);
  assert.match(table, /chip brand" title="发布列车">批次 #3139/);
  assert.match(workTable(workRows(WORK, 'repo'), 'repo'), /<th>仓库<\/th><th>占比/);
  const list = workList(issue, 'issue');
  assert.equal((list.match(/data-row=/g) || []).length, 4);
  assert.doesNotMatch(list, /<table/);
  assert.match(list, /claude-fleet · 批次 #3139 · 42%/);
  assert.match(workTable([], 'issue'), /这段时间没有计入你名下的用量/);
}));

test('a task\'s drawer: sessions, models, where it ran, whose; a repo\'s lists its tasks', () => zh(() => {
  const rows = workRows(WORK, 'issue');
  const d = workDrawer(rows[0], 'issue', { work: WORK, me: 'verkyyi', rangeKey: 'ui.use.r.7d' });
  assert.match(d, /data-shell="close"/);
  assert.match(d, /issue-3188/);
  assert.match(d, /Opus 5.5 <span class="mono" style="color:var\(--muted\)">390 万/);
  assert.match(d, /服务节点 <b>macmini<\/b> · 登录 <span class="mono">verky<\/span>/);
  assert.match(d, /记在谁名下<\/dt><dd>verkyyi/);
  assert.match(d, /7 天 420 万/);
  assert.match(workDrawer(rows[2], 'issue', { work: WORK }), /orchestrator<br>steward/);
  const repo = workDrawer(workRows(WORK, 'repo')[2], 'repo', { work: WORK });
  assert.match(repo, /里面的任务/);
  assert.match(repo, /编排与管家/);
  assert.match(repo, /没挂在任务上的会话/);
  assert.doesNotMatch(repo, /#3188/);
  assert.match(workDrawer(workRows(WORK, 'epic')[0], 'epic', { work: WORK }), /#3188 合并额度与用量页/);
}));

test('small parsers: the range, a repo\'s name, a batch\'s number', () => {
  assert.equal(rangeOf('30d'), '30d');
  assert.equal(rangeOf('today'), 'today');
  assert.equal(rangeOf('1y'), '7d');
  assert.equal(rangeOf(null), '7d');
  assert.equal(repoName('verkyyi/claude-fleet'), 'claude-fleet');
  assert.equal(epicNum('verkyyi/claude-fleet#3139'), '3139');
  assert.equal(epicNum(''), '');
});

test('the page reads /v1/me/usage only — never the pool, never person-usage', () => {
  for (const f of ['usage.js', 'quota.js', 'lib/usage-view.js']) {
    const src = readFileSync(new URL('../dist/' + f, import.meta.url), 'utf8');
    assert.doesNotMatch(src, /\/v1\/me\/quota|person-usage|\/v1\/admin\//, `${f} reads another answer`);
  }
  assert.match(readFileSync(new URL('../dist/usage.js', import.meta.url), 'utf8'), /\/v1\/me\/usage\?range=/);
  assert.match(readFileSync(new URL('../dist/quota.js', import.meta.url), 'utf8'), /Shell\.start\(\)/);
});
