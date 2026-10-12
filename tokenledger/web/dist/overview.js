// web/dist/overview.js — Overview, at / (claude-fleet#1989, slimmed by #3230):
// only what matters — my limit, what I used today, my running sessions, 14
// days of Claude + Codex tokens and what needs me. The numbers are
// /v1/me/usage (EPIC #3225 C2: the viewer's own pool usage and their own
// limit, never the pool's) and the fleet's session list; where the tokens went
// is 我的用量 (/usage), one link away. No per-machine, per-model or per-device
// split here any more: the same computer used to show up under four names.
//
// Each panel stands alone: one answer failing draws that panel's error, not a
// blank page.
import { Shell } from './app-shell.js';
import { esc, ic, fmtTokens, greeting } from './lib/shell.js';
import { t } from './lib/i18n.js';
import { dayKeys, stack, delta, fullFrom, areaChart, sessionRows, running, attention, orphanAttention, kpi, limitKpi } from './lib/pages.js';

const failed = (r) => `<div class="ghostrow err">${ic('alert')} ${esc(r.reason ? r.reason.message : t('ui.unavailable'))}</div>`;

export default Shell.mount('overview', async (ctx) => {
  const { api, me } = ctx;
  const keys = dayKeys(Date.now(), 14);
  // 30d is the shortest range whose days cover the chart's 14.
  const [use, fleet] = await Promise.allSettled([api('/v1/me/usage?range=30d'), ctx.fleet()]);

  const u = use.status === 'fulfilled' ? use.value : null;
  const byDay = new Map((u && Array.isArray(u.days) ? u.days : []).map((d) => [d.day, d]));
  const claude = keys.map((k) => Number((byDay.get(k) || {}).claude) || 0);
  const codex = keys.map((k) => Number((byDay.get(k) || {}).codex) || 0);
  const daily = claude.map((c, i) => c + codex[i]);
  const rows = fleet.status === 'fulfilled' ? sessionRows(fleet.value, null) : [];
  const down = { text: t('ui.unavailable'), down: true };

  const k1 = u ? limitKpi(u.limit) : kpi(t('ui.ov.limit'), '—', [], down);
  const k2 = kpi(t('ui.ov.today'), u ? fmtTokens(Number(u.today) || 0) : '—', u ? daily : [],
    u ? delta(u.today, u.today_prev, 'ui.ov.vsYesterday', !fullFrom(u.since_first, keys[12] + 'T00:00:00Z') && 'ui.ov.noFullYesterday') : down);
  const k3 = kpi(t('ui.ov.running'), fleet.status === 'fulfilled' ? String(running(rows).length) : '—', [],
    { text: fleet.status === 'fulfilled' ? t('ui.ov.open', { n: rows.length }) : t('ui.unavailable'), muted: true });

  const chart = !u ? failed(use)
    : daily.some((x) => x) ? areaChart(stack(claude, codex), keys) + `<p style="margin-top:10px;font-size:13px"><a href="/app/usage">${esc(t('ui.ov.whereTo'))}</a></p>`
      : `<div class="empty">${ic('list')}<b>${esc(t('ui.ov.noTokens'))}</b><span>${esc(t('ui.ov.noTokensSub'))}</span></div>`;

  const att = fleet.status === 'fulfilled' ? attention(rows, [], false).concat(orphanAttention(fleet.value)) : null;
  const attHTML = att == null ? failed(fleet)
    : att.length ? '<div class="attn">' + att.map((a) => `<div><span class="ic ${a.tone}">${ic(a.icon)}</span><div><b>${esc(a.title)}</b><span>${esc(a.sub)}</span></div></div>`).join('') + '</div>'
      : `<div class="empty">${ic('check')}<b>${esc(t('ui.ov.nothing'))}</b><span>${esc(t('ui.ov.nothingSub'))}</span></div>`;

  const name = me.name || me.login || t('ui.me.you');

  ctx.el.innerHTML =
    `<div class="pagehead"><div><h2 style="font:600 1.35rem var(--f-ui)">${esc(greeting(new Date().getHours(), name))}</h2><p>${esc(t('ui.ov.subUser'))}</p></div>` +
    `<div class="acts"><a class="btn" href="/fleet/keys">${ic('phone')}${esc(t('ui.ov.phone'))}</a><a class="btn" href="/app/usage">${ic('scroll')}${esc(t('ui.nav.usage'))}</a></div></div>` +
    `<div class="grid g3">${k1}${k2}${k3}</div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.days14'))}</h3><div class="legend"><span><i style="background:var(--brand)"></i>Claude</span><span><i style="background:var(--codex)"></i>Codex</span></div></div><div class="panel-b">${chart}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.attention'))}</h3></div>${attHTML}</div></div>`;
});
