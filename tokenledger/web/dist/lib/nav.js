// web/dist/lib/nav.js — the view vocabulary: which bands this page has, and
// which of them a given view mounts. No DOM: web/dist/scope.js renders the bar
// and web/dist/app.js does the mounting, this file holds the parts worth
// testing without a browser.
//
// This is the FOURTH position this page has taken on the same question, and
// the first three are overturned here rather than quietly deleted:
//
//   1. One surface, no navigation. The bar held nothing because there was
//      nothing to navigate BETWEEN -- the Now/Review tabs had just been retired
//      for splitting one question into two halves a reader had to choose
//      between.
//   2. An ANCHOR nav (#54). Four buttons, a scroll-spy, still one surface:
//      "This moves the viewport. It issues no request, mounts nothing, hides
//      nothing, and owns no state." Then #97 gave each entry a `view` to write
//      into the hash, which overturned the last clause.
//   3. Mounting views (#98): a view MOUNTS its band and unmounts the others,
//      and the loaders are gated on what is mounted, so a view sends only the
//      requests its own cards read. The scroll-spy is gone with the scrolling:
//      the current view IS the current highlight, and there is no longer a
//      position on a 4,459px page to measure.
//   4. This one (#130): the DEFAULT stops being the whole page. #98 built the
//      machinery to show less and then pointed it at `all`, so the one view
//      nobody chooses -- the one every bare URL lands on -- was still the only
//      view that had never been asked to justify itself. It is now a set of its
//      own, VIEW_DEFAULT below, and `all` keeps meaning all while becoming a
//      place you GO rather than the place you start. What that costs a shared
//      link, and why it is paid rather than argued away, is written on VIEW_ALL.
//
// What is NOT overturned -- and this is the part that has survived all three --
// is the reason the Now/Review tabs were retired. They split the page into
// regions that FETCHED AND REFRESHED ON THEIR OWN RHYTHMS, so "what is burning
// right now" and "what did this period cost" drifted apart and a reader who
// picked one was told to choose between halves of an answer. A view here is a
// slice of ONE scope, ONE hash and ONE refresh loop: `view` is in state.js's
// PRESENTATION_KEYS, so switching one re-draws from rows already in hand and
// costs zero requests (seq.js's replay()), and every band that IS mounted is
// asking about the same account, the same window and the same chips. Isolation
// here is about which questions get ASKED, never about letting two of them
// answer as of different moments.

/** VIEW_ALL is the page with every band mounted. Since #130 that is ALL it is:
 *  it is no longer the default, and the sentence this comment used to open with
 *  is the one that was overturned --
 *
 *    "...and it is the default: it is what this page has always been, and it is
 *     what every link ever shared -- none of which carries a `view` -- must keep
 *     landing on."
 *
 *  That claim was true and the cost of dropping it is real: no link ever shared
 *  carries a `view`, so every one of them now opens on VIEW_DEFAULT's two bands
 *  rather than the five its sender saw. It is PAID rather than argued away, on
 *  three grounds. Nothing is lost that a reader cannot get back in one press --
 *  the other bands are unmounted, not deleted, and "All" is in the bar on every
 *  view. Nothing the link actually SPELLED is touched -- the subscription, span,
 *  chips and session it carries are orthogonal to `view` (state.js's setState
 *  moves one key), so the page it opens is still scoped exactly as its sender
 *  scoped it. And the alternative was to keep the price of the whole page on
 *  every first screen forever, including for the reader who opened it only to
 *  find out whether they were about to be blocked.
 *
 *  It lives here rather than in state.js because it is part of the same
 *  vocabulary SECTIONS spells: the set of views is "no band filter, the default
 *  set, or exactly one band". state.js re-exports it, and derives VIEWS from
 *  them together.
 */
export const VIEW_ALL = 'all';

/** VIEW_QUOTA is the quota band's own view, named here because one caller
 *  outside this file has to ASK for it rather than merely list it.
 *
 *  scope.js narrows the subscription picker to the accounts that can have a
 *  quota reading, and only on this view (#126) -- so it needs the word, and
 *  taking it from `SECTIONS[0].view` would key that behaviour on the band's
 *  POSITION, which #95 has already moved once. A named constant survives the
 *  next reorder; an index does not. */
export const VIEW_QUOTA = 'quota';

