// web/dist/lib/pages.js — what the four everyday pages compute from the
// hub's answers, with no DOM (claude-fleet#1989): Overview's days, bars and
// attention list, Sessions' rows and filters, Config's item lists. The page
// scripts (overview.js, sessions-page.js, connect.js, config.js) fetch and
// draw; web/test/pages.test.mjs pins these.
//
// Nothing here widens what the hub sent: a user's answers are already cut to
// their own machine login (claude-fleet#1985), and these functions only
// group, sort and label them.

import { esc, ic, fmtTokens, spark } from './shell.js';
import { t, fmtDate } from './i18n.js';

const DAY = 86400000;

/** utcMidnight is the start of the UTC day holding t. The hub's days are UTC. */
export const utcMidnight = (t) => Math.floor(t / DAY) * DAY;

/** dayKeys are the last n UTC days ending today, oldest first, as YYYY-MM-DD. */
export function dayKeys(now, n) {
  const end = utcMidnight(now);
  const out = [];
  for (let i = n - 1; i >= 0; i--) out.push(new Date(end - i * DAY).toISOString().slice(0, 10));
  return out;
}

/** dayTokens lays a sparse /v1/history series onto keys: absent days are 0. */
export function dayTokens(keys, series) {
  const by = new Map((Array.isArray(series) ? series : []).map((p) => [p.key, Number(p.tokens) || 0]));
  return keys.map((k) => by.get(k) || 0);
}

/** stack pairs Claude and Codex per day: [[claude, codex], …]. */
export const stack = (claude, codex) => claude.map((c, i) => [c, codex[i] || 0]);

/** dayLabel is "Oct 6" / "10月6日" for a YYYY-MM-DD key. */
export function dayLabel(key) {
  const [y, m, d] = key.split('-').map(Number);
  return fmtDate(new Date(y, m - 1, d, 12).getTime(), undefined, false);
}

/** delta is the KPI's change line against the previous window, or '' when
 *  there was nothing before to compare with. `key` is the t() template, its
 *  {p} the signed percent. */
export function delta(cur, prev, key) {
  cur = Number(cur) || 0; prev = Number(prev) || 0;
  if (!prev) return { text: '', down: false };
  const p = Math.round(((cur - prev) / prev) * 100);
  return { text: t(key, { p: `${p >= 0 ? '+' : ''}${p}%` }), down: p < 0 };
}

/** bars turns /v1/usage buckets into [label, tokens] rows, largest first,
 *  merged by label (one machine can report through several endpoints), the
 *  tail past `top` folded into "other". */
export function bars(buckets, top = 6) {
  const m = new Map();
  for (const b of Array.isArray(buckets) ? buckets : []) {
    const name = b.label || b.key || 'unknown';
    m.set(name, (m.get(name) || 0) + (Number(b.tokens) || 0));
  }
  const rows = [...m.entries()].filter((r) => r[1] > 0).sort((a, b) => b[1] - a[1]);
  if (rows.length <= top) return rows;
  const rest = rows.slice(top - 1).reduce((t, r) => t + r[1], 0);
  return [...rows.slice(0, top - 1), [t('ui.ov.other'), rest]];
}

/** niceMax rounds a chart's top up to 1, 2 or 5 × a power of ten. */
export function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 5, 10]) if (v <= m * p) return m * p;
  return 10 * p;
}

