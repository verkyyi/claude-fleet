// web/dist/tasks.js — 任务, at /tasks (claude-fleet#3325, EPIC #3178): what the
// viewer asked for, as the hub keeps it — one record T<n> per ⌘P task, written
// before its session was placed. A task that chose a repo carries its GitHub
// issue; one with no repo is the record alone until 「建 GitHub 单」 files one.
// The record's session state is the inventory's own word (`live`), read beside
// the record by /v1/fleet/tasks; the list re-reads on the push channel's
// `sessions` answer.
import { Shell } from './app-shell.js';
import { esc, ic, relTime } from './lib/shell.js';
import { taskRows, taskCounts, TASK_FILTERS, filterTasks, stateOf, hhmm } from './lib/pages.js';
import { t } from './lib/i18n.js';

const S = { filter: 'all', query: '', rows: [], open: '' };

const dot = (st) => `<span class="dot ${stateOf(st).dot}"></span>`;
const ghLink = (r) => (r.issueURL ? `<a href="${esc(r.issueURL)}" target="_blank" rel="noopener">#${esc(r.issueN)}</a>` : '—');

function table() {
  const rows = filterTasks(S.rows, S.filter, S.query);
  if (!S.rows.length) return `<tr><td colspan="7"><div class="empty">${ic('scroll')}<b>${esc(t('ui.task.none'))}</b><span>${esc(t('ui.task.noneHint'))}</span></div></td></tr>`;
  if (!rows.length) return `<tr><td colspan="7"><div class="empty">${ic('search')}<b>${esc(t('ui.ses.noMatch'))}</b><span>${esc(t('ui.ses.noMatchSub'))}</span></div></td></tr>`;
  return rows.map((r) => `<tr class="click" data-id="${esc(r.id)}" tabindex="0"><td class="mono">${esc(r.id)}</td>` +
    `<td>${esc(r.title)}</td><td>${esc(r.owner)}</td>` +
    `<td class="mono">${esc(r.machine || '—')}${r.session ? ` · ${esc(r.session)}` : ''}</td>` +
    `<td><div class="status">${dot(r.state)}<span>${esc(r.stateLabel)}</span></div></td>` +
    `<td>${ghLink(r)}</td><td class="mono r">${esc(hhmm(r.born))}</td></tr>`).join('');
}

function draw(ctx) {
  const c = taskCounts(S.rows);
  const seg = TASK_FILTERS.map(([f, label]) => `<button data-f="${f}" aria-pressed="${S.filter === f}">${esc(t(label))} <span class="n">${c[f]}</span></button>`).join('');
  if (ctx.el.querySelector('#tq')) {
    ctx.el.querySelector('#tseg').innerHTML = seg;
    ctx.el.querySelector('#trows').innerHTML = table();
    ctx.el.querySelector('#tband').textContent = t('ui.task.band', c);
    return;
  }
  ctx.el.innerHTML = `<div class="pagehead"><div><p id="tband">${esc(t('ui.task.band', c))}</p></div></div>` +
    `<div class="panel"><div class="panel-h"><div class="toolbar"><div class="seg" id="tseg" role="group" aria-label="${esc(t('ui.ses.filter'))}">${seg}</div></div><label class="search">${ic('search')}<input class="input" id="tq" placeholder="${esc(t('ui.task.search'))}" aria-label="${esc(t('ui.task.search'))}"></label></div>` +
    `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.task.colId'))}</th><th>${esc(t('ui.task.colTitle'))}</th><th>${esc(t('ui.col.person'))}</th><th>${esc(t('ui.task.colWhere'))}</th><th>${esc(t('ui.col.state'))}</th><th>GitHub</th><th class="r">${esc(t('ui.col.started'))}</th></tr></thead><tbody id="trows">${table()}</tbody></table></div></div>`;
  ctx.el.querySelector('#tq').value = S.query;
  ctx.el.querySelector('#tq').addEventListener('input', (e) => { S.query = e.target.value; draw(ctx); });
  ctx.el.querySelector('#tseg').addEventListener('click', (e) => { const b = e.target.closest('[data-f]'); if (b) { S.filter = b.dataset.f; draw(ctx); } });
  const openRow = (e) => { const tr = e.target.closest('tr[data-id]'); if (tr) { S.open = tr.dataset.id; detail(ctx); } };
  ctx.el.querySelector('#trows').addEventListener('click', openRow);
  ctx.el.querySelector('#trows').addEventListener('keydown', (e) => { if (e.key === 'Enter') openRow(e); });
}

