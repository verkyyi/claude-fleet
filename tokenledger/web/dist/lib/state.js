// web/dist/lib/state.js — URL ⇄ state. No DOM. The hash is the only copy of the state.
// The one import this file has, and it costs it nothing: lib/nav.js is the
// nav's TABLE, not its rendering (scope.js does the DOM), so the line above
// still holds. VIEWS is derived from it below.
import { SECTIONS } from './nav.js';

export const DIMS = ['machine', 'login', 'project', 'model', 'branch', 'team', 'session', 'source'];
export const API_PARAM = { machine: 'endpoint', login: 'user', project: 'project', model: 'model', branch: 'branch', team: 'team', session: 'session', source: 'source' };
export const SPAN_VALUES = ['7d', '30d', '90d'];
export const GROUPS = ['project', 'login', 'machine', 'model', 'branch', 'team', 'source'];
export const SORTS = ['tokens', 'cost', 'started', 'duration', 'turns'];
// The consumption table's own sort. Kept apart from SORTS rather than merged:
// that list belongs to the sessions table and carries `started`/`duration`,
// which mean nothing for a provider row. One shared key would let a session
// sort survive into a table that cannot honour it.
export const CSORTS = ['cost', 'tokens', 'events'];
// The stalled table's own sort, kept apart from the other two for the same
// reason they are kept apart from each other: `tokens` and `cost` mean nothing
// for an issue, and `age` means nothing for a provider row. One shared key
// would let a sort survive into a table that cannot honour it.
export const RSORTS = ['age', 'comments'];
// VIEWS is which band the page is showing, and it is DERIVED from the nav's own
// table rather than written out again here. The two cannot disagree: a section
// added to SECTIONS is a routable view the moment it exists, and a view nothing
// navigates to cannot be spelled. The same reason nav.js shares one i18n key
// between the entry and the band it points at.
//
// `all` is the extra value and it is the default: the whole page, every band,
// which is exactly what this page has always been. That is what keeps every
// link ever shared — none of which carries a `view` — landing on the page its
// sender saw. #98 is what makes the other four actually unmount anything; until
// then `view` is a key the URL carries and the nav writes, and nothing more.
export const VIEW_ALL = 'all';
export const VIEWS = [VIEW_ALL, ...SECTIONS.map((s) => s.view)];
export const DEFAULTS = Object.freeze({ view: VIEW_ALL, session: null, sub: 'all', span: '30d', from: null, to: null, chips: {}, g1: 'project', g2: 'model', sort: 'tokens', csort: 'cost', repo: null, rsort: 'age', rlabel: null, rshipped: null });

const pick = (v, allowed, dflt) => (allowed.includes(v) ? v : dflt);
const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; };

