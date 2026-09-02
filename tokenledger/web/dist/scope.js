// web/dist/scope.js — renders the sticky scope bar (tabs, subscription
// select, span buttons, chips, theme toggle) purely from state. No fetching;
// app.js owns the load loop and calls back into it via the handler object.
import { DIMS } from './lib/state.js';
import { shortProject } from './lib/format.js';
import { el, $ } from './lib/dom.js';
// `app` is read only inside functions below (never at module-eval time), so
// this is a safe circular import: app.js imports renderScope/setBusy from
// here, and by the time either is actually CALLED (from route(), which only
// runs after app.js has fully evaluated and boot()'s account fetch has
// resolved), `app`'s exported binding is fully populated. This is how a chip
// for the "machine" dimension resolves its label — scope.js's own signature
// (state, accounts, callbacks) has no room for the endpoint roster that
// now.js caches on `app.endpoints` after every /v1/endpoints fetch.
import { app } from './app.js';

// Restored as early as possible (module-eval time, right after the document
// is parsed) so there is no flash of the wrong theme — copied verbatim from
// the old page's top-level snippet.
try {
  const saved = localStorage.getItem('ccquota-theme');
  if (saved) document.documentElement.setAttribute('data-theme', saved);
} catch {}

let handlers = {};

/** chipLabel resolves the DISPLAY text for one chip. Everything but
 *  machine/project/session shows its raw filter value. */
function chipLabel(dim, value) {
  if (dim === 'machine') {
    const eps = app.endpoints || [];
    const ep = eps.find((e) => e.endpoint_id === value);
    return ep ? (ep.label || ep.hostname || value) : value;
  }
  if (dim === 'project') return shortProject(value);
  if (dim === 'session') return value.slice(0, 8);
  return value;
}

export function renderScope(root, state, accounts, cb) {
  handlers = cb || {};
  if (!root.dataset.bound) {
    bind(root);
    root.dataset.bound = '1';
  }

  $('#tab-now', root).setAttribute('aria-selected', String(state.view === 'now'));
  $('#tab-review', root).setAttribute('aria-selected', String(state.view === 'review'));

  const sel = $('#sub', root);
  const opts = accounts.map((a) => el('option', { value: a.account_uuid },
    a.email || a.display_name || a.account_uuid));
  if (accounts.length > 1) opts.unshift(el('option', { value: 'all' }, `All ${accounts.length} subscriptions`));
  sel.replaceChildren(...opts);
  sel.style.display = accounts.length > 1 ? '' : 'none';
  sel.value = state.sub;

  for (const btn of root.querySelectorAll('.seg button')) {
    btn.setAttribute('aria-pressed', String(btn.dataset.span === state.span));
  }

  const chipsRow = $('#chips', root);
  const dims = DIMS.filter((d) => state.chips[d]);
  if (!dims.length) {
    chipsRow.hidden = true;
    chipsRow.replaceChildren();
    return;
  }
  chipsRow.hidden = false;
  const chips = dims.map((d) => el('span', { class: 'chip' },
    d + ': ',
    el('b', {}, chipLabel(d, state.chips[d])),
    el('button', { type: 'button', 'aria-label': 'remove ' + d, onclick: () => handlers.onChipRemove && handlers.onChipRemove(d) }, '×')));
  chips.push(el('span', { class: 'chip clear' },
    el('button', { type: 'button', onclick: () => handlers.onClear && handlers.onClear() }, 'Clear all')));
  chipsRow.replaceChildren(...chips);
}

function bind(root) {
  $('#tab-now', root).addEventListener('click', () => handlers.onView && handlers.onView('now'));
  $('#tab-review', root).addEventListener('click', () => handlers.onView && handlers.onView('review'));
  $('#sub', root).addEventListener('change', (e) => handlers.onSub && handlers.onSub(e.target.value));
  for (const btn of root.querySelectorAll('.seg button')) {
    btn.addEventListener('click', () => handlers.onSpan && handlers.onSpan(btn.dataset.span));
  }
  // Theme toggle: copied verbatim from the old page's click handler.
  $('#theme', root).addEventListener('click', () => {
    const cur = document.documentElement.getAttribute('data-theme');
    const next = cur === 'dark' ? 'light' : cur === 'light' ? 'auto' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('ccquota-theme', next); } catch {}
  });
}

export function setBusy(b) {
  const p = $('#progress');
  if (p) p.hidden = !b;
}
