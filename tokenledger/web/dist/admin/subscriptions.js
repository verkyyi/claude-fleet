// web/dist/admin/subscriptions.js — Subscriptions, at /subscriptions
// (claude-fleet#1990): the pool at a glance, one card per subscription (5-hour
// and weekly use with their resets, live sessions, the credential, pause /
// remove behind a confirm), the three-step add (provider → run the commands on
// a machine and wait for it to arrive → done), who is on which, and recent
// switches. Reads /v1/limits, /v1/accounts, /v1/fleet/credentials, /v1/live,
// /v1/fleet/users and /v1/account-switches; pause is the setting
// pool.paused.<account>, remove deletes the vault's credential. An admin's.
import { Shell } from '../app-shell.js';
import { esc, ic, relTime } from '../lib/shell.js';
import {
  subscriptions, subState, credState, headroom, leaseRows, switchRows, level, fmtIn,
  addSubCommands, arrived, LABEL_RE,
} from '../lib/admin.js';
import { t } from '../lib/i18n.js';

const failed = (e) => `<div class="ghostrow err">${ic('alert')} ${esc(e.message)}</div>`;
const val = (r) => (r.status === 'fulfilled' ? r.value : null);

function win(name, w, skip) {
  if (!w || w.p == null) return `<div class="win"><div class="win-h"><span>${esc(name)}</span><b>—</b></div><div class="track"><i style="width:0"></i></div></div>`;
  const reset = fmtIn(w.resets);
  return `<div class="win"><div class="win-h"><span>${esc(name)}</span><b>${w.p}%</b></div><div class="track"><i class="${level(w.p, skip)}" style="width:${w.p}%"></i></div>` +
    (reset ? `<div class="win-h"><span>${esc(t('ui.sub.resets', { when: reset }))}</span></div>` : '') + '</div>';
}

function card(s, skip) {
  const st = subState(s, skip);
  const chip = st === 'paused' ? `<span class="chip">${esc(t('ui.sub.paused'))}</span>`
    : st === 'full' ? `<span class="chip warn">${esc(t('ui.sub.full'))}</span>`
      : `<span class="chip ok"><span class="dot ok"></span>${esc(t('ui.sub.active'))}</span>`;
  const cs = credState(s.cred);
  const acts = s.cred
    ? `<div class="sub-acts"><button class="btn sm" data-act="pause" data-id="${esc(s.id)}">${s.paused ? ic('play') + esc(t('ui.sub.resume')) : ic('pause') + esc(t('ui.sub.pause'))}</button>` +
      `<button class="btn sm danger" data-act="remove" data-id="${esc(s.id)}">${ic('trash')}${esc(t('ui.sub.remove'))}</button></div>`
    : `<div class="sub-acts"><span class="chip" title="${esc(t('ui.sub.notPoolHint'))}">${esc(t('ui.sub.notPool'))}</span></div>`;
  return `<div class="panel sub${s.paused ? ' paused' : ''}"><div class="sub-top"><span class="prov ${s.prov}">${s.prov === 'codex' ? 'X' : 'C'}</span>` +
    `<div class="t"><b>${esc(s.label)}</b><span>${esc(s.plan || (s.prov === 'codex' ? 'Codex' : 'Claude'))}</span></div>${chip}</div>` +
    (s.available || s.h5 || s.h7 ? win(t('ui.sub.h5'), s.h5, skip) + win(t('ui.sub.h7'), s.h7, skip)
      : `<div class="win-h"><span>${esc(s.reason || t('ui.sub.noUsage'))}</span></div>`) +
    `<div class="sub-meta"><div><span>${esc(t('ui.sub.sessionsNow'))}</span>${s.sessions}</div>` +
    (s.readAt ? `<div title="${esc(s.readNote)}"><span>${esc(t('ui.sub.lastRead'))}</span>${esc(relTime(s.readAt))}` +
      (s.readVia ? ` · ${esc(t(s.readVia === 'hub' ? 'ui.sub.viaHub' : 'ui.sub.viaNode'))}` : '') + '</div>' : '') +
    `<div><span>${esc(t('ui.sub.cred'))}</span><span class="chip ${cs.tone}">${ic('shield')}${esc(cs.text)}</span></div></div>` +
    acts + '</div>';
}

