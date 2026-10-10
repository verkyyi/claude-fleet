// web/dist/config.js — Config, at /config (claude-fleet#1989): the settings
// that follow a person to every machine. My settings is the person layer
// (/v1/fleet/person-bundle: read, export to a file, import one back); Team
// settings is the team layer (/v1/fleet/team-bundle), read-only here to
// everyone — an admin publishes and restores it in Admin · Settings
// (claude-fleet#1990, moved there by #2515), and imports into their own layer
// here like anyone. Every PUT is a new version, audited by the hub. Order on
// every machine: fleet defaults, then team, then person; whatever is set
// locally wins. 角色与规则 (claude-fleet#2787) is the person layer's roles +
// rule table, merged by the hub (/v1/fleet/person-bundle/roles?merged=1) and
// edited here field by field — the same layer `fleet role` edits in a session.
import { Shell } from './app-shell.js';
import { esc, ic, relTime } from './lib/shell.js';
import { bundleItems, bundleList, parseImport } from './lib/pages.js';
import { t } from './lib/i18n.js';
import { ROLES, layerOf, setField, withRoleLayer, listEdit, listUndo, setBody, setRuleTier, resetRule, roleCard, roleDetail, rulesTable } from './lib/roles-view.js';

// The role the cards point at, kept across a refresh.
let selRole = ROLES[0];

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
  const [pr, tr, rr] = await Promise.allSettled([ctx.api('/v1/fleet/person-bundle?history=1'), ctx.api('/v1/fleet/team-bundle?history=1'),
    ctx.api('/v1/fleet/person-bundle/roles?merged=1')]);
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

  // 角色与规则 + my history: only with a layer to edit (a login bound to no one has none).
  let roles = '', myHist = '';
  if (rr.status === 'fulfilled' && pr.status === 'fulfilled') {
    const v = rr.value;
    const sub = v.note ? esc(v.note) : esc(t('ui.roles.sub', { sha: String(v.stable || '').slice(0, 7), v: v.rules && v.rules.version ? v.rules.version : '—' }));
    roles = `<div class="panel" id="roles-panel"><div class="panel-h"><div><h3>${esc(t('ui.roles.title'))}</h3><span class="sub">${sub}</span></div>` +
      `<span class="chip">${esc(t('ui.roles.nextSession'))}</span></div><div class="panel-b" id="roles"></div>` +
      `<div class="panel-h"><div><h3>${esc(t('ui.roles.rules'))}</h3><span class="sub">${esc(t('ui.roles.rulesSub'))}</span></div></div>` +
      `<div id="rules">${rulesTable(v.rules, pr.value.bundle)}</div></div>`;
    const ph = Array.isArray(pr.value.history) ? pr.value.history : [];
    if (ph.length) {
      myHist = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.roles.history'))}</h3><span class="sub">${esc(t('ui.roles.historySub'))}</span></div><div class="panel-b"><div class="timeline">` +
        ph.map((h) => {
          const n = Number(h.version) || 0;
          const cur = n === Number(pr.value.version);
          return `<div><b>v${n}</b>${h.note ? ' · ' + esc(h.note) : ''}${cur ? ` <span class="chip ok">${esc(t('ui.roles.current'))}</span>` : ` <button class="btn sm ghost" data-mine-restore="${n}">${esc(t('ui.roles.restore', { v: n }))}</button>`}<span>${esc(h.actor || '—')} · ${esc(relTime(h.created))}</span></div>`;
        }).join('') + '</div></div></div>';
    }
  } else if (rr.status === 'rejected' && pr.status === 'fulfilled') {
    roles = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.roles.title'))}</h3></div>${failed(rr.reason)}</div>`;
  }

  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.cfg.lead'))}</p></div></div>` +
    `<div class="grid g2">${mine}${team}</div>${roles}${myHist}${hist}`;

  if (roles && rr.status === 'fulfilled') wireRoles(ctx, rr.value, pr.value);

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

