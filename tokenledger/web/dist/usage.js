// web/dist/usage.js — 我的用量, at /usage (claude-fleet#2519): the viewer's
// personal budget (5-hour and 7-day windows, fleet.person_budget) and their
// tokens per day this week. Reads /v1/fleet/person-usage?mine=1, which the hub
// cuts to the viewer — a user always, an admin with mine=1; everyone's is the
// operator's list (`fleet config people`).
import { Shell } from './app-shell.js';
import { esc, ic } from './lib/shell.js';
import { usageBudget, usageDays, hb } from './lib/pages.js';
import { t } from './lib/i18n.js';

Shell.mount('usage', async (ctx) => {
  const u = await ctx.api('/v1/fleet/person-usage?mine=1');
  const st = (u.people || [])[0] || {};
  const days = usageDays(u.days);
  const chart = days.length ? hb(days, 'var(--brand-2)')
    : `<div class="empty">${ic('list')}<b>${esc(t('ui.use.none'))}</b><span>${esc(t('ui.use.noneHint'))}</span></div>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.use.sub'))}</p></div></div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.use.perDay'))}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div><div class="panel-b">${chart}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.use.budget'))}</h3></div><div class="panel-b">${usageBudget(st)}</div></div></div>`;
});
