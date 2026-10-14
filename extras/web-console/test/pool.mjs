import assert from 'node:assert/strict';
import { subscriptions, withOverview } from '../src/admin/pool.ts';
// Execute the production TypeScript join directly (Node strips types).
const id = n => 'cred:' + String(n).repeat(64);
const lim = pct => ({ available: true, five_hour: { utilization: pct, resets_at:'2027-01-01T00:00:00Z' }, seven_day: { utilization: 1 }, observed_at:'2026-10-14T00:00:00Z', read_status:'ok' });
const a = {principal_id:'pool',provider:'claude',account:'collision',credential_id:id(1),limits:lim(8)};
const b = {principal_id:'pool',provider:'claude',account:'second',credential_id:id(2),limits:lim(99)};
const own = {...a,principal_id:'alice',credential_id:id(3),limits:lim(17)};
const alias = {...a,account:'alias'};
const input = {creds:{credentials:[a,b,alias,own]}, limits:{per_account:[{account_uuid:'old',label:'collision',limits:lim(90)}]},accounts:[{account_uuid:'old',email:'collision@example.com'}]};
let rows = subscriptions(input);
assert.equal(rows.filter(r=>r.managed).length,3);
assert.equal(rows.find(r=>r.id===id(1)).h5.p,8);
assert.equal(rows.find(r=>r.id===id(1)).h7.p,1); // API is percent: 1% must never render as 100%.
assert.equal(rows.find(r=>r.id===id(2)).h5.p,99);
assert.equal(rows.find(r=>r.id===id(3)).h5.p,17);
assert.equal(rows.find(r=>r.id==='old'),undefined);
// A stale overview response to the same label cannot undo a replacement.
const replacement = {...a,credential_id:id(4),limits:{available:false,read_status:'unknown'}};
rows = subscriptions({creds:{credentials:[replacement]}});
rows = withOverview(rows,[{owner:'pool',provider:'claude',account:'collision',credential_id:id(1),used_5h_pct:100,state:'limited'}]);
assert.equal(rows[0].h5,null); assert.equal(rows[0].limited,false);
// The displayed label belongs to the imported credential, even with a real UUID.
rows = subscriptions({creds:{credentials:[{...a,account_uuid:'old'}]},limits:input.limits});
assert.equal(rows.length,1); assert.equal(rows[0].label,'collision'); assert.equal(rows[0].h5.p,8);
// No singleton/domain/label guess for an older response either.
rows = subscriptions({creds:{credentials:[{principal_id:'pool',provider:'claude',account:'example'}]},limits:input.limits,accounts:input.accounts});
assert.equal(rows.length,1); assert.equal(rows[0].h5,null);
// A failed attempt keeps that credential's timestamp and last good reading.
rows = subscriptions({creds:{credentials:[{...a,limits:{...lim(8),read_status:'failed',read_note:'HTTP 503'}}]}});
assert.equal(rows[0].readNote,'HTTP 503'); assert.equal(rows[0].readAt,'2026-10-14T00:00:00Z');
console.log('PASS: production subscriptions join isolates credentials, aliases, replacements and owners');
