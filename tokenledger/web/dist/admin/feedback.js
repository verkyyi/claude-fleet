// web/dist/admin/feedback.js — 反馈, at /admin/feedback (claude-fleet#3357,
// EPIC #3354 C3): every /fleet-feedback the hub took, newest first, filtered by
// state. A row opens a drawer with what the public issue never says — who, the
// login, the machine, the session — the attachments (already held against the
// secret shapes, kept seven days), the GitHub issue and the reply, plus
// 「在 GitHub 打开」 and 「标为重复」. /v1/admin/feedback; an admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, relTime } from '../lib/shell.js';
import { FEEDBACK_STATES, feedbackState, feedbackKind, fmtBytes } from '../lib/admin.js';
import { t } from '../lib/i18n.js';

const avatar = (who) => `<span class="av" style="background:var(--brand)">${esc(String(who || '?').slice(0, 2).toUpperCase())}</span>`;
const chip = (st) => { const [c, w] = feedbackState(st); return `<span class="chip ${c}">${esc(w)}</span>`; };

// The filter is the address's (?state=), read on every draw.
function stateFromURL() {
  let s = 'all';
  try { s = new URLSearchParams(location.search).get('state') || 'all'; } catch { /* default */ }
  return FEEDBACK_STATES.includes(s) ? s : 'all';
}

const S = { state: 'all', rows: [], next: '', counts: {} };

const rowHTML = (f) => `<div class="ev click" data-id="${esc(f.id)}" tabindex="0">${avatar(f.login || f.who)}` +
  `<span class="what"><b class="mono" style="font-weight:500">${esc(f.id)}</b> · <b style="font-weight:500">${esc(f.who || f.login)}</b>` +
  ` <span class="sub">${esc([f.host, feedbackKind(f.machine_kind), f.agent].filter(Boolean).join(' · '))}</span>` +
  `<br><span>${esc(f.text)}</span>` +
  `${f.attachments ? ` <span class="sub">${ic('download')}${esc(t('ui.fb.nAttach', { n: f.attachments }))}</span>` : ''}` +
  `${f.gh_number ? ` <span class="sub">#${esc(f.gh_number)}</span>` : ''}</span>` +
  `${chip(f.state)}<time datetime="${esc(f.created_at)}">${esc(relTime(f.created_at))}</time></div>`;

function list() {
  if (!S.rows.length) {
    return `<div class="empty">${ic('scroll')}<b>${esc(t('ui.fb.empty'))}</b><span>${esc(t(S.state === 'all' ? 'ui.fb.emptySub' : 'ui.fb.emptyState'))}</span></div>`;
  }
  return S.rows.map(rowHTML).join('') +
    (S.next ? `<div style="padding:12px;text-align:center"><button class="btn sm" data-more>${esc(t('ui.fb.more'))}</button></div>` : '');
}

async function load(ctx, more) {
  const q = new URLSearchParams();
  if (S.state !== 'all') q.set('state', S.state);
  if (more && S.next) q.set('before', S.next);
  const qs = q.toString();
  const a = await ctx.api('/v1/admin/feedback' + (qs ? '?' + qs : ''));
  S.rows = more ? S.rows.concat(a.feedback || []) : (a.feedback || []);
  S.next = a.next || '';
  S.counts = a.counts || {};
}

function draw(ctx) {
  const all = Object.values(S.counts).reduce((x, y) => x + y, 0);
  const seg = FEEDBACK_STATES.map((s) => `<button data-state="${s}" aria-pressed="${s === S.state}">${esc(t(s === 'all' ? 'ui.aud.k.all' : 'ui.fb.s.' + s))}<span class="n">${s === 'all' ? all : S.counts[s] || 0}</span></button>`).join('');
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.fb.lead'))}</p></div></div>` +
    `<div class="panel"><div class="panel-h"><div class="seg" role="group" aria-label="${esc(t('ui.aud.filter'))}" style="flex-wrap:wrap">${seg}</div><span class="sub">${esc(t('ui.aud.shown', { n: S.rows.length }))}</span></div><div class="alog" id="fbrows">${list()}</div></div>`;
  ctx.setCount('feedback', S.counts.received || 0);
}

