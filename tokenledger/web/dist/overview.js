// web/dist/overview.js — Overview, at / (claude-fleet#1989): four numbers with
// a small trend, 14 days of Claude + Codex tokens, what needs you, and 7 days
// by machine / by model (an admin also by person). Every number comes from
// /v1/summary, /v1/history, /v1/usage and the fleet's session list — for a
// user already cut to their own machine login by the hub (#1985).
//
// Each panel stands alone: one answer failing draws that panel's error, not a
// blank page.
import { Shell } from './app-shell.js';
import { esc, ic, fmtTokens, spark, greeting } from './lib/shell.js';
import { t } from './lib/i18n.js';
import { dayKeys, dayTokens, stack, delta, bars, areaChart, sessionRows, running, attention, activeDevices } from './lib/pages.js';

const enc = encodeURIComponent;

function kpi(label, val, trend, d) {
  return `<div class="panel kpi"><span class="lbl">${esc(label)}</span><span class="val">${esc(val)}</span>${trend && trend.length ? spark(trend, 'var(--brand)', true) : ''}<span class="delta${d && d.down ? ' down' : ''}"${d && d.muted ? ' style="color:var(--muted)"' : ''}>${esc((d && d.text) || ' ')}</span></div>`;
}

function hb(rows, color) {
  if (!rows.length) return `<div class="ghostrow">${esc(t('ui.ov.noUsage7'))}</div>`;
  const max = rows[0][1] || 1;
  return '<div class="hb">' + rows.map((r) => `<div class="hb-row"><span class="name mono" title="${esc(r[0])}">${esc(r[0])}</span><span class="track"><i style="width:${(r[1] / max * 100).toFixed(0)}%;background:${color}"></i></span><span class="v">${esc(fmtTokens(r[1]))}</span></div>`).join('') + '</div>';
}

const failed = (r) => `<div class="ghostrow err">${ic('alert')} ${esc(r.reason ? r.reason.message : t('ui.unavailable'))}</div>`;

