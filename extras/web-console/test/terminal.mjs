import assert from 'node:assert/strict';
import { touchWheel } from '../src/shared/touch-wheel.ts';

// C8X3: a finger moving down 3 cells scrolls back 3 wheel steps (wheel up, < 0)
assert.deepEqual(touchWheel(0, 60, 20), { steps: -3, carry: 0 });
// moving up scrolls forward; a partial cell is carried, never lost or doubled
assert.deepEqual(touchWheel(0, -50, 20), { steps: 2, carry: -10 });
assert.deepEqual(touchWheel(-10, -10, 20), { steps: 1, carry: 0 });
assert.deepEqual(touchWheel(0, 5, 20), { steps: 0, carry: 5 });
// a tiny or unmeasured cell never turns one drag into a flood of reports
assert.equal(touchWheel(0, 80, 0).steps, -10);
console.log('terminal: ok');
