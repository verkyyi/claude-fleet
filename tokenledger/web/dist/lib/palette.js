// web/dist/lib/palette.js — which colour a named series gets, and why it is
// the same colour tomorrow.
//
// Issue #55: every multi-series chart on this page used to take its hue from
// the series' ARRAY INDEX, and every one of those arrays is ordered by
// something that moves:
//
//   - `stack_models` is ranked by tokens in the CURRENT window
//     (internal/api/query.go) — widen the span by a day, add a chip, or let
//     usage drift, and the top-6 reorders;
//   - `lines` followed the `accounts` array;
//   - `turnBars` followed first-appearance order inside a session, which
//     "load more" changes.
//
// So the same model changed colour between two views of the same data. A
// reader who has learned "orange is Opus" has to learn it again on every
// refresh, and the legend stops being a memory aid and becomes a lookup.
//
// The fix is to derive the slot from the NAME rather than the position.
// `seriesPalette` hashes each name to a home slot, so a name's colour does
// not depend on where it sits in the array — a reorder changes nothing at
// all. Two names can still hash to the same slot (six names into eight slots
// collide better than nine times in ten, so ignoring it was never an
// option), and that is resolved by probing to the next free slot. Probing is
// done in NAME order, never the caller's order, because the caller's order
// is precisely the thing that moves: probe in rank order and a reorder could
// shuffle a colliding pair again.
//
// What this buys, honestly stated: colour is stable across reorders, always.
// It is stable across MEMBERSHIP changes too, except for names that collide
// — if a colliding neighbour leaves the top-6, the name that had been pushed
// off its home slot moves back to it. That is a much smaller surface than
// "any reorder repaints everything", and it is the price of keeping the
// eight curated, theme-aware palette hues instead of generating arbitrary
// ones.

/** The palette, in `styles.css`'s own variables — eight hues defined for
 *  both themes. `--ink-3` (OTHER_COLOR) is deliberately not one of them: it
 *  is the recessive grey reserved for the folded "other" band, so "other"
 *  reads as a leftover rather than as a ninth series. */
const SERIES = ['--s1', '--s2', '--s3', '--s4', '--s5', '--s6', '--s7', '--s8'];

export const OTHER_COLOR = 'var(--ink-3)';
export const SERIES_SLOTS = SERIES.length;

/** slotColor is for a FIXED enumeration whose order is part of the design
 *  and never comes from the data — `composition()`'s five token kinds, which
 *  are drawn in the same order every time. Anything whose order is DERIVED
 *  from the data wants `seriesPalette` instead.
 *
 *  Past the end of the palette it folds into "other". The old `seriesColor`
 *  claimed exactly this in its comment and actually did `Math.min(i, 7)` —
 *  a clamp, which quietly gives a ninth series the eighth one's hue and
 *  implies a relationship that is not there. Nothing reaches nine today
 *  (the server caps the stack at 6 + other), so this is the documented
 *  behaviour finally being the real one. */
export const slotColor = (i) =>
  (Number.isInteger(i) && i >= 0 && i < SERIES.length ? `var(${SERIES[i]})` : OTHER_COLOR);

/** fnv1a — a 32-bit string hash, chosen for being short, dependency-free and
 *  identical in every JS engine. Nothing cryptographic is wanted here: the
 *  only property that matters is that the same name always lands on the same
 *  number. `Math.imul` keeps the multiply in 32-bit space, which plain `*`
 *  would not. */
export function fnv1a(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** seriesPalette maps `names` to CSS colours, ALIGNED TO THE INPUT — index
 *  `i` of the result is the colour for `names[i]` — so a caller keeps
 *  drawing in whatever order it likes while the colours follow the names.
 *
 *  More names than palette slots: the overflow gets OTHER_COLOR, matching
 *  how both stacked charts already draw the band they folded. */
export function seriesPalette(names) {
  const list = (names || []).map((n) => String(n));
  const out = new Array(list.length).fill(OTHER_COLOR);
  const taken = new Array(SERIES.length).fill(false);

  const byName = list
    .map((name, i) => ({ name, i }))
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.i - b.i));

  for (const { name, i } of byName) {
    const home = fnv1a(name) % SERIES.length;
    let slot = home;
    while (taken[slot]) {
      slot = (slot + 1) % SERIES.length;
      if (slot === home) { slot = -1; break; }   // every slot taken: fold into "other"
    }
    if (slot < 0) continue;
    taken[slot] = true;
    out[i] = `var(${SERIES[slot]})`;
  }
  return out;
}