Shell.mount('overview', async (ctx) => {
  const { api, admin, me } = ctx;
  const now = Date.now();
  const keys = dayKeys(now, 14);
  const since14 = keys[0] + 'T00:00:00Z';
  const today = keys[13] + 'T00:00:00Z';
  const q = (path, extra) => api(`${path}?account=all&${extra}`);
  const [sumToday, sum7, hClaude, hCodex, byHost, byModel, byPerson, fleet, devs] = await Promise.allSettled([
    q('/v1/summary', `since=${enc(today)}&compare=1`),
    q('/v1/summary', 'since=7d&compare=1'),
    q('/v1/history', `granularity=day&since=${enc(since14)}&source=claude`),
    q('/v1/history', `granularity=day&since=${enc(since14)}&source=codex`),
    q('/v1/usage', 'by=endpoint&since=7d'),
    q('/v1/usage', 'by=model&since=7d'),
    admin ? q('/v1/usage', 'by=user&since=7d') : Promise.resolve(null),
    ctx.fleet(),
    admin ? Promise.resolve(null) : api('/v1/fleet/devices'),
  ]);

  const claude = hClaude.status === 'fulfilled' ? dayTokens(keys, hClaude.value.series) : null;
  const codex = hCodex.status === 'fulfilled' ? dayTokens(keys, hCodex.value.series) : null;
  const daily = claude && codex ? claude.map((c, i) => c + codex[i]) : [];
  const rows = fleet.status === 'fulfilled' ? sessionRows(fleet.value, null) : [];
  const nodes = fleet.status === 'fulfilled' ? fleet.value.nodes || [] : [];
  const val = (r, f) => (r.status === 'fulfilled' ? f(r.value) : '—');

  const k1 = kpi(t(admin ? 'ui.ov.tokensToday' : 'ui.ov.myTokensToday'), val(sumToday, (s) => fmtTokens(s.tokens)), daily,
    sumToday.status === 'fulfilled' ? delta(sumToday.value.tokens, sumToday.value.prev && sumToday.value.prev.tokens, 'ui.ov.vsYesterday') : { text: t('ui.unavailable'), down: true });
  const k2 = kpi(t(admin ? 'ui.ov.tokens7' : 'ui.ov.myTokens7'), val(sum7, (s) => fmtTokens(s.tokens)), daily.slice(-7),
    sum7.status === 'fulfilled' ? delta(sum7.value.tokens, sum7.value.prev && sum7.value.prev.tokens, 'ui.ov.vsLastWeek') : { text: t('ui.unavailable'), down: true });
  const run = running(rows).length;
  const k3 = kpi(t(admin ? 'ui.ov.running' : 'ui.ov.mySessions'), fleet.status === 'fulfilled' ? String(run) : '—', [],
    { text: fleet.status === 'fulfilled' ? t('ui.ov.open', { n: rows.length }) : t('ui.unavailable'), muted: true });
  let k4;
  if (admin) {
    const on = nodes.filter((n) => n.availability === 'online').length;
    k4 = kpi(t('ui.ov.machinesOnline'), fleet.status === 'fulfilled' ? `${on}/${nodes.length}` : '—', [], { text: nodes.length - on ? t('ui.ov.notOnline', { n: nodes.length - on }) : t('ui.ov.allOnline'), down: nodes.length - on > 0 });
  } else {
    const n = devs.status === 'fulfilled' ? activeDevices(devs.value.devices).length : null;
    k4 = kpi(t('ui.ov.myDevices'), n == null ? '—' : String(n), [], { text: n == null ? t('ui.unavailable') : t('ui.ov.certsRenew'), muted: true });
  }

  const chart = claude && codex
    ? (daily.some((x) => x) ? areaChart(stack(claude, codex), keys) : `<div class="empty">${ic('list')}<b>${esc(t('ui.ov.noTokens'))}</b><span>${esc(t('ui.ov.noTokensSub'))}</span></div>`)
    : failed(hClaude.status === 'rejected' ? hClaude : hCodex);

  const att = fleet.status === 'fulfilled' ? attention(rows, nodes, admin) : null;
  const attHTML = att == null ? failed(fleet)
    : att.length ? '<div class="attn">' + att.map((a) => `<div><span class="ic ${a.tone}">${ic(a.icon)}</span><div><b>${esc(a.title)}</b><span>${esc(a.sub)}</span></div></div>`).join('') + '</div>'
      : `<div class="empty">${ic('check')}<b>${esc(t('ui.ov.nothing'))}</b><span>${esc(t('ui.ov.nothingSub'))}</span></div>`;

  const panel = (title, r, color, f) => `<div class="panel"><div class="panel-h"><h3>${esc(title)}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div><div class="panel-b">${r.status === 'fulfilled' ? hb(bars(f(r.value)), color) : failed(r)}</div></div>`;
  const name = me.name || me.login || t('ui.me.you');

  ctx.el.innerHTML =
    `<div class="pagehead"><div><h2 style="font:600 1.35rem var(--f-ui)">${esc(greeting(new Date().getHours(), name))}</h2><p>${esc(t(admin ? 'ui.ov.subAdmin' : 'ui.ov.subUser'))}</p></div>` +
    `<div class="acts"><a class="btn" href="/sessions">${ic('list')}${esc(t('ui.nav.sessions'))}</a></div></div>` +
    `<div class="grid g4">${k1}${k2}${k3}${k4}</div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.perDay'))}</h3><div class="legend"><span><i style="background:var(--brand)"></i>Claude</span><span><i style="background:var(--codex)"></i>Codex</span></div></div><div class="panel-b">${chart}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.attention'))}</h3></div>${attHTML}</div></div>` +
    `<div class="grid ${admin ? 'g3' : 'g2'}">` +
    panel(t('ui.ov.byMachine'), byHost, 'var(--brand)', (v) => v.buckets) +
    panel(t('ui.ov.byModel'), byModel, 'var(--codex)', (v) => v.buckets) +
    (admin ? panel(t('ui.ov.byPerson'), byPerson, 'var(--brand-2)', (v) => v.buckets) : '') + '</div>';
});