export function parse(hash) {
  const s = { ...DEFAULTS, chips: {} };
  const h = (hash || '').replace(/^#/, '');
  const [path, qs = ''] = h.split('?');
  // `/now` and `/review` are consumed and dropped: the split they named is
  // gone, but links to it are in people's history and in chat logs, and a
  // shared link that lands on a blank page is how a rename loses readers
  // nobody hears from. Everything after it -- the session id and the whole
  // query string -- still resolves.
  const m = path.match(/^\/(?:(?:now|review)\/?)?(?:session\/([^/?]+))?\/?$/);
  if (m && m[1]) s.session = decodeURIComponent(m[1]);
  const p = new URLSearchParams(qs);
  // A query key, not a path segment, and that is deliberate. The path is where
  // /now and /review lived, and the reason they had to be consumed-and-dropped
  // above is that a path segment is exclusive: it cannot sit beside the session
  // overlay, so `#/review/session/abc` needed its own branch in the grammar. A
  // query key is orthogonal by construction — `#/session/abc?view=ops` opens the
  // overlay ON the operations view and closing it lands back there.
  s.view = pick(p.get('view'), VIEWS, DEFAULTS.view);
  if (p.get('sub')) s.sub = p.get('sub');
  s.span = pick(p.get('span'), SPAN_VALUES, DEFAULTS.span);
  s.from = num(p.get('from'));
  s.to = num(p.get('to'));
  if (s.from && s.to && s.to <= s.from) { s.from = null; s.to = null; }
  if (!s.from) s.to = null;
  for (const d of DIMS) { const v = p.get(d); if (v) s.chips[d] = v; }
  s.g1 = pick(p.get('g1'), GROUPS, DEFAULTS.g1);
  s.g2 = pick(p.get('g2'), GROUPS, DEFAULTS.g2);
  s.sort = pick(p.get('sort'), SORTS, DEFAULTS.sort);
  s.csort = pick(p.get('csort'), CSORTS, DEFAULTS.csort);
  s.repo = p.get('repo') || DEFAULTS.repo;
  s.rsort = pick(p.get('rsort'), RSORTS, DEFAULTS.rsort);
  // A label is DATA, not one of a fixed set, so there is no allowlist to check
  // it against -- a repository grows labels without this file hearing about
  // it. A label nothing currently carries is still honoured rather than
  // dropped: repo.js keeps it in the picker at zero, so the control and the
  // (empty) table agree. Silently clearing it here would leave the picker
  // reading "all" over a filtered set.
  s.rlabel = p.get('rlabel') || DEFAULTS.rlabel;
  s.rshipped = p.get('rshipped') === '1' ? '1' : DEFAULTS.rshipped;
  return s;
}

export function format(s) {
  const p = new URLSearchParams();
  // First, so a shared link says which page it is before it says how it is
  // filtered. Omitted at the default like every other key: `#/` still means
  // the whole page, and the nav writing `view=all` into every URL would be a
  // change to what a clean link looks like for no gain.
  if (s.view !== DEFAULTS.view) p.set('view', s.view);
  if (s.sub && s.sub !== DEFAULTS.sub) p.set('sub', s.sub);
  if (s.span !== DEFAULTS.span) p.set('span', s.span);
  if (s.from) p.set('from', String(s.from));
  if (s.from && s.to) p.set('to', String(s.to));
  for (const d of DIMS) if (s.chips[d]) p.set(d, s.chips[d]);
  if (s.g1 !== DEFAULTS.g1) p.set('g1', s.g1);
  if (s.g2 !== DEFAULTS.g2) p.set('g2', s.g2);
  if (s.sort !== DEFAULTS.sort) p.set('sort', s.sort);
  if (s.csort !== DEFAULTS.csort) p.set('csort', s.csort);
  if (s.repo) p.set('repo', s.repo);
  if (s.rsort !== DEFAULTS.rsort) p.set('rsort', s.rsort);
  if (s.rlabel) p.set('rlabel', s.rlabel);
  if (s.rshipped) p.set('rshipped', '1');
  const path = '#/' + (s.session ? 'session/' + encodeURIComponent(s.session) : '');
  const qs = p.toString();
  return qs ? path + '?' + qs : path;
}

// PRESENTATION_KEYS narrow or reorder rows the page ALREADY HAS. None of them
// appears in any request: the stalled table's filter and sort are applied to
// the same 348 issues the tier fetched once, and `csort` reorders the provider
// rows of one /v1/usage answer that is already in memory.
//
// The test for membership is mechanical, and it is the one to apply to any key
// added later: does changing it change the URL of a single request the page
// sends? `sort` does -- /v1/sessions is sorted server-side -- so it is NOT in
// here. `csort` does not: rows.js sorts those rows in the browser, and the key
// appears in no query string anywhere in the repo.
//
// dataKey is `format` with those keys flattened back to their defaults, so two
// states that ask the hub for exactly the same thing produce the same key.
// That is how app.js tells "redraw" from "re-fetch" -- without it, hiding some
// rows costs a round trip for every one of them, and the control that did the
// hiding goes on reporting its old value until the answer lands.
//
// `view` passes that mechanical test outright, and it is the key this list
// exists for. Switching view narrows WHICH bands the page shows; it does not
// change a single character of a single request URL -- every band on every view
// asks about the same account, the same window and the same chips. So the page
// re-draws from the rows already in hand and the switch costs zero requests.
// Leaving it out would make a view a full reload of the whole page: the same
// mistake `csort` made, at four times the price (#48 measured that one at 19
// requests per click). It stays true after #98 unmounts bands for real -- an
// unmounted band sends no request at all, which is fewer requests, never a
// different one, and seq.js's replay() is what hands its rows back on return.
export const PRESENTATION_KEYS = ['rsort', 'rlabel', 'rshipped', 'csort', 'view'];
export function dataKey(s) {
  const flat = { ...s, session: null };
  for (const k of PRESENTATION_KEYS) flat[k] = DEFAULTS[k];
  return format(flat);
}

/** accountsInScope narrows the account list to the ones the CURRENT state can
 *  actually be looking at. Today that is the source chip, which is the one
 *  filter that takes a subscription out of scope without naming it.
 *
 *  Exported because two callers must agree on this set or the page contradicts
 *  itself: resolveSub picks from it, and scope.js's <select> lists it and
 *  counts it to decide whether to offer "all" at all. A private copy in each is
 *  how a picker ends up offering a choice the router immediately undoes. */
export const accountsInScope = (accounts, s) => {
  const source = (s && s.chips && s.chips.source) || null;
  return (accounts || []).filter((a) => !source || (a.source || 'claude') === source);
};

/** resolveSub is the ONE rule for "which subscription is this state actually
 *  looking at". It ANSWERS, it does not mutate: app.js's route() is what writes
 *  the answer back into the state and the hash.
 *
 *  Three cases, in order:
 *    - the state names an account that exists in scope   -> keep it
 *    - exactly one account exists in scope               -> that one
 *    - anything else (none, several, an unknown uuid)    -> 'all'
 *
 *  The middle case is the whole of #92. 'all' is DEFAULTS.sub and format()
 *  omits a default, so the canonical hash `#/` parses back to 'all' forever --
 *  and the old fallback forced any unrecognised sub to 'all' including on a hub
 *  that has exactly one. So a one-subscription hub could not leave the
 *  "showing all subscriptions" state by any route, and spent every screen
 *  explaining cross-subscription arithmetic it had never performed (while the
 *  two limits banners, gated on the complement of that same condition, could
 *  never appear at all). One subscription is not a set to aggregate; it is the
 *  subscription. */
export function resolveSub(s, accounts) {
  const inScope = accountsInScope(accounts, s);
  if (s.sub && s.sub !== 'all' && inScope.some((a) => a.account_uuid === s.sub)) return s.sub;
  return inScope.length === 1 ? inScope[0].account_uuid : DEFAULTS.sub;
}

export const withChip = (s, dim, value) => ({ ...s, chips: { ...s.chips, [dim]: value } });
export function withoutChip(s, dim) { const chips = { ...s.chips }; delete chips[dim]; return { ...s, chips }; }
export const clearChips = (s) => ({ ...s, chips: {} });

// apiQuery renders the scope as the API's query string. omitDim implements the
// faceted-search rule: a card grouped by X leaves out its own X chip.
export function apiQuery(s, { from, to, omitDim, extra } = {}) {
  const p = new URLSearchParams();
  p.set('account', s.sub || 'all');
  p.set('since', new Date(from).toISOString());
  p.set('until', new Date(to).toISOString());
  for (const d of DIMS) if (s.chips[d] && d !== omitDim) p.set(API_PARAM[d], s.chips[d]);
  for (const [k, v] of Object.entries(extra || {})) p.set(k, String(v));
  return p.toString();
}
