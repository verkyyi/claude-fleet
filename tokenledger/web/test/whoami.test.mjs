import test from 'node:test';
import assert from 'node:assert/strict';
import { STRINGS, strings, whoami } from '../dist/lib/whoami.js';

// claude-fleet#1467: every human page carries the same header -- who is
// signed in, and the way out -- decided from /v1/me, never guessed per page.

test('both dictionaries say the same things', () => {
  assert.deepEqual(Object.keys(STRINGS.en).sort(), Object.keys(STRINGS['zh-CN']).sort());
  assert.equal(strings('fr'), STRINGS['zh-CN'], 'an unknown lang falls back to zh-CN');
});

test('no answer, or an open hub, draws nothing', () => {
  for (const me of [null, undefined, {}, { via: 'open' }, { via: 'wecom' }, { via: 'tailnet' }, 'yilianghui']) {
    assert.equal(whoami(me), null, JSON.stringify(me));
  }
});

test("the operator's doors name the door, not a person", () => {
  assert.deepEqual(whoami({ via: 'token', can_logout: true }), { name: '管理员', sub: '令牌', person: '', via: '令牌', logout: true });
  assert.equal(whoami({ via: 'token', can_logout: false }).logout, false, 'a bearer has no cookie to clear');
});

test('a GitHub person (claude-fleet#1984): their username, the role and GitHub under it', () => {
  const admin = whoami({ via: 'github', person: 'gh:12345', name: 'verkyyi', role: 'admin', can_logout: true }, 'en');
  assert.deepEqual(admin, { name: 'verkyyi', sub: 'Admin · GitHub', person: '', via: 'GitHub', logout: true });
  assert.equal(whoami({ via: 'github', person: 'gh:7', name: 'alice', role: 'user', can_logout: true }).sub, '使用者 · GitHub');
  assert.equal(whoami({ via: 'github', person: 'gh:7', name: ' ' }), null);
});
