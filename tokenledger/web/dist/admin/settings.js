// web/dist/admin/settings.js — Settings, at /admin/settings (claude-fleet#1990):
// the hub's own settings, stored in its database and applied at once, every
// change one audit row (hub_settings.go). Public counter and badges, the
// subscription pool's skip threshold and failover, which machines a new
// person gets a login on, SPOT machines — and, read-only, what the deploy
// sets (the admins, the ways in from /v1/access) — and the team settings
// layer (/v1/fleet/team-bundle): publish a file as its next version, restore
// an older one (claude-fleet#1990; here since #2515 — Config shows it to
// everyone read-only). An admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, relTime } from '../lib/shell.js';
import { SETTING_GROUPS, settingValue } from '../lib/admin.js';
import { bundleItems, bundleList, parseImport } from '../lib/pages.js';
import { t } from '../lib/i18n.js';

export default Shell.mount('settings', async (ctx) => {
  const [setR, usR, acR, tr] = await Promise.allSettled([ctx.api('/v1/fleet/settings'), ctx.api('/v1/fleet/users'), ctx.api('/v1/access'), ctx.api('/v1/fleet/team-bundle?history=1')]);
  if (setR.status === 'rejected') throw setR.reason;
  const answer = setR.value;
  const row = (it) => {
    const { value, source } = settingValue(answer, it.key);
    const src = source === 'default' ? `<span class="chip">${esc(t('ui.set.default'))}</span>` : source === 'legacy' ? `<span class="chip warn">${esc(t('ui.set.legacy'))}</span>` : '';
    const name = t('ui.set.k.' + it.key), help = t('ui.set.h.' + it.key);
    let ctl;
    if (it.type === 'onoff') ctl = `<button class="switch" role="switch" aria-checked="${value === 'on'}" data-key="${esc(it.key)}" aria-label="${esc(name)}"></button>`;
    else if (it.type === 'pct') ctl = `<span class="numin"><input class="input" data-key="${esc(it.key)}" value="${esc(value)}" inputmode="numeric" aria-label="${esc(name)}">%</span>`;
    else if (it.type === 'count') ctl = `<span class="numin"><input class="input" data-key="${esc(it.key)}" value="${esc(value)}" inputmode="numeric" aria-label="${esc(name)}"></span>`;
    else ctl = `<span class="numin"><input class="input mono" style="width:14rem;text-align:left" data-key="${esc(it.key)}" value="${esc(value)}" placeholder="${it.type === 'names' ? 'macmini=m5, mini2=m4' : 'mini2, m4'}" aria-label="${esc(name)}"></span>`;
    return `<div><div class="l"><b>${esc(name)} ${src}</b><span>${esc(help)} · <code>${esc(it.key)}</code></span></div>${ctl}</div>`;
  };
  const groups = SETTING_GROUPS.map((g) => `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.set.g.' + g.id))}</h3></div><div class="setlist">${g.items.map(row).join('')}</div></div>`).join('');

  const admins = usR.status === 'fulfilled' ? (usR.value.admins || []).map((a) => a.login).join(', ') : '';
  const access = acR.status === 'fulfilled' ? acR.value : null;
  const ghOn = access && access.hub ? !!access.hub.github : null;
  const deploy = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.set.g.deploy'))}</h3></div><div class="setlist">` +
    `<div><div class="l"><b>${esc(t('ui.set.admins'))}</b><span>CCQUOTA_GITHUB_ADMINS</span></div><span class="envlock">${ic('lock')}${esc(admins || '—')}</span></div>` +
    `<div><div class="l"><b>${esc(t('ui.set.ghApp'))}</b><span>${esc(t('ui.set.ghAppSub'))}</span></div><span class="envlock">${ic('lock')}${esc(ghOn == null ? '—' : t(ghOn ? 'ui.set.configured' : 'ui.set.notConfigured'))}</span></div>` +
    `<div><div class="l"><b>${esc(t('ui.set.secrets'))}</b><span>${esc(t('ui.set.secretsSub'))}</span></div><span class="envlock">${ic('lock')}${esc(t('ui.set.k8s'))}</span></div></div></div>`;

  // The team layer: every machine's defaults under each person's own.
  let team = '';
  if (tr.status === 'fulfilled') {
    const tb = tr.value;
    const hist = Array.isArray(tb.history) && tb.history.length
      ? `<div class="panel-b"><div class="timeline">` + tb.history.map((h) => {
        const v = Number(h.version) || 0;
        const restore = v && v !== Number(tb.version) ? `<button class="btn sm" style="margin-top:6px" data-restore="${v}">${esc(t('ui.cfg.restore', { v }))}</button>` : '';
        return `<div><b>v${v}</b>${h.note ? ' · ' + esc(h.note) : ''}<span>${esc(h.actor || '—')} · ${esc(relTime(h.created))}</span>${restore}</div>`;
      }).join('') + '</div></div>' : '';
    team = `<div class="panel" id="team"><div class="panel-h"><div><h3>${esc(t('ui.cfg.team'))}</h3><span class="sub">${tb.version ? `v${tb.version} · ` : ''}${esc(t('ui.cfg.teamSub'))}</span></div>` +
      `<div class="toolbar"><button class="btn sm primary" id="publish">${esc(t('ui.cfg.publish'))}</button><input type="file" id="publishfile" accept="application/json,.json" hidden></div></div>` +
      bundleList(bundleItems(tb.bundle), 'team') + hist + '</div>';
  } else if (tr.reason.status !== 404) {
    team = `<div class="panel" id="team"><div class="panel-h"><h3>${esc(t('ui.cfg.team'))}</h3></div><div class="ghostrow err">${ic('alert')} ${esc(tr.reason.message)}</div></div>`;
  }

  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.set.lead'))}</p></div></div>${groups}${team}${deploy}`;

  // Publish a file as the team layer's next version, or restore an older one
  // as a new version.
  const base = tr.status === 'fulfilled' ? tr.value.version || 0 : 0;
  const pub = ctx.el.querySelector('#publish');
  const pubFile = ctx.el.querySelector('#publishfile');
  if (pub && pubFile) {
    pub.onclick = () => pubFile.click();
    pubFile.onchange = async () => {
      const f = pubFile.files && pubFile.files[0];
      if (!f) return;
      try {
        const bundle = parseImport(await f.text());
        const out = await ctx.api('/v1/fleet/team-bundle', { method: 'PUT', json: { bundle, base, note: `Published ${f.name}` } });
        ctx.toast(t('ui.cfg.published', { v: (out && out.version) || '' }));
        await ctx.refresh();
      } catch (e) { ctx.toast(t('ui.cfg.importFail', { e: e.message })); }
    };
  }
  ctx.el.querySelectorAll('[data-restore]').forEach((b) => {
    b.onclick = () => {
      const v = Number(b.dataset.restore);
      ctx.confirm(t('ui.cfg.restoreQ', { v }), esc(t('ui.cfg.restoreBody', { v })), t('ui.cfg.restore', { v }), async () => {
        try {
          const out = await ctx.api('/v1/fleet/team-bundle', { method: 'PUT', json: { restore: v, base } });
          ctx.toast(t('ui.cfg.restored', { v, n: (out && out.version) || '' }));
          await ctx.refresh();
        } catch (e) { ctx.toast(t('ui.err.action', { e: e.message })); }
      });
    };
  });

  const put = async (key, value) => {
    try {
      await ctx.api('/v1/fleet/settings', { method: 'PUT', json: { key, value } });
      ctx.toast(t('ui.set.saved'));
    } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
    await ctx.refresh();
  };
  ctx.el.onclick = (e) => {
    const b = e.target.closest('button.switch[data-key]');
    if (b) put(b.dataset.key, b.getAttribute('aria-checked') === 'true' ? 'off' : 'on');
  };
  ctx.el.onchange = (e) => {
    const i = e.target.closest('input[data-key]');
    if (i) put(i.dataset.key, i.value.trim());
  };
});
