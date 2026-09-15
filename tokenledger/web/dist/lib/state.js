// web/dist/lib/state.js — URL ⇄ state. No DOM. The hash is the only copy of the state.
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
export const DEFAULTS = Object.freeze({ session: null, sub: 'all', span: '30d', from: null, to: null, chips: {}, g1: 'project', g2: 'model', sort: 'tokens', csort: 'cost', repo: null, rsort: 'age', rlabel: null, rshipped: null });

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
// the same 348 issues the tier fetched once.
//
// dataKey is `format` with those keys flattened back to their defaults, so two
// states that ask the hub for exactly the same thing produce the same key.
// That is how app.js tells "redraw" from "re-fetch" -- without it, hiding some
// rows costs a round trip for every one of them, and the control that did the
// hiding goes on reporting its old value until the answer lands.
export const PRESENTATION_KEYS = ['rsort', 'rlabel', 'rshipped'];
export function dataKey(s) {
  const flat = { ...s, session: null };
  for (const k of PRESENTATION_KEYS) flat[k] = DEFAULTS[k];
  return format(flat);
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
