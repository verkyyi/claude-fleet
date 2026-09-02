// web/dist/session.js — placeholder for Task 13 (the session detail overlay).
//
// app.js calls renderDetail() whenever the route carries a `session` id and
// closeDetail() otherwise, regardless of which view is active. Until task 13
// replaces this file with the real overlay (header fields + turnBars + turn
// table, per task-13-brief.md), both just keep <aside id="detail"> hidden —
// rendering a half-built panel would be worse than rendering nothing.
export function renderDetail(root, state, app) {
  root.hidden = true;
}

export function closeDetail(root) {
  root.hidden = true;
}
