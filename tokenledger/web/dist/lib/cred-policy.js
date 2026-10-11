// Subscription permissions: the hub owns identity resolution and verdicts.
// This editor only writes one scope through the audited administrator API.
import { esc } from './shell.js';
import { t } from './i18n.js';

export const POLICY_PATH = '/v1/fleet/cred-policy';
export function policyEntry(view, scope, id) {
  return (view[scope === 'node' ? 'nodes' : 'users'] || []).find((x) => x.id === id);
}
export function policyMode(entry) {
  return !entry ? 'inherit' : entry.error ? 'invalid' : entry.allow.length ? 'selected' : 'deny';
}
const modeText = (mode) => ({ inherit: t('ui.policy.inherit'), selected: t('ui.policy.selected'), deny: t('ui.policy.deny'), invalid: t('ui.policy.invalid') })[mode];
const validID = (id) => /^(?:[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}|codex:account:[a-f0-9]{32})$/.test(id);

// Never guess an ID from a label. Keep selected IDs even after their
// credential was removed, so an unrelated edit cannot silently drop them.
export function policyChoices(credentials, entry, scope, id) {
  const choices = new Map();
  const missing = [];
  for (const c of credentials || []) {
    if (!['claude', 'codex'].includes(c.provider)) continue;
    if (scope === 'user' && !['pool', id].includes(c.principal_id)) continue;
    const uuid = String(c.account_uuid || '').toLowerCase();
    const label = `${c.provider} · ${c.account} · ${c.principal_id}`;
    if (!validID(uuid)) { missing.push({ id: '', label }); continue; }
    const old = choices.get(uuid);
    choices.set(uuid, { id: uuid, label: old ? old.label + ' / ' + label : label });
  }
  for (const uuid of entry?.allow || []) {
    if (!choices.has(uuid)) choices.set(uuid, { id: uuid, label: t('ui.policy.unavailable') });
  }
  return [...choices.values(), ...missing];
}
export function policyPayload(scope, id, mode, selected) {
  if (!['node', 'user'].includes(scope) || !id) throw new Error(t('ui.policy.choose'));
  if (!['inherit', 'deny', 'selected'].includes(mode)) throw new Error(t('ui.policy.chooseMode'));
  const allow = mode === 'inherit' ? null : mode === 'deny' ? [] : [...new Set(selected)].sort();
  if (mode === 'selected' && !allow.length) throw new Error(t('ui.policy.chooseSubscriptions'));
  if (allow?.some((uuid) => !validID(uuid))) throw new Error(t('ui.policy.missingID'));
  return { scope, id, allow };
}
const fingerprint = (entry) => JSON.stringify(entry ? { allow: [...entry.allow].sort(), error: entry.error || '' } : null);

export async function savePolicy(api, before, payload) {
  const latest = await api(POLICY_PATH);
  if (fingerprint(policyEntry(latest, payload.scope, payload.id)) !== fingerprint(before)) {
    throw new Error(t('ui.policy.changed'));
  }
  // The API has no revision token: this detects changes before saving, but
  // is not an atomic compare-and-set across simultaneous administrators.
  return api(POLICY_PATH, { method: 'PUT', json: payload });
}

export function effectiveHTML(effective) {
  const rows = effective.accounts || [];
  return `<p class="sub">${esc(t('ui.policy.resultNote'))}</p>` + (rows.length
    ? `<div class="tw"><table class="t"><thead><tr><th>${esc(t('ui.policy.subscription'))}</th><th>${esc(t('ui.policy.verdict'))}</th><th>${esc(t('ui.policy.reason'))}</th></tr></thead><tbody>` + rows.map((c) =>
      `<tr><td>${esc(c.provider)} · ${esc(c.account)}<br><small class="mono">${esc(c.account_uuid || t('ui.policy.missingID'))}</small></td><td>${esc(c.allowed ? t('ui.policy.allowed') : t('ui.policy.denied'))}</td><td>${esc(c.reason || '—')}</td></tr>`).join('') + '</tbody></table></div>'
    : `<p>${esc(t('ui.policy.empty'))}</p>`);
}

