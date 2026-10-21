// legacy.mjs — every old member-side address and where it lands (GR5E C9,
// src/app/legacy.ts): one row per old address, its query and hash carried
// along, the key that became the path dropped; a new address is not old.
// Run: node --experimental-strip-types test/legacy.mjs
import assert from 'node:assert/strict';
import { LEGACY, SHELL_REF, legacyTarget, shellPath, terminalPath } from '../src/app/legacy.ts';

const rows = [
  // 我的's tabs (C1's move, now this table's)
  ['/usage', '', '', '/me/usage'],
  ['/usage', '?range=30d', '', '/me/usage?range=30d'],
  ['/devices', '?tab=home', '', '/me/devices?tab=home'],
  ['/devices', '?tab=phone&step=3', '', '/me/devices?tab=phone&step=3'],
  ['/settings', '', '#logins', '/me/settings#logins'],
  ['/settings', '?e=wechat-taken', '#logins', '/me/settings?e=wechat-taken#logins'],
  ['/me', '', '', '/me/account'],
  // 任务 · 会话: the list; a code opens that session
  ['/tasks', '', '', '/'],
  ['/tasks', '?q=K3F9', '', '/s/K3F9'],
  ['/tasks', '?q=T1&lang=en', '', '/s/T1?lang=en'],
  ['/tasks', '?q=%20&lang=en', '', '/?lang=en'],
  ['/sessions', '?q=K3F9', '', '/s/K3F9'],
  ['/sessions', '?q=K3F9&lang=en', '#x', '/s/K3F9?lang=en#x'],
  ['/sessions/', '?q=AB12', '', '/s/AB12'],
  // bare 会话 is still its full page; ?open= is that page's own row
  ['/sessions', '', '', null],
  ['/sessions', '?open=K3F9', '', null],
  ['/sessions', '?q=%20', '', null],
  // /terminal: your Shell's session; a worker's, that session's terminal
  ['/terminal', '', '', '/s/shell?view=term'],
  ['/terminal', '?continue=claude', '', '/s/shell?view=term&continue=claude'],
  ['/terminal', '?worker=u-1%2Ff-2', '', '/s/u-1%2Ff-2?view=term'],
  ['/terminal', '?worker=', '', '/'],
];
for (const [path, search, hash, want] of rows) assert.equal(legacyTarget(path, search, hash), want, `${path}${search}${hash}`);

// every row of the table is tested above
const tested = new Set(rows.map(([p]) => p.replace(/\/+$/, '')));
for (const p of Object.keys(LEGACY)) assert.ok(tested.has(p), `${p} has no test row`);

// a new address is not old
for (const p of ['/', '/new', '/chat', '/s/K3F9', '/me/usage', '/me/account']) assert.equal(legacyTarget(p, '?x=1'), null, p);

// the new addresses, spelled once
assert.equal(SHELL_REF, 'shell');
assert.equal(shellPath(), '/s/shell?view=term');
assert.equal(terminalPath('a/b'), '/s/a%2Fb?view=term');
assert.ok(!/^[A-Z0-9]{4}$/i.test(SHELL_REF), 'the Shell\'s ref is never a code');
console.log('legacy: ok');
