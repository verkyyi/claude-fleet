// web/dist/admin/sessions.js — All sessions, at /admin/sessions
// (claude-fleet#2515): every open session in the fleet, with its person and
// subscription — what Sessions showed an admin before their own page became
// their own. /v1/admin/sessions; the table is lib/sessions-view.js.
import { Shell } from '../app-shell.js';
import { sessionsPage } from '../lib/sessions-view.js';

export default Shell.mount('all-sessions', sessionsPage({ all: true }));