function detail(ctx) {
  const r = S.rows.find((x) => x.id === S.open);
  if (!r) return;
  const kv = (k, v) => `<dt>${esc(t(k))}</dt><dd>${v}</dd>`;
  const from = [r.via, r.device, r.born ? new Date(r.born * 1000).toLocaleTimeString() : ''].filter(Boolean).map(esc).join(' · ');
  const where = [r.machine, r.repo || t('ui.ses.noRepo'), r.agent, r.session].filter(Boolean).map(esc).join(' · ');
  const state = `${esc(r.stateLabel)}${r.observed ? ` <span class="sub">(${esc(relTime(r.observed))})</span>` : ''}${r.ctxLeft != null ? ` · ${esc(t('ui.task.ctxLeft', { n: r.ctxLeft }))}` : ''}`;
  const attach = r.issueURL ? `${ghLink(r)}${r.repoChosen ? ` <span class="sub">${esc(t('ui.task.becauseRepo'))}</span>` : ''}`
    : `<span class="sub">${esc(t('ui.task.noIssue'))}</span>`;
  const fileBtn = r.issueURL ? '' : `<div><button class="btn sm" data-task-issue="${esc(r.id)}">${ic('plus')} ${esc(t('ui.task.fileIssue'))}</button>` +
    `<p class="sub" style="margin-top:6px">${esc(t('ui.task.fileIssueHint'))}</p></div>`;
  ctx.drawer(`<div class="modal-h"><div style="display:grid;gap:2px;min-width:0"><h3 class="mono">${esc(r.id)}</h3><span style="font-size:12.5px;color:var(--muted)">${esc(r.title)}</span></div><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>` +
    `<div class="modal-b"><div class="status">${dot(r.state)}<b>${esc(r.stateLabel)}</b></div>` +
    (r.note ? `<p class="sub">${esc(r.note)}</p>` : '') +
    `<dl class="kv">${kv('ui.task.from', from || '—')}${kv('ui.task.where', where || '—')}${kv('ui.col.state', state)}${kv('ui.task.attach', attach)}` +
    `${kv('ui.task.asked', esc(r.asked || '—'))}${r.parked ? kv('ui.task.parked', esc(r.parked)) : ''}</dl>${fileBtn}</div>`);
  const b = document.querySelector(`[data-task-issue="${CSS.escape(r.id)}"]`);
  if (b) b.addEventListener('click', async () => {
    let repo = r.repo;
    if (!repo) {
      repo = (window.prompt(t('ui.task.whichRepo')) || '').trim();
      if (!repo) return;
    }
    b.disabled = true;
    try {
      await ctx.api(`/v1/fleet/tasks/${encodeURIComponent(r.id)}/issue`, { json: { repo } });
      ctx.toast(t('ui.task.filed'));
      await load(ctx);
      detail(ctx);
    } catch (e) {
      b.disabled = false;
      ctx.toast(e.message || String(e));
    }
  });
}

async function load(ctx) {
  const body = await ctx.api('/v1/fleet/tasks');
  S.rows = taskRows(body);
  draw(ctx);
  ctx.setCount('tasks', S.rows.length);
}

export default Shell.mount('tasks', async (ctx) => {
  await load(ctx);
  ctx.subscribe('sessions', () => { load(ctx).catch(() => {}); }, { min: 5000 });
});
