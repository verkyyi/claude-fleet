import { Shell } from '../app-shell.js';
import { esc } from '../lib/shell.js';
import { routeFor, pathParam } from '../lib/router.js';
import { userRows, pairsCell } from '../lib/admin.js';
import { mountObjectPolicy } from '../lib/cred-policy.js';
import { t } from '../lib/i18n.js';

export default Shell.mount('person', async (ctx) => {
  const id = pathParam(location.pathname,routeFor(location.pathname));
  const list = await ctx.api('/v1/fleet/users');
  const users = [...userRows(list), ...(list.admins || []).map((u) => ({...u, role:'admin', deploy:true}))];
  const u = users.find((row) => (row.principal || 'gh:' + row.github_id) === id);
  if (!u) throw new Error(t('ui.policy.notFound'));
  ctx.el.innerHTML = `<div class="pagehead"><div><a class="sub" href="/app/admin/users">← ${esc(t('ui.nav.people'))}</a><h2>${esc(u.login)}</h2><p>${esc(t('ui.policy.userHint'))}</p></div><span class="chip brand">${esc(t(u.role === 'admin' ? 'ui.role.admin' : 'ui.role.user'))}</span></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.policy.identity'))}</h3></div><dl class="kv panel-b"><dt>GitHub</dt><dd>${esc(u.login)}</dd><dt>ID</dt><dd class="mono">${esc(id)}</dd><dt>${esc(t('ui.usr.th.login'))}</dt><dd>${pairsCell(u)}</dd></dl></div><section class="panel" id="user-policy"></section>` + (u.deploy ? '' : `<div class="panel"><div class="panel-b"><button class="btn danger" data-remove>${esc(t('ui.usr.remove'))}</button><p class="sub">${esc(t('ui.usr.rmBody'))}</p></div></div>`);
  const remove = ctx.el.querySelector('[data-remove]');
  if (remove) remove.onclick = () => ctx.confirm(t('ui.usr.rmQ',{login:u.login}),esc(t('ui.usr.rmBody')),t('ui.usr.rmBtn'),async () => {
    try { const out = await ctx.api('/v1/fleet/users?login='+encodeURIComponent(u.login),{method:'DELETE'});ctx.toast(t('ui.usr.removed',{login:u.login,n:out.devices_revoked || 0}));await ctx.navigate('/app/admin/users'); }
    catch(err) { ctx.toast(err.message); }
  });
  await mountObjectPolicy(ctx,ctx.el.querySelector('#user-policy'),'user',id);
});
