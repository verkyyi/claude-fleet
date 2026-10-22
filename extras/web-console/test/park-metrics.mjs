// Exercise the production React component, including its phone grouping.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { transform } from 'rolldown/utils';
import { renderToStaticMarkup } from 'react-dom/server';
import React from 'react';
const path = new URL('../src/admin/machines/ParkSummary.tsx', import.meta.url);
const source = await readFile(path, 'utf8');
const { code } = await transform(path.pathname, source, { lang: 'tsx', jsx: { runtime: 'classic' } });
// Resolve React in this test's module; production component has no other imports.
const transformed = code.replace(/import \* as React from ["']react["'];?/, 'const React = globalThis.__parkReact;');
globalThis.__parkReact = React;
const { ParkSummary } = await import('data:text/javascript;base64,' + Buffer.from(transformed).toString('base64'));
const draw = (reading, lang = 'zh') => renderToStaticMarkup(React.createElement(ParkSummary, { reading, lang }));
const r = { sessions_working: 7, sessions_idle: 0, sessions_parked: 4, parked_saved_mb: 5939.2, idle_rss_mb: 0 };
assert.equal(draw({}), ''); // Old node stays quiet.
assert.equal(draw({ sessions_working: 7 }), ''); // Partial report is unknown.
const zh = draw(r);
for (const text of ['会话 11 个 · 在算 7', '已停放 4 · 省 5.8 GB', '空闲常驻 0']) assert.ok(zh.includes(text), text);
const en = draw(r, 'en');
for (const text of ['11 sessions · 7 working', '4 parked · 5.8 GB saved', '0 idle in memory']) assert.ok(en.includes(text), text);
// Three direct children, each its own row at 390; wider screens flow across.
assert.equal((en.match(/<span/g) || []).length, 3);
assert.match(en, /flex-col.*sm:flex-row sm:flex-wrap/);
assert.doesNotMatch(draw({ ...r, sessions_parked: 0 }), /已停放|省/);
for (const lang of ['zh', 'en']) {
 const idle = draw({ ...r, sessions_idle: 2, idle_rss_mb: 1024, idle_reasons: { watched: 1, background: 1 } }, lang);
 assert.match(idle, /1.0 GB/);
 assert.ok(idle.includes(lang === 'zh' ? '有人在看着 1 · 跑着后台命令 1' : 'being viewed 1 · background job 1'));
}
assert.match(draw({ ...r, sessions_idle: 1, idle_rss_mb: null }), /内存读不到/);
assert.match(draw({ ...r, parked_saved_mb: null }), /节省量未采到/);
assert.match(draw({ ...r, parked_saved_mb: null }, 'en'), /savings unavailable/);
console.log('park metrics component: bilingual, absent, zero and 390px grouping PASS');
