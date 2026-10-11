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
    const label = `${c.provider === 'claude' ? 'Claude' : 'Codex'} · ${c.account}`;
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

// A machine's display hostname is never an authorization key. Resolve the
// enrolled identity once, and collapse all its logins into one editable row.
export async function machineTargets(view, snapshot, api) {
  const targets = new Map((view.nodes || []).map((n) => [n.id, { id: n.id, label: n.id }]));
  const endpoints = [...new Map((snapshot.nodes || []).filter((n) => n.endpoint_id).map((n) => [n.endpoint_id, n])).values()];
  const answers = await Promise.allSettled(endpoints.map((n) => api(POLICY_PATH + '?endpoint_id=' + encodeURIComponent(n.endpoint_id))));
  const failed = [];
  answers.forEach((answer, i) => {
    const id = answer.status === 'fulfilled' && answer.value.effective?.machine;
    if (id) targets.set(id, { id, label: id });
    else failed.push({ id: 'unresolved:' + endpoints[i].endpoint_id, label: endpoints[i].hostname || endpoints[i].endpoint_id,
      error: answer.status === 'rejected' ? answer.reason.message : t('ui.policy.unknownMachine') });
  });
  return [...targets.values(), ...failed];
}
export function userTargets(view, users) {
  const targets = new Map((view.users || []).map((u) => [u.id, { id: u.id, label: u.id }]));
  for (const u of [...(users.users || []), ...(users.admins || [])]) {
    const id = u.principal || (u.github_id ? 'gh:' + u.github_id : '');
    if (id) targets.set(id, { id, label: u.login || id });
  }
  return [...targets.values()];
}
export function newDraft(entry) {
  return { before: entry, mode: policyMode(entry), selected: [...(entry?.allow || [])] };
}
export function draftChanged(draft) {
  const mode = policyMode(draft.before);
  return draft.mode !== mode || (mode === 'selected' && JSON.stringify([...draft.selected].sort()) !== JSON.stringify([...draft.before.allow].sort()));
}
const statusText = (entry) => policyMode(entry) === 'selected' ? t('ui.policy.count', { n: entry.allow.length }) : modeText(policyMode(entry));

