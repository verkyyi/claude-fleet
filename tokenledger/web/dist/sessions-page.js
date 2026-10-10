// web/dist/sessions-page.js — Sessions, at /sessions (claude-fleet#1989):
// every open session of the viewer's own — a user's, and an admin's too
// (claude-fleet#2515; the whole fleet is All sessions, admin/sessions.js) —
// filtered by state, searched, and opened into a side drawer with how to
// reach it from a terminal and what it has done. The table is
// lib/sessions-view.js.
import { Shell } from './app-shell.js';
import { sessionsPage } from './lib/sessions-view.js';

export default Shell.mount('sessions', sessionsPage());
