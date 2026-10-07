// web/dist/sessions-page.js — Sessions, at /sessions (claude-fleet#1989):
// every open session the viewer may see — a user their own, an admin the
// whole fleet — filtered by state, searched, and opened into a side drawer
// with how to reach it from a terminal and what it has done.
//
// Rows are /v1/fleet/fleet_sessions; context %, model and (admin) the
// subscription are joined from /v1/live by worktree. Re-read every 15 s while
// the tab is visible; the filter, search and an open drawer survive it.
import { Shell } from './app-shell.js';
import { esc, ic, ctxBar, relTime } from './lib/shell.js';
import { sessionRows, counts, filterRows, stateOf, FILTERS, hhmm } from './lib/pages.js';
import { t, punct } from './lib/i18n.js';

const S = { filter: 'all', query: '', rows: [], open: '' };

const dot = (st) => `<span class="dot ${stateOf(st).dot}"></span>`;

function table(ctx) {
  const a = ctx.admin;
  const rows = filterRows(S.rows, S.filter, S.query);
  const cols = a ? 8 : 6;
  if (!S.rows.length) return `<tr><td colspan="${cols}"><div class="empty">${ic('list')}<b>${esc(t('ui.ses.none'))}</b><span>${esc(t(a ? 'ui.ses.noneAdmin' : 'ui.ses.noneUser'))}</span></div></td></tr>`;
  if (!rows.length) return `<tr><td colspan="${cols}"><div class="empty">${ic('search')}<b>${esc(t('ui.ses.noMatch'))}</b><span>${esc(t('ui.ses.noMatchSub'))}</span></div></td></tr>`;
  return rows.map((r) => `<tr class="click" data-id="${esc(r.id)}" tabindex="0"><td><div class="status">${dot(r.state)}<span><span class="sname">${esc(r.key)}</span><br><span class="repo">${esc(r.title || '—')}</span></span></div></td>` +
    `<td class="repo mono">${esc(r.repo || '—')}</td><td>${esc(stateOf(r.state).label)}</td><td class="mono">${esc(r.machine)}${r.availability !== 'online' ? ` <span class="chip ${r.availability === 'lost' ? 'bad' : 'warn'}">${esc(t('ui.avail.' + (r.availability === 'lost' ? 'lost' : 'maintenance')))}</span>` : ''}</td>` +
    (a ? `<td>${esc(r.person || '—')}</td><td>${esc(r.account || '—')}</td>` : '') +
    `<td>${ctxBar(r.ctx)}</td><td class="mono r">${esc(hhmm(r.born))}</td></tr>`).join('');
}

function draw(ctx) {
  const c = counts(S.rows);
  const seg = FILTERS.map(([f, label]) => `<button data-f="${f}" aria-pressed="${S.filter === f}">${esc(t(label))} <span class="n">${c[f]}</span></button>`).join('');
  const a = ctx.admin;
  const box = ctx.el.querySelector('#sq');
  if (box) { ctx.el.querySelector('#seg').innerHTML = seg; ctx.el.querySelector('#rows').innerHTML = table(ctx); return; }
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t(a ? 'ui.ses.subAdmin' : 'ui.ses.subUser'))}${punct().gap}${t('ui.ses.history', { cmd: '<code>/fleet-history</code>' })}</p></div></div>` +
    `<div class="panel"><div class="panel-h"><div class="toolbar"><div class="seg" id="seg" role="group" aria-label="${esc(t('ui.ses.filter'))}">${seg}</div></div><label class="search">${ic('search')}<input class="input" id="sq" placeholder="${esc(t('ui.ses.search'))}" aria-label="${esc(t('ui.ses.search'))}"></label></div>` +
    `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.col.session'))}</th><th>${esc(t('ui.col.repo'))}</th><th>${esc(t('ui.col.state'))}</th><th>${esc(t('ui.col.machine'))}</th>${a ? `<th>${esc(t('ui.col.person'))}</th><th>${esc(t('ui.col.subscription'))}</th>` : ''}<th>${esc(t('ui.col.context'))}</th><th class="r">${esc(t('ui.col.started'))}</th></tr></thead><tbody id="rows">${table(ctx)}</tbody></table></div></div>`;
  ctx.el.querySelector('#sq').value = S.query;
  ctx.el.querySelector('#sq').addEventListener('input', (e) => { S.query = e.target.value; draw(ctx); });
  ctx.el.querySelector('#seg').addEventListener('click', (e) => { const b = e.target.closest('[data-f]'); if (b) { S.filter = b.dataset.f; draw(ctx); } });
  const openRow = (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) { S.open = tr.dataset.id; detail(ctx); } };
  ctx.el.querySelector('#rows').addEventListener('click', openRow);
  ctx.el.querySelector('#rows').addEventListener('keydown', (e) => { if (e.key === 'Enter') openRow(e); });
}

