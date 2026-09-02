// web/dist/lib/state.js — URL ⇄ state. No DOM. The hash is the only copy of the state.
export const DIMS = ['machine', 'login', 'project', 'model', 'branch', 'team', 'session'];
export const API_PARAM = { machine: 'endpoint', login: 'user', project: 'project', model: 'model', branch: 'branch', team: 'team', session: 'session' };
export const SPAN_VALUES = ['7d', '30d', '90d'];
export const GROUPS = ['project', 'login', 'machine', 'model', 'branch', 'team'];
export const SORTS = ['tokens', 'cost', 'started', 'duration', 'turns'];
export const DEFAULTS = Object.freeze({ view: 'now', session: null, sub: 'all', span: '30d', from: null, to: null, chips: {}, g1: 'project', g2: 'model', sort: 'tokens' });

const pick = (v, allowed, dflt) => (allowed.includes(v) ? v : dflt);
const num = (v) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null; };

export function parse(hash) {
  const s = { ...DEFAULTS, chips: {} };
  const h = (hash || '').replace(/^#/, '');
  const [path, qs = ''] = h.split('?');
  const m = path.match(/^\/(now|review)(?:\/session\/([^/?]+))?\/?$/);
  if (m) { s.view = m[1]; if (m[2]) s.session = decodeURIComponent(m[2]); }
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
  const path = '#/' + s.view + (s.session ? '/session/' + encodeURIComponent(s.session) : '');
  const qs = p.toString();
  return qs ? path + '?' + qs : path;
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
