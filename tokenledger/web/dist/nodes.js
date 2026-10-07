// web/dist/nodes.js — Machines, at /nodes (claude-fleet#1990): one card per
// computer that runs sessions (load trend, status, sessions, version), the
// maintenance switch behind a confirm, «add a machine» (a one-time join code,
// its command and countdown, waiting for the machine to join), and the SPOT
// switch. Reads /v1/nodes, /v1/fleet/join-codes, /v1/fleet/settings; writes
// fleet.node_maintenance.<machine> and fleet.spot. An admin's.
import { Shell } from './app-shell.js';
import { esc, ic, spark, relTime } from './lib/shell.js';
import { machineCards, joined, countdown } from './lib/admin.js';
import { t } from './lib/i18n.js';

const join = { label: '', expires: 0, timer: 0, tick: 0 };

function stop() { clearTimeout(join.timer); clearInterval(join.tick); }

function status(m) {
  if (m.status === 'online') return `<span class="status"><span class="dot ok"></span>${esc(t('ui.mach.online'))}</span>`;
  if (m.status === 'maintenance') return `<span class="status"><span class="dot warn"></span>${esc(t('ui.mach.maint'))}</span>`;
  return `<span class="status"><span class="dot bad"></span>${esc(t('ui.mach.lost'))}</span>`;
}

function card(m) {
  const load = m.loadCore == null || m.status === 'lost' ? '—' : m.loadCore.toFixed(2);
  const trend = m.hist.length ? spark(m.hist, m.status === 'lost' ? 'var(--bad)' : 'var(--brand)', true)
    : `<div class="ghostrow" style="font-size:12px">${esc(t('ui.mach.noTrend'))}</div>`;
  const why = m.maintenance ? `<span style="font-size:12px;color:var(--muted)">${esc(t('ui.mach.maintWhy', { reason: m.maintenance.reason || '—', by: m.maintenance.by || '—', when: relTime(m.maintenance.since) }))}</span>` : '';
  const btn = m.status === 'maintenance' || (m.status === 'lost' && m.maintenance)
    ? `<button class="btn sm" data-act="leave" data-m="${esc(m.name)}">${ic('wrench')}${esc(t('ui.mach.endMaint'))}</button>`
    : m.status === 'online' ? `<button class="btn sm" data-act="enter" data-m="${esc(m.name)}" data-n="${m.sessions == null ? '' : m.sessions}">${ic('wrench')}${esc(t('ui.mach.maintBtn'))}</button>` : '';
  return `<div class="panel mc"><div class="mc-h"><b>${esc(m.name)}</b>${m.kind === 'ephemeral' ? `<span class="chip brand">${esc(t('ui.mach.spot'))}</span>` : ''}${status(m)}</div>${why}` +
    trend +
    `<div class="stats"><div><b>${m.sessions == null ? '?' : m.sessions}</b>${esc(t('ui.mach.sessions'))}</div><div><b>${esc(load)}</b>${esc(t('ui.mach.load'))}</div><div><b>${esc(m.version || '—')}</b>${esc(t('ui.mach.version'))}</div></div>` +
    `<div class="mc-f"><span>${esc(t('ui.mach.seen', { when: relTime(m.seen) }))}</span>${btn}</div></div>`;
}

function joinModal(ctx, j) {
  ctx.modal(`<div class="modal-h"><h3>${esc(t('ui.mach.add.title'))}</h3><button class="btn ghost sm" data-shell="close" aria-label="${esc(t('ui.close'))}">${ic('x')}</button></div><div class="modal-b">` +
    `<p>${esc(t('ui.mach.add.run'))}</p><div class="cmdbox"><span>${esc(j.command)}</span><button class="btn sm" data-shell="copy" data-text="${esc(j.command)}" aria-label="${esc(t('ui.copy'))}">${ic('copy')}</button></div>` +
    `<dl class="kv"><dt>${esc(t('ui.mach.add.code'))}</dt><dd class="mono">${esc(j.code)}</dd><dt>${esc(t('ui.mach.add.works'))}</dt><dd>${esc(t('ui.mach.add.once'))}</dd><dt>${esc(t('ui.mach.add.expires'))}</dt><dd class="mono" id="exp">${esc(countdown(j.expires_at))}</dd></dl>` +
    `<div class="waiting" id="joinwait"><span class="spinner"></span>${esc(t('ui.mach.add.waiting'))}</div></div>` +
    `<div class="modal-f"><button class="btn ghost" data-shell="close">${esc(t('ui.close'))}</button></div>`);
}

