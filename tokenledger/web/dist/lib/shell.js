// web/dist/lib/shell.js — the app shell's decisions, with no DOM
// (claude-fleet#1989): which menu a role sees, what the sidebar says about the
// viewer, and the small string builders every page shares (icons, sparkline,
// context bar, numbers). app-shell.js draws them; web/test/shell.test.mjs pins
// them.
//
// The menu is /v1/me's `pages` (claude-fleet#1985), never a role test here: a
// page the hub does not list is not drawn, and an id this table does not know
// is skipped. The admin group is C8's (#1990): Subscriptions, Machines, Users,
// Settings, Audit.
//
// Every word goes through t() (lib/i18n.js), English and 简体中文 alike.
import { t, fmtCompact, fmtAgo } from './i18n.js';

/** esc makes a value safe inside HTML text and attribute values. */
export const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/** Icons, after the prototype: 24×24 stroke paths. */
export const ICONS = Object.freeze({
  home: '<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13"/><circle cx="4" cy="6" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="18" r="1"/>',
  card: '<rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M2.5 10h19M6 15h4"/>',
  server: '<rect x="3" y="4" width="18" height="7" rx="1.5"/><rect x="3" y="13" width="18" height="7" rx="1.5"/><path d="M7 7.5h.01M7 16.5h.01"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3M15 8l2 2"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5"/><path d="M16 4.6a3.5 3.5 0 010 6.8M18 14.8c1.8.7 3 2.4 3.5 5.2"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>',
  scroll: '<path d="M6 3h11a2 2 0 012 2v14a2 2 0 01-2 2H7a2 2 0 01-2-2V8"/><path d="M5 8H3V5a2 2 0 014 0v3M9 9h7M9 13h7M9 17h4"/>',
  shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/>',
  check: '<path d="M4 12.5l5 5L20 6.5"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  alert: '<path d="M12 3l9.5 17h-19z"/><path d="M12 10v4M12 17.5h.01"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  out: '<path d="M15 4h4v16h-4M10 8l-4 4 4 4M6 12h11"/>',
  lock: '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
  term: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 9l3 3-3 3M12 15h5"/>',
  git: '<circle cx="6" cy="6" r="2.5"/><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="8" r="2.5"/><path d="M6 8.5v7M18 10.5c0 4-6 3-10 6"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  refresh: '<path d="M20 11a8 8 0 10-2.3 5.7M20 4v7h-7"/>',
  fleet: '<path d="M4 17l4-10 4 10M12 17l4-10 4 10M3 20h18"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  pause: '<path d="M9 5v14M15 5v14"/>',
  play: '<path d="M7 5l12 7-12 7z"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
  wrench: '<path d="M14.5 6.5a4 4 0 00-5.4 5L4 16.6 7.4 20l5.1-5.1a4 4 0 005-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/>',
  download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
});

/** ic is one icon's <svg>. */
export const ic = (name, cls) => `<svg class="i ${cls || ''}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name] || ''}</svg>`;

/** PAGES is every page the menu can draw, in menu order; `label` is a t()
 *  key. `group` 'admin' goes under the Admin heading. Ids are /v1/me's (roles.go pagesFor). */
export const PAGES = Object.freeze([
  { id: 'overview', label: 'ui.nav.overview', icon: 'home', href: '/' },
  { id: 'sessions', label: 'ui.nav.sessions', icon: 'list', href: '/sessions' },
  { id: 'devices', label: 'ui.nav.devices', icon: 'key', href: '/connect' },
  { id: 'config', label: 'ui.nav.config', icon: 'sliders', href: '/config' },
  // The admin group (claude-fleet#1990).
  { id: 'subscriptions', label: 'ui.nav.subscriptions', icon: 'card', group: 'admin', href: '/subscriptions' },
  { id: 'machines', label: 'ui.nav.machines', icon: 'server', group: 'admin', href: '/nodes' },
  { id: 'people', label: 'ui.nav.people', icon: 'users', group: 'admin', href: '/admin/users' },
  { id: 'settings', label: 'ui.nav.settings', icon: 'gear', group: 'admin', href: '/admin/settings' },
  { id: 'audit', label: 'ui.nav.audit', icon: 'scroll', group: 'admin', href: '/admin/audit' },
]);