function detail(ctx) {
  const r = S.rows.find((x) => x.id === S.open);
  if (!r) return;
  const st = stateOf(r.state);
  const cmd = `fleet connect ${r.machine}`;
  const tl = [];
  if (r.born) tl.push([t('ui.ses.startedOn', { m: r.machine }), hhmm(r.born)]);
  if (r.needs) tl.push([r.needs, '']);
  tl.push([r.state === 'waiting' ? t('ui.ses.waitingYou', { state: st.label }) : st.label, r.observed ? relTime(r.observed) : t('ui.now')]);
  ctx.drawer(`<div class="modal-h"><div style="display:grid;gap:2px;min-width:0"><h3 class="mono">${esc(r.key)}</h3><span style="font-size:12.5px;color:var(--muted)">${esc(r.repo || t('ui.ses.noRepo'))}</span></div><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>` +
    `<div class="modal-b"><div class="status">${dot(r.state)}<b>${esc(st.label)}</b></div>` +
    (r.title ? `<p style="font-size:15px;font-weight:500">${esc(r.title)}</p>` : '') +
    `<dl class="kv"><dt>${esc(t('ui.col.machine'))}</dt><dd class="mono">${esc(r.machine)}</dd><dt>${esc(t('ui.ses.agent'))}</dt><dd>${esc(r.agent || '—')}${r.model ? ` · <span class="mono">${esc(r.model)}</span>` : ''}</dd>` +
    (ctx.admin ? `<dt>${esc(t('ui.col.person'))}</dt><dd>${esc(r.person || '—')}</dd><dt>${esc(t('ui.col.subscription'))}</dt><dd>${esc(r.account || '—')}</dd>` : '') +
    `<dt>${esc(t('ui.col.context'))}</dt><dd>${ctxBar(r.ctx)}</dd><dt>${esc(t('ui.col.started'))}</dt><dd class="mono">${esc(hhmm(r.born))}</dd>${r.worktree ? `<dt>${esc(t('ui.ses.worktree'))}</dt><dd class="mono">${esc(r.worktree)}</dd>` : ''}</dl>` +
    `<div><h4 style="font:600 13px var(--f-ui);margin-bottom:10px">${esc(t('ui.ses.attach'))}</h4><div class="cmdbox"><span>${esc(cmd)}</span><button class="btn sm" data-shell="copy" data-text="${esc(cmd)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div><p style="font-size:12.5px;color:var(--muted);margin-top:8px">${t('ui.ses.attachHint', { m: esc(r.machine), key: `<span class="mono">${esc(r.key)}</span>` })}</p></div>` +
    `<div><h4 style="font:600 13px var(--f-ui);margin-bottom:10px">${esc(t('ui.ses.timeline'))}</h4><div class="timeline">${tl.map(([t, w]) => `<div>${esc(t)}<span>${esc(w)}</span></div>`).join('')}</div></div></div>`);
}

Shell.mount('sessions', async (ctx) => {
  const load = async (fresh) => {
    const [fs, live] = await Promise.all([ctx.fleet(fresh), ctx.api('/v1/live').catch(() => null)]);
    S.rows = sessionRows(fs, live);
    draw(ctx);
    ctx.setCount('sessions', S.rows.length);
  };
  await load(false);
  if (!S.timer) S.timer = setInterval(() => { if (!document.hidden) load(true).catch(() => {}); }, 15000);
});
