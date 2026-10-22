import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { transform } from 'rolldown/utils';
const path = new URL('../src/admin/machines/model.ts', import.meta.url);
const { code } = await transform(path.pathname, await readFile(path, 'utf8'), { lang: 'ts' });
const { machineRows } = await import('data:text/javascript;base64,' + Buffer.from(code).toString('base64'));
const host = 'Verkys-Mac';
const rows = (nodes) => machineRows({ machines: [{ hostname: host, role: 'managed', status: 'online' }], nodes });
const client = { hostname: host, endpoint_id: 'old-client', role: 'client' };
const managed = { hostname: host, endpoint_id: 'new-managed', role: 'managed' };
const row = rows([client, managed])[0];
assert.deepEqual(row.eps, ['old-client', 'new-managed']); // Retirement still includes every endpoint.
assert.deepEqual(row.policyEps, ['new-managed']); // Client's old enrollment cannot hide the compute policy.
assert.deepEqual(rows([client])[0].policyEps, []); // Never borrow a client's policy.
assert.deepEqual(rows([managed, { hostname: host, endpoint_id: 'legacy' }])[0].policyEps, ['new-managed', 'legacy']);
console.log('machine policy endpoint selection PASS');

const live = { ...managed, status: 'online' };
const old = { hostname: host, endpoint_id: 'old-login', status: 'lost', max_sessions: 30 };
assert.equal(rows([live, old])[0].cap, null); // M5: 12 current sessions must not display /30 from October 5.
assert.equal(rows([{ ...live, max_sessions: 4 }, old])[0].cap, 4);
assert.equal(rows([live, { ...live, endpoint_id: 'bounded', max_sessions: 4 }])[0].cap, null);
assert.equal(rows([{ ...live, max_sessions: 4 }, { ...live, endpoint_id: 'bounded', max_sessions: 6 }])[0].cap, 10);
assert.equal(rows([old])[0].cap, null);
assert.equal(rows([{ ...live, max_sessions: 4 }, { ...client, status: 'online', max_sessions: 30 },
  { ...live, endpoint_id: 'machine-agent', machine_link: true }])[0].cap, 4);
console.log('machine capacity excludes lost endpoints and preserves dynamic admission PASS');

const stable = 'dfc510e34b9800268b8de3eb0603665f198529f6';
const compute = { ...live, os_user: 'fleetverky', fleet_version: 'ccb0d24' };
const machine = { hostname: host, role: 'host', status: 'online', fleet_version: '0b591685',
  installs: { logins: [{ login: 'fleetverky', install: { version: stable } }] } };
const versionRow = (m, ns) => machineRows({ machines: [m], nodes: ns }, { stable })[0];
const personal = { ...client, status: 'online', fleet_version: '0b591685' };
assert.equal(versionRow(machine, [personal, compute]).version, 'dfc510e');
assert.equal(versionRow(machine, [personal, compute]).behind, false);
assert.equal(versionRow(machine, [personal, { ...compute, desired: { want: 1, reached: 0 } }]).behind, false);
assert.equal(versionRow({ ...machine, installs: undefined }, [personal, compute]).version, 'ccb0d24');
assert.equal(versionRow(machine, [personal]).version, '');
assert.equal(versionRow(machine, [personal, { ...compute, status: 'lost' }]).version, '');
const other = { ...live, os_user: 'second', fleet_version: 'aaaaaaa' };
assert.equal(versionRow(machine, [compute, other]).version, 'dfc510e / aaaaaaa');
assert.equal(versionRow(machine, [compute, other]).behind, true);
assert.equal(versionRow({ ...machine, versions: { runtime: stable } }, [personal, compute]).version, 'dfc510e');
assert.equal(versionRow({ ...machine, installs: { runtime: { version: stable } } }, [compute]).version, 'dfc510e');
assert.equal(versionRow({ ...machine, installs: undefined }, [{ ...compute,
  installs: { logins: [{ login: 'fleetverky', install: { version: stable } }] } }]).behind, false);
console.log('machine runtime uses installed releases and excludes client Git heads PASS');

const { machineSessionGroups } = await import('data:text/javascript;base64,' + Buffer.from(code).toString('base64'));
const session = (availability) => ({ availability, worker: { state: 'done' } });
const detail = { machine: { sessions: 1 }, sessions: [session('online')], pending_sessions: [session('lost')], historical_sessions: [session('historical')] };
assert.deepEqual(Object.fromEntries(Object.entries(machineSessionGroups(detail)).map(([k,v]) => [k,Array.isArray(v) ? v.length : v])),
  { current: 1, pending: 1, history: 1, count: 1, partial: false });
assert.equal(machineSessionGroups({ ...detail, machine: { sessions: null } }).count, null);
const oldHub = machineSessionGroups({ machine: { sessions: 1 }, sessions: [session('online'), session('lost')] });
assert.equal(oldHub.current.length, 1);
assert.equal(oldHub.pending.length, 1);
assert.equal(oldHub.partial, false);
assert.equal(machineSessionGroups({ machine: { sessions: 2 }, sessions: [session('online')] }).partial, true);
console.log('machine session counts keep pending and historical snapshots separate PASS');