/** areaChart is the 14-day stacked chart: Claude below, Codex on top. */
export function areaChart(data, keys) {
  const W = 640, H = 220, L = 62, R = 8, T = 10, B = 26;
  const n = Math.max(2, data.length);
  const max = niceMax(Math.max(0, ...data.map((d) => d[0] + d[1])));
  const x = (i) => L + i * (W - L - R) / (n - 1);
  const y = (v) => T + (H - T - B) * (1 - v / max);
  let grid = '';
  for (let t = 0; t <= 4; t++) {
    const v = max * t / 4;
    grid += `<line x1="${L}" x2="${W - R}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}"/><text x="${L - 8}" y="${(y(v) + 4).toFixed(1)}" text-anchor="end">${fmtTokens(v)}</text>`;
  }
  const top = data.map((d, i) => [x(i), y(d[0] + d[1])]);
  const mid = data.map((d, i) => [x(i), y(d[0])]);
  const line = (pts) => pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  if (!data.length) return '';
  const claude = line(mid) + ` L${x(data.length - 1).toFixed(1)} ${y(0).toFixed(1)} L${x(0).toFixed(1)} ${y(0).toFixed(1)}Z`;
  const codex = line(top) + ' ' + mid.slice().reverse().map((p) => 'L' + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ') + 'Z';
  const every = Math.max(1, Math.round((keys.length - 1) / 3));
  const xl = keys.map((k, i) => (i % every === 0 || i === keys.length - 1) && !(i !== keys.length - 1 && keys.length - 1 - i < every / 2)
    ? `<text x="${x(i).toFixed(1)}" y="${H - 6}" text-anchor="${i === 0 ? 'start' : i === keys.length - 1 ? 'end' : 'middle'}">${esc(dayLabel(k))}</text>` : '').join('');
  const total = data.reduce((t, d) => t + d[0] + d[1], 0);
  return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(t('ui.ov.chartLabel', { n: data.length, total: fmtTokens(total) }))}"><g class="grid">${grid}</g>` +
    `<path d="${claude}" fill="var(--brand)" opacity=".22"/><path d="${line(mid)}" fill="none" stroke="var(--brand)" stroke-width="2"/>` +
    `<path d="${codex}" fill="var(--codex)" opacity=".2"/><path d="${line(top)}" fill="none" stroke="var(--codex)" stroke-width="2"/>${xl}</svg>`;
}

/* ---------------- sessions ---------------- */

/** STATES are a fleet worker's states as the page names them (`label` a
 *  t() key); `group` is the filter it counts under. */
const STATE_DEF = {
  working: { dot: 'ok pulse', group: 'working' },
  waiting: { dot: 'warn', group: 'waiting' },
  blocked: { dot: 'bad', group: 'waiting' },
  idle: { dot: 'idle', group: 'idle' },
  done: { dot: 'idle', group: 'idle' },
  unknown: { dot: 'idle', group: 'idle' },
};
export const STATES = Object.freeze(Object.fromEntries(Object.entries(STATE_DEF).map(([k, v]) => [k, Object.freeze({ ...v, key: 'ui.st.' + k })])));
export const stateOf = (s) => { const d = STATES[s] || STATES.unknown; return { ...d, label: t(d.key) }; };

/** FILTERS are the segmented control's buttons, in order: [id, t() key]. */
export const FILTERS = Object.freeze([['all', 'ui.f.all'], ['working', 'ui.st.working'], ['waiting', 'ui.st.waiting'], ['idle', 'ui.st.idle']]);

/** liveIndex keys /v1/live's sessions by worktree (else cwd), so a fleet
 *  worker finds its context %, model and subscription. */
export function liveIndex(live) {
  const m = new Map();
  for (const s of (live && Array.isArray(live.sessions)) ? live.sessions : []) {
    for (const k of [s.worktree, s.cwd]) if (k && !m.has(k)) m.set(k, s);
  }
  return m;
}

/** sessionRows flattens /v1/fleet/fleet_sessions (+ /v1/live) into the
 *  table's rows, newest first. */
