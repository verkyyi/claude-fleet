// web/dist/machines.js — 我的机器, at /machines (claude-fleet#2518): the
// machines the viewer's logins are on — each one's login, whether it takes
// sessions (开 · 只协调 · 暂停 · 维护中 · 离线), its load per core, and how many
// of the viewer's sessions run there. A person's own laptop reads 只协调.
//
// Below them, 服务与定时任务 (claude-fleet#2526): the background services and
// scheduled tasks registered under the viewer's logins (lib/services.js), a
// failed one red, a row opening its log's last line.
//
// Reads /v1/nodes (cut to the viewer's logins by the hub) and /v1/me.logins;
// writes nothing. Re-read every 30 s while the tab is visible and the page
// shown (the poll is the page's: leaving it stops it, claude-fleet#2793).
import { Shell } from './app-shell.js';
import { esc, ic } from './lib/shell.js';
import { myMachines } from './lib/pages.js';
import { serviceRows, servicesSection, svcClick } from './lib/services.js';
import { t } from './lib/i18n.js';

const S = { svcs: [] };

const CHIP = { on: 'ok', coord: '', paused: 'warn', maint: 'warn', lost: 'bad' };

function row(r) {
  const why = r.takes === 'coord' ? (r.why || t('ui.my.coordWhy')) : r.why;
  const takes = `<span class="chip ${CHIP[r.takes]}"${why ? ` title="${esc(why)}"` : ''}>${esc(t('ui.my.' + r.takes))}</span>`;
  const load = r.loadCore == null ? '—' : t('ui.my.perCore', { n: r.loadCore.toFixed(2) });
  const ses = r.sessions === null ? '—' : r.sessions === undefined ? '?' : String(r.sessions);
  return `<tr data-m="${esc(r.hostname)}"><td><b>${esc(r.label)}</b>${r.label !== r.hostname ? ` <span class="mono" style="opacity:.6">${esc(r.hostname)}</span>` : ''}</td>` +
    `<td class="mono">${esc(r.login)}</td><td>${takes}</td><td class="mono">${esc(load)}</td><td class="mono r">${esc(ses)}</td></tr>`;
}

function draw(ctx, rows, svcs) {
  const body = rows.length ? rows.map(row).join('')
    : `<tr><td colspan="5"><div class="empty">${ic('server')}<b>${esc(t('ui.my.none'))}</b><span>${esc(t('ui.my.noneSub'))}</span><a class="btn" href="/connect">${esc(t('ui.nav.devices'))}</a></div></td></tr>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.my.sub'))}</p></div></div>` +
    `<div class="panel"><div class="tw"><table class="t" id="mymachines"><thead><tr><th>${esc(t('ui.col.machine'))}</th><th>${esc(t('ui.my.colLogin'))}</th><th>${esc(t('ui.my.colTakes'))}</th><th>${esc(t('ui.my.colLoad'))}</th><th class="r">${esc(t('ui.my.colSessions'))}</th></tr></thead><tbody>${body}</tbody></table></div></div>` +
    servicesSection(svcs);
}

export default Shell.mount('mymachines', async (ctx) => {
  const load = async () => {
    const snap = await ctx.api('/v1/nodes');
    const rows = myMachines(snap, ctx.me);
    S.svcs = serviceRows(snap);
    draw(ctx, rows, S.svcs);
    ctx.setCount('mymachines', rows.length);
  };
  ctx.el.onclick = (e) => { svcClick(ctx, e, S.svcs); };
  await load();
  ctx.every(30000, () => { if (!document.hidden) load().catch(() => {}); });
});