/** VIEW_DEFAULT is the view a bare URL lands on, and DEFAULT_BANDS is what it
 *  mounts: the quota band and the ledger band.
 *
 *  A view of its OWN, not a redefinition of `all` (#130). `all` has to go on
 *  meaning every band -- it is the bar's way back to the whole page and it is
 *  what nav.test.mjs pins -- so the moment "the default" and "everything"
 *  stopped being the same SET they had to stop being the same WORD. Two words,
 *  one each, and neither has to carry the other's meaning.
 *
 *  It is a word almost no reader will ever see. state.js omits `view` at the
 *  default, so this view's URL is `#/`, and pressing its entry in the bar writes
 *  nothing into the hash. It is spelled out anyway instead of being a nameless
 *  special case inside bandsFor, because two things need a value and not a
 *  condition: VIEWS has to ACCEPT it, so `?view=overview` typed by hand routes
 *  instead of falling back, and the bar has to have something to mark its own
 *  entry with (scope.js's syncNav marks by view, and "exactly one current entry"
 *  is a property it states outright).
 *
 *  Why these two bands, and not three or one (EPIC #122, 拍板 6): they are the
 *  only two that answer in the reader's own tense. Quota is "can I still work",
 *  the one question on this page with a deadline (#95 moved it to the front for
 *  that reason). The ledger is "what did it cost". Usage, progress and
 *  operations all answer "why" -- they explain the two figures above them, and
 *  an explanation nobody asked for is most of what the default page used to be.
 *
 *  No order is carried here. bandsFor filters BANDS rather than returning this
 *  list, so page order is the PAGE's whatever order this happens to be written
 *  in -- the same reason index.html, not the caller, decides where a band sits. */
export const VIEW_DEFAULT = 'overview';
export const DEFAULT_BANDS = Object.freeze([VIEW_QUOTA, 'ledger']);

/** SECTIONS is the page's band list, in page order, and it is also what the bar
 *  prints (after the "All" entry scope.js puts in front of it).
 *
 *  `key` is the i18n key the entry PRINTS, and it is the same key the band
 *  itself prints in index.html. Deliberately shared, not duplicated: a nav that
 *  says "Progress" over a band that says something else is worse than no nav,
 *  and one key cannot disagree with itself.
 *
 *  `view` is the value the entry WRITES into the hash (`#/?view=usage`) and, as
 *  of #98, also the value index.html tags that band's nodes with
 *  (`data-band="usage"`) -- so this column is the single name for "that band",
 *  shared by the URL, the markup and the fetch plan. state.js derives its VIEWS
 *  from it, so a view that no entry can reach does not exist and an entry that
 *  reaches nothing cannot be written. It is a short, URL-shaped word rather
 *  than an element id, because it is what a reader sees in a link they paste to
 *  a colleague -- `view=progress` says what they are being sent to;
 *  `view=repo-band` names a div.
 *
 *  The order is the PAGE order, and quota leads it as of #95. That overturns a
 *  positioning #98 had just argued for — "on `view=all` it is still the same
 *  continuous page, just folded, so the page opens as a ledger" — so it is
 *  written down rather than quietly done. What #98 was defending is that the
 *  operations tier, nine cards of gauges and machines and sessions, should not
 *  be the first thing a reader meets; that still holds and the fold is still
 *  shut. What it did not separate out is that ONE card in that tier is not
 *  operational trivia: every other band on this page answers in the past tense
 *  — what was paid, what drove it, what it bought — and this one answers "how
 *  much runway is left before work stops", which is the only question here with
 *  a deadline. A reader who opens the page to find out whether they are about to
 *  be blocked was, until #95, the one reader the page could not serve without a
 *  click into a shut <details>. The ledger is one band lower and one label
 *  clearer, which is a smaller cost than that.
 *
 *  There used to be a third column, `target`: the id of the band-label element
 *  the entry SCROLLED TO. #98 removed it with the scrolling. A nav entry no
 *  longer points at an element on a page that is already showing it -- it
 *  decides which elements are on the page at all, and `data-band` in the shell
 *  is where that mapping is now written, because a band is several sibling
 *  nodes (its label and its sections) and never one. */
export const SECTIONS = [
  { key: 'band.quota', view: VIEW_QUOTA },
  { key: 'band.ledger', view: 'ledger' },
  { key: 'band.usage', view: 'usage' },
  { key: 'band.progress', view: 'progress' },
  { key: 'ops.title', view: 'ops' },
];

/** BANDS is just the view column, named: the set of things a page node can be
 *  tagged `data-band=` with, and the set app.js mounts from. */
export const BANDS = SECTIONS.map((s) => s.view);

/** bandsFor is the whole routing decision, as a pure function of one word:
 *  which bands does this view put on the page?
 *
 *  `all` is every band; the default view is DEFAULT_BANDS; any other view is
 *  exactly itself. That is the entire rule, and writing it out as a function
 *  rather than inlining `view === 'all' || view === band` at each of its callers
 *  is what keeps app.js's mounting and review.js's fetch plan from drifting
 *  apart -- a band that mounts but whose requests were not planned for draws
 *  cards reporting no readings, and one whose requests go out while it is
 *  unmounted is the waste #98 exists to stop.
 *
 *  Three cases since #130, and all three are expressed as a FILTER OF BANDS
 *  rather than as a list each branch builds for itself. That is what keeps "in
 *  page order" structural instead of a promise three branches have to keep
 *  separately: a band cannot come back in the order its view happened to name
 *  it, whatever a later edit writes into DEFAULT_BANDS.
 *
 *  An unknown view cannot reach here (state.js's parse() falls back to the
 *  default), but if one did it would mount nothing, which is the visible
 *  failure rather than the silent one. */
export function bandsFor(view) {
  const want = view === VIEW_ALL ? BANDS : view === VIEW_DEFAULT ? DEFAULT_BANDS : [view];
  return BANDS.filter((b) => want.includes(b));
}