export function sessionRows(fs, live) {
  const idx = liveIndex(live);
  const rows = [];
  for (const s of (fs && Array.isArray(fs.sessions)) ? fs.sessions : []) {
    const w = s.worker || {};
    const l = idx.get(w.worktree) || null;
    rows.push({
      id: w.worker_id || s.worker_id || `${s.machine_name}/${w.key}`,
      key: w.key || w.name || w.handle || '—',
      repo: w.repo || '',
      title: w.title || w.name || '',
      state: STATES[w.state] ? w.state : 'unknown',
      needs: w.needs || '',
      machine: s.machine_name || '',
      availability: s.availability || 'online',
      person: s.os_user || '',
      agent: w.agent || '',
      worktree: w.worktree || '',
      born: Number(w.born) || 0,
      observed: s.observed_at || '',
      ctx: l && !l.context_unknown && Number.isFinite(Number(l.context_used_pct)) ? Number(l.context_used_pct) : null,
      model: (l && l.model) || '',
      account: (l && l.account) || '',
    });
  }
  return rows.sort((a, b) => b.born - a.born || a.key.localeCompare(b.key));
}

/** counts per filter group. */
export function counts(rows) {
  const c = { all: rows.length, working: 0, waiting: 0, idle: 0 };
  for (const r of rows) c[stateOf(r.state).group]++;
  return c;
}

/** filterRows applies the state filter and the search box. */
export function filterRows(rows, filter, query) {
  const q = String(query || '').trim().toLowerCase();
  return rows.filter((r) => (filter === 'all' || !filter || stateOf(r.state).group === filter) &&
    (!q || [r.key, r.repo, r.title, r.machine, r.person].join(' ').toLowerCase().includes(q)));
}

/** running is the sessions that are not resting. */
export const running = (rows) => rows.filter((r) => ['working', 'waiting', 'blocked'].includes(r.state));

/** attention is Overview's "Needs attention": sessions waiting on someone,
 *  and — for an admin — machines that are lost or in maintenance. */
export function attention(rows, nodes, admin) {
  const out = [];
  for (const r of rows) {
    if (r.state === 'waiting') out.push({ tone: 'warn', icon: 'alert', title: t('ui.att.waiting', { key: r.key }), sub: [r.title, r.machine].filter(Boolean).join(' · ') });
    if (r.state === 'blocked') out.push({ tone: 'bad', icon: 'alert', title: t('ui.att.blocked', { key: r.key }), sub: [r.title, r.machine].filter(Boolean).join(' · ') });
  }
  if (admin) {
    for (const n of Array.isArray(nodes) ? nodes : []) {
      if (n.availability === 'lost') out.push({ tone: 'bad', icon: 'server', title: t('ui.att.lost', { m: n.machine_name }), sub: t('ui.att.lostSub') });
      if (n.availability === 'maintenance') out.push({ tone: 'warn', icon: 'server', title: t('ui.att.maint', { m: n.machine_name }), sub: t('ui.att.maintSub') });
    }
  }
  return out;
}

/** hhmm is when a session was born (epoch seconds): the clock time today,
 *  else the day and time. */
export function hhmm(sec, now = Date.now()) {
  if (!sec) return '—';
  const d = new Date(sec * 1000);
  if (new Date(now).toDateString() === d.toDateString()) return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  return fmtDate(d.getTime());
}

/* ---------------- devices ---------------- */

/** activeDevices are the devices not revoked. */
export const activeDevices = (devs) => (Array.isArray(devs) ? devs : []).filter((d) => !d.revoked_at);

/** looksLikeKey is the hand-issue box's check before it asks the hub. */
export const looksLikeKey = (k) => /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/=]{16,}/.test(String(k || '').trim());

/* ---------------- config ---------------- */

const short = (v) => {
  const s = typeof v === 'string' ? v : JSON.stringify(v);
  return s.length > 60 ? s.slice(0, 57) + '…' : s;
};

/** bundleItems lists a team / person bundle as [kind, text] rows, the way the
 *  Config page shows them: one per MCP server, hook, skill or setting. */
