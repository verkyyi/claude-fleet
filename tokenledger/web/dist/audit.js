// web/dist/audit.js — Audit, at /admin/audit (claude-fleet#1990): everything
// that changed access, money or machines, newest first, grouped by day —
// the fleet audit, the credential audit, the device audit and the hub's own,
// merged by the hub (/v1/admin/audit). Filter by kind; export the filter as
// CSV. Stored audit text is shown as recorded, never translated. An admin's.
import { Shell } from './app-shell.js';
import { esc, ic } from './lib/shell.js';
import { AUDIT_KINDS, auditDays, auditWho } from './lib/admin.js';
import { t } from './lib/i18n.js';

let kind = 'all';
try { kind = new URLSearchParams(location.search).get('kind') || 'all'; } catch { /* default */ }
if (!AUDIT_KINDS.includes(kind)) kind = 'all';

const avatar = (who) => `<span class="av" style="background:var(--brand)">${esc(String(who || '?').slice(0, 2).toUpperCase())}</span>`;
const hhmm = (at) => { const d = new Date(at); return Number.isFinite(d.getTime()) ? `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}` : ''; };

Shell.mount('audit', async (ctx) => {
  const q = kind === 'all' ? '' : '?kind=' + encodeURIComponent(kind);
  const a = await ctx.api('/v1/admin/audit' + q);
  const counts = a.counts || {};
  const all = Object.values(counts).reduce((x, y) => x + y, 0);
  const seg = AUDIT_KINDS.map((k) => `<button data-kind="${k}" aria-pressed="${k === kind}">${esc(t('ui.aud.k.' + k))}<span class="n">${k === 'all' ? all : counts[k] || 0}</span></button>`).join('');
  const days = auditDays(a.events);
  const log = days.length
    ? days.map((d) => `<div class="day">${esc(d.day)}</div>` + d.events.map((e) => {
      const who = auditWho(e);
      const what = [e.action, e.target, e.outcome].filter(Boolean).map(esc).join(' · ');
      return `<div class="ev">${avatar(who)}<span class="what"><b style="font-weight:500">${esc(who)}</b> · <span class="mono">${what}</span>${e.detail ? `<br><span style="font-size:12px;color:var(--muted)">${esc(e.detail)}</span>` : ''}</span>` +
        `<span class="chip">${esc(t('ui.aud.k.' + e.kind))}</span><time datetime="${esc(e.at)}">${esc(hhmm(e.at))}</time></div>`;
    }).join('')).join('')
    : `<div class="empty">${ic('scroll')}<b>${esc(t('ui.aud.empty'))}</b><span>${esc(t(kind === 'all' ? 'ui.aud.emptySub' : 'ui.aud.emptyKind'))}</span></div>`;
  const csv = '/v1/admin/audit?format=csv' + (kind === 'all' ? '' : '&kind=' + encodeURIComponent(kind));
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.aud.lead', { days: a.days || 60 }))}</p></div><div class="acts"><a class="btn" href="${esc(csv)}" download>${ic('download')}${esc(t('ui.aud.csv'))}</a></div></div>` +
    `<div class="panel"><div class="panel-h"><div class="seg" role="group" aria-label="${esc(t('ui.aud.filter'))}" style="flex-wrap:wrap">${seg}</div><span class="sub">${esc(t('ui.aud.shown', { n: (a.events || []).length }))}</span></div><div class="alog">${log}</div></div>`;
  ctx.el.onclick = (e) => {
    const b = e.target.closest('[data-kind]');
    if (!b || b.dataset.kind === kind) return;
    kind = b.dataset.kind;
    try { history.replaceState(null, '', kind === 'all' ? location.pathname : '?kind=' + kind); } catch { /* fine */ }
    ctx.refresh();
  };
});