/** navFor turns /v1/me's pages into the menu: [{heading}|{id,label,icon,href}].
 *  Only pages the hub listed AND that have a page to go to; the Admin heading
 *  only above at least one admin item. */
export function navFor(pages) {
  const allowed = new Set(Array.isArray(pages) ? pages : []);
  const shown = PAGES.filter((p) => allowed.has(p.id) && p.href).map((p) => ({ ...p, label: t(p.label) }));
  const own = shown.filter((p) => !p.group);
  const admin = shown.filter((p) => p.group === 'admin');
  return admin.length ? [...own, { heading: t('ui.nav.admin') }, ...admin] : own;
}

/** pageAllowed is whether the menu lists this page for the viewer. */
export const pageAllowed = (me, id) => !!(me && Array.isArray(me.pages) && me.pages.includes(id));

/** title is a page id's heading in the top bar. */
export const titleOf = (id) => { const p = PAGES.find((x) => x.id === id); return p ? t(p.label) : ''; };

/** isAdmin reads the role /v1/me reported. An operator token is an admin. */
export const isAdmin = (me) => !!me && (me.role === 'admin' || me.role === 'operator');

/** viewer is what the sidebar's foot says: a name, and role · door. */
export function viewer(me) {
  if (!me) return null;
  const name = me.name || me.login || me.person || (me.via === 'token' ? 'operator' : t('ui.me.you'));
  const role = t(isAdmin(me) ? 'ui.role.admin' : 'ui.role.user');
  const door = ['github', 'token', 'open'].includes(me.via) ? t('ui.door.' + me.via) : me.via || '';
  return { name, sub: door ? `${role} · ${door}` : role, initials: String(name).slice(0, 2).toUpperCase(), logout: !!me.can_logout };
}

/** fmtTokens prints a token count the way the KPI tiles do: 212.4M / 2.12 亿. */
export const fmtTokens = (n) => fmtCompact(n);

/** spark is a 120×34 sparkline, filled under the line when fill is set. */
export function spark(vals, color, fill) {
  const v = (vals && vals.length ? vals : [0, 0]).map((x) => Number(x) || 0);
  if (v.length === 1) v.unshift(v[0]);
  const w = 120, h = 34, max = Math.max(1, ...v), step = w / (v.length - 1);
  const pts = v.map((x, i) => [i * step, h - 3 - (x / max) * (h - 6)]);
  const d = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  const last = pts[pts.length - 1];
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">` +
    (fill ? `<path d="${d} L${w} ${h} L0 ${h}Z" fill="${color}" opacity=".12"/>` : '') +
    `<path d="${d}" fill="none" stroke="${color}" stroke-width="1.8" vector-effect="non-scaling-stroke"/>` +
    `<circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="2.4" fill="${color}"/></svg>`;
}

/** ctxBar is a context-window bar; no number = a dash. */
export function ctxBar(p) {
  if (p == null || p === '' || !Number.isFinite(Number(p))) return '<span class="ctx">—</span>';
  const n = Math.max(0, Math.min(100, Math.round(Number(p))));
  return `<span class="ctx"><span class="bar"><i class="${n > 60 ? 'warn' : ''}" style="width:${n}%"></i></span>${n}%</span>`;
}

/** relTime is "12 min ago" / "12 分钟前", from an epoch-ms or ISO time. */
export const relTime = (t0, now = Date.now()) => fmtAgo(t0, now);

/** greeting is the overview's hello, by the viewer's local hour. */
export function greeting(hour, name) {
  const k = hour >= 5 && hour < 12 ? 'morning' : hour >= 12 && hour < 18 ? 'afternoon' : 'evening';
  return t('ui.hello.' + k, { name });
}

/** liveLine is the top bar's "Live · 3 sessions · 2 of 3 machines online",
 *  from /v1/fleet/fleet_sessions; '' when there is no answer. */
export function liveLine(fs) {
  if (!fs || !Array.isArray(fs.sessions)) return '';
  const n = fs.sessions.length;
  const nodes = Array.isArray(fs.nodes) ? fs.nodes : [];
  const on = nodes.filter((x) => x.availability === 'online').length;
  const parts = [n === 1 ? t('ui.live.one') : t('ui.live.many', { n })];
  if (nodes.length) parts.push(t(nodes.length === 1 ? 'ui.live.machine1' : 'ui.live.machines', { on, all: nodes.length }));
  return parts.join(' · ');
}
