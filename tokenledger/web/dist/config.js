// web/dist/config.js — Config, at /config (claude-fleet#1989): the settings
// that follow a person to every machine. My settings is the person layer
// (/v1/fleet/person-bundle: read, export to a file, import one back); Team
// settings is the team layer (/v1/fleet/team-bundle), read-only here to
// everyone — an admin publishes and restores it in Admin · Settings
// (claude-fleet#1990, moved there by #2515), and imports into their own layer
// here like anyone. Every PUT is a new version, audited by the hub. Order on
// every machine: fleet defaults, then team, then person; whatever is set
// locally wins.
import { Shell } from './app-shell.js';
import { esc, ic, relTime } from './lib/shell.js';
import { bundleItems, bundleList, parseImport } from './lib/pages.js';
import { t } from './lib/i18n.js';

const failed = (e) => `<div class="ghostrow err">${ic('alert')} ${esc(e.message)}</div>`;

function download(name, obj) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(obj, null, 2) + '\n'], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export default Shell.mount('config', async (ctx) => {
  const { me, admin } = ctx;
  // Everyone's own layer, an admin's included (claude-fleet#2515).
  const [pr, tr] = await Promise.allSettled([ctx.api('/v1/fleet/person-bundle?history=1'), ctx.api('/v1/fleet/team-bundle?history=1')]);
  const who = me.name || me.login || t('ui.me.you');

  let mine;
  if (pr.status === 'fulfilled') {
    const p = pr.value;
    mine = `<div class="panel"><div class="panel-h"><div><h3>${esc(t('ui.cfg.mine'))}</h3><span class="sub">${p.version ? `v${p.version} · ` : ''}${esc(t('ui.cfg.mineSub', { who }))}</span></div>` +
      `<div class="toolbar"><button class="btn sm" id="export">${esc(t('ui.cfg.export'))}</button><button class="btn sm" id="import">${esc(t('ui.cfg.import'))}</button><input type="file" id="importfile" accept="application/json,.json" hidden></div></div>` +
      bundleList(bundleItems(p.bundle), 'mine') + '</div>';
  } else if (pr.reason.status === 404) {
    mine = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.cfg.mine'))}</h3></div><div class="empty">${ic('sliders')}<b>${esc(t('ui.cfg.noLayer'))}</b><span>${esc(pr.reason.message)}</span></div></div>`;
  } else {
    mine = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.cfg.mine'))}</h3></div>${failed(pr.reason)}</div>`;
  }

  let team, hist = '';
  if (tr.status === 'fulfilled') {
    const tb = tr.value;
    team = `<div class="panel"><div class="panel-h"><div><h3>${esc(t('ui.cfg.team'))}</h3><span class="sub">${tb.version ? `v${tb.version} · ` : ''}${esc(t('ui.cfg.teamSub'))}</span></div>` +
      (admin ? `<a class="chip" href="/admin/settings#team">${ic('lock')}${esc(t('ui.cfg.publishIn'))}</a>`
        : `<span class="chip">${ic('lock')}${esc(t('ui.cfg.adminsPublish'))}</span>`) + '</div>' + bundleList(bundleItems(tb.bundle), 'team') + '</div>';
    if (Array.isArray(tb.history) && tb.history.length) {
      hist = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.cfg.history'))}</h3><span class="sub">${esc(t('ui.cfg.historySub'))}</span></div><div class="panel-b"><div class="timeline">` +
        tb.history.map((h) => {
          const v = Number(h.version) || 0;
          return `<div><b>v${v}</b>${h.note ? ' · ' + esc(h.note) : ''}<span>${esc(h.actor || '—')} · ${esc(relTime(h.created))}</span></div>`;
        }).join('') + '</div></div></div>';
    }
  } else {
    team = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.cfg.team'))}</h3></div>${failed(tr.reason)}</div>`;
  }

  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.cfg.lead'))}</p></div></div>` +
    `<div class="grid g2">${mine}${team}</div>${hist}`;

  const ex = ctx.el.querySelector('#export');
  if (ex) ex.onclick = () => { download('my-settings.json', { version: pr.value.version, bundle: pr.value.bundle || {} }); ctx.toast(t('ui.cfg.exported', { file: 'my-settings.json' })); };
  const im = ctx.el.querySelector('#import');
  const file = ctx.el.querySelector('#importfile');
  if (im && file) {
    im.onclick = () => file.click();
    file.onchange = async () => {
      const f = file.files && file.files[0];
      if (!f) return;
      try {
        const bundle = parseImport(await f.text());
        await ctx.api('/v1/fleet/person-bundle', { method: 'PUT', json: { bundle, base: pr.value.version || 0, note: `Imported ${f.name}` } });
        ctx.toast(t('ui.cfg.imported'));
        await ctx.refresh();
      } catch (e) { ctx.toast(t('ui.cfg.importFail', { e: e.message })); }
    };
  }
});
