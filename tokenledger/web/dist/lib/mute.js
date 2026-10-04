// web/dist/lib/mute.js — the "I know about this" control, shared by Now's
// Alerts card and Review's Findings card.
//
// It is its own module for the reason lib/findings.js is: two views print
// findings, and a control that existed twice would drift into two answers to
// the same question. findings.js stays a pure string renderer with no DOM (see
// its header); this is the half that needs a button, a request and a reload,
// so it lives next to it rather than inside it.
//
// # What the control can say
//
// Exactly two things, because a mute has exactly two states: silence this for
// a day, or end the silence now. There is no duration picker. The HTTP
// endpoint takes `hours` and the store clamps it (store.MaxMuteFor), so a
// longer silence is reachable by anyone scripting against the hub — but the
// page's job is the decision an operator makes at 2am while looking at a red
// dot, and a menu at that moment is a worse tool than a default.
//
// A day is the default because it is the span over which the answer changes:
// long enough to finish the thing that caused the alert, short enough that a
// forgotten mute cannot hide a condition past the next working day.
import { el } from './dom.js';
import { t } from './i18n.js';
import { isMuted, muteLine } from './findings.js';

// MUTE_HOURS is what the page's one-click mute asks for. It matches
// store.DefaultMuteFor, but it is sent explicitly rather than omitted: the
// button's label states a duration to the operator, and a label that promised
// "a day" while the server silently applied its own default would be a lie the
// first time that default moved.
const MUTE_HOURS = 24;

// muteControls renders the footer line for one finding: its mute state (when
// muted) and the one action available.
//
// `f` needs an `id`. A finding without one is not actionable — nothing can be
// attached to something that has no name — so this returns null rather than
// rendering a button that would fail. That is not a hypothetical: every
// in-tree rule sets one, but a surface reading an older hub across a version
// skew would see findings with no id at all, and a dead button is worse than
// no button.
export function muteControls(f, app) {
  if (!f || !f.id) return null;
  const row = el('div', { class: 'mute' });
  const status = isMuted(f) ? el('span', { class: 'mute-state' }, muteLine(f)) : null;
  const err = el('span', { class: 'mute-err', role: 'status' });

  const action = el('button', {
    type: 'button', class: 'linkish',
    onclick: async () => {
      // Guard the double-click, and say the request is in flight. The button
      // triggers a full page reload on success, which is not instant on a
      // hub with a wide brush, and a second click in that gap would post a
      // second mute (harmless, being an upsert) or a mute-then-unmute race
      // (not harmless).
      if (action.disabled) return;
      action.disabled = true;
      err.textContent = '';
      try {
        await app.post('/v1/findings/mutes', isMuted(f)
          ? { id: f.id, action: 'unmute' }
          : { id: f.id, kind: f.kind || '', hours: MUTE_HOURS });
        // Re-read rather than patch the row in place. The mute changes where
        // the finding RANKS and whether it counts against the live cap, so
        // the correct new card is the one the server computes — patching the
        // DOM here would show a muted finding still sitting in the top eight
        // until something else happened to reload.
        await app.refresh();
      } catch (e) {
        action.disabled = false;
        err.textContent = t('findings.muted.failed', { error: e.message });
      }
    },
  }, isMuted(f) ? t('findings.unmute') : t('findings.mute', { hours: MUTE_HOURS }));

  row.append(...[status, action, err].filter(Boolean));
  return row;
}