// wireRoles draws the selected role and turns every control into one PUT of
// the person bundle at its base version (409: someone else wrote — read again).
function wireRoles(ctx, view, person) {
  const host = ctx.el.querySelector('#roles');
  const bundle = person.bundle || {};
  const save = async (next, note) => {
    try {
      await ctx.api('/v1/fleet/person-bundle', { method: 'PUT', json: { bundle: next, base: person.version || 0, note } });
      ctx.toast(t('ui.roles.saved'));
    } catch (e) {
      ctx.toast(e.status === 409 ? t('ui.roles.conflict') : t('ui.roles.saveFail', { e: e.message }));
    }
    await ctx.refresh();
  };
  const draw = () => {
    if (!ROLES.includes(selRole)) selRole = ROLES[0];
    const layer = layerOf(view, selRole);
    host.innerHTML = `<div class="rolecards">${ROLES.map((r) => roleCard(r, view.roles[r], r === selRole)).join('')}</div>` +
      roleDetail(selRole, view.roles[selRole], layer);
    const put = (l, note) => save(withRoleLayer(bundle, selRole, l), `${selRole}: ${note}`);
    host.querySelectorAll('.rc').forEach((b) => { b.onclick = () => { selRole = b.dataset.role; draw(); }; });
    host.querySelectorAll('select[data-field]').forEach((sel) => {
      sel.onchange = () => {
        const k = sel.dataset.field;
        const r = view.roles[selRole];
        const builtin = r && r.base && r.base.front ? r.base.front[k] : undefined;
        // picking the built-in value back is 还原, not a copy of it
        put(setField(layer, k, !sel.value || sel.value === builtin ? undefined : sel.value), sel.value ? `${k} → ${sel.value}` : t('ui.roles.noteReset', { k }));
      };
    });
    host.querySelectorAll('[data-reset]').forEach((b) => { b.onclick = () => put(setField(layer, b.dataset.reset, undefined), t('ui.roles.noteReset', { k: b.dataset.reset })); });
    host.querySelectorAll('form[data-list]').forEach((f) => {
      f.onsubmit = (ev) => {
        ev.preventDefault();
        const w = f.elements.w.value.trim();
        if (w) put(listEdit(layer, f.dataset.list, w), `${f.dataset.list} ${w}`);
      };
    });
    host.querySelectorAll('[data-undo]').forEach((b) => { b.onclick = () => put(listUndo(layer, b.dataset.undo, b.dataset.item), t('ui.roles.noteUndo', { k: b.dataset.undo, x: b.dataset.item })); });
    const de = host.querySelector('[data-edit="description"]');
    if (de) {
      de.onclick = () => {
        const r = view.roles[selRole];
        const cur = (r && r.fields && r.fields.description) || layer.front.description || '';
        const v = window.prompt(t('ui.roles.descPrompt'), cur);
        if (v == null || v === cur) return;
        put(setField(layer, 'description', v.trim() ? v.trim() : undefined), 'description');
      };
    }
    const sb = host.querySelector('[data-save-body]');
    if (sb) sb.onclick = () => put(setBody(layer, host.querySelector('#rbody').value), t('ui.roles.noteBody'));
    const rb = host.querySelector('[data-reset-body]');
    if (rb) rb.onclick = () => put(setBody(layer, ''), t('ui.roles.noteReset', { k: 'body' }));
  };
  draw();
  const rules = ctx.el.querySelector('#rules');
  rules.querySelectorAll('select[data-rule]').forEach((sel) => {
    sel.onchange = () => {
      const n = Number(sel.dataset.rule);
      const row = (view.rules.rows || []).find((r) => r.n === n) || (Array.isArray(bundle.rules) ? bundle.rules : []).find((r) => Number(r.n) === n);
      if (row) save(setRuleTier(bundle, row, sel.value), t('ui.roles.noteRule', { n, tier: sel.value }));
    };
  });
  rules.querySelectorAll('[data-rule-reset]').forEach((b) => { b.onclick = () => save(resetRule(bundle, b.dataset.ruleReset), t('ui.roles.noteRuleReset', { n: b.dataset.ruleReset })); });
  ctx.el.querySelectorAll('[data-mine-restore]').forEach((b) => {
    b.onclick = () => {
      const v = Number(b.dataset.mineRestore);
      ctx.confirm(t('ui.roles.restoreQ', { v }), esc(t('ui.roles.restoreBody', { v })), t('ui.roles.restore', { v }), async () => {
        try {
          await ctx.api('/v1/fleet/person-bundle', { method: 'PUT', json: { restore: v, base: person.version || 0 } });
          ctx.toast(t('ui.roles.restored', { v }));
        } catch (e) {
          ctx.toast(e.status === 409 ? t('ui.roles.conflict') : t('ui.roles.saveFail', { e: e.message }));
        }
        await ctx.refresh();
      });
    };
  });
}
