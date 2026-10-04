import test from 'node:test';
import assert from 'node:assert/strict';
import { FLEET_LINKS, NOTE_UNASSIGNED, fleetNav } from '../dist/lib/fleetnav.js';
import { en } from '../dist/lib/i18n/en.js';

// claude-fleet#1458: the home page had no way to 连接 / 我的会话. The way
// there is per-person, so it is a decision over /v1/fleet/me, not markup.

test('every link and the note print through a key the dictionary has', () => {
  for (const { key, href } of FLEET_LINKS) {
    assert.ok(key in en, `${key} is missing from the dictionary`);
    assert.match(href, /^\/[a-z]+$/, `${href} is a page on this hub`);
  }
  assert.ok(NOTE_UNASSIGNED in en);
  assert.ok('fleet.nav' in en, 'the nav needs its accessible name');
});

test('a hub without the fleet module shows nothing', () => {
  assert.deepEqual(fleetNav(null), { links: [], note: null, login: null });
  assert.deepEqual(fleetNav(undefined), { links: [], note: null, login: null });
});

test("the operator's door gets every page, the roster included", () => {
  const nav = fleetNav({ signed_in: false, principal: null, accounts: [] });
  assert.deepEqual(nav.links.map((l) => l.href), ['/connect', '/sessions', '/nodes']);
  assert.equal(nav.note, null);
});

test('a person with an active login gets the two personal pages and their login', () => {
  const nav = fleetNav({
    signed_in: true, person: 'yilianghui',
    principal: { principal_id: 'yilianghui', login: 'verkyyi' },
    accounts: [{ hostname: 'mini2', login: 'verkyyi', state: 'pending' }, { hostname: 'macmini', login: 'verkyyi', state: 'active' }],
  });
  assert.deepEqual(nav.links.map((l) => l.href), ['/connect', '/sessions']);
  assert.equal(nav.note, null);
  assert.equal(nav.login, 'verkyyi');
});

test('a person placed nowhere yet is told so, and gets no link to an empty page', () => {
  for (const me of [
    { signed_in: true, person: 'zhangsan', principal: null, accounts: [] },
    { signed_in: true, person: 'zhangsan', principal: { login: 'zhangsan' }, accounts: [{ state: 'pending' }, { state: 'failed' }] },
    { signed_in: true, person: 'ccquota-staff', principal: null },
  ]) {
    const nav = fleetNav(me);
    assert.deepEqual(nav.links, []);
    assert.equal(nav.note, NOTE_UNASSIGNED);
    assert.equal(nav.login, null);
  }
});
