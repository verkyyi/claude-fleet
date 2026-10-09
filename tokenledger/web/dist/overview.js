// web/dist/overview.js — Overview, at / (claude-fleet#1989): four numbers with
// a small trend, 14 days of Claude + Codex tokens, what needs you, and 7 days
// by machine / by model. Every number comes from /v1/summary, /v1/history,
// /v1/usage, the fleet's session list and /v1/fleet/devices — already cut by
// the hub to the viewer's own (machine, login) pairs (#1985, #2514), an
// admin's too (#2515): the hub by person is By person, admin/overview.js.
//
// Each panel stands alone: one answer failing draws that panel's error, not a
// blank page.
import { Shell } from './app-shell.js';
import { esc, ic, fmtTokens, greeting } from './lib/shell.js';
import { t } from './lib/i18n.js';
import { dayKeys, dayTokens, stack, delta, bars, areaChart, sessionRows, running, attention, clientDevices, scopeOf, kpi, hb } from './lib/pages.js';

const enc = encodeURIComponent;

const failed = (r) => `<div class="ghostrow err">${ic('alert')} ${esc(r.reason ? r.reason.message : t('ui.unavailable'))}</div>`;

Shell.mount('overview', async (ctx) => {
  const { api, me } = ctx;
  const now = Date.now();
  const keys = dayKeys(now, 14);
  const since14 = keys[0] + 'T00:00:00Z';
  const today = keys[13] + 'T00:00:00Z';
  const q = (path, extra) => api(`${path}?account=all&${extra}`);
  const [sumToday, sum7, hClaude, hCodex, byHost, byModel, fleet, devs] = await Promise.allSettled([
    q('/v1/summary', `since=${enc(today)}&compare=1`),
    q('/v1/summary', 'since=7d&compare=1'),
    q('/v1/history', `granularity=day&since=${enc(since14)}&source=claude`),
    q('/v1/history', `granularity=day&since=${enc(since14)}&source=codex`),
    q('/v1/usage', 'by=endpoint&since=7d'),
    q('/v1/usage', 'by=model&since=7d'),
    ctx.fleet(),
    api('/v1/fleet/devices'),
  ]);

  const claude = hClaude.status === 'fulfilled' ? dayTokens(keys, hClaude.value.series) : null;
  const codex = hCodex.status === 'fulfilled' ? dayTokens(keys, hCodex.value.series) : null;
  const daily = claude && codex ? claude.map((c, i) => c + codex[i]) : [];
  const rows = fleet.status === 'fulfilled' ? sessionRows(fleet.value, null) : [];
  const val = (r, f) => (r.status === 'fulfilled' ? f(r.value) : '—');

  const k1 = kpi(t('ui.ov.myTokensToday'), val(sumToday, (s) => fmtTokens(s.tokens)), daily,
    sumToday.status === 'fulfilled' ? delta(sumToday.value.tokens, sumToday.value.prev && sumToday.value.prev.tokens, 'ui.ov.vsYesterday') : { text: t('ui.unavailable'), down: true });
  const k2 = kpi(t('ui.ov.myTokens7'), val(sum7, (s) => fmtTokens(s.tokens)), daily.slice(-7),
    sum7.status === 'fulfilled' ? delta(sum7.value.tokens, sum7.value.prev && sum7.value.prev.tokens, 'ui.ov.vsLastWeek') : { text: t('ui.unavailable'), down: true });
  const run = running(rows).length;
  const k3 = kpi(t('ui.ov.mySessions'), fleet.status === 'fulfilled' ? String(run) : '—', [],
    { text: fleet.status === 'fulfilled' ? t('ui.ov.open', { n: rows.length }) : t('ui.unavailable'), muted: true });
  const n = devs.status === 'fulfilled' ? clientDevices(devs.value).length : null;
  const k4 = kpi(t('ui.ov.myDevices'), n == null ? '—' : String(n), [], { text: n == null ? t('ui.unavailable') : t('ui.ov.certsRenew'), muted: true });

  const chart = claude && codex
    ? (daily.some((x) => x) ? areaChart(stack(claude, codex), keys) : `<div class="empty">${ic('list')}<b>${esc(t('ui.ov.noTokens'))}</b><span>${esc(t('ui.ov.noTokensSub'))}</span></div>`)
    : failed(hClaude.status === 'rejected' ? hClaude : hCodex);

  const att = fleet.status === 'fulfilled' ? attention(rows, [], false) : null;
  const attHTML = att == null ? failed(fleet)
    : att.length ? '<div class="attn">' + att.map((a) => `<div><span class="ic ${a.tone}">${ic(a.icon)}</span><div><b>${esc(a.title)}</b><span>${esc(a.sub)}</span></div></div>`).join('') + '</div>'
      : `<div class="empty">${ic('check')}<b>${esc(t('ui.ov.nothing'))}</b><span>${esc(t('ui.ov.nothingSub'))}</span></div>`;

  const panel = (title, r, color, f) => `<div class="panel"><div class="panel-h"><h3>${esc(title)}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div><div class="panel-b">${r.status === 'fulfilled' ? hb(bars(f(r.value)), color) : failed(r)}</div></div>`;
  const name = me.name || me.login || t('ui.me.you');

  ctx.el.innerHTML =
    `<div class="pagehead"><div><h2 style="font:600 1.35rem var(--f-ui)">${esc(greeting(new Date().getHours(), name))}</h2><p>${esc(t('ui.ov.subUser'))}</p>${scopeOf(me) ? `<p class="mono" style="font-size:12px;opacity:.7" id="ovscope">${esc(scopeOf(me))}</p>` : ''}</div>` +
    `<div class="acts"><a class="btn" href="/sessions">${ic('list')}${esc(t('ui.nav.sessions'))}</a></div></div>` +
    `<div class="grid g4">${k1}${k2}${k3}${k4}</div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.perDay'))}</h3><div class="legend"><span><i style="background:var(--brand)"></i>Claude</span><span><i style="background:var(--codex)"></i>Codex</span></div></div><div class="panel-b">${chart}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.attention'))}</h3></div>${attHTML}</div></div>` +
    '<div class="grid g2">' +
    panel(t('ui.ov.byMachine'), byHost, 'var(--brand)', (v) => v.buckets) +
    panel(t('ui.ov.byModel'), byModel, 'var(--codex)', (v) => v.buckets) + '</div>';
});
