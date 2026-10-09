// web/dist/lib/devices-view.js — the registered devices table, for two
// pages (claude-fleet#2515): Devices & SSH (/connect) lists the viewer's own,
// an admin's included; All devices (/admin/devices) lists every person's with
// an Owner column. Revoke is the same button on both: a person revokes their
// own, an admin any.
import { esc, ic, relTime } from './shell.js';
import { activeDevices } from './pages.js';
import { t, fmtDate } from './i18n.js';

const day = (iso) => fmtDate(iso, undefined, false);

/** devicesPanel draws /v1/fleet/devices (all=false) or /v1/admin/devices
 *  (all=true, with each device's owner). */
export function devicesPanel(devs, all) {
  const a = !!all;
  const list = (devs && devs.devices) || [];
  const cols = a ? 8 : 7;
  const rows = list.length ? list.map((d) => `<tr><td><div class="status">${ic('term')}<span><b style="font-weight:500">${esc(d.name || t('ui.dev.device'))}</b><br><span class="repo mono">${esc(d.fingerprint)}</span></span></div></td>` +
    (a ? `<td>${esc(d.principal_id || '—')}</td>` : '') +
    `<td class="mono">${esc(day(d.registered_at))}</td><td>${esc(relTime(d.last_used_at))}</td><td class="mono">${esc(d.last_machine || '—')}</td><td class="mono r">${Number(d.renewals) || 0}</td>` +
    `<td>${d.revoked_at ? `<span class="chip bad">${esc(t('ui.dev.revoked'))}</span>` : `<span class="chip ok">${esc(t('ui.dev.activeChip'))}</span>`}</td>` +
    `<td class="r">${d.revoked_at ? '' : `<button class="btn sm danger" data-revoke="${esc(d.fingerprint)}" data-name="${esc(d.name || d.fingerprint)}">${esc(t('ui.dev.revoke'))}</button>`}</td></tr>`).join('')
    : `<tr><td colspan="${cols}"><div class="empty">${ic('key')}<b>${esc(t('ui.dev.none'))}</b><span>${t('ui.dev.noneSub', { cmd: '<code>fleet login</code>' })}</span></div></td></tr>`;
  return `<div class="panel"><div class="panel-h"><h3>${esc(t(a ? 'ui.dev.all' : 'ui.dev.mine'))}</h3><span class="sub">${esc(t('ui.dev.active', { n: activeDevices(list).length }))}</span></div>` +
    `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.col.device'))}</th>${a ? `<th>${esc(t('ui.col.owner'))}</th>` : ''}<th>${esc(t('ui.col.registered'))}</th><th>${esc(t('ui.col.lastUsed'))}</th><th>${esc(t('ui.col.lastMachine'))}</th><th class="r">${esc(t('ui.col.renewals'))}</th><th>${esc(t('ui.col.status'))}</th><th></th></tr></thead><tbody>${rows}</tbody></table></div></div>`;
}

/** wireRevoke binds the panel's revoke buttons on ctx.el. */
export function wireRevoke(ctx) {
  ctx.el.querySelectorAll('[data-revoke]').forEach((b) => {
    b.onclick = () => ctx.confirm(t('ui.dev.revokeQ', { name: b.dataset.name }), t('ui.dev.revokeBody', { cmd: '<code>fleet login</code>' }), t('ui.dev.revokeBtn'), async () => {
      try {
        await ctx.api('/v1/fleet/devices/revoke', { json: { fingerprint: b.dataset.revoke } });
        ctx.toast(t('ui.dev.revokedToast', { name: b.dataset.name }));
        await ctx.refresh();
      } catch (e) { ctx.toast(t('ui.dev.revokeFail', { e: e.message })); }
    });
  });
}
