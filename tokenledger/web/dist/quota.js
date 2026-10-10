// web/dist/quota.js — 我的额度, at /quota (claude-fleet#2517): the
// subscriptions the viewer's own sessions run on — the 5-hour and 7-day
// windows, when the binding one resets, used up or paused. Reads
// /v1/me/quota, which the hub cuts to the viewer's own (machine, login)
// pairs and strips of every account identifier; an admin's is theirs too —
// the whole pool stays on Subscriptions.
import { Shell } from './app-shell.js';
import { esc } from './lib/shell.js';
import { quotaTable } from './lib/pages.js';
import { t } from './lib/i18n.js';

export default Shell.mount('quota', async (ctx) => {
  const rows = await ctx.api('/v1/me/quota');
  ctx.el.innerHTML = `<div class="panel"><div class="panel-h"><div><h3>${esc(t('ui.nav.quota'))}</h3>` +
    `<span class="sub">${esc(t('ui.q.sub'))}</span></div></div>${quotaTable(rows)}</div>` +
    (Array.isArray(rows) && rows.length ? `<p class="sub" style="font-size:12.5px;color:var(--muted);margin-top:10px">${esc(t('ui.q.note'))}</p>` : '');
});