function editPolicy(ctx, scope, id, view, credentials, done) {
  const before = policyEntry(view, scope, id);
  const choices = policyChoices(credentials, before, scope, id);
  const oldMode = policyMode(before);
  const oldText = `${modeText(oldMode)}${before?.allow?.length ? ': ' + before.allow.join(', ') : ''}`;
  ctx.modal(`<div class="modal-h"><h3>${esc(t('ui.policy.edit', { target: id }))}</h3><button class="btn ghost" data-shell="close">${esc(t('ui.close'))}</button></div>` +
    `<form id="policy-editor" style="overflow-wrap:anywhere"><div class="modal-b"><p>${esc(t('ui.policy.before', { value: oldText }))}</p>` +
    `<p class="sub">${esc(t('ui.policy.scopeNote'))}</p><label class="f">${esc(t('ui.policy.mode'))}<select class="input" name="mode">` +
    (oldMode === 'invalid' ? `<option value="invalid">${esc(modeText('invalid'))}</option>` : '') +
    ['inherit', 'selected', 'deny'].map((m) => `<option value="${m}"${oldMode === m ? ' selected' : ''}>${esc(modeText(m))}</option>`).join('') + '</select></label>' +
    `<fieldset data-policy-choices><legend>${esc(t('ui.policy.subscription'))}</legend>` + choices.map((c) =>
      `<label style="display:block;margin:10px 0"><input type="checkbox" name="subscription" value="${esc(c.id)}"${before?.allow?.includes(c.id) ? ' checked' : ''}${!c.id ? ' disabled' : ''}> ${esc(c.label)}<br><small class="mono">${esc(c.id || t('ui.policy.missingID'))}</small></label>`).join('') +
    `</fieldset><p class="sub">${esc(t('ui.policy.timing'))}</p><p class="err" role="alert" data-policy-error></p></div>` +
    `<div class="modal-f"><button type="button" class="btn ghost" data-shell="close">${esc(t('ui.cancel'))}</button><button class="btn primary" type="submit">${esc(t('ui.policy.review'))}</button></div></form>`);
  const form = document.querySelector('#policy-editor');
  const mode = form.elements.mode;
  const toggle = () => { form.querySelector('[data-policy-choices]').disabled = mode.value !== 'selected'; };
  mode.onchange = toggle; toggle();
  form.onsubmit = (event) => {
    event.preventDefault();
    let payload;
    try {
      payload = policyPayload(scope, id, mode.value, [...form.querySelectorAll('[name="subscription"]:checked')].map((c) => c.value));
    } catch (err) { form.querySelector('[data-policy-error]').textContent = err.message; return; }
    const next = modeText(mode.value) + (payload.allow?.length ? ': ' + choices.filter((c) => payload.allow.includes(c.id)).map((c) => `${c.label} (${c.id})`).join(', ') : '');
    ctx.confirm(t('ui.policy.edit', { target: id }), '<span style="overflow-wrap:anywhere">' + esc(oldText) + '<br>→ ' + esc(next) + '<br><br>' + esc(t('ui.policy.timing')) + '</span>', t('ui.policy.save'), async () => {
      try {
        await savePolicy(ctx.api, before, payload);
        ctx.toast(t('ui.policy.saved'));
        await done();
      } catch (err) { ctx.toast(t('ui.err.action', { e: err.message })); }
    });
  };
}

