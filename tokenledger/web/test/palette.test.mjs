import test from 'node:test';
import assert from 'node:assert/strict';
import { seriesPalette, slotColor, SERIES_SLOTS, OTHER_COLOR } from '../dist/lib/palette.js';

// The defect this file exists for (issue #55): chart colour came from the
// series' ARRAY INDEX, and every one of those arrays is ordered by something
// that moves — `stack_models` by tokens in the current window, `lines` by the
// accounts array, `turnBars` by first appearance in a session. Change the
// span, add a chip, or let usage drift a little, and the same model came back
// a different colour. These tests pin the property that makes the legend
// worth learning: the same NAME is the same colour, whatever position it
// arrives in.

const OPUS = 'claude-opus-4-1', SONNET = 'claude-sonnet-4-5', HAIKU = 'claude-haiku-4-5';

test('a reorder does not change any colour', () => {
  const names = [OPUS, SONNET, HAIKU, 'gpt-5', 'gemini-2.5-pro', 'grok-4'];
  const asRanked = seriesPalette(names);
  const byName = new Map(names.map((n, i) => [n, asRanked[i]]));

  // Same set, every rotation of it: the ranking the API returns is exactly
  // this unstable.
  for (let r = 1; r < names.length; r++) {
    const rotated = [...names.slice(r), ...names.slice(0, r)];
    const colors = seriesPalette(rotated);
    rotated.forEach((n, i) => assert.equal(colors[i], byName.get(n),
      `${n} changed colour after rotating the input by ${r}`));
  }

  // And reversed, which is what a "least tokens first" sort would hand us.
  const reversed = [...names].reverse();
  seriesPalette(reversed).forEach((c, i) => assert.equal(c, byName.get(reversed[i])));
});

test('six models get six different colours', () => {
  // The whole reason the slot is probed rather than taken straight from the
  // hash: six names into eight slots collide far more often than not, and two
  // bands of one colour in a stack are unreadable.
  const names = [OPUS, SONNET, HAIKU, 'gpt-5', 'gemini-2.5-pro', 'grok-4'];
  const colors = seriesPalette(names);
  assert.equal(new Set(colors).size, names.length);
  assert.ok(!colors.includes(OTHER_COLOR), 'no name within the palette size folds into other');
});

test('a full palette stays distinct, and the overflow folds into other', () => {
  const full = Array.from({ length: SERIES_SLOTS }, (_, i) => `model-${i}`);
  const colors = seriesPalette(full);
  assert.equal(new Set(colors).size, SERIES_SLOTS);

  const over = [...full, 'model-extra', 'model-extra-2'];
  const overColors = seriesPalette(over);
  // The two that did not fit are grey, not a second helping of an existing
  // hue — the behaviour the old comment claimed and the old clamp did not do.
  assert.equal(overColors.filter((c) => c === OTHER_COLOR).length, 2);
  assert.equal(new Set(overColors).size, SERIES_SLOTS + 1);
});

test('the result is aligned to the input, and an empty input is empty', () => {
  assert.deepEqual(seriesPalette([]), []);
  assert.deepEqual(seriesPalette(undefined), []);
  const colors = seriesPalette([OPUS, SONNET]);
  assert.equal(colors.length, 2);
  assert.notEqual(colors[0], colors[1]);
});

test('names that are not strings still get a stable colour', () => {
  // `lines` passes account labels and `turnBars` passes model ids; neither is
  // guaranteed to be a string by the API contract, and a chart must not lose
  // its colours over it.
  assert.deepEqual(seriesPalette([1, 2]), seriesPalette(['1', '2']));
});

test('slotColor is the fixed-enumeration accessor and folds past the palette', () => {
  // composition()'s token kinds are drawn in a designed order, so THEY are
  // allowed to be positional. Everything past the palette is grey.
  assert.notEqual(slotColor(0), slotColor(1));
  assert.equal(new Set(Array.from({ length: SERIES_SLOTS }, (_, i) => slotColor(i))).size, SERIES_SLOTS);
  assert.equal(slotColor(SERIES_SLOTS), OTHER_COLOR);
  assert.equal(slotColor(-1), OTHER_COLOR);
});
