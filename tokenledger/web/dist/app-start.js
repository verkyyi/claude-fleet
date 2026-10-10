// web/dist/app-start.js — app.html's one script (claude-fleet#2793): start the
// shell on the page the address names. Each page's module is import()ed by
// the shell when it is first shown (PAGES' `module`, lib/shell.js).
import { Shell } from './app-shell.js';

Shell.start();
