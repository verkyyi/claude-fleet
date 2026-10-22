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