// The add flow: step 0 provider + label, 1 the commands and the wait, 2 done.
const add = { step: 0, prov: 'claude', label: '', since: 0, timer: 0, from: '' };

function addModal(ctx) {
  const steps = [t('ui.sub.add.s1'), t('ui.sub.add.s2'), t('ui.sub.add.s3')];
  const sp = '<div class="stepper">' + steps.map((n, i) => `<span class="${i === add.step ? 'on' : i < add.step ? 'done' : ''}"><b>${i < add.step ? '✓' : i + 1}</b>${esc(n)}</span>`).join('') + '</div>';
  let b, f;
  if (add.step === 0) {
    b = `<div class="choice"><button data-add="prov" data-v="claude" aria-pressed="${add.prov === 'claude'}"><span class="prov claude">C</span><b>Claude</b><small>${esc(t('ui.sub.add.claudePlans'))}</small></button>` +
      `<button data-add="prov" data-v="codex" aria-pressed="${add.prov === 'codex'}"><span class="prov codex">X</span><b>Codex</b><small>${esc(t('ui.sub.add.codexPlans'))}</small></button></div>` +
      `<label class="f">${esc(t('ui.sub.add.label'))}<input class="input mono" id="sublabel" placeholder="${add.prov === 'codex' ? 'codex-2' : 'max-e'}" value="${esc(add.label)}" autocomplete="off" spellcheck="false"></label>` +
      `<p class="sub" style="font-size:12.5px;color:var(--muted)">${esc(t('ui.sub.add.labelHint'))}</p><p class="err" id="suberr" hidden></p>`;
    f = `<button class="btn ghost" data-shell="close">${esc(t('ui.cancel'))}</button><button class="btn primary" data-add="next">${esc(t('ui.sub.add.continue'))}</button>`;
  } else if (add.step === 1) {
    const { cmds, note } = addSubCommands(add.prov, add.label);
    const box = (c) => `<div class="cmdbox"><span>${esc(c)}</span><button class="btn sm" data-shell="copy" data-text="${esc(c)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div>`;
    b = `<p>${esc(t('ui.sub.add.run'))}</p>` + cmds.map(box).join('') +
      (note ? `<p style="font-size:12.5px;color:var(--muted)">${esc(note)}</p>` : '') +
      `<p style="font-size:12.5px;color:var(--muted)">${esc(t('ui.sub.add.needs'))}</p>` +
      `<div class="waiting"><span class="spinner"></span>${esc(t('ui.sub.add.waiting'))}</div>`;
    f = `<button class="btn ghost" data-shell="close">${esc(t('ui.cancel'))}</button>`;
  } else {
    b = `<div style="display:flex;gap:14px;align-items:center"><div class="big-ic ok">${ic('check')}</div><div><b>${esc(t('ui.sub.add.inPool', { label: add.label }))}</b>` +
      `<p style="color:var(--muted);font-size:13px">${esc(t('ui.sub.add.sealed', { from: add.from || '—' }))}</p></div></div>`;
    f = `<button class="btn primary" data-shell="close">${esc(t('ui.sub.add.done'))}</button>`;
  }
  ctx.modal(`<div class="modal-h"><h3>${esc(t('ui.sub.add.title'))}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div><div class="modal-b">${sp}${b}</div><div class="modal-f">${f}</div>`);
  const inp = document.getElementById('sublabel');
  if (inp) inp.focus();
}

async function poll(ctx) {
  clearTimeout(add.timer);
  if (add.step !== 1 || !document.querySelector('.modal')) return;
  try {
    const a = await ctx.api('/v1/fleet/credentials/audit?limit=50');
    const row = arrived(a, add.prov, add.label, add.since);
    if (row) {
      add.step = 2; add.from = row.hostname || row.detail || '';
      addModal(ctx); ctx.toast(t('ui.sub.add.toast', { label: add.label }));
      ctx.refresh();
      return;
    }
  } catch { /* keep waiting: a blip is not an answer */ }
  add.timer = setTimeout(() => poll(ctx), 3000);
}

