// web/dist/review.js — placeholder for Task 12 (the Review view).
//
// Task 11 only needs app.js's router to have somewhere to mount while Review
// isn't built yet. Task 12 replaces this file with the real Review view
// described in task-12-brief.md (timeline + brush, KPI strip, findings,
// group-by breakdowns, efficiency, model mix, hourly heatmap, wall history,
// sessions table).
import { el } from './lib/dom.js';

export function renderReview(root, state, app) {
  root.replaceChildren(el('div', { class: 'card' },
    el('h2', {}, 'Review'),
    el('p', { class: 'hint' }, 'Review — coming in the next task.')));
  return { fetchers: [], apply() {} };
}
