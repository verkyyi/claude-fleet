import test from 'node:test';
import assert from 'node:assert/strict';
import { scaleMax, shareText, fmtSigned, delta } from '../dist/lib/format.js';

// The defect this file exists for (issue #51): two bar lists of the same
// quantity, drawn side by side, each normalized to its own tallest row. A
// full-width bar on the left and a full-width bar on the right were different
// numbers — and nothing on the page said so. `scaleMax` is the one
// denominator both lists must be drawn at, and these tests pin the property
// that makes the comparison honest: equal length ⇔ equal number.
test('one scale over two lists makes equal bars equal numbers', () => {
  const left = [{ value: 900 }, { value: 300 }];
  const right = [{ value: 450 }, { value: 300 }];
  const max = scaleMax([...left, ...right]);
  assert.equal(max, 900);
  const width = (v) => (v / max) * 100;
  // The two 300s are the whole point: same number, same width, across cards.
  assert.equal(width(left[1].value), width(right[1].value));
  // ...and the right card's biggest row is honestly half the left card's,
  // instead of being stretched to full width by its own local max.
  assert.equal(width(right[0].value), 50);
});

// A previous-period marker sits on the same track as the fill, so the scale
// has to be big enough to hold it. A row that collapsed (prev far above every
// current value) would otherwise put its marker past the end of the track.
test('the scale covers previous-period markers too', () => {
  assert.equal(scaleMax([{ value: 10, prev: 4000 }, { value: 100 }]), 4000);
  // Missing / malformed figures are zero, not NaN — one bad row must not take
  // the scale (and therefore every bar drawn at it) out with it.
  assert.equal(scaleMax([{ value: undefined }, { value: 50 }, { prev: null }]), 50);
  assert.equal(scaleMax([{ value: 'x' }, { value: 7 }]), 7);
});

// Floor of 1: an all-zero list still has to divide by something.
test('an empty or all-zero list still has a usable denominator', () => {
  assert.equal(scaleMax([]), 1);
  assert.equal(scaleMax(), 1);
  assert.equal(scaleMax([{ value: 0 }, { value: 0, prev: 0 }]), 1);
});

test('a share is a percentage of the denominator it was given', () => {
  assert.equal(shareText(250, 1000), '25.0%');
  assert.equal(shareText(1000, 1000), '100.0%');
  // A row too small to round to 0.1% is present, not absent: "<0.1%" says
  // there IS something here, where "0.0%" claims it measured to nothing.
  assert.equal(shareText(1, 1e6), '<0.1%');
  assert.equal(shareText(0, 1000), '0.0%');
});

// null, not '—'. The dash on this page already means "no cost", "unknown" and
// "notional"; a fourth meaning would finish emptying it out. Callers render
// null as absence.
test('no denominator means no share, and says so as null', () => {
  assert.equal(shareText(5, 0), null);
  assert.equal(shareText(5, undefined), null);
  assert.equal(shareText(5, -3), null);
});

// delta used to return a percentage and nothing else, so a row could say
// "+18%" and never say of what. The absolute difference is now always there,
// including when there is no previous figure to take a ratio against.
test('delta reports the absolute difference, not only the ratio', () => {
  const grew = delta(1200, 1000);
  assert.equal(grew.abs, 200);
  assert.equal(grew.text, '+20%');
  const shrank = delta(800, 1000);
  assert.equal(shrank.abs, -200);
  // No previous data: the ratio is undefined, the subtraction is not.
  const fresh = delta(500, 0);
  assert.equal(fresh.pct, null);
  assert.equal(fresh.abs, 500);
  assert.equal(fresh.text, '—');
});

test('an absolute difference keeps its sign, and zero says zero', () => {
  assert.equal(fmtSigned(1500), '+' + (1500).toLocaleString());
  assert.equal(fmtSigned(-1500), '−' + (1500).toLocaleString());
  // Not "0": a row that did not move should read as measured, not missing.
  assert.equal(fmtSigned(0), '±0');
});