export async function mountPolicy(ctx, root) {
  if (!ctx.admin) return;
  root.innerHTML = `<div class="panel-h"><h3>${esc(t('ui.policy.title'))}</h3></div>`;
  try {
    const [view, snapshot, users, creds] = await Promise.all([
      ctx.api(POLICY_PATH), ctx.api('/v1/nodes'), ctx.api('/v1/fleet/users'), ctx.api('/v1/fleet/credentials'),
    ]);
    if (!root.isConnected) return;
    const machines = new Map((view.nodes || []).map((n) => ['machine:' + n.id, n.id]));
    for (const n of snapshot.nodes || []) {
      if (n.endpoint_id) machines.set('endpoint:' + n.endpoint_id, `${n.hostname} · ${n.os_user || n.endpoint_id}`);
    }
    const people = new Map((view.users || []).map((u) => [u.id, u.id]));
    for (const u of [...(users.users || []), ...(users.admins || [])]) {
      const id = u.principal || (u.github_id ? 'gh:' + u.github_id : '');
      if (id) people.set(id, `${u.login} (${id})`);
    }
    const options = (rows) => `<option value="">${esc(t('ui.policy.optional'))}</option>` + [...rows].map(([id, label]) => `<option value="${esc(id)}">${esc(label)}</option>`).join('');
    root.innerHTML += `<div style="padding:0 20px 20px"><p>${esc(t('ui.policy.lead'))}</p><p class="sub">${esc(t('ui.policy.defaults'))}</p>` +
      `<form data-policy-query class="toolbar"><label class="f">${esc(t('ui.policy.node'))}<select class="input" name="node">${options(machines)}</select></label>` +
      `<label class="f">${esc(t('ui.policy.user'))}<select class="input" name="user">${options(people)}</select></label><button class="btn" type="submit">${esc(t('ui.policy.inspect'))}</button></form>` +
      `<div data-policy-result aria-live="polite"></div></div>`;
    const form = root.querySelector('form');
    const result = root.querySelector('[data-policy-result]');
    let generation = 0;
    form.onchange = () => { generation++; result.innerHTML = ''; };
    const inspect = async () => {
      const seq = ++generation;
      const node = form.elements.node.value, principal = form.elements.user.value;
      result.innerHTML = '';
      if (!node && !principal) { result.textContent = t('ui.policy.choose'); return; }
      const query = new URLSearchParams();
      if (node.startsWith('endpoint:')) query.set('endpoint_id', node.slice(9));
      if (node.startsWith('machine:')) query.set('machine', node.slice(8));
      if (principal) query.set('principal', principal);
      try {
        const answer = await ctx.api(POLICY_PATH + '?' + query);
        if (seq !== generation || !root.isConnected) return;
        const eff = answer.effective;
        const targets = [];
        if (eff.machine) targets.push(['node', eff.machine, t('ui.policy.node')]);
        if (eff.principal) targets.push(['user', eff.principal, t('ui.policy.user')]);
        result.innerHTML = targets.map(([scope, id, label]) => `<p>${esc(label)}: <b>${esc(id)}</b> · ${esc(modeText(policyMode(policyEntry(answer, scope, id))))} ` +
          `<button type="button" class="btn sm" data-policy-edit="${scope}" data-id="${esc(id)}">${esc(t('ui.policy.editButton'))}</button></p>`).join('') + effectiveHTML(eff);
        result.onclick = (event) => {
          const button = event.target.closest('[data-policy-edit]');
          if (button) editPolicy(ctx, button.dataset.policyEdit, button.dataset.id, answer, creds.credentials, inspect);
        };
      } catch (err) {
        if (seq === generation && root.isConnected) result.textContent = t('ui.err.action', { e: err.message });
      }
    };
    form.onsubmit = (event) => { event.preventDefault(); inspect(); };
  } catch (err) {
    if (!root.isConnected) return;
    root.innerHTML += `<p class="err" role="alert">${esc(t('ui.err.action', { e: err.message }))}</p><button class="btn" data-policy-retry>${esc(t('ui.err.retry'))}</button>`;
    root.querySelector('[data-policy-retry]').onclick = () => mountPolicy(ctx, root);
  }
}
