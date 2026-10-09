// web/dist/admin/users.js — Users, at /admin/users (claude-fleet#1990): the GitHub
// accounts that may sign in. Adding a name saves its numeric GitHub ID at once
// (a freed name taken over later is refused); removing one signs them out on
// their next request and revokes their devices. Admins come from the deploy
// (CCQUOTA_GITHUB_ADMINS) and are read-only here. /v1/fleet/users; every
// change is audited by the hub. 生成邀请命令 mints an invite
// (/v1/fleet/invites, claude-fleet#2261). An admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, relTime } from '../lib/shell.js';
import { userRows, cleanLogin, GH_LOGIN_RE } from '../lib/admin.js';
import { t } from '../lib/i18n.js';

const avatar = (login) => `<span class="av" style="background:var(--brand)">${esc(String(login || '?').slice(0, 2).toUpperCase())}</span>`;

// inviteModal shows a minted invite's command — the only time its code is
// ever shown — with a copy button.
function inviteModal(ctx, inv) {
  const until = inv.expires_at ? new Date(inv.expires_at).toLocaleString() : '—';
  ctx.modal(`<div class="modal-h"><h3>${esc(t('ui.usr.inv.title'))}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div><div class="modal-b">` +
    `<p>${esc(t('ui.usr.inv.run'))}</p><div class="cmdbox"><span>${esc(inv.command)}</span><button class="btn sm" data-shell="copy" data-text="${esc(inv.command)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div>` +
    `<dl class="kv"><dt>${esc(t('ui.usr.inv.for'))}</dt><dd>${inv.github_login ? `<span class="mono">${esc(inv.github_login)}</span>` : esc(t('ui.usr.inv.anyone'))}</dd>` +
    `<dt>${esc(t('ui.usr.inv.works'))}</dt><dd>${esc(t('ui.usr.inv.once'))}</dd><dt>${esc(t('ui.usr.inv.expires'))}</dt><dd class="mono">${esc(until)}</dd></dl>` +
    `<p class="sub mono">${esc(t('ui.usr.inv.revoke', { id: inv.id }))}</p></div>` +
    `<div class="modal-f"><button class="btn ghost" data-shell="close">${esc(t('ui.close'))}</button></div>`);
}

Shell.mount('people', async (ctx) => {
  const list = await ctx.api('/v1/fleet/users');
  const rows = userRows(list);
  ctx.setCount('people', rows.length);
  const tr = (u) => `<tr><td><div class="status">${avatar(u.login)}<span><b style="font-weight:500">${esc(u.login)}</b><br><span class="repo">github.com/${esc(u.login)}</span></span></div></td>` +
    `<td class="mono">${esc(u.github_id || '—')}</td>` +
    `<td>${u.role === 'admin' ? `<span class="chip brand">${esc(t('ui.role.admin'))}</span>` : `<span class="chip">${esc(t('ui.role.user'))}</span>`}</td>` +
    `<td class="mono">${esc(u.machine_login || '—')}</td>` +
    `<td>${u.deploy ? `<span class="envlock">${ic('lock')}${esc(t('ui.usr.deploy'))}</span>` : esc(u.added_by || '—')}</td>` +
    `<td>${u.last_seen ? esc(relTime(u.last_seen)) : esc(t('ui.usr.never'))}</td>` +
    `<td class="r">${u.deploy ? '' : `<button class="btn sm danger" data-act="rm" data-login="${esc(u.login)}">${esc(t('ui.usr.remove'))}</button>`}</td></tr>`;
  const table = rows.length
    ? `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.usr.th.account'))}</th><th>${esc(t('ui.usr.th.id'))}</th><th>${esc(t('ui.usr.th.role'))}</th><th>${esc(t('ui.usr.th.login'))}</th><th>${esc(t('ui.usr.th.by'))}</th><th>${esc(t('ui.usr.th.seen'))}</th><th></th></tr></thead><tbody>${rows.map(tr).join('')}</tbody></table></div>`
    : `<div class="empty">${ic('users')}<b>${esc(t('ui.usr.empty'))}</b><span>${esc(t('ui.usr.emptySub'))}</span></div>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.usr.lead'))}</p></div></div>` +
    `<div class="panel"><div class="panel-h"><form class="toolbar" id="addform" style="flex:1"><label class="search" style="max-width:340px">${ic('git')}<input class="input" id="newuser" placeholder="${esc(t('ui.usr.placeholder'))}" aria-label="${esc(t('ui.usr.aria'))}" autocomplete="off" spellcheck="false"></label>` +
    `<button class="btn primary" type="submit">${ic('plus')}${esc(t('ui.usr.add'))}</button>` +
    `<button class="btn" type="button" data-act="invite" title="${esc(t('ui.usr.inv.hint'))}">${ic('copy')}${esc(t('ui.usr.invite'))}</button></form><span class="sub">${esc(t('ui.usr.count', { n: rows.length }))}</span></div>${table}</div>`;

  const form = ctx.el.querySelector('#addform');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const inp = ctx.el.querySelector('#newuser');
    const login = cleanLogin(inp.value);
    if (!GH_LOGIN_RE.test(login)) { ctx.toast(t('ui.usr.bad')); inp.focus(); return; }
    if (rows.some((u) => String(u.login).toLowerCase() === login.toLowerCase())) { ctx.toast(t('ui.usr.already', { login })); return; }
    const btn = form.querySelector('button'); btn.disabled = true;
    try {
      const out = await ctx.api('/v1/fleet/users', { json: { login } });
      ctx.toast(t('ui.usr.added', { login: out.added || login, id: out.github_id || '—' }));
      await ctx.refresh();
    } catch (err) {
      btn.disabled = false;
      ctx.toast(t('ui.err.action', { e: err.message }));
    }
  };
  ctx.el.onclick = async (e) => {
    if (e.target.closest('[data-act="invite"]')) {
      // An invite (claude-fleet#2261): one install command that lets one
      // newcomer in — the typed username, when valid, is the only one it admits.
      const login = cleanLogin(ctx.el.querySelector('#newuser').value);
      try {
        const inv = await ctx.api('/v1/fleet/invites', { json: GH_LOGIN_RE.test(login) ? { github_login: login } : {} });
        inviteModal(ctx, inv);
      } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
      return;
    }
    const b = e.target.closest('[data-act="rm"]');
    if (!b) return;
    const login = b.dataset.login;
    ctx.confirm(t('ui.usr.rmQ', { login }), esc(t('ui.usr.rmBody')), t('ui.usr.rmBtn'), async () => {
      try {
        const out = await ctx.api('/v1/fleet/users?login=' + encodeURIComponent(login), { method: 'DELETE' });
        ctx.toast(t('ui.usr.removed', { login, n: out.devices_revoked || 0 }));
        await ctx.refresh();
      } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
    });
  };
});