export async function mountPolicy(ctx, root) {
  if (!ctx.admin) return;
  root.innerHTML = `<div class="panel-h"><h3>${esc(t('ui.policy.title'))}</h3></div><p class="panel-b">${esc(t('ui.loading'))}</p>`;
  try {
    let [view, snapshot, users, creds] = await Promise.all([
      ctx.api(POLICY_PATH), ctx.api('/v1/nodes'), ctx.api('/v1/fleet/users'), ctx.api('/v1/fleet/credentials'),
    ]);
    if (!root.isConnected) return;
    let scope = 'user', selected = '', machines = null, busy = false, renderGeneration = 0;
    const people = userTargets(view, users), drafts = new Map();
    let machinesPromise;
    const loadMachines = () => machinesPromise || (machinesPromise = machineTargets(view, snapshot, ctx.api).then((rows) => (machines = rows)));
    const key = (id) => scope + ':' + id;
    const draftOf = (id) => {
      if (!drafts.has(key(id))) drafts.set(key(id), newDraft(policyEntry(view, scope, id)));
      return drafts.get(key(id));
    };
    const render = async () => {
      const generation = ++renderGeneration;
      root.innerHTML = `<div class="panel-h"><div><h3>${esc(t('ui.policy.title'))}</h3><p class="sub">${esc(t('ui.policy.defaults'))}</p></div></div>` +
        `<div class="policy-tabs" role="group" aria-label="${esc(t('ui.policy.by'))}">` +
        [['user', t('ui.policy.byUser')], ['node', t('ui.policy.byMachine')]].map(([value, label]) =>
          `<button type="button" class="btn${scope === value ? ' primary' : ' ghost'}" data-policy-scope="${value}" aria-pressed="${scope === value}">${esc(label)}</button>`).join('') + '</div><div data-policy-workspace></div>';
      root.querySelectorAll('[data-policy-scope]').forEach((button) => { button.onclick = () => {
        if (busy || button.dataset.policyScope === scope) return;
        scope = button.dataset.policyScope; selected = ''; render();
      }; });
      const workspace = root.querySelector('[data-policy-workspace]');
      if (scope === 'node' && !machines) { workspace.innerHTML = `<p class="panel-b">${esc(t('ui.loading'))}</p>`; await loadMachines(); }
      if (generation !== renderGeneration || !root.isConnected) return;
      const targets = scope === 'user' ? people : machines;
      if (!targets.some((row) => row.id === selected && !row.error)) selected = targets.find((row) => !row.error)?.id || '';
      workspace.innerHTML = `<div class="policy-workspace"><div class="policy-targets" aria-label="${esc(scope === 'user' ? t('ui.policy.user') : t('ui.policy.node'))}">` +
        (targets.length ? targets.map((row) => {
          const entry = policyEntry(view, scope, row.id), mode = policyMode(entry);
          return `<button type="button" class="policy-target" data-policy-target="${esc(row.id)}" aria-pressed="${row.id === selected}"${row.error ? ' disabled' : ''} title="${esc(row.error || row.id)}"><strong>${esc(row.label)}</strong>` +
            `<span class="chip ${mode === 'deny' || mode === 'invalid' || row.error ? 'bad' : mode === 'inherit' ? 'ok' : 'brand'}">${esc(row.error ? t('ui.policy.unknownMachine') : statusText(entry))}</span>` +
            `<small data-draft-label="${esc(row.id)}">${drafts.has(key(row.id)) && draftChanged(drafts.get(key(row.id))) ? esc(t('ui.policy.unsaved')) : ''}</small></button>`;
        }).join('') : `<p class="panel-b">${esc(t('ui.policy.noTargets'))}</p>`) + '</div><div class="policy-editor" data-policy-editor></div></div>';
      root.querySelectorAll('[data-policy-target]').forEach((button) => { button.onclick = () => {
        if (busy) return; selected = button.dataset.policyTarget; render();
      }; });
      const target = targets.find((row) => row.id === selected);
      if (target) drawEditor(target);
      drawInspector(workspace);
    };
    const drawEditor = (target) => {
      const editor = root.querySelector('[data-policy-editor]'), draft = draftOf(target.id);
      const choices = policyChoices(creds.credentials, draft.before, scope, target.id);
      editor.innerHTML = `<form data-policy-form><div class="policy-editor-head"><div><h3>${esc(target.label)}</h3><p class="sub">${esc(scope === 'user' ? t('ui.policy.userHint') : t('ui.policy.machineHint'))}</p></div>` +
        `<button type="button" class="btn ghost sm" data-policy-reset>${esc(t('ui.policy.reset'))}</button></div>` +
        `<fieldset class="policy-modes"><legend>${esc(t('ui.policy.mode'))}</legend>` +
        [['inherit', t('ui.policy.allHint')], ['selected', t('ui.policy.selectedHint')], ['deny', t('ui.policy.denyHint')]].map(([mode, hint]) =>
          `<label class="policy-mode"><input type="radio" name="mode" value="${mode}"${draft.mode === mode ? ' checked' : ''}><span><strong>${esc(modeText(mode))}</strong><small>${esc(hint)}</small></span></label>`).join('') + '</fieldset>' +
        (draft.mode === 'invalid' ? `<p class="err">${esc(t('ui.policy.chooseMode'))}</p>` : '') +
        `<fieldset class="policy-subscriptions" data-policy-choices><legend>${esc(t('ui.policy.subscription'))}</legend>` +
        choices.map((choice) => `<label class="policy-subscription"><input type="checkbox" name="subscription" value="${esc(choice.id)}"${draft.selected.includes(choice.id) ? ' checked' : ''}${!choice.id ? ' disabled' : ''}><span>${esc(choice.label)}${!choice.id ? `<small>${esc(t('ui.policy.missingID'))}</small>` : ''}</span></label>`).join('') + '</fieldset>' +
        `<div class="policy-save"><div><p data-policy-current>${esc(t('ui.policy.before', { value: statusText(draft.before) }))}</p><small data-policy-dirty></small></div><button class="btn primary" type="submit">${esc(t('ui.policy.save'))}</button></div>` +
        `<p class="err" data-policy-error role="alert"></p><details class="policy-notes"><summary>${esc(t('ui.policy.notes'))}</summary><p>${esc(t('ui.policy.scopeNote'))}</p><p>${esc(t('ui.policy.timing'))}</p></details></form>`;
      const form = editor.querySelector('form'), choicesBox = form.querySelector('[data-policy-choices]');
      const update = () => {
        choicesBox.hidden = draft.mode !== 'selected'; choicesBox.disabled = draft.mode !== 'selected';
        form.querySelector('[type=submit]').disabled = !draftChanged(draft) || busy;
        form.querySelector('[data-policy-reset]').disabled = draft.mode === 'inherit' || busy;
        form.querySelector('[data-policy-dirty]').textContent = draftChanged(draft) ? t('ui.policy.unsaved') : t('ui.policy.savedState');
        root.querySelectorAll('[data-draft-label]').forEach((el) => {
          if (el.dataset.draftLabel === target.id) el.textContent = draftChanged(draft) ? t('ui.policy.unsaved') : '';
        });
      };
      form.onchange = () => {
        draft.mode = form.elements.mode.value;
        draft.selected = [...form.querySelectorAll('[name=subscription]:checked')].map((c) => c.value);
        form.querySelector('[data-policy-error]').textContent = ''; update();
      };
      form.querySelector('[data-policy-reset]').onclick = () => {
        draft.mode = 'inherit'; form.querySelector('[name=mode][value=inherit]').checked = true; update();
      };
      form.onsubmit = async (event) => {
        event.preventDefault(); if (busy) return;
        const savedScope = scope;
        try {
          const payload = policyPayload(scope, target.id, draft.mode, draft.selected);
          busy = true;
          root.querySelectorAll('button,input,select').forEach((el) => { el.disabled = true; });
          await savePolicy(ctx.api, draft.before, payload);
          const family = savedScope === 'node' ? 'nodes' : 'users';
          view[family] = view[family].filter((entry) => entry.id !== target.id);
          if (payload.allow !== null) view[family].push({ id: target.id, allow: payload.allow });
          drafts.delete(savedScope + ':' + target.id);
          ctx.toast(t('ui.policy.saved'));
          busy = false; await render();
        } catch (error) {
          busy = false;
          await render();
          root.querySelector('[data-policy-error]').textContent = error.message;
        }
      };
      update();
    };
    // Inspection is optional and does not gate either editing workflow.
    const drawInspector = (workspace) => {
      const details = document.createElement('details'); details.className = 'policy-inspector';
      details.innerHTML = `<summary>${esc(t('ui.policy.inspectTitle'))}</summary><div data-policy-inspect></div>`;
      workspace.append(details);
      details.ontoggle = async () => {
        if (!details.open || details.dataset.loaded) return;
        details.dataset.loaded = '1';
        const area = details.querySelector('[data-policy-inspect]');
        area.innerHTML = `<p>${esc(t('ui.loading'))}</p>`;
        const rows = await loadMachines(); if (!details.isConnected) return;
        const options = (list) => `<option value="">${esc(t('ui.policy.optional'))}</option>` + list.filter((row) => !row.error).map((row) => `<option value="${esc(row.id)}">${esc(row.label)}</option>`).join('');
        area.innerHTML = `<p class="sub">${esc(t('ui.policy.lead'))}</p><form class="toolbar" data-policy-query><label class="f">${esc(t('ui.policy.user'))}<select class="input" name="user" required>${options(people)}</select></label>` +
          `<label class="f">${esc(t('ui.policy.node'))}<select class="input" name="node" required>${options(rows)}</select></label><button class="btn" type="submit">${esc(t('ui.policy.inspect'))}</button></form><div data-policy-result aria-live="polite"></div>`;
        const form = area.querySelector('form'), result = area.querySelector('[data-policy-result]');
        let queryGeneration = 0;
        form.onchange = () => { queryGeneration++; result.innerHTML = ''; };
        form.onsubmit = async (event) => {
          event.preventDefault(); const sequence = ++queryGeneration;
          result.textContent = t('ui.loading');
          const query = new URLSearchParams({ machine: form.elements.node.value, principal: form.elements.user.value });
          try {
            const answer = await ctx.api(POLICY_PATH + '?' + query);
            if (sequence === queryGeneration && result.isConnected) result.innerHTML = effectiveHTML(answer.effective);
          } catch (error) { if (sequence === queryGeneration && result.isConnected) result.textContent = error.message; }
        };
      };
    };
    await render();
  } catch (error) {
    if (!root.isConnected) return;
    root.innerHTML = `<div class="panel-h"><h3>${esc(t('ui.policy.title'))}</h3></div><div class="panel-b"><p class="err" role="alert">${esc(t('ui.err.action', { e: error.message }))}</p><button class="btn" data-policy-retry>${esc(t('ui.err.retry'))}</button></div>`;
    root.querySelector('[data-policy-retry]').onclick = () => mountPolicy(ctx, root);
  }
}
