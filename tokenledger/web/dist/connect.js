// web/dist/connect.js — Devices & SSH, at /connect (claude-fleet#1989): the
// one-line install, a certificate issued by hand for a pasted public key, the
// viewer's own registered devices with revoke (an admin's too since
// claude-fleet#2515; everyone's is All devices, admin/devices.js), each
// machine's ways in, and the ~/.ssh/config snippet — from /v1/fleet/connect,
// /v1/fleet/devices (its audit folds under the table as the history,
// claude-fleet#2520) with /v1/nodes' client machines (claude-fleet#2795), POST /v1/fleet/cert and POST /v1/fleet/devices/revoke.
import { Shell } from './app-shell.js';
import { esc, ic } from './lib/shell.js';
import { looksLikeKey } from './lib/pages.js';
import { devicesPanel, historyPanel, wireRevoke } from './lib/devices-view.js';
import { t, fmtDate } from './lib/i18n.js';

const ttl = (sec) => (sec >= 3600 ? t('ui.dur.hours', { n: Math.round(sec / 3600) }) : t('ui.dur.minutes', { n: Math.round(sec / 60) }));
const failed = (e) => `<div class="ghostrow err">${ic('alert')} ${esc(e.message)}</div>`;

Shell.mount('devices', async (ctx) => {
  const [conn, devs, nodes] = await Promise.allSettled([ctx.api('/v1/fleet/connect'), ctx.api('/v1/fleet/devices'), ctx.api('/v1/nodes')]);
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
    (devs.status === 'fulfilled' ? devicesPanel(devs.value, false, nodes.status === 'fulfilled' ? nodes.value : null) + historyPanel(devs.value) : `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.dev.mine'))}</h3></div>${failed(devs.reason)}</div>`) +
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
  wireRevoke(ctx);
});
