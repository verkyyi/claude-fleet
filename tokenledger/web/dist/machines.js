// web/dist/machines.js — 我的机器, at /machines (claude-fleet#2518): the
// machines the viewer's logins are on — each one's login, whether it takes
// sessions (开 · 只协调 · 暂停 · 维护中 · 离线), its load per core, and how many
// of the viewer's sessions run there. A person's own laptop reads 只协调.
//
// Below them, 服务与定时任务 (claude-fleet#2526): the background services and
// scheduled tasks registered under the viewer's logins (lib/services.js), a
// failed one red, a row opening its log's last line.
//
// A row opens the machine's page, /machines/<host> (claude-fleet#2796): a
// click, or j/k to pick and ↵.
//
// Reads /v1/nodes (cut to the viewer's logins by the hub) and /v1/me.logins;
// writes nothing. It moves by itself (claude-fleet#2794): every `nodes` answer
// of the push channel — the same roster, cut the same way — redraws it, and
// the head says how old it is (leaving the page drops it, claude-fleet#2793).
import { Shell } from './app-shell.js';
import { esc, ic, freshTag } from './lib/shell.js';
import { observedOf } from './lib/stream.js';
import { myMachines } from './lib/pages.js';
import { serviceRows, servicesSection, svcClick } from './lib/services.js';
import { machineHref, listNav } from './lib/machine-view.js';
import { t } from './lib/i18n.js';

const S = { svcs: [] };

const CHIP = { on: 'ok', coord: '', paused: 'warn', maint: 'warn', lost: 'bad' };

function row(r) {
  const why = r.takes === 'coord' ? (r.why || t('ui.my.coordWhy')) : r.why;
  const takes = `<span class="chip ${CHIP[r.takes]}"${why ? ` title="${esc(why)}"` : ''}>${esc(t('ui.my.' + r.takes))}</span>`;
  const load = r.loadCore == null ? '—' : t('ui.my.perCore', { n: r.loadCore.toFixed(2) });
  const ses = r.sessions === null ? '—' : r.sessions === undefined ? '?' : String(r.sessions);
  // One click (or j/k + ↵) into the machine's page (claude-fleet#2796).
  const href = machineHref(r.hostname);
  return `<tr class="click" data-m="${esc(r.hostname)}" data-href="${esc(href)}" tabindex="0"><td><a href="${esc(href)}"><b>${esc(r.label)}</b></a>${r.label !== r.hostname ? ` <span class="mono" style="opacity:.6">${esc(r.hostname)}</span>` : ''}</td>` +
    `<td class="mono">${esc(r.login)}</td><td>${takes}</td><td class="mono">${esc(load)}</td><td class="mono r">${esc(ses)}</td></tr>`;
}

function draw(ctx, rows, svcs, at) {
  const body = rows.length ? rows.map(row).join('')
    : `<tr><td colspan="5"><div class="empty">${ic('server')}<b>${esc(t('ui.my.none'))}</b><span>${esc(t('ui.my.noneSub'))}</span><a class="btn" href="/connect">${esc(t('ui.nav.devices'))}</a></div></td></tr>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.my.sub'))}</p></div>${freshTag(at)}</div>` +
    `<div class="panel"><div class="tw"><table class="t" id="mymachines"><thead><tr><th>${esc(t('ui.col.machine'))}</th><th>${esc(t('ui.my.colLogin'))}</th><th>${esc(t('ui.my.colTakes'))}</th><th>${esc(t('ui.my.colLoad'))}</th><th class="r">${esc(t('ui.my.colSessions'))}</th></tr></thead><tbody>${body}</tbody></table></div></div>` +
    servicesSection(svcs);
}

export default Shell.mount('mymachines', async (ctx) => {
  const show = (snap, at) => {
    const rows = myMachines(snap, ctx.me);
    S.svcs = serviceRows(snap);
    // A pushed redraw keeps the row j/k picked (claude-fleet#2794).
    const a = document.activeElement;
    const picked = a && ctx.el.contains(a) && a.dataset ? a.dataset.m : '';
    draw(ctx, rows, S.svcs, at);
    if (picked) { const r = [...ctx.el.querySelectorAll('#mymachines tr[data-m]')].find((x) => x.dataset.m === picked); if (r) r.focus(); }
    ctx.setCount('mymachines', rows.length);
  };
  ctx.el.onclick = (e) => { svcClick(ctx, e, S.svcs); };
  listNav(ctx, '#mymachines tr[data-href]');
  const snap = await ctx.api('/v1/nodes');
  show(snap, observedOf('nodes', snap));
  ctx.subscribe('nodes', (e) => { if (e.body) show(e.body, e.observedAt); });
});
