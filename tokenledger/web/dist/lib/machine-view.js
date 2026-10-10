// web/dist/lib/machine-view.js — one machine's page, with no DOM
// (claude-fleet#2796, EPIC #2792 C4): what /v1/nodes/<host> says, made into
// the five blocks a person reads — 登录 · 服务与定时任务 · 版本与更新 · 负载与内存 ·
// 会话 — each with how long ago it was measured (lib/shell.js freshness).
// Also the way into it from either machine list: machineHref, and listNav,
// the j/k + ↵ keys over a list's rows. machine.js draws the blocks;
// web/test/machine-view.test.mjs pins them.
import { freshness } from './shell.js';
import { serviceRows } from './services.js';
import { sessionRows } from './pages.js';

/** HOUR is how many of the roster's five-minute points make the trend. */
export const HOUR = 12;

/** machineHref is a machine's page: its short name, ?from=nodes when opened
 *  from the admin's Machines (so the menu lights that list). */
export function machineHref(host, fromNodes) {
  const name = String(host || '').split('.')[0];
  return `/machines/${encodeURIComponent(name)}${fromNodes ? '?from=nodes' : ''}`;
}

/** backHref is the list the page was opened from. */
export const backHref = (search) => (new URLSearchParams(search || '').get('from') === 'nodes' ? '/nodes' : '/machines');

const gb = (b) => (Number(b) > 0 ? Number(b) / (1 << 30) : 0);

/** versionModel is 版本与更新: what runs, what should, the updater's phase. */
export function versionModel(v) {
  v = v || {};
  const comps = [];
  const have = v.components || {}, want = v.want_components || {};
  for (const k of [...new Set([...Object.keys(have), ...Object.keys(want)])].sort()) {
    comps.push({ name: k, have: have[k] || '', want: want[k] || '', off: !!want[k] && have[k] !== want[k] });
  }
  const rel = (r) => (r ? String(r).slice(0, 7) : '');
  return {
    agent: v.agent || '', fleet: v.fleet || '', runtime: rel(v.runtime),
    want: v.want ? { n: v.want, rel: rel(v.want_release) } : null,
    reached: v.want || v.reached ? { n: v.reached || 0, rel: rel(v.release) } : null,
    behind: !!v.want && (v.want !== v.reached || !!v.diff), diff: v.diff || '',
    comps, phase: v.phase || '', result: v.result || '', reason: v.reason || '', updatedAt: v.updated_at || null,
    // Components and the phase come only from a node that reports them (C6).
    reported: !!(comps.length || v.phase || v.at),
  };
}

/** loadModel is load and its last hour: per core now, the trend, and how far
 *  back the trend reaches when the hub restarted inside the hour. */
export function loadModel(l) {
  l = l || {};
  const hist = Array.isArray(l.hist) ? l.hist.slice(-HOUR) : [];
  const step = Number(l.hist_step_sec) || 300;
  return {
    perCore: l.ncpu > 0 ? (Number(l.now) || 0) / l.ncpu : null, ncpu: Number(l.ncpu) || 0, now: Number(l.now) || 0,
    hist, peak: hist.length ? Math.max(...hist) : null,
    // A trend shorter than the hour: the hub restarted, it starts N min ago.
    shortMin: hist.length && hist.length < HOUR ? Math.round(((hist.length - 1) * step) / 60) : null,
    noTrend: !hist.length, unread: Array.isArray(l.unread) ? l.unread : [],
  };
}

/** memModel is memory: used / total in GB and the share used. */
export function memModel(m) {
  m = m || {};
  const total = gb(m.total);
  return { total, used: gb(m.used), pct: m.pressure == null ? null : Math.round(Number(m.pressure) * 100), known: total > 0 };
}

/** loginRows is the logins block: each login's word, its sessions, when heard. */
export function loginRows(d) {
  return ((d && d.logins) || []).map((n) => ({
    login: n.os_user || '', status: n.status || 'lost',
    sessions: n.sessions == null ? null : n.sessions,
    admit: n.admit === false ? (n.admit_why || 'no') : '',
    refused: (n.logins_refused && n.logins_refused[n.os_user]) || ((d.machine && d.machine.logins_refused) || {})[n.os_user] || '',
    credsep: n.credsep || '', seen: n.last_heartbeat || null, agent: n.agent_version || '',
  }));
}

/** detailModel is the whole page from one /v1/nodes/<host> answer. */
export function detailModel(d, now = Date.now()) {
  const m = (d && d.machine) || {};
  const host = m.hostname || '';
  const name = host.split('.')[0];
  const ver = (d && d.version) || {};
  return {
    host, name, label: m.alias || name, status: m.status || 'lost', role: m.role || '', maintenance: m.maintenance || null,
    logins: loginRows(d), others: Number(d && d.other_logins) || 0, loginsAt: freshness(d && d.logins_at, now),
    services: serviceRows({ machines: [{ ...m, services: (d && d.services) || [], services_at: d && d.services_at }] }),
    servicesAt: freshness(d && d.services_at, now),
    version: versionModel(ver), versionAt: freshness(ver.at, now),
    load: loadModel(d && d.load), mem: memModel(d && d.mem), sysAt: freshness(d && d.load && d.load.at, now),
    sessions: sessionRows({ sessions: (d && d.sessions) || [] }), sessionsAt: freshness(d && d.sessions_at, now),
  };
}

/** clientRedirect is where a client device's page goes instead (C3: only a
 *  host has a page): 我的设备, or the admin's 全部设备. */
export const clientRedirect = (admin) => (admin ? '/admin/devices' : '/connect');

/** nextIndex is the row j/k moves to from i over n rows (-1 = none yet). */
export function nextIndex(i, n, key) {
  if (!n) return -1;
  if (key === 'j') return i < 0 ? 0 : Math.min(n - 1, i + 1);
  if (key === 'k') return i < 0 ? 0 : Math.max(0, i - 1);
  return i;
}

/** listNav makes a list's rows ([data-href]) a way in: a click (not on a
 *  button or a link of its own) or ↵ opens the row, j/k move between rows.
 *  Its listeners are the page's (ctx.on), gone when the page is left. */
export function listNav(ctx, selector = '[data-href]') {
  // Once per page shown: a ctx.refresh() runs the page's render again.
  if (ctx.el.dataset.listNav) return;
  ctx.el.dataset.listNav = '1';
  const rows = () => [...ctx.el.querySelectorAll(selector)];
  ctx.on(ctx.el, 'click', (e) => {
    const r = e.target.closest(selector);
    if (!r || e.target.closest('button, a, input, [data-act], [data-svc]') || e.defaultPrevented) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey) { window.open(r.dataset.href, '_blank'); return; }
    ctx.navigate(r.dataset.href);
  });
  ctx.on(document, 'keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || document.querySelector('#layer .scrim')) return;
    const tag = (e.target && e.target.tagName) || '';
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(tag) || (e.target && e.target.isContentEditable)) return;
    const rs = rows();
    const i = rs.indexOf(document.activeElement);
    if (e.key === 'j' || e.key === 'k') {
      const n = nextIndex(i, rs.length, e.key);
      if (n >= 0) { e.preventDefault(); rs[n].focus(); }
    } else if (e.key === 'Enter' && i >= 0) {
      e.preventDefault();
      ctx.navigate(rs[i].dataset.href);
    }
  });
}
