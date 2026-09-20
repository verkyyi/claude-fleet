import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

// ---------------------------------------------------------------------------
// The share page's copy (issue #55 fixed the dashboard; #73 the other half).
//
// web/dist/share.html is served at /share behind the share-token gate, while
// /lib/ is behind the viewer gate — a share recipient importing
// ./lib/palette.js is answered 401 — so the page carries its own copy of the
// palette rather than importing this one. A copy is only as good as the day
// it was taken, and the failure it would reintroduce is quiet: the share page
// keeps colouring by name, just by a DIFFERENT name-to-hue map, so a reader
// comparing the dashboard with the page they shared still sees Opus change
// colour. Nothing on screen says which copy moved.
//
// So this runs the real inline implementation — lifted out of share.html
// between its `>>> palette` / `<<< palette` markers, never a transcription of
// it — against this module over inputs that matter, and fails the moment one
// side moves. Evaluating the extracted block needs no DOM: it is pure string
// arithmetic, which is exactly why it can be extracted at all.
function sharePalette() {
  const html = readFileSync(new URL('../dist/share.html', import.meta.url), 'utf8');
  const block = html.match(/\/\/ >>> palette[^\n]*\n([\s\S]*?)\n\/\/ <<< palette/);
  assert.ok(block, 'share.html has lost its `>>> palette` / `<<< palette` markers');
  return new Function(`${block[1]}\nreturn { seriesPalette, OTHER_COLOR, SERIES };`)();
}

test('share.html colours a name exactly as lib/palette.js does', () => {
  const share = sharePalette();
  assert.equal(share.OTHER_COLOR, OTHER_COLOR, 'the folded "other" colour has drifted');
  assert.equal(share.SERIES.length, SERIES_SLOTS, 'the two palettes have different slot counts');

  // Names the share page really sees (model_split is ByModel, ranked by
  // tokens), plus a set larger than the palette so the overflow rule is
  // compared too — the old `% SERIES.length` gave the ninth model the first
  // one's hue instead of folding it into grey.
  const models = [OPUS, SONNET, HAIKU, 'gpt-5', 'gemini-2.5-pro', 'grok-4',
    'claude-opus-4-5', 'claude-sonnet-4', 'claude-haiku-3-5', 'o3'];
  for (let n = 0; n <= models.length; n++) {
    const names = models.slice(0, n);
    assert.deepEqual(share.seriesPalette(names), seriesPalette(names),
      `share.html and lib/palette.js disagree on ${n} models`);
    const reversed = [...names].reverse();
    assert.deepEqual(share.seriesPalette(reversed), seriesPalette(reversed),
      `share.html and lib/palette.js disagree once the ranking flips (${n} models)`);
  }
});
