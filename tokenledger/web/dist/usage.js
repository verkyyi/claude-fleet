// web/dist/usage.js — 我的用量, at /usage: one page for how much is left, how
// much each day, which models and where it went (claude-fleet#3229, EPIC #3225
// C4; 我的额度 at /quota moved here, lib/router.js MOVED). Reads only
// /v1/me/usage (C2), the viewer's own pool usage — never the pool's windows.
// The range rides ?range=; where-it-went's switch and the drawer stay in the
// page. Under 520px the breakdown is one line a row. lib/usage-view.js draws.
import { Shell } from './app-shell.js';
import { esc } from './lib/shell.js';
import { t } from './lib/i18n.js';
import { RANGES, MODES, rangeOf, kpis, dayChart, modelBars, workRows, workTable, workList, workDrawer } from './lib/usage-view.js';

const NARROW = '(max-width: 520px)';

export default Shell.mount('usage', async (ctx) => {
  const range = rangeOf(new URLSearchParams(location.search).get('range'));
  const u = await ctx.api('/v1/me/usage?range=' + range);
  const rangeKey = (RANGES.find((r) => r[0] === range) || RANGES[1])[1];
  const mq = typeof matchMedia === 'function' ? matchMedia(NARROW) : null;
  let mode = 'issue';
  let rows = workRows(u.work, mode);

  const seg = (items, cur, attr) => `<div class="seg" role="group">` +
    items.map(([v, k]) => `<button type="button" data-${attr}="${v}" aria-pressed="${v === cur}">${esc(t(k))}</button>`).join('') + '</div>';
  const work = () => (mq && mq.matches ? workList(rows, mode) : workTable(rows, mode));
  const narrow = mq && mq.matches ? ' style="grid-template-columns:1fr 1fr"' : '';

  const draw = () => {
    ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.use.sub'))}</p></div><div class="acts">${seg(RANGES, range, 'range')}</div></div>` +
      `<div class="grid g4"${narrow}>${kpis(u).join('')}</div>` +
      `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.use.perDay'))}</h3><div class="legend"><span><i style="background:var(--brand)"></i>Claude</span><span><i style="background:var(--codex)"></i>Codex</span></div></div><div class="panel-b">${dayChart(u.days)}</div></div>` +
      `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.use.models'))}</h3><span class="sub">${esc(t(rangeKey))}</span></div><div class="panel-b">${modelBars(u.models)}</div></div></div>` +
      `<div class="panel" id="work"><div class="panel-h"><div><h3>${esc(t('ui.use.where'))}</h3><span class="sub">${esc(t('ui.use.whereSub'))}</span></div>${seg(MODES, mode, 'tab')}</div><div id="work-b">${work()}</div></div>`;
  };
  draw();

  const open = (i) => {
    const r = rows[i];
    if (r) ctx.drawer(workDrawer(r, mode, { work: u.work, me: ctx.me && (ctx.me.name || ctx.me.login), rangeKey }));
  };
  ctx.on(ctx.el, 'click', (e) => {
    const rb = e.target.closest('[data-range]');
    if (rb) {
      const q = new URLSearchParams(location.search);
      if (rb.dataset.range === '7d') q.delete('range'); else q.set('range', rb.dataset.range);
      ctx.navigate(location.pathname + (q.toString() ? '?' + q : ''));
      return;
    }
    const tb = e.target.closest('[data-tab]');
    if (tb) {
      mode = tb.dataset.tab;
      rows = workRows(u.work, mode);
      for (const b of ctx.el.querySelectorAll('[data-tab]')) b.setAttribute('aria-pressed', String(b.dataset.tab === mode));
      ctx.el.querySelector('#work-b').innerHTML = work();
      return;
    }
    const row = e.target.closest('[data-row]');
    if (row) open(+row.dataset.row);
  });
  ctx.on(ctx.el, 'keydown', (e) => {
    const row = e.key === 'Enter' && e.target.closest && e.target.closest('[data-row]');
    if (row) open(+row.dataset.row);
  });
  if (mq) ctx.on(mq, 'change', draw);
});
