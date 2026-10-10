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
// page. Re-read every 10 s while the tab is visible and the page shown.
//
// 日志 (C5, claude-fleet#2797): a click on a service or task row follows its
// log below (lib/svc-log.js) — the last 200 lines within seconds, new ones as
// they come; scrolled up it stops following (and loads earlier pages at the
// top), back at the bottom it follows again; ↑ ↓ PageUp PageDown scroll it.
// 操作… opens the row's drawer (lib/services.js). The choice rides the URL
// (?log=<login>/<name>), so a reload keeps it; the panel lives outside the
// 10 s redraw, so a re-read never resets the lines.
import { Shell, api } from './app-shell.js';
import { esc, ic, spark, freshTag } from './lib/shell.js';
import { routeFor, pathParam } from './lib/router.js';
import { detailModel, backHref, clientRedirect } from './lib/machine-view.js';
import { servicesSection, logDrawer, svcDrawerClick } from './lib/services.js';
import { createLog, logPath, atBottom, MAX_LINES } from './lib/svc-log.js';
import { stateOf, hhmm } from './lib/pages.js';
import { t } from './lib/i18n.js';

const S = { svcs: [], host: '', sel: null, log: null };

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
  main(ctx).innerHTML = `<nav class="crumb" aria-label="${esc(t('ui.md.crumb'))}"><a href="${esc(back)}">${ic('server')}${esc(t(back === '/nodes' ? 'ui.nav.machines' : 'ui.nav.mymachines'))}</a><span>/</span><b>${esc(v.label)}</b>` +
    `${v.label !== v.name ? `<span class="mono" style="opacity:.6">${esc(v.name)}</span>` : ''}${status(v.status)}${maint}</nav>` +
    `<div class="grid g3 md-top">${loadBlock(v)}${versionBlock(v)}${loginsBlock(v)}</div>` +
    sessionsBlock(v) + servicesBlock(v);
  for (const tr of ctx.el.querySelectorAll('tr[data-svc]')) {
    const r = S.svcs[Number(tr.dataset.svc)];
    if (r && S.sel && r.login === S.sel.login && r.name === S.sel.name) tr.setAttribute('aria-selected', 'true');
  }
}

// main is the redrawn part of the page; the log panel beside it is drawn once.
function main(ctx) {
  let m = ctx.el.querySelector('#md-main');
  if (!m) {
    ctx.el.innerHTML = `<div id="md-main"></div>${logPanel()}`;
    m = ctx.el.querySelector('#md-main');
  }
  return m;
}

// ---- 日志 --------------------------------------------------------------

function logPanel() {
  return `<section class="panel" id="md-logs"><div class="panel-h"><div><h3>${esc(t('ui.log.title'))}</h3>` +
    `<span class="sub" id="md-log-what">${esc(t('ui.log.pick'))}</span></div>` +
    `<span class="md-age"><span id="md-log-st"></span>` +
    `<label class="md-follow" hidden><input type="checkbox" id="md-log-follow" checked> ${esc(t('ui.log.follow'))}</label>` +
    `<button class="btn sm ghost" id="md-log-more" hidden>${esc(t('ui.log.more'))}</button></span></div>` +
    `<pre class="logbox" id="md-log-box" tabindex="0" hidden></pre></section>`;
}

const hms = (ms) => { const d = new Date(ms); return [d.getHours(), d.getMinutes(), d.getSeconds()].map((n) => String(n).padStart(2, '0')).join(':'); };

function lineHTML(l) {
  if (l.skipped) return `<div class="ll skip">${esc(t('ui.log.skipped', { n: l.skipped }))}</div>`;
  return `<div class="ll">${l.ts ? `<span class="lt">${esc(hms(l.ts))}</span>` : ''}${esc(l.text) || ' '}</div>`;
}

function topHTML(st) {
  const k = st.start ? 'ui.log.begin' : st.lines.length >= MAX_LINES ? 'ui.log.cap' : 'ui.log.older';
  return `<div class="ll lhead" id="md-log-top">${esc(t(k, { n: MAX_LINES, cmd: S.sel ? `fleet ${S.sel.kind === 'task' ? 'task' : 'service'} logs ${S.sel.name}` : '' }))}</div>`;
}

function logStatus(st) {
  const el = document.getElementById('md-log-st');
  if (!el) return;
  const word = st.mode === 'live' ? '' : t('ui.log.st.' + (st.mode === 'refused' ? st.why : st.mode));
  const cls = st.mode === 'live' ? 'ok' : st.mode === 'refused' ? 'bad' : 'warn';
  el.innerHTML = (word ? `<span class="chip ${cls}">${esc(word)}</span> ` : `<span class="chip ok">${esc(t('ui.log.st.live'))}</span> `) +
    (st.lastAt ? freshTag(st.lastAt) : '');
  const f = document.getElementById('md-log-follow');
  if (f) f.checked = st.follow;
}

