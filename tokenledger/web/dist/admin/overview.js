// web/dist/admin/overview.js — By person, at /admin/overview
// (claude-fleet#2515): the four numbers, the machines that need an admin,
// and one row a person (claude-fleet#3228) — their pool tokens, open
// sessions and the (服务节点 · 登录) pairs they hold — from
// /v1/admin/overview (admin_views.go).
import { Shell } from '../app-shell.js';
import { esc, ic, fmtTokens } from '../lib/shell.js';
import { t } from '../lib/i18n.js';
import { attention, kpi, hb } from '../lib/pages.js';

export default Shell.mount('by-person', async (ctx) => {
  const ov = await ctx.api('/v1/admin/overview?since=7d');
  const tot = ov.totals || {};
  const nodes = ov.nodes || [];
  const people = ov.people || [];

  const off = (tot.machines || 0) - (tot.machines_online || 0);
  const tiles = kpi(t('ui.ov.tokensToday'), fmtTokens(tot.tokens_today || 0), [], { text: ' ', muted: true }) +
    kpi(t('ui.ov.tokens7'), fmtTokens(tot.tokens || 0), [], { text: ' ', muted: true }) +
    kpi(t('ui.ov.running'), String(tot.running || 0), [], { text: t('ui.ov.open', { n: tot.sessions || 0 }), muted: true }) +
    (ov.fleet ? kpi(t('ui.ov.machinesOnline'), `${tot.machines_online || 0}/${tot.machines || 0}`, [], { text: off ? t('ui.ov.notOnline', { n: off }) : t('ui.ov.allOnline'), down: off > 0 }) : '');

  const att = attention([], nodes, true);
  const attHTML = att.length
    ? '<div class="attn">' + att.map((a) => `<div><span class="ic ${a.tone}">${ic(a.icon)}</span><div><b>${esc(a.title)}</b><span>${esc(a.sub)}</span></div></div>`).join('') + '</div>'
    : `<div class="empty">${ic('check')}<b>${esc(t('ui.ov.nothing'))}</b><span>${esc(t('ui.bp.attentionSub'))}</span></div>`;

  const rows = people.length
    ? people.map((p) => `<tr><td>${esc(p.name || p.principal || '—')}</td><td class="mono">${esc((p.logins || []).map((l) => l.join(' · ')).join(', ') || '—')}</td>` +
      `<td>${esc(p.sessions ? t('ui.bp.running', { n: p.sessions, r: p.running || 0 }) : '—')}</td><td class="mono r">${esc(fmtTokens(p.today || 0))}</td><td class="mono r">${esc(fmtTokens(p.week || 0))}</td></tr>`).join('')
    : `<tr><td colspan="5"><div class="empty">${ic('users')}<b>${esc(t('ui.bp.none'))}</b></div></td></tr>`;
  const table = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.bp.people'))}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div>` +
    `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.col.person'))}</th><th>${esc(t('ui.bp.login'))}</th><th>${esc(t('ui.bp.sessions'))}</th><th class="r">${esc(t('ui.bp.today'))}</th><th class="r">${esc(t('ui.bp.week'))}</th></tr></thead><tbody>${rows}</tbody></table></div></div>`;

  const bars = people.filter((p) => p.week > 0).map((p) => [p.name || p.principal, p.week]);
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.bp.sub'))}</p></div>` +
    // The keys page is everyone's, the admin's too (claude-fleet#3199).
    `<div class="acts"><a class="btn" href="/fleet/keys">${ic('phone')}${esc(t('ui.ov.phone'))}</a></div></div>` +
    `<div class="grid g4">${tiles}</div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.byPerson'))}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div><div class="panel-b">${hb(bars, 'var(--brand-2)')}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.attention'))}</h3></div>${attHTML}</div></div>` + table;
});
