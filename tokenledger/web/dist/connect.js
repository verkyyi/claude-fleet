// web/dist/connect.js — Devices & SSH, at /connect (claude-fleet#1989): the
// one-line install, a certificate issued by hand for a pasted public key, the
// registered devices (a user's own, an admin's everyone's) with revoke, each
// machine's ways in, and the ~/.ssh/config snippet — from /v1/fleet/connect,
// /v1/fleet/devices, POST /v1/fleet/cert and POST /v1/fleet/devices/revoke.
import { Shell } from './app-shell.js';
import { esc, ic, relTime } from './lib/shell.js';
import { activeDevices, looksLikeKey } from './lib/pages.js';
import { t, fmtDate } from './lib/i18n.js';

const day = (iso) => fmtDate(iso, undefined, false);
const ttl = (sec) => (sec >= 3600 ? t('ui.dur.hours', { n: Math.round(sec / 3600) }) : t('ui.dur.minutes', { n: Math.round(sec / 60) }));
const failed = (e) => `<div class="ghostrow err">${ic('alert')} ${esc(e.message)}</div>`;

function devicesPanel(ctx, devs) {
  const a = ctx.admin;
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

Shell.mount('devices', async (ctx) => {
  const [conn, devs] = await Promise.allSettled([ctx.api('/v1/fleet/connect'), ctx.api('/v1/fleet/devices')]);
  const c = conn.status === 'fulfilled' ? conn.value : null;
  const hours = ttl((c && c.cert_ttl_sec) || 43200);
  const install = c && c.install_command;

  const connectPanel = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.connect'))}</h3></div><div class="panel-b" style="display:grid;gap:12px">` +
    (install && c.install_ready !== false
      ? `<div class="cmdbox"><span>${esc(install)}</span><button class="btn sm" data-shell="copy" data-text="${esc(install)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div><p style="font-size:13px;color:var(--muted)">${t('ui.dev.thenLogin', { cmd: '<code>fleet login</code>' })}</p>`
      : `<p style="font-size:13px;color:var(--muted)">${esc((c && c.problem) || (conn.status === 'rejected' ? conn.reason.message : t('ui.dev.notReady')))}</p>`) + '</div></div>';

  const certPanel = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.byHand'))}</h3></div><div class="panel-b" style="display:grid;gap:10px">` +
    (c && c.ca_enabled === false ? `<p style="font-size:13px;color:var(--muted)">${esc(t('ui.dev.noCA'))}</p>`
      : `<label class="f">${esc(t('ui.dev.pubkey'))}<input class="input mono" id="pubkey" placeholder="ssh-ed25519 AAAAC3Nza… you@laptop" autocomplete="off" spellcheck="false"></label>` +
        `<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap"><button class="btn" id="cert">${esc(t('ui.dev.issue'))}</button><span style="font-size:12.5px;color:var(--muted)">${esc(t('ui.dev.validNote', { ttl: hours }))}</span></div><div id="certout" hidden></div>`) + '</div></div>';

  const machines = (c && c.machines) || [];
  const routeRows = machines.flatMap((m) => (m.routes && m.routes.length ? m.routes : [{ name: '—', host: '' }]).map((r) => `<tr><td class="mono">${esc(m.alias || m.hostname)}</td><td>${esc(r.name)}</td><td class="mono">${esc(r.host ? r.host + (r.port ? ':' + r.port : '') : '—')}</td></tr>`)).join('');
  const routes = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.ways'))}</h3></div>` + (c
    ? (routeRows ? `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.col.machine'))}</th><th>${esc(t('ui.col.route'))}</th><th>${esc(t('ui.col.address'))}</th></tr></thead><tbody>${routeRows}</tbody></table></div>` : `<div class="empty">${ic('server')}<b>${esc(t('ui.dev.noMachines'))}</b><span>${esc(t(ctx.admin ? 'ui.dev.noMachinesAdmin' : 'ui.dev.noMachinesUser'))}</span></div>`)
    : failed(conn.reason)) + '</div>';
  const cfg = c && c.ssh_config ? c.ssh_config : '';
  const snippet = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.sshConfig'))}</h3>${cfg ? `<button class="btn sm" data-shell="copy" data-text="${esc(cfg)}">${ic('copy')}${esc(t('ui.copy'))}</button>` : ''}</div><div class="panel-b">` +
    (cfg ? `<pre class="out">${esc(cfg)}</pre>${c.config_path ? `<p style="font-size:12.5px;color:var(--muted);margin-top:8px">${t('ui.dev.goesIn', { path: `<code>${esc(c.config_path)}</code>` })}</p>` : ''}` : `<div class="ghostrow">${esc(t('ui.dev.nothingCfg'))}</div>`) + '</div></div>';

  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.dev.lead', { ttl: hours }))}</p></div></div>` +
    `<div class="grid g2">${connectPanel}${certPanel}</div>` +
    (devs.status === 'fulfilled' ? devicesPanel(ctx, devs.value) : `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.mine'))}</h3></div>${failed(devs.reason)}</div>`) +
    `<div class="grid g2">${routes}${snippet}</div>`;

  const btn = ctx.el.querySelector('#cert');
  if (btn) btn.onclick = async () => {
    const key = ctx.el.querySelector('#pubkey').value.trim();
    const out = ctx.el.querySelector('#certout');
    if (!looksLikeKey(key)) { ctx.toast(t('ui.dev.badKey')); return; }
    btn.disabled = true;
    try {
      const r = await ctx.api('/v1/fleet/cert', { json: { public_key: key } });
      out.hidden = false;
      out.innerHTML = `<label class="f">${esc(t('ui.dev.certUntil', { t: fmtDate(r.valid_before) }))}<textarea class="input" readonly rows="4">${esc(r.certificate)}</textarea></label>` +
        `<button class="btn sm" data-shell="copy" data-text="${esc(r.certificate)}" style="margin-top:8px">${ic('copy')}${esc(t('ui.dev.copyCert'))}</button>`;
      ctx.toast(t('ui.dev.issued', { ttl: hours }));
    } catch (e) {
      out.hidden = false; out.innerHTML = `<p class="err" style="font-size:13px">${esc(e.message)}</p>`;
    } finally { btn.disabled = false; }
  };
  ctx.el.querySelectorAll('[data-revoke]').forEach((b) => {
    b.onclick = () => ctx.confirm(t('ui.dev.revokeQ', { name: b.dataset.name }), t('ui.dev.revokeBody', { cmd: '<code>fleet login</code>' }), t('ui.dev.revokeBtn'), async () => {
      try {
        await ctx.api('/v1/fleet/devices/revoke', { json: { fingerprint: b.dataset.revoke } });
        ctx.toast(t('ui.dev.revokedToast', { name: b.dataset.name }));
        await ctx.refresh();
      } catch (e) { ctx.toast(t('ui.dev.revokeFail', { e: e.message })); }
    });
  });
});
