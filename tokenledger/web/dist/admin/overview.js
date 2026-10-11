// web/dist/admin/overview.js — By person, at /admin/overview
// (claude-fleet#2515): one row a person (claude-fleet#3228, #3231) — four
// numbers about people, the 7-day bars by person, what needs an admin
// (machines, people near their limit), and the table: today, 7 days, personal
// limit, what they are mostly on, sessions. A row opens the person's drawer —
// the limit, the task, the subscriptions their passes are on and the
// (服务节点 · 登录) pairs running their sessions. Only pool usage counts,
// filed under the person who leased it; from /v1/admin/overview
// (admin_views.go, admin_people.go).
import { Shell } from '../app-shell.js';
import { esc, ic, fmtTokens } from '../lib/shell.js';
import { t } from '../lib/i18n.js';
import { attention, kpi, hb } from '../lib/pages.js';
import { personLimit } from '../lib/admin.js';

const shortRepo = (r) => String(r || '').split('/').pop();
const doingOf = (p) => (p.doing ? [shortRepo(p.doing.repo), p.doing.issue ? '#' + p.doing.issue : ''].filter(Boolean).join(' · ') : '');

function limitCell(p) {
  const l = personLimit(p);
  if (!l) return `<span class="chip">${esc(t('ui.bp.noLimit'))}</span>`;
  if (!l.week) return esc(t('ui.bp.only5h', { n: fmtTokens(l.h5) }));
  return `${esc(t('ui.bp.left', { left: fmtTokens(l.left) }))} <span style="color:var(--muted)">${esc(t('ui.bp.ofWeek', { n: fmtTokens(l.week) }))}</span>`;
}

function personDrawer(p, subName) {
  const muted = '<span style="color:var(--muted)">—</span>';
  const logins = (p.logins || []).map(([n, l]) => `<span class="mono">${esc(l)}</span> <span style="color:var(--muted)">${esc(t('ui.bp.dAt', { n }))}</span>`).join('<br>');
  return `<div class="modal-h"><div style="display:grid;gap:2px;min-width:0"><h3>${esc(p.name || p.principal)}</h3>` +
    `<span style="font-size:12.5px;color:var(--muted)">${esc(t('ui.bp.dSub', { week: fmtTokens(p.week || 0), today: fmtTokens(p.today || 0) }))}</span></div>` +
    `<button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>` +
    `<div class="modal-b"><dl class="kv"><dt>${esc(t('ui.bp.limit'))}</dt><dd>${limitCell(p)}</dd>` +
    `<dt>${esc(t('ui.bp.doing'))}</dt><dd>${esc(doingOf(p)) || muted}</dd>` +
    `<dt>${esc(t('ui.bp.dSubs'))}</dt><dd>${(p.subs || []).length ? esc(p.subs.map(subName).join(', ')) : muted}</dd>` +
    `<dt>${esc(t('ui.bp.dLogins'))}</dt><dd>${logins || muted}</dd></dl></div>`;
}

export default Shell.mount('by-person', async (ctx) => {
  const ov = await ctx.api('/v1/admin/overview?since=7d');
  const tot = ov.totals || {};
  const nodes = ov.nodes || [];
  const people = ov.people || [];
  // A pass is bound to a vault account; the pool names its subscription.
  const names = new Map((ov.pool || []).map((s) => [s.account, s.label || s.account]));
  const subName = (a) => names.get(a) || a;

  const limits = people.map((p) => [p, personLimit(p)]).filter(([, l]) => l && l.week);
  const over = limits.filter(([, l]) => l.over);
  const tiles = kpi(t('ui.bp.kToday'), fmtTokens(tot.tokens_today || 0), [], { text: ' ', muted: true }) +
    kpi(t('ui.bp.kWeek'), fmtTokens(tot.tokens || 0), [], { text: ' ', muted: true }) +
    kpi(t('ui.bp.kActive'), String(people.filter((p) => p.week > 0).length), [], { text: t('ui.bp.kActiveSub'), muted: true }) +
    kpi(t('ui.bp.kOver'), t('ui.bp.kOverN', { n: over.length }), [],
      over.length ? { text: over.map(([p]) => p.name || p.principal).join('、'), down: true } : { text: t('ui.bp.kOverNone'), muted: true });

  // A person with a weekly limit and some use of it, the fullest first; a
  // machine that needs an admin after them.
  const att = limits.filter(([, l]) => l.pct > 0).sort((a, b) => b[1].pct - a[1].pct).map(([p, l]) => (l.over
    ? { tone: 'bad', icon: 'alert', title: t('ui.bp.attOver', { name: p.name || p.principal }), sub: t('ui.bp.attOverSub') }
    : { tone: l.pct >= 80 ? 'warn' : 'ok', icon: 'alert', title: t('ui.bp.attLimit', { name: p.name || p.principal, p: l.pct }), sub: t('ui.bp.attLeft', { left: fmtTokens(l.left) }) }))
    .concat(attention([], nodes, true));
  const attHTML = att.length
    ? '<div class="attn">' + att.map((a) => `<div><span class="ic ${a.tone}">${ic(a.icon)}</span><div><b>${esc(a.title)}</b><span>${esc(a.sub)}</span></div></div>`).join('') + '</div>'
    : `<div class="empty">${ic('check')}<b>${esc(t('ui.ov.nothing'))}</b><span>${esc(t('ui.bp.attentionSub'))}</span></div>`;

  const rows = people.length
    ? people.map((p, i) => `<tr data-p="${i}" style="cursor:pointer"><td><b style="font-weight:500">${esc(p.name || p.principal || '—')}</b></td>` +
      `<td class="mono r">${esc(fmtTokens(p.today || 0))}</td><td class="mono r">${esc(fmtTokens(p.week || 0))}</td><td>${limitCell(p)}</td>` +
      `<td>${esc(doingOf(p) || '—')}</td><td>${esc(p.sessions ? t('ui.bp.running', { n: p.sessions, r: p.running || 0 }) : '—')}</td></tr>`).join('')
    : `<tr><td colspan="6"><div class="empty">${ic('users')}<b>${esc(t('ui.bp.none'))}</b></div></td></tr>`;
  const table = `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.bp.people'))}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div>` +
    `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.col.person'))}</th><th class="r">${esc(t('ui.bp.today'))}</th><th class="r">${esc(t('ui.bp.week'))}</th>` +
    `<th>${esc(t('ui.bp.limit'))}</th><th>${esc(t('ui.bp.doing'))}</th><th>${esc(t('ui.bp.sessions'))}</th></tr></thead><tbody>${rows}</tbody></table></div></div>`;

  const bars = people.filter((p) => p.week > 0).map((p) => [p.name || p.principal, p.week]);
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.bp.sub'))}</p></div>` +
    // The keys page is everyone's, the admin's too (claude-fleet#3199).
    `<div class="acts"><a class="btn" href="/fleet/keys">${ic('phone')}${esc(t('ui.ov.phone'))}</a></div></div>` +
    `<div class="grid g4">${tiles}</div>` +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.byPerson'))}</h3><span class="sub">${esc(t('ui.ov.days7'))}</span></div><div class="panel-b">${hb(bars, 'var(--brand-2)')}</div></div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.ov.attention'))}</h3></div>${attHTML}</div></div>` + table;

  ctx.el.onclick = (e) => {
    const tr = e.target.closest('tr[data-p]');
    if (tr && people[+tr.dataset.p]) ctx.drawer(personDrawer(people[+tr.dataset.p], subName));
  };
});