Shell.mount('subscriptions', async (ctx) => {
  const [lim, acc, cr, live, us, sw, set] = await Promise.allSettled([
    ctx.api('/v1/limits?account=all'), ctx.api('/v1/accounts'), ctx.api('/v1/fleet/credentials'),
    ctx.api('/v1/live'), ctx.api('/v1/fleet/users'), ctx.api('/v1/account-switches?limit=8'), ctx.api('/v1/fleet/settings'),
  ]);
  // A hub with neither usage nor a vault has nothing to draw: say why.
  if (lim.status === 'rejected' && cr.status === 'rejected') throw lim.reason;
  const skipRow = val(set) && (val(set).hub || []).find((h) => h.key === 'pool.skip_pct');
  const skip = Number(skipRow && skipRow.value) || 85;
  // Only what the vault holds is the hub's to count and manage (claude-fleet#2127);
  // the rest of the reported accounts wait, collapsed, under 未纳管.
  const all = subscriptions({ limits: val(lim), accounts: val(acc), creds: val(cr), live: val(live) });
  const cards = all.filter((c) => c.managed), other = all.filter((c) => !c.managed);
  ctx.setCount('subscriptions', cards.length);
  const nC = cards.filter((c) => c.prov === 'claude').length, nX = cards.length - nC;
  const h5 = headroom(cards, 'h5'), h7 = headroom(cards, 'h7');
  const pausedN = cards.filter((c) => c.paused).length;
  const kpi = (lbl, v, d) => `<div class="panel kpi"><span class="lbl">${esc(lbl)}</span><span class="val">${esc(v)}</span><span class="delta" style="color:var(--muted)">${esc(d)}</span></div>`;
  const kpis = '<div class="grid g4">' +
    kpi(t('ui.sub.kpi.subs'), String(cards.length), t('ui.sub.kpi.split', { c: nC, x: nX })) +
    kpi(t('ui.sub.kpi.h5'), h5 ? h5.free + '%' : '—', h5 && h5.next ? t('ui.sub.kpi.next', { when: fmtIn(h5.next) }) : t('ui.sub.kpi.noReading')) +
    kpi(t('ui.sub.kpi.h7'), h7 ? h7.free + '%' : '—', h7 && h7.next ? t('ui.sub.kpi.next', { when: fmtIn(h7.next) }) : t('ui.sub.kpi.noReading')) +
    kpi(t('ui.sub.kpi.vault'), String(((val(cr) && val(cr).credentials) || []).filter((c) => c.principal_id === 'pool').length),
      pausedN ? t('ui.sub.kpi.paused', { n: pausedN }) : t('ui.sub.kpi.nonePaused')) + '</div>';

  const vaultNote = cr.status === 'rejected' ? `<div class="notice">${ic('alert')}<span>${esc(t('ui.sub.vaultOff', { e: cr.reason.message }))}</span></div>` : '';
  const body = cards.length ? cards.map((c) => card(c, skip)).join('')
    : `<div class="panel"><div class="empty">${ic('card')}<b>${esc(t('ui.sub.empty'))}</b><span>${esc(t('ui.sub.emptySub'))}</span></div></div>`;
  const grid = `<div class="subcards">${body}<button class="addcard" data-act="add"><span class="plus">${ic('plus')}</span><b>${esc(t('ui.sub.addOne'))}</b><span style="font-size:12.5px">${esc(t('ui.sub.addKinds'))}</span></button></div>`;
  const unmanaged = other.length
    ? `<details class="panel unmanaged"><summary><b>${esc(t('ui.sub.unmanaged', { n: other.length }))}</b></summary>` +
      `<p style="font-size:12.5px;color:var(--muted);margin:0 0 12px">${esc(t('ui.sub.unmanagedHint'))}</p>` +
      `<div class="subcards">${other.map((c) => card(c, skip)).join('')}</div></details>`
    : '';

  const rows = leaseRows(val(live), all, val(us));
  const leases = rows.length
    ? `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.sub.th.session'))}</th><th>${esc(t('ui.sub.th.person'))}</th><th>${esc(t('ui.sub.th.sub'))}</th><th class="r">${esc(t('ui.sub.th.since'))}</th></tr></thead><tbody>` +
      rows.map((r) => `<tr><td class="sname mono">${esc(r.session)}</td><td>${esc(r.person)}</td><td>${esc(r.sub)}</td><td class="mono r">${esc(relTime(r.since))}</td></tr>`).join('') + '</tbody></table></div>'
    : live.status === 'rejected' ? failed(live.reason) : `<div class="empty"><span>${esc(t('ui.sub.noLeases'))}</span></div>`;
  const sws = switchRows(val(sw), all);
  const switches = sws.length
    ? '<div class="attn">' + sws.map((x) => `<div><span class="ic ok">${ic('refresh')}</span><div><b>${esc(x.from)} → ${esc(x.to)}</b><span>${esc(relTime(x.at))}${x.where ? ' · ' + esc(x.where) : ''}</span></div></div>`).join('') + '</div>'
    : sw.status === 'rejected' ? failed(sw.reason) : `<div class="empty"><span>${esc(t('ui.sub.noSwitches'))}</span></div>`;

  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.sub.lead', { skip }))}</p></div><div class="acts"><button class="btn primary" data-act="add">${ic('plus')}${esc(t('ui.sub.addOne'))}</button></div></div>` +
    vaultNote + kpis + grid + unmanaged +
    `<div class="grid g21"><div class="panel"><div class="panel-h"><h3>${esc(t('ui.sub.who'))}</h3><span class="sub">${esc(t('ui.sub.live'))}</span></div>${leases}</div>` +
    `<div class="panel"><div class="panel-h"><h3>${esc(t('ui.sub.switches'))}</h3></div>${switches}</div></div>`;

  const byId = new Map(cards.map((c) => [c.id, c]));
  ctx.el.onclick = (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const s = byId.get(b.dataset.id);
    if (b.dataset.act === 'add') {
      Object.assign(add, { step: 0, label: '', since: 0, from: '' });
      addModal(ctx);
    } else if (b.dataset.act === 'pause' && s && s.cred) {
      const go = async () => {
        try {
          await ctx.api('/v1/fleet/settings', { method: 'PUT', json: { key: 'pool.paused.' + s.cred.account, value: s.paused ? '' : 'on' } });
          ctx.toast(t(s.paused ? 'ui.sub.resumed' : 'ui.sub.pausedToast', { label: s.label }));
          await ctx.refresh();
        } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
      };
      if (s.paused) go();
      else ctx.confirm(t('ui.sub.pauseQ', { label: s.label }), esc(t('ui.sub.pauseBody', { n: s.sessions })), t('ui.sub.pause'), go);
    } else if (b.dataset.act === 'remove' && s && s.cred) {
      ctx.confirm(t('ui.sub.removeQ', { label: s.label }), esc(t('ui.sub.removeBody', { n: s.sessions })), t('ui.sub.removeBtn'), async () => {
        try {
          await ctx.api('/v1/fleet/credentials', { json: { action: 'delete', principal_id: 'pool', provider: s.cred.provider, account: s.cred.account } });
          if (s.paused) await ctx.api('/v1/fleet/settings', { method: 'PUT', json: { key: 'pool.paused.' + s.cred.account, value: '' } }).catch(() => {});
          ctx.toast(t('ui.sub.removed', { label: s.label }));
          await ctx.refresh();
        } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
      });
    }
  };
  // The modal lives in the shell's layer, outside ctx.el.
  document.onclick = (e) => {
    const b = e.target.closest('[data-add]');
    if (!b) return;
    if (b.dataset.add === 'prov') {
      add.prov = b.dataset.v; add.label = (document.getElementById('sublabel') || {}).value || '';
      addModal(ctx);
    } else if (b.dataset.add === 'next') {
      const label = ((document.getElementById('sublabel') || {}).value || '').trim();
      const err = document.getElementById('suberr');
      if (!LABEL_RE.test(label)) { if (err) { err.hidden = false; err.textContent = t('ui.sub.add.badLabel'); } return; }
      if (cards.some((c) => c.cred && c.cred.provider === add.prov && c.cred.account === label)) { if (err) { err.hidden = false; err.textContent = t('ui.sub.add.exists', { label }); } return; }
      Object.assign(add, { step: 1, label, since: Date.now() });
      addModal(ctx);
      poll(ctx);
    }
  };
});
