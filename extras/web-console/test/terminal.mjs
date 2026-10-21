import assert from 'node:assert/strict';
import { touchWheel } from '../src/shared/touch-wheel.ts';
import { webGoTarget } from '../src/shared/web-go.ts';

// C8X3: a finger moving down 3 cells scrolls back 3 wheel steps (wheel up, < 0)
assert.deepEqual(touchWheel(0, 60, 20), { steps: -3, carry: 0 });
// moving up scrolls forward; a partial cell is carried, never lost or doubled
assert.deepEqual(touchWheel(0, -50, 20), { steps: 2, carry: -10 });
assert.deepEqual(touchWheel(-10, -10, 20), { steps: 1, carry: 0 });
assert.deepEqual(touchWheel(0, 5, 20), { steps: 0, carry: 5 });
// a tiny or unmeasured cell never turns one drag into a flood of reports
assert.equal(touchWheel(0, 80, 0).steps, -10);
console.log('terminal: ok');
const wid = '33333333-3333-4333-8333-333333333333/44444444-4444-4444-8444-444444444444';
assert.equal(webGoTarget('web-go;w=' + wid), wid);
assert.equal(webGoTarget('cur;token=x;m=-;l=-;w=' + wid), null); // the thin loop's word, not ours
assert.equal(webGoTarget('web-go;w=../../etc'), null);
assert.equal(webGoTarget('web-go;w=' + wid + ';x=1'), null);
console.log('web-go: ok');