function onLog(kind, lines, st) {
  const box = document.getElementById('md-log-box');
  if (!box) return;
  if (kind === 'status') {
    // Refused (another login's, gone): the box says so instead of waiting.
    if (st.mode === 'refused') box.innerHTML = `<div class="ll lhead">${esc(t('ui.log.st.' + st.why))}</div>`;
    logStatus(st);
    return;
  }
  if (kind === 'reset') {
    box.innerHTML = topHTML(st) + (lines.length ? lines.map(lineHTML).join('') : `<div class="ll lhead">${esc(t('ui.log.empty'))}</div>`);
  } else if (kind === 'append') {
    const empty = box.querySelector('.ll.lhead:not(#md-log-top)');
    if (empty) empty.remove();
    box.insertAdjacentHTML('beforeend', lines.map(lineHTML).join(''));
  } else if (kind === 'prepend') {
    const h0 = box.scrollHeight;
    const top = document.getElementById('md-log-top');
    if (top) top.remove();
    box.insertAdjacentHTML('afterbegin', topHTML(st) + lines.map(lineHTML).join(''));
    box.scrollTop += box.scrollHeight - h0;
    logStatus(st);
    return;
  }
  if (st.follow) box.scrollTop = box.scrollHeight;
  logStatus(st);
}

// pick follows row r's log (null: none), and says so in the URL.
function pick(ctx, r) {
  if (S.log) { S.log.stop(); S.log = null; }
  S.sel = r;
  const q = new URLSearchParams(location.search);
  if (r) q.set('log', r.login + '/' + r.name); else q.delete('log');
  const qs = q.toString();
  history.replaceState(history.state, '', location.pathname + (qs ? '?' + qs : '') + location.hash);
  for (const tr of ctx.el.querySelectorAll('tr[data-svc]')) {
    const x = S.svcs[Number(tr.dataset.svc)];
    if (r && x && x.login === r.login && x.name === r.name) tr.setAttribute('aria-selected', 'true'); else tr.removeAttribute('aria-selected');
  }
  const box = document.getElementById('md-log-box');
  const what = document.getElementById('md-log-what');
  const follow = ctx.el.querySelector('.md-follow');
  const more = document.getElementById('md-log-more');
  if (!box) return;
  box.hidden = !r; if (follow) follow.hidden = !r; if (more) more.hidden = !r;
  if (what) what.textContent = r ? `${r.login} · ${r.name} · ${t('ui.svc.kind.' + r.kind)}` : t('ui.log.pick');
  box.innerHTML = '';
  const st = document.getElementById('md-log-st'); if (st) st.innerHTML = '';
  if (!r) return;
  box.innerHTML = `<div class="ll lhead">${esc(t('ui.log.loading'))}</div>`;
  const url = logPath(S.host, r.login, r.name);
  S.log = createLog({
    url,
    head: async (u) => { try { await api(u, { method: 'HEAD' }); return 200; } catch (e) { return e.status || 0; } },
    getJSON: (u) => api(u),
    onChange: onLog,
  });
  S.log.start();
}

function wireLog(ctx) {
  const box = document.getElementById('md-log-box');
  const follow = document.getElementById('md-log-follow');
  const more = document.getElementById('md-log-more');
  if (box) {
    ctx.on(box, 'scroll', () => {
      if (!S.log) return;
      S.log.setFollow(atBottom(box));
      if (box.scrollTop < 40 && S.log.canOlder()) S.log.older();
    }, { passive: true });
  }
  if (follow) {
    ctx.on(follow, 'change', () => {
      if (!S.log) return;
      S.log.setFollow(follow.checked);
      if (follow.checked && box) box.scrollTop = box.scrollHeight;
    });
  }
  if (more) {
    ctx.on(more, 'click', () => {
      const r = S.sel;
      if (!r) return;
      ctx.drawer(logDrawer(r));
      const d = document.querySelector('#layer .drawer');
      if (d) d.onclick = (ev) => { svcDrawerClick(ctx, ev, r, d); };
    });
  }
}

function missing(ctx, name) {
  const back = backHref(location.search);
  main(ctx).innerHTML = `<div class="panel"><div class="empty">${ic('server')}<b>${esc(t('ui.md.none', { m: name }))}</b><span>${esc(t('ui.md.noneSub'))}</span><a class="btn" href="${esc(back)}">${esc(t('ui.md.back'))}</a></div></div>`;
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
    S.host = (d.machine && d.machine.hostname) || name;
    const first = !ctx.el.querySelector('#md-main');
    draw(ctx, v);
    if (first) {
      wireLog(ctx);
      // ?log=<login>/<name>: the log a reload (or a shared link) was on.
      const want = new URLSearchParams(location.search).get('log');
      const r = want && S.svcs.find((x) => x.login + '/' + x.name === want);
      if (r) pick(ctx, r);
    }
  };
  // A row picks its log; the same row again keeps it.
  ctx.el.onclick = (e) => {
    const tr = e.target && e.target.closest ? e.target.closest('tr[data-svc]') : null;
    const r = tr ? S.svcs[Number(tr.dataset.svc)] : null;
    if (r && !(S.sel && S.sel.login === r.login && S.sel.name === r.name)) pick(ctx, r);
    if (r) { const p = document.getElementById('md-logs'); if (p && p.scrollIntoView) p.scrollIntoView({ block: 'nearest' }); }
  };
  stopLog();
  await load();
  ctx.every(10000, () => { if (!document.hidden) load().catch(() => {}); });
}, { dispose: stopLog });

// stopLog ends the follow: the page left, or drawn again from scratch.
function stopLog() {
  if (S.log) S.log.stop();
  S.log = null; S.sel = null;
}
