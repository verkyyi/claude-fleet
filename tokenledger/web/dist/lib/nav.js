// web/dist/lib/nav.js — the section nav's table, and the scroll-spy's one
// decision. No DOM: web/dist/scope.js does the measuring and the rendering,
// this file holds the parts worth testing without a browser.
//
// #54 added a nav to a page that deliberately had none, and said of it: "This
// moves the viewport. It issues no request, mounts nothing, hides nothing, and
// owns no state." Half of that is now overturned, on purpose (#97, EPIC #91):
// the nav OWNS STATE -- each entry names a `view`, and pressing it writes that
// view into the hash. #98 is what will make it hide things too.
//
// What is NOT overturned is the reason the Now/Review tabs were retired: they
// split the page into regions that fetched and refreshed on their own rhythms.
// A view here is a slice of ONE scope and ONE set of answers -- `view` is in
// state.js's PRESENTATION_KEYS, so switching one sends no request at all. That
// is the whole difference between this and the tabs, and it is why this is not
// the old mistake wearing a new name.

/** SECTIONS is the nav, in page order, and it is also the page's own band list.
 *
 *  `target` is the element id the entry scrolls to and spies on. Those are the
 *  BAND labels, not the sections under them, so a reader who jumps lands on the
 *  label that says which question the cards below answer — arriving at the
 *  first card with the band scrolled off the top is arriving without it.
 *
 *  `key` is the i18n key the entry PRINTS, and it is the same key the band
 *  itself prints. Deliberately shared, not duplicated: a nav that says
 *  "Progress" over a band that says something else is worse than no nav, and
 *  one key cannot disagree with itself.
 *
 *  `view` is the value the entry WRITES into the hash (`#/?view=usage`), and
 *  this table is the only place the set of views is spelled: state.js derives
 *  its VIEWS from exactly this column, so a view that no entry can reach does
 *  not exist and an entry that reaches nothing cannot be written. It is a
 *  short, URL-shaped word rather than the `target` id, because it is what a
 *  reader sees in a link they paste to a colleague -- `view=progress` says
 *  what they are being sent to; `view=repo-band` names an element.
 *
 *  Operations is the exception on both counts and it is not an inconsistency:
 *  its band label IS its <summary>, so `#ops` is both the target and the
 *  labelled band. */
export const SECTIONS = [
  { target: 'ledger-band', key: 'band.ledger', view: 'ledger' },
  { target: 'usage-band', key: 'band.usage', view: 'usage' },
  { target: 'repo-band', key: 'band.progress', view: 'progress' },
  { target: 'ops', key: 'ops.title', view: 'ops' },
];

/** pickActive is the whole scroll-spy decision, as a pure function of numbers.
 *
 *  `tops` are the viewport-relative tops (getBoundingClientRect().top) of the
 *  VISIBLE entries, in page order; `navH` is how much of the viewport the
 *  sticky bar covers. The active entry is the LAST one whose top has passed
 *  under the bar — "which band am I reading under", which is the question a
 *  reader of a 4,459px page is actually asking. Returns an index into `tops`,
 *  or -1 when there is nothing to highlight.
 *
 *  `atBottom` overrides it, and has to. The last band on this page is the
 *  operations fold, and folded shut it is one <summary> line: scrolled all the
 *  way down, its top never passes under the bar, so without this the nav would
 *  highlight Progress while the reader looks at Operations. Same for any final
 *  band shorter than the viewport.
 *
 *  TOLERANCE is what keeps a jump from marking the band ABOVE the one it just
 *  jumped to. Both sides of this comparison are fractional measured layout —
 *  the bar's height and the target's top — and a click lands the target on the
 *  line to within a pixel or two, in either direction, depending on device
 *  pixel ratio and zoom. Observed: a click on Operations settled it at
 *  navH + 1.8 and a strict line left Usage marked, on a page where the reader
 *  was plainly looking at Operations. Bands here are hundreds of pixels apart,
 *  so a few pixels of grace cannot reach the wrong one. */
const TOLERANCE = 4;

export function pickActive(tops, navH, atBottom = false) {
  if (!tops.length) return -1;
  if (atBottom) return tops.length - 1;
  let active = 0;
  for (let i = 0; i < tops.length; i++) {
    if (tops[i] - navH <= TOLERANCE) active = i;
    else break;
  }
  return active;
}
