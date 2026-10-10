// web/dist/machine.js — one machine, at /machines/<host> (claude-fleet#2796,
// EPIC #2792 C4): opened from 我的机器 or the admin's Machines with one click
// (or j/k + ↵). On one screen: 负载与内存 (the last hour's trend), 版本与更新,
// 登录, 会话, 服务与定时任务 — each block saying how long ago it was measured
// (lib/shell.js freshness: yellow past a minute, grey past five, 时间未知 for a
// node that does not say). Below them a place for the logs (C5's).
//
// Reads /v1/nodes/<host> only — the hub cuts it to the viewer's logins (a
// user sees their own rows and 「另有 N 个登录」; a machine with none of their
// logins is 404). A client device has no page (C3): it goes to the devices
// page. The service rows open the same drawer as the lists (lib/services.js).
// Re-read every 10 s while the tab is visible and the page shown.
import { Shell } from './app-shell.js';
import { esc, ic, spark } from './lib/shell.js';
import { routeFor, pathParam } from './lib/router.js';
import { detailModel, backHref, clientRedirect } from './lib/machine-view.js';
import { servicesSection, svcClick } from './lib/services.js';
import { stateOf, hhmm } from './lib/pages.js';
import { t } from './lib/i18n.js';

const S = { svcs: [] };

const fresh = (f) => `<span class="fresh ${esc(f.cls)}">${esc(f.text)}</span>`;
const head = (title, f, extra) => `<div class="panel-h"><h3>${esc(title)}</h3><span class="md-age">${extra || ''}${fresh(f)}</span></div>`;

const STATUS = { online: ['ok', 'ui.mach.online'], maintenance: ['warn', 'ui.mach.maint'], lost: ['bad', 'ui.mach.lost'] };
const status = (s) => { const [d, k] = STATUS[s] || STATUS.lost; return `<span class="status"><span class="dot ${d}"></span>${esc(t(k))}</span>`; };

function loadBlock(v) {
  const l = v.load, m = v.mem;
  const trend = l.noTrend ? `<div class="ghostrow" style="font-size:12px">${esc(t('ui.mach.noTrend'))}</div>`
    : spark(l.hist, v.status === 'lost' ? 'var(--bad)' : 'var(--brand)', true);
  const note = l.shortMin != null ? `<div class="hint">${esc(t('ui.md.trendShort', { n: l.shortMin }))}</div>` : '';
  const unread = l.unread.length ? `<div class="hint" style="color:var(--warn)">${esc(t('ui.md.unread', { what: l.unread.join(' · ') }))}</div>` : '';
  const per = l.perCore == null ? '—' : l.perCore.toFixed(2);
  const mem = m.known ? `${m.used.toFixed(m.used < 10 ? 1 : 0)}/${m.total.toFixed(0)} GB` : '—';
  return `<div class="panel" id="md-load">${head(t('ui.md.load'), v.sysAt)}<div class="panel-b">` +
    `<div class="stats"><div><b>${esc(per)}</b>${esc(t('ui.md.perCore', { n: l.ncpu || '?' }))}</div><div><b>${esc(l.peak == null ? '—' : l.peak.toFixed(2))}</b>${esc(t('ui.md.peak'))}</div>` +
    `<div><b>${esc(mem)}</b>${esc(t('ui.md.mem'))}${m.pct == null ? '' : ` · ${m.pct}%`}</div></div>` +
    `<div class="md-trend">${trend}</div>${note}${unread}</div></div>`;
}

function versionBlock(v) {
  const x = v.version;
  const pair = (p) => (p ? `v${p.n}${p.rel ? ' · ' + p.rel : ''}` : '—');
  let rows = `<dt>${esc(t('ui.md.agent'))}</dt><dd class="mono">${esc(x.agent || '—')}</dd>` +
    `<dt>${esc(t('ui.md.fleet'))}</dt><dd class="mono">${esc(x.fleet || '—')}</dd>`;
  if (x.want || x.reached) {
    rows += `<dt>${esc(t('ui.mach.want'))}</dt><dd class="mono">${esc(pair(x.want))}</dd>` +
      `<dt>${esc(t('ui.mach.reached'))}</dt><dd class="mono"${x.behind ? ' style="color:var(--warn)"' : ''} title="${esc(x.diff)}">${esc(pair(x.reached))}</dd>`;
  }
  if (x.reported) {
    if (x.comps.length) {
      rows += `<dt>${esc(t('ui.md.comps'))}</dt><dd class="mono">${x.comps.map((c) => `<span${c.off ? ' style="color:var(--warn)"' : ''}>${esc(c.name)} ${esc(c.have || '—')}${c.off ? ` → ${esc(c.want)}` : ''}</span>`).join(' · ')}</dd>`;
    }
    if (x.phase || x.result) rows += `<dt>${esc(t('ui.md.update'))}</dt><dd>${esc([x.phase, x.result].filter(Boolean).join(' · '))}${x.reason ? `<br><span class="hint">${esc(x.reason)}</span>` : ''}</dd>`;
  } else {
    rows += `<dt>${esc(t('ui.md.update'))}</dt><dd class="hint">${esc(t('ui.md.tooOld'))}</dd>`;
  }
  return `<div class="panel" id="md-version">${head(t('ui.md.version'), v.versionAt)}<div class="panel-b"><dl class="kv">${rows}</dl></div></div>`;
}

