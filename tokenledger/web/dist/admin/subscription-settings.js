import { Shell } from '../app-shell.js';
import { esc } from '../lib/shell.js';
import { mountGlobalPolicy } from '../lib/cred-policy.js';
import { settingValue } from '../lib/admin.js';
import { t } from '../lib/i18n.js';

export default Shell.mount('subscription-settings', async (ctx) => {
  ctx.el.innerHTML = `<div class="pagehead"><div><a class="sub" href="/app/subscriptions">← ${esc(t('ui.nav.subscriptions'))}</a><h2>${esc(t('ui.policy.global'))}</h2></div></div><section class="panel" id="global-policy"></section><section class="panel" id="pool-settings"></section>`;
  await Promise.all([mountGlobalPolicy(ctx,ctx.el.querySelector('#global-policy')),mountPool(ctx,ctx.el.querySelector('#pool-settings'))]);
});

async function mountPool(ctx,root) {
  try {
    const settings = await ctx.api('/v1/fleet/settings');
    const skip = settingValue(settings,'pool.skip_pct').value, move = settingValue(settings,'pool.move_when_full').value;
    root.innerHTML = `<div class="panel-h"><h3>${esc(t('ui.set.g.pool'))}</h3></div><div class="setlist"><div><div class="l"><b>${esc(t('ui.set.k.pool.skip_pct'))}</b><span>${esc(t('ui.set.h.pool.skip_pct'))}</span></div><form class="toolbar"><input class="input" style="width:80px" type="number" min="1" max="100" required value="${esc(skip)}" aria-label="${esc(t('ui.set.k.pool.skip_pct'))}"><span>%</span><button class="btn">${esc(t('ui.policy.save'))}</button></form></div><div><div class="l"><b>${esc(t('ui.set.k.pool.move_when_full'))}</b><span>${esc(t('ui.set.h.pool.move_when_full'))}</span></div><button class="switch" role="switch" aria-label="${esc(t('ui.set.k.pool.move_when_full'))}" aria-checked="${move==='on'}"></button></div></div><p class="err panel-b" role="alert"></p>`;
    const form = root.querySelector('form'),toggle = root.querySelector('[role=switch]');
    const put = async(key,value,button) => {
      button.disabled=true;
      try { await ctx.api('/v1/fleet/settings',{method:'PUT',json:{key,value}});ctx.toast(t('ui.set.saved'));await mountPool(ctx,root); }
      catch(err) { root.querySelector('.err').textContent=err.message;button.disabled=false; }
    };
    form.onsubmit=(e)=>{e.preventDefault();void put('pool.skip_pct',form.querySelector('input').value,form.querySelector('button'));};
    toggle.onclick=()=>put('pool.move_when_full',toggle.getAttribute('aria-checked')==='true'?'off':'on',toggle);
  } catch(err) { root.innerHTML=`<p class="panel-b err">${esc(err.message)}</p>`; }
}