export function bundleItems(bundle) {
  const b = bundle && typeof bundle === 'object' ? bundle : {};
  const out = [];
  const obj = (k) => (b[k] && typeof b[k] === 'object' && !Array.isArray(b[k]) ? b[k] : {});
  for (const name of Object.keys(obj('mcp')).sort()) out.push(['mcp', name]);
  for (const [ev, list] of Object.entries(obj('hooks'))) {
    for (const h of Array.isArray(list) ? list : []) out.push(['hook', `${ev}${h && h.matcher ? ' ' + h.matcher : ''} · ${short((h && h.command) || '')}`]);
  }
  for (const name of Object.keys(obj('hook_scripts')).sort()) out.push(['script', name]);
  for (const name of Object.keys(obj('skills')).sort()) out.push(['skill', name]);
  for (const [k, v] of Object.entries(obj('claude_settings'))) out.push(['claude', `${k} = ${short(v)}`]);
  for (const [k, v] of Object.entries(obj('codex_config'))) out.push(['codex', `${k} = ${short(v)}`]);
  return out;
}

/** parseImport reads an exported file back: either the bare bundle or the
 *  whole GET answer ({version, bundle}). Throws on anything else. */
export function parseImport(text) {
  let v;
  try { v = JSON.parse(text); } catch { throw new Error(t('ui.cfg.notJson')); }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(t('ui.cfg.notObject'));
  const bundle = v.bundle && typeof v.bundle === 'object' ? v.bundle : v;
  return bundle;
}

// ── 我的额度 (claude-fleet#2517) ─────────────────────────────────────────

/** quotaState is a /v1/me/quota row's status chip: [tone, text]. Used up
 *  says which window — the weekly one is the wait people ask about. */
export function quotaState(r) {
  const full = (p) => p != null && Number(p) >= 100;
  switch (r && r.state) {
    case 'ok': return ['ok', t('ui.q.ok')];
    case 'paused': return ['', t('ui.q.paused')];
    case 'limited':
      return ['bad', t(full(r.used_7d_pct) ? 'ui.q.limitedWeek' : full(r.used_5h_pct) ? 'ui.q.limited5h' : 'ui.q.limited')];
    default: return ['', t('ui.q.unknown')];
  }
}

const qLevel = (p) => (p >= 100 ? 'bad' : p >= 70 ? 'warn' : '');

function qCell(p) {
  if (p == null) return '<td class="mono">—</td>';
  const n = Math.max(0, Math.min(100, Math.round(Number(p))));
  return `<td class="mono"><div class="win"><b>${n}%</b><div class="track"><i class="${qLevel(n)}" style="width:${n}%"></i></div></div></td>`;
}

/** quotaTable draws /v1/me/quota: one row per subscription, or the empty
 *  state when the hub has given the person none. */
export function quotaTable(rows) {
  const list = Array.isArray(rows) ? rows : [];
  if (!list.length) {
    return `<div class="empty"><b>${esc(t('ui.q.empty'))}</b><span>${esc(t('ui.q.emptyHint'))}</span></div>`;
  }
  const th = ['ui.q.col.sub', 'ui.q.col.h5', 'ui.q.col.h7', 'ui.q.col.reset', 'ui.q.col.state'].map((k) => `<th>${esc(t(k))}</th>`).join('');
  const body = list.map((r) => {
    const [tone, text] = quotaState(r);
    return `<tr class="quota-row"><td><b>${esc(r.subscription || '—')}</b></td>${qCell(r.used_5h_pct)}${qCell(r.used_7d_pct)}` +
      `<td>${esc(r.resets_at ? fmtDate(r.resets_at) : '—')}</td><td><span class="chip ${tone}">${esc(text)}</span></td></tr>`;
  }).join('');
  return `<div class="tw"><table class="t quota"><thead><tr>${th}</tr></thead><tbody>${body}</tbody></table></div>`;
}

// 我的机器 (claude-fleet#2518): one row per login of the viewer's, from
// /v1/nodes (already cut to their logins, nodes.go handleNodes) and
// /v1/me.logins. A machine link is a carrier, not a login, and is left out;
// so is any (machine, login) /v1/me does not list as theirs. No join code, no
// retire, nothing about another login's compute.

