// 角色与规则 on /config (claude-fleet#2787): the layer edits are pure — each
// returns the whole person bundle to PUT, everything else in it untouched.
import test from 'node:test';
import assert from 'node:assert/strict';
import { layerOf, setField, withRoleLayer, listEdit, listUndo, setBody, personRows, setRuleTier, resetRule,
  splitBody, sayLabel, roleCard, roleDetail, rulesTable } from '../dist/lib/roles-view.js';

const view = { roles: { steward: { fields: { name: 'steward', model: 'sonnet', effort: 'medium' }, base: { front: { name: 'steward', model: 'opus', effort: 'medium' }, body: '# s\n' },
  sources: { model: ['person:v2'], effort: ['agents'], body: ['agents'] }, locked: [], changed: 1, layer: { front: { model: 'sonnet' }, body: '' }, body: '# s\n' } } };

test('a field set and put back: the role leaves the bundle, the rest stays', () => {
  const bundle = { mcp: { notes: { command: 'x' } }, roles: { steward: { front: { model: 'sonnet' } } } };
  const l = layerOf(view, 'steward');
  assert.deepEqual(l, { front: { model: 'sonnet' }, body: '' });
  const haiku = withRoleLayer(bundle, 'steward', setField(l, 'model', 'haiku'));
  assert.deepEqual(haiku.roles.steward, { front: { model: 'haiku' } });
  assert.deepEqual(haiku.mcp, bundle.mcp);
  assert.equal(bundle.roles.steward.front.model, 'sonnet', 'the input is not mutated');
  const back = withRoleLayer(bundle, 'steward', setField(l, 'model', undefined));
  assert.equal('roles' in back, false);
  assert.deepEqual(back.mcp, bundle.mcp);
  assert.deepEqual(layerOf(view, 'worker'), { front: {}, body: '' });
});

test('list edits: +X / -X, the opposite replaced, never doubled; undo one', () => {
  let l = { front: {}, body: '' };
  l = listEdit(l, 'skills', 'notes');
  l = listEdit(l, 'skills', '-fleet-claim');
  l = listEdit(l, 'skills', '+notes');
  assert.deepEqual(l.front.skills, ['-fleet-claim', '+notes']);
  l = listEdit(l, 'skills', '-notes');
  assert.deepEqual(l.front.skills, ['-fleet-claim', '-notes']);
  l = listUndo(l, 'skills', '-notes');
  l = listUndo(l, 'skills', '-fleet-claim');
  assert.equal('skills' in l.front, false);
});

test('body: a paragraph appended, cleared by an empty one', () => {
  const l = setBody({ front: { model: 'x' }, body: '' }, 'one line  \n\n');
  assert.equal(l.body, 'one line\n');
  assert.equal(setBody(l, '   ').body, '');
  assert.deepEqual(withRoleLayer({}, 'worker', l).roles.worker, { front: { model: 'x' }, body: 'one line\n' });
  assert.deepEqual(splitBody('# w\n\nrules.\n\n## （你加的）\n\nmine\n'), ['# w\n\nrules.\n', '\n## （你加的）\n\nmine\n']);
});

test('rules: a tier change copies the row, 还原 takes it out; a table text reads too', () => {
  const md = '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 金额 | 必须问你（never:money） | ask | 报价, 金额 |\n';
  assert.deepEqual(personRows(md), [{ n: 101, role: 'steward', cond: '金额', action: '必须问你（never:money）', tier: 'ask', keywords: ['报价', '金额'] }]);
  const row = { n: 11, role: 'orchestrator', cond: '单子没写优先级', action: '问你', tier: 'ask', keywords: [], source: '自带' };
  const b = setRuleTier({ rules: md, skills: { a: 'x' } }, row, 'default');
  assert.deepEqual(b.rules.map((r) => [r.n, r.tier]), [[11, 'default'], [101, 'ask']]);
  assert.equal('source' in b.rules[0], false);
  assert.deepEqual(b.skills, { a: 'x' });
  const c = resetRule(resetRule(b, 11), 101);
  assert.equal('rules' in c, false);
});

test('drawing: yours is marked, the lock and the source labels', () => {
  assert.equal(sayLabel('person:v3'), sayLabel('person:v3'));
  assert.match(roleCard('steward', view.roles.steward, true), /class="chip you"/);
  const d = roleDetail('steward', view.roles.steward, layerOf(view, 'steward'));
  assert.match(d, /<s>opus<\/s>/);
  assert.match(d, /data-reset="model"/);
  assert.doesNotMatch(d, /data-reset="effort"/);
  const r = rulesTable({ rows: [{ n: 1, role: 'orchestrator', cond: 'a', action: 'b', tier: 'auto', keywords: [] }], problems: ['x'] },
    { rules: [{ n: 4, role: 'orchestrator', cond: 'c', action: 'd', tier: 'off', keywords: [] }] });
  assert.match(r, /data-rule-reset="4"/);
  assert.match(r, /class="you gone"/);
  assert.doesNotMatch(r, /data-rule-reset="1"/);
});