async function pollJoin(ctx) {
  clearTimeout(join.timer);
  if (!document.getElementById('joinwait')) { stop(); return; }
  try {
    const hit = joined(await ctx.api('/v1/fleet/join-codes'), join.label);
    if (hit) {
      stop();
      const w = document.getElementById('joinwait');
      if (w) w.innerHTML = `${ic('check')}<b>${esc(t('ui.mach.add.joined', { host: hit.joined_host || '—' }))}</b>`;
      ctx.toast(t('ui.mach.add.joined', { host: hit.joined_host || '—' }));
      ctx.refresh();
      return;
    }
  } catch { /* keep waiting */ }
  join.timer = setTimeout(() => pollJoin(ctx), 3000);
}

Shell.mount('machines', async (ctx) => {
  const [snapR, setR] = await Promise.allSettled([ctx.api('/v1/nodes'), ctx.api('/v1/fleet/settings')]);
  if (snapR.status === 'rejected') throw snapR.reason;
  const snap = snapR.value;
  const ms = machineCards(snap);
  ctx.setCount('machines', ms.length);
  const settings = setR.status === 'fulfilled' ? setR.value : null;
  const spotRow = settings && (settings.hub || []).find((h) => h.key === 'fleet.spot');
  const spotOn = !!(spotRow && spotRow.value === 'on');
  const spot = snap.spot;
  const spotLine = !spot ? t('ui.mach.spotNone')
    : spotOn ? t('ui.mach.spotOn', { max: spot.max || 0, idle: spot.idle_minutes || 30, n: (spot.nodes || []).length })
      : t('ui.mach.spotOff', { n: (spot.nodes || []).length });

  const cards = ms.length ? `<div class="mcards">${ms.map(card).join('')}</div>`
    : `<div class="panel"><div class="empty">${ic('server')}<b>${esc(t('ui.mach.empty'))}</b><span>${esc(t('ui.mach.emptySub'))}</span><button class="btn primary" data-act="add">${ic('plus')}${esc(t('ui.mach.addBtn'))}</button></div></div>`;
  ctx.el.innerHTML = `<div class="pagehead"><div><p>${esc(t('ui.mach.lead'))}</p></div><div class="acts"><button class="btn primary" data-act="add">${ic('plus')}${esc(t('ui.mach.addBtn'))}</button></div></div>` +
    cards +
    `<div class="panel"><div class="panel-h"><div><h3>${esc(t('ui.mach.spotTitle'))}</h3><span class="sub">${esc(t('ui.mach.spotSub'))}</span></div>` +
    `<button class="switch" role="switch" aria-checked="${spotOn}" data-act="spot" aria-label="${esc(t('ui.mach.spotTitle'))}"${settings ? '' : ' disabled'}></button></div>` +
    `<div class="panel-b" style="font-size:13px;color:var(--muted)">${esc(spotLine)}</div></div>`;

  const put = async (key, value, ok) => {
    try {
      await ctx.api('/v1/fleet/settings', { method: 'PUT', json: { key, value } });
      ctx.toast(ok);
      await ctx.refresh();
    } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
  };
  ctx.el.onclick = async (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const m = b.dataset.m;
    if (b.dataset.act === 'enter') {
      const n = b.dataset.n === '' ? '?' : b.dataset.n;
      // The confirm clears its layer before it calls back: keep the reason
      // as it is typed.
      let reason = t('ui.mach.reasonDefault');
      ctx.confirm(t('ui.mach.enterQ', { m }), esc(t('ui.mach.enterBody', { n })) +
        `</p><label class="f">${esc(t('ui.mach.reason'))}<input class="input" id="mreason" maxlength="200" value="${esc(reason)}"></label><p>`,
      t('ui.mach.enterBtn'), () => put('fleet.node_maintenance.' + m, reason.trim() || t('ui.mach.reasonDefault'), t('ui.mach.entered', { m })));
      const inp = document.getElementById('mreason');
      if (inp) inp.oninput = () => { reason = inp.value; };
    } else if (b.dataset.act === 'leave') {
      put('fleet.node_maintenance.' + m, '', t('ui.mach.left', { m }));
    } else if (b.dataset.act === 'spot') {
      put('fleet.spot', spotOn ? 'off' : 'on', t(spotOn ? 'ui.mach.spotOffToast' : 'ui.mach.spotOnToast'));
    } else if (b.dataset.act === 'add') {
      try {
        stop();
        join.label = 'web-' + Date.now().toString(36);
        const j = await ctx.api('/v1/fleet/join-codes', { json: { label: join.label } });
        joinModal(ctx, j);
        join.tick = setInterval(() => {
          const el = document.getElementById('exp');
          if (!el) { stop(); return; }
          el.textContent = countdown(j.expires_at);
        }, 1000);
        pollJoin(ctx);
      } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
    }
  };
});