function loginsBlock(v) {
  const body = v.logins.map((r) => {
    const st = r.refused ? `<span class="chip bad" title="${esc(r.refused)}">${esc(t('ui.md.refused'))}</span>`
      : r.status === 'online' ? `<span class="chip ok">${esc(t('ui.mach.online'))}</span>`
        : r.status === 'maintenance' ? `<span class="chip warn">${esc(t('ui.mach.maint'))}</span>` : `<span class="chip bad">${esc(t('ui.mach.lost'))}</span>`;
    return `<tr><td class="mono"><b>${esc(r.login)}</b></td><td>${st}${r.admit ? ` <span class="chip warn" title="${esc(r.admit)}">${esc(t('ui.my.paused'))}</span>` : ''}</td>` +
      `<td class="mono r">${r.sessions == null ? '?' : r.sessions}</td></tr>`;
  }).join('');
  const others = v.others ? `<tr><td colspan="3" class="hint">${esc(t('ui.md.others', { n: v.others }))}</td></tr>` : '';
  const empty = !v.logins.length && !v.others ? `<tr><td colspan="3" class="hint">—</td></tr>` : '';
  return `<div class="panel" id="md-logins">${head(t('ui.md.logins'), v.loginsAt)}<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.md.login'))}</th><th>${esc(t('ui.col.state'))}</th><th class="r">${esc(t('ui.mach.sessions'))}</th></tr></thead><tbody>${body}${others}${empty}</tbody></table></div></div>`;
}

function sessionsBlock(v) {
  const body = v.sessions.length ? v.sessions.map((r) => `<tr><td><div class="status"><span class="dot ${stateOf(r.state).dot}"></span><span><span class="sname">${esc(r.key)}</span><br><span class="repo">${esc(r.title || '—')}</span></span></div></td>` +
    `<td>${esc(stateOf(r.state).label)}</td><td class="mono">${esc(r.person || '—')}</td><td class="mono r">${esc(hhmm(r.born))}</td></tr>`).join('')
    : `<tr><td colspan="4" class="hint">${esc(t('ui.md.noSessions'))}</td></tr>`;
  return `<div class="panel" id="md-sessions">${head(t('ui.md.sessions'), v.sessionsAt, `<span class="hint">${v.sessions.length} ·</span>`)}<div class="tw md-scroll"><table class="t"><thead><tr><th>${esc(t('ui.col.session'))}</th><th>${esc(t('ui.col.state'))}</th><th>${esc(t('ui.md.login'))}</th><th class="r">${esc(t('ui.col.started'))}</th></tr></thead><tbody>${body}</tbody></table></div></div>`;
}

function servicesBlock(v) {
  const inner = v.services.length ? servicesSection(v.services) : `<div class="panel"><div class="panel-b hint">${esc(t('ui.md.noServices'))}</div></div>`;
  return `<section id="md-services"><div class="md-sh"><h3>${esc(t('ui.md.services'))}</h3>${fresh(v.servicesAt)}</div>${inner}</section>`;
}

function draw(ctx, v) {
  const back = backHref(location.search);
  const maint = v.maintenance ? `<span class="hint">${esc(t('ui.mach.maint'))}${v.maintenance.reason ? ' · ' + esc(v.maintenance.reason) : ''}</span>` : '';
  ctx.el.innerHTML = `<nav class="crumb" aria-label="${esc(t('ui.md.crumb'))}"><a href="${esc(back)}">${ic('server')}${esc(t(back === '/nodes' ? 'ui.nav.machines' : 'ui.nav.mymachines'))}</a><span>/</span><b>${esc(v.label)}</b>` +
    `${v.label !== v.name ? `<span class="mono" style="opacity:.6">${esc(v.name)}</span>` : ''}${status(v.status)}${maint}</nav>` +
    `<div class="grid g3 md-top">${loadBlock(v)}${versionBlock(v)}${loginsBlock(v)}</div>` +
    sessionsBlock(v) + servicesBlock(v) +
    // C5 (#2797) fills it: the services' logs, live.
    '<div id="md-logs"></div>';
}

function missing(ctx, name) {
  const back = backHref(location.search);
  ctx.el.innerHTML = `<div class="panel"><div class="empty">${ic('server')}<b>${esc(t('ui.md.none', { m: name }))}</b><span>${esc(t('ui.md.noneSub'))}</span><a class="btn" href="${esc(back)}">${esc(t('ui.md.back'))}</a></div></div>`;
}

export default Shell.mount('machine', async (ctx) => {
  const name = pathParam(location.pathname, routeFor(location.pathname));
  const load = async () => {
    let d;
    try {
      d = await ctx.api('/v1/nodes/' + encodeURIComponent(name));
    } catch (e) {
      if (e.status === 404) { missing(ctx, name); return; }
      throw e;
    }
    if (d.machine && d.machine.role === 'client') {
      // A client device has no machine page (C3): its place is the devices page.
      const to = clientRedirect(ctx.admin);
      history.replaceState(null, '', to);
      ctx.navigate(to);
      return;
    }
    const v = detailModel(d);
    S.svcs = v.services;
    draw(ctx, v);
  };
  ctx.el.onclick = (e) => { svcClick(ctx, e, S.svcs); };
  await load();
  ctx.every(10000, () => { if (!document.hidden) load().catch(() => {}); });
});
