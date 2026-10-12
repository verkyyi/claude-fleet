// 「机器」只列托管机器 (claude-fleet#2795): /v1/nodes' machines[].role splits a
// host (the hub places sessions there) from a client device (a laptop or tablet
// running only the shell). The admin Machines page draws the hosts; the client
// devices join 我的设备 / 全部设备, once each.
import test from 'node:test';
import assert from 'node:assert/strict';
import { machineCards, clientMachines, isClient } from '../dist/lib/admin.js';
import { myMachines, deviceMachines } from '../dist/lib/pages.js';
import { devicesPanel } from '../dist/lib/devices-view.js';
import { useLocale } from '../dist/lib/i18n.js';
import { en } from '../dist/lib/i18n/en.js';

const mach = (hostname, role, extra = {}) => ({ hostname, role, status: 'online', last_heartbeat: '2026-10-09T10:00:00Z', ...extra });
const node = (hostname, os_user, extra = {}) => ({ endpoint_id: `ep_${hostname}_${os_user}`, hostname, os_user, status: 'online', ncpu: 8, load1: 1, sessions: 0, ...extra });
// Two managed machines, three client devices.
const SNAP = {
  machines: [mach('mac-c.local', 'host'), mach('mac-d.local', 'host'), mach('mac-a.local', 'client'), mach('mac-b.local', 'client'), mach('ipad', 'client', { alias: 'iPad' })],
  nodes: [
    node('mac-c.local', 'root', { machine_link: true }), node('mac-c.local', 'carol'), node('mac-d.local', 'carol'),
    node('mac-a.local', 'carol', { personal: true, compute_off: true }), node('mac-b.local', 'carol', { personal: true }), node('ipad', 'carol', { personal: true }),
  ],
};

test('the Machines page draws the 2 hosts, not the 3 client devices', () => {
  const cards = machineCards(SNAP);
  assert.deepEqual(cards.map((c) => c.name), ['mac-c', 'mac-d']);
  assert.equal(clientMachines(SNAP).length, 3);
  assert.equal(isClient(SNAP.machines[2]), true);
  assert.equal(isClient(SNAP.machines[0]), false);
});

test('an older hub says no role: every machine is still a card', () => {
  const old = { machines: SNAP.machines.map(({ role, ...m }) => m), nodes: SNAP.nodes };
  assert.equal(machineCards(old).length, 5);
  assert.equal(clientMachines(old).length, 0);
  assert.deepEqual(deviceMachines(old, []), []);
});

test('我的机器 lists the hosts only', () => {
  assert.deepEqual(myMachines(SNAP, null).map((r) => r.hostname), ['mac-c.local', 'mac-d.local']);
});

test('the client devices join the device list once each', () => {
  // mac-a is already a registered device by name: not listed again.
  const devs = [{ fingerprint: 'SHA256:a', name: 'MAC-A', registered_at: '2026-10-01T00:00:00Z', last_used_at: '2026-10-09T09:00:00Z' }];
  const ms = deviceMachines(SNAP, devs);
  assert.deepEqual(ms.map((m) => m.label), ['iPad', 'mac-b']);
  assert.equal(ms[1].logins, 'carol');
  useLocale('en', en);
  const html = devicesPanel({ devices: devs }, false, SNAP);
  assert.equal((html.match(/data-client=/g) || []).length, 2);
  assert.equal((html.match(/data-revoke=/g) || []).length, 1);
  assert.match(html, /3 active/);
  for (const h of ['mac-a.local', 'mac-b.local', 'ipad']) assert.ok(html.includes('>MAC-A<') || html.includes(h), h);
  // No /v1/nodes (an older page, a failed read): the list as it was.
  assert.equal((devicesPanel({ devices: devs }, false).match(/data-client=/g) || []).length, 0);
});

test('All devices names the client device\'s logins as its owner', () => {
  useLocale('en', en);
  const html = devicesPanel({ devices: [] }, true, SNAP);
  assert.equal((html.match(/data-client=/g) || []).length, 3);
  assert.ok(!/class="empty"/.test(html));
});