/** takesOf is whether a login takes sessions: coord · lost · maint · paused · on.
 *  A login that only coordinates (a person's laptop) says so even offline. */
export function takesOf(n) {
  if (n.compute_off) return 'coord';
  if (n.status === 'lost') return 'lost';
  if (n.status === 'maintenance') return 'maint';
  if (n.admit === false) return 'paused';
  return 'on';
}

/** myMachines turns /v1/nodes + /v1/me into the page's rows, the machines
 *  that take sessions first, then by name. */
export function myMachines(snap, me) {
  const pairs = me && Array.isArray(me.logins) && me.logins.length ? me.logins : null;
  const mine = (n) => !pairs || pairs.some((p) => p.machine === n.hostname && p.login === n.os_user);
  const alias = new Map(((snap && snap.machines) || []).map((m) => [m.hostname, m.alias || '']));
  const rows = ((snap && snap.nodes) || []).filter((n) => !n.machine_link && mine(n)).map((n) => {
    const takes = takesOf(n);
    const coord = takes === 'coord';
    const live = takes !== 'lost';
    return {
      id: n.endpoint_id, hostname: n.hostname, label: alias.get(n.hostname) || n.hostname,
      login: n.os_user, takes, why: takes === 'paused' ? n.admit_why || '' : coord ? n.compute_why || '' : '',
      personal: !!n.personal,
      loadCore: coord || !live || !(n.ncpu > 0) ? null : (Number(n.load1) || 0) / n.ncpu,
      sessions: coord ? null : n.sessions == null ? undefined : n.sessions,
    };
  });
  return rows.sort((a, b) => (a.takes === 'coord') - (b.takes === 'coord') || a.label.localeCompare(b.label) || a.login.localeCompare(b.login));
}

/** kpi is one number tile: a label, the value, a trend line and a delta. */
export function kpi(label, val, trend, d) {
  return `<div class="panel kpi"><span class="lbl">${esc(label)}</span><span class="val">${esc(val)}</span>${trend && trend.length ? spark(trend, 'var(--brand)', true) : ''}<span class="delta${d && d.down ? ' down' : ''}"${d && d.muted ? ' style="color:var(--muted)"' : ''}>${esc((d && d.text) || ' ')}</span></div>`;
}

/** hb draws [label, tokens] rows (bars()) as horizontal bars. */
export function hb(rows, color) {
  if (!rows.length) return `<div class="ghostrow">${esc(t('ui.ov.noUsage7'))}</div>`;
  const max = rows[0][1] || 1;
  return '<div class="hb">' + rows.map((r) => `<div class="hb-row"><span class="name mono" title="${esc(r[0])}">${esc(r[0])}</span><span class="track"><i style="width:${(r[1] / max * 100).toFixed(0)}%;background:${color}"></i></span><span class="v">${esc(fmtTokens(r[1]))}</span></div>`).join('') + '</div>';
}

/** bundleList draws a settings layer's [kind, text] items (bundleItems);
 *  src 'team' or 'mine' labels each row's source. */
export function bundleList(list, src) {
  if (!list.length) return `<div class="empty">${ic('sliders')}<b>${esc(t('ui.cfg.empty'))}</b><span>${esc(t(src === 'team' ? 'ui.cfg.emptyTeam' : 'ui.cfg.emptyMine'))}</span></div>`;
  return '<div class="items">' + list.map(([k, txt]) => `<div><span class="kind">${esc(k)}</span><span class="mono" style="min-width:0;overflow-wrap:anywhere">${esc(txt)}</span><span class="src chip${src === 'team' ? ' brand' : ''}">${esc(t(src === 'team' ? 'ui.cfg.srcTeam' : 'ui.cfg.srcMine'))}</span></div>`).join('') + '</div>';
}
