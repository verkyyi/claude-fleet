// net.mjs — the weak-network band's state (GR5E C8, src/shared/net.ts): two
// fetches in a row with no answer is「网络不太好」, one answer is back (one
// fleet:net-back, every reader re-reads), an HTTP error is an answer; the band
// says how old the screen is in whole minutes; every read reports there.
// Run: node --experimental-strip-types test/net.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

let backs = 0;
globalThis.window = new EventTarget();
window.addEventListener('fleet:net-back', () => backs++);
const { minutesAgo, netMiss, netOk, netReset, netState, netSubscribe } = await import('../src/shared/net.ts');

netReset(1000);
netMiss();
assert.equal(netState().bad, false, 'one miss is not yet weak');
netOk(2000);
netMiss();
assert.equal(netState().bad, false, 'an answer between resets the count');
netMiss();
assert.equal(netState().bad, true, 'two misses in a row: weak');
assert.equal(netState().lastOk, 2000, 'the screen is as old as the last answer');
const seen = [];
const off = netSubscribe((n) => seen.push(n.bad));
netOk(5000);
assert.deepEqual(seen, [false]);
assert.equal(backs, 1, 'back: one fleet:net-back');
netOk(6000);
assert.equal(backs, 1, 'already good: no second');
off();
window.dispatchEvent(new Event('offline'));
assert.equal(netState().bad, true, 'the browser saying offline is weak at once');
netOk(7000);
assert.equal(backs, 2);

assert.equal(minutesAgo(0, 59_000), 0);
assert.equal(minutesAgo(0, 3 * 60_000 + 5), 3);
assert.equal(minutesAgo(10, 0), 0, 'never negative');

const api = readFileSync(new URL('../src/shared/api.ts', import.meta.url), 'utf8');
assert.equal((api.match(/if \(r\) netOk\(\); else netMiss\(\);/g) || []).length, 3, 'getJSON, getJSONIf (T47B) and sendJSON all report');
const bar = readFileSync(new URL('../src/app/NetBar.tsx', import.meta.url), 'utf8');
assert.match(bar, /网络不太好，正在重连… 下面是 \$\{n\} 分钟前的样子/, 'the band says the design page\'s words');
const rows = readFileSync(new URL('../src/app/work-rows.tsx', import.meta.url), 'utf8');
assert.match(rows, /visibilitychange/, 'back from the background, the list is read again');
assert.match(rows, /NET_BACK/, 'the network back, the list is read again');
console.log('net: ok');