async function detail(ctx, id) {
  let f;
  try { f = await ctx.api('/v1/admin/feedback/' + encodeURIComponent(id)); } catch (e) { ctx.toast(e.message || String(e)); return; }
  const kv = (k, v) => `<dt>${esc(t(k))}</dt><dd>${v}</dd>`;
  const c = f.ctx || {};
  const mono = (v) => (v ? `<span class="mono">${esc(v)}</span>` : '—');
  const atts = (f.attach || []).length
    ? (f.attach || []).map((a) => `<div style="margin:6px 0"><a class="btn sm" href="${esc(a.url)}" download>${ic('download')}${esc(a.name)}</a> <span class="sub">${esc(fmtBytes(a.size))}</span>` +
      ` <button class="btn ghost sm" data-peek="${esc(a.url)}">${esc(t('ui.fb.peek'))}</button></div>`).join('') + `<pre class="mono" id="fbpeek" hidden style="max-height:40vh;overflow:auto;white-space:pre-wrap;font-size:12px"></pre>`
    : `<span class="sub">${esc(t('ui.fb.noAttach'))}</span>`;
  const gh = f.gh_url ? `<a href="${esc(f.gh_url)}" target="_blank" rel="noopener">#${esc(f.gh_number)}</a>` : `<span class="sub">${esc(t('ui.fb.notFiled'))}</span>`;
  const reply = f.reply ? `${esc(f.reply)}${f.replied_at ? ` <span class="sub">(${esc(t('ui.fb.delivered', { at: relTime(f.replied_at) }))})</span>` : ` <span class="sub">(${esc(t('ui.fb.notDelivered'))})</span>`}` : '—';
  const acts = (f.gh_url ? `<a class="btn" href="${esc(f.gh_url)}" target="_blank" rel="noopener">${ic('git')}${esc(t('ui.fb.openGH'))}</a>` : '') +
    (f.state !== 'closed' ? `<button class="btn" data-dup>${ic('copy')}${esc(t('ui.fb.dup'))}</button>` : '');
  ctx.drawer(`<div class="modal-h"><div style="display:grid;gap:2px;min-width:0"><h3 class="mono">${esc(f.id)}</h3><span style="font-size:12.5px;color:var(--muted)">${esc(new Date(f.created_at).toLocaleString())}</span></div><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div>` +
    `<div class="modal-b"><div class="status">${chip(f.state)}</div><p style="white-space:pre-wrap">${esc(f.text)}</p>` +
    `<dl class="kv">${kv('ui.fb.who', esc(f.who || '—'))}${kv('ui.fb.login', mono(f.login))}${kv('ui.fb.host', mono(f.host))}` +
    `${kv('ui.fb.kind', esc(feedbackKind(f.machine_kind)) + (f.agent ? ' · ' + esc(f.agent) : ''))}` +
    `${kv('ui.fb.session', [c.window, c.cc_session].filter(Boolean).map(mono).join(' · ') || '—')}${kv('ui.fb.worker', mono(c.worker_id))}` +
    `${kv('ui.fb.version', mono(c.fleet_version))}${kv('ui.fb.issue', gh)}${kv('ui.fb.reply', reply)}${kv('ui.fb.attach', atts)}</dl>` +
    `<div class="acts" style="display:flex;gap:8px;flex-wrap:wrap">${acts}</div></div>`);
  const layer = document.getElementById('layer');
  if (!layer) return;
  layer.querySelectorAll('[data-peek]').forEach((b) => b.addEventListener('click', async () => {
    const pre = layer.querySelector('#fbpeek');
    try {
      const r = await fetch(b.dataset.peek + '?inline=1', { credentials: 'same-origin' });
      const ty = r.headers.get('Content-Type') || '';
      pre.textContent = !r.ok ? `${r.status}` : ty.startsWith('text/') ? (await r.text()).slice(0, 65536) : t('ui.fb.binary');
    } catch (e) { pre.textContent = e.message || String(e); }
    pre.hidden = false;
  }));
  const dup = layer.querySelector('[data-dup]');
  if (dup) dup.addEventListener('click', async () => {
    const of = (window.prompt(t('ui.fb.dupOf')) || '').trim();
    if (!of) return;
    dup.disabled = true;
    try {
      const out = await ctx.api('/v1/admin/feedback/' + encodeURIComponent(f.id) + '/duplicate', { json: { of } });
      ctx.toast(out.note || t('ui.fb.dupDone', { reply: out.reply }));
      ctx.close();
      await ctx.refresh();
    } catch (e) {
      dup.disabled = false;
      ctx.toast(t('ui.err.action', { e: e.message }));
    }
  });
}

export default Shell.mount('feedback', async (ctx) => {
  S.state = stateFromURL();
  await load(ctx, false);
  draw(ctx);
  const open = (e) => { const r = e.target.closest('[data-id]'); if (r) detail(ctx, r.dataset.id); };
  ctx.el.onclick = async (e) => {
    const b = e.target.closest('[data-state]');
    if (b && b.dataset.state !== S.state) {
      S.state = b.dataset.state;
      try { history.replaceState(null, '', S.state === 'all' ? location.pathname : '?state=' + S.state); } catch { /* fine */ }
      ctx.refresh();
      return;
    }
    if (e.target.closest('[data-more]')) {
      try { await load(ctx, true); draw(ctx); } catch (err) { ctx.toast(err.message || String(err)); }
      return;
    }
    open(e);
  };
  ctx.el.onkeydown = (e) => { if (e.key === 'Enter') open(e); };
});
