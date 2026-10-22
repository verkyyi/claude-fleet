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
