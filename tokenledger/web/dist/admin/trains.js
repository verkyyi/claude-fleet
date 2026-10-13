// web/dist/admin/trains.js — 发布列车, at /trains (claude-fleet#3870, EPIC
// #3863 C7): every release-train run of the last 7 days, newest first, as one
// time bar — board, Linux, hub, release, the Mac half after it — against the
// 5-minute line; a slow or unshipped one says where it stuck, in the hub's own
// words (the same line its run summary prints). Four KPIs above, the two
// lanes (stable · stable-macos). A row opens its merges and its stage table.
// One read: GET /v1/fleet/release/stats — the ledger, 共同约定 7. An admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, relTime } from '../lib/shell.js';
import { fmtSecs, scaleOf, bars, state, whyLine, kpis, lanes, SLOW_SECS } from '../lib/trains.js';
import { t } from '../lib/i18n.js';

const S = { st: null, open: '' };

function kpiHTML(k) {
  return `<div class="kpi"><span class="lbl">${esc(k.label)}</span><span class="val ${esc(k.cls)}">${esc(k.value)}</span>` +
    `${k.sub ? `<span class="tr-sub">${esc(k.sub)}</span>` : ''}</div>`;
}

function laneHTML(l) {
  return `<span><span class="dot ${esc(l.cls)}"></span> ${esc(l.label)} <b class="mono">${esc(l.sha)}</b>` +
    `${l.note ? ` <span class="tr-sub">${esc(l.note)}</span>` : ''}</span>`;
}

function detailHTML(r) {
  const merges = (r.merges || []).map((m) => `<div>· <span class="mono">${esc(String(m.sha).slice(0, 7))}</span> ${esc(m.subject || '')}</div>`).join('') ||
    `<div class="tr-sub">${esc(t('ui.tr.noMerges'))}</div>`;
  const rows = (r.stages || []).map((s) => `<tr><td>${esc(s.name)}${s.off_path ? ` <span class="tr-sub">${esc(t('ui.tr.offPath'))}</span>` : ''}</td>` +
    `<td class="n">+${esc(fmtSecs(s.offset_secs))}</td><td class="n">${esc(fmtSecs(s.secs))}</td>` +
    `<td class="n">${s.off_path ? '—' : esc(fmtSecs(s.budget_secs))}</td><td class="n">${esc(s.result || '')}</td></tr>`).join('');
  const mac = r.mac ? `<div style="margin-top:6px">${esc(t('ui.tr.macAfter', { c: r.mac.conclusion, after: fmtSecs(r.mac.after_secs) }))}</div>` : '';
  const link = r.run_url ? ` · <a href="${esc(r.run_url)}" target="_blank" rel="noopener">${esc(t('ui.tr.openRun'))}</a>` : '';
  return `<div class="tr-detail">${merges}<table><thead><tr><td>${esc(t('ui.tr.col.stage'))}</td><td class="n">${esc(t('ui.tr.col.at'))}</td>` +
    `<td class="n">${esc(t('ui.tr.col.secs'))}</td><td class="n">${esc(t('ui.tr.col.budget'))}</td><td class="n">${esc(t('ui.tr.col.result'))}</td></tr></thead>` +
    `<tbody>${rows}</tbody></table>${mac}<div class="tr-sub" style="margin-top:6px">run ${esc(r.run_id)}${link}</div></div>`;
}

function runHTML(r, max) {
  const [cls, words] = state(r);
  const segs = bars(r, max).map((b) => `<span class="tr-seg ${b.kind}${b.off ? ' off' : ''}${b.red ? ' red' : ''}" title="${esc(b.title)}" ` +
    `style="left:${b.left.toFixed(2)}%;width:${b.width.toFixed(2)}%">${b.queue ? `<i style="width:${((b.queue / b.width) * 100).toFixed(1)}%"></i>` : ''}${esc(b.name)}</span>`).join('');
  const five = `<span class="tr-five" style="left:${((SLOW_SECS / max) * 100).toFixed(2)}%" title="${esc(t('ui.tr.five'))}"></span>`;
  const why = whyLine(r);
  const shipped = r.conclusion === 'success' || r.conclusion === 'superseded';
  return `<div class="tr-run" data-run="${esc(r.run_id)}" tabindex="0" aria-expanded="${S.open === r.run_id}">` +
    `<div class="tr-top"><b class="mono">${esc(String(r.sha).slice(0, 7))}</b>` +
    `<span class="tr-sub">${esc(t('ui.tr.merges', { n: (r.merges || []).length }))}</span><span class="chip ${cls}">${esc(words)}</span>` +
    `<time class="tr-sub" datetime="${esc(r.started_at)}">${esc(relTime(r.started_at))}</time>` +
    `<span class="tot${r.total_secs > SLOW_SECS ? ' bad' : ''}">${esc(fmtSecs(r.total_secs))}</span></div>` +
    `<div class="tr-gantt">${segs}${five}</div>` +
    `${why ? `<div class="tr-why${shipped ? '' : ' bad'}">${esc(why)}</div>` : ''}` +
    `${S.open === r.run_id ? detailHTML(r) : ''}</div>`;
}

function draw(ctx) {
  const st = S.st || {};
  const runs = st.runs || [];
  const max = scaleOf(runs);
  const legend = [['lin', 'ui.tr.lg.lin'], ['hub', 'ui.tr.lg.hub'], ['rel', 'ui.tr.lg.rel'], ['mac', 'ui.tr.lg.mac'], ['board', 'ui.tr.lg.board']]
    .map(([k, l]) => `<span><i class="tr-seg ${k}" style="position:static"></i>${esc(t(l))}</span>`).join('') +
    `<span><i style="border-left:2px dashed var(--warn);border-radius:0;width:0"></i>${esc(t('ui.tr.five'))}</span>`;
  const list = runs.length ? runs.map((r) => runHTML(r, max)).join('')
    : `<div class="empty">${ic('fleet')}<b>${esc(t('ui.tr.empty'))}</b><span>${esc(t('ui.tr.emptySub'))}</span></div>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.tr.lead', { days: st.days || 7 }))}</p></div></div>` +
    `<div class="tr-kpis">${kpis(st).map(kpiHTML).join('')}</div>` +
    `<div class="panel"><div class="tr-lanes">${lanes(st).map(laneHTML).join('')}</div>` +
    `<div id="trrows">${list}</div><div class="tr-legend">${legend}</div></div>`;
}

export default Shell.mount('trains', async (ctx) => {
  S.st = await ctx.api('/v1/fleet/release/stats?days=7');
  draw(ctx);
  const toggle = (e) => {
    const r = e.target.closest('[data-run]');
    if (!r || e.target.closest('a')) return;
    S.open = S.open === r.dataset.run ? '' : r.dataset.run;
    draw(ctx);
    const again = ctx.el.querySelector(`[data-run="${CSS.escape(r.dataset.run)}"]`);
    if (again) again.focus();
  };
  ctx.el.onclick = toggle;
  ctx.el.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle(e); } };
});
